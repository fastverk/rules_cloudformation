"""Merge typed-rule shards into a CloudFormation template.

Driven by `cloudformation_stack` (see stack.bzl). Reads:
  * one Properties shard per resource (each shard is the contents of
    a `Resources.X.Properties` block, emitted by a spec-derived
    rule in `defs.bzl`),
  * zero or more `AWS::CloudFormation::Init` shards (each gets
    spliced under the target resource's
    `Metadata.AWS::CloudFormation::Init`),
  * zero or more `AWS::CloudFormation::Interface` shards (each gets
    spliced under the template's top-level
    `Metadata.AWS::CloudFormation::Interface`).

Writes one canonical JSON template. The output is deterministic:
keys are emitted in sort order, intrinsic shards are merged in
input order, indentation is 2 spaces. That way the
`cloudformation_stack_up_to_date` `diff_test` in consumer repos
catches drift on every CI run.

Argv:
  `--output=PATH` (required) — where to write the template.
  `--description=STR` (optional) — template Description.
  `--resource=NAME=CFN_TYPE=PROPERTIES_SHARD_PATH` (repeated, may
       be empty if the stack only carries intrinsics).
  `--init=TARGET_RESOURCE_NAME=SHARD_PATH` (repeated, optional).
       The target resource must appear in a `--resource=...`; the
       aggregator fails otherwise.
  `--interface=SHARD_PATH` (repeated, optional). Typically at most
       one — multiples are merged left-to-right.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _parse_resource(spec: str) -> tuple[str, str, Path]:
    parts = spec.split("=", 2)
    if len(parts) != 3:
        raise SystemExit(
            f"--resource expects NAME=CFN_TYPE=PATH, got {spec!r}"
        )
    name, cfn_type, path = parts
    if not name or not cfn_type or not path:
        raise SystemExit(f"--resource has empty field: {spec!r}")
    return name, cfn_type, Path(path)


def _parse_init(spec: str) -> tuple[str, Path]:
    parts = spec.split("=", 1)
    if len(parts) != 2:
        raise SystemExit(
            f"--init expects TARGET_RESOURCE_NAME=PATH, got {spec!r}"
        )
    return parts[0], Path(parts[1])


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--description", default="")
    ap.add_argument("--resource", action="append", default=[])
    ap.add_argument("--init", action="append", default=[])
    ap.add_argument("--interface", action="append", default=[])
    args = ap.parse_args(argv)

    resources: dict[str, dict] = {}
    for raw in args.resource:
        name, cfn_type, path = _parse_resource(raw)
        if name in resources:
            raise SystemExit(
                f"duplicate resource name in stack: {name!r}"
            )
        resources[name] = {
            "Type": cfn_type,
            "Properties": json.loads(path.read_text()),
        }

    for raw in args.init:
        target, path = _parse_init(raw)
        if target not in resources:
            raise SystemExit(
                f"--init targets {target!r}, which is not in the "
                f"stack's resources ({sorted(resources.keys())!r})"
            )
        # CFN tolerates either a single `AWS::CloudFormation::Init`
        # value or a list, but the structure here is one Init tree
        # per target. Duplicates last-write-wins with a warning.
        if "Metadata" in resources[target] and "AWS::CloudFormation::Init" in resources[target]["Metadata"]:
            print(
                f"stack_aggregator: warning — multiple --init shards "
                f"target {target!r}; later ones overwrite earlier.",
                file=sys.stderr,
            )
        resources[target].setdefault("Metadata", {})
        resources[target]["Metadata"]["AWS::CloudFormation::Init"] = json.loads(path.read_text())

    template: dict = {"AWSTemplateFormatVersion": "2010-09-09"}
    if args.description:
        template["Description"] = args.description

    if args.interface:
        merged: dict = {}
        for path in args.interface:
            shard = json.loads(Path(path).read_text())
            for k, v in shard.items():
                merged[k] = v
        template["Metadata"] = {"AWS::CloudFormation::Interface": merged}

    if resources:
        template["Resources"] = dict(sorted(resources.items()))

    args.output.write_text(json.dumps(template, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
