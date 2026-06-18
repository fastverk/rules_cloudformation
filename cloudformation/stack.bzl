"""`cloudformation_stack` — render a CFN template from typed-rule shards.

Each `cloudformation_aws_*` rule in `defs.bzl` emits a JSON shard
containing the resource's `Properties`. This aggregator collects
those shards into a single CloudFormation template, keyed by the
contributing rule's label.name (the v0.4 limitation — custom
`<kind_id>_name` overrides aren't surfaced; users name targets
PascalCase to match CFN's logical-id requirements).

Intrinsics (`cloudformation_aws_cloudformation_init`,
`cloudformation_aws_cloudformation_interface`) plug into the same
aggregator via the `intrinsics` attr. Init shards splice under
their declared `target_resource_name`; Interface shards splice
under the template-level `Metadata`.

Cross-resource references use the `cfn_ref` / `cfn_getatt`
Starlark helpers below — they return sentinel strings the
aggregator rewrites into `{"Ref": ...}` / `{"Fn::GetAtt": [...]}`
intrinsic dicts at shard-merge time. The aggregator also validates
that every referenced name is in the stack's resource set, so a
typo fails the build with a clear pointer instead of producing a
broken template that AWS rejects later.

Deploy wrappers (`bazel run` driving `aws cloudformation deploy`)
ride on a later phase.
"""

load(
    "//cloudformation:intrinsics.bzl",
    "CloudformationAwsCloudformationInitInfo",
    "CloudformationAwsCloudformationInterfaceInfo",
)
load("//cloudformation:parameter.bzl", "CloudformationParameterInfo")
load("//cloudformation:output.bzl", "CloudformationOutputInfo")
load("//cloudformation:condition.bzl", "CloudformationConditionInfo")
load("//cloudformation:mapping.bzl", "CloudformationMappingInfo")
load("//cloudformation:cfn_types.bzl", "CFN_TYPES")

# Sentinel prefixes for cross-resource references. The aggregator
# (cloudformation/private/stack_aggregator.py) deep-walks each
# shard's JSON values and rewrites these into the corresponding
# CFN intrinsic dicts. Picked `@@cfn:` because `@@` doesn't collide
# with any AWS string convention and stays grep-able in templates.
_REF_SENTINEL = "@@cfn:ref:"
_GETATT_SENTINEL = "@@cfn:getatt:"
_IMPORTVALUE_SENTINEL = "@@cfn:importvalue:"
_SUB_SENTINEL = "@@cfn:sub:"
_BASE64_SENTINEL = "@@cfn:base64:"
_FINDINMAP_SENTINEL = "@@cfn:findinmap:"

# Unit Separator (0x1f, octal \037 — Starlark has no \x escape) joins the three
# FindInMap args in the flat sentinel string (can't appear in a CFN map/key
# name). Kept in sync with stack_aggregator.py's _FINDINMAP_SEP.
_FINDINMAP_SEP = "\037"

def cfn_ref(resource_name):
    """Sentinel string the aggregator rewrites to `{"Ref": resource_name}`.

    Use in any spec-derived rule attr that takes a string CFN
    property. Example:

    ```python
    cloudformation_aws_s3_bucket_policy(
        name = "MyPolicy",
        Bucket = cfn_ref("MyBucket"),
        PolicyDocument = "...",
    )
    ```

    The aggregator fails the build if `resource_name` isn't one of
    the stack's resources — typos are caught at Bazel-build time
    rather than at AWS deploy time.

    Args:
      resource_name: the contributing rule's `label.name` (== the
        CFN logical id under `Resources` in the rendered template).

    Returns:
      A sentinel string that round-trips through JSON encoding into
      the shard the aggregator reads.
    """
    if not resource_name:
        fail("cfn_ref: resource_name must be non-empty")
    return _REF_SENTINEL + resource_name

def cfn_getatt(resource_name, attribute):
    """Sentinel string the aggregator rewrites to `{"Fn::GetAtt": [resource_name, attribute]}`.

    Use in any spec-derived rule attr that takes a string CFN
    property. Example:

    ```python
    cloudformation_aws_iam_policy(
        name = "ReadBucketPolicy",
        PolicyDocument = json.encode({
            "Statement": [{
                "Effect": "Allow",
                "Action": "s3:GetObject",
                "Resource": cfn_getatt("MyBucket", "Arn"),
            }],
        }),
    )
    ```

    Args:
      resource_name: the contributing rule's `label.name`.
      attribute: the CFN attribute exposed by that resource type
        (per the AWS docs — e.g. `Arn`, `DomainName`, `WebsiteURL`).

    Returns:
      A sentinel string the aggregator rewrites at template-render
      time.
    """
    if not resource_name:
        fail("cfn_getatt: resource_name must be non-empty")
    if not attribute:
        fail("cfn_getatt: attribute must be non-empty")
    if "." in resource_name or "." in attribute:
        fail("cfn_getatt: resource_name + attribute may not contain '.' (sentinel separator)")
    return _GETATT_SENTINEL + resource_name + "." + attribute

def cfn_base64(value):
    """Sentinel string the aggregator rewrites to `{"Fn::Base64": <value>}`.

    Wraps a plain string or another intrinsic (commonly `cfn_sub`) — e.g.
    EC2 `UserData`, which CloudFormation requires base64-encoded:

    ```python
    # LaunchTemplateData.UserData
    cfn_base64(cfn_sub("#!/bin/bash\\necho ${SomeParam}\\n"))
    ```

    The aggregator recurses into `value`, so a nested `cfn_sub` / `cfn_ref`
    rewrites correctly under the `Fn::Base64`.

    Args:
      value: the string to base64-encode at deploy time — a literal, or a
        `cfn_sub` / `cfn_ref` sentinel.

    Returns:
      A sentinel string the aggregator rewrites at template-render time.
    """
    if not value:
        fail("cfn_base64: value must be non-empty")
    return _BASE64_SENTINEL + value

def cfn_import_value(export_name):
    """Sentinel string the aggregator rewrites to `{"Fn::ImportValue": export_name}`.

    Pulls a value exported by a sibling stack's
    `cloudformation_output(... Export = "<name>")`. The aggregator
    can't validate that the export exists at Bazel-build time
    (it lives in a different stack, possibly not yet deployed); a
    typo surfaces at CFN deploy time as `No export named X found`.

    Args:
      export_name: the `Export` name set on the producing stack's
        output (region-globally unique, set by the operator).

    Returns:
      A sentinel string that round-trips through JSON encoding into
      the shard the aggregator reads.
    """
    if not export_name:
        fail("cfn_import_value: export_name must be non-empty")
    return _IMPORTVALUE_SENTINEL + export_name

def cfn_sub(template):
    """Sentinel string the aggregator rewrites to `{"Fn::Sub": template}`.

    Use `${ResourceName.Attribute}` / `${ParameterName}` /
    `${AWS::AccountId}` / etc. inside the template string; AWS
    substitutes them at deploy time. The aggregator does NOT
    validate the embedded names — CFN does, at deploy time.

    Currently the string-only form. The two-arg form
    `{"Fn::Sub": ["template", {var: val, ...}]}` is not yet
    surfaced; emit it as a literal dict in `json.encode(...)` if
    you need it.

    Args:
      template: the substitution template string (with `${...}`
        placeholders).

    Returns:
      A sentinel string that round-trips through JSON encoding.
    """
    if not template:
        fail("cfn_sub: template must be non-empty")
    return _SUB_SENTINEL + template

def cfn_find_in_map(map_name, top_level_key, second_level_key):
    """Sentinel string the aggregator rewrites to `{"Fn::FindInMap": [map_name, top_level_key, second_level_key]}`.

    Reads a value from a `cloudformation_mapping`. Because it's a string,
    it fits both scalar property attrs and `json.encode(...)` values.
    The keys may themselves be `cfn_ref(...)` sentinels (commonly
    `cfn_ref("Environment")` or `cfn_ref("AWS::Region")`) — the aggregator
    rewrites them. The aggregator fails the build if `map_name` isn't a
    mapping declared on the stack.

    ```python
    cfn_find_in_map("EnvironmentConfig", cfn_ref("Environment"), "RootDomain")
    ```

    Args:
      map_name: the `cloudformation_mapping` target's `label.name`.
      top_level_key: first-level key (literal or a `cfn_ref(...)`).
      second_level_key: second-level key (literal or a `cfn_ref(...)`).

    Returns:
      A sentinel string the aggregator rewrites at template-render time.
    """
    if not map_name or not top_level_key or not second_level_key:
        fail("cfn_find_in_map: map_name, top_level_key, and second_level_key must all be non-empty")
    for part in [map_name, top_level_key, second_level_key]:
        if _FINDINMAP_SEP in part:
            fail("cfn_find_in_map: args may not contain the sentinel separator")
    return _FINDINMAP_SENTINEL + map_name + _FINDINMAP_SEP + top_level_key + _FINDINMAP_SEP + second_level_key

# ─── Condition-function helpers ──────────────────────────────────────────────
#
# Unlike the `cfn_*` sentinels above, these return plain dicts — CFN condition
# functions take lists of operands, which don't fit a flat sentinel string.
# Use them inside `json.encode(...)` to build a `cloudformation_condition`'s
# `expression` (or an `Fn::If` in a property). Operands may be literals,
# `cfn_ref(...)` / `cfn_find_in_map(...)` sentinels, or nested helpers; the
# aggregator deep-walks and rewrites any sentinels.

def cfn_equals(a, b):
    """`{"Fn::Equals": [a, b]}` — true when `a` and `b` are equal."""
    return {"Fn::Equals": [a, b]}

def cfn_and(*conditions):
    """`{"Fn::And": [...]}` — true when all operand conditions are true (2–10)."""
    return {"Fn::And": list(conditions)}

def cfn_or(*conditions):
    """`{"Fn::Or": [...]}` — true when any operand condition is true (2–10)."""
    return {"Fn::Or": list(conditions)}

def cfn_not(condition):
    """`{"Fn::Not": [condition]}` — negation."""
    return {"Fn::Not": [condition]}

def cfn_if(condition_name, value_if_true, value_if_false):
    """`{"Fn::If": [condition_name, value_if_true, value_if_false]}`.

    `condition_name` is a `cloudformation_condition` target's `label.name`
    (a bare string — condition references aren't `Ref`s).
    """
    if not condition_name:
        fail("cfn_if: condition_name must be non-empty")
    return {"Fn::If": [condition_name, value_if_true, value_if_false]}

def _kind_id_from_shard(shard_basename, label_name):
    # Spec-derived rules name their shard
    # `<label.name>.<kind_id>.json`. Stripping the prefix +
    # `.json` suffix recovers the kind id which we look up in
    # CFN_TYPES to get the `AWS::Service::Resource` Type string.
    prefix = label_name + "."
    suffix = ".json"
    if not shard_basename.startswith(prefix) or not shard_basename.endswith(suffix):
        fail("cloudformation_stack: unexpected shard filename {} (expected {}<kind_id>{})".format(
            shard_basename,
            prefix,
            suffix,
        ))
    return shard_basename[len(prefix):-len(suffix)]

def _cloudformation_stack_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    args = ctx.actions.args()
    args.add("--output", output.path)
    if ctx.attr.description:
        args.add("--description", ctx.attr.description)

    inputs = []
    resource_names_seen = {}
    for dep in ctx.attr.resources:
        # Spec-derived rules expose their shard via DefaultInfo's
        # single file. We don't load the per-kind `*Info` provider
        # — there are 1500+ of them — so we lean on the filename
        # convention + the CFN_TYPES map.
        files = dep[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("cloudformation_stack: dep {} produced {} files (expected 1)".format(dep.label, len(files)))
        shard = files[0]
        # The contributing rule's label.name is the CFN logical id.
        # We approximate via the shard filename's `<label.name>.` prefix.
        # (Bazel doesn't expose dep label.name in a way that's robust
        # across alias targets; the filename is the authoritative
        # source the rule itself wrote.)
        # Find the first `.` to split label.name from kind_id.
        basename = shard.basename
        dot = basename.find(".")
        if dot < 0 or not basename.endswith(".json"):
            fail("cloudformation_stack: dep {} shard {} doesn't match `<name>.<kind_id>.json` convention".format(dep.label, basename))
        resource_name = basename[:dot]
        kind_id = _kind_id_from_shard(basename, resource_name)
        if kind_id not in CFN_TYPES:
            fail("cloudformation_stack: shard kind_id {} from {} is not in CFN_TYPES (regenerate cfn_types.bzl)".format(kind_id, dep.label))
        cfn_type = CFN_TYPES[kind_id]
        if resource_name in resource_names_seen:
            fail("cloudformation_stack: duplicate resource name {} (from {} and {})".format(
                resource_name,
                resource_names_seen[resource_name],
                dep.label,
            ))
        resource_names_seen[resource_name] = dep.label
        args.add("--resource={}={}={}".format(resource_name, cfn_type, shard.path))
        inputs.append(shard)

    for dep in ctx.attr.intrinsics:
        if CloudformationAwsCloudformationInitInfo in dep:
            info = dep[CloudformationAwsCloudformationInitInfo]
            args.add("--init={}={}".format(info.target_resource_name, info.json.path))
            inputs.append(info.json)
        elif CloudformationAwsCloudformationInterfaceInfo in dep:
            info = dep[CloudformationAwsCloudformationInterfaceInfo]
            args.add("--interface={}".format(info.json.path))
            inputs.append(info.json)
        else:
            fail("cloudformation_stack: intrinsics entry {} doesn't carry a known intrinsic provider".format(dep.label))

    parameter_names_seen = {}
    for dep in ctx.attr.parameters:
        if CloudformationParameterInfo not in dep:
            fail("cloudformation_stack: parameters entry {} is not a cloudformation_parameter".format(dep.label))
        info = dep[CloudformationParameterInfo]
        if info.name in parameter_names_seen:
            fail("cloudformation_stack: duplicate parameter name {} (from {} and {})".format(
                info.name,
                parameter_names_seen[info.name],
                dep.label,
            ))
        if info.name in resource_names_seen:
            fail("cloudformation_stack: name collision: {} declared as both a resource and a parameter".format(info.name))
        parameter_names_seen[info.name] = dep.label
        args.add("--parameter={}={}".format(info.name, info.json.path))
        inputs.append(info.json)

    output_names_seen = {}
    for dep in ctx.attr.outputs:
        if CloudformationOutputInfo not in dep:
            fail("cloudformation_stack: outputs entry {} is not a cloudformation_output".format(dep.label))
        info = dep[CloudformationOutputInfo]
        if info.name in output_names_seen:
            fail("cloudformation_stack: duplicate output name {} (from {} and {})".format(
                info.name,
                output_names_seen[info.name],
                dep.label,
            ))
        output_names_seen[info.name] = dep.label
        args.add("--output_decl={}={}".format(info.name, info.json.path))
        inputs.append(info.json)

    condition_names_seen = {}
    for dep in ctx.attr.conditions:
        if CloudformationConditionInfo not in dep:
            fail("cloudformation_stack: conditions entry {} is not a cloudformation_condition".format(dep.label))
        info = dep[CloudformationConditionInfo]
        if info.name in condition_names_seen:
            fail("cloudformation_stack: duplicate condition name {} (from {} and {})".format(
                info.name,
                condition_names_seen[info.name],
                dep.label,
            ))
        condition_names_seen[info.name] = dep.label
        args.add("--condition={}={}".format(info.name, info.json.path))
        inputs.append(info.json)

    mapping_names_seen = {}
    for dep in ctx.attr.mappings:
        if CloudformationMappingInfo not in dep:
            fail("cloudformation_stack: mappings entry {} is not a cloudformation_mapping".format(dep.label))
        info = dep[CloudformationMappingInfo]
        if info.name in mapping_names_seen:
            fail("cloudformation_stack: duplicate mapping name {} (from {} and {})".format(
                info.name,
                mapping_names_seen[info.name],
                dep.label,
            ))
        mapping_names_seen[info.name] = dep.label
        args.add("--mapping={}={}".format(info.name, info.json.path))
        inputs.append(info.json)

    # Attach `Condition:` to resources (aggregator validates the name against
    # the declared conditions). The keys are CFN logical ids (resource
    # `label.name`s); the values are condition `label.name`s.
    for res_name, cond_name in ctx.attr.resource_conditions.items():
        args.add("--resource_condition={}={}".format(res_name, cond_name))

    ctx.actions.run(
        executable = ctx.executable._aggregator,
        arguments = [args],
        inputs = inputs,
        outputs = [output],
        mnemonic = "CloudformationStack",
        progress_message = "Aggregating CFN stack %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([output]))]

cloudformation_stack = rule(
    implementation = _cloudformation_stack_impl,
    doc = "Aggregate typed-rule shards into one CFN template. Resource names = each contributing rule's `label.name` (so name targets PascalCase to satisfy CFN logical-id rules). Cross-resource refs work via `cfn_ref` / `cfn_getatt` Starlark helpers (above). Top-level Parameters / Outputs / Conditions / Mappings blocks are populated from the `parameters` / `outputs` / `conditions` / `mappings` attrs (see the sibling `.bzl` files). Gate a resource on a condition via `resource_conditions`. Cross-stack imports use `cfn_import_value`; `Fn::Sub` via `cfn_sub`; `Fn::FindInMap` via `cfn_find_in_map`; conditions via `cfn_equals` / `cfn_and` / `cfn_or` / `cfn_not` / `cfn_if`.",
    attrs = {
        "description": attr.string(
            doc = "CFN template `Description` field. Optional.",
        ),
        "resources": attr.label_list(
            doc = "Typed-rule targets from `defs.bzl`. Each contributes one entry under `Resources`, keyed by the target's `label.name`.",
            allow_files = False,
        ),
        "intrinsics": attr.label_list(
            doc = "`cloudformation_aws_cloudformation_init` / `_interface` targets from `intrinsics.bzl`. Init shards splice under their declared `target_resource_name`; Interface shards splice under the template-level `Metadata`.",
            allow_files = False,
        ),
        "parameters": attr.label_list(
            doc = "`cloudformation_parameter` targets from `parameter.bzl`. Each contributes one entry under the template's top-level `Parameters` block, keyed by the target's `label.name`. Reference from resource shards with `cfn_ref(\"<name>\")`.",
            allow_files = False,
            providers = [CloudformationParameterInfo],
        ),
        "outputs": attr.label_list(
            doc = "`cloudformation_output` targets from `output.bzl`. Each contributes one entry under the template's top-level `Outputs` block, keyed by the target's `label.name`. Set `Export` on an output to make it importable by sibling stacks via `cfn_import_value(\"<export-name>\")`.",
            allow_files = False,
            providers = [CloudformationOutputInfo],
        ),
        "conditions": attr.label_list(
            doc = "`cloudformation_condition` targets from `condition.bzl`. Each contributes one entry under the template's top-level `Conditions` block, keyed by the target's `label.name`. Reference from `resource_conditions`, a `cloudformation_output(Condition=...)`, or an `Fn::If` first arg.",
            allow_files = False,
            providers = [CloudformationConditionInfo],
        ),
        "mappings": attr.label_list(
            doc = "`cloudformation_mapping` targets from `mapping.bzl`. Each contributes one entry under the template's top-level `Mappings` block, keyed by the target's `label.name`. Read with `cfn_find_in_map(\"<name>\", <top_key>, <second_key>)`.",
            allow_files = False,
            providers = [CloudformationMappingInfo],
        ),
        "resource_conditions": attr.string_dict(
            doc = "Map of resource `label.name` -> condition `label.name`. Attaches a `Condition:` to that resource so it's created only when the condition holds. The condition must be declared in `conditions` (validated at build time).",
        ),
        "_aggregator": attr.label(
            default = "//cloudformation/private:stack_aggregator",
            executable = True,
            cfg = "exec",
        ),
    },
)
