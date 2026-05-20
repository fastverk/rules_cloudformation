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

Cross-resource references (`Ref` / `Fn::GetAtt`) and deploy
wrappers (`bazel run` driving `aws cloudformation deploy`) ride on
later phases.
"""

load(
    "//cloudformation:intrinsics.bzl",
    "CloudformationAwsCloudformationInitInfo",
    "CloudformationAwsCloudformationInterfaceInfo",
)
load("//cloudformation:cfn_types.bzl", "CFN_TYPES")

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
    doc = "Aggregate typed-rule shards into one CFN template. Phase-1 limitations: resource names = each contributing rule's `label.name` (so name targets PascalCase to satisfy CFN logical-id rules); no `Parameters` / `Outputs` / cross-resource refs yet.",
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
