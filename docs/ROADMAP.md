# rules_cloudformation roadmap

Three milestones to first useful release. Numbering matches the
`rules_docker_compose` cadence: v0.1 = schema-derived primitives,
v0.2 = hand-written orchestration, v0.3 = deploy wrappers + linter.

## v0.1 — schema fetch + codegen

Get the schema into the repo as Bazel-fetched data, run codegen, ship
the first typed rule end-to-end.

- **Schema fetch.** `cloudformation/private/extensions.bzl` defines an
  `http_archive`-backed module extension pinning
  `aws-cloudformation/cloudformation-template-schema` to a specific
  commit + sha256. Same shape as `rules_docker_compose`'s
  `compose_spec_extension`, except `http_archive` (not `http_file`)
  because the upstream packages the schema as part of a Maven build,
  not a single JSON file — see `docs/SCHEMA_SOURCE.md`.

- **MODULE.bazel wires `rules_jsonschema`.** Adds
  `bazel_dep(name = "rules_jsonschema", version = "0.2.0")` and a
  `use_extension` block consuming the schema repo.

- **Codegen pipeline.** A single
  `jsonschema_starlark_codegen` invocation reads the master
  `Schema.template` and emits
  `cloudformation/cloudformation_rules.bzl` — one `rule()` per
  `AWS::*` definition. Estimated ~1000+ rules (e.g.
  `cloudformation_aws_s3_bucket`, `cloudformation_aws_lambda_function`,
  `cloudformation_aws_ec2_instance`, `cloudformation_aws_iam_role`,
  `cloudformation_aws_dynamodb_table`, …). The committed `.bzl` is
  diff-tested against fresh codegen on every CI build, exactly like
  `compose_rules.bzl` in `rules_docker_compose`.

- **Smoke test.** One end-to-end example: a single
  `cloudformation_aws_s3_bucket` target rendered through a
  placeholder aggregator into golden YAML. Validates that the
  schema-fetch → codegen → typed-attr → JSON-shard → YAML pipeline
  works for at least one resource type before the v0.2 aggregator
  arrives.

## v0.2 — hand-written orchestration

Replace the placeholder aggregator with the real graph-walking
implementation, plus cross-stack ref resolution.

- **`cloudformation_stack`.** Aggregator rule. Collects shards from
  `deps`, validates the `Ref` graph (every logical ID referenced is
  defined or has a matching `cloudformation_resource_ref`), and
  renders one canonical `template.yaml` via a Rust `cfn-gen` binary.
  Same shape as `docker_compose`: shard JSON → typed struct (from
  `rules_jsonschema`'s `jsonschema_rust_library`) → canonical YAML.
  Stable key ordering so re-renders are byte-identical.

- **`cloudformation_resource_ref`.** Cross-stack reference resolver.
  Given a target stack label and an output name, resolves to the
  exported value at build time (via either a checked-in
  `outputs.json` or a stack-output index file), then rewrites a
  property of a named resource in the rendered template to that
  value. Same role as `docker_compose_oci_image_ref`: a build-time
  override that turns a symbolic reference into a concrete pinned
  value before deploy.

- **Providers.** `CloudformationResourceInfo`,
  `CloudformationStackInfo`, `CloudformationResourceRefInfo`.

## v0.3 — deploy + lint

Ship the runtime wrappers and the Java-based linter.

- **`cloudformation_up`.** `bazel run` wrapper that invokes
  `aws cloudformation deploy --template-file <rendered> --stack-name
  <stack>` against the rendered template, with `--parameter-overrides`
  flowing through from rule attrs. Same shape as
  `docker_compose_up`'s `bazel run` wrapper.

- **`cloudformation_down`.** `bazel run` wrapper for
  `aws cloudformation delete-stack`. Mirrors `docker_compose_down`.

- **Java linter.** Port of cfn-lint–style rules built with
  `rules_java`. Why Java: the upstream schema repo is a Maven project
  whose intrinsic-function and reference tables already exist in
  Java — reusing them is cheaper than reimplementing. Packaged as a
  `java_binary` invoked from a `cloudformation_lint_test` rule that
  runs against every `cloudformation_stack`.
