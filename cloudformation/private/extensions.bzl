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
# ⛔ PIN A VERSION, NEVER `/latest/`. The old pin was a sha256 against
# `d1uauaxba7bl26.cloudfront.net/latest/…` — a checksum on a URL AWS republishes
# under. Every spec publication broke the FETCH (not the drift test) with
# "Checksum was X but wanted Y", and bumping the hash only bought time until the
# next one. Measured 2026-08-14: three different digests for that URL inside one
# day — `3bf0f8b5…` pinned, `96655fef…` seen by CI, `b39a6168…` on a laptop.
#
# ⭐ AWS publishes the same artifact under an IMMUTABLE version path, which
# assembler_resources/config.yml already knew (its `test` entry points at
# `/14.1.0/gzip/…`). Pinning the version makes the sha256 mean something again:
# it can only change when the constant below changes.
#
# ⚠ The `gzip/` variant deliberately: S3 serves it with `Content-Encoding: gzip`,
# so the TRANSFER is 0.9 MB rather than 16.6 MB.
#
# ⛔ THE SHA256 BELOW IS OF THE DECOMPRESSED JSON, NOT OF THE GZIP BYTES. Bazel's
# downloader honours Content-Encoding and decompresses BEFORE hashing, so pinning
# `shasum -a 256` of the downloaded `.gz` fails with a mismatch that reads exactly
# like a corrupted or moved artifact. Take the hash after `gunzip -c`:
#
#     curl -fsSL <url> | gunzip -c | shasum -a 256
#
# (SpecificationLoader.java also sniffs GZIP_MAGIC, so a gzip file would work too
# — but it never sees one, because Bazel has already decompressed it.)
#
# To refresh: bump the version, re-pin the sha256, then
# `bazel run //cloudformation:update` and commit the regenerated defs.bzl and
# cfn_types.bzl IN THE SAME CHANGE — the diff_test gates compare against them.
_RESOURCE_SPEC_VERSION = "260.0.0"
_RESOURCE_SPEC_URL = "https://cfn-resource-specifications-us-east-1-prod.s3.us-east-1.amazonaws.com/{}/gzip/CloudFormationResourceSpecification.json".format(_RESOURCE_SPEC_VERSION)
_RESOURCE_SPEC_SHA256 = "b39a61685b44cd03bbd27fe76c737bd405eb15645c7b30b4fd77abbbccc5db37"

# AWS per-resource endpoint schemas. The assembler-derived JSON
# Schemas only carry URL-only `description` fields on attrs; the
# per-resource AWS endpoint schemas at
# https://schema.cloudformation.us-east-1.amazonaws.com/ ship rich
# prose descriptions for every property. v0.2 overlays them on top
# of the assembler's output before feeding the codegen.
#
# Each entry: filename → sha256. Refresh by re-downloading
# (`curl -fsSL .../<filename>.json | shasum -a 256`).
# ⛔ VENDORED, NOT FETCHED, for the same reason as the spec above: this endpoint is
# unversioned, so a sha256 against it is a checksum on a moving target. It HAD
# already drifted (`306c17ea…` pinned vs `55a4dcb7…` live on 2026-08-14) and would
# have become the next spontaneous build break the moment the spec stopped being one.
#
# Unlike the resource spec there is no versioned path on offer, so immutability has
# to come from committing the bytes. At 118 KB that is affordable — this repo
# already commits a 5.2 MB generated defs.bzl.
#
# To refresh: re-download into vendor/, then `bazel run //cloudformation:update`
# and commit the regenerated files in the same change.
# Vendored: cloudformation/private/vendor/aws-s3-bucket.json

def _impl(_mctx):
    http_file(
        name = "cfn_resource_spec",
        urls = [_RESOURCE_SPEC_URL],
        sha256 = _RESOURCE_SPEC_SHA256,
        downloaded_file_path = "CloudFormationResourceSpecification.json",
    )
    # The endpoint schemas are vendored under //cloudformation/private/vendor, so
    # this extension declares no repository for them at all. Consumers take the
    # in-repo label directly; see cloudformation/BUILD.bazel.

cfn_sources_extension = module_extension(implementation = _impl)
