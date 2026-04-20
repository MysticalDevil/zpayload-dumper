# utf8_range Vendor

Vendored from `protocolbuffers/protobuf` `v31.1` `third_party/utf8_range`.

Included files are intentionally limited to the build-time minimum used by this
project:

- `utf8_range.c`
- `utf8_range.h`
- `utf8_range_sse.inc`
- `utf8_range_neon.inc`
- `LICENSE`

These files are compiled directly by [build.zig](../../build.zig)
so CI does not need to fetch the full protobuf source tree just to obtain
`utf8_range`.
