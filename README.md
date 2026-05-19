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

- **Schema source** — the upstream Java assembler
  (`aws.cfn.codegen.json.Main` from
  `aws-cloudformation/cloudformation-template-schema`) is built and
  run at build time against a sha-pinned snapshot of the AWS
  CloudFormation Resource Specification. The assembler sources are
  vendored (delomboked, see `docs/SCHEMA_SOURCE.md` for the Lombok
  trade-off); the spec is fetched by `http_file` at a sha256 pinned
  in `cloudformation/private/extensions.bzl`.
- **`cfn_assemble`** custom rule (in
  `cloudformation/private/assemble.bzl`) runs the assembler with a
  synthesized YAML config — one region (us-east-1), one custom
  resource group (any `AWS::*` regex pattern), one emitted
  `<group>-spec.json` per invocation. The output is a
  consumer-ready JSON Schema.
- **Codegen pipeline** — `rules_jsonschema`'s
  `jsonschema_starlark_codegen` produces
  `cloudformation/aws_s3_bucket.bzl` from the assembled `storage`
  group's schema. Committed + gated by a `diff_test` so CI fails
  on drift between the upstream schema source and the committed
  `.bzl`.
- **`cloudformation_aws_s3_bucket`** — typed Bazel rule, one
  `attr.*` per CFN Resource Specification property, emits a JSON
  shard ready for a future `cloudformation_stack` aggregator.
  Re-exported from `//cloudformation:defs.bzl`.
- **End-to-end smoke** (`examples/smoke/`) — declares an S3 bucket
  + a byte-stability diff_test on the emitted shard. Green.

> Note on the schema source: v0.1.0 was retagged to swap an early
> per-resource AWS-endpoint approach for the upstream Java
> assembler. This keeps the source-of-truth aligned with cfn-lint
> and the CFN documentation, at the cost of a build-time Java
> compile. See [`docs/SCHEMA_SOURCE.md`](docs/SCHEMA_SOURCE.md) for
> the trade-offs and the Lombok wrinkle.

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

## Schema source (current)

The schema is sourced via the upstream Java assembler from
[aws-cloudformation/cloudformation-template-schema](https://github.com/aws-cloudformation/cloudformation-template-schema),
run at build time against a sha-pinned snapshot of the AWS
CloudFormation Resource Specification (us-east-1). The assembler
sources are vendored under
`cloudformation/private/assembler_src/` in delomboked form (see
[docs/SCHEMA_SOURCE.md](docs/SCHEMA_SOURCE.md) for the Lombok-vs-JDK
context).

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

`rules_jsonschema`, `rules_java`, `rules_jvm_external`, and
(transitively) a Rust toolchain are pulled in once the v0.1
codegen pipeline lands. The Maven artifacts for the assembler are
pinned by `maven_install.json`; consumers don't need to repin.

## License

MIT.
