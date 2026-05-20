#!/usr/bin/env python3
"""Overlay AWS-endpoint per-resource property `description` fields
onto the assembler-derived schema.

The upstream Java assembler emits schemas whose property
`description` fields are URL-only (links to the AWS docs page).
The AWS-published per-resource endpoint schemas at
`https://schema.cloudformation.us-east-1.amazonaws.com/<resource>.json`
ship rich prose descriptions for every property. This script
walks the two schemas in parallel and overlays the endpoint's
descriptions onto the assembled schema's matching properties.

Both schemas describe the same shape, just at different paths:

  Assembled (input from --assembled):
    definitions/AWS_S3_Bucket/properties/Properties/properties/<prop>/description

  Endpoint (input from --endpoints — repeatable):
    typeName = "AWS::S3::Bucket"
    properties/<prop>/description

The script's contract:

  argv  --assembled=PATH (mandatory)
        --endpoints=PATH (repeatable, one per resource type)
        --output=PATH (mandatory)
  stdin (unused — passes the assembled bytes through with overlays)
  stdout (unused)
  stderr human-readable diagnostics

Exits 0 on success; non-zero if --assembled can't be parsed or
overlay fails. Endpoint files that don't reference a resource the
assembled schema knows about are silently skipped (with a
diagnostic on stderr) — the use case is "add docs for the resources
you've already wired up."
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def aws_to_underscore(type_name: str) -> str:
    """`AWS::S3::Bucket` → `AWS_S3_Bucket` to match the assembler's
    JSON-pointer-safe naming."""
    return type_name.replace("::", "_")


def overlay_resource(assembled: dict, endpoint: dict) -> int:
    """Overlay one endpoint's per-property descriptions onto the
    assembled schema. Returns the number of properties enriched."""
    type_name = endpoint.get("typeName", "")
    if not type_name:
        sys.stderr.write("overlay_descriptions: endpoint missing typeName, skipping\n")
        return 0

    key = aws_to_underscore(type_name)
    target = (
        assembled.get("definitions", {})
        .get(key, {})
        .get("properties", {})
        .get("Properties", {})
        .get("properties", {})
    )
    if not target:
        sys.stderr.write(
            f"overlay_descriptions: assembled schema has no {key}, skipping\n"
        )
        return 0

    enriched = 0
    for prop_name, prop_schema in endpoint.get("properties", {}).items():
        endpoint_desc = prop_schema.get("description")
        if not endpoint_desc:
            continue
        if prop_name not in target:
            continue
        # Replace the assembler's URL-only description with the
        # rich endpoint prose. We keep the prose as-is — the
        # endpoint already includes the original doc URL within
        # its prose for cases that want it.
        target[prop_name]["description"] = endpoint_desc
        enriched += 1

    sys.stderr.write(
        f"overlay_descriptions: enriched {enriched} property "
        f"description(s) for {type_name}\n"
    )
    return enriched


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--assembled", required=True, type=Path)
    p.add_argument("--endpoints", action="append", default=[], type=Path)
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()

    try:
        with args.assembled.open("rb") as f:
            assembled = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"overlay_descriptions: failed to parse --assembled: {e}\n")
        return 2

    total = 0
    for ep_path in args.endpoints:
        try:
            with ep_path.open("rb") as f:
                endpoint = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            sys.stderr.write(
                f"overlay_descriptions: failed to parse --endpoint {ep_path}: {e}\n"
            )
            return 3
        total += overlay_resource(assembled, endpoint)

    # Write enriched output. Sort keys + 2-space indent so the result
    # is byte-stable across runs and reviewable in code review.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(assembled, f, sort_keys=True, indent=2)
        f.write("\n")

    sys.stderr.write(
        f"overlay_descriptions: enriched {total} description(s) total → {args.output}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
