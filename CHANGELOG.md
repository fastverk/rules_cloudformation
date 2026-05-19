# Changelog

All notable changes to rules_cloudformation. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.1.0 — codegen pipeline + first typed resource

- `cfn_schemas_extension` module extension that `http_file`s
  per-resource CFN schemas, sha256-pinned from the AWS endpoint
  at `schema.cloudformation.us-east-1.amazonaws.com`.
- `jsonschema_starlark_codegen` invocation under
  `//cloudformation` generates `aws_s3_bucket.bzl` from the
  upstream schema. Committed; gated by `diff_test`;
  `bazel run //cloudformation:update` regenerates.
- `cloudformation_aws_s3_bucket` rule (30 typed `attr.*`,
  one per JSON-Schema property) + `CloudformationAwsS3BucketInfo`
  provider. Re-exported from `//cloudformation:defs.bzl`.
- End-to-end smoke (`examples/smoke/`) declaring an S3 bucket
  through the typed rule. Byte-stability diff_test on the
  emitted JSON shard.
- Pivoted schema source from
  `aws-cloudformation/cloudformation-template-schema` (Mustache
  template, not literal JSON) to the AWS per-resource endpoint.
  See `docs/SCHEMA_SOURCE.md` for the trade-off.

## 0.0.1 — scaffold

- Initial scaffold via `rels scaffold`. No public API yet.
