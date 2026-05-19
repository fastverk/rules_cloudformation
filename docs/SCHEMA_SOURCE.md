# Schema source

Where `rules_cloudformation`'s typed rules ultimately come from.

## Choice (v0.1)

We fetch the per-resource-type JSON Schemas AWS publishes at
`https://schema.cloudformation.us-east-1.amazonaws.com/<filename>.json`
via `http_file`, pinning each by its sha256. One Bazel repo per
resource type (`@aws_cfn_aws_s3_bucket` and so on), one
`jsonschema_starlark_codegen` invocation per repo, one committed
`.bzl` per resource type. Same diff_test + write_source_files
cascade as `rules_docker_compose`.

### Why not `aws-cloudformation/cloudformation-template-schema`?

The design doc this file replaces pinned that repo. It turns out
`Schema.template` in there is a Mustache template with
`{{{draft}}}` / `{{{intrinsics}}}` / `{{{resources}}}` placeholders —
not a literal JSON Schema. Assembling it into a consumable artifact
requires running the upstream Java assembler (`pom.xml` builds a
shaded jar). Doable but a lot of moving parts for v0.1; pivoted
to the per-resource AWS endpoint which already publishes the
expanded JSON Schemas.

Re-evaluate in v0.3 when the linter pulls in `rules_java` anyway —
at that point running the assembler in-Bazel is one more
java_binary target away.

### Alternatives considered

| Source | Why not chosen |
|---|---|
| `aws-cloudformation/cloudformation-template-schema` (Mustache `Schema.template`) | Needs upstream Java assembler. Revisit in v0.3 when rules_java enters the deps anyway. |
| `aws-cloudformation/cloudformation-cli` registry schemas | Individual JSON schemas exist but the canonical *combined* schema isn't published. Same end result as the AWS endpoint, more indirection. |
| Hand-curated subset | rules_jsonschema's whole point is avoiding drift between hand-written rules and upstream. Hard-no. |

## Pin

Pins live in
[`cloudformation/private/extensions.bzl`](../cloudformation/private/extensions.bzl)
as a `_PINNED_SCHEMAS` dict mapping filename → sha256:

```python
_PINNED_SCHEMAS = {
    "aws-s3-bucket.json": "306c17eac19e62159bdeaa872af1fe85b28e0cfd43d955d35765182b3904f4ab",
    # v0.2 fans out via the cfn_schemas.bundle tag class
}
```

Adding a resource type is four lines:

```sh
curl -fsSL -o aws-foo-bar.json https://schema.cloudformation.us-east-1.amazonaws.com/aws-foo-bar.json
shasum -a 256 aws-foo-bar.json                      # drop into _PINNED_SCHEMAS
# Add a use_repo() entry in MODULE.bazel for @aws_cfn_aws_foo_bar
# Add a jsonschema_starlark_codegen + write_source_files entry in //cloudformation:BUILD.bazel
bazel run //cloudformation:update                   # regenerate the .bzl
```

## Upstream stability

The AWS endpoint is a live URL, not a content-addressable artifact.
`sha256` pinning gives us reproducibility regardless: a re-fetch
either succeeds with the same bytes or fails the build with a hash
mismatch. The `_PINNED_SCHEMAS` dict is the source of truth for
which schemas this repo claims to track at a given version.

## Path to ~1200 resource types

v0.1 covers `AWS::S3::Bucket` as a codegen smoke. v0.2 lifts the
hard-coded list into a tag class:

```python
cfn_schemas = use_extension(
    "@rules_cloudformation//cloudformation/private:extensions.bzl",
    "cfn_schemas_extension",
)
cfn_schemas.bundle(
    resources = ["AWS::S3::Bucket", "AWS::Lambda::Function", ...],
)
```

so consumers opt into the resource set they care about — declaring
1200 typed Bazel rules per consumer when they use 10 is wasted
analysis time. Bundling lands in v0.2 (see
[`ROADMAP.md`](ROADMAP.md)).
