"""`aws_cli_toolchain` rule — pairs an executable target with the
`AwsCliToolchainInfo` provider so `cloudformation_up` /
`cloudformation_down` (and future deploy rules) can resolve it via
the standard Bazel toolchain mechanism.

Most users won't write `aws_cli_toolchain` directly — they'll
either accept the default toolchain registered by
rules_cloudformation (PATH-based), or register one that wires a
hermetically-fetched aws CLI binary (rules_multitool, an
`http_file` archive, etc.).
"""

load(":toolchain_type.bzl", "AwsCliToolchainInfo")

def _aws_cli_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(
        aws_cli_info = AwsCliToolchainInfo(
            aws = ctx.attr.aws.files_to_run,
            default_runfiles = ctx.attr.aws[DefaultInfo].default_runfiles,
        ),
    )]

aws_cli_toolchain = rule(
    implementation = _aws_cli_toolchain_impl,
    doc = "Register a target as the aws CLI for cloudformation deploy rules. Pair with a `toolchain(...)` declaration pointing at `@rules_cloudformation//cloudformation/aws_cli:toolchain_type`.",
    attrs = {
        "aws": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "Executable target whose entry point is the aws CLI. Can be an `sh_binary` wrapping system `aws` (the default), or a hermetically-fetched binary (rules_multitool, http_file, etc.).",
        ),
    },
)
