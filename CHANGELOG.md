# Changelog

## [Unreleased]

### Added

- `-v`, `--version` flag to print version and tool description.
- Colored brief usage output for unsupported arguments and invalid options.
- ZIP64 extra field parsing and local/central directory cross-validation for zip input.
- TAR input support (`.tar`, `.tar.gz`, `.tgz`) with automatic payload.bin extraction.
- `payload-gen` CLI for generating synthetic test samples and delta payloads (replaces standalone Python scripts).
- `docs/PYTHON_GENERATORS.md` and `docs/PYTHON_GENERATORS.zh.md` documenting the Python tooling.
- Integration test for bench512 modem partition extraction.
- Unit tests for bsdiff patch application.
- Dry-run mode (`--dry-run`) for simulating extraction without writing output.
- Disk space pre-check via `statvfs` before extraction.
- Memory-bounded pending queue (256 MB) with spill-to-temp fallback for out-of-order operations.
- Progress tracking with TTY-aware rendering (dynamic multi-partition view vs line-based logs).
- Environment variable color override (`ZPAYLOAD_COLOR`, `NO_COLOR`, `CLICOLOR`, `CLICOLOR_FORCE`).
- Centralized platform abstraction (`src/utils/platform.zig`) for OS-specific paths and APIs.

### Changed

- Default concurrency changed from `4` to half of logical CPU threads (`nproc / 2`).
- Unsupported arguments now print brief `renderUsage` instead of full help.
- Migrated Python helpers from standalone scripts to a `uv`-managed package under `scripts/`.
- Replaced `fixture` / `夹具` jargon with `test sample` / `测试样本` across all docs.
- `decompressZstdToWriter` and `decompressXzToWriter` now use `streamRemaining` API with a dedicated zstd window buffer.
- `--format` CLI option syntax updated to `--format <mode>` with `--format=json` shorthand.
- Updated distro support matrix: Ubuntu/Debian/Fedora now marked as "build from source" instead of "not supported".
- **Simplified temp directory logic**: removed `TMPDIR` support and disk-space-based fallback. zip/tar extraction now always uses
  `./.tmp` under the current working directory, and the temp directory is always auto-removed after extraction completes.

### Fixed

- Hardened bsdiff `applyPatch` with explicit bounds checks and correct backward seek handling.
- Improved engine error handling: spill directory creation failures are no longer silently ignored.
- Worker and engine threads now use `defer join()` to guarantee cleanup on early returns.
- `help.zig` no longer panics on `ZPAYLOAD_COLOR=` without a value.
- `fs_hash.zig` now verifies read count matches expected bytes.
- Eliminated hard-coded `/tmp` and `.tmp` paths by centralizing them in `src/utils/platform.zig`.

## [0.0.1] - 2026-04-20

Initial release.
