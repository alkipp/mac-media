//! Misst Render- und PNG-Zeit für die Zielgrößen.
//!
//! Aufruf: `cargo run --release -p render-mcp --example bench`

use std::time::Instant;

use render_mcp::{Renderer2d, demo_scene, encode_png};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut renderer = Renderer2d::new()?;

    for (width, height) in [(1254, 775), (3840, 2160)] {
        let scene = demo_scene(width, height);
        // Aufwärmen: Shader und Puffer sind nach dem ersten Lauf bereit.
        let _ = renderer.render(&scene, width, height)?;

        let started = Instant::now();
        let rgba = renderer.render(&scene, width, height)?;
        let render = started.elapsed();

        let started = Instant::now();
        let png = encode_png(&rgba, width, height)?;
        let encode = started.elapsed();

        println!(
            "{width}×{height}: Render {:.1} ms, PNG {:.1} ms, {} Bytes",
            render.as_secs_f64() * 1000.0,
            encode.as_secs_f64() * 1000.0,
            png.len()
        );
    }

    Ok(())
}
