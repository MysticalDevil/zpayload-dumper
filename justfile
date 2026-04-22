set shell := ["bash", "-euo", "pipefail", "-c"]

build:
    zig build

test:
    zig build test

test_stress:
    zig build test_stress

check_e2e:
    zig build check_e2e

sim_test name="just-sim":
    uv run --project scripts payload-gen sample --name {{name}}
    zig build check_e2e -- tests/data/generated/{{name}}/payload.bin tests/data/generated/{{name}}/extracted

bench_smoke:
    zig build bench_smoke

bench_pressure:
    zig build bench_pressure

release:
    ./scripts/build-release.sh

clean:
    rm -rf .zig-* zig-*out tests/data/generated release .build-release
