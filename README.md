# mac-media

*Native Mac resources behind one MCP endpoint: GPU/Metal, ANE, CPU and the
media engines.*

> **Naming:** the project is `mac-media`. Internal identifiers still say
> `mac-compute` — the gateway binary `mac-compute-gateway`, the launch-agent
> label `de.kippar.mac-compute-gateway` and `~/Library/Application Support/mac-compute/`.
> Renaming those moves state, token, venvs and models, so it is a separate
> migration rather than a find-and-replace.

OpenCode talks to exactly one MCP server. Behind it sits a gateway that starts
and supervises several native backend processes and exposes their tools under a
single namespace. New backends are added as a manifest in `servers.d/` — no
change to the OpenCode configuration.

**Status:** gateway with discovery, namespacing, `capabilities`, reload,
supervision and a job queue (SQLite). `render-mcp` renders through Vello/wgpu
(Metal) to PNG, single or as a frame series from a JSON scene. `ml-mcp` reports
CoreML devices and classifies images via Vision. `media-mcp` uses VideoToolbox
for probe, thumbnails and transcoding. `video-mcp` renders 2D and 3D scenes with
optional effects to H.264/HEVC/ProRes via AVAssetWriter and SceneKit; 2D frames
travel through a ring buffer instead of PNG files. `llm-mcp` generates text via
llama.cpp with Metal. `mock-mcp` is the test backend.

## Architecture

```text
OpenCode
  └─ mac-compute (gateway, Streamable HTTP, 127.0.0.1:8787/mcp)
       ├─ job queue   SQLite   jobs.sqlite
       ├─ render-mcp  Rust    Vello + wgpu       → GPU/Metal
       ├─ ml-mcp      Swift   CoreML             → ANE/GPU/CPU
       ├─ media-mcp   Swift   VideoToolbox       → media engines
       ├─ video-mcp   Swift   AVFoundation       → video
       └─ llm-mcp     Rust    llama.cpp (Metal)  → GPU/unified memory
```

The gateway is the only network endpoint. It binds to `127.0.0.1` only,
requires a bearer token, and forwards `tools/list` and `tools/call` to the
responsible backend. If a backend dies, the gateway stays reachable and reports
just that backend as `down`.

## Repository layout

```text
mac-media/
├── Cargo.toml              Rust workspace
├── assets/fonts/           PT Sans (OFL) for deterministic text
├── crates/
│   ├── mcp-core/           manifests, validation, shared types
│   ├── jobs/               job queue (SQLite)
│   ├── gateway/            mac-compute-gateway
│   ├── scene/              scene format v1: validation, sampling, errors
│   ├── mock-mcp/           test backend (echo, sleep)
│   ├── render-mcp/         Vello + wgpu, PNG and frame series
│   └── llm-mcp/            llama.cpp with Metal
├── swift/
│   ├── Package.swift       Swift package (macOS 15+)
│   ├── Sources/MLMCP/      ml-mcp: CoreML + Vision
│   ├── Sources/MediaMCP/   media-mcp: VideoToolbox
│   └── Sources/VideoMCP/   video-mcp: AVFoundation
├── backends/
│   ├── photo/              Python MCP: depth, SAM, BiRefNet, ESRGAN, Whisper
│   └── gen/                Python MCP: FLUX.2 Klein (mflux), PaddleOCR-VL
├── config/
│   ├── manifest.schema.json
│   ├── scene.schema.json   scene format v1
│   ├── scenes/             example scenes
│   └── servers.d/          example manifests
└── scripts/
    ├── 3d-video.sh         acceptance run for the 3D scene
    ├── 4k-video.sh         acceptance run for 4K30
    ├── bench-ocr.sh        measure text recognition runtime (ml_ocr)
    ├── blender-clean.py    clean a photogrammetry mesh headless in Blender
    ├── check.sh            quality gate
    ├── codec-video.sh      acceptance run for audio, HEVC, ProRes
    ├── golden-video.sh     acceptance run: frames → MP4
    ├── gateway-call.py     call any gateway tool from the shell
    ├── install-mac.sh      install/update on the Mac
    ├── rotate-token.sh     token rotation with a grace period
    └── sign-mac.sh         sign and notarise (Developer ID)
```

Integration tests live in `crates/*/tests/`.

## Installing on the Mac

```sh
./scripts/install-mac.sh --dry-run   # show what would happen
./scripts/install-mac.sh             # add missing pieces
./scripts/install-mac.sh --build     # rebuild binaries
```

The script is idempotent and creates:

| Path | Content |
|---|---|
| `~/Library/Application Support/mac-compute/bin/` | binaries (gateway, render, LLM, ML, media) |
| `~/Library/Application Support/mac-compute/servers.d/` | manifests (`0600`, paths resolved) |
| `~/Library/Application Support/mac-compute/state/` | queue (`jobs.sqlite`) and MCP sessions (`sessions/`) |
| `~/.config/mac-compute/token` | bearer token (`0600`, 32 bytes hex) |
| `~/Library/LaunchAgents/de.kippar.mac-compute-gateway.plist` | launch agent |
| `~/Library/Logs/mac-compute/` | `gateway.log`, `gateway.err.log`, JSONL |

Missing binaries are built (`cargo build --release`, `swift build -c release`);
existing manifests and tokens are kept. `--update-manifests` overwrites the
manifests, `--no-restart` leaves the launch agent alone. At the end the script
checks `/health` with the token.

A wrapper installer can call this script; pass `--no-gateway` to skip it.

## Calling tools from the shell

`scripts/gateway-call.py` is the client for the running gateway: one call, no
session handshake by hand. It reads the token from `~/.config/mac-compute/token`
and never prints it.

```sh
./scripts/gateway-call.py --list                       # all 41 tool names
./scripts/gateway-call.py ml_info                      # any tool, empty arguments
./scripts/gateway-call.py ml_analyze '{"path":"foto.heic","detail":"objects"}'
./scripts/gateway-call.py ml_analyze --file auftrag.json
./scripts/gateway-call.py --json ml_analyze '{"path":"foto.heic"}'   # raw result
```

It exists because the same client was written five times in one session — twice
in bash with `curl`, three times in Python — every time for a single call. The
Streamable-HTTP handshake (SSE response, `mcp-session-id` from the `initialize`
header) and the JSON parsing now live in one place.

## Manifest

A backend is described by a JSON file under `config/servers.d/`. Installed they
live in `~/Library/Application Support/mac-compute/servers.d/` with mode
`0600`. Schema: `config/manifest.schema.json`.

Checked-in manifests contain no machine paths: `@APP_SUPPORT@` stands for
`~/Library/Application Support/mac-compute`, `@HOME@` for the home directory.
The gateway expands them on load, and `install-mac.sh` on install — a clone
works on any Mac without editing text.

```json
{
  "name": "media",
  "version": "0.1.0",
  "transport": "stdio",
  "command": [
    "@APP_SUPPORT@/bin/media-mcp",
    "--stdio"
  ],
  "capabilities": ["videotoolbox", "h264", "hevc", "thumbnail", "hardware-encode"],
  "timeout": 600000,
  "maxMemoryMB": 4096,
  "enabled": true
}
```

| Field | Required | Default | Rule |
|---|---|---|---|
| `name` | yes | – | 1–32 chars, `a-z`, `0-9`, `-`, starts with a letter |
| `version` | no | – | 1–32 chars, starts with a digit |
| `transport` | yes | – | `stdio` |
| `command` | yes | – | array; `command[0]` absolute path; no empty arguments |
| `capabilities` | yes | – | 1–32 chars, `a-z`, `0-9`, `-`, no duplicates |
| `timeout` | no | `600000` | 1000–86400000 ms |
| `maxMemoryMB` | no | `4096` | 64–65536 MiB |
| `enabled` | no | `true` | `false` keeps it configured but stopped |

Unknown fields are rejected. The name determines the tool namespace:
`render` → `render_svg`; OpenCode puts the server name in front
(`mac-compute_render_svg`).

Regenerate the schema when the types change:

```sh
cargo run -p mcp-core --example manifest_schema > config/manifest.schema.json
```

## Discovery and tools

On start the gateway reads `servers.d/*.json` in alphabetical order, validates
every manifest and starts only enabled backends as stdio child processes.
Invalid manifests and duplicate names are skipped; a backend that fails appears
as `down` while the gateway stays reachable.

Tools appear as `<name>_<tool>` (for example `mock_echo`). Three gateway tools
come on top: `capabilities` (status, limits, errors and tool list per backend),
`metrics` (uptime, job counters including mean duration, backends, restarts,
limits, gateway RSS) and `workers` (local worker with id, host, slots and
counters). Both return plain text lines without secrets.

A file watcher notices changes in `servers.d/`; after 300 ms of debouncing the
gateway reloads the registry and sends `tools/list_changed`. The gateway
announces `tools.listChanged` in `initialize` — without it, MCP clients never
register a handler and keep their stale tool list until the session reconnects.
A supervisor checks every two seconds whether a backend closed its transport and
restarts it with up to three attempts (1 s, 2 s, 4 s backoff). A timeout marks
the backend `down`; the gateway remains reachable.

## Jobs

*Long renders run as a job with id, progress and cancellation.*

`submit_job` accepts a backend call and answers immediately; a worker executes
it. These three tools belong to the gateway, not to a backend, and therefore
carry no namespace:

| Tool | Input | Output |
|---|---|---|
| `submit_job` | `tool` (namespaced), optional `arguments`, `priority` 0–9 | `job_id`, `state`, `queue_position` |
| `job_status` | `job_id` | `job` with `state`, `progress`, `result` or `error`, plus `queue_position` |
| `job_cancel` | `job_id` | `state`, `changed` |

States: `queued` → `rendering` → optional `encoding` and `muxing` → `done`.
Failures end in `failed`, cancellation in `cancelled`. `rendering` is the generic
"running" state until a backend reports a finer phase. An error is
`{"kind": "timeout", "message": "…"}`; `kind` is `invalid_request`,
`backend_unavailable`, `timeout`, `cancelled`, `interrupted` or `internal`.

The queue lives in `<state_dir>/jobs.sqlite`; without `--state-dir` that is
`.../mac-compute/state/`. Waiting jobs survive a gateway restart; whatever was
running is marked `failed` with `kind: interrupted`.

| Limit | Flag | Default | Effect |
|---|---|---|---|
| `maxQueue` | `--max-queue` | 64 | waiting jobs in total |
| `maxQueuePerBackend` | `--max-queue-per-backend` | 32 | waiting jobs per backend |
| `maxConcurrent` | `--max-concurrent` | 1 | jobs running at once |
| `maxPerBackend` | `--max-per-backend` | 1 | jobs running at once per backend |

With no free slot, `submit_job` answers `invalid_params` instead of queueing
silently. Selection is by priority (higher first), then by age; when a job's
backend is busy, the next one runs. No backend can hog GPU, memory or the queue.
Cancelling a running job terminates the backend, because a hanging call would
otherwise run until the manifest timeout; the supervisor restarts it afterwards.
`capabilities` reports counters and limits under `queue`.

## Render

`render-mcp` keeps a Vello/wgpu context (Metal) warm. `render_png` returns a
demo scene as a PNG block, `render_svg` converts SVG with usvg into a Vello
scene and renders it through wgpu/Metal (`vello_svg`); system fonts are loaded.
Vello is pinned to 0.10 because `vello_svg` 0.11 builds on it. Measured on the
Mac: 1254 × 775 in 2.9 ms, 3840 × 2160 in 10.6 ms (render time, without PNG
encoding).

## ML

`ml-mcp` (Swift) reports the Metal device and CoreML compute devices, classifies
PNG images, reads text from images and PDFs via Vision, and describes what an
image shows with the on-device model of macOS 27.

| Tool | Input | Output |
|---|---|---|
| `ml_info` | – | Metal device, `cpu`/`gpu`/`neuralEngine`, Vision and OCR languages |
| `ml_classify` | PNG as base64 (max 8 MiB), `max_results` 1–10 | image size, duration, labels with confidence |
| `ml_ane_probe` | – | layers of the probe model with the assigned compute device |
| `ml_models` | optional `refresh` | models in the model directory with version, author and compute devices (60 s cache) |
| `ml_ocr` | `path` under `/inbox` (image or PDF), `pages`, `languages`, `level`, `dpi`, `format`, `write` | text, `## page n` markers, optionally JSON with lines, boxes and confidence |
| `ml_analyze` | `path` under `/inbox` (HEIC, JPEG, PNG, TIFF), `region`, `question`, `detail`, `language`, `vision`, `format`, `write` | image facts, scene labels, boxes with confidence, text, quality, and a narrative description |

### `ml_analyze`

Two engines, because neither is exact alone. **Vision** runs local detectors on
ANE/GPU (scene labels, salient objects, rectangles, text, barcodes, animals,
people, faces, aesthetics, lens smudge) — fast and measurable, but it only names
broad categories. The **on-device language model** of macOS 27 reads the image as
an attachment and describes objects, positions and details in words — it
understands context, but it invents brands when a logo is too small. The tool
keeps the parts apart: boxes and confidences are measurements, the narrative is
an interpretation, and every text claim the model makes is compared against the
Vision result.

```text
ml_analyze(path="/inbox/photo.heic")
ml_analyze(path="/inbox/photo.heic", detail="objects")          # name each box
ml_analyze(path="/inbox/photo.heic", region={x:0.28,y:0.28,width:0.28,height:0.24},
           question="Which brand does the logo show?")
```

Measured on the Mac (iPhone 16 Pro photo, 3024 × 4032, portrait):

| Run | Duration | Result |
|---|---|---|
| full frame, `detail=brief` | 2.6 s (cold start 7.4 s) | "a router by Ubiquiti" |
| full frame, `detail=normal` | 3.9–4.9 s | summary plus 2–3 objects with position and detail |
| `detail=objects` | 5.9 s + 1 s per labelled box | salient object becomes "Ubiquiti PoE switch" |
| `region` on the logo, 28 % × 24 % | 3.7 s | "brand Ubiquiti, logo is a curve" |

| Detector | 2048 px | Note |
|---|---|---|
| classify | 70 ms | Apple's scene model: `cord 0.78`, `machine 0.15` |
| saliency | 21 ms | one box around the device, 73 % |
| rectangles | 8 ms | sub-parts: logo plate, socket |
| text | 77 ms | nothing on a photo without lettering |
| animals / people / faces | 14–27 ms | each loads its own model on first use (4.7 s cold) |
| aesthetics / smudge | 10 / 16 ms | 0.33 and 0.00 for the sample photo |

**Orientation is applied first.** `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceCreateThumbnailWithTransform` returns display pixels; a plain
decode returns the stored buffer, which for an iPhone portrait photo is rotated
90°. Without that step every box describes a sideways image — `sips` writes the
stored 4032 × 3024 and hides the problem. Guarded by
`OrientationTests.testGedrehtesFotoWirdAufgerichtet`.

**Detail comes from the crop, not from a bigger prompt.** The model downsamples
internally; a 12 MP photo arrives as roughly 1 500 × 2 000 pixels and a logo
three centimetres wide carries no letters. `region` takes normalized fractions
with a top-left origin (the values printed under "Erkannte Flächen"), so the
agent can zoom in on the interesting part and ask again.

Limits, measured 2026-11-07:

- **Brands from a logo are unreliable.** The full frame named the right brand
  ("Ubiquiti"), a 26 % crop of the same logo produced "brand D, type U". Use a
  crop plus a question, and treat a brand as a claim, not a fact.
- **A rigid output schema invites invention.** The same image produced "power
  supply with a red button and a light-bulb logo" through `@Generable`, while a
  free answer named the correct device. The fixed layout is therefore requested
  in the prompt and parsed afterwards (`parseNarrative`), not enforced by a
  schema.
- **Text claims are checked.** The model read "u" and "2" on a picture without
  any lettering. Every entry of its `Text:` line that the Vision pass does not
  find appears as a note ("Modell nennt Text, den die Texterkennung nicht
  liest …").
- **Small crops are not objects.** `detail=objects` labels only boxes of at least
  3 % area from saliency, animals, people and faces; a 4 % × 4 % crop of a power
  strip was labelled "graffiti spray can by POG". Rectangles stay unnamed.
- **Embossed lettering is lost on both paths.** At the device edge of a 12 MP
  photo sits "12VDC" — about 60 px wide, embossed and upside down. The model
  answered "3.5 mm jack" and "TESSERAC"; Vision found nothing, even after a 4×
  upscale. Anything below roughly 10 % of the image width needs a macro shot,
  not a better prompt.
- **The narrative needs macOS 27** (`FoundationModels`, `Attachment<ImageContent>`).
  Without it the tool still returns every Vision measurement and a note. The
  Swift package therefore builds against macOS 26 as the floor.


### `ml_ocr`

Vision reads text without loading weights (ANE/GPU); no model files are loaded.
A PDF page with a text layer is read directly (29 ms measured); only pages
without text are rendered at `dpi` (default 200) and recognised. Pages run four
in parallel.

Measured on the Mac, a 17-page A4 scan at 200 dpi and `level=accurate`:
**4.1 s total, 241 ms per page**, 555 ms of pure recognition per OCR page.
`level=fast` was not faster on this scan (575 ms); the lever is parallelism, not
the mode. Single pages land at 0.35–0.58 s. For comparison: `gen_ocr`
(PaddleOCR-VL) loads a ~2 GB model on every call and needed more than 300 s for
one page.

```text
ml_ocr(path="/inbox/scan.pdf", pages="1-17", write=True, format="text")
```

Re-measure with `scripts/bench-ocr.sh <file-under-inbox> [pages]`; the script
prints client time and the duration reported by the tool for each mode.

Images are loaded through `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceCreateThumbnailWithTransform`, so EXIF orientation is applied
before recognition. Without it a portrait phone photo is recognised sideways and
every box from `format=json` sits in the rotated raster. Guarded by
`OcrOrientationTests.testGedrehtesFotoWirdGelesen`.

Limits: `ml_ocr` returns text in reading order, but **no table structure, no
formulas and no handwriting** — `gen_ocr` handles those. On numbers and IBANs
the language correction can distort characters (`0`/`O`, `.`/`:`); then set
`language_correction=false` and support proper nouns with `custom_words`.
`force_ocr=true` bypasses a broken PDF text layer.

Lines are sorted by text-line clustering (tolerance: half a line height), so
two-column pages and slightly skewed scans keep their reading order.

`ml_ane_probe` loads `models/ane_probe.mlmodel`, runs it with
`computeUnits = .cpuAndNeuralEngine` and then reads the `MLComputePlan`. The
probe model (three convolutions, 3→32→32→32) is produced by
`swift/scripts/make_ane_probe.py`; all four layers are assigned to the
**Neural Engine**. The script needs `coremltools` in a virtualenv and is not
part of the gate.

Apple's own model from `VNClassifyImageRequest` picks its compute device by
itself; per-layer proof only works with a model of your own, like the probe.

## Media

`media-mcp` (Swift) uses VideoToolbox and AVFoundation. Inputs live only under
`.../mac-compute/inbox/`, outputs under `.../artifacts/<uuid>/`.

| Tool | Purpose |
|---|---|
| `media_info` | VideoToolbox encoders and hardware flags |
| `media_probe` | duration, resolution, frame rate, codec, audio tracks |
| `media_thumbnail` | PNG at `at_seconds` (integer or decimal), width 16–4096 |
| `media_transcode` | MP4 export (H.264/HEVC) with SHA-256 |
| `media_encode` | H.264 test video via `VTCompressionSession`, hardware forced |

`media_encode` queries
`kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` after the run
and reports the result (`hardware: true`). VideoToolbox also lists H.264, HEVC
and ProRes as hardware encoders; which encoder an `AVAssetExportSession` picks
stays invisible.

`media_thumbnail` reports path, size and dimensions plus the mean brightness of
the frame (`luma`) and the timestamp actually read (`pts`). Both are checked by
`scripts/media-thumbnail-check.sh`; it deliberately sends the timestamp as an
integer, because exactly that was silently read as 0 until 0.11.1 and every
preview was the black first frame.

## Video

`video-mcp` (Swift) renders a JSON scene to H.264 MP4. The frames are produced
by `render-mcp` as a subprocess on the GPU, AVAssetWriter encodes with hardware
preference. Outputs land under `.../artifacts/<uuid>/`.

| Tool | Purpose |
|---|---|
| `video_info` | encoders with hardware flag, discovered `render-mcp`, paths |
| `render_video` | scene as object or `scene_path` → video, optional `codec`, `audio_path`, `effects` |
| `render_3d` | 3D scene (SceneKit) as object or `scene3d_path` → video, same options |
| `render_start` | like `render_video`, runs in the background and returns an id |
| `render_status` | state, progress 0–100 and result for an id |
| `render_cancel` | aborts a run; `render-mcp` is stopped, frames are removed |

A scene is validated JSON (`config/scene.schema.json`), example:
`config/scenes/golden.json`.

```json
{
  "version": 1,
  "width": 1920, "height": 1080,
  "fps": 30, "duration": 10.0,
  "background": "#101218",
  "layers": [
    {"type": "rect", "x": 120, "y": 160, "width": 420, "height": 240,
     "radius": 24, "color": "#5B8DEF", "motion": {"dx": 760, "dy": 0}},
    {"type": "circle", "x": 960, "y": 720, "radius": 140,
     "color": "#4FA37A", "motion": {"dy": -280, "opacity_from": 0.2, "opacity_to": 1.0}}
  ]
}
```

Rules: `version` 1, edges 16–8192, 1–120 fps, duration up to 600 s, at most 256
layers, colours as `#RRGGBB`/`#RRGGBBAA`. Unknown fields and missing images are
rejected. Layers: `rect`, `circle`, `text`, `image`. `motion` moves and fades
over the whole duration: either linearly via `dx`/`dy`/`opacity_from`/
`opacity_to`, or via `keyframes` with absolute positions. Both forms know
`easing` (`linear`, `ease-in`, `ease-out`, `ease-in-out`); keyframes and linear
fields are mutually exclusive. Example with keyframes: `config/scenes/easing.json`.

Text is rasterised with the bundled font `assets/fonts/PT_Sans-Web-Regular.ttf`
(OFL); if it is missing, system fonts are used with a warning. Image layers
accept PNG (including 16-bit and greyscale), JPEG and WebP; the content is
compared, not the extension. Example: `config/scenes/text.json`.

Without the gateway, for tests:

```sh
render-mcp --scene config/scenes/golden.json --frames-dir /tmp/frames
video-mcp --render config/scenes/golden.json /tmp/golden.mp4
video-mcp --render config/scenes/golden.json /tmp/hevc.mp4 --codec hevc
video-mcp --render config/scenes/golden.json /tmp/pr.mov --codec prores422
video-mcp --render config/scenes/golden.json /tmp/av.mp4 \
  --audio /System/Library/Sounds/Glass.aiff
video-mcp --probe /tmp/golden.mp4
```

`codec`: `h264` (default, `mp4`), `hevc` (`mp4`), `prores422`/`prores4444`
(`mov`). ProRes runs without a hardware requirement; H.264 and HEVC request the
hardware path and report it in the result. `audio_path` adds an AAC track via an
AVMutableComposition; `av_sync` reports the difference in start times in
milliseconds.

At 4K the hardware encoder is the ceiling: H.264 needs 3.10 s for 150 frames
(277 kB), HEVC 3.27 s (353 kB) — which is why H.264 stays the default. The
`PrioritizeEncodingSpeedOverQuality` switch changes nothing (byte-identical
files), so the encoder is already at its limit.

`effects` (a list, also for `render_3d` and `render_start`) applies CoreImage
filters to every frame in order: `blur` (radius), `bloom` (intensity, radius),
`color` (saturation, contrast, brightness) and `vignette` (intensity, radius).
Without effects the encode path stays byte-identical.

`render_3d` takes its own scene with camera, light and objects (`box`, `sphere`,
`plane`, `text`), renders offscreen through SceneKit/Metal and uses the same
encoding chain. Camera: `position`, `target`, `fov`; either `orbit` (degrees,
axis) for a steady rotation or `path` with 2–64 anchor points
`{t, position, target}` for a camera move (ascending times, smooth
interpolation). Several lights via `lights` (`omni`, `directional`, `spot`,
`ambient`, each with `intensity`, `color`, `castsShadow`); `light`/`ambient`
remain as a simple fallback. Objects know `emissive`, `emissiveIntensity` and
`roughness`/`metalness` for PBR materials. Limit: 512 objects. Example:
`config/scenes/3d-golden.json`. CLI: `video-mcp --render3d <scene> <out>
[--audio <file>] [--bloom 0.2] [--vignette 0.3] [--saturation 1.05]`.

4K30 is unlocked: `config/scenes/4k.json` renders 3840×2160 at 30 fps; measured
150 frames in 7 s with 1.15 GiB peak RSS, hardware encoder active.

`config/scenes/rechenzentrum.json` shows the 3D setup (119 objects,
camera orbit, racks, LEDs, labels) from `scripts/make-data-center-scene.js`. The
five-minute film `config/scenes/rechenzentrum-5min.json` (436 objects, 306 s,
23 camera anchors, six lights, chapters for three hosts, monitoring and backup)
is generated by `scripts/make-data-center-5min.js`; the narration lives in the
vault as a transcript.

### Frame transport

2D runs get their frames through a ring buffer, not through PNG files:
`render-mcp --sink shm` writes raw BGRA pixels into a pre-created file with four
slots, `video-mcp` reads them out and encodes at the same time. A byte on stdin
frees a slot, so the renderer runs at most four frames ahead. That removes PNG
decoding (20 ms per 4K frame), and wall time becomes the maximum of rendering
and encoding instead of the sum.

| Scene | PNG (files) | Ring | Change |
|---|---:|---:|---:|
| 1080p, 300 frames | 4.34 s (14.5 ms/frame) | 1.79 s (6.0 ms) | −59 % |
| 4K, 150 frames | 6.64 s (44.2 ms) | 3.08 s (20.6 ms) | −54 % |
| 4K, three effects | 9.17 s (61.2 ms) | 3.20 s (21.3 ms) | −65 % |

Measured on an M2 Pro, three runs each (`scripts/bench-media.sh --repeat 3`).
Peak RSS of the 4K acceptance run drops from 1.15 GiB to 196 MiB, because no
frames are buffered as PNG any more.

`VIDEO_FRAME_TRANSPORT=png` forces the file path, as does `keep_frames: true` or
`--keep-frames`, because then the frames are meant to stay. An installed
`render-mcp` without `--sink` is detected and served over PNG automatically. The
3D pipeline (`render_3d`) goes one step further: it runs in its own process and
hands every frame straight to the encoder (`transport: direct`), without a file
and without PNG. 90 frames of the 3D acceptance run take 0.7 s instead of 3 s;
only `keep_frames` writes PNG again.

Continuation: `render_start` returns `render-<uuid>`, `render_status` gives
`state`/`progress`/result, `render_cancel` answers immediately with `cancelled`
and terminates the `render-mcp` subprocess (SIGTERM, after 500 ms SIGKILL).
`render_start` accepts 2D or 3D sources (`scene`, `scene_path`, `scene3d`,
`scene3d_path`); 3D thus also runs as a job with progress and cancellation. A
time budget for the `render-mcp` subprocess applies per run: `timeout_s` on the
tool or `RENDER_TIMEOUT_S` (default 600 s). At most two runs at once.

`scripts/golden-video.sh` checks the 10-second acceptance run (300 frames,
determinism, H.264, hardware). `scripts/codec-video.sh` checks H.264, HEVC and
ProRes 422 plus audio muxing on a 3-second scene, `scripts/3d-video.sh` the 3D
scene and `scripts/4k-video.sh` 4K30 including peak RSS. `scripts/bench-media.sh`
compares both transport paths for 1080p, 4K and 4K with effects and checks the
thresholds with `--gate` (1080p ≤ 3.0 s, 4K ≤ 5.0 s). Measured on the Mac:
golden 2 s, codec about 3 s, 3D (90 frames) 0.7 s, 4K30 (150 frames) 4 s.

## Photo

`photo` (Python, its own venv) is the image and audio backend. It holds exactly
one model, unloads the text model in llama-swap before loading, and writes
results to `.../artifacts/<uuid>/`.

| Tool | Input | Result |
|---|---|---|
| `photo_models` | – | loaded model, device, paths |
| `photo_unload` | – | release the model |
| `photo_depth` | `path` | `depth.png` + `depth.npy` |
| `photo_upscale` | `path`, `scale` 2/4 | `upscaled.png` |
| `photo_matte` | `path` | `matte.png` (RGBA) |
| `photo_segment` | `path`, `points` or `box` | `mask.png` |
| `photo_transcribe` | `path`, `language` | `transcript.srt` + `.txt` |

Models: Depth Anything V2 Large (CC-BY-NC-4.0), SAM 2.1 Large (Apache-2.0),
BiRefNet (MIT), Real-ESRGAN x2 and x4plus (BSD-3), Whisper large-v3-turbo (MIT).
Stored under `~/models/photo/`, downloaded with
`backends/photo/download-models.sh` (aria2 or curl, 5.6 MB/s).

The image models compute in half precision (`fp16`) unless `PHOTO_FP16` is `0`;
against fp32 the deviation stays at 1–2 of 255 (PSNR above 61 dB). `scale: 2`
uses its own x2 model. Measured on an M2 Pro (768 × 768, warm model):
`photo_upscale` 2× 5.5 s → **1.2 s**, 4× 4.6 s → 4.3 s, `photo_depth`
1.1 s → 0.97 s.

```bash
python3.14 -m venv "$HOME/Library/Application Support/mac-compute/venvs/photo"
V="$HOME/Library/Application Support/mac-compute/venvs/photo"
"$V/bin/pip" install -r backends/photo/requirements.txt
backends/photo/download-models.sh
./scripts/install-mac.sh --update-manifests
```

The backend is enabled in `config/servers.d/photo.json`. It starts with the
gateway; `capabilities` shows `photo` with seven tools. RIFE (frame
interpolation) is still missing.

For in-between frames, Apple's **MetalFX frame interpolator** was evaluated
instead (macOS 26+, available on the M2 Pro): 6.7 ms per 1080p intermediate
frame, and pixel-exact against a real 60 fps reference of the same crop (PSNR
99 dB; plain 50 % blending would sit at 30 dB). Not built in, because it doubles
the frame count and therefore encoder and runtime — it is a quality option, not
a speed gain.

## Gen

`gen` (Python, its own venv) generates images with FLUX.2 Klein 4B and
Z-Image-Turbo via mflux (MLX, 4- and 6-bit), plus a local SDXL checkpoint via
diffusers on MPS, and recognises text with PaddleOCR-VL. All image models run as
a subprocess, OCR as a worker in a second venv; memory is released after every
job.

| Tool | Input | Result |
|---|---|---|
| `gen_txt2img` | `prompt`, `width`, `height`, `steps`, `seed` | `image.png` |
| `gen_zimage` | `prompt`, `width`, `height`, `steps`, `seed`, `guidance` | `image.png` |
| `gen_sdxl` | `prompt`, `negative_prompt`, size, steps, `cfg_scale`, `seed`, `sampling_method`, `engine`, `device`, `type` | `image.png` |
| `gen_edit` | `prompt`, `images[]`, `strength`, `steps`, `seed` | `edited.png` |
| `gen_ocr` | `path`, `task` (`ocr`/`table`/`formula`/`chart`) | text |
| `gen_models` | – | paths and state |
| `gen_unload` | – | release the OCR model |

Models: FLUX.2 Klein 4B mflux Q4 (4.62 GB, Apache-2.0), Z-Image-Turbo 6B mflux
Q6 (8.45 GB, Apache-2.0), PaddleOCR-VL (1.92 GB, Apache-2.0) and the local SDXL
checkpoint NSFW-gen-v2 (6.94 GB, `~/models/gen/sdxl-nsfw-v2/`, venv `sdxl` with
diffusers; not in the download script — details in `backends/gen/README.md`).
Stored under `~/models/gen/`, downloaded with `backends/gen/download-models.sh`
and `backends/gen/download-zimage.sh`.

### Installing a model

New models come with two scripts instead of a bespoke download script:

```sh
./scripts/model-fetch.sh mflux-community/z-image-turbo-mflux-q6 \
  ~/models/gen/z-image-turbo-mflux-q6        # download and verify
./scripts/model-fetch.sh mflux-community/z-image-turbo-mflux-q6 \
  ~/models/gen/z-image-turbo-mflux-q6 --check # verify only, ~26 s for 8 GB
./scripts/model-check.sh gen zimage ~/models/gen/z-image-turbo-mflux-q6 \
  --repo mflux-community/z-image-turbo-mflux-q6 --capability z-image
```

`model-fetch.sh` reads size and SHA-256 from the Hugging Face API
(`/api/models/<repo>/tree/main?recursive=true`), downloads with curl over a
single connection at 5.6 MB/s and verifies every file afterwards. Small config
files are not in LFS and are checked by size. Gated repos need a login:
`hf auth login` on the Mac writes `~/.cache/huggingface/token`; the script reads
the token from there (or `HF_TOKEN`) and passes it to curl as a header file —
never as an argument. HTTP 401 means "token missing or invalid", 403 "accept the
licence on the model page". If curl aborts a large run with a network error
(`Connection reset by peer`, exit 56), the script resumes with `aria2c -c` —
network errors only, an HTTP error is not retried. Before that, curl gave up
after five attempts although only 219 MB were missing (2026-10-28, 3.9 GB GGUF).

`model-check.sh` checks the whole chain: files against Hugging Face, the
manifest (JSON, version, capability), `tools/list` including the announced
`tools.listChanged` capability, and the output of `<backend>_models`. That is
how you notice when a tool exists but never reaches the session.

The older `backends/*/download-*.sh` stay as evidence of their sources; new
models no longer get a bespoke download script.

Not implemented: TRELLIS.2 (24 GB NVIDIA, CUDA), Wan2.2 (diffusers ~34 GB,
GGUF/ComfyUI only), StableMaterials.

### Mesh preparation

`gen_mesh` builds a mesh from an image with TripoSR. For models that already
arrive as a photogrammetry scan from an iPhone (Polycam, Apple Object Capture),
building one is the wrong step — what is missing is cleanup. That is what
`scripts/blender-clean.py` does, headless through Blender 5.2:

```sh
blender --background --factory-startup --python scripts/blender-clean.py -- \
  --input scan.glb --output scan-clean.glb \
  --target-tris 60000 --fill-holes --keep-largest \
  --up Y --texture-max 2048 --report scan-clean.json
```

Steps: import (GLB/GLTF, OBJ, USDZ/USD, FBX, STL, PLY), join objects, merge
duplicate vertices, remove loose vertices and small islands, close open borders,
normals outward, decimate (`collapse` or `planar`), limit textures, export. The
report lists triangles, boundary and non-manifold edges before and after, filled
holes, removed islands, dimensions in millimetres and the duration per step.

Two texture fields in the report, do not confuse them: `textures` lists only what
`--texture-max` **downscaled** (so an empty list means "nothing had to be
scaled"), `texture_images` inventories every texture with its pixel size — that
is how you see whether a texture arrived at all.

Decimation preserves the scan's UVs by interpolation; the texture is not
unwrapped again. If you need a new UV layout, unwrap in Blender after cleanup and
bake there.

Measured on an M2 Pro, TripoSR mesh with 258,376 triangles:

| Step | Duration |
|---|---|
| import (OBJ, 14 MB) | 0.09 s |
| cleanup (merge, islands, holes) | 0.81 s |
| decimate to 60,000 triangles | 0.89 s |
| export GLB | 0.24 s |

`bpy` has no type stubs; `mypy` does not run for this script. `ruff format`,
`ruff check`, `bandit` and the run itself are the checks.

## Signing

`scripts/sign-mac.sh` signs the gateway and backends with the hardened runtime
and can notarise the directory as a ZIP:

```sh
scripts/sign-mac.sh --check
scripts/sign-mac.sh --identity "Developer ID Application: … (TEAMID)"
scripts/sign-mac.sh --identity … --notarize --profile mac-compute
```

Prerequisites are a Developer ID in the keychain and a notarytool profile.
Without both, `--check` aborts without changing anything. Individual executables
cannot be stapled; build a signed package for stable distribution. No Developer
ID is installed on the current Mac.

## LLM

> **Disabled since 2026-10-23.** `servers.d/llm.json` is set to
> `"enabled": false`. The real text models run through llama-swap on
> `127.0.0.1:8080`. Reason: `llm-mcp` uses fixed ChatML, 4096 context and at
> most 1024 new tokens — not suitable for larger models. The demo backend also
> held 469 MB permanently.

`llm-mcp` loads a GGUF model on start and keeps it warm. The path comes from
`LLM_MODEL_PATH` or is the first `.gguf` file under `.../mac-compute/models/`.

| Tool | Input | Output |
|---|---|---|
| `llm_models` | – | available `.gguf` files with size |
| `llm_generate` | `prompt`, optional `system`, `model`, `max_tokens` 1–1024, `temperature` 0–2, `seed` | text plus duration |
| `llm_embed` | `text` 1–8192 chars, optional `model` | vector (6 decimals), dimensions, norm, duration |

Without `model`, the model loaded at start is used. A different name from
`llm_models` is loaded on demand and replaces the active model. Before every
load, `llm-mcp` checks the file size plus 25 % headroom against `maxMemoryMB`
(manifest, `LLM_MAX_MEMORY_MB` or 4096 MB) and rejects oversized models with
`memory_limit`. Generation and embedding each keep one model in cache (separate
locks); a model switch releases the old one first. Embeddings use their own
context with `n_ctx` equal to the text length and pooling via
`embeddings_seq_ith`, falling back to the last token for causal models. Measured
with Qwen2.5-0.5B: 896 dimensions.

Tested with Qwen2.5-0.5B-Instruct Q4_K_M (Apache-2.0, 469 MB): model start in
0.6 s, "capital of France?" → `Paris` in 0.1 s. Generation runs in a blocking
thread; one call does not block the MCP server.

Loading a model:

```sh
curl -L -o "$HOME/Library/Application Support/mac-compute/models/qwen2.5-0.5b-instruct-q4_k_m.gguf" \
  https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

Building `llama-cpp-2` needs `cmake` and takes a few minutes the first time.

## Development

The source tree lives on the Mac under `~/workspace/git/mac-media` and is
visible inside the OpenCode sandbox as `/workspace/git/mac-media`. Both
sides work on the same files.

| Task | Where |
|---|---|
| writing, git, docs | sandbox or Mac |
| `cargo` build and tests | **Mac** (Rust 1.99, native toolchain) |
| render and LLM build (Metal) | Mac |
| `ml-mcp`, `media-mcp` (Swift) | Mac |
| launch agent, token, binaries | Mac |

The sandbox deliberately has no Rust or Swift toolchain; all builds and tests run
natively on the Mac:

```sh
cargo build --release --workspace
cargo test --workspace
swift build -c release --package-path swift
```

## Operation

Binaries live in `~/Library/Application Support/mac-compute/bin/`, manifests in
`.../mac-compute/servers.d/` (mode `0600`). The queue is
`.../mac-compute/state/jobs.sqlite`; the directory is `0700`, the database
`0600`. Every run creates a directory under `.../mac-compute/artifacts/`;
`scripts/artifacts-prune.sh` keeps the newest five and shows in a dry run what it
would delete (`--apply` deletes). The gateway runs as the launch agent
`de.kippar.mac-compute-gateway`, the token sits in
`~/.config/mac-compute/token` (`0600`). To run it by hand:

```sh
cargo run -p mac-compute-gateway -- \
  --bind 127.0.0.1:8787 \
  --servers-dir "$HOME/Library/Application Support/mac-compute/servers.d" \
  --state-dir "$HOME/Library/Application Support/mac-compute/state" \
  --token-file "$HOME/.config/mac-compute/token" \
  --log-dir "$HOME/Library/Logs/mac-compute"
```

The gateway binds to loopback only, requires a token of at least 32 characters,
and answers on `/health` as on `/mcp` exclusively with a bearer token. Details
are in the internal runbook.

### MCP sessions

The Streamable HTTP transport issues one `Mcp-Session-Id` per client. The
gateway keeps it in memory and also writes it as JSON under
`.../mac-compute/state/sessions/` (`0600`, one file per session). After a
restart — every deploy triggers one — it loads the session from that file,
replays the `initialize` handshake internally and answers the next request with
the same result instead of `404 Not Found`. The client notices nothing and does
not have to reconnect; a running image or video job is not lost.

If the file is missing (session from before the feature, or cleaned up), the id
receives the last seen client profile (`client-profile.json`) and lives on. Ids
that do not consist of `[A-Za-z0-9-]` or are longer than 128 characters are
never used as a file name. On start the gateway cleans up: files older than 30
days and anything beyond 512 entries disappear.

### Resources

Besides tools, the gateway offers one MCP resource: `mac-media://tools` returns
the aggregated tool list of all backends as JSON. That is the only inventory that
makes sense as a resource — artefacts (images, videos) live in the artefact
directory and come back through tool results.

### Rotating the token

`scripts/rotate-token.sh` backs up the current token as `token.previous`,
creates a new one (32 bytes, `0600`) and unloads and reloads the launch agent;
then it checks both tokens against `/health`.

```sh
./scripts/rotate-token.sh --dry-run   # show the sequence only
./scripts/rotate-token.sh             # rotate, reload, verify
```

The old token stays valid from the modification date of `token.previous` for
`--token-grace-hours` (default 168, `0` disables the grace period); after that
only the new one counts. An existing `token.previous` aborts the run unless
`--force` is given — otherwise a still valid token would be lost. Every rotation
replaces the predecessor; whoever still holds the oldest token after two
rotations loses access and needs a restart with the new value.

By hand it is the same steps:

```sh
cd ~/.config/mac-compute
cp token token.previous && chmod 600 token.previous
openssl rand -hex 32 > token.new && mv token.new token && chmod 600 token

launchctl bootout "gui/$(id -u)/de.kippar.mac-compute-gateway"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/de.kippar.mac-compute-gateway.plist"
```

An existing but formally invalid `token.previous` (shorter than 32 characters or
containing whitespace) makes the start fail instead of silently losing the grace
period. Delete `token.previous` after it expires.

## Logs

With `--log-dir` the gateway additionally writes JSONL with daily rotation
(`<dir>/gateway.<date>.jsonl`). The directory is created on start and must be
absolute. stderr stays with launchd and ends up in `gateway.err.log`.

## Quality gate

Prerequisites on the Mac (once):

```sh
rustup component add rustfmt clippy
cargo install --locked cargo-audit cargo-deny cargo-nextest
brew install shellcheck
```

Run `scripts/check.sh` before every merge: `cargo fmt --check`,
`cargo clippy -D warnings`, tests (nextest + doc tests), `cargo deny check`,
`cargo audit`, `swift build` and `swift test`, `bash -n` and `shellcheck` for
shell scripts, plus `ast.parse` and — if installed — `ruff format --check` and
`ruff check` for `scripts/*.py`. No commit on `main`, every change through a
branch.

## License

MIT OR Apache-2.0. The texts are in `LICENSE-MIT` and `LICENSE-APACHE`. The test
model Qwen2.5-0.5B-Instruct is Apache-2.0 and not part of the repository.
