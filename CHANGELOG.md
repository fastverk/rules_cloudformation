# Changelog

All notable changes to rules_cloudformation. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.2.0 — 6 groups, 26 typed rules, docstring overlay

- Scaled the codegen pipeline from one S3 Bucket rule to **26
  typed Bazel rules across 6 resource-type groups**:
  - `storage` — AWS::S3::Bucket / BucketPolicy / AccessPoint
  - `compute` — Lambda Function/Permission, ECS Service/Cluster/TaskDefinition, ECR Repository
  - `identity` — IAM Role/Policy/ManagedPolicy/User/Group
  - `messaging` — SQS Queue/QueuePolicy, SNS Topic/Subscription/TopicPolicy, EventBridge EventBus/Rule
  - `observability` — CloudWatch Logs LogGroup/LogStream, CloudWatch Alarm
  - `database` — DynamoDB Table/GlobalTable
- One `cfn_assemble` + `jsonschema_starlark_codegen` pair per
  group, emitting `cloudformation/<group>.bzl`. Each gated by
  its own `diff_test`. `bazel run //cloudformation:update`
  regenerates all groups.
- **`cfn_overlay_descriptions`** (`cloudformation/private/overlay.bzl`)
  layers AWS-endpoint per-resource property descriptions on top
  of the assembler-derived schema before codegen. Trades URL-only
  attr docs for rich prose. v0.2 pins endpoint coverage for
  `AWS::S3::Bucket`; expanding to other resources is a one-line
  pin per resource in `cloudformation/private/extensions.bzl`.
- `defs.bzl` re-exports every group's rules + providers, so
  consumers only need one `load(...)` call.
- Internal cleanup: dropped unused `cfn_template_schema_src` from
  `use_repo`; trimmed stale Java language-version pins from
  `.bazelrc` (kept only the runtime pin needed for the remote JDK).

## 0.1.0 — (retag) Java-assembler-based schema source

- Pivoted the schema source from the per-resource AWS endpoint
  (`schema.cloudformation.us-east-1.amazonaws.com/*.json`) to the
  upstream Java assembler in
  `aws-cloudformation/cloudformation-template-schema`, run at
  build time against a sha-pinned snapshot of the AWS
  CloudFormation Resource Specification (us-east-1, sha256
  `3bf0f8b5...`). This aligns the source of truth with cfn-lint
  and the CFN Linter docs.
- New module extension `cfn_sources_extension` (in
  `cloudformation/private/extensions.bzl`) — `http_archive`s the
  upstream source tarball (commit `5d7815b1...`) and `http_file`s
  the Resource Specification.
- New `cfn_assemble` custom rule (in
  `cloudformation/private/assemble.bzl`) — runs the assembler with
  a synthesized YAML config that pins region → local-file URI and
  declares a single custom resource group. Output: one
  `<group>-spec.json` consumable by
  `jsonschema_starlark_codegen`.
- Assembler sources are vendored in delomboked form under
  `cloudformation/private/assembler_src/` because Bazel 9.1.0's
  rules_java toolchain runs JavaBuilder on remotejdk25, and Lombok
  has no JDK-25-compatible release. The trade-off + refresh
  procedure is in `docs/SCHEMA_SOURCE.md`.
- One local Codegen patch: `addPrimitiveType` falls back to "Json"
  when the upstream-treated-as-primitive `propType` is null (newer
  CFN spec entries can have `Type: Json` with no `PrimitiveType`
  set — upstream NPEs on these).
- `cloudformation_aws_s3_bucket` rule re-derived from the
  assembled `storage` group's schema; the emitted JSON shard
  byte-matches the v0.0.1/early-v0.1 output for the smoke test
  inputs.

## 0.0.1 — scaffold

- Initial scaffold via `rels scaffold`. No public API yet.
