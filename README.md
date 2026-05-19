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

## Status: v0.0.1 — scaffold

No public surface yet — the eight scaffold files, the planned design
in this README and in [docs/ROADMAP.md](docs/ROADMAP.md), and the
schema-source design note in
[docs/SCHEMA_SOURCE.md](docs/SCHEMA_SOURCE.md). See `CHANGELOG.md`
for what has shipped.

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
bazel_dep(name = "rules_cloudformation", version = "0.0.1")
```

`rules_jsonschema`, `rules_java`, and (transitively) a Rust toolchain
will be pulled in once the v0.1 codegen pipeline lands.

## License

MIT.
