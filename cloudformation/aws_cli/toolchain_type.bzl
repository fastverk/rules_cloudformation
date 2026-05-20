"""Toolchain type + info provider for the `aws` CLI consumed by
`cloudformation_up` / `cloudformation_down`.

Indirected via a toolchain so consumers who want a hermetic
deployment story (multitool-fetched aws CLI, a Bazel-built static
binary, a sidecar Docker image) can register their own toolchain
and have `cloudformation_up` pick it up — no changes to the deploy
rules.

The default toolchain registered by rules_cloudformation
(`//cloudformation/aws_cli:default_aws_cli_toolchain`) shells out
to whatever `aws` is on the user's PATH. This is the friendliest
default for local dev + CI runners that already have aws CLI
installed; less hermetic, but no platform-specific pkg/.zip
plumbing needed in rules_cloudformation.
"""

AwsCliToolchainInfo = provider(
    doc = "Carries the `aws` CLI binary used by cloudformation deploy rules.",
    fields = {
        "aws": "FilesToRunProvider — its `.executable` is the aws CLI entry point.",
        "default_runfiles": "Runfiles needed to invoke `aws` at runtime (the wrapping `sh_binary`'s deps, plus any hermetic-binary auxiliary files).",
    },
)

AWS_CLI_TOOLCHAIN_TYPE = "@rules_cloudformation//cloudformation/aws_cli:toolchain_type"
