"""Module extension that fetches CloudFormation resource-type schemas.

AWS publishes per-resource-type JSON Schemas at
`https://schema.cloudformation.us-east-1.amazonaws.com/aws-<service>-<resource>.json`.
We pin each one by sha256 — the live URL isn't content-addressable
on its own, but the sha pin gives us bazel-native reproducibility.

v0.1 fetches one resource type (`AWS::S3::Bucket`) to validate the
codegen pipeline end-to-end. v0.2 will fan out into the full
~1200 resource types, gated behind a `cfn_schemas.bundle(resources=
[...])` tag class so consumers opt in to the resource set they
care about (compiling 1200 typed Bazel rules in every consumer is
not free).

The CFN Schema.template artifact in
aws-cloudformation/cloudformation-template-schema is a Mustache
template, not literal JSON — assembling it requires running the
upstream Java assembler. The per-resource AWS endpoint sidesteps
that build step.

Two lines move when refreshing a schema:
  - bump the URL (only if upstream restructures)
  - bump the sha256 (`curl -fsSL <url> | shasum -a 256`)
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

# AWS publishes the canonical per-resource schemas at this endpoint.
# us-east-1 is the source-of-truth region; the other regional
# subdomains mirror it on a delay.
_AWS_SCHEMA_BASE = "https://schema.cloudformation.us-east-1.amazonaws.com"

# Pinned schemas. Each entry: filename → sha256. Add a new entry by:
#   1. curl -fsSLO https://schema.cloudformation.us-east-1.amazonaws.com/<file>.json
#   2. shasum -a 256 <file>.json
#   3. Drop the sha here, and add a jsonschema_starlark_codegen rule
#      in //cloudformation:BUILD.bazel pointing at @aws_cfn_<resource>.
_PINNED_SCHEMAS = {
    "aws-s3-bucket.json": "306c17eac19e62159bdeaa872af1fe85b28e0cfd43d955d35765182b3904f4ab",
}

def _impl(_mctx):
    for filename, sha256 in _PINNED_SCHEMAS.items():
        # Repo name strips `.json` and rewrites `-` to `_` so the
        # @aws_cfn_<resource> label is Bazel-canonical.
        repo_name = "aws_cfn_" + filename.removesuffix(".json").replace("-", "_")
        http_file(
            name = repo_name,
            urls = ["{}/{}".format(_AWS_SCHEMA_BASE, filename)],
            sha256 = sha256,
            downloaded_file_path = filename,
        )

cfn_schemas_extension = module_extension(implementation = _impl)
