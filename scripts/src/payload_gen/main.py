"""Top-level CLI entrypoint for payload fixture generators."""

from __future__ import annotations

import argparse

from payload_gen import delta_generator, sample_generator


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="payload-gen",
        description="Generate synthetic payload.bin and OTA fixtures for zpayload-dumper.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    sample_parser = subparsers.add_parser(
        "sample",
        help="generate valid and invalid payload/OTA fixtures",
    )
    sample_parser.set_defaults(run=sample_generator.main)

    delta_parser = subparsers.add_parser(
        "delta",
        help="generate SOURCE_BSDIFF delta payload fixtures",
    )
    delta_parser.set_defaults(run=delta_generator.main)

    return parser


def main() -> int:
    parser = build_parser()
    args, remaining = parser.parse_known_args()
    return args.run(remaining)


if __name__ == "__main__":
    raise SystemExit(main())
