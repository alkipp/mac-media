# Changelog

All notable changes to this repository. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer 2.0.0](https://semver.org/lang/de/).

`VERSION` is the version of the repository; backend versions live separately in
the `servers.d` manifests and in the Swift binaries.

This repository is the public export of a private project. The full development
history stays in the private repository; the version number is carried over so
both trees stay comparable.

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
