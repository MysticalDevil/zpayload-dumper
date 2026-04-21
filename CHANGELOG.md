# Changelog

## [Unreleased]

### Added

- `-v`, `--version` flag to print version and tool description.
- Colored brief usage output for unsupported arguments and invalid options.

### Changed

- Default concurrency changed from `4` to half of logical CPU threads (`nproc / 2`).
- Unsupported arguments now print brief `renderUsage` instead of full help.

## [0.0.1] - 2026-04-20

Initial release.
