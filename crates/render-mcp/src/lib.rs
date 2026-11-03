//! `render-mcp`: 2D-Rendering über Vello und wgpu (Metal auf dem Mac).
//!
//! Der Server hält einen GPU-Kontext warm und rendert pro Aufruf in eine
//! Textur, liest sie zurück und kodiert PNG. In dieser Ausbaustufe gibt es
//! eine feste Demo-Szene; SVG- und Textpfade folgen.

use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use base64::Engine as _;
use rmcp::{
    ErrorData as McpError, ServerHandler, ServiceExt,
    handler::server::wrapper::Parameters,
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    tool, tool_handler, tool_router,
    transport::stdio,
};
use schemars::JsonSchema;
use serde::Deserialize;
use tokio::sync::Mutex;
use vello::{
    AaConfig, RenderParams, Renderer, RendererOptions, Scene,
    kurbo::{Affine, Circle, Rect, RoundedRect, Stroke},
    peniko::{self, Color, Fill},
    wgpu,
};

/// Kleinste erlaubte Kantenlänge.
pub const MIN_SIZE: u32 = 16;

/// Größte erlaubte Kantenlänge.
pub const MAX_SIZE: u32 = 8192;

/// GPU-Kontext für 2D-Rendering.
pub struct Renderer2d {
    device: wgpu::Device,
    queue: wgpu::Queue,
    renderer: Renderer,
}

impl Renderer2d {
    /// Eröffnet Adapter, Device und Vello-Renderer (Metal auf dem Mac).
    pub fn new() -> Result<Self, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            ..Default::default()
        }))
        .map_err(|error| format!("kein GPU-Adapter: {error}"))?;

        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
                .map_err(|error| format!("kein GPU-Device: {error}"))?;
        let renderer = Renderer::new(&device, RendererOptions::default())
            .map_err(|error| format!("Vello-Renderer: {error}"))?;

        Ok(Self {
            device,
            queue,
            renderer,
        })
    }

    /// Rendert die Szene und gibt RGBA8 zurück.
    pub fn render(&mut self, scene: &Scene, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("mac-compute-render"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let params = RenderParams {
            base_color: Color::from_rgb8(0x10, 0x12, 0x18),
            width,
            height,
            antialiasing_method: AaConfig::Area,
        };

        self.renderer
            .render_to_texture(&self.device, &self.queue, scene, &view, &params)
            .map_err(|error| format!("Rendern fehlgeschlagen: {error}"))?;

        let unpadded = width * 4;
        let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let padded = unpadded.div_ceil(align) * align;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("mac-compute-readback"),
            size: u64::from(padded) * u64::from(height),
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("mac-compute-copy"),
            });
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([encoder.finish()]);

        let slice = buffer.slice(..);
        let (sender, receiver) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device
            .poll(wgpu::PollType::Wait {
                submission_index: None,
                timeout: None,
            })
            .map_err(|error| format!("GPU-Poll: {error}"))?;
        receiver
            .recv()
            .map_err(|_| "Mapping-Kanal geschlossen".to_string())?
            .map_err(|error| format!("Mapping: {error}"))?;

        let mapped = slice.get_mapped_range();
        let mut rgba = Vec::with_capacity((unpadded as usize) * height as usize);
        for row in 0..height as usize {
            let start = row * padded as usize;
            rgba.extend_from_slice(&mapped[start..start + unpadded as usize]);
        }
        drop(mapped);
        buffer.unmap();

        Ok(rgba)
    }
}

/// Baut die Systemschrift-Datenbank für SVG-Text.
fn svg_options() -> resvg::usvg::Options<'static> {
    let mut options = resvg::usvg::Options::default();
    options.fontdb_mut().load_system_fonts();
    options
}

/// Rastert SVG mit resvg/usvg. `foreignObject` wird bewusst abgelehnt,
/// weil usvg den HTML-Inhalt nicht rendert; dafür ist WebKit nötig.
pub fn render_svg_png(
    svg: &str,
    width: Option<u32>,
    height: Option<u32>,
) -> Result<(Vec<u8>, u32, u32), String> {
    if svg.contains("foreignObject") {
        return Err(
            "foreignObject wird von resvg/usvg nicht unterstützt; SVG ohne foreignObject \
             verwenden oder sips/WebKit als Fallback nehmen"
                .to_string(),
        );
    }
    let tree = resvg::usvg::Tree::from_str(svg, &svg_options())
        .map_err(|error| format!("SVG nicht lesbar: {error}"))?;
    let size = tree.size();
    let (target_w, target_h) = fit(size.width(), size.height(), width, height);
    if !(MIN_SIZE..=MAX_SIZE).contains(&target_w) || !(MIN_SIZE..=MAX_SIZE).contains(&target_h) {
        return Err(format!(
            "Zielgröße {target_w}×{target_h} liegt außerhalb von {MIN_SIZE}–{MAX_SIZE}"
        ));
    }

    let mut pixmap = resvg::tiny_skia::Pixmap::new(target_w, target_h)
        .ok_or_else(|| "PNG-Pixmap konnte nicht angelegt werden".to_string())?;
    let scale_x = target_w as f32 / size.width();
    let scale_y = target_h as f32 / size.height();
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale_x, scale_y),
        &mut pixmap.as_mut(),
    );
    let png = pixmap
        .encode_png()
        .map_err(|error| format!("PNG-Daten: {error}"))?;
    Ok((png, target_w, target_h))
}

/// Zielgröße aus SVG-Größe und optionalen Kantenlängen; Seitenverhältnis bleibt.
fn fit(intrinsic_w: f32, intrinsic_h: f32, width: Option<u32>, height: Option<u32>) -> (u32, u32) {
    let base_w = if intrinsic_w > 0.0 {
        intrinsic_w
    } else {
        100.0
    };
    let base_h = if intrinsic_h > 0.0 {
        intrinsic_h
    } else {
        100.0
    };
    match (width, height) {
        (Some(w), Some(h)) => (w, h),
        (Some(w), None) => (
            w,
            (f64::from(w) * f64::from(base_h) / f64::from(base_w)).round() as u32,
        ),
        (None, Some(h)) => (
            (f64::from(h) * f64::from(base_w) / f64::from(base_h)).round() as u32,
            h,
        ),
        (None, None) => (base_w.round() as u32, base_h.round() as u32),
    }
}

/// Demo-Szene: Hintergrund, drei Kreise und ein gerahmtes Rechteck.
pub fn demo_scene(width: u32, height: u32) -> Scene {
    let w = f64::from(width);
    let h = f64::from(height);
    let mut scene = Scene::new();

    scene.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Color::from_rgb8(0x1b, 0x1d, 0x24),
        None,
        &Rect::new(0.0, 0.0, w, h),
    );

    let radius = (w.min(h) / 6.0).max(8.0);
    let dots = [
        (0.30, 0.38, Color::from_rgb8(0x5b, 0x8d, 0xef)),
        (0.50, 0.55, Color::from_rgb8(0x4f, 0xa3, 0x7a)),
        (0.70, 0.42, Color::from_rgb8(0xd9, 0xa4, 0x41)),
    ];
    for (x, y, color) in dots {
        scene.fill(
            Fill::NonZero,
            Affine::IDENTITY,
            color,
            None,
            &Circle::new((w * x, h * y), radius),
        );
    }

    let frame = RoundedRect::from_rect(Rect::new(w * 0.10, h * 0.12, w * 0.90, h * 0.88), 24.0);
    scene.stroke(
        &Stroke::new(3.0),
        Affine::IDENTITY,
        Color::from_rgb8(0x8a, 0x94, 0xa6),
        None,
        &frame,
    );

    scene
}

/// Kodiert RGBA8 als PNG.
pub fn encode_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder
            .write_header()
            .map_err(|error| format!("PNG-Kopf: {error}"))?;
        writer
            .write_image_data(rgba)
            .map_err(|error| format!("PNG-Daten: {error}"))?;
    }
    Ok(out)
}

/// Größte Kantenlänge einer Zwischenrasterung (Text, Bild) in Pixeln.
const MAX_RASTER_EDGE: f64 = 16_384.0;

/// Gebündelte Schrift für Text-Ebenen; liegt im Repo unter `assets/fonts/`.
///
/// Der Pfad ist bewusst relativ zum Crate-Verzeichnis und wird zur Laufzeit
/// gelesen, damit eine fehlende Datei erkannt und gemeldet werden kann.
const BUNDLED_FONT: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../assets/fonts/PT_Sans-Web-Regular.ttf"
);

/// Familienname der gebündelten Schrift.
const BUNDLED_FONT_FAMILY: &str = "PT Sans";

thread_local! {
    /// Schriften je Thread nur einmal laden: Lesen und Parsen der Schriftdatei
    /// ist teuer und würde sonst bei jedem Frame einer Textszene erneut laufen.
    static TEXT_OPTIONS: std::cell::RefCell<Option<resvg::usvg::Options<'static>>> =
        const { std::cell::RefCell::new(None) };
}

/// Baut eine Vello-Szene aus einer Szene (Version 1) zum Zeitpunkt `time`.
///
/// Hintergrund und Ebenen werden in Dateireihenfolge gezeichnet; Verschiebung
/// und Deckkraft kommen aus [`scene::Scene::sample`] (linear oder Keyframes,
/// optional mit Easing). Die Funktion ist rein: gleiche Szene und gleiche Zeit
/// ergeben dieselbe Vello-Szene und damit dieselben PNG-Bytes.
pub fn render_scene_frame(spec: &scene::Scene, time: f64) -> Result<Scene, String> {
    let mut target = Scene::new();
    let (red, green, blue, alpha) = spec.background.to_rgba8();
    let area = Rect::new(0.0, 0.0, f64::from(spec.width), f64::from(spec.height));
    target.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Color::from_rgba8(red, green, blue, alpha),
        None,
        &area,
    );

    for sample in spec.sample(time) {
        draw_scene_layer(&mut target, spec, sample.layer, sample.placement)?;
    }

    Ok(target)
}

/// Zeichnet eine Ebene mit aufgelöster Position und Deckkraft.
fn draw_scene_layer(
    target: &mut Scene,
    spec: &scene::Scene,
    layer: &scene::Layer,
    placement: scene::Placement,
) -> Result<(), String> {
    match layer {
        scene::Layer::Rect(rect) => {
            let brush = brush_color(rect.color, placement.opacity);
            let area = Rect::new(
                placement.x,
                placement.y,
                placement.x + rect.width,
                placement.y + rect.height,
            );
            if rect.radius > 0.0 {
                let rounded = RoundedRect::from_rect(area, rect.radius);
                target.fill(Fill::NonZero, Affine::IDENTITY, brush, None, &rounded);
            } else {
                target.fill(Fill::NonZero, Affine::IDENTITY, brush, None, &area);
            }
            Ok(())
        }
        scene::Layer::Circle(circle) => {
            let brush = brush_color(circle.color, placement.opacity);
            let shape = Circle::new((placement.x, placement.y), circle.radius);
            target.fill(Fill::NonZero, Affine::IDENTITY, brush, None, &shape);
            Ok(())
        }
        scene::Layer::Text(text) => {
            // Vello bräuchte Glyph-Indizes und Schriftdaten; der Umweg über
            // eine kleine SVG-Seite hält die Abhängigkeiten bei resvg.
            let (image, x, y) = rasterize_text(text, placement)?;
            let brush = peniko::ImageBrush::new(image).with_alpha(placement.opacity as f32);
            target.draw_image(&brush, Affine::translate((x, y)));
            Ok(())
        }
        scene::Layer::Image(image) => {
            let path = spec.resolve_image_path(image);
            let data = load_image(&path)?;
            let scale_x = image.width / f64::from(data.width);
            let scale_y = image.height / f64::from(data.height);
            let transform = Affine::new([scale_x, 0.0, 0.0, scale_y, placement.x, placement.y]);
            let brush = peniko::ImageBrush::new(data).with_alpha(placement.opacity as f32);
            target.draw_image(&brush, transform);
            Ok(())
        }
    }
}

/// Farbe mit angepasster Deckkraft; Vello erwartet Alpha zwischen 0 und 255.
fn brush_color(color: scene::Color, opacity: f64) -> Color {
    let (red, green, blue, alpha) = color.to_rgba8();
    let alpha = (f64::from(alpha) * opacity).round().clamp(0.0, 255.0) as u8;
    Color::from_rgba8(red, green, blue, alpha)
}

/// Rastert eine Textzeile über resvg und liefert Bild und linke obere Ecke.
///
/// Gerastert wird mit der gebündelten Schrift [`BUNDLED_FONT`], damit derselbe
/// Text auf jedem Rechner dieselben Bytes ergibt. `x` ist der linke Rand, `y`
/// die Grundlinie (Baseline); die Rasterung ist entsprechend nach oben versetzt.
fn rasterize_text(
    layer: &scene::TextLayer,
    placement: scene::Placement,
) -> Result<(peniko::ImageData, f64, f64), String> {
    let size = layer.size;
    let glyphs = layer.text.chars().count().max(1) as f64;
    let padding = size * 0.25;
    let width = (glyphs * size * 0.75 + size).ceil();
    let height = (size * 1.4).ceil();
    if !(1.0..=MAX_RASTER_EDGE).contains(&width) || !(1.0..=MAX_RASTER_EDGE).contains(&height) {
        return Err(format!(
            "Text ist mit size {size} zu groß zum Rastern ({width}×{height} Pixel)"
        ));
    }
    let (red, green, blue, alpha) = layer.color.to_rgba8();
    let baseline = padding + size;
    let svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\">\
         <text x=\"0\" y=\"{baseline}\" font-family=\"PT Sans, sans-serif\" \
         font-size=\"{size}\" fill=\"#{red:02X}{green:02X}{blue:02X}\" \
         fill-opacity=\"{}\">{}</text></svg>",
        f64::from(alpha) / 255.0,
        escape_xml(&layer.text),
    );

    let tree = with_text_options(|options| resvg::usvg::Tree::from_str(&svg, options))
        .map_err(|error| format!("Text ist nicht rasterbar: {error}"))?;
    let pixel_width = width as u32;
    let pixel_height = height as u32;
    let mut pixmap = resvg::tiny_skia::Pixmap::new(pixel_width, pixel_height)
        .ok_or_else(|| "Text-Pixmap konnte nicht angelegt werden".to_string())?;
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::identity(),
        &mut pixmap.as_mut(),
    );

    let image = peniko::ImageData {
        data: peniko::Blob::from(pixmap.data().to_vec()),
        format: peniko::ImageFormat::Rgba8,
        // tiny-skia arbeitet mit vormultipliziertem Alpha.
        alpha_type: peniko::ImageAlphaType::AlphaPremultiplied,
        width: pixel_width,
        height: pixel_height,
    };
    Ok((image, placement.x, placement.y - baseline))
}

/// Führt `use_options` mit der zwischengespeicherten Schriften-Datenbank aus.
fn with_text_options<T>(use_options: impl FnOnce(&resvg::usvg::Options<'static>) -> T) -> T {
    TEXT_OPTIONS.with(|slot| {
        let mut slot = slot.borrow_mut();
        let options = slot.get_or_insert_with(text_options);
        use_options(options)
    })
}

/// Baut die Schriften-Optionen mit der gebündelten Schrift.
fn text_options() -> resvg::usvg::Options<'static> {
    text_options_with(Path::new(BUNDLED_FONT))
}

/// Baut Schriften-Optionen; fehlt `font`, gelten die Systemschriften.
///
/// Die gebündelte Schrift macht Text-Rasterungen unabhängig von den auf dem
/// Rechner installierten Schriften. Fehlt die Datei oder enthält sie keinen
/// Schriftschnitt, wird einmal je Thread auf stderr gewarnt und auf
/// `load_system_fonts` zurückgefallen; abgebrochen wird nicht.
fn text_options_with(font: &Path) -> resvg::usvg::Options<'static> {
    let mut options = resvg::usvg::Options::default();
    // fontdb übergeht kaputte Schriftdaten ohne Fehler; dann bleibt die
    // Datenbank leer und der Rückfall auf die Systemschriften greift.
    let usable = match std::fs::read(font) {
        Ok(data) => {
            options.fontdb_mut().load_font_data(data);
            !options.fontdb.is_empty()
        }
        Err(_) => false,
    };
    if usable {
        options.font_family = BUNDLED_FONT_FAMILY.to_string();
        options
            .fontdb_mut()
            .set_sans_serif_family(BUNDLED_FONT_FAMILY);
    } else {
        eprintln!(
            "render-mcp: gebündelte Schrift '{}' fehlt oder ist unlesbar; \
             es werden die Systemschriften verwendet",
            font.display()
        );
        options.fontdb_mut().load_system_fonts();
    }
    options
}

/// Maskiert Zeichen, die in SVG-Text eine Rolle spielen.
fn escape_xml(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            other => out.push(other),
        }
    }
    out
}

/// Liest ein Bild (PNG, JPEG, WebP) und liefert RGBA8.
///
/// `image` wandelt dabei 16-Bit- und Graustufenbilder sowie Paletten nach
/// RGBA8; Alpha wird anschließend vormultipliziert. Das Format wird am Inhalt
/// erkannt, nicht an der Endung.
fn load_image(path: &Path) -> Result<peniko::ImageData, String> {
    let decoded = image::ImageReader::open(path)
        .map_err(|error| format!("Bild '{}' ist nicht lesbar: {error}", path.display()))?
        .with_guessed_format()
        .map_err(|error| format!("Bild '{}': Format nicht erkennbar: {error}", path.display()))?
        .decode()
        .map_err(|error| match error {
            image::ImageError::Unsupported(_) => format!(
                "Bild '{}': Format wird nicht unterstützt ({error})",
                path.display()
            ),
            error => format!("Bild '{}' ist nicht dekodierbar: {error}", path.display()),
        })?;
    let width = decoded.width();
    let height = decoded.height();
    let mut rgba = decoded.into_rgba8().into_raw();

    // Vello erwartet vormultipliziertes Alpha; PNG/JPEG/WebP speichern es gerade.
    for pixel in rgba.as_chunks_mut::<4>().0 {
        let alpha = u32::from(pixel[3]);
        for channel in &mut pixel[..3] {
            *channel = ((u32::from(*channel) * alpha + 127) / 255) as u8;
        }
    }

    Ok(peniko::ImageData {
        data: peniko::Blob::from(rgba),
        format: peniko::ImageFormat::Rgba8,
        alpha_type: peniko::ImageAlphaType::AlphaPremultiplied,
        width,
        height,
    })
}

/// Argumente für `render_png`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct RenderArgs {
    /// Breite in Pixeln (16–8192).
    #[schemars(range(min = 16, max = 8192))]
    pub width: u32,

    /// Höhe in Pixeln (16–8192).
    #[schemars(range(min = 16, max = 8192))]
    pub height: u32,
}

/// Argumente für `render_svg`.
#[derive(Debug, Deserialize, JsonSchema)]
pub struct SvgArgs {
    /// SVG-Quelltext (max. 1 MB).
    #[schemars(length(max = 1_000_000))]
    pub svg: String,

    /// Zielbreite in Pixeln (16–8192); ohne Höhe bleibt das Seitenverhältnis.
    #[schemars(range(min = 16, max = 8192))]
    pub width: Option<u32>,

    /// Zielhöhe in Pixeln (16–8192); ohne Breite bleibt das Seitenverhältnis.
    #[schemars(range(min = 16, max = 8192))]
    pub height: Option<u32>,
}

/// MCP-Server für 2D-Rendering.
#[derive(Clone)]
pub struct RenderServer {
    renderer: Arc<Mutex<Renderer2d>>,
}

impl RenderServer {
    /// Erzeugt den Server mit warmem GPU-Kontext.
    pub fn new(renderer: Renderer2d) -> Self {
        Self {
            renderer: Arc::new(Mutex::new(renderer)),
        }
    }
}

#[tool_router]
impl RenderServer {
    #[tool(description = "Rastert SVG über resvg/usvg als PNG")]
    async fn svg(
        &self,
        Parameters(SvgArgs { svg, width, height }): Parameters<SvgArgs>,
    ) -> Result<CallToolResult, McpError> {
        if svg.len() > 1_000_000 {
            return Err(McpError::invalid_params("svg ist größer als 1 MB", None));
        }
        let started = Instant::now();
        let (png, target_w, target_h) = match render_svg_png(&svg, width, height) {
            Ok(result) => result,
            Err(error) => {
                return Ok(CallToolResult::error(vec![ContentBlock::text(error)]));
            }
        };
        let elapsed = started.elapsed();
        let data = base64::engine::general_purpose::STANDARD.encode(&png);

        Ok(CallToolResult::success(vec![
            ContentBlock::image(data, "image/png"),
            ContentBlock::text(format!(
                "{target_w}×{target_h} in {:.1} ms, {} Bytes PNG",
                elapsed.as_secs_f64() * 1000.0,
                png.len()
            )),
        ]))
    }

    #[tool(description = "Rendert eine Demo-Szene über Vello/wgpu (Metal) als PNG")]
    async fn png(
        &self,
        Parameters(RenderArgs { width, height }): Parameters<RenderArgs>,
    ) -> Result<CallToolResult, McpError> {
        if !(MIN_SIZE..=MAX_SIZE).contains(&width) || !(MIN_SIZE..=MAX_SIZE).contains(&height) {
            return Err(McpError::invalid_params(
                format!("width und height müssen zwischen {MIN_SIZE} und {MAX_SIZE} liegen"),
                None,
            ));
        }

        let started = Instant::now();
        let scene = demo_scene(width, height);
        let rgba = {
            let mut renderer = self.renderer.lock().await;
            renderer
                .render(&scene, width, height)
                .map_err(|error| McpError::internal_error(error, None))?
        };
        let png = encode_png(&rgba, width, height)
            .map_err(|error| McpError::internal_error(error, None))?;
        let elapsed = started.elapsed();
        let data = base64::engine::general_purpose::STANDARD.encode(&png);

        Ok(CallToolResult::success(vec![
            ContentBlock::image(data, "image/png"),
            ContentBlock::text(format!(
                "{width}×{height} in {:.1} ms, {} Bytes PNG",
                elapsed.as_secs_f64() * 1000.0,
                png.len()
            )),
        ]))
    }
}

#[tool_handler]
impl ServerHandler for RenderServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("render-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions("Rendert 2D-Szenen über Vello und wgpu (Metal).")
    }
}

/// Bedient das Backend über stdio.
pub async fn run_stdio(renderer: Renderer2d) -> Result<(), Box<dyn std::error::Error>> {
    let service = RenderServer::new(renderer).serve(stdio()).await?;
    service.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;
    use std::path::{Path, PathBuf};

    use image::{DynamicImage, ImageFormat};
    use vello::peniko;

    use super::*;

    /// Eigenes temporäres Verzeichnis je Test; kein zusätzliches crate nötig.
    fn temp_dir(name: &str) -> PathBuf {
        let name = format!("render-mcp-test-{}-{name}", std::process::id());
        let dir = std::env::temp_dir().join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("Temp-Verzeichnis anlegen");
        dir
    }

    /// Schreibt `source` im Format `format` unter dem Namen `name` und liefert
    /// den Pfad; das Verzeichnis wird von [`cleanup`] wieder entfernt.
    fn write_image(name: &str, source: DynamicImage, format: ImageFormat) -> PathBuf {
        let path = temp_dir(name).join(name);
        let mut buffer = Cursor::new(Vec::new());
        source.write_to(&mut buffer, format).expect("Bild kodieren");
        std::fs::write(&path, buffer.into_inner()).expect("Bild schreiben");
        path
    }

    /// Entfernt das Temp-Verzeichnis eines Testbilds.
    fn cleanup(path: &Path) {
        if let Some(dir) = path.parent() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }

    /// Textzeile mit lateinischen Buchstaben, die PT Sans sicher enthält.
    fn text_layer() -> scene::TextLayer {
        scene::TextLayer {
            x: 0.0,
            y: 0.0,
            text: "Hallo Welt".to_string(),
            size: 32.0,
            color: scene::Color::from_rgba8(0xFF, 0xFF, 0xFF, 0xFF),
            motion: None,
        }
    }

    fn placement() -> scene::Placement {
        scene::Placement {
            x: 10.0,
            y: 40.0,
            opacity: 1.0,
        }
    }

    #[test]
    fn bundled_font_is_loaded() {
        let font = Path::new(BUNDLED_FONT);
        assert!(font.is_file(), "Schrift fehlt: {}", font.display());

        let options = text_options();
        assert_eq!(options.font_family, BUNDLED_FONT_FAMILY);
        assert!(!options.fontdb.is_empty());
    }

    #[test]
    fn missing_font_falls_back_to_system_fonts() {
        let options = text_options_with(Path::new("/nicht/vorhanden/PT_Sans.ttf"));
        assert_ne!(options.font_family, BUNDLED_FONT_FAMILY);
    }

    #[test]
    fn text_raster_is_byte_identical_on_two_runs() {
        let first = rasterize_text(&text_layer(), placement()).expect("erste Rasterung");
        // Zwischenspeicher leeren: der zweite Lauf liest die Schrift erneut ein.
        TEXT_OPTIONS.with(|slot| *slot.borrow_mut() = None);
        let second = rasterize_text(&text_layer(), placement()).expect("zweite Rasterung");

        assert_eq!(first.0.width, second.0.width);
        assert_eq!(first.0.height, second.0.height);
        assert_eq!((first.1, first.2), (second.1, second.2));
        let pixels = first.0.data.data();
        assert_eq!(pixels, second.0.data.data());
        assert!(
            pixels.as_chunks::<4>().0.iter().any(|pixel| pixel[3] > 0),
            "Rasterung enthält keine sichtbaren Pixel"
        );
    }

    #[test]
    fn load_image_decodes_png_to_premultiplied_rgba8() {
        let source = image::RgbaImage::from_pixel(1, 1, image::Rgba([200, 100, 50, 128]));
        let path = write_image(
            "logo.png",
            DynamicImage::ImageRgba8(source),
            ImageFormat::Png,
        );

        let loaded = load_image(&path).expect("PNG dekodiert");
        assert!(matches!(loaded.format, peniko::ImageFormat::Rgba8));
        assert!(matches!(
            loaded.alpha_type,
            peniko::ImageAlphaType::AlphaPremultiplied
        ));
        assert_eq!((loaded.width, loaded.height), (1, 1));
        // Gerades Alpha 128 wird vormultipliziert: (Kanal · 128 + 127) / 255.
        assert_eq!(loaded.data.data(), [100u8, 50, 25, 128].as_slice());
        cleanup(&path);
    }

    #[test]
    fn load_image_decodes_jpeg_to_rgba8() {
        let source = image::RgbImage::from_pixel(2, 3, image::Rgb([32, 96, 160]));
        let path = write_image(
            "logo.jpg",
            DynamicImage::ImageRgb8(source),
            ImageFormat::Jpeg,
        );

        let loaded = load_image(&path).expect("JPEG dekodiert");
        assert!(matches!(loaded.format, peniko::ImageFormat::Rgba8));
        assert_eq!((loaded.width, loaded.height), (2, 3));
        assert_eq!(loaded.data.data().len(), 2 * 3 * 4);
        for pixel in loaded.data.data().as_chunks::<4>().0 {
            assert_eq!(pixel[3], 255);
            for (decoded, expected) in pixel[..3].iter().zip([32u8, 96, 160]) {
                assert!(
                    decoded.abs_diff(expected) <= 12,
                    "JPEG-Farbe {decoded} weicht von {expected} ab"
                );
            }
        }
        cleanup(&path);
    }

    #[test]
    fn load_image_converts_16_bit_and_grayscale_to_rgba8() {
        let wide: image::ImageBuffer<image::Rgba<u16>, Vec<u16>> =
            image::ImageBuffer::from_pixel(1, 1, image::Rgba([u16::MAX, 0, 32_768, u16::MAX]));
        let path = write_image(
            "logo16.png",
            DynamicImage::ImageRgba16(wide),
            ImageFormat::Png,
        );

        let loaded = load_image(&path).expect("16-Bit-PNG dekodiert");
        assert_eq!((loaded.width, loaded.height), (1, 1));
        let pixel = &loaded.data.data()[..4];
        assert_eq!(pixel[0], 255);
        assert_eq!(pixel[1], 0);
        assert!(pixel[2].abs_diff(128) <= 1, "16-Bit-Anteil: {}", pixel[2]);
        assert_eq!(pixel[3], 255);
        cleanup(&path);

        let gray = image::GrayImage::from_pixel(2, 2, image::Luma([64u8]));
        let path = write_image(
            "logo-gray.png",
            DynamicImage::ImageLuma8(gray),
            ImageFormat::Png,
        );
        let loaded = load_image(&path).expect("Graustufen-PNG dekodiert");
        assert_eq!((loaded.width, loaded.height), (2, 2));
        for pixel in loaded.data.data().as_chunks::<4>().0 {
            assert_eq!(pixel, [64u8, 64, 64, 255].as_slice());
        }
        cleanup(&path);
    }

    #[test]
    fn load_image_rejects_unsupported_formats() {
        let dir = temp_dir("gif");
        let path = dir.join("logo.gif");
        std::fs::write(&path, b"GIF89a\x01\x00\x01\x00\x00\x00\x00;").expect("GIF schreiben");

        let error = load_image(&path).expect_err("GIF wird nicht unterstützt");
        assert!(error.contains("Format wird nicht unterstützt"), "{error}");
        assert!(error.contains("logo.gif"), "{error}");
        cleanup(&path);
    }
}
