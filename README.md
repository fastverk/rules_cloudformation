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

## Status: v0.5.0

What v0.5 adds on top of v0.4.0:

- **Cross-resource refs** — `cfn_ref(name)` and `cfn_getatt(name,
  attr)` Starlark helpers in `cloudformation/stack.bzl` produce
  sentinel strings the aggregator rewrites into `{"Ref": ...}` /
  `{"Fn::GetAtt": [...]}`. The aggregator validates that every
  ref points at a real resource in the stack — typos surface at
  Bazel-build time, not at AWS-deploy time.

```python
load("@rules_cloudformation//cloudformation:defs.bzl",
     "cloudformation_aws_s3_bucket",
     "cloudformation_aws_s3_bucket_policy")
load("@rules_cloudformation//cloudformation:stack.bzl",
     "cfn_ref", "cfn_getatt", "cloudformation_stack")

cloudformation_aws_s3_bucket(name = "Assets", BucketName = "app-assets")
cloudformation_aws_s3_bucket_policy(
    name = "AssetsPolicy",
    Bucket = cfn_ref("Assets"),
    PolicyDocument = json.encode({
        "Statement": [{
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": cfn_getatt("Assets", "Arn"),
        }],
    }),
)
cloudformation_stack(name = "stack", resources = [":Assets", ":AssetsPolicy"])
```

## Status: v0.4.0 (prior)

What v0.4 adds on top of v0.3.1:

- **`cloudformation_stack` aggregator** (`cloudformation/stack.bzl`)
  — collects typed-rule shards into a complete CFN template.
  Intrinsics splice into per-resource (`Init`) or template-level
  (`Interface`) `Metadata`. Phase-1 limitation: CFN logical ids =
  contributing rule's `label.name` (name targets PascalCase). Cross-
  resource refs + deploy wrappers are deferred to later phases.

Example:

```python
load("@rules_cloudformation//cloudformation:defs.bzl",
     "cloudformation_aws_s3_bucket")
load("@rules_cloudformation//cloudformation:stack.bzl",
     "cloudformation_stack")

cloudformation_aws_s3_bucket(name = "AppAssets", BucketName = "my-app-assets")
cloudformation_stack(
    name = "app_stack",
    description = "App backing services.",
    resources = [":AppAssets"],
)
# Output: `app_stack.json` — a deployable CFN template.
```

## Status: v0.3.1 (prior)

What v0.3.1 adds on top of v0.3.0:

- **Hand-authored CFN metadata intrinsics** in
  `cloudformation/intrinsics.bzl`:
  `cloudformation_aws_cloudformation_init` (cfn-init config-set
  tree) and `cloudformation_aws_cloudformation_interface`
  (template Metadata parameter-group block). These live outside
  the Resource Spec so they're not covered by the auto-kinds
  pipeline; loaded separately:
  `load("@rules_cloudformation//cloudformation:intrinsics.bzl", ...)`.

What v0.3 adds on top of v0.2.0:

- **Exhaustive coverage — 1582 typed rules** across the entire
  pinned CFN Resource Specification (was 26 in v0.2 / one in v0.1).
  Powered by `rules_jsonschema` v0.3's new auto-kinds flags
  (`--kinds-pointer-base`, `--kinds-key-filter`, the template
  flags) instead of hand-enumerating each `--kind=` mapping.
- **Adding a new resource type is a no-op** — bump the upstream
  spec pin (`cfn_sources_extension`) and the new resources show up
  in the regenerated `defs.bzl`.
- **Single `defs.bzl`** — the per-group files (`storage.bzl`,
  `compute.bzl`, …) collapsed into one generated artifact.
  Consumers `load("//cloudformation:defs.bzl", ...)` exactly like
  they did in v0.2; the loaded surface is a strict superset.
- **Breaking**: the per-kind item-name attr is namespaced
  (`aws_s3_bucket_name` rather than the v0.2 short tag
  `bucket_name`) to prevent collisions in the 1500+ rule set. The
  CFN property attrs (`BucketName`, `VersioningConfiguration`, …)
  are unchanged.

---

## v0.2.0 status (still shipped):

What v0.2 adds on top of v0.1.0:

- **6 resource-type groups, 26 typed rules** — every common AWS
  resource type for storage / compute / identity / messaging /
  observability / database. Each group is a separate
  `cfn_assemble` + `jsonschema_starlark_codegen` pair; consumers
  pick which group(s) to load. Re-exported from
  `//cloudformation:defs.bzl`. Adding a new resource is two
  edits in `cloudformation/BUILD.bazel`.
- **Docstring overlay** — `cfn_overlay_descriptions` layers
  AWS-endpoint per-resource property `description` fields onto
  the assembler-derived schemas before codegen. Trades URL-only
  attr docs for rich prose. v0.2 ships endpoint coverage for
  `AWS::S3::Bucket`; expanding coverage is a one-line pin per
  resource. Endpoints not yet pinned pass through unchanged.
- **Internal cleanup** — dropped the unused
  `cfn_template_schema_src` use_repo from MODULE.bazel; trimmed
  the stale `.bazelrc` Java language-version pin.

---

## v0.1.0 status (still shipped):

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
bazel_dep(name = "rules_cloudformation", version = "0.2.0")
```

`rules_jsonschema`, `rules_java`, `rules_jvm_external`, and
(transitively) a Rust toolchain are pulled in once the v0.1
codegen pipeline lands. The Maven artifacts for the assembler are
pinned by `maven_install.json`; consumers don't need to repin.

## License

MIT.
