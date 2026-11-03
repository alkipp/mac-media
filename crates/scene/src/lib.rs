//! Szenenbeschreibung (Version 1) für das Frame-Rendering.
//!
//! Eine Szene ist eine JSON-Datei mit Bildfläche, Dauer, Hintergrundfarbe und
//! Ebenen. Die Regeln sind absichtlich eng: unbekannte Felder, eine falsche
//! Version und Werte außerhalb der Grenzen werden abgelehnt, nicht still
//! korrigiert.
//!
//! ```json
//! {"version":1,"width":1920,"height":1080,"fps":30,"duration":10.0,
//!  "background":"#101218","layers":[]}
//! ```
//!
//! [`Scene::from_path`] prüft zusätzlich, dass Bildpfade relativ zur
//! Szenen-Datei liegen und die Dateien vorhanden sind.
//!
//! Eine Ebene kann optional `motion` tragen: entweder lineare Felder
//! (`dx`, `dy`, `opacity_from`, `opacity_to`) über die Gesamtdauer oder eine
//! Liste von `keyframes` in Sekunden. `easing` gilt in beiden Fällen. Beide
//! Formen schließen sich aus.

use std::fmt;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Erwartete Version des Formats.
pub const VERSION: u32 = 1;

/// Kleinste erlaubte Kantenlänge in Pixeln.
pub const MIN_SIZE: u32 = 16;

/// Größte erlaubte Kantenlänge in Pixeln.
pub const MAX_SIZE: u32 = 8192;

/// Kleinste erlaubte Bildrate.
pub const MIN_FPS: u32 = 1;

/// Größte erlaubte Bildrate.
pub const MAX_FPS: u32 = 120;

/// Größte erlaubte Dauer in Sekunden.
pub const MAX_DURATION: f64 = 600.0;

/// Größte erlaubte Zahl von Ebenen.
pub const MAX_LAYERS: usize = 256;

/// Größte erlaubte Zahl von Stützpunkten je Bewegung.
pub const MAX_KEYFRAMES: usize = 64;

/// Kleinste erlaubte Schriftgröße.
pub const MIN_TEXT_SIZE: f64 = 1.0;

/// Größte erlaubte Schriftgröße.
pub const MAX_TEXT_SIZE: f64 = 512.0;

/// Erlaubte Endungen für Bild-Ebenen, klein geschrieben.
const IMAGE_EXTENSIONS: [&str; 4] = ["png", "jpg", "jpeg", "webp"];

/// Einordnung eines Szenen-Fehlers.
///
/// Die Texte erscheinen im JSON als `kind`; sie sind stabil und für Aufrufer
/// gedacht, die Fälle unterscheiden wollen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// Datei ist nicht lesbar.
    Io,
    /// JSON ist syntaktisch falsch, hat unbekannte Felder oder falsche Typen.
    InvalidJson,
    /// Die Version ist nicht 1.
    UnsupportedVersion,
    /// Ein Wert liegt außerhalb der erlaubten Grenzen.
    OutOfRange,
    /// Eine Farbe ist kein `#RRGGBB` oder `#RRGGBBAA`.
    InvalidColor,
    /// Ein Bildpfad ist absolut, enthält `..` oder hat eine unbekannte Endung.
    InvalidPath,
    /// Eine Bilddatei fehlt relativ zum Szenen-Verzeichnis.
    MissingImage,
    /// Eine Bewegung ist widersprüchlich: `keyframes` zusammen mit linearen
    /// Feldern oder unsortierte/doppelte Stützpunkte.
    InvalidMotion,
}

impl ErrorKind {
    /// Text, wie er im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Io => "io",
            Self::InvalidJson => "invalid_json",
            Self::UnsupportedVersion => "unsupported_version",
            Self::OutOfRange => "out_of_range",
            Self::InvalidColor => "invalid_color",
            Self::InvalidPath => "invalid_path",
            Self::MissingImage => "missing_image",
            Self::InvalidMotion => "invalid_motion",
        }
    }
}

/// Fehler beim Laden oder Prüfen einer Szene.
///
/// Serialisiert als `{"kind":"…","message":"…"}`; das ist dasselbe Format, das
/// Gateway und Jobs für Fehler verwenden.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SceneError {
    kind: ErrorKind,
    message: String,
}

impl SceneError {
    /// Erzeugt einen Fehler mit Einordnung und Meldung.
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

    /// Einordnung als Text, wie im JSON.
    pub fn kind_str(&self) -> &'static str {
        self.kind.as_str()
    }

    /// Meldung für den Aufrufer.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// Fehler als JSON-Objekt `{"kind":…,"message":…}`.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({ "kind": self.kind_str(), "message": self.message })
    }
}

impl fmt::Display for SceneError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.kind_str(), self.message)
    }
}

impl std::error::Error for SceneError {}

/// Farbe als RGBA8 mit Werten aus `#RRGGBB` oder `#RRGGBBAA`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Color {
    /// Rotanteil.
    pub r: u8,
    /// Grünanteil.
    pub g: u8,
    /// Blauanteil.
    pub b: u8,
    /// Deckkraft.
    pub a: u8,
}

impl Color {
    /// Farbe aus fertigen Kanälen.
    pub const fn from_rgba8(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    /// Liest `#RRGGBB` oder `#RRGGBBAA` (Hex-Ziffern in beliebiger Schreibweise).
    pub fn from_hex(value: &str) -> Result<Self, SceneError> {
        // Ohne führendes '#' bleibt der Rest leer und ist damit ungültig.
        let digits = value.strip_prefix('#').unwrap_or("");
        let valid = matches!(digits.len(), 6 | 8) && digits.bytes().all(|b| b.is_ascii_hexdigit());
        if !valid {
            return Err(SceneError::new(
                ErrorKind::InvalidColor,
                format!("Farbe '{value}' ist ungültig: erwartet #RRGGBB oder #RRGGBBAA"),
            ));
        }
        let channel = |range: std::ops::Range<usize>| -> u8 {
            u8::from_str_radix(&digits[range], 16).expect("Hex-Ziffern sind geprüft")
        };
        let a = if digits.len() == 8 {
            channel(6..8)
        } else {
            255
        };
        Ok(Self {
            r: channel(0..2),
            g: channel(2..4),
            b: channel(4..6),
            a,
        })
    }

    /// Kanäle als `(r, g, b, a)`.
    pub fn to_rgba8(self) -> (u8, u8, u8, u8) {
        (self.r, self.g, self.b, self.a)
    }

    /// Kanäle als `[r, g, b, a]`.
    pub fn to_array(self) -> [u8; 4] {
        [self.r, self.g, self.b, self.a]
    }

    /// Farbe als `#RRGGBB` (deckend) oder `#RRGGBBAA`.
    pub fn to_hex(self) -> String {
        if self.a == 255 {
            format!("#{:02X}{:02X}{:02X}", self.r, self.g, self.b)
        } else {
            format!("#{:02X}{:02X}{:02X}{:02X}", self.r, self.g, self.b, self.a)
        }
    }
}

impl fmt::Display for Color {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.to_hex())
    }
}

impl Serialize for Color {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for Color {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Color::from_hex(&value).map_err(serde::de::Error::custom)
    }
}

/// Verlauf, mit dem zwischen zwei Werten interpoliert wird.
///
/// Der Wert wird auf 0.0–1.0 geklemmt; die Kurven sind bewusst einfach und
/// ohne Zufall, damit dieselbe Szene zur selben Zeit denselben Wert ergibt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Easing {
    /// Gleichmäßig: `t`.
    #[default]
    Linear,
    /// Beschleunigend: `t²`.
    EaseIn,
    /// Abbremsend: `1 - (1 - t)²`.
    EaseOut,
    /// Weich an und aus: `3t² - 2t³`.
    EaseInOut,
}

impl Easing {
    /// Text, wie er im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Linear => "linear",
            Self::EaseIn => "ease-in",
            Self::EaseOut => "ease-out",
            Self::EaseInOut => "ease-in-out",
        }
    }

    /// Ob der Verlauf linear ist; dient dem Weglassen im JSON.
    pub fn is_linear(&self) -> bool {
        matches!(self, Self::Linear)
    }

    /// Gewicht für einen Fortschritt 0.0–1.0; außerhalb geklemmt.
    pub fn apply(self, progress: f64) -> f64 {
        if !progress.is_finite() {
            return 0.0;
        }
        let t = progress.clamp(0.0, 1.0);
        match self {
            Self::Linear => t,
            Self::EaseIn => t * t,
            Self::EaseOut => {
                let inverse = 1.0 - t;
                1.0 - inverse * inverse
            }
            Self::EaseInOut => t * t * (3.0 - 2.0 * t),
        }
    }
}

/// Stützpunkt einer Bewegung zu einem Zeitpunkt in Sekunden.
///
/// `x` und `y` sind absolute Positionen in Pixeln, keine Verschiebungen.
/// Fehlende Felder erben den Standort der Ebene (`x`, `y`) bzw. die volle
/// Deckkraft 1.0. Vor dem ersten und nach dem letzten Punkt gilt der jeweilige
/// Wert.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Keyframe {
    /// Zeitpunkt in Sekunden seit Szenenbeginn.
    pub t: f64,
    /// Absolute Position in x-Richtung in Pixeln; fehlt sie, gilt `x` der Ebene.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    /// Absolute Position in y-Richtung in Pixeln; fehlt sie, gilt `y` der Ebene.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    /// Deckkraft 0.0–1.0; fehlt sie, gilt 1.0.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f64>,
}

/// Bewegung einer Ebene: linear über die Gesamtdauer oder als Keyframes.
///
/// Beide Formen schließen sich aus. Fehlende lineare Felder bleiben neutral
/// (keine Verschiebung, volle Deckkraft). Gesetzt und nicht gesetzt wird
/// unterschieden, damit `keyframes` nicht still mit `dx: 0` kombiniert wird.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Motion {
    /// Verschiebung in x-Richtung in Pixeln.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dx: Option<f64>,
    /// Verschiebung in y-Richtung in Pixeln.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dy: Option<f64>,
    /// Deckkraft am Anfang (0.0–1.0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity_from: Option<f64>,
    /// Deckkraft am Ende (0.0–1.0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity_to: Option<f64>,
    /// Verlauf zwischen den Werten; fehlt er, gilt `linear`.
    #[serde(default, skip_serializing_if = "Easing::is_linear")]
    pub easing: Easing,
    /// Stützpunkte in Sekunden; schließen die linearen Felder aus.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyframes: Option<Vec<Keyframe>>,
}

/// Rechteck-Ebene.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RectLayer {
    /// Linke Kante in Pixeln.
    pub x: f64,
    /// Obere Kante in Pixeln.
    pub y: f64,
    /// Breite in Pixeln.
    pub width: f64,
    /// Höhe in Pixeln.
    pub height: f64,
    /// Eckenradius in Pixeln; 0 zeichnet ein scharfes Rechteck.
    #[serde(default)]
    pub radius: f64,
    /// Füllfarbe.
    pub color: Color,
    /// Optionale Bewegung.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<Motion>,
}

/// Kreis-Ebene.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CircleLayer {
    /// Mittelpunkt in x-Richtung in Pixeln.
    pub x: f64,
    /// Mittelpunkt in y-Richtung in Pixeln.
    pub y: f64,
    /// Radius in Pixeln.
    pub radius: f64,
    /// Füllfarbe.
    pub color: Color,
    /// Optionale Bewegung.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<Motion>,
}

/// Text-Ebene.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TextLayer {
    /// Linke Kante in Pixeln.
    pub x: f64,
    /// Grundlinie (Baseline) in Pixeln.
    pub y: f64,
    /// Textinhalt.
    pub text: String,
    /// Schriftgröße in Pixeln.
    pub size: f64,
    /// Textfarbe.
    pub color: Color,
    /// Optionale Bewegung.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<Motion>,
}

/// Bild-Ebene; der Pfad ist relativ zur Szenen-Datei.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ImageLayer {
    /// Linke Kante in Pixeln.
    pub x: f64,
    /// Obere Kante in Pixeln.
    pub y: f64,
    /// Zielbreite in Pixeln.
    pub width: f64,
    /// Zielhöhe in Pixeln.
    pub height: f64,
    /// Relativer Pfad mit Endung `.png`, `.jpg`, `.jpeg` oder `.webp`.
    pub path: String,
    /// Optionale Bewegung.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<Motion>,
}

/// Eine Ebene der Szene.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Layer {
    /// Rechteck, optional mit Eckenradius.
    Rect(RectLayer),
    /// Kreis.
    Circle(CircleLayer),
    /// Textzeile.
    Text(TextLayer),
    /// Bild (PNG, JPEG oder WebP).
    Image(ImageLayer),
}

/// Art einer Ebene, wie sie im JSON im Feld `type` steht.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerKind {
    /// `rect`
    Rect,
    /// `circle`
    Circle,
    /// `text`
    Text,
    /// `image`
    Image,
}

impl LayerKind {
    /// Text, wie er im JSON steht.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rect => "rect",
            Self::Circle => "circle",
            Self::Text => "text",
            Self::Image => "image",
        }
    }
}

impl Layer {
    /// Art der Ebene.
    pub fn kind(&self) -> LayerKind {
        match self {
            Self::Rect(_) => LayerKind::Rect,
            Self::Circle(_) => LayerKind::Circle,
            Self::Text(_) => LayerKind::Text,
            Self::Image(_) => LayerKind::Image,
        }
    }

    /// Ausgangsposition `(x, y)` ohne Bewegung.
    pub fn base_position(&self) -> (f64, f64) {
        match self {
            Self::Rect(layer) => (layer.x, layer.y),
            Self::Circle(layer) => (layer.x, layer.y),
            Self::Text(layer) => (layer.x, layer.y),
            Self::Image(layer) => (layer.x, layer.y),
        }
    }

    /// Bewegung der Ebene, falls angegeben.
    pub fn motion(&self) -> Option<&Motion> {
        match self {
            Self::Rect(layer) => layer.motion.as_ref(),
            Self::Circle(layer) => layer.motion.as_ref(),
            Self::Text(layer) => layer.motion.as_ref(),
            Self::Image(layer) => layer.motion.as_ref(),
        }
    }

    /// Position und Deckkraft zum Zeitpunkt `time` in Sekunden.
    ///
    /// `duration` ist die Gesamtdauer der Szene; sie bestimmt den Fortschritt
    /// für `dx`/`dy`/`opacity_from`/`opacity_to`. Keyframes werden dagegen
    /// direkt in Sekunden ausgewertet. Nicht-endliche Zeiten gelten als 0.
    pub fn placement_at(&self, time: f64, duration: f64) -> Placement {
        let duration = if duration.is_finite() && duration > 0.0 {
            duration
        } else {
            0.0
        };
        let time = if time.is_finite() {
            time.clamp(0.0, duration)
        } else {
            0.0
        };
        let (base_x, base_y) = self.base_position();
        let Some(motion) = self.motion() else {
            return Placement {
                x: base_x,
                y: base_y,
                opacity: 1.0,
            };
        };
        if let Some(keyframes) = motion.keyframes.as_deref() {
            return sample_keyframes(keyframes, motion.easing, (base_x, base_y), time);
        }
        let progress = if duration > 0.0 {
            (time / duration).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let weight = motion.easing.apply(progress);
        let opacity_from = motion.opacity_from.unwrap_or(1.0);
        let opacity_to = motion.opacity_to.unwrap_or(1.0);
        Placement {
            x: base_x + motion.dx.unwrap_or(0.0) * weight,
            y: base_y + motion.dy.unwrap_or(0.0) * weight,
            opacity: (opacity_from + (opacity_to - opacity_from) * weight).clamp(0.0, 1.0),
        }
    }

    /// Prüft die Werte der Ebene; `index` erscheint in der Meldung.
    ///
    /// `duration` begrenzt die Zeitpunkte der Keyframes.
    pub fn validate(&self, index: usize, duration: f64) -> Result<(), SceneError> {
        let context = format!("Ebene {index} ({})", self.kind().as_str());
        match self {
            Self::Rect(layer) => {
                require_finite(&context, "x", layer.x)?;
                require_finite(&context, "y", layer.y)?;
                require_positive(&context, "width", layer.width)?;
                require_positive(&context, "height", layer.height)?;
                require_finite(&context, "radius", layer.radius)?;
                if layer.radius < 0.0 {
                    return Err(out_of_range(format!(
                        "{context}: radius {} darf nicht negativ sein",
                        layer.radius
                    )));
                }
                validate_motion(&context, layer.motion.as_ref(), duration)
            }
            Self::Circle(layer) => {
                require_finite(&context, "x", layer.x)?;
                require_finite(&context, "y", layer.y)?;
                require_positive(&context, "radius", layer.radius)?;
                validate_motion(&context, layer.motion.as_ref(), duration)
            }
            Self::Text(layer) => {
                require_finite(&context, "x", layer.x)?;
                require_finite(&context, "y", layer.y)?;
                if !layer.size.is_finite() || !(MIN_TEXT_SIZE..=MAX_TEXT_SIZE).contains(&layer.size)
                {
                    return Err(out_of_range(format!(
                        "{context}: size {} liegt außerhalb von {MIN_TEXT_SIZE}–{MAX_TEXT_SIZE}",
                        layer.size
                    )));
                }
                validate_motion(&context, layer.motion.as_ref(), duration)
            }
            Self::Image(layer) => {
                require_finite(&context, "x", layer.x)?;
                require_finite(&context, "y", layer.y)?;
                require_positive(&context, "width", layer.width)?;
                require_positive(&context, "height", layer.height)?;
                validate_relative_path(&context, &layer.path)?;
                validate_motion(&context, layer.motion.as_ref(), duration)
            }
        }
    }
}

/// Position und Deckkraft einer Ebene zu einem Zeitpunkt.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// Linke Kante in Pixeln, inklusive Verschiebung.
    pub x: f64,
    /// Obere Kante in Pixeln, inklusive Verschiebung.
    pub y: f64,
    /// Deckkraft 0.0–1.0.
    pub opacity: f64,
}

/// Ebene mit aufgelöster Position zu einem Zeitpunkt.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample<'a> {
    /// Ebene, wie sie in der Szene steht.
    pub layer: &'a Layer,
    /// Position und Deckkraft zum abgefragten Zeitpunkt.
    pub placement: Placement,
}

/// Vollständige Szene.
///
/// `base_dir` bleibt außerhalb des JSON und wird nur von
/// [`Scene::from_path`] gesetzt; es dient dem Auflösen der Bildpfade.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    /// Formatversion; muss [`VERSION`] sein.
    pub version: u32,
    /// Breite in Pixeln.
    pub width: u32,
    /// Höhe in Pixeln.
    pub height: u32,
    /// Bilder pro Sekunde.
    pub fps: u32,
    /// Dauer in Sekunden.
    pub duration: f64,
    /// Hintergrundfarbe.
    pub background: Color,
    /// Ebenen von hinten nach vorn.
    pub layers: Vec<Layer>,
    /// Verzeichnis der Szenen-Datei; nicht Teil des JSON.
    #[serde(skip)]
    base_dir: Option<PathBuf>,
}

impl Scene {
    /// Liest eine Szene aus JSON und prüft alle Regeln.
    pub fn from_json(text: &str) -> Result<Self, SceneError> {
        let scene: Self = serde_json::from_str(text).map_err(|error| {
            SceneError::new(
                ErrorKind::InvalidJson,
                format!("Szene ist kein gültiges JSON: {error}"),
            )
        })?;
        scene.validate()?;
        Ok(scene)
    }

    /// Liest eine Szene aus einer Datei und löst Bildpfade relativ zu ihr auf.
    ///
    /// Geprüft wird auch, dass jede Bilddatei vorhanden ist.
    pub fn from_path(path: &Path) -> Result<Self, SceneError> {
        let text = std::fs::read_to_string(path).map_err(|error| {
            SceneError::new(
                ErrorKind::Io,
                format!("Szene '{}' ist nicht lesbar: {error}", path.display()),
            )
        })?;
        let mut scene = Self::from_json(&text)?;
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        for layer in &scene.layers {
            let Layer::Image(image) = layer else {
                continue;
            };
            let target = dir.join(&image.path);
            if !target.is_file() {
                return Err(SceneError::new(
                    ErrorKind::MissingImage,
                    format!(
                        "Bild '{}' fehlt relativ zum Szenen-Verzeichnis '{}'",
                        image.path,
                        dir.display()
                    ),
                ));
            }
        }
        scene.base_dir = Some(dir.to_path_buf());
        Ok(scene)
    }

    /// Prüft alle Regeln der Version 1.
    pub fn validate(&self) -> Result<(), SceneError> {
        if self.version != VERSION {
            return Err(SceneError::new(
                ErrorKind::UnsupportedVersion,
                format!(
                    "version {} wird nicht unterstützt, erwartet wird {VERSION}",
                    self.version
                ),
            ));
        }
        if !(MIN_SIZE..=MAX_SIZE).contains(&self.width) {
            return Err(out_of_range(format!(
                "width {} liegt außerhalb von {MIN_SIZE}–{MAX_SIZE}",
                self.width
            )));
        }
        if !(MIN_SIZE..=MAX_SIZE).contains(&self.height) {
            return Err(out_of_range(format!(
                "height {} liegt außerhalb von {MIN_SIZE}–{MAX_SIZE}",
                self.height
            )));
        }
        if !(MIN_FPS..=MAX_FPS).contains(&self.fps) {
            return Err(out_of_range(format!(
                "fps {} liegt außerhalb von {MIN_FPS}–{MAX_FPS}",
                self.fps
            )));
        }
        if !self.duration.is_finite() || self.duration <= 0.0 || self.duration > MAX_DURATION {
            return Err(out_of_range(format!(
                "duration {} muss > 0 und <= {MAX_DURATION} Sekunden sein",
                self.duration
            )));
        }
        if self.layers.len() > MAX_LAYERS {
            return Err(out_of_range(format!(
                "{} Ebenen überschreiten das Maximum von {MAX_LAYERS}",
                self.layers.len()
            )));
        }
        for (index, layer) in self.layers.iter().enumerate() {
            layer.validate(index, self.duration)?;
        }
        Ok(())
    }

    /// Zahl der Frames: `round(duration * fps)`.
    pub fn frame_count(&self) -> u32 {
        (self.duration * f64::from(self.fps)).round() as u32
    }

    /// Zeitpunkt eines Frames in Sekunden.
    pub fn frame_time(&self, frame: u32) -> f64 {
        f64::from(frame) / f64::from(self.fps)
    }

    /// Fortschritt 0.0–1.0 für einen Zeitpunkt; außerhalb der Dauer geklemmt.
    pub fn progress(&self, time: f64) -> f64 {
        if !time.is_finite() || self.duration <= 0.0 {
            return 0.0;
        }
        (time / self.duration).clamp(0.0, 1.0)
    }

    /// Zeitpunkt in Sekunden auf 0.0–`duration` geklemmt.
    ///
    /// Nicht-endliche Zeiten ergeben 0.0. Gleiche Szene und gleiche Zeit
    /// ergeben damit immer denselben Wert.
    pub fn clamp_time(&self, time: f64) -> f64 {
        if !time.is_finite() || self.duration <= 0.0 {
            return 0.0;
        }
        time.clamp(0.0, self.duration)
    }

    /// Verzeichnis der Szenen-Datei, sofern über [`Scene::from_path`] geladen.
    pub fn base_dir(&self) -> Option<&Path> {
        self.base_dir.as_deref()
    }

    /// Absoluter oder relativer Pfad einer Bilddatei.
    ///
    /// Ohne Basiverzeichnis bleibt der Pfad unverändert.
    pub fn resolve_image_path(&self, layer: &ImageLayer) -> PathBuf {
        match &self.base_dir {
            Some(dir) => dir.join(&layer.path),
            None => PathBuf::from(&layer.path),
        }
    }

    /// Ebene an Position `index` zum Zeitpunkt `time`.
    pub fn sample_layer(&self, index: usize, time: f64) -> Option<Sample<'_>> {
        let layer = self.layers.get(index)?;
        let time = self.clamp_time(time);
        Some(Sample {
            layer,
            placement: layer.placement_at(time, self.duration),
        })
    }

    /// Alle Ebenen zum Zeitpunkt `time`, in Zeichenreihenfolge.
    pub fn sample(&self, time: f64) -> Vec<Sample<'_>> {
        let time = self.clamp_time(time);
        self.layers
            .iter()
            .map(|layer| Sample {
                layer,
                placement: layer.placement_at(time, self.duration),
            })
            .collect()
    }
}

/// Fehler für Werte außerhalb der Grenzen.
fn out_of_range(message: impl Into<String>) -> SceneError {
    SceneError::new(ErrorKind::OutOfRange, message)
}

fn require_finite(context: &str, field: &str, value: f64) -> Result<(), SceneError> {
    if value.is_finite() {
        Ok(())
    } else {
        Err(out_of_range(format!(
            "{context}: {field} muss eine endliche Zahl sein"
        )))
    }
}

fn require_positive(context: &str, field: &str, value: f64) -> Result<(), SceneError> {
    require_finite(context, field, value)?;
    if value > 0.0 {
        Ok(())
    } else {
        Err(out_of_range(format!(
            "{context}: {field} muss größer als 0 sein, war {value}"
        )))
    }
}

/// Prüft eine Bewegung; `duration` begrenzt die Zeitpunkte der Keyframes.
///
/// Ein unbekannter Easing-Name scheitert bereits beim Deserialisieren
/// ([`ErrorKind::InvalidJson`]). Widersprüchliche oder unsortierte Keyframes
/// sind [`ErrorKind::InvalidMotion`], Zahlen außerhalb der Grenzen
/// [`ErrorKind::OutOfRange`].
fn validate_motion(
    context: &str,
    motion: Option<&Motion>,
    duration: f64,
) -> Result<(), SceneError> {
    let Some(motion) = motion else {
        return Ok(());
    };
    let linear_fields = [
        ("motion.dx", motion.dx),
        ("motion.dy", motion.dy),
        ("motion.opacity_from", motion.opacity_from),
        ("motion.opacity_to", motion.opacity_to),
    ];
    for (field, value) in linear_fields {
        if let Some(value) = value {
            require_finite(context, field, value)?;
        }
    }
    let Some(keyframes) = motion.keyframes.as_deref() else {
        return Ok(());
    };
    let linear_set = motion.dx.is_some()
        || motion.dy.is_some()
        || motion.opacity_from.is_some()
        || motion.opacity_to.is_some();
    if linear_set {
        return Err(SceneError::new(
            ErrorKind::InvalidMotion,
            format!("{context}: keyframes schließen dx/dy/opacity_from/opacity_to aus"),
        ));
    }
    if keyframes.len() > MAX_KEYFRAMES {
        return Err(out_of_range(format!(
            "{context}: {} Keyframes überschreiten das Maximum von {MAX_KEYFRAMES}",
            keyframes.len()
        )));
    }
    for (index, keyframe) in keyframes.iter().enumerate() {
        let position = format!("{context}: keyframes[{index}]");
        if !keyframe.t.is_finite() || keyframe.t < 0.0 || keyframe.t > duration {
            return Err(out_of_range(format!(
                "{position}.t {} muss zwischen 0 und {duration} Sekunden liegen",
                keyframe.t
            )));
        }
        if let Some(value) = keyframe.x {
            require_finite(&position, "x", value)?;
        }
        if let Some(value) = keyframe.y {
            require_finite(&position, "y", value)?;
        }
        if let Some(value) = keyframe.opacity {
            require_finite(&position, "opacity", value)?;
        }
        if index > 0 {
            let previous = keyframes[index - 1];
            if keyframe.t <= previous.t {
                return Err(SceneError::new(
                    ErrorKind::InvalidMotion,
                    format!(
                        "{position}.t {} muss größer als der vorherige Stützpunkt ({}) sein",
                        keyframe.t, previous.t
                    ),
                ));
            }
        }
    }
    Ok(())
}

/// Wertet Keyframes zum Zeitpunkt `time` (Sekunden) aus.
///
/// Vor dem ersten und nach dem letzten Stützpunkt gilt der jeweilige Wert;
/// dazwischen wird mit `easing` zwischen den beiden Nachbarn interpoliert.
fn sample_keyframes(
    keyframes: &[Keyframe],
    easing: Easing,
    base: (f64, f64),
    time: f64,
) -> Placement {
    let (base_x, base_y) = base;
    if keyframes.is_empty() {
        return Placement {
            x: base_x,
            y: base_y,
            opacity: 1.0,
        };
    }
    // Bei genau einem Stützpunkt greift immer einer der beiden Randfälle.
    let first = keyframes[0];
    let last = keyframes[keyframes.len() - 1];
    if time <= first.t {
        return keyframe_placement(first, base);
    }
    if time >= last.t {
        return keyframe_placement(last, base);
    }
    let mut segment = keyframes.len().saturating_sub(2);
    for (index, window) in keyframes.windows(2).enumerate() {
        if time < window[1].t {
            segment = index;
            break;
        }
    }
    let start = keyframes[segment];
    let end = keyframes[segment + 1];
    let span = end.t - start.t;
    let local = if span > 0.0 {
        ((time - start.t) / span).clamp(0.0, 1.0)
    } else {
        1.0
    };
    let weight = easing.apply(local);
    let opacity = lerp(
        start.opacity.unwrap_or(1.0),
        end.opacity.unwrap_or(1.0),
        weight,
    );
    Placement {
        x: lerp(start.x.unwrap_or(base_x), end.x.unwrap_or(base_x), weight),
        y: lerp(start.y.unwrap_or(base_y), end.y.unwrap_or(base_y), weight),
        opacity: opacity.clamp(0.0, 1.0),
    }
}

/// Position eines einzelnen Stützpunkts mit geerbten Feldern.
fn keyframe_placement(keyframe: Keyframe, base: (f64, f64)) -> Placement {
    Placement {
        x: keyframe.x.unwrap_or(base.0),
        y: keyframe.y.unwrap_or(base.1),
        opacity: keyframe.opacity.unwrap_or(1.0).clamp(0.0, 1.0),
    }
}

/// Lineare Interpolation; `weight` ist bereits geglättet.
fn lerp(from: f64, to: f64, weight: f64) -> f64 {
    from + (to - from) * weight
}

/// Prüft einen Bildpfad: relativ, ohne `..`, ohne Laufwerks- oder Wurzelteil,
/// mit einer der Endungen `.png`, `.jpg`, `.jpeg` oder `.webp`; die Endung
/// wird unabhängig von der Schreibweise akzeptiert.
fn validate_relative_path(context: &str, value: &str) -> Result<(), SceneError> {
    let path = Path::new(value);
    let safe = !value.is_empty()
        && path.is_relative()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir));
    if !safe {
        return Err(SceneError::new(
            ErrorKind::InvalidPath,
            format!("{context}: path '{value}' muss relativ sein, ohne '..', ohne Wurzelpfad"),
        ));
    }
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase);
    if extension.is_some_and(|extension| IMAGE_EXTENSIONS.contains(&extension.as_str())) {
        Ok(())
    } else {
        Err(SceneError::new(
            ErrorKind::InvalidPath,
            format!(
                "{context}: path '{value}' hat keine unterstützte Endung, \
                 erwartet wird .png, .jpg, .jpeg oder .webp"
            ),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r##"{
        "version": 1,
        "width": 1920,
        "height": 1080,
        "fps": 30,
        "duration": 10.0,
        "background": "#101218",
        "layers": [
            {"type":"rect","x":100,"y":100,"width":200,"height":80,"radius":12,"color":"#5B8DEF"},
            {"type":"circle","x":960,"y":540,"radius":80,"color":"#4FA37A"},
            {"type":"text","x":100,"y":900,"text":"Hallo","size":48,"color":"#FFFFFF"},
            {"type":"image","x":0,"y":0,"width":200,"height":200,"path":"assets/logo.png"}
        ]
    }"##;

    /// Eigenes temporäres Verzeichnis je Test; kein zusätzliches crate nötig.
    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("scene-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("Temp-Verzeichnis anlegen");
        dir
    }

    fn scene_with_layers(layers: &str) -> String {
        format!(
            r##"{{"version":1,"width":640,"height":360,"fps":30,"duration":2.0,
                "background":"#101218","layers":[{layers}]}}"##
        )
    }

    /// Szene mit abweichender Dauer; `scene_with_layers` nutzt 2.0 Sekunden.
    fn scene_with_duration(layers: &str, duration: f64) -> String {
        scene_with_layers(layers).replace("\"duration\":2.0", &format!("\"duration\":{duration}"))
    }

    /// Szene aus einer Ebene mit gegebener Dauer.
    fn parse_scene(layer: &str, duration: f64) -> Result<Scene, SceneError> {
        Scene::from_json(&scene_with_duration(layer, duration))
    }

    /// Rechteck-Ebene (10×10 bei 0/0) mit roher `motion`-Angabe als JSON.
    fn rect_with_motion(motion: &str) -> String {
        let motion: serde_json::Value = serde_json::from_str(motion).expect("motion ist JSON");
        let layer = serde_json::json!({
            "type": "rect",
            "x": 0.0,
            "y": 0.0,
            "width": 10.0,
            "height": 10.0,
            "color": "#FFFFFF",
            "motion": motion,
        });
        layer.to_string()
    }

    #[test]
    fn valid_scene_is_accepted() {
        let scene = Scene::from_json(SAMPLE).expect("Szene ist gültig");
        assert_eq!(scene.version, VERSION);
        assert_eq!((scene.width, scene.height), (1920, 1080));
        assert_eq!(scene.fps, 30);
        assert_eq!(scene.duration, 10.0);
        assert_eq!(scene.background, Color::from_rgba8(0x10, 0x12, 0x18, 255));
        assert_eq!(scene.layers.len(), 4);
        assert_eq!(scene.layers[0].kind(), LayerKind::Rect);
        assert_eq!(scene.layers[1].kind(), LayerKind::Circle);
        assert_eq!(scene.layers[2].kind(), LayerKind::Text);
        assert_eq!(scene.layers[3].kind(), LayerKind::Image);
        assert_eq!(scene.frame_count(), 300);
        assert!(scene.base_dir().is_none());
    }

    #[test]
    fn unknown_field_is_rejected() {
        let layer = r##"{"type":"circle","x":1,"y":2,"radius":3,"color":"#FFFFFF","shadow":true}"##;
        let error = Scene::from_json(&scene_with_layers(layer)).expect_err("Feld ist unbekannt");
        assert_eq!(error.kind(), ErrorKind::InvalidJson);
        assert!(error.message().contains("shadow"), "{}", error.message());

        let error = Scene::from_json(
            r##"{"version":1,"width":640,"height":360,"fps":30,"duration":2.0,
                 "background":"#101218","layers":[],"audio":"x.mp3"}"##,
        )
        .expect_err("Feld ist unbekannt");
        assert_eq!(error.kind(), ErrorKind::InvalidJson);
    }

    #[test]
    fn wrong_version_is_rejected() {
        let text = scene_with_layers("").replace("\"version\":1", "\"version\":2");
        let error = Scene::from_json(&text).expect_err("Version 2 ist nicht unterstützt");
        assert_eq!(error.kind(), ErrorKind::UnsupportedVersion);
    }

    #[test]
    fn values_out_of_range_are_rejected() {
        let too_wide = scene_with_layers("").replace("\"width\":640", "\"width\":8193");
        assert_eq!(
            Scene::from_json(&too_wide)
                .expect_err("Breite zu groß")
                .kind(),
            ErrorKind::OutOfRange
        );

        let too_long = scene_with_layers("").replace("\"duration\":2.0", "\"duration\":601.0");
        assert_eq!(
            Scene::from_json(&too_long)
                .expect_err("Dauer zu lang")
                .kind(),
            ErrorKind::OutOfRange
        );

        let slow = scene_with_layers("").replace("\"fps\":30", "\"fps\":0");
        assert_eq!(
            Scene::from_json(&slow).expect_err("fps zu klein").kind(),
            ErrorKind::OutOfRange
        );

        let large_text = r##"{"type":"text","x":0,"y":0,"text":"x","size":513,"color":"#FFFFFF"}"##;
        assert_eq!(
            Scene::from_json(&scene_with_layers(large_text))
                .expect_err("Schriftgröße zu groß")
                .kind(),
            ErrorKind::OutOfRange
        );

        let layer = r##"{"type":"circle","x":1,"y":1,"radius":1,"color":"#FFFFFF"}"##;
        let too_many = scene_with_layers(&vec![layer; MAX_LAYERS + 1].join(","));
        assert_eq!(
            Scene::from_json(&too_many)
                .expect_err("zu viele Ebenen")
                .kind(),
            ErrorKind::OutOfRange
        );
    }

    #[test]
    fn missing_image_is_rejected() {
        let dir = temp_dir("missing-image");
        let scene_path = dir.join("scene.json");
        std::fs::write(
            &scene_path,
            scene_with_layers(
                r#"{"type":"image","x":0,"y":0,"width":10,"height":10,"path":"logo.png"}"#,
            ),
        )
        .expect("Szene schreiben");

        let error = Scene::from_path(&scene_path).expect_err("Bild fehlt");
        assert_eq!(error.kind(), ErrorKind::MissingImage);
        assert!(error.message().contains("logo.png"));

        std::fs::write(dir.join("logo.png"), b"kein echtes PNG").expect("Bild anlegen");
        let scene = Scene::from_path(&scene_path).expect("Bild ist vorhanden");
        assert_eq!(scene.base_dir(), Some(dir.as_path()));
        let Layer::Image(image) = &scene.layers[0] else {
            panic!("Bild-Ebene erwartet");
        };
        assert_eq!(scene.resolve_image_path(image), dir.join("logo.png"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn image_extensions_are_case_insensitive() {
        let dir = temp_dir("image-extensions");
        let scene_path = dir.join("scene.json");
        for name in ["logo.jpg", "logo.jpeg", "logo.WEBP", "logo.PNG"] {
            std::fs::write(dir.join(name), b"Bildinhalt").expect("Bild anlegen");
            let scene_text = scene_with_layers(&format!(
                r#"{{"type":"image","x":0,"y":0,"width":10,"height":10,"path":"{name}"}}"#
            ));
            std::fs::write(&scene_path, scene_text).expect("Szene schreiben");

            let scene = Scene::from_path(&scene_path).expect("Endung ist erlaubt");
            let Layer::Image(image) = &scene.layers[0] else {
                panic!("Bild-Ebene erwartet");
            };
            assert_eq!(scene.resolve_image_path(image), dir.join(name));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unsupported_image_extension_is_rejected() {
        for path in ["logo.gif", "logo.GIF", "logo", "logo.png.bak"] {
            let layer =
                format!(r#"{{"type":"image","x":0,"y":0,"width":10,"height":10,"path":"{path}"}}"#);
            let error = Scene::from_json(&scene_with_layers(&layer))
                .expect_err("Endung ist nicht unterstützt");
            assert_eq!(error.kind(), ErrorKind::InvalidPath);
            assert!(error.message().contains(path), "{}", error.message());
        }
    }

    #[test]
    fn parent_path_is_rejected() {
        let text = scene_with_layers(
            r#"{"type":"image","x":0,"y":0,"width":10,"height":10,
                "path":"assets/../logo.png"}"#,
        );
        let error = Scene::from_json(&text).expect_err("'..' ist unerlaubt");
        assert_eq!(error.kind(), ErrorKind::InvalidPath);

        let absolute = scene_with_layers(
            r#"{"type":"image","x":0,"y":0,"width":10,"height":10,"path":"/tmp/logo.png"}"#,
        );
        assert_eq!(
            Scene::from_json(&absolute)
                .expect_err("absoluter Pfad ist unerlaubt")
                .kind(),
            ErrorKind::InvalidPath
        );
    }

    #[test]
    fn frame_count_rounds() {
        let scene = Scene::from_json(SAMPLE).expect("Szene ist gültig");
        assert_eq!(scene.frame_count(), 300);

        let text = scene_with_layers("")
            .replace("\"fps\":30", "\"fps\":24")
            .replace("\"duration\":2.0", "\"duration\":2.5");
        let scene = Scene::from_json(&text).expect("Szene ist gültig");
        assert_eq!(scene.frame_count(), 60);
        assert_eq!(scene.frame_time(24), 1.0);
    }

    #[test]
    fn motion_is_linear() {
        let text = scene_with_layers(
            r##"{"type":"rect","x":100,"y":200,"width":10,"height":10,"color":"#FFFFFF",
                "motion":{"dx":100,"dy":-50,"opacity_from":0.0,"opacity_to":1.0}}"##,
        )
        .replace("\"duration\":2.0", "\"duration\":10.0");
        let scene = Scene::from_json(&text).expect("Szene ist gültig");
        assert_eq!(scene.frame_count(), 300);

        let start = scene.sample(0.0);
        assert_eq!(start[0].placement.x, 100.0);
        assert_eq!(start[0].placement.y, 200.0);
        assert_eq!(start[0].placement.opacity, 0.0);

        let middle = scene.sample(5.0);
        assert_eq!(middle[0].placement.x, 150.0);
        assert_eq!(middle[0].placement.y, 175.0);
        assert!((middle[0].placement.opacity - 0.5).abs() < 1e-9);

        let end = scene.sample(10.0);
        assert_eq!(end[0].placement.x, 200.0);
        assert_eq!(end[0].placement.y, 150.0);
        assert_eq!(end[0].placement.opacity, 1.0);

        // Nach dem Ende bleibt der Endzustand stehen.
        let after = scene.sample(99.0);
        assert_eq!(after[0].placement.x, 200.0);
    }

    #[test]
    fn scene_without_motion_is_static() {
        let scene = Scene::from_json(SAMPLE).expect("Szene ist gültig");
        let start = scene.sample(0.0);
        let end = scene.sample(scene.duration);
        for (left, right) in start.iter().zip(&end) {
            assert_eq!(left.placement, right.placement);
            assert_eq!(left.placement.opacity, 1.0);
        }
        assert_eq!(start[0].placement.x, 100.0);
        assert_eq!(start[0].placement.y, 100.0);
    }

    #[test]
    fn motion_without_easing_behaves_like_linear() {
        let implicit_motion = r#"{
            "dx": 100,
            "dy": -50,
            "opacity_from": 0.0,
            "opacity_to": 1.0
        }"#;
        let layer = rect_with_motion(implicit_motion);
        let implicit = parse_scene(&layer, 2.0).expect("Szene ist gültig");

        let explicit_motion = r#"{
            "dx": 100,
            "dy": -50,
            "opacity_from": 0.0,
            "opacity_to": 1.0,
            "easing": "linear"
        }"#;
        let layer = rect_with_motion(explicit_motion);
        let explicit = parse_scene(&layer, 2.0).expect("Szene ist gültig");

        for time in [0.0, 0.5, 1.0, 2.0] {
            let expected = implicit.sample(time)[0].placement;
            let actual = explicit.sample(time)[0].placement;
            assert_eq!(expected, actual);
        }

        // Fehlende Felder werden beim Serialisieren weggelassen.
        let json = serde_json::to_string(&implicit).expect("serialisierbar");
        let again = Scene::from_json(&json).expect("erneut gültig");
        assert_eq!(again, implicit);
    }

    #[test]
    fn easing_survives_a_round_trip() {
        let layer = rect_with_motion(r#"{"dx": 10, "easing": "ease-out"}"#);
        let scene = parse_scene(&layer, 2.0).expect("Szene ist gültig");
        let json = serde_json::to_string(&scene).expect("serialisierbar");
        assert!(json.contains("\"easing\":\"ease-out\""), "{json}");
        let again = Scene::from_json(&json).expect("erneut gültig");
        assert_eq!(again, scene);
    }

    #[test]
    fn easing_shapes_the_curve() {
        let at_quarter = |easing: &str| {
            let motion = serde_json::json!({
                "dx": 1000.0,
                "opacity_from": 0.0,
                "opacity_to": 1.0,
                "easing": easing,
            });
            let layer = rect_with_motion(&motion.to_string());
            let scene = parse_scene(&layer, 2.0).expect("Szene ist gültig");
            let placement = scene.sample(0.5)[0].placement;
            assert_eq!(placement.y, 0.0);
            // Deckkraft und Verschiebung nutzen dasselbe Gewicht.
            assert!((placement.x - placement.opacity * 1000.0).abs() < 1e-9);
            placement.x
        };
        assert!((at_quarter("linear") - 250.0).abs() < 1e-9);
        assert!((at_quarter("ease-in") - 62.5).abs() < 1e-9);
        assert!((at_quarter("ease-out") - 437.5).abs() < 1e-9);
        assert!((at_quarter("ease-in-out") - 156.25).abs() < 1e-9);
    }

    #[test]
    fn keyframes_are_interpolated() {
        let motion = r#"{
            "keyframes": [
                {"t": 0, "x": 0, "y": 0, "opacity": 0},
                {"t": 2, "x": 200, "y": 100, "opacity": 1},
                {"t": 4, "x": 200, "y": 300}
            ]
        }"#;
        let layer = rect_with_motion(motion);
        let scene = parse_scene(&layer, 4.0).expect("Szene ist gültig");
        let at = |time: f64| scene.sample(time)[0].placement;

        let middle = at(1.0);
        assert_eq!(middle.x, 100.0);
        assert_eq!(middle.y, 50.0);
        assert_eq!(middle.opacity, 0.5);

        let second_half = at(3.0);
        assert_eq!(second_half.x, 200.0);
        assert_eq!(second_half.y, 200.0);
        assert_eq!(second_half.opacity, 1.0);

        // Genau auf einem Stützpunkt gilt dessen Wert.
        let support = at(2.0);
        assert_eq!(support.x, 200.0);
        assert_eq!(support.y, 100.0);
        assert_eq!(support.opacity, 1.0);

        // Vor dem ersten und nach dem letzten Punkt gilt der jeweilige Wert.
        let before = at(-5.0);
        assert_eq!(before.x, 0.0);
        assert_eq!(before.y, 0.0);
        assert_eq!(before.opacity, 0.0);

        let after = at(99.0);
        assert_eq!(after.x, 200.0);
        assert_eq!(after.y, 300.0);
        assert_eq!(after.opacity, 1.0);
    }

    #[test]
    fn keyframes_inherit_layer_position_and_opacity() {
        let layer = r##"{
            "type": "circle",
            "x": 50,
            "y": 60,
            "radius": 5,
            "color": "#FFFFFF",
            "motion": {
                "keyframes": [
                    {"t": 0},
                    {"t": 2, "x": 150}
                ]
            }
        }"##;
        let scene = parse_scene(layer, 2.0).expect("Szene ist gültig");

        let start = scene.sample(0.0)[0].placement;
        assert_eq!(start.x, 50.0);
        assert_eq!(start.y, 60.0);
        assert_eq!(start.opacity, 1.0);

        let middle = scene.sample(1.0)[0].placement;
        assert_eq!(middle.x, 100.0);
        assert_eq!(middle.y, 60.0);
        assert_eq!(middle.opacity, 1.0);
    }

    #[test]
    fn keyframes_use_layer_easing() {
        let motion = r#"{
            "easing": "ease-in-out",
            "keyframes": [
                {"t": 0, "x": 0},
                {"t": 2, "x": 1000}
            ]
        }"#;
        let layer = rect_with_motion(motion);
        let scene = parse_scene(&layer, 2.0).expect("Szene ist gültig");
        let placement = scene.sample(0.5)[0].placement;
        assert!((placement.x - 156.25).abs() < 1e-9, "x={}", placement.x);
        assert_eq!(placement.y, 0.0);
        assert_eq!(placement.opacity, 1.0);
    }

    #[test]
    fn empty_keyframes_keep_the_layer_static() {
        let layer = rect_with_motion(r#"{"keyframes": []}"#);
        let scene = parse_scene(&layer, 2.0).expect("Szene ist gültig");
        let placement = scene.sample(1.0)[0].placement;
        assert_eq!(placement.x, 0.0);
        assert_eq!(placement.y, 0.0);
        assert_eq!(placement.opacity, 1.0);
    }

    #[test]
    fn unknown_easing_is_rejected() {
        let layer = rect_with_motion(r#"{"dx": 10, "easing": "bounce"}"#);
        let error = parse_scene(&layer, 2.0).expect_err("Easing ist unbekannt");
        assert_eq!(error.kind(), ErrorKind::InvalidJson);
        assert!(error.message().contains("bounce"), "{}", error.message());
    }

    #[test]
    fn broken_keyframes_are_rejected() {
        let layer = rect_with_motion(r#"{"keyframes": [{"t": 1}, {"t": 0}]}"#);
        let error = parse_scene(&layer, 2.0).expect_err("unsortiert");
        assert_eq!(error.kind(), ErrorKind::InvalidMotion);

        let layer = rect_with_motion(r#"{"keyframes": [{"t": 1}, {"t": 1}]}"#);
        let error = parse_scene(&layer, 2.0).expect_err("doppelt");
        assert_eq!(error.kind(), ErrorKind::InvalidMotion);

        let layer = rect_with_motion(r#"{"keyframes": [{"t": 0}, {"t": 2.5}]}"#);
        let error = parse_scene(&layer, 2.0).expect_err("hinter dem Ende");
        assert_eq!(error.kind(), ErrorKind::OutOfRange);

        let layer = rect_with_motion(r#"{"keyframes": [{"t": -0.5}]}"#);
        let error = parse_scene(&layer, 2.0).expect_err("vor dem Anfang");
        assert_eq!(error.kind(), ErrorKind::OutOfRange);
    }

    #[test]
    fn too_many_keyframes_are_rejected() {
        let keyframes = (0..=MAX_KEYFRAMES)
            .map(|index| format!(r#"{{"t": {:0.2}}}"#, index as f64 * 0.01))
            .collect::<Vec<_>>()
            .join(",");
        let motion = format!(r#"{{"keyframes": [{keyframes}]}}"#);
        let layer = rect_with_motion(&motion);
        let error = parse_scene(&layer, 2.0).expect_err("zu viele Stützpunkte");
        assert_eq!(error.kind(), ErrorKind::OutOfRange);
    }

    #[test]
    fn keyframes_and_linear_fields_are_exclusive() {
        let conflicts = [
            r#"{"dx": 10, "keyframes": [{"t": 0, "x": 1}]}"#,
            r#"{"dy": 10, "keyframes": [{"t": 0, "x": 1}]}"#,
            r#"{"opacity_from": 0.5, "keyframes": [{"t": 0, "x": 1}]}"#,
            r#"{"opacity_to": 0.5, "keyframes": [{"t": 0, "x": 1}]}"#,
        ];
        for motion in conflicts {
            let layer = rect_with_motion(motion);
            let error = parse_scene(&layer, 2.0).expect_err("beides gesetzt");
            assert_eq!(error.kind(), ErrorKind::InvalidMotion);
        }
    }

    #[test]
    fn unknown_keyframe_field_is_rejected() {
        let layer = rect_with_motion(r#"{"keyframes": [{"t": 0, "scale": 2}]}"#);
        let error = parse_scene(&layer, 2.0).expect_err("Feld ist unbekannt");
        assert_eq!(error.kind(), ErrorKind::InvalidJson);
        assert!(error.message().contains("scale"), "{}", error.message());
    }

    #[test]
    fn sampling_is_deterministic() {
        let motion = r#"{
            "easing": "ease-out",
            "keyframes": [
                {"t": 0, "x": 0, "opacity": 0},
                {"t": 3, "x": 90, "opacity": 1}
            ]
        }"#;
        let layer = rect_with_motion(motion);
        let scene = parse_scene(&layer, 3.0).expect("Szene ist gültig");
        for time in [0.25, 1.0, 2.5] {
            let first = scene.sample(time)[0].placement;
            let second = scene.sample(time)[0].placement;
            assert_eq!(first, second);
        }
    }

    #[test]
    fn colors_are_parsed_and_written() {
        let color = Color::from_hex("#5B8DEF").expect("Farbe ist gültig");
        assert_eq!(color.to_rgba8(), (0x5B, 0x8D, 0xEF, 255));
        assert_eq!(color.to_hex(), "#5B8DEF");

        let translucent = Color::from_hex("#5B8DEF80").expect("Farbe ist gültig");
        assert_eq!(translucent.to_rgba8(), (0x5B, 0x8D, 0xEF, 0x80));
        assert_eq!(translucent.to_hex(), "#5B8DEF80");

        assert_eq!(
            Color::from_hex("#12345").expect_err("zu kurz").kind(),
            ErrorKind::InvalidColor
        );
        assert_eq!(
            Color::from_hex("5B8DEG").expect_err("kein Hex").kind(),
            ErrorKind::InvalidColor
        );
    }

    #[test]
    fn error_serializes_as_kind_and_message() {
        let error = SceneError::new(ErrorKind::MissingImage, "Bild fehlt");
        let json = serde_json::to_value(&error).expect("Fehler ist serialisierbar");
        assert_eq!(json["kind"], "missing_image");
        assert_eq!(json["message"], "Bild fehlt");
    }
}
