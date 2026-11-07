# Changelog

All notable changes to this repository. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer 2.0.0](https://semver.org/lang/de/).

`VERSION` is the version of the repository; backend versions live separately in
the `servers.d` manifests and in the Swift binaries.

This repository is the public export of a private project. The full development
history stays in the private repository; the version number is carried over so
both trees stay comparable.

## [0.14.0] - 2026-11-07

### Added

- **`scripts/gateway-call.py`**: calls any tool of the running gateway from the
  shell (`--list`, JSON arguments inline or via `--file`, `--json` for the raw
  result). The Streamable-HTTP handshake and the SSE parsing live in one file
  instead of being rewritten per call.

### Fixed

- **`ml_ocr` ignored the EXIF orientation.** A portrait photo was recognised
  sideways and every box from `format=json` sat in the rotated raster. Images
  are now loaded through `CGImageSourceCreateThumbnailAtIndex` with the
  transform option; covered by `OcrOrientationTests`.
- **The quality gate could pass with zero Swift tests.** `swift test` exits 0
  when no XCTest suite runs. `scripts/check.sh` now counts the executed tests
  and fails on zero.

## [0.13.0] - 2026-11-07

### Added

- **`ml_analyze`**: describes an image and its detail, combining the local
  Vision detectors (scene labels, salient objects, rectangles, text, barcodes,
  animals, people, faces, aesthetics, lens smudge) with the on-device language
  model of macOS 27. `region` zooms into a normalised crop, `question` asks one
  question about it, `detail=objects` labels every salient box in a second pass.
- Image facts come from the file: display size after EXIF orientation, camera,
  lens, capture time and location.

### Notes

- Measurements on a 12 MP photo: full frame 3.9–4.9 s, a 28 % logo crop 3.7 s,
  `detail=objects` about one second per labelled box.
- A brand read from a logo stays a claim; a rigid output schema made the model
  invent details, so the layout is requested in the prompt and parsed
  afterwards.
- Text the model claims but the OCR pass does not find is reported as a warning.

## [0.12.6] - 2026-11-03

### Added

- First public export: gateway with discovery, namespacing, hot reload,
  supervision and a SQLite job queue; backends `render-mcp`, `ml-mcp`,
  `media-mcp`, `video-mcp`, `photo`, `gen` and `llm-mcp`.

### Changed for publication

- Example scenes no longer contain a real network: host names replaced with
  `node-a`/`node-b`/`node-c`, the network explainer scene removed.
- The optional local SDXL checkpoint is described generically; its directory is
  `~/models/gen/sdxl-local/`.
- Internal documentation references removed.

### Not included

- The private network explainer scene and the narration script.
- Backend-specific README files, which describe a particular machine.
