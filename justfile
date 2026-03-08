set shell := ["bash", "-euo", "pipefail", "-c"]

build:
    zig build

test:
    zig build test

test-stress:
    zig build test-stress

check-e2e:
    zig build check-e2e

sim-test name="just-sim":
    python3 scripts/generate_sample_payload.py --name {{name}}
    zig build check-e2e -- testdata/generated/{{name}}/payload.bin testdata/generated/{{name}}/extracted

bench-smoke:
    zig build bench-smoke

clean:
    rm -rf .zig-cache zig-out testdata/generated
