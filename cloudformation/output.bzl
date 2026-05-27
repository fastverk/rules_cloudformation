"""`cloudformation_output` — declare a top-level CFN template Output.

Outputs surface values from a stack — resource ARNs, URLs,
generated names — for the AWS console UI, for `aws describe-stacks`
consumers, and (with `Export`) for cross-stack references via
`Fn::ImportValue`.

The output logical id is the rule's `label.name`. Match CFN's
logical-id rules: alphanumeric, PascalCase by convention.

Example:

```python
load("//cloudformation:output.bzl", "cloudformation_output")
load("//cloudformation:stack.bzl", "cfn_getatt")

cloudformation_output(
    name = "BucketArn",
    Value = cfn_getatt("MyBucket", "Arn"),
    Description = "ARN of the data bucket.",
    Export = "shared-data-bucket-arn",   # importable from sibling stacks
)
```

The other stack consumes via:

```python
cfn_import_value("shared-data-bucket-arn")
```
"""

CloudformationOutputInfo = provider(
    doc = "A CloudFormation template Output declaration. The stack aggregator collects these into the template's top-level `Outputs` block, keyed by the rule's `label.name`.",
    fields = {
        "name": "string: the output logical id (= the rule's `label.name`).",
        "json": "File: JSON shard with the Output's properties (Value, Description, Export, ...).",
    },
)

def _cloudformation_output_impl(ctx):
    if not ctx.attr.Value:
        fail("cloudformation_output({}): Value is required".format(ctx.label.name))

    payload = {"Value": ctx.attr.Value}
    if ctx.attr.Description:
        payload["Description"] = ctx.attr.Description
    if ctx.attr.Export:
        payload["Export"] = {"Name": ctx.attr.Export}
    if ctx.attr.Condition:
        payload["Condition"] = ctx.attr.Condition

    shard = ctx.actions.declare_file(ctx.label.name + ".cloudformation_output.json")
    ctx.actions.write(shard, json.encode(payload))
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationOutputInfo(name = ctx.label.name, json = shard),
    ]

cloudformation_output = rule(
    implementation = _cloudformation_output_impl,
    doc = "Declare a top-level CFN template Output. The rule's `label.name` is the output logical id. Plug into a `cloudformation_stack` via its `outputs` attr. Set `Export` to make the value importable from sibling stacks via `cfn_import_value(\"<export-name>\")`. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/outputs-section-structure.html.",
    provides = [CloudformationOutputInfo],
    attrs = {
        "Value": attr.string(
            doc = "The value to expose. Plain strings, `cfn_ref(...)`, `cfn_getatt(...)`, `cfn_sub(...)`, and `cfn_import_value(...)` all work — the aggregator rewrites sentinels at template-render time. Required.",
            mandatory = True,
        ),
        "Description": attr.string(
            doc = "Human-readable description shown alongside the output in the AWS console.",
        ),
        "Export": attr.string(
            doc = "If set, exports the value under this name (region-globally unique). Sibling stacks consume via `cfn_import_value(\"<export-name>\")`.",
        ),
        "Condition": attr.string(
            doc = "Name of a stack-level Condition (declared elsewhere) gating this output's emission. Optional.",
        ),
    },
)
