"""`cloudformation_parameter` — declare a top-level CFN template Parameter.

The Resource Spec doesn't cover the template's `Parameters` block
(it's a CFN structural directive, not a resource). This rule fills
that gap: one `cloudformation_parameter` per top-level Parameter,
collected into a stack via the `parameters` attr of
`cloudformation_stack`.

The parameter logical id is the rule's `label.name` (consistent
with how resources are keyed). Match CFN's logical-id rules:
alphanumeric, PascalCase by convention.

Example:

```python
load("//cloudformation:parameter.bzl", "cloudformation_parameter")

cloudformation_parameter(
    name = "VpcId",
    Type = "AWS::EC2::VPC::Id",
    Description = "VPC the stack runs in.",
)

cloudformation_parameter(
    name = "InstanceType",
    Type = "String",
    Default = "t3.micro",
    AllowedValues = json.encode(["t3.micro", "t3.small", "t3.medium"]),
    Description = "Compute size for the web tier.",
)
```

Then on the stack:

```python
cloudformation_stack(
    name = "my_stack",
    parameters = [":VpcId", ":InstanceType"],
    resources = [...],
)
```

Reference parameters from resources with `cfn_ref("VpcId")` — the
same helper works for params and resources because CFN's `Ref`
intrinsic is overloaded.
"""

load("@rules_jsonschema//runtime:helpers.bzl", "parse_json_or_none", "strip_empty")

CloudformationParameterInfo = provider(
    doc = "A CloudFormation template Parameter declaration. The stack aggregator collects these into the template's top-level `Parameters` block, keyed by the rule's `label.name`.",
    fields = {
        "name": "string: the parameter logical id (= the rule's `label.name`).",
        "json": "File: JSON shard with the Parameter's properties (Type, Description, Default, ...).",
    },
)

# Per the CFN Parameters spec, these are the allowed property keys.
# Listed here so a typo on a non-existent key fails at Bazel-load
# time rather than at AWS-deploy time.
_ALLOWED_TYPES = [
    "String",
    "Number",
    "List<Number>",
    "CommaDelimitedList",
    # AWS-specific parameter types — the spec has many; we accept any
    # string starting with "AWS::" via the prefix check in _impl.
]

def _cloudformation_parameter_impl(ctx):
    if not ctx.attr.Type:
        fail("cloudformation_parameter({}): Type is required".format(ctx.label.name))
    type_ok = ctx.attr.Type in _ALLOWED_TYPES or ctx.attr.Type.startswith("AWS::") or ctx.attr.Type.startswith("List<AWS::")
    if not type_ok:
        fail("cloudformation_parameter({}): unknown Type {!r}. Expected one of {} or an AWS::… SSM-style type.".format(
            ctx.label.name,
            ctx.attr.Type,
            _ALLOWED_TYPES,
        ))

    payload = {"Type": ctx.attr.Type}
    if ctx.attr.Description:
        payload["Description"] = ctx.attr.Description
    if ctx.attr.Default:
        payload["Default"] = ctx.attr.Default
    if ctx.attr.NoEcho:
        # CFN expects a bool; accept the strings "true"/"false" at
        # the attr boundary (string-typed attrs are easier to default
        # to "no value" than booleans).
        if ctx.attr.NoEcho not in ("true", "false"):
            fail("cloudformation_parameter({}): NoEcho must be \"true\" or \"false\"".format(ctx.label.name))
        payload["NoEcho"] = ctx.attr.NoEcho == "true"
    if ctx.attr.AllowedPattern:
        payload["AllowedPattern"] = ctx.attr.AllowedPattern
    if ctx.attr.ConstraintDescription:
        payload["ConstraintDescription"] = ctx.attr.ConstraintDescription
    if ctx.attr.MinLength:
        payload["MinLength"] = int(ctx.attr.MinLength)
    if ctx.attr.MaxLength:
        payload["MaxLength"] = int(ctx.attr.MaxLength)
    if ctx.attr.MinValue:
        payload["MinValue"] = int(ctx.attr.MinValue)
    if ctx.attr.MaxValue:
        payload["MaxValue"] = int(ctx.attr.MaxValue)
    allowed_values = parse_json_or_none(ctx.attr.AllowedValues)
    if allowed_values:
        payload["AllowedValues"] = allowed_values

    payload = strip_empty(payload)
    shard = ctx.actions.declare_file(ctx.label.name + ".cloudformation_parameter.json")
    ctx.actions.write(shard, json.encode(payload))
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationParameterInfo(name = ctx.label.name, json = shard),
    ]

cloudformation_parameter = rule(
    implementation = _cloudformation_parameter_impl,
    doc = "Declare a top-level CFN template Parameter. The rule's `label.name` is the parameter logical id (alphanumeric, PascalCase by convention). Plug into a `cloudformation_stack` via its `parameters` attr; reference from resources with `cfn_ref(\"<name>\")`. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/parameters-section-structure.html.",
    provides = [CloudformationParameterInfo],
    attrs = {
        "Type": attr.string(
            doc = "Parameter type. One of `String`, `Number`, `List<Number>`, `CommaDelimitedList`, or any `AWS::…` / `List<AWS::…>` SSM-style type. Required.",
            mandatory = True,
        ),
        "Description": attr.string(
            doc = "Human-readable description shown in the AWS console UI.",
        ),
        "Default": attr.string(
            doc = "Default value used when the parameter isn't overridden at deploy time.",
        ),
        "AllowedValues": attr.string(
            doc = "JSON-encoded list of permitted values, e.g. `'[\"a\", \"b\"]'`. Optional.",
        ),
        "AllowedPattern": attr.string(
            doc = "Regex the value must match (`String` / `CommaDelimitedList` types only).",
        ),
        "ConstraintDescription": attr.string(
            doc = "Error message shown when the value violates `AllowedPattern` / `AllowedValues` / `Min/Max…`.",
        ),
        "MinLength": attr.string(
            doc = "Minimum string length (`String` type only). Passed as string for default-elidability; parsed as int.",
        ),
        "MaxLength": attr.string(
            doc = "Maximum string length.",
        ),
        "MinValue": attr.string(
            doc = "Minimum numeric value (`Number` type only).",
        ),
        "MaxValue": attr.string(
            doc = "Maximum numeric value.",
        ),
        "NoEcho": attr.string(
            doc = "If `\"true\"`, mask the value in stack-event output (use for secrets). Default `\"false\"`.",
            values = ["", "true", "false"],
        ),
    },
)
