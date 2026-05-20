"""`cfn_overlay_descriptions` — enrich an assembler-derived JSON
Schema with `description` fields from one or more AWS per-resource
endpoint schemas.

The upstream Java assembler emits URL-only `description` fields
on attrs. AWS's per-resource endpoint schemas at
`https://schema.cloudformation.us-east-1.amazonaws.com/` carry
rich prose for every property. This rule layers them on top by
running `overlay_descriptions.py` at build time:

```python
load("//cloudformation/private:overlay.bzl", "cfn_overlay_descriptions")

cfn_overlay_descriptions(
    name = "storage_with_docs",
    assembled = ":assembled_storage",
    endpoints = [
        "@cfn_endpoint_aws_s3_bucket//file:aws-s3-bucket.json",
    ],
)
```

The output is a single `<name>.json` that downstream
`jsonschema_starlark_codegen` consumes the same way it would the
raw assembled schema — the only difference is richer attr docs in
the generated typed rules.

Endpoints for resources the assembled schema doesn't know about
are silently skipped (with stderr diagnostic). Adding overlay
coverage for a new resource: pin its endpoint schema in
`cloudformation/private/extensions.bzl` and add it to the
`endpoints` list above.
"""

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    args = ctx.actions.args()
    args.add("--assembled", ctx.file.assembled)
    args.add_all(ctx.files.endpoints, before_each = "--endpoints")
    args.add("--output", out)
    ctx.actions.run(
        executable = ctx.executable._overlay,
        arguments = [args],
        inputs = depset([ctx.file.assembled] + ctx.files.endpoints),
        outputs = [out],
        mnemonic = "CfnOverlayDescriptions",
        progress_message = "cfn overlay descriptions %s (%d endpoint(s))" % (
            ctx.label,
            len(ctx.files.endpoints),
        ),
    )
    return [DefaultInfo(files = depset([out]))]

cfn_overlay_descriptions = rule(
    implementation = _impl,
    attrs = {
        "assembled": attr.label(
            allow_single_file = [".json"],
            mandatory = True,
            doc = "The assembler-derived JSON Schema (typically the " +
                  "output of `cfn_assemble`).",
        ),
        "endpoints": attr.label_list(
            allow_files = [".json"],
            doc = "AWS per-resource endpoint schemas. Each provides " +
                  "rich `description` text for one resource type. " +
                  "Endpoints that don't match a resource in the " +
                  "assembled schema are silently skipped.",
        ),
        "_overlay": attr.label(
            default = "//cloudformation/private:overlay_descriptions",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Layer AWS-endpoint property descriptions onto an " +
          "assembler-derived JSON Schema.",
)
