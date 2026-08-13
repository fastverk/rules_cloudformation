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

After merging, the aggregator deep-walks every value in the merged
template and rewrites the cross-resource reference sentinels
emitted by `cfn_ref` / `cfn_getatt` (see stack.bzl) into the
corresponding CFN intrinsic dicts:

  `@@cfn:ref:Name`        →  `{"Ref": "Name"}`
  `@@cfn:getatt:Name.Att` →  `{"Fn::GetAtt": ["Name", "Att"]}`
  `@@cfn:findinmap:M<US>K1<US>K2` → `{"Fn::FindInMap": ["M","K1","K2"]}`
        (US = the unit-separator `_FINDINMAP_SEP`; each arg is rewritten
         recursively so a nested `cfn_ref` resolves)
  `@@cfn:join:D<RS>V1<RS>V2`      → `{"Fn::Join": ["D", ["V1","V2"]]}`
  `@@cfn:joinlistref:D<RS>S`      → `{"Fn::Join": ["D", <S rewritten>]}`
        (RS = the record-separator `_JOIN_SEP` — a DIFFERENT control
         character to `_FINDINMAP_SEP`, so a FindInMap nested inside a
         Join survives the split with its own separators intact. The two
         Join sentinels are separate prefixes because CFN's second
         argument is either a list of values or a single list-VALUED
         reference, and nothing in the flat string distinguishes them
         after encoding — see `cfn_join` in stack.bzl.)

Any Ref/GetAtt sentinel pointing at a name not in the stack's
resource+parameter set fails the build (pseudo-parameters like
`AWS::Region` are exempt); FindInMap validates the map name against
the stack's declared mappings. Typos are caught at Bazel-build time
rather than at AWS deploy time.

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


_REF_SENTINEL = "@@cfn:ref:"
_GETATT_SENTINEL = "@@cfn:getatt:"
_IMPORTVALUE_SENTINEL = "@@cfn:importvalue:"
_SUB_SENTINEL = "@@cfn:sub:"
_BASE64_SENTINEL = "@@cfn:base64:"
_FINDINMAP_SENTINEL = "@@cfn:findinmap:"
# Two Join sentinels: an explicit list of values, and a single list-VALUED
# reference. Kept in sync with stack.bzl, which decides which one to emit from
# the Starlark type of `values` — by the time it reaches here both are flat
# strings and the distinction is unrecoverable.
_JOIN_SENTINEL = "@@cfn:join:"
_JOIN_LISTREF_SENTINEL = "@@cfn:joinlistref:"
# Unit Separator — joins the three FindInMap args inside the flat sentinel
# string. It can't appear in a CFN map/key name, so the split is unambiguous.
_FINDINMAP_SEP = "\x1f"
# Record Separator — joins the delimiter + values inside a Join sentinel.
# Deliberately a different character to _FINDINMAP_SEP: a cfn_find_in_map
# nested in a join's value list arrives carrying \x1f inside its own sentinel,
# and splitting the join on \x1f would shred it into fragments that match no
# prefix and render as literal strings — a silently-vanished map lookup.
_JOIN_SEP = "\x1e"


def _rewrite_sentinels(value, valid_names: set[str], valid_mappings: set[str], path: str):
    """Deep-walk `value`, replacing sentinel strings with CFN
    intrinsic dicts. Yields validation errors via SystemExit when
    a sentinel points at a name not in `valid_names` (only Ref /
    GetAtt are validated; ImportValue references a sibling stack
    we can't introspect; Sub embeds CFN-deploy-time names).

    `path` is a human-readable JSON-path-ish breadcrumb used in
    error messages (e.g. `Resources.MyPolicy.Properties.Bucket`).
    """
    if isinstance(value, str):
        if value.startswith(_REF_SENTINEL):
            ref_name = value[len(_REF_SENTINEL):]
            # CFN pseudo-parameters (AWS::Region, AWS::AccountId, …) are always
            # valid and never declared in the stack — don't validate them.
            if ref_name.startswith("AWS::"):
                return {"Ref": ref_name}
            if ref_name not in valid_names:
                raise SystemExit(
                    f"stack_aggregator: cfn_ref({ref_name!r}) at {path} "
                    f"points at a name that isn't in the stack "
                    f"(known resources + parameters: {sorted(valid_names)!r})"
                )
            return {"Ref": ref_name}
        if value.startswith(_FINDINMAP_SENTINEL):
            body = value[len(_FINDINMAP_SENTINEL):]
            parts = body.split(_FINDINMAP_SEP)
            if len(parts) != 3:
                raise SystemExit(
                    f"stack_aggregator: malformed cfn_find_in_map sentinel at "
                    f"{path}: expected 3 parts, got {len(parts)}"
                )
            map_name = parts[0]
            if map_name not in valid_mappings:
                raise SystemExit(
                    f"stack_aggregator: cfn_find_in_map({map_name!r}, ...) at "
                    f"{path} points at a map that isn't in the stack "
                    f"(known mappings: {sorted(valid_mappings)!r})"
                )
            # Recurse each arg so nested cfn_ref (e.g. the top-level key) rewrites.
            return {"Fn::FindInMap": [
                _rewrite_sentinels(p, valid_names, valid_mappings, f"{path}[{i}]")
                for i, p in enumerate(parts)
            ]}
        if value.startswith(_GETATT_SENTINEL):
            body = value[len(_GETATT_SENTINEL):]
            ref_name, _, attribute = body.partition(".")
            if not ref_name or not attribute:
                raise SystemExit(
                    f"stack_aggregator: malformed cfn_getatt sentinel at "
                    f"{path}: {value!r}"
                )
            if ref_name not in valid_names:
                raise SystemExit(
                    f"stack_aggregator: cfn_getatt({ref_name!r}, ...) at "
                    f"{path} points at a name that isn't in the stack "
                    f"(known resources + parameters: {sorted(valid_names)!r})"
                )
            return {"Fn::GetAtt": [ref_name, attribute]}
        if value.startswith(_IMPORTVALUE_SENTINEL):
            export_name = value[len(_IMPORTVALUE_SENTINEL):]
            if not export_name:
                raise SystemExit(
                    f"stack_aggregator: empty cfn_import_value sentinel at {path}"
                )
            return {"Fn::ImportValue": export_name}
        if value.startswith(_SUB_SENTINEL):
            template = value[len(_SUB_SENTINEL):]
            if not template:
                raise SystemExit(
                    f"stack_aggregator: empty cfn_sub sentinel at {path}"
                )
            return {"Fn::Sub": template}
        if value.startswith(_BASE64_SENTINEL):
            inner = value[len(_BASE64_SENTINEL):]
            if not inner:
                raise SystemExit(
                    f"stack_aggregator: empty cfn_base64 sentinel at {path}"
                )
            # Recurse so a nested cfn_sub / cfn_ref under the base64 rewrites too.
            return {"Fn::Base64": _rewrite_sentinels(inner, valid_names, valid_mappings, path)}
        # ⛔ The listref form MUST be tested before the plain join form. The two
        # prefixes don't actually collide (`@@cfn:joinlistref:` diverges from
        # `@@cfn:join:` at the character after "join"), but that is one edit away
        # from being untrue, and getting it wrong is not a crash — a listref
        # matched as a plain join renders `[delim, ["listref-tail"]]`, a
        # one-element list of garbage, which is valid JSON and deploys.
        if value.startswith(_JOIN_LISTREF_SENTINEL):
            body = value[len(_JOIN_LISTREF_SENTINEL):]
            delimiter, sep, inner = body.partition(_JOIN_SEP)
            if not sep or not inner:
                raise SystemExit(
                    f"stack_aggregator: malformed cfn_join (list-ref form) "
                    f"sentinel at {path}: expected DELIM<RS>SENTINEL, got {value!r}"
                )
            rewritten = _rewrite_sentinels(inner, valid_names, valid_mappings, path)
            # The whole point of this form is that the second argument is a
            # single intrinsic, NOT a list containing one. If it didn't rewrite
            # to an intrinsic dict it was a literal, and `{"Fn::Join": [",",
            # "text"]}` is rejected by CFN at deploy with a template format
            # error that names nothing useful. stack.bzl already refuses this,
            # so reaching here means a hand-built sentinel.
            if not isinstance(rewritten, dict):
                raise SystemExit(
                    f"stack_aggregator: cfn_join at {path} was given a single "
                    f"value that is not an intrinsic ({inner!r}); Fn::Join's "
                    f"second argument must be a list or something that yields "
                    f"one. Pass a list instead: cfn_join(delim, [value])."
                )
            return {"Fn::Join": [delimiter, rewritten]}
        if value.startswith(_JOIN_SENTINEL):
            body = value[len(_JOIN_SENTINEL):]
            # Split, not partition: everything after the delimiter is a value.
            # The delimiter itself is NOT recursed — CFN requires a literal
            # there, and stack.bzl rejects a sentinel for it.
            parts = body.split(_JOIN_SEP)
            delimiter, items = parts[0], parts[1:]
            if not items:
                raise SystemExit(
                    f"stack_aggregator: cfn_join at {path} has no values "
                    f"(an empty join yields the empty string, which is almost "
                    f"never what the caller meant)"
                )
            # Recurse each value so nested cfn_ref / cfn_getatt / cfn_find_in_map
            # resolve — and so their names are validated like anywhere else.
            return {"Fn::Join": [delimiter, [
                _rewrite_sentinels(item, valid_names, valid_mappings, f"{path}[{i}]")
                for i, item in enumerate(items)
            ]]}
        return value
    if isinstance(value, dict):
        return {k: _rewrite_sentinels(v, valid_names, valid_mappings, f"{path}.{k}") for k, v in value.items()}
    if isinstance(value, list):
        return [_rewrite_sentinels(v, valid_names, valid_mappings, f"{path}[{i}]") for i, v in enumerate(value)]
    return value


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


def _parse_named_shard(spec: str, flag: str) -> tuple[str, Path]:
    parts = spec.split("=", 1)
    if len(parts) != 2:
        raise SystemExit(
            f"{flag} expects NAME=PATH, got {spec!r}"
        )
    if not parts[0] or not parts[1]:
        raise SystemExit(f"{flag} has empty field: {spec!r}")
    return parts[0], Path(parts[1])


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--description", default="")
    ap.add_argument("--resource", action="append", default=[])
    ap.add_argument("--init", action="append", default=[])
    ap.add_argument("--interface", action="append", default=[])
    ap.add_argument("--parameter", action="append", default=[])
    ap.add_argument("--output_decl", action="append", default=[])
    ap.add_argument("--condition", action="append", default=[])
    ap.add_argument("--mapping", action="append", default=[])
    ap.add_argument("--resource_condition", action="append", default=[])
    ap.add_argument("--resource_depends_on", action="append", default=[])
    ap.add_argument("--resource_deletion_policy", action="append", default=[])
    ap.add_argument("--resource_update_replace_policy", action="append", default=[])
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

    parameters: dict[str, dict] = {}
    for raw in args.parameter:
        name, path = _parse_named_shard(raw, "--parameter")
        if name in parameters:
            raise SystemExit(
                f"duplicate parameter name in stack: {name!r}"
            )
        if name in resources:
            raise SystemExit(
                f"name collision: {name!r} declared as both a resource and a parameter"
            )
        parameters[name] = json.loads(path.read_text())

    outputs: dict[str, dict] = {}
    for raw in args.output_decl:
        name, path = _parse_named_shard(raw, "--output_decl")
        if name in outputs:
            raise SystemExit(
                f"duplicate output name in stack: {name!r}"
            )
        outputs[name] = json.loads(path.read_text())

    conditions: dict[str, object] = {}
    for raw in args.condition:
        name, path = _parse_named_shard(raw, "--condition")
        if name in conditions:
            raise SystemExit(
                f"duplicate condition name in stack: {name!r}"
            )
        conditions[name] = json.loads(path.read_text())

    mappings: dict[str, dict] = {}
    for raw in args.mapping:
        name, path = _parse_named_shard(raw, "--mapping")
        if name in mappings:
            raise SystemExit(
                f"duplicate mapping name in stack: {name!r}"
            )
        mappings[name] = json.loads(path.read_text())

    # Attach `Condition:` to resources. Validated against declared conditions so
    # a typo fails at build time, not at AWS deploy. (Both fields are plain
    # names — not a shard path — so this doesn't use _parse_named_shard.)
    for raw in args.resource_condition:
        rc_parts = raw.split("=", 1)
        if len(rc_parts) != 2 or not rc_parts[0] or not rc_parts[1]:
            raise SystemExit(f"--resource_condition expects RESOURCE=CONDITION, got {raw!r}")
        res_name, cond_name = rc_parts[0], rc_parts[1]
        if res_name not in resources:
            raise SystemExit(
                f"--resource_condition targets {res_name!r}, which is not in "
                f"the stack's resources ({sorted(resources.keys())!r})"
            )
        if cond_name not in conditions:
            raise SystemExit(
                f"--resource_condition for {res_name!r} names condition "
                f"{cond_name!r}, which is not declared in the stack "
                f"(known conditions: {sorted(conditions.keys())!r})"
            )
        resources[res_name]["Condition"] = cond_name

    # Attach `DependsOn:` to resources, for the ordering CFN cannot infer.
    #
    # CFN derives its dependency graph from Ref / Fn::GetAtt edges, which `cfn_ref` and
    # `cfn_getatt` already produce — so this is only for the cases where the ordering is
    # real but no value flows between the two resources. The canonical one, which every
    # VPC hits:
    #
    #     IgwAttachment      Ref -> Igw
    #     PublicDefaultRoute Ref -> Igw   (GatewayId)
    #
    # Both depend on the IGW; neither depends on the other. CFN is free to create the
    # route first, and it then fails with "The gateway ID 'igw-…' does not exist or is
    # not attached". AWS documents the DependsOn as REQUIRED for AWS::EC2::Route with a
    # GatewayId. Being a race, it can pass once and fail on the next rebuild.
    #
    # Same validation stance as --resource_condition: an unknown name is fatal at build
    # time. A typo'd DependsOn is otherwise silent and reinstates the exact race this
    # exists to remove.
    for raw in args.resource_depends_on:
        rd_parts = raw.split("=", 1)
        if len(rd_parts) != 2 or not rd_parts[0] or not rd_parts[1]:
            raise SystemExit(
                f"--resource_depends_on expects RESOURCE=DEP[,DEP...], got {raw!r}"
            )
        res_name = rd_parts[0]
        if res_name not in resources:
            raise SystemExit(
                f"--resource_depends_on targets {res_name!r}, which is not in "
                f"the stack's resources ({sorted(resources.keys())!r})"
            )
        deps = [d.strip() for d in rd_parts[1].split(",") if d.strip()]
        if not deps:
            raise SystemExit(
                f"--resource_depends_on for {res_name!r} names no dependencies"
            )
        for dep in deps:
            if dep not in resources:
                raise SystemExit(
                    f"--resource_depends_on for {res_name!r} names {dep!r}, which is "
                    f"not in the stack's resources ({sorted(resources.keys())!r})"
                )
            if dep == res_name:
                raise SystemExit(
                    f"--resource_depends_on for {res_name!r} depends on itself"
                )
        # A single dependency renders as a bare string rather than a one-element list.
        # Both are valid CFN; the string form is what hand-authored templates use, and
        # matching it keeps a generated template diffable against the one it replaced.
        resources[res_name]["DependsOn"] = deps[0] if len(deps) == 1 else sorted(deps)

    # Attach `DeletionPolicy:` / `UpdateReplacePolicy:`. Like Condition and DependsOn
    # above these are SIBLINGS of `Properties` — the typed shards carry only the
    # Properties payload, so resource-level attributes have always belonged here.
    #
    # ⛔ NESTING THESE INSIDE `Properties` PRODUCES A TEMPLATE THAT VALIDATES AND THEN
    # FAILS AT DEPLOY with an unrecognised property. The nesting is the thing to test,
    # not merely that the key is present somewhere.
    #
    # ⚠ `Snapshot` is accepted for every resource type here, though CFN only honours it on
    # types that support snapshots. Restricting per type would need this script to carry a
    # table of which types qualify; the mismatch fails at create, loudly and immediately,
    # which is a better trade than a table that goes stale.
    _DELETION_POLICIES = ("Delete", "Retain", "Snapshot", "RetainExceptOnCreate")
    # ⚠ UpdateReplacePolicy has NO RetainExceptOnCreate — it is meaningless there, since
    # the resource by definition already existed. Kept as separate tuples rather than one
    # shared list so the difference is visible instead of assumed.
    _UPDATE_REPLACE_POLICIES = ("Delete", "Retain", "Snapshot")

    for flag, key, allowed in (
        ("resource_deletion_policy", "DeletionPolicy", _DELETION_POLICIES),
        ("resource_update_replace_policy", "UpdateReplacePolicy", _UPDATE_REPLACE_POLICIES),
    ):
        for raw in getattr(args, flag):
            rp_parts = raw.split("=", 1)
            if len(rp_parts) != 2 or not rp_parts[0] or not rp_parts[1]:
                raise SystemExit(f"--{flag} expects RESOURCE=POLICY, got {raw!r}")
            res_name, policy = rp_parts[0], rp_parts[1]
            # Same validation stance as --resource_condition: an unknown resource name is
            # fatal at build time. A typo'd policy name is otherwise silent, and silently
            # means Delete — the exact outcome this attribute exists to prevent.
            if res_name not in resources:
                raise SystemExit(
                    f"--{flag} targets {res_name!r}, which is not in "
                    f"the stack's resources ({sorted(resources.keys())!r})"
                )
            if policy not in allowed:
                raise SystemExit(
                    f"--{flag} for {res_name!r} is {policy!r}, which is not one of "
                    f"{list(allowed)!r}"
                )
            resources[res_name][key] = policy

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

    if parameters:
        template["Parameters"] = dict(sorted(parameters.items()))

    if mappings:
        template["Mappings"] = dict(sorted(mappings.items()))

    if conditions:
        template["Conditions"] = dict(sorted(conditions.items()))

    if resources:
        template["Resources"] = dict(sorted(resources.items()))

    if outputs:
        template["Outputs"] = dict(sorted(outputs.items()))

    # Sentinel rewrite happens AFTER all shards are merged so the
    # validator can see the full {resource,parameter}-name set.
    # Walk the whole template — Interface ParameterLabels, Init
    # configs, Outputs.Value, Conditions, Mappings, etc. can all
    # carry sentinels.
    valid_names = set(resources.keys()) | set(parameters.keys())
    valid_mappings = set(mappings.keys())
    template = _rewrite_sentinels(template, valid_names, valid_mappings, "$")

    args.output.write_text(json.dumps(template, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
