# Changelog

All notable changes to rules_cloudformation. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.6.0 — deploy wrappers (cloudformation_up / cloudformation_down)

- New `cloudformation_up` and `cloudformation_down` executable
  rules in `cloudformation/deploy.bzl`. `bazel run :foo_up` deploys
  the stack via the aws CLI's `cloudformation deploy`;
  `bazel run :foo_down` calls `delete-stack`. Extra argv after
  `--` flows through to the aws CLI.
- New aws CLI toolchain abstraction
  (`cloudformation/aws_cli/toolchain_type.bzl`). The default
  toolchain (`@rules_cloudformation//cloudformation/aws_cli:default_aws_cli_toolchain`,
  auto-registered) is a thin `sh_binary` around system `aws` on
  PATH — friendliest for dev + CI runners that already have aws
  CLI installed. Consumers can register their own toolchain (e.g.
  multitool-fetched, http_file, sidecar Docker) and Bazel's
  toolchain resolution will prefer it without any changes to the
  deploy rules.
- Deploy rule attrs: `stack` (the cloudformation_stack target;
  mandatory), `stack_name` (defaults to label.name), `region`,
  `capabilities` (list — e.g. `["CAPABILITY_IAM"]`),
  `parameter_overrides` (string_dict).
- Smoke targets exercise the launcher generation end-to-end
  (build-only — no real AWS calls in CI).

## 0.5.0 — cross-resource refs (cfn_ref / cfn_getatt)

- New `cfn_ref(resource_name)` and `cfn_getatt(resource_name,
  attribute)` Starlark helpers in `cloudformation/stack.bzl`. They
  return sentinel strings (`@@cfn:ref:Name`,
  `@@cfn:getatt:Name.Attr`) that the aggregator rewrites into
  `{"Ref": ...}` / `{"Fn::GetAtt": [...]}` CFN intrinsic dicts at
  template-render time.
- Aggregator validates that every sentinel points at a name in the
  stack's resource set — typos fail the Bazel build with a
  `$.Resources.X.Properties.Y` breadcrumb instead of a deferred
  AWS-side template rejection.
- Smoke stack now exercises both helpers: a `BucketPolicy` whose
  `Bucket` is `cfn_ref("SmokeBucket")` and whose policy statement
  references `cfn_getatt("SmokeBucket", "Arn")`. Expected JSON
  updated.

## 0.4.0 — cloudformation_stack aggregator

- New `cloudformation_stack` rule (`cloudformation/stack.bzl`) —
  takes typed-rule shards (from `defs.bzl`) and intrinsic shards
  (from `intrinsics.bzl`) and renders one CFN template:
  `Resources.X = {Type, Properties}` per resource, Init shards
  spliced under `Resources.<target>.Metadata.AWS::CloudFormation::Init`,
  Interface shards spliced under template-level
  `Metadata.AWS::CloudFormation::Interface`. Optional
  `description` attr fills the template's `Description` field.
- New generated `cfn_types.bzl` (snake-id → `AWS::Service::Resource`
  map for all 1582 spec rules) — needed because snake-case loses
  the segment boundaries that distinguish e.g.
  `ApplicationAutoScaling::ScalableTarget` from
  `Application::AutoScalingScalableTarget`. Regenerated alongside
  `defs.bzl` via `bazel run //cloudformation:update`.
- Smoke stack in `examples/smoke` aggregates an S3 bucket + EC2
  instance + Init metadata + Interface block into one template,
  byte-stable `diff_test` against committed expected JSON.
- **Phase-1 limitations** — the aggregator uses each contributing
  rule's `label.name` as the CFN logical id (so Bazel targets must
  be PascalCase and alphanumeric). The `<kind_id>_name` custom-name
  attr on the typed rules is unused for now. Cross-resource
  refs (`Ref` / `Fn::GetAtt`) and deploy wrappers
  (`cloudformation_up` / `_down`) are deferred to later phases.

## 0.3.1 — CFN intrinsics (Init, Interface)

- New `cloudformation/intrinsics.bzl` with two hand-authored rules
  for the CFN metadata directives that live outside the Resource
  Spec:
  - `cloudformation_aws_cloudformation_init` — emits the
    `AWS::CloudFormation::Init` config-set tree (configSets +
    named config blocks) that `cfn-init` interprets at instance
    boot. Carries a `target_resource_name` for the future stack
    aggregator to attach the shard under the right resource's
    `Metadata`.
  - `cloudformation_aws_cloudformation_interface` — emits the
    `AWS::CloudFormation::Interface` template-level metadata
    that groups Parameters into labelled sections for the AWS
    console UI.
- Smoke tests in `examples/smoke` cover both with byte-stable
  `diff_test` gates.

Purely additive — no changes to the spec-derived rules in
`defs.bzl`. Consumers wanting the intrinsics
`load("@rules_cloudformation//cloudformation:intrinsics.bzl", ...)`
alongside the existing `defs.bzl` load.

## 0.3.0 — exhaustive coverage via rules_jsonschema auto-kinds

- Switched from 6 hand-curated service groups to a **single
  assembler invocation covering the entire CFN Resource Spec**,
  driven by rules_jsonschema v0.3's new auto-kinds flags
  (`--kinds-pointer-base`, `--kinds-key-filter`, the template
  flags). Result: **1582 typed Bazel rules** across every
  `AWS::Service::Resource` in the pinned spec (was 26).
- Adding a new resource type is now a no-op — bump the upstream
  spec pin in `cfn_sources_extension` and the new resources show
  up in the regenerated `defs.bzl`.
- `defs.bzl` is now the generated artifact (was a hand-written
  re-export shim over 6 per-group `.bzl` files). The per-group
  files (`storage.bzl`, `compute.bzl`, …) are removed.
- **Breaking**: the per-kind item-name attr is now namespaced with
  the full `aws_service_resource` id (e.g. `aws_s3_bucket_name`)
  rather than the v0.2 short tag (`bucket_name`). The change
  prevents collisions across the 1500+ resource set; the v0.2
  short-tag form wasn't unique once coverage expanded past one
  service per "kind concept" (S3, EC2, and S3Outposts all have
  "bucket"-ish resources, etc.).
- Endpoint-description overlay (`cfn_overlay_descriptions`)
  preserved against the new single `assembled_all` target;
  `AWS::S3::Bucket` retains its rich property docs. Endpoint
  coverage for additional resources is still pin-per-resource in
  `cloudformation/private/extensions.bzl`.

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
