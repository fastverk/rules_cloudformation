"""Module extension that fetches the CloudFormation Resource
Specification snapshot.

v0.1 builds the upstream Java assembler
(`aws.cfn.codegen.json.Main`) from sources vendored under
`cloudformation/private/assembler_src/` — delomboked once, then
patched, then committed (see `docs/SCHEMA_SOURCE.md` for the
trade-off). The assembler is fed a sha-pinned snapshot of the AWS
CloudFormation Resource Specification (the us-east-1 non-gzip
endpoint) and emits per-group JSON Schemas. One group is then fed
through `jsonschema_starlark_codegen` to produce the typed Bazel
rules.

One repo today:
  - `@cfn_resource_spec`: the sha-pinned
    CloudFormationResourceSpecification.json (~15MB). The endpoint
    is documented as non-gzip; the assembler's SpecificationLoader
    auto-detects the encoding by magic bytes.

Refreshing the spec is a 2-line change: bump the URL (if AWS
restructures), bump the sha256 (`curl -fsSL <url> | shasum -a 256`).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

# AWS CloudFormation Resource Specification, us-east-1 non-gzip
# endpoint. Computed by `curl -fsSL <url> | shasum -a 256` at pin
# time. Refresh whenever AWS updates the underlying spec.
_RESOURCE_SPEC_URL = "https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json"
_RESOURCE_SPEC_SHA256 = "3bf0f8b5034b51c622da82f7cec9499112a40719f28fff5c6d2050a0c3a24459"

# AWS per-resource endpoint schemas. The assembler-derived JSON
# Schemas only carry URL-only `description` fields on attrs; the
# per-resource AWS endpoint schemas at
# https://schema.cloudformation.us-east-1.amazonaws.com/ ship rich
# prose descriptions for every property. v0.2 overlays them on top
# of the assembler's output before feeding the codegen.
#
# Each entry: filename → sha256. Refresh by re-downloading
# (`curl -fsSL .../<filename>.json | shasum -a 256`).
_PINNED_ENDPOINT_SCHEMAS = {
    "aws-s3-bucket.json": "306c17eac19e62159bdeaa872af1fe85b28e0cfd43d955d35765182b3904f4ab",
}

_AWS_SCHEMA_BASE = "https://schema.cloudformation.us-east-1.amazonaws.com"

def _impl(_mctx):
    http_file(
        name = "cfn_resource_spec",
        urls = [_RESOURCE_SPEC_URL],
        sha256 = _RESOURCE_SPEC_SHA256,
        downloaded_file_path = "CloudFormationResourceSpecification.json",
    )
    for filename, sha256 in _PINNED_ENDPOINT_SCHEMAS.items():
        # Repo name strips `.json` and rewrites `-` to `_` so the
        # @cfn_endpoint_<resource> label is Bazel-canonical.
        repo_name = "cfn_endpoint_" + filename.removesuffix(".json").replace("-", "_")
        http_file(
            name = repo_name,
            urls = ["{}/{}".format(_AWS_SCHEMA_BASE, filename)],
            sha256 = sha256,
            downloaded_file_path = filename,
        )

cfn_sources_extension = module_extension(implementation = _impl)
