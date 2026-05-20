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
load("//cloudformation:cfn_types.bzl", "CFN_TYPES")

# Sentinel prefixes for cross-resource references. The aggregator
# (cloudformation/private/stack_aggregator.py) deep-walks each
# shard's JSON values and rewrites these into the corresponding
# CFN intrinsic dicts. Picked `@@cfn:` because `@@` doesn't collide
# with any AWS string convention and stays grep-able in templates.
_REF_SENTINEL = "@@cfn:ref:"
_GETATT_SENTINEL = "@@cfn:getatt:"

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
    doc = "Aggregate typed-rule shards into one CFN template. Resource names = each contributing rule's `label.name` (so name targets PascalCase to satisfy CFN logical-id rules). Cross-resource refs work via `cfn_ref` / `cfn_getatt` Starlark helpers (above). `Parameters` / `Outputs` template sections are deferred.",
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
        "_aggregator": attr.label(
            default = "//cloudformation/private:stack_aggregator",
            executable = True,
            cfg = "exec",
        ),
    },
)
