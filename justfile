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
    python3 scripts/generate_sample_payload.py --name {{name}}
    zig build check_e2e -- tests/data/generated/{{name}}/payload.bin tests/data/generated/{{name}}/extracted

bench_smoke:
    zig build bench_smoke

bench_pressure:
    zig build bench_pressure

release version:
    ./scripts/release.sh {{version}}

clean:
    rm -rf .zig-cache zig-out tests/data/generated release
