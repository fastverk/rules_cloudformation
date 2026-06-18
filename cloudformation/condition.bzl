"""`cloudformation_condition` — declare a top-level CFN template Condition.

Conditions gate whether resources / outputs are created (and feed
`Fn::If`), based on parameters or mappings evaluated at deploy time.
The condition logical id is the rule's `label.name`.

The `expression` is the condition function as JSON — build it with the
`cfn_equals` / `cfn_and` / `cfn_or` / `cfn_not` helpers (from
`stack.bzl`), which return plain dicts, and embed `cfn_ref(...)` /
`cfn_find_in_map(...)` for the dynamic operands (the stack aggregator
rewrites those sentinels at render time):

```python
load("//cloudformation:condition.bzl", "cloudformation_condition")
load("//cloudformation:stack.bzl", "cfn_equals", "cfn_ref")

cloudformation_condition(
    name = "IsProd",
    expression = json.encode(cfn_equals(cfn_ref("Environment"), "production")),
)
```

Reference the condition by its `label.name` from a stack's
`resource_conditions` / a `cloudformation_output(Condition = ...)` / an
`Fn::If` first arg.
"""

CloudformationConditionInfo = provider(
    doc = "A CloudFormation template Condition declaration. The stack aggregator collects these into the template's top-level `Conditions` block, keyed by the rule's `label.name`.",
    fields = {
        "name": "string: the condition logical id (= the rule's `label.name`).",
        "json": "File: JSON shard with the condition function expression.",
    },
)

def _cloudformation_condition_impl(ctx):
    if not ctx.attr.expression:
        fail("cloudformation_condition({}): expression is required".format(ctx.label.name))

    shard = ctx.actions.declare_file(ctx.label.name + ".cloudformation_condition.json")
    ctx.actions.write(shard, ctx.attr.expression)
    return [
        DefaultInfo(files = depset([shard])),
        CloudformationConditionInfo(name = ctx.label.name, json = shard),
    ]

cloudformation_condition = rule(
    implementation = _cloudformation_condition_impl,
    doc = "Declare a top-level CFN template Condition. The rule's `label.name` is the condition logical id. Plug into a `cloudformation_stack` via its `conditions` attr. See https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/conditions-section-structure.html.",
    provides = [CloudformationConditionInfo],
    attrs = {
        "expression": attr.string(
            mandatory = True,
            doc = "The condition function as JSON (`json.encode(...)`). Build it " +
                  "with `cfn_equals` / `cfn_and` / `cfn_or` / `cfn_not` and embed " +
                  "`cfn_ref(...)` / `cfn_find_in_map(...)` for dynamic operands — " +
                  "the aggregator rewrites those sentinels at render time.",
        ),
    },
)
