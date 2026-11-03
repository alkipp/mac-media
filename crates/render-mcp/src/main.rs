//! Startet `render-mcp` als MCP-Server oder rendert eine Szene als Frames.
//!
//! Modus 1 (ohne Argumente): stdio-MCP wie bisher, mit warmem GPU-Kontext.
//! Modus 2 (`--scene …`): Szene validieren und Frames schreiben, damit
//! `video-mcp` daraus ein Video bauen kann.
//!
//! Zwei Senken stehen zur Wahl:
//!
//! ```text
//! render-mcp --scene szene.json --frames-dir /tmp/frames [--frames 300]
//! render-mcp --scene szene.json --sink shm --shm frames.bin --slots 4
//! ```
//!
//! Der PNG-Weg schreibt `frame-0000.png` … Der Ring-Puffer schreibt rohe
//! BGRA-Frames in eine vorab angelegte Datei; `video-mcp` liest sie ohne
//! PNG-Dekodierung. Ein Byte auf stdin gibt jeweils einen belegten Platz frei,
//! damit der Renderer höchstens `slots` Frames vorausläuft.

use std::fs;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

use render_mcp::{Renderer2d, encode_png, render_scene_frame};
use serde::Serialize;

/// Ziel der gerenderten Frames.
enum Sink {
    /// Ein PNG je Frame im angegebenen Verzeichnis.
    Png { dir: PathBuf },
    /// Ein Ring-Puffer mit rohen BGRA-Frames in einer gemeinsamen Datei.
    Shared { path: PathBuf, slots: usize },
}

/// Argumente des Frame-Modus.
struct FrameOptions {
    scene: PathBuf,
    sink: Sink,
    frames: Option<u32>,
}

/// Fehler der Kommandozeile; wird als `{kind, message}` auf stderr gemeldet.
struct CliError {
    kind: &'static str,
    message: String,
}

impl CliError {
    fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

/// Zusammenfassung am Ende eines Frame-Laufs, eine JSON-Zeile auf stdout.
#[derive(Serialize)]
struct FrameReport {
    scene: String,
    frames: u32,
    width: u32,
    height: u32,
    fps: u32,
    duration: f64,
    dir: String,
}

fn main() {
    if let Err(error) = run() {
        let line = serde_json::json!({ "kind": error.kind, "message": error.message });
        eprintln!("{line}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), CliError> {
    // Das Gateway startet das Backend mit `--stdio`; der Schalter bleibt
    // zulässig und ändert nichts am stdio-Betrieb.
    let args: Vec<String> = std::env::args()
        .skip(1)
        .filter(|argument| argument != "--stdio")
        .collect();

    if args
        .iter()
        .any(|argument| argument == "--help" || argument == "-h")
    {
        print_help();
        return Ok(());
    }
    if args.is_empty() {
        return run_stdio();
    }
    run_frames(parse_args(&args)?)
}

/// Standardbetrieb: MCP über stdio.
fn run_stdio() -> Result<(), CliError> {
    // GPU-Kontext vor der Tokio-Laufzeit aufbauen: Der Adapter-Handshake
    // blockiert und soll keinen Runtime-Worker belegen.
    let renderer = Renderer2d::new().map_err(|error| CliError::new("render", error))?;
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|error| CliError::new("runtime", error.to_string()))?;
    runtime
        .block_on(render_mcp::run_stdio(renderer))
        .map_err(|error| CliError::new("stdio", error.to_string()))
}

fn print_help() {
    println!(
        "render-mcp – 2D-Rendering und Szenen-Frames\n\n\
         Aufruf:\n  \
         render-mcp                                     MCP über stdio\n  \
         render-mcp --scene <datei> --frames-dir <dir>  Frames als PNG\n  \
         render-mcp --scene <datei> --sink shm --shm <datei>  Frames als BGRA im Ring\n\n\
         Optionen:\n  \
         --scene <datei>      Szenen-JSON (Version 1)\n  \
         --frames-dir <dir>   Zielverzeichnis für frame-0000.png, frame-0001.png, …\n  \
         --sink <art>         png (Default) oder shm\n  \
         --shm <datei>        Ring-Datei für --sink shm (Größe slots × Framegröße)\n  \
         --slots <n>          Plätze im Ring (Default 4, 1–32)\n  \
         --frames <n>         Zahl der Frames (Default: round(duration * fps))\n  \
         --help               diese Hilfe"
    );
}

fn parse_args(args: &[String]) -> Result<FrameOptions, CliError> {
    let mut scene = None;
    let mut frames_dir = None;
    let mut frames = None;
    let mut sink_name: Option<String> = None;
    let mut shm = None;
    let mut slots: usize = 4;

    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--scene" => scene = Some(PathBuf::from(next_value(args, index)?)),
            "--frames-dir" => frames_dir = Some(PathBuf::from(next_value(args, index)?)),
            "--sink" => sink_name = Some(next_value(args, index)?.to_string()),
            "--shm" => shm = Some(PathBuf::from(next_value(args, index)?)),
            "--slots" => {
                let value = next_value(args, index)?;
                let count: usize = value.parse().map_err(|_| {
                    CliError::new(
                        "usage",
                        format!("--slots erwartet eine Zahl, bekommen: {value}"),
                    )
                })?;
                if !(1..=32).contains(&count) {
                    return Err(CliError::new("usage", "--slots liegt außerhalb von 1…32"));
                }
                slots = count;
            }
            "--frames" => {
                let value = next_value(args, index)?;
                let count: u32 = value.parse().map_err(|_| {
                    CliError::new(
                        "usage",
                        format!("--frames erwartet eine Zahl, bekommen: {value}"),
                    )
                })?;
                if count == 0 {
                    return Err(CliError::new("usage", "--frames muss größer als 0 sein"));
                }
                frames = Some(count);
            }
            other => {
                return Err(CliError::new(
                    "usage",
                    format!("unbekannte Option '{other}'"),
                ));
            }
        }
        index += 2;
    }

    let scene = scene.ok_or_else(|| CliError::new("usage", "--scene fehlt"))?;
    let sink = match sink_name.as_deref().unwrap_or("png") {
        "png" => Sink::Png {
            dir: frames_dir.ok_or_else(|| CliError::new("usage", "--frames-dir fehlt"))?,
        },
        "shm" => {
            if frames_dir.is_some() {
                return Err(CliError::new(
                    "usage",
                    "--frames-dir gilt nur für --sink png",
                ));
            }
            Sink::Shared {
                path: shm.ok_or_else(|| CliError::new("usage", "--shm fehlt"))?,
                slots,
            }
        }
        other => {
            return Err(CliError::new(
                "usage",
                format!("unbekannte Senke '{other}' (erwartet png oder shm)"),
            ));
        }
    };

    Ok(FrameOptions {
        scene,
        sink,
        frames,
    })
}

fn next_value(args: &[String], index: usize) -> Result<&str, CliError> {
    args.get(index + 1)
        .map(String::as_str)
        .ok_or_else(|| CliError::new("usage", format!("{} braucht einen Wert", args[index])))
}

/// Rendert die Szene in die gewählte Senke und meldet das Ergebnis als JSON.
fn run_frames(options: FrameOptions) -> Result<(), CliError> {
    let spec = scene::Scene::from_path(&options.scene)
        .map_err(|error| CliError::new(error.kind_str(), error.message().to_string()))?;

    // Ohne --frames zählt die Szenendauer; mindestens ein Frame, damit jede
    // gültige Szene ein Bild ergibt.
    let total = match options.frames {
        Some(frames) => frames,
        None => spec.frame_count().max(1),
    };

    match &options.sink {
        Sink::Png { dir } => run_frames_png(&options.scene, dir, &spec, total),
        Sink::Shared { path, slots } => run_frames_shared(path, *slots, &spec, total),
    }
}

/// Rendert die Szene als PNG-Frames und meldet das Ergebnis als JSON.
fn run_frames_png(
    scene_path: &Path,
    frames_dir: &Path,
    spec: &scene::Scene,
    total: u32,
) -> Result<(), CliError> {
    fs::create_dir_all(frames_dir).map_err(|error| {
        CliError::new(
            "io",
            format!(
                "Frame-Verzeichnis '{}' ist nicht anlegbar: {error}",
                frames_dir.display()
            ),
        )
    })?;

    let mut renderer = Renderer2d::new().map_err(|error| CliError::new("render", error))?;
    let digits = digits_for(total);

    for index in 0..total {
        let rgba = render_frame(&mut renderer, spec, index)?;
        let png = encode_png(&rgba, spec.width, spec.height)
            .map_err(|error| CliError::new("render", error))?;
        let path = frames_dir.join(format!("frame-{index:0digits$}.png"));
        fs::write(&path, png).map_err(|error| {
            CliError::new(
                "io",
                format!("Frame '{}' ist nicht schreibbar: {error}", path.display()),
            )
        })?;
    }

    let report = FrameReport {
        scene: scene_path.display().to_string(),
        frames: total,
        width: spec.width,
        height: spec.height,
        fps: spec.fps,
        duration: spec.duration,
        dir: frames_dir.display().to_string(),
    };
    let line =
        serde_json::to_string(&report).map_err(|error| CliError::new("json", error.to_string()))?;
    println!("{line}");
    Ok(())
}

/// Kopfzeile des Ring-Puffers, einmal vor dem ersten Frame auf stdout.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamHeader {
    kind: &'static str,
    frames: u32,
    width: u32,
    height: u32,
    fps: u32,
    duration: f64,
    pixel_format: &'static str,
    row_bytes: usize,
    frame_bytes: usize,
    slots: usize,
}

/// Meldung je geschriebenem Frame; die Zeile ist zugleich die Freigabe für
/// `video-mcp`, den Platz auszulesen.
#[derive(Serialize)]
struct FrameLine {
    kind: &'static str,
    index: u32,
}

/// Schreibt rohe BGRA-Frames in einen vorab angelegten Ring-Puffer.
///
/// Die Datei legt `video-mcp` an (Größe `slots × Framegröße`); hier wird nur
/// hineingeschrieben. Vor jedem Frame ab dem zweiten Durchlauf wartet der
/// Renderer auf ein Freigabebyte auf stdin, damit er höchstens `slots` Frames
/// vorausläuft und der Speicher begrenzt bleibt.
fn run_frames_shared(
    path: &Path,
    slots: usize,
    spec: &scene::Scene,
    total: u32,
) -> Result<(), CliError> {
    let frame_bytes = usize::try_from(spec.width)
        .ok()
        .and_then(|width| {
            usize::try_from(spec.height)
                .ok()
                .map(|height| width * 4 * height)
        })
        .ok_or_else(|| CliError::new("usage", "Szene ist zu groß für den Ring-Puffer"))?;
    let expected = (frame_bytes as u64)
        .checked_mul(slots as u64)
        .ok_or_else(|| CliError::new("usage", "Ring-Größe läuft über"))?;

    let file = File::options()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| {
            CliError::new(
                "io",
                format!("Ring-Datei '{}' ist nicht offen: {error}", path.display()),
            )
        })?;
    let length = file
        .metadata()
        .map_err(|error| CliError::new("io", format!("Ring-Datei nicht lesbar: {error}")))?
        .len();
    if length != expected {
        return Err(CliError::new(
            "io",
            format!(
                "Ring-Datei hat {length} Byte, erwartet werden {expected} \
                 ({slots} Plätze × {frame_bytes} Byte)"
            ),
        ));
    }

    let mut renderer = Renderer2d::new().map_err(|error| CliError::new("render", error))?;
    let stdout = io::stdout();
    let mut out = stdout.lock();

    let header = StreamHeader {
        kind: "frames",
        frames: total,
        width: spec.width,
        height: spec.height,
        fps: spec.fps,
        duration: spec.duration,
        pixel_format: "bgra8",
        row_bytes: frame_bytes / usize::try_from(spec.height).unwrap_or(1).max(1),
        frame_bytes,
        slots,
    };
    write_line(&mut out, &header)?;

    let mut stdin = io::stdin();
    for index in 0..total {
        let slot = index as usize % slots;
        if index as usize >= slots {
            let mut permit = [0u8; 1];
            if stdin.read_exact(&mut permit).is_err() {
                return Err(CliError::new(
                    "io",
                    "Encoder hat den Lauf beendet, bevor alle Frames gelesen waren",
                ));
            }
        }

        let mut pixels = render_frame(&mut renderer, spec, index)?;
        // Vello liefert RGBA8; der Encoder erwartet BGRA im Speicher.
        rgba_to_bgra(&mut pixels);
        file.write_all_at(&pixels, (slot as u64) * (frame_bytes as u64))
            .map_err(|error| CliError::new("io", format!("Frame ist nicht schreibbar: {error}")))?;
        write_line(
            &mut out,
            &FrameLine {
                kind: "frame",
                index,
            },
        )?;
    }
    Ok(())
}

/// Rendert einen Frame und prüft die Puffergröße.
fn render_frame(
    renderer: &mut Renderer2d,
    spec: &scene::Scene,
    index: u32,
) -> Result<Vec<u8>, CliError> {
    let time = spec.frame_time(index);
    let vello_scene =
        render_scene_frame(spec, time).map_err(|error| CliError::new("render", error))?;
    let rgba = renderer
        .render(&vello_scene, spec.width, spec.height)
        .map_err(|error| CliError::new("render", error))?;
    let expected = (spec.width as usize) * 4 * (spec.height as usize);
    if rgba.len() != expected {
        return Err(CliError::new(
            "render",
            format!("Frame hat {} Byte, erwartet werden {expected}", rgba.len()),
        ));
    }
    Ok(rgba)
}

/// Tauscht Rot und Blau; Alpha bleibt an Position 3.
fn rgba_to_bgra(pixels: &mut [u8]) {
    for pixel in pixels.as_chunks_mut::<4>().0 {
        pixel.swap(0, 2);
    }
}

/// Eine JSON-Zeile auf stdout; der Flush ist Pflicht, weil `video-mcp` Zeile
/// für Zeile mitliest.
fn write_line<T: Serialize>(out: &mut impl Write, value: &T) -> Result<(), CliError> {
    let line = serde_json::to_string(value)
        .map_err(|error| CliError::new("json", format!("JSON nicht baubar: {error}")))?;
    writeln!(out, "{line}")
        .and_then(|()| out.flush())
        .map_err(|error| {
            CliError::new(
                "io",
                format!("stdout ist nicht schreibbar: {error} (liest der Encoder noch?)"),
            )
        })
}

/// Frame-Nummern sind mindestens vierstellig und wachsen mit der Zahl der
/// Frames (ab 10000 fünfstellig), damit keine Namen kollidieren.
fn digits_for(total: u32) -> usize {
    total.to_string().len().max(4)
}

#[cfg(test)]
mod tests {
    use super::rgba_to_bgra;

    #[test]
    fn tauscht_rot_und_blau_und_laesst_alpha_stehen() {
        let mut pixels = [1, 2, 3, 4, 250, 251, 252, 253];
        rgba_to_bgra(&mut pixels);
        assert_eq!(pixels, [3, 2, 1, 4, 252, 251, 250, 253]);
    }

    #[test]
    fn laesst_unvollstaendige_pixel_unberuehrt() {
        // Kein vollständiges Pixel am Ende: der Rest bleibt, wie er ist.
        let mut pixels = [9, 8, 7, 6, 5];
        rgba_to_bgra(&mut pixels);
        assert_eq!(pixels, [7, 8, 9, 6, 5]);
    }
}
