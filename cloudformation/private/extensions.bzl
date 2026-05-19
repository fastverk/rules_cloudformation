"""Module extension that fetches the CloudFormation assembler source
+ the CloudFormation Resource Specification snapshot.

v0.1 builds the upstream Java assembler
(`aws.cfn.codegen.json.Main`) from
`aws-cloudformation/cloudformation-template-schema` at a pinned
commit, and runs it at build time against a sha-pinned snapshot of
the AWS CloudFormation Resource Specification (the us-east-1
non-gzip endpoint). The assembler emits per-group JSON Schemas;
one group is then fed through `jsonschema_starlark_codegen` to
produce the typed Bazel rules.

Two repos:
  - `@cfn_template_schema_src`: tarball of the assembler source,
    with a stub BUILD.bazel that exposes the Java sources + bundled
    config.yml / Schema.template / Intrinsics.json resources as
    filegroups.
  - `@cfn_resource_spec`: the sha-pinned
    CloudFormationResourceSpecification.json (~15MB). The endpoint
    is documented as non-gzip; the assembler's SpecificationLoader
    auto-detects the encoding by magic bytes.

Refreshing the spec is a 3-line change: bump the URL, bump the
sha256 (`curl -fsSL <url> | shasum -a 256`), re-pin Maven.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

# Pinned commit on aws-cloudformation/cloudformation-template-schema.
_TEMPLATE_SCHEMA_COMMIT = "5d7815b14fd533c15c30f9046a76cdcb89afd32a"
_TEMPLATE_SCHEMA_SHA256 = "7f40b919bbea6109244903744262074f6afa32fdd780a6dca0540ef1b57bd774"

# AWS CloudFormation Resource Specification, us-east-1 non-gzip
# endpoint. Computed by `curl -fsSL <url> | shasum -a 256` at pin
# time. Refresh whenever AWS updates the underlying spec.
_RESOURCE_SPEC_URL = "https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json"
_RESOURCE_SPEC_SHA256 = "3bf0f8b5034b51c622da82f7cec9499112a40719f28fff5c6d2050a0c3a24459"

# Stub BUILD file inserted into the upstream source tarball. Exports
# the Java sources + bundled resources as filegroups under labels
# that //cloudformation/private:BUILD.bazel consumes.
_TEMPLATE_SCHEMA_BUILD = """
load("@rules_java//java:defs.bzl", "java_library")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "java_srcs",
    srcs = glob(["src/main/java/**/*.java"]),
)

# Bundled assembler resources, wrapped in a java_library so the
# strip-prefix is interpreted relative to this external repo's
# package — `Mustache#compile("Schema.template")` resolves to the
# classpath root.
java_library(
    name = "resources",
    resources = [
        "src/main/resources/config.yml",
        "src/main/resources/Schema.template",
        "src/main/resources/Intrinsics.json",
    ],
    resource_strip_prefix = "src/main/resources",
)

exports_files([
    "src/main/resources/config.yml",
    "src/main/resources/Schema.template",
    "src/main/resources/Intrinsics.json",
])
"""

def _impl(_mctx):
    http_archive(
        name = "cfn_template_schema_src",
        urls = [
            "https://github.com/aws-cloudformation/cloudformation-template-schema/archive/{}.tar.gz".format(_TEMPLATE_SCHEMA_COMMIT),
        ],
        sha256 = _TEMPLATE_SCHEMA_SHA256,
        strip_prefix = "cloudformation-template-schema-{}".format(_TEMPLATE_SCHEMA_COMMIT),
        build_file_content = _TEMPLATE_SCHEMA_BUILD,
    )

    http_file(
        name = "cfn_resource_spec",
        urls = [_RESOURCE_SPEC_URL],
        sha256 = _RESOURCE_SPEC_SHA256,
        downloaded_file_path = "CloudFormationResourceSpecification.json",
    )

cfn_sources_extension = module_extension(implementation = _impl)
