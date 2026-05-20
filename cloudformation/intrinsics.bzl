"""Hand-authored Bazel rules for CloudFormation metadata directives
that live outside the Resource Spec.

The Resource Specification covers ~1500 `AWS::Service::Resource`
types, surfaced via the spec-derived rules in
[`defs.bzl`](defs.bzl). Two CFN directives are *not* resources —
they are metadata blocks — so they don't fit that pipeline:

  * `AWS::CloudFormation::Init` — config-set tree attached to a
    resource's `Metadata`. `cfn-init` on the target instance
    interprets it to install packages, render files, run commands.
  * `AWS::CloudFormation::Interface` — top-level template
    `Metadata` block that groups Parameters into labelled sections
    for the AWS console UI.

Hand-written here because the set is finite (two), the schemas are
AWS-documented and stable, and the structures don't slot into the
property-bag-per-resource model the spec-derived codegen produces.
JSON-encoded attrs let typed values flow in via `json.encode(...)`
at the Bazel-load site without needing per-key attr enumeration of
deeply-nested + user-named config blocks.
"""

load("@rules_jsonschema//runtime:helpers.bzl", "parse_json_or_none", "strip_empty")

CloudformationAwsCloudformationInitInfo = provider(
    doc = "An AWS::CloudFormation::Init config-set tree. Shard JSON is the inner Init payload (configSets + named config blocks); the future stack aggregator splices it under the target resource's Metadata.",
    fields = {
        "target_resource_name": "string: name of the resource (under `Resources`) this Init attaches to via its `Metadata.AWS::CloudFormation::Init` key.",
        "json": "File: JSON shard with the Init payload.",
    },
)

CloudformationAwsCloudformationInterfaceInfo = provider(
    doc = "An AWS::CloudFormation::Interface metadata block. Shard JSON is the inner Interface payload (ParameterGroups + ParameterLabels); the future stack aggregator splices it under the template's top-level Metadata.",
    fields = {
        "json": "File: JSON shard with the Interface payload.",
    },
)

def _cloudformation_aws_cloudformation_init_impl(ctx):
    target_name = ctx.attr.target_resource_name or ctx.label.name
    config_sets = parse_json_or_none(ctx.attr.config_sets) or {}
    configs = parse_json_or_none(ctx.attr.configs) or {}
    # AWS::CloudFormation::Init payload layout: `configSets` (a map
    # of config-set-name → ordered list of config-block names)
    # sits alongside the named config blocks themselves at the same
    # level (not under a wrapper key). Merge in that shape here.
    payload = dict(configs)
    if config_sets:
        payload["configSets"] = config_sets
    payload = strip_empty(payload)
    shard = ctx.actions.declare_file(ctx.label.name + ".aws_cloudformation_init.json")
    ctx.actions.write(shard, json.encode(payload))
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationAwsCloudformationInitInfo(
            target_resource_name = target_name,
            json = shard,
        ),
    ]

cloudformation_aws_cloudformation_init = rule(
    implementation = _cloudformation_aws_cloudformation_init_impl,
    doc = "AWS::CloudFormation::Init metadata block — a config-set tree (configSets + named configs containing packages/files/commands/services) that cfn-init interprets at instance boot. Lives under the target resource's `Metadata.AWS::CloudFormation::Init` key in the rendered template. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-init.html.",
    provides = [CloudformationAwsCloudformationInitInfo],
    attrs = {
        "target_resource_name": attr.string(
            doc = "Name of the resource (under `Resources`) this Init applies to. Defaults to the rule's label name; the future stack aggregator uses this to find the target resource and splice the shard into its `Metadata`.",
        ),
        "config_sets": attr.string(
            doc = "JSON-encoded `configSets` dict. Maps a config-set name to an ordered list of config-block names. Example: `'{\"default\": [\"setup\", \"install\"]}'`. See the AWS docs for the configSets ordering + multi-set semantics.",
        ),
        "configs": attr.string(
            doc = "JSON-encoded dict of config-block-name → config-block. Each block can carry `packages`, `groups`, `users`, `sources`, `files`, `commands`, `services` keys. Refer to the AWS docs for the per-key schema.",
        ),
    },
)

def _cloudformation_aws_cloudformation_interface_impl(ctx):
    parameter_groups = parse_json_or_none(ctx.attr.parameter_groups) or []
    parameter_labels = parse_json_or_none(ctx.attr.parameter_labels) or {}
    payload = {}
    if parameter_groups:
        payload["ParameterGroups"] = parameter_groups
    if parameter_labels:
        payload["ParameterLabels"] = parameter_labels
    shard = ctx.actions.declare_file(ctx.label.name + ".aws_cloudformation_interface.json")
    ctx.actions.write(shard, json.encode(payload))
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationAwsCloudformationInterfaceInfo(json = shard),
    ]

cloudformation_aws_cloudformation_interface = rule(
    implementation = _cloudformation_aws_cloudformation_interface_impl,
    doc = "AWS::CloudFormation::Interface template-level metadata block — groups Parameters into ordered, labelled sections for the AWS console when a user launches the stack manually. Lives under the template's top-level `Metadata.AWS::CloudFormation::Interface` key. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-cfn-interface-section.html.",
    provides = [CloudformationAwsCloudformationInterfaceInfo],
    attrs = {
        "parameter_groups": attr.string(
            doc = "JSON-encoded list of `{\"Label\": {\"default\": STR}, \"Parameters\": [PARAM_NAME, ...]}` entries. Each entry becomes one labelled section in the console UI, in the listed order. Example: `'[{\"Label\": {\"default\": \"Network\"}, \"Parameters\": [\"VpcId\", \"SubnetIds\"]}]'`.",
        ),
        "parameter_labels": attr.string(
            doc = "JSON-encoded dict mapping a parameter name to `{\"default\": STR}`. Overrides the parameter's displayed name in the console UI. Example: `'{\"VpcId\": {\"default\": \"Which VPC?\"}}'`.",
        ),
    },
)
