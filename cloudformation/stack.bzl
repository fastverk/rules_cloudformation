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

load("//cloudformation:cfn_types.bzl", "CFN_TYPES")
load("//cloudformation:condition.bzl", "CloudformationConditionInfo")
load(
    "//cloudformation:intrinsics.bzl",
    "CloudformationAwsCloudformationInitInfo",
    "CloudformationAwsCloudformationInterfaceInfo",
)
load("//cloudformation:mapping.bzl", "CloudformationMappingInfo")
load("//cloudformation:output.bzl", "CloudformationOutputInfo")
load("//cloudformation:parameter.bzl", "CloudformationParameterInfo")

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

# Fn::Join has TWO sentinels, not one, because its second argument is either a
# list of values or a single thing that IS a list — and the two render
# differently. See `cfn_join` for the full story; the short version is that both
# forms reach the aggregator as a flat string, so nothing distinguishes them
# once encoded. Encoding the form in the prefix is the only place the
# information survives.
_JOIN_SENTINEL = "@@cfn:join:"
_JOIN_LISTREF_SENTINEL = "@@cfn:joinlistref:"

# Unit Separator (0x1f, octal \037 — Starlark has no \x escape) joins the three
# FindInMap args in the flat sentinel string (can't appear in a CFN map/key
# name). Kept in sync with stack_aggregator.py's _FINDINMAP_SEP.
_FINDINMAP_SEP = "\037"

# Record Separator (0x1e, octal \036) joins the delimiter + values inside a Join
# sentinel. Kept in sync with stack_aggregator.py's _JOIN_SEP.
#
# ⛔ DELIBERATELY NOT `_FINDINMAP_SEP`, and this is not a style choice. A
# `cfn_find_in_map(...)` nested in a join's value list is entirely legal, and it
# arrives carrying \037 INSIDE its own sentinel. If Join split on \037 too, that
# nested sentinel would be shredded into fragments — each of which then fails to
# match any prefix and renders as a literal string, so the template builds and
# the map lookup silently disappears. Two separate control characters keep the
# two encoding layers independent.
#
# Join-inside-Join is the case this does NOT rescue (both layers would use
# \036), so `cfn_join` rejects it outright rather than mis-splitting it.
_JOIN_SEP = "\036"

# The sentinels that can legitimately stand where `cfn_join`'s second argument
# is a single list-valued reference. Everything else in the sentinel set yields
# a STRING — `Fn::Sub`, `Fn::Base64` and `Fn::Join` itself always do — and CFN
# rejects `{"Fn::Join": [",", {"Fn::Sub": "..."}]}` at deploy with a template
# format error that names nothing useful. Cheaper to refuse it here.
_JOIN_LISTREF_ALLOWED = [
    _REF_SENTINEL,
    _GETATT_SENTINEL,
    _IMPORTVALUE_SENTINEL,
    _FINDINMAP_SENTINEL,
]

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

def cfn_join(delimiter, values):
    """Sentinel string the aggregator rewrites to `{"Fn::Join": [delimiter, <values>]}`.

    Concatenates values into ONE string at deploy time. Being a string, it fits
    anywhere the other sentinels do — a scalar property attr, a
    `cloudformation_output(Value = ...)`, a `json.encode(...)` payload.

    ⛔ THE REASON THIS EXISTS is that a CFN `Outputs.*.Value` must be a STRING,
    and several `Fn::GetAtt` attributes are LISTS. The canonical one is a
    delegated Route53 zone's nameservers:

    ```python
    cloudformation_output(
        name = "ZoneNameServers",
        Value = cfn_join(",", cfn_getatt("Zone", "NameServers")),
    )
    ```

    Without the join, that output renders as a bare `{"Fn::GetAtt": [...]}`,
    which builds cleanly, deploys, and then rolls the stack back with

        Template format error: Every Value member must be a string.

    — an error naming neither the output nor the attribute. Nothing upstream
    catches it: the typed rules check PROPERTY types, not output values, and
    the aggregator validates that a `cfn_getatt` names a real resource but has
    no notion of that attribute's type.

    ⭐ TWO FORMS, AND THE DIFFERENCE IS LOAD-BEARING. CFN's second argument is
    either a list of values, or a single thing that IS a list:

    ```python
    # Form 1 — an explicit list. Elements may be literals or sentinels.
    cfn_join("-", [cfn_ref("Environment"), "assets"])
    #  ->  {"Fn::Join": ["-", [{"Ref": "Environment"}, "assets"]]}

    # Form 2 — ONE sentinel that itself yields a list.
    cfn_join(",", cfn_getatt("Zone", "NameServers"))
    #  ->  {"Fn::Join": [",", {"Fn::GetAtt": ["Zone", "NameServers"]}]}
    ```

    ⚠ Passing form 2's argument as a one-element list is the mistake to avoid.
    `cfn_join(",", [cfn_getatt("Zone", "NameServers")])` renders
    `[",", [{"Fn::GetAtt": ...}]]`, which CFN reads as a list of ONE element
    that happens to be a list — not as a list-valued reference. It does not
    join the nameservers; it fails the same template format error the join was
    added to fix, and it looks correct in review.

    The form is decided HERE, by the type of `values`, and encoded in the
    sentinel prefix. It cannot be recovered later: both forms reach the
    aggregator as a flat string, with nothing left to infer from.

    Nested sentinels in form 1 are rewritten normally, so `cfn_ref`,
    `cfn_getatt`, `cfn_import_value` and `cfn_find_in_map` all compose. Two
    things do not, and fail here rather than silently:

    * A nested `cfn_join` — both layers would use the same separator, so the
      split would shred the inner one into fragments that render as literals.
      Build the inner string in Starlark instead, or emit a literal
      `{"Fn::Join": ...}` dict inside `json.encode(...)`.
    * A form-2 argument that is a literal or a string-valued sentinel
      (`cfn_sub` / `cfn_base64` / another join). Those are not lists, and CFN
      rejects them at deploy.

    Args:
      delimiter: literal string placed between values. May be `""` (the common
        case for building an ARN or a URL) — CFN requires a literal here, so a
        sentinel is not accepted.
      values: EITHER a list of strings (literals and/or sentinels, at least
        one), OR a single `cfn_ref` / `cfn_getatt` / `cfn_import_value` /
        `cfn_find_in_map` sentinel whose value is list-valued.

    Returns:
      A sentinel string the aggregator rewrites at template-render time.
    """
    if type(delimiter) != "string":
        fail("cfn_join: delimiter must be a string, got {}".format(type(delimiter)))
    if _JOIN_SEP in delimiter:
        fail("cfn_join: delimiter may not contain the sentinel separator")

    if type(values) == "list":
        # An empty list renders `{"Fn::Join": [d, []]}`, which evaluates to the
        # empty string — so a list comprehension that matched nothing produces
        # an empty property rather than an error. Refuse it; an intentional
        # empty string is `""`.
        if not values:
            fail("cfn_join: values list is empty (an empty join yields \"\" — pass \"\" directly if that is what you mean)")
        for i, v in enumerate(values):
            if type(v) != "string":
                fail("cfn_join: values[{}] must be a string, got {} (a dict — e.g. cfn_if(...) — can't ride a flat sentinel; emit a literal {{\"Fn::Join\": ...}} inside json.encode(...) instead)".format(i, type(v)))
            if _JOIN_SEP in v:
                fail("cfn_join: values[{}] may not contain the sentinel separator (a nested cfn_join is not supported — see the docstring)".format(i))
        return _JOIN_SENTINEL + delimiter + _JOIN_SEP + _JOIN_SEP.join(values)

    if type(values) == "string":
        if not values:
            fail("cfn_join: values must be non-empty")
        for prefix in _JOIN_LISTREF_ALLOWED:
            if values.startswith(prefix):
                return _JOIN_LISTREF_SENTINEL + delimiter + _JOIN_SEP + values
        fail(
            "cfn_join: a single (non-list) values argument must be a cfn_ref / cfn_getatt / " +
            "cfn_import_value / cfn_find_in_map sentinel whose value is list-valued, got {}. ".format(repr(values)) +
            "A literal string is not a list, and cfn_sub / cfn_base64 / cfn_join yield strings — " +
            "CFN rejects all of them as Fn::Join's second argument. Did you mean a one-element " +
            "list, i.e. cfn_join(delim, [value])?",
        )

    fail("cfn_join: values must be a list of strings or a single list-valued sentinel string, got {}".format(type(values)))

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

    # Attach `DependsOn:` for ordering CFN cannot infer from a Ref/GetAtt edge. The
    # aggregator validates every name against the stack's resources — see its comment for
    # the IGW-attachment race this exists to remove.
    for res_name, deps in ctx.attr.resource_depends_on.items():
        args.add("--resource_depends_on={}={}".format(res_name, deps))

    # Attach `DeletionPolicy:` / `UpdateReplacePolicy:`. Like Condition and DependsOn
    # above, these are SIBLINGS of `Properties`, not properties — the typed shards carry
    # only the Properties payload, so resource-level attributes have always been the
    # aggregator's job.
    #
    # ⛔ WITHOUT DeletionPolicy A STACK CAN NEVER ADOPT AN EXISTING RESOURCE. CloudFormation
    # REQUIRES it on every resource in a `--change-set-type IMPORT`, so `resource import` is
    # simply unavailable to stacks built with these rules — which is what blocked bringing
    # three hand-created ECR mirror repositories under management.
    #
    # ⚠ AND THE SECOND CONSEQUENCE IS LIVE, NOT HYPOTHETICAL: measured on the deployed
    # `tbzl-build-plane-ecr`, 0 of 14 resources carried a DeletionPolicy, so a stack delete
    # or a failed create-replace would have destroyed the container registry the whole build
    # plane pulls from. The hand-authored YAML stack next door had `Retain` on 32 of 32 —
    # same estate, same intent, opposite outcome, purely because one author could express it.
    for res_name, policy in ctx.attr.resource_deletion_policies.items():
        args.add("--resource_deletion_policy={}={}".format(res_name, policy))
    for res_name, policy in ctx.attr.resource_update_replace_policies.items():
        args.add("--resource_update_replace_policy={}={}".format(res_name, policy))

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
    doc = "Aggregate typed-rule shards into one CFN template. Resource names = each contributing rule's `label.name` (so name targets PascalCase to satisfy CFN logical-id rules). Cross-resource refs work via `cfn_ref` / `cfn_getatt` Starlark helpers (above). Top-level Parameters / Outputs / Conditions / Mappings blocks are populated from the `parameters` / `outputs` / `conditions` / `mappings` attrs (see the sibling `.bzl` files). Gate a resource on a condition via `resource_conditions`. Cross-stack imports use `cfn_import_value`; `Fn::Sub` via `cfn_sub`; `Fn::FindInMap` via `cfn_find_in_map`; `Fn::Join` via `cfn_join` (which is what turns a list-valued `cfn_getatt` into something a string-typed slot such as an Output `Value` will accept); conditions via `cfn_equals` / `cfn_and` / `cfn_or` / `cfn_not` / `cfn_if`.",
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
        "resource_depends_on": attr.string_dict(
            doc = "Map of resource `label.name` -> comma-separated resource `label.name`s it must be created after. Emits `DependsOn:`. Only needed where the ordering is real but no value flows between the resources, so CFN cannot infer it from a `cfn_ref`/`cfn_getatt` edge — canonically `AWS::EC2::Route` with a `GatewayId`, which AWS documents as REQUIRING a dependency on the `AWS::EC2::VPCGatewayAttachment` (both merely Ref the gateway, so neither depends on the other, and the route can be created first and fail). Every name is validated against the stack's resources at build time. A single dependency renders as a bare string, several as a sorted list.",
        ),
        "resource_deletion_policies": attr.string_dict(
            doc = "Map of resource `label.name` -> `Retain` | `Delete` | `Snapshot` | `RetainExceptOnCreate`. Emits `DeletionPolicy:` as a sibling of `Properties`. Two reasons to reach for it: CloudFormation REQUIRES a DeletionPolicy on every resource in a `resource import`, so without this a stack can never adopt existing infrastructure; and `Retain` is what stops a stack delete taking a data store, registry or hosted zone with it. Unset means absent from the template, which is CFN's own default (`Delete`) — deliberately NOT defaulted to `Retain` here, so rendered output is byte-identical for stacks that do not opt in and the semantics match the platform rather than this rule's opinion. ⚠ `Snapshot` is only valid on resource types that support snapshots; it is accepted here for any type and CloudFormation rejects the mismatch at create, loudly and immediately. Restricting per type would need the generator to know which types qualify.",
        ),
        "resource_update_replace_policies": attr.string_dict(
            doc = "Map of resource `label.name` -> `Retain` | `Delete` | `Snapshot`. Emits `UpdateReplacePolicy:`. Governs the OTHER way a resource disappears: an update that REPLACES it (a create-replace deletes the old one), which `DeletionPolicy` alone does not cover and which stack-level termination protection does not cover either. Same unset semantics and same `Snapshot` caveat as `resource_deletion_policies`.",
        ),
        "_aggregator": attr.label(
            default = "//cloudformation/private:stack_aggregator",
            executable = True,
            cfg = "exec",
        ),
    },
)
