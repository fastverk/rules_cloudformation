# rules_cloudformation

Bazel rules for AWS CloudFormation templates — schema-derived typed
Bazel rules via [`rules_jsonschema`](https://github.com/fastverk/rules_jsonschema),
plus a Java-based linter via [`rules_java`](https://github.com/bazelbuild/rules_java).
Each CFN resource type becomes a typed Bazel rule with one `attr.*`
per JSON Schema property.

The user-facing Starlark surface mirrors the
[aws-cloudformation/cloudformation-template-schema](https://github.com/aws-cloudformation/cloudformation-template-schema)
**exhaustively** — every property the schema accepts is a typed Bazel
`attr.*`. There's no hand-curated subset and no allowlist of deferred
fields. Drift is impossible by construction:

- The canonical schema is fetched on-demand from
  `aws-cloudformation/cloudformation-template-schema` at a commit +
  sha256 pinned in `cloudformation/private/extensions.bzl`.
- `rules_jsonschema`'s `jsonschema_starlark_codegen` emits
  `cloudformation/cloudformation_rules.bzl` — one `rule()` per
  `AWS::*` resource type definition in the schema, typed `attr.*` per
  property.
- A small Rust `cfn-gen` binary decodes per-target JSON shards into
  the typed resource model (`#[serde(deny_unknown_fields)]` rejects
  anything the schema doesn't declare) and emits a canonical
  `template.yaml`.
- The Java linter (port of cfn-lint patterns, built with `rules_java`)
  runs after rendering and reports semantic issues the schema alone
  cannot express (e.g. cross-property constraints, recommended-name
  conventions).

The hand-written part of the repo is small and scoped to things the
schema can't describe: graph aggregation, cross-stack reference
resolution, and `bazel run` wrappers around `aws cloudformation
deploy`. Codegen goes through rules_jsonschema's plugin contract —
see that repo's
[`plugin_contract.md`](https://github.com/fastverk/rules_jsonschema/blob/main/jsonschema/plugin_contract.md)
if you want to swap a plugin for one of your own.

## Status: v0.1.0

What ships:

- **Schema fetch** — `cfn_schemas_extension` (in
  `cloudformation/private/extensions.bzl`) `http_file`s
  per-resource AWS CFN schemas, sha256-pinned. v0.1 pins one
  resource type (`AWS::S3::Bucket`); v0.2 fans out the list via a
  `cfn_schemas.bundle(resources = [...])` tag class so consumers
  opt into the resource set they care about.
- **Codegen pipeline** — `rules_jsonschema`'s
  `jsonschema_starlark_codegen` produces
  `cloudformation/aws_s3_bucket.bzl` from the upstream schema.
  Committed + gated by a `diff_test` so CI fails on drift between
  the upstream schema and the committed `.bzl`.
- **`cloudformation_aws_s3_bucket`** — typed Bazel rule, one
  `attr.*` per JSON-Schema property (30 attrs), emits a JSON
  shard ready for a future `cloudformation_stack` aggregator.
  Re-exported from `//cloudformation:defs.bzl`.
- **End-to-end smoke** (`examples/smoke/`) — declares an S3 bucket
  + a byte-stability diff_test on the emitted shard. Green.

> Note on the schema source: the original design pinned
> `aws-cloudformation/cloudformation-template-schema`, but
> `Schema.template` there is a Mustache template, not literal
> JSON. v0.1 pivots to the AWS per-resource endpoint at
> `https://schema.cloudformation.us-east-1.amazonaws.com/`. See
> [`docs/SCHEMA_SOURCE.md`](docs/SCHEMA_SOURCE.md).

Deferred to v0.2 / v0.3 (see [docs/ROADMAP.md](docs/ROADMAP.md)):

- Bundle tag class — opt into N resource types in one
  MODULE.bazel call.
- `cloudformation_stack` aggregator (collects shards into one
  `template.yaml` via a Rust `cfn-gen` binary).
- `cloudformation_resource_ref` for cross-stack refs (resolves
  stack outputs at build time, like
  `docker_compose_oci_image_ref`).
- `cloudformation_up` / `_down` `bazel run` wrappers around
  `aws cloudformation deploy` / `delete-stack`.
- Java linter port of cfn-lint patterns.

## Planned architecture

Mirrors [`rules_docker_compose`](https://github.com/fastverk/rules_docker_compose):

- **Hand-written rules** (will be re-exported by
  `cloudformation/defs.bzl`):
  - `cloudformation_stack` — aggregator. Collects per-target
    resource/parameter/output/mapping shards from `deps` and renders
    one canonical `template.yaml`. Analogous to `docker_compose`.
  - `cloudformation_resource_ref` — resolves a cross-stack `Ref` /
    `Fn::ImportValue` / stack-output target at build time and
    overrides a referenced resource property in the rendered output.
    Analogous to `docker_compose_oci_image_ref`, which resolves OCI
    digests into a service's `image:`.
  - `cloudformation_up` / `cloudformation_down` — `bazel run`
    wrappers around `aws cloudformation deploy` and
    `aws cloudformation delete-stack`. Analogous to
    `docker_compose_up` / `_down`.

- **Schema-derived rules** (generated, committed, `diff_test`-gated):
  one `cloudformation_<resource_type>` rule per `AWS::*` resource
  type, generated from the official CFN schema via
  `jsonschema_starlark_codegen`. Examples:
  `cloudformation_aws_s3_bucket`, `cloudformation_aws_lambda_function`,
  `cloudformation_aws_ec2_instance`. The full set is ~1000+ rules.
  See [docs/SCHEMA_SOURCE.md](docs/SCHEMA_SOURCE.md) for how the
  schema's `AWS::*` type definitions map to Starlark rules.

- **Java linter** — port of cfn-lint–style validation rules,
  packaged as a `java_binary` via `rules_java`. Runs over the
  rendered `template.yaml` at test time. Why Java: the upstream
  schema repo is itself a Maven project, so the schema's intrinsic
  function tables and reference data are already in Java; reusing
  them avoids a parallel reimplementation.

- **Refs + labels** — every shard produced by a schema-derived rule
  emits a `CloudformationResourceInfo` provider carrying its logical
  ID, type, and the labels of any resources it references.
  `cloudformation_stack` walks the provider graph to validate that
  every `Ref` resolves inside the stack (or is satisfied by a
  `cloudformation_resource_ref` shard).

## Planned schema source

The canonical schema will be fetched via `http_archive` from
[aws-cloudformation/cloudformation-template-schema](https://github.com/aws-cloudformation/cloudformation-template-schema)
at a pinned commit + sha256. That repo builds a single
`Schema.template` master schema describing every `AWS::*` resource
type with full property typing.

An alternative source — the per-region service endpoint
`https://schema.cloudformation.us-east-1.amazonaws.com/` — exposes
per-resource-type schemas but isn't a stable, content-addressable
artifact. The curated GitHub repo is more reproducible. See
[docs/SCHEMA_SOURCE.md](docs/SCHEMA_SOURCE.md) for the full tradeoff
discussion.

## Install

`.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/fastverk/bazel-registry/main/
common --registry=https://bcr.bazel.build/
```

`MODULE.bazel`:

```python
bazel_dep(name = "rules_cloudformation", version = "0.1.0")
```

`rules_jsonschema`, `rules_java`, and (transitively) a Rust toolchain
will be pulled in once the v0.1 codegen pipeline lands.

## License

MIT.
