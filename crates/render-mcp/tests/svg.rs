//! Prüft SVG-Rasterung über resvg/usvg.

use render_mcp::render_svg_png;

const RECT: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
  <rect width="100" height="50" fill="#5B8DEF"/>
</svg>"##;

const TEXT: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="80">
  <rect width="200" height="80" fill="#101218"/>
  <text x="12" y="48" font-family="Helvetica" font-size="28" fill="#F5F5F7">Hallo Welt</text>
</svg>"##;

fn render(svg: &str, width: Option<u32>, height: Option<u32>) -> (Vec<u8>, u32, u32) {
    render_svg_png(svg, width, height).expect("SVG ist gültig")
}

#[test]
fn renders_svg_with_aspect_ratio() {
    let (png, width, height) = render(RECT, Some(200), None);
    assert_eq!((width, height), (200, 100));
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
}

#[test]
fn renders_svg_text() {
    let (png, width, height) = render(TEXT, None, None);
    assert_eq!((width, height), (200, 80));
    assert!(png.len() > 500);
}

#[test]
fn rejects_broken_svg() {
    assert!(render_svg_png("<svg", None, None).is_err());
}

#[test]
fn rejects_foreign_object() {
    let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><foreignObject width="100" height="50"><div xmlns="http://www.w3.org/1999/xhtml">Text</div></foreignObject></svg>"#;
    let error = render_svg_png(svg, None, None).expect_err("foreignObject wird abgelehnt");
    assert!(error.contains("foreignObject"));
}
