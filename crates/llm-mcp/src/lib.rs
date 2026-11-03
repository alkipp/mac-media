//! `llm-mcp`: lokale Textgenerierung und Embeddings über llama.cpp mit Metal.
//!
//! Modelle werden beim ersten Aufruf geladen und bleiben warm. Generierung und
//! Embeddings nutzen getrennte Caches, damit sie sich nicht behindern; in jedem
//! Cache liegt höchstens ein Modell. Die Rechenarbeit läuft in
//! Blocking-Threads, damit der MCP-Server währenddessen erreichbar bleibt.
//!
//! Modellpfad: `LLM_MODEL_PATH` oder die erste `.gguf`-Datei unter
//! `~/Library/Application Support/mac-compute/models/`.
//!
//! Speicherlimit: `LLM_MAX_MEMORY_MB`, sonst `maxMemoryMB` aus dem Manifest
//! `servers.d/llm.json` (Pfad per `LLM_MANIFEST`), sonst 4096 MiB. Geprüft
//! wird vor jedem Laden gegen die Dateigröße plus Reserve.

use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::LlamaModel;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::sampling::LlamaSampler;
use rmcp::{
    ErrorData as McpError, ServerHandler, ServiceExt,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    tool, tool_handler, tool_router,
    transport::stdio,
};
use schemars::JsonSchema;
use serde::Deserialize;

/// Größte Prompt-Länge in Zeichen.
pub const MAX_PROMPT_CHARS: usize = 8000;

/// Größte Eingabe für `embed` in Zeichen.
pub const MAX_EMBED_CHARS: usize = 8192;

/// Größte Anzahl neuer Tokens.
pub const MAX_NEW_TOKENS: u32 = 1024;

/// Standard-Kontextgröße.
const DEFAULT_CONTEXT: u32 = 4096;

/// Kleinste Kontextgröße für Embeddings.
const MIN_EMBED_CONTEXT: u32 = 32;

/// Speicherlimit in MiB, wenn weder Umgebung noch Manifest eines liefern.
pub const DEFAULT_MAX_MEMORY_MB: u64 = 4096;

/// Aufschlag auf die Modellgröße in Prozent (siehe [`estimate_memory_mb`]).
pub const MEMORY_RESERVE_PERCENT: u64 = 25;

/// Ein MiB in Bytes.
const MIB: u64 = 1024 * 1024;

/// Manifest dieses Backends im Manifestverzeichnis.
const MANIFEST_NAME: &str = "llm.json";

/// Art eines Fehlers; der Text steht als `kind` im JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// Aufruf war formal ungültig.
    InvalidParams,
    /// Modell wurde im Modellverzeichnis nicht gefunden.
    ModelNotFound,
    /// Modell überschreitet das Speicherlimit des Manifests.
    MemoryLimit,
    /// Modell ließ sich nicht laden.
    Model,
    /// Generierung ist fehlgeschlagen.
    Generate,
    /// Embedding ist fehlgeschlagen.
    Embedding,
    /// Interner Fehler, etwa eine vergiftete Sperre.
    Internal,
}

impl ErrorKind {
    /// Text, wie er im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidParams => "invalid_params",
            Self::ModelNotFound => "model_not_found",
            Self::MemoryLimit => "memory_limit",
            Self::Model => "model_error",
            Self::Generate => "generate_error",
            Self::Embedding => "embedding_error",
            Self::Internal => "internal",
        }
    }
}

impl std::fmt::Display for ErrorKind {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Fehler mit Einordnung und Meldung, wie ihn die übrigen Backends liefern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LlmError {
    kind: ErrorKind,
    message: String,
}

impl LlmError {
    /// Erzeugt einen Fehler mit Einordnung.
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    /// Einordnung des Fehlers.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// Meldung für den Aufrufer.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// JSON-Objekt `{"kind":…,"message":…}`.
    ///
    /// Von Hand geschrieben, damit die Crate ohne `serde_json` auskommt.
    pub fn to_json(&self) -> String {
        format!(
            "{{\"kind\":\"{}\",\"message\":\"{}\"}}",
            self.kind.as_str(),
            json_escape(&self.message)
        )
    }
}

impl std::fmt::Display for LlmError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.kind, self.message)
    }
}

impl std::error::Error for LlmError {}

/// Maskiert Anführungszeichen, Backslashes und Steuerzeichen für JSON.
fn json_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            character if character.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => escaped.push(character),
        }
    }
    escaped
}

/// Ein geladenes Modell samt Name; Kontexte entstehen je Aufruf daraus.
pub struct LoadedModel {
    name: String,
    model: LlamaModel,
}

/// Ein fertig gerundetes Embedding.
#[derive(Debug, Clone, PartialEq)]
pub struct Embedding {
    /// Anzahl der Dimensionen.
    pub dimensions: usize,
    /// Modellname ohne `.gguf`.
    pub model: String,
    /// Vektor, auf sechs Nachkommastellen gerundet.
    pub vector: Vec<f64>,
    /// Euklidische Norm des gerundeten Vektors.
    pub norm: f64,
}

impl Embedding {
    /// Rundet einen rohen Vektor und berechnet daraus die Norm.
    pub fn from_values(model: &str, values: &[f32]) -> Self {
        let vector: Vec<f64> = values
            .iter()
            .map(|value| round6(f64::from(*value)))
            .collect();
        let norm = round6(vector.iter().map(|value| value * value).sum::<f64>().sqrt());
        Self {
            dimensions: vector.len(),
            model: model.to_string(),
            vector,
            norm,
        }
    }

    /// JSON-Darstellung `{"dimensions":…,"model":…,"vector":[…],"norm":…}`.
    pub fn to_json(&self) -> String {
        let vector: Vec<String> = self
            .vector
            .iter()
            .map(|value| format!("{value:.6}"))
            .collect();
        format!(
            "{{\"dimensions\":{},\"model\":\"{}\",\"vector\":[{}],\"norm\":{:.6}}}",
            self.dimensions,
            json_escape(&self.model),
            vector.join(","),
            self.norm
        )
    }
}

/// Rundet auf sechs Nachkommastellen.
pub fn round6(value: f64) -> f64 {
    (value * 1_000_000.0).round() / 1_000_000.0
}

/// Ein gefundenes Modell im Modellverzeichnis.
#[derive(Debug, Clone)]
pub struct ModelEntry {
    /// Dateiname ohne `.gguf`.
    pub name: String,
    /// Vollständiger Pfad.
    pub path: PathBuf,
    /// Größe in Bytes.
    pub size_bytes: u64,
}

/// MCP-Server für lokale Textgenerierung und Embeddings.
#[derive(Clone)]
pub struct LlmServer {
    /// Ein Backend für den ganzen Prozess; llama.cpp erlaubt nur eine
    /// Initialisierung gleichzeitig.
    backend: Arc<LlamaBackend>,
    /// Modell für die Generierung.
    state: Arc<Mutex<Option<LoadedModel>>>,
    /// Eigenes Modell für Embeddings, damit die Generierung nicht blockiert.
    embed_state: Arc<Mutex<Option<LoadedModel>>>,
    models_dir: PathBuf,
    default_model: PathBuf,
    /// Limit aus dem Manifest in MiB.
    max_memory_mb: u64,
}

/// Argumente für `generate`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct GenerateArgs {
    /// Aufgabe oder Frage an das Modell (max. 8000 Zeichen).
    #[schemars(length(max = 8000))]
    pub prompt: String,

    /// Optionale Systemanweisung.
    #[schemars(length(max = 2000))]
    pub system: Option<String>,

    /// Maximale Anzahl neuer Tokens (1–1024, Standard 256).
    #[schemars(range(min = 1, max = 1024))]
    pub max_tokens: Option<u32>,

    /// Temperatur (0–2, Standard 0,7). 0 bedeutet greedy.
    #[schemars(range(min = 0.0, max = 2.0))]
    pub temperature: Option<f64>,

    /// Zufallsseed (Standard 1234).
    pub seed: Option<u32>,

    /// Modellname ohne `.gguf` (Standard: das geladene Modell).
    #[schemars(length(max = 128))]
    pub model: Option<String>,
}

/// Argumente für `embed`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct EmbedArgs {
    /// Text, der eingebettet wird (1–8192 Zeichen).
    #[schemars(length(min = 1, max = 8192))]
    pub text: String,

    /// Modellname ohne `.gguf` (Standard: das geladene Modell).
    #[schemars(length(max = 128))]
    pub model: Option<String>,
}

impl LlmServer {
    /// Lädt Backend und Standardmodell.
    pub fn load(model_path: &Path) -> Result<Self, String> {
        let models_dir = model_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        let max_memory_mb = memory_limit_mb(&models_dir);
        let backend = Arc::new(init_backend()?);
        let state =
            load_model(&backend, model_path, max_memory_mb).map_err(|error| error.to_string())?;
        Ok(Self {
            backend,
            state: Arc::new(Mutex::new(Some(state))),
            embed_state: Arc::new(Mutex::new(None)),
            models_dir,
            default_model: model_path.to_path_buf(),
            max_memory_mb,
        })
    }

    /// Alle `.gguf`-Dateien im Modellverzeichnis, alphabetisch.
    pub fn available_models(&self) -> Vec<ModelEntry> {
        scan_models(&self.models_dir)
    }

    /// Löst einen Modellnamen gegen die gefundenen Dateien auf.
    fn resolve_model(&self, requested: Option<&str>) -> Result<PathBuf, String> {
        let Some(name) = requested else {
            return Ok(self.default_model.clone());
        };
        self.available_models()
            .into_iter()
            .find(|entry| {
                entry.name == name || entry.path.file_name().is_some_and(|file| file == name)
            })
            .map(|entry| entry.path)
            .ok_or_else(|| format!("Modell '{name}' nicht gefunden"))
    }

    /// Pfad zum Modell: Env-Variable oder erste `.gguf` im Modellverzeichnis.
    pub fn default_model_path() -> Result<PathBuf, String> {
        if let Some(path) = std::env::var_os("LLM_MODEL_PATH") {
            return Ok(PathBuf::from(path));
        }
        let home = std::env::var_os("HOME").ok_or("HOME ist nicht gesetzt")?;
        let dir = PathBuf::from(home).join("Library/Application Support/mac-compute/models");
        let mut candidates: Vec<PathBuf> = std::fs::read_dir(&dir)
            .map_err(|error| format!("Modellverzeichnis {:?}: {error}", dir))?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "gguf")
            })
            .collect();
        candidates.sort();
        candidates
            .into_iter()
            .next()
            .ok_or_else(|| format!("kein GGUF-Modell unter {:?}; LLM_MODEL_PATH setzen", dir))
    }
}

/// Baut den ChatML-Prompt für Qwen-Instruct-Modelle.
fn chat_prompt(system: Option<&str>, user: &str) -> String {
    let system = system.unwrap_or("Du bist ein knapper, hilfreicher Assistent.");
    format!(
        "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n"
    )
}

/// Listet `.gguf`-Dateien in einem Verzeichnis, alphabetisch nach Namen.
pub fn scan_models(dir: &Path) -> Vec<ModelEntry> {
    let mut entries: Vec<ModelEntry> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "gguf")
        })
        .filter_map(|path| {
            let name = path.file_stem()?.to_string_lossy().to_string();
            let size_bytes = std::fs::metadata(&path).ok()?.len();
            Some(ModelEntry {
                name,
                path,
                size_bytes,
            })
        })
        .collect();
    entries.sort_by(|left, right| left.name.cmp(&right.name));
    entries
}

/// Dateiname ohne `.gguf`.
fn model_name(path: &Path) -> String {
    path.file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// Ob ein anderes Modell geladen werden muss.
///
/// Jeder Cache hält genau ein Modell; weicht der Name ab, wird das alte
/// vorher freigegeben.
fn needs_reload(loaded: Option<&str>, requested: &str) -> bool {
    loaded != Some(requested)
}

/// Schätzt den Speicherbedarf eines Modells in MiB.
///
/// Die Dateigröße ist nur das Gewicht. Dazu kommen KV-Cache, Graph- und
/// Backend-Puffer sowie die Kopien im Unified Memory von Metal; ein Aufschlag
/// von [`MEMORY_RESERVE_PERCENT`] deckt das für Embedding-Modelle und kleine
/// Generierungsmodelle grob ab. Der Wert ist bewusst pessimistisch: lieber ein
/// Modell ablehnen als den Mac in den Swap zwingen.
pub fn estimate_memory_mb(size_bytes: u64) -> u64 {
    size_bytes
        .saturating_mul(100 + MEMORY_RESERVE_PERCENT)
        .div_ceil(100 * MIB)
}

/// Prüft, ob ein Modell der Größe `size_bytes` in das Limit passt.
pub fn check_memory_budget(size_bytes: u64, limit_mb: u64) -> Result<(), LlmError> {
    let needed = estimate_memory_mb(size_bytes);
    if needed > limit_mb {
        return Err(LlmError::new(
            ErrorKind::MemoryLimit,
            format!(
                "Modell zu groß: {:.0} MB Datei, geschätzt {needed} MB inklusive \
                 {MEMORY_RESERVE_PERCENT} % Reserve, maxMemoryMB={limit_mb}",
                size_bytes as f64 / MIB as f64
            ),
        ));
    }
    Ok(())
}

/// Liest `maxMemoryMB` aus einem Manifest.
///
/// Bewusst ohne JSON-Parser: Das Manifest ist klein und wird vom Gateway
/// validiert; gesucht wird der Schlüssel `"maxMemoryMB"` mit ganzzahligem Wert.
pub fn parse_max_memory_mb(manifest: &str) -> Option<u64> {
    let key = "\"maxMemoryMB\"";
    let start = manifest.find(key)? + key.len();
    let rest = manifest.get(start..)?.trim_start().strip_prefix(':')?;
    let digits: String = rest
        .trim_start()
        .chars()
        .take_while(|character| character.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

/// Pfad zum Manifest dieses Backends.
fn manifest_path(models_dir: &Path) -> PathBuf {
    if let Some(path) = std::env::var_os("LLM_MANIFEST") {
        return PathBuf::from(path);
    }
    models_dir
        .parent()
        .unwrap_or(models_dir)
        .join("servers.d")
        .join(MANIFEST_NAME)
}

/// Speicherlimit in MiB aus Umgebung, Manifest oder Standard.
fn memory_limit_mb(models_dir: &Path) -> u64 {
    if let Some(value) = std::env::var("LLM_MAX_MEMORY_MB")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
    {
        return value;
    }
    std::fs::read_to_string(manifest_path(models_dir))
        .ok()
        .and_then(|text| parse_max_memory_mb(&text))
        .unwrap_or(DEFAULT_MAX_MEMORY_MB)
}

/// Initialisiert das Backend; llama.cpp protokolliert sonst sehr gesprächig.
fn init_backend() -> Result<LlamaBackend, String> {
    llama_cpp_2::send_logs_to_tracing(llama_cpp_2::LogOptions::default().with_logs_enabled(false));
    LlamaBackend::init().map_err(|error| format!("Backend: {error}"))
}

/// Prüft das Speicherlimit und lädt das Modell von der Platte.
fn load_model(
    backend: &LlamaBackend,
    model_path: &Path,
    limit_mb: u64,
) -> Result<LoadedModel, LlmError> {
    let size_bytes = std::fs::metadata(model_path)
        .map_err(|error| {
            LlmError::new(
                ErrorKind::Model,
                format!("Modell {:?}: {error}", model_path),
            )
        })?
        .len();
    check_memory_budget(size_bytes, limit_mb)?;

    let params = LlamaModelParams::default().with_n_gpu_layers(1000);
    let model = LlamaModel::load_from_file(backend, model_path, &params).map_err(|error| {
        LlmError::new(
            ErrorKind::Model,
            format!("Modell {:?}: {error}", model_path),
        )
    })?;
    Ok(LoadedModel {
        name: model_name(model_path),
        model,
    })
}

/// Erzeugt Text mit dem geladenen Modell.
pub fn generate(
    backend: &LlamaBackend,
    loaded: &LoadedModel,
    prompt: &str,
    max_tokens: u32,
    temperature: f64,
    seed: u32,
) -> Result<String, LlmError> {
    let tokens = loaded.model.vocab().tokenize(prompt.as_bytes(), true, true);
    if tokens.is_empty() {
        return Err(LlmError::new(
            ErrorKind::InvalidParams,
            "Prompt ergibt keine Tokens",
        ));
    }

    let needed = u32::try_from(tokens.len()).unwrap_or(u32::MAX) + max_tokens + 8;
    let n_ctx = needed.clamp(512, DEFAULT_CONTEXT.max(needed));
    let mut context = loaded
        .model
        .new_context(
            backend,
            LlamaContextParams::default().with_n_ctx(NonZeroU32::new(n_ctx)),
        )
        .map_err(|error| LlmError::new(ErrorKind::Generate, format!("Kontext: {error}")))?;

    let mut batch = LlamaBatch::new(tokens.len().max(512), 1);
    let last = tokens.len() - 1;
    for (index, token) in tokens.iter().enumerate() {
        batch
            .add(*token, index as i32, &[0], index == last)
            .map_err(|error| LlmError::new(ErrorKind::Generate, format!("Batch: {error}")))?;
    }
    context
        .decode(&mut batch)
        .map_err(|error| LlmError::new(ErrorKind::Generate, format!("Prompt-Decode: {error}")))?;

    let mut sampler = if temperature <= 0.01 {
        LlamaSampler::greedy()
    } else {
        LlamaSampler::chain_simple([
            LlamaSampler::temp(temperature as f32),
            LlamaSampler::dist(seed),
        ])
    };

    let mut output: Vec<u8> = Vec::new();
    let start = batch.n_tokens();
    for step in 0..max_tokens {
        let token = sampler.sample(&context, batch.n_tokens() - 1);
        sampler.accept(token);
        if loaded.model.vocab().is_eog(token) {
            break;
        }
        output.extend_from_slice(&loaded.model.vocab().token_to_piece(token, true, None));

        batch.clear();
        batch
            .add(token, start + step as i32, &[0], true)
            .map_err(|error| LlmError::new(ErrorKind::Generate, format!("Batch: {error}")))?;
        context
            .decode(&mut batch)
            .map_err(|error| LlmError::new(ErrorKind::Generate, format!("Decode: {error}")))?;
    }

    Ok(String::from_utf8_lossy(&output).trim().to_string())
}

/// Berechnet den Embedding-Vektor eines Textes.
///
/// Der Kontext entsteht je Aufruf: llama-cpp-2 0.1.160 bietet keinen Weg, den
/// KV-Cache eines Kontexts zu leeren, und llama.cpp verwendet belegte Zellen
/// derselben Sequenz nicht wieder. Ein wiederverwendeter Kontext würde deshalb
/// die Reste des vorigen Textes mitsehen und falsche Vektoren liefern. Das
/// Modell selbst bleibt geladen und warm.
pub fn embed(
    backend: &LlamaBackend,
    loaded: &LoadedModel,
    text: &str,
) -> Result<Vec<f32>, LlmError> {
    let tokens = loaded.model.vocab().tokenize(text.as_bytes(), true, true);
    if tokens.is_empty() {
        return Err(LlmError::new(
            ErrorKind::InvalidParams,
            "Text ergibt keine Tokens",
        ));
    }
    let n_tokens = u32::try_from(tokens.len()).map_err(|_| {
        LlmError::new(
            ErrorKind::InvalidParams,
            format!("Text zu lang: {} Tokens", tokens.len()),
        )
    })?;
    // Kontext genau so groß wie der Text plus Reserve. `n_batch` und `n_ubatch`
    // müssen den ganzen Text fassen, sonst bricht llama.cpp bei nicht-kausalen
    // Modellen ab.
    let n_ctx = n_tokens.saturating_add(8).max(MIN_EMBED_CONTEXT);
    let params = LlamaContextParams::default()
        .with_embeddings(true)
        .with_n_ctx(NonZeroU32::new(n_ctx))
        .with_n_batch(n_ctx)
        .with_n_ubatch(n_ctx);
    let mut context = loaded
        .model
        .new_context(backend, params)
        .map_err(|error| LlmError::new(ErrorKind::Embedding, format!("Kontext: {error}")))?;

    let mut batch = LlamaBatch::new(tokens.len(), 1);
    let last = tokens.len() - 1;
    for (index, token) in tokens.iter().enumerate() {
        // Logits nur für das letzte Token: der Rückfallweg ohne Pooling liest
        // genau dort den Vektor ab.
        batch
            .add(*token, index as i32, &[0], index == last)
            .map_err(|error| LlmError::new(ErrorKind::Embedding, format!("Batch: {error}")))?;
    }
    context
        .decode(&mut batch)
        .map_err(|error| LlmError::new(ErrorKind::Embedding, format!("Decode: {error}")))?;

    // Embedding-Modelle liefern den gepoolten Vektor der Sequenz; kausale
    // Modelle ohne Pooling nur den Vektor des letzten Tokens.
    let values = match context.embeddings_seq_ith(0) {
        Ok(values) => values.to_vec(),
        Err(_) => context
            .embeddings_ith(last as i32)
            .map_err(|_| {
                LlmError::new(
                    ErrorKind::Embedding,
                    "Modell liefert keine Embeddings (Pooling fehlt)",
                )
            })?
            .to_vec(),
    };
    Ok(values)
}

/// Prüft die Eingabe für `embed`.
pub fn validate_embed_text(text: &str) -> Result<(), LlmError> {
    if text.trim().is_empty() {
        return Err(LlmError::new(ErrorKind::InvalidParams, "text ist leer"));
    }
    if text.chars().count() > MAX_EMBED_CHARS {
        return Err(LlmError::new(
            ErrorKind::InvalidParams,
            format!("text ist länger als {MAX_EMBED_CHARS} Zeichen"),
        ));
    }
    Ok(())
}

/// Fehlerantwort für `embed`: isError mit `{"kind":…,"message":…}`.
fn embed_error(error: &LlmError) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(error.to_json())])
}

#[tool_router]
impl LlmServer {
    #[tool(description = "Listet die verfügbaren GGUF-Modelle im Modellverzeichnis")]
    fn models(&self) -> Result<CallToolResult, McpError> {
        let entries = self.available_models();
        if entries.is_empty() {
            return Ok(CallToolResult::success(vec![ContentBlock::text(
                "keine Modelle gefunden".to_string(),
            )]));
        }
        let lines: Vec<String> = entries
            .iter()
            .map(|entry| {
                format!(
                    "- {} ({:.0} MB)",
                    entry.name,
                    entry.size_bytes as f64 / (1024.0 * 1024.0)
                )
            })
            .collect();
        Ok(CallToolResult::success(vec![ContentBlock::text(
            lines.join("\n"),
        )]))
    }

    #[tool(description = "Erzeugt Text mit dem lokalen llama.cpp-Modell (Metal)")]
    async fn generate(
        &self,
        Parameters(args): Parameters<GenerateArgs>,
    ) -> Result<CallToolResult, McpError> {
        if args.prompt.chars().count() > MAX_PROMPT_CHARS {
            return Err(McpError::invalid_params(
                format!("prompt ist länger als {MAX_PROMPT_CHARS} Zeichen"),
                None,
            ));
        }
        let max_tokens = args.max_tokens.unwrap_or(256).clamp(1, MAX_NEW_TOKENS);
        let temperature = args.temperature.unwrap_or(0.7).clamp(0.0, 2.0);
        let seed = args.seed.unwrap_or(1234);
        let prompt = chat_prompt(args.system.as_deref(), &args.prompt);

        let path = self
            .resolve_model(args.model.as_deref())
            .map_err(|error| McpError::internal_error(error, None))?;
        let name = model_name(&path);
        let state = Arc::clone(&self.state);
        let backend = Arc::clone(&self.backend);
        let limit_mb = self.max_memory_mb;
        let started = Instant::now();
        let text = tokio::task::spawn_blocking(move || {
            let mut guard = state
                .lock()
                .map_err(|_| LlmError::new(ErrorKind::Internal, "Modell-Sperre vergiftet"))?;
            let needs_load = needs_reload(guard.as_ref().map(|loaded| loaded.name.as_str()), &name);
            if needs_load {
                // Altes Modell zuerst freigeben, sonst lägen kurzzeitig beide im
                // Speicher und das Limit wäre wirkungslos.
                *guard = None;
                *guard = Some(load_model(&backend, &path, limit_mb)?);
            }
            let loaded = guard
                .as_ref()
                .ok_or_else(|| LlmError::new(ErrorKind::Internal, "kein Modell geladen"))?;
            generate(&backend, loaded, &prompt, max_tokens, temperature, seed)
        })
        .await
        .map_err(|error| McpError::internal_error(format!("Task: {error}"), None))?
        .map_err(|error: LlmError| McpError::internal_error(error.message().to_string(), None))?;

        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        Ok(CallToolResult::success(vec![
            ContentBlock::text(text),
            ContentBlock::text(format!("{max_tokens} max. Tokens, {elapsed:.0} ms")),
        ]))
    }

    #[tool(description = "Berechnet ein Embedding für einen Text (llama.cpp, Metal)")]
    async fn embed(
        &self,
        Parameters(args): Parameters<EmbedArgs>,
    ) -> Result<CallToolResult, McpError> {
        let started = Instant::now();
        if let Err(error) = validate_embed_text(&args.text) {
            return Ok(embed_error(&error));
        }
        let path = match self.resolve_model(args.model.as_deref()) {
            Ok(path) => path,
            Err(message) => {
                return Ok(embed_error(&LlmError::new(
                    ErrorKind::ModelNotFound,
                    message,
                )));
            }
        };
        let name = model_name(&path);
        let text = args.text;
        let state = Arc::clone(&self.embed_state);
        let backend = Arc::clone(&self.backend);
        let limit_mb = self.max_memory_mb;
        let result = tokio::task::spawn_blocking(move || {
            let mut guard = state
                .lock()
                .map_err(|_| LlmError::new(ErrorKind::Internal, "Embedding-Sperre vergiftet"))?;
            let needs_load = needs_reload(guard.as_ref().map(|loaded| loaded.name.as_str()), &name);
            if needs_load {
                // Ein Cache mit einem Modell: das alte vor dem neuen freigeben.
                *guard = None;
                *guard = Some(load_model(&backend, &path, limit_mb)?);
            }
            let loaded = guard
                .as_ref()
                .ok_or_else(|| LlmError::new(ErrorKind::Internal, "kein Modell geladen"))?;
            let values = embed(&backend, loaded, &text)?;
            Ok::<Embedding, LlmError>(Embedding::from_values(&loaded.name, &values))
        })
        .await
        .map_err(|error| McpError::internal_error(format!("Task: {error}"), None))?;

        match result {
            Ok(embedding) => {
                let elapsed = started.elapsed().as_secs_f64() * 1000.0;
                Ok(CallToolResult::success(vec![
                    ContentBlock::text(embedding.to_json()),
                    ContentBlock::text(format!(
                        "{} Dimensionen, {elapsed:.0} ms",
                        embedding.dimensions
                    )),
                ]))
            }
            Err(error) => Ok(embed_error(&error)),
        }
    }
}

#[tool_handler]
impl ServerHandler for LlmServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("llm-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions("Lokale Textgenerierung und Embeddings über llama.cpp mit Metal.")
    }
}

/// Bedient das Backend über stdio.
pub async fn run_stdio(server: LlmServer) -> Result<(), Box<dyn std::error::Error>> {
    let service = server.serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        Embedding, ErrorKind, LlmError, LlmServer, MAX_EMBED_CHARS, chat_prompt,
        check_memory_budget, embed, estimate_memory_mb, needs_reload, parse_max_memory_mb, round6,
        scan_models, validate_embed_text,
    };

    #[test]
    fn scans_gguf_models() {
        let dir = std::env::temp_dir().join(format!("llm-mcp-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        std::fs::write(dir.join("b.gguf"), b"12345").expect("Modell");
        std::fs::write(dir.join("a.gguf"), b"123").expect("Modell");
        std::fs::write(dir.join("notiz.txt"), b"x").expect("Notiz");

        let entries = scan_models(&dir);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "a");
        assert_eq!(entries[0].size_bytes, 3);
        assert_eq!(entries[1].name, "b");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn chat_prompt_uses_chatml() {
        let prompt = chat_prompt(Some("System"), "Frage");
        assert!(prompt.starts_with("<|im_start|>system\nSystem"));
        assert!(prompt.contains("<|im_start|>user\nFrage"));
        assert!(prompt.ends_with("<|im_start|>assistant\n"));
    }

    #[test]
    fn loads_only_when_the_model_changes() {
        assert!(needs_reload(None, "a"));
        assert!(!needs_reload(Some("a"), "a"));
        assert!(needs_reload(Some("a"), "b"));
    }

    #[test]
    fn estimates_memory_with_reserve() {
        assert_eq!(estimate_memory_mb(0), 0);
        // 1 Byte wird auf ein MiB aufgerundet.
        assert_eq!(estimate_memory_mb(1), 1);
        // 1000 MiB Datei plus 25 % Reserve.
        assert_eq!(estimate_memory_mb(1000 * 1024 * 1024), 1250);
        // Krumme Größe rundet auf.
        assert_eq!(estimate_memory_mb(820 * 1024 * 1024), 1025);
    }

    #[test]
    fn rejects_models_over_the_limit() {
        let size = 1000 * 1024 * 1024;
        assert!(check_memory_budget(size, 4096).is_ok());

        let error = check_memory_budget(size, 1024).expect_err("über dem Limit");
        assert_eq!(error.kind(), ErrorKind::MemoryLimit);
        assert!(error.message().contains("maxMemoryMB=1024"), "{}", error);
        assert!(error.message().contains("1250"), "{}", error);
        assert!(error.message().contains("1000 MB"), "{}", error);
    }

    #[test]
    fn reads_max_memory_from_manifest() {
        let manifest = r#"{"name":"llm","timeout":600000,"maxMemoryMB": 2048,"enabled":true}"#;
        assert_eq!(parse_max_memory_mb(manifest), Some(2048));
        assert_eq!(parse_max_memory_mb("{}"), None);
        assert_eq!(parse_max_memory_mb(r#"{"maxMemoryMB":"4096"}"#), None);
        assert_eq!(parse_max_memory_mb(r#"{"maxMemoryMB":}"#), None);
    }

    #[test]
    fn rounds_to_six_decimals() {
        assert!((round6(0.123_456_789) - 0.123_457).abs() < 1e-12);
        assert!((round6(-1.5) + 1.5).abs() < 1e-12);
        assert!(round6(0.0).abs() < 1e-12);
    }

    #[test]
    fn builds_embedding_with_norm() {
        let embedding = Embedding::from_values("m", &[3.0, 4.0]);
        assert_eq!(embedding.dimensions, 2);
        assert_eq!(embedding.model, "m");
        assert_eq!(embedding.vector, vec![3.0, 4.0]);
        assert!((embedding.norm - 5.0).abs() < 1e-12);
    }

    #[test]
    fn formats_embedding_as_json() {
        let embedding = Embedding::from_values("qwen", &[0.5, -0.25]);
        assert_eq!(
            embedding.to_json(),
            "{\"dimensions\":2,\"model\":\"qwen\",\"vector\":[0.500000,-0.250000],\
             \"norm\":0.559017}"
        );
    }

    #[test]
    fn escapes_model_names_in_json() {
        let embedding = Embedding::from_values("a\"b\\c", &[1.0]);
        assert!(
            embedding.to_json().contains(r#""model":"a\"b\\c""#),
            "{}",
            embedding.to_json()
        );
    }

    #[test]
    fn formats_errors_as_json() {
        let error = LlmError::new(ErrorKind::MemoryLimit, "zu \"groß\"");
        assert_eq!(
            error.to_json(),
            r#"{"kind":"memory_limit","message":"zu \"groß\""}"#
        );
        assert_eq!(error.kind().as_str(), "memory_limit");
    }

    #[test]
    fn validates_embed_text() {
        assert!(validate_embed_text("hallo").is_ok());

        let empty = validate_embed_text("   ").expect_err("leer");
        assert_eq!(empty.kind(), ErrorKind::InvalidParams);
        assert!(empty.message().contains("leer"));

        let longest = "a".repeat(MAX_EMBED_CHARS);
        assert!(validate_embed_text(&longest).is_ok());

        let too_long = "a".repeat(MAX_EMBED_CHARS + 1);
        let error = validate_embed_text(&too_long).expect_err("zu lang");
        assert_eq!(error.kind(), ErrorKind::InvalidParams);
        let expected = MAX_EMBED_CHARS.to_string();
        assert!(error.message().contains(expected.as_str()));
    }

    /// Modellabhängig: braucht ein GGUF-Modell und Metal, deshalb nur manuell
    /// mit `cargo test -p llm-mcp -- --ignored`.
    #[test]
    #[ignore = "braucht ein GGUF-Modell im Modellverzeichnis und Metal"]
    fn embeds_text_with_real_model() {
        let path = LlmServer::default_model_path().expect("Modellpfad");
        let server = LlmServer::load(&path).expect("Server");
        let guard = server.state.lock().expect("Sperre");
        let loaded = guard.as_ref().expect("Modell geladen");

        let values = embed(&server.backend, loaded, "Hallo Welt").expect("Embedding");
        let embedding = Embedding::from_values(&loaded.name, &values);

        assert!(embedding.dimensions > 0);
        assert_eq!(embedding.dimensions, embedding.vector.len());
        assert!(embedding.norm > 0.0);
    }
}
