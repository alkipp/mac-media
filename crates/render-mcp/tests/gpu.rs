//! Prüft den GPU-Renderpfad auf dem Mac.

use render_mcp::{Renderer2d, demo_scene, encode_png};

#[test]
fn renders_a_png() {
    let mut renderer = Renderer2d::new().expect("GPU-Kontext");
    let scene = demo_scene(64, 64);
    let rgba = renderer.render(&scene, 64, 64).expect("Rendern");
    assert_eq!(rgba.len(), 64 * 64 * 4);

    let png = encode_png(&rgba, 64, 64).expect("PNG");
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
}
