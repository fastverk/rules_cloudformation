"""`cloudformation_mapping` — declare a top-level CFN template Mapping.

A Mapping is a fixed two-level lookup table (`Map[TopKey][SecondKey] =
Value`) resolved at deploy time via `Fn::FindInMap`. The classic use is
per-environment / per-region config. The mapping logical id is the
rule's `label.name`.

```python
load("//cloudformation:mapping.bzl", "cloudformation_mapping")
load("//cloudformation:stack.bzl", "cfn_find_in_map", "cfn_ref")

cloudformation_mapping(
    name = "EnvironmentConfig",
    mapping = json.encode({
        "development": {"RootDomain": "savvifi.dev"},
        "production": {"RootDomain": "savvifi.com"},
    }),
)

# read it from a resource property:
#   cfn_find_in_map("EnvironmentConfig", cfn_ref("Environment"), "RootDomain")
```
"""

CloudformationMappingInfo = provider(
    doc = "A CloudFormation template Mapping declaration. The stack aggregator collects these into the template's top-level `Mappings` block, keyed by the rule's `label.name`.",
    fields = {
        "name": "string: the mapping logical id (= the rule's `label.name`).",
        "json": "File: JSON shard with the two-level mapping table.",
    },
)

def _cloudformation_mapping_impl(ctx):
    if not ctx.attr.mapping:
        fail("cloudformation_mapping({}): mapping is required".format(ctx.label.name))

    shard = ctx.actions.declare_file(ctx.label.name + ".cloudformation_mapping.json")
    ctx.actions.write(shard, ctx.attr.mapping)
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationMappingInfo(name = ctx.label.name, json = shard),
    ]

cloudformation_mapping = rule(
    implementation = _cloudformation_mapping_impl,
    doc = "Declare a top-level CFN template Mapping (a two-level lookup table). The rule's `label.name` is the mapping logical id. Plug into a `cloudformation_stack` via its `mappings` attr; read with `cfn_find_in_map(\"<name>\", <top_key>, <second_key>)`. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/mappings-section-structure.html.",
    provides = [CloudformationMappingInfo],
    attrs = {
        "mapping": attr.string(
            mandatory = True,
            doc = "The two-level mapping table as JSON (`json.encode({top: {key: value}})`).",
        ),
    },
)
