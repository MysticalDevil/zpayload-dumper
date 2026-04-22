# Changelog

## [Unreleased]

### Added

- `-v`, `--version` flag to print version and tool description.
- Colored brief usage output for unsupported arguments and invalid options.
- ZIP64 extra field parsing and local/central directory cross-validation for zip input.
- `payload-gen` CLI for generating synthetic test samples and delta payloads (replaces standalone Python scripts).
- `docs/PYTHON_GENERATORS.md` and `docs/PYTHON_GENERATORS.zh.md` documenting the Python tooling.
- Integration test for bench512 modem partition extraction.
- Unit tests for bsdiff patch application.

### Changed

- Default concurrency changed from `4` to half of logical CPU threads (`nproc / 2`).
- Unsupported arguments now print brief `renderUsage` instead of full help.
- Migrated Python helpers from standalone scripts to a `uv`-managed package under `scripts/`.
- Replaced `fixture` / `夹具` jargon with `test sample` / `测试样本` across all docs.
- `decompressZstdToWriter` and `decompressXzToWriter` now use `streamRemaining` API with a dedicated zstd window buffer.
- `--format` CLI option syntax updated to `--format <mode>` with `--format=json` shorthand.

### Fixed

- Hardened bsdiff `applyPatch` with explicit bounds checks and correct backward seek handling.
- Improved engine error handling: spill directory creation failures are no longer silently ignored.
- Worker and engine threads now use `defer join()` to guarantee cleanup on early returns.
- `help.zig` no longer panics on `ZPAYLOAD_COLOR=` without a value.
- `fs_hash.zig` now verifies read count matches expected bytes.

## [0.0.1] - 2026-04-20

Initial release.
