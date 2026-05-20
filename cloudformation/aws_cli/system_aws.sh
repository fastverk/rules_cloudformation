#!/usr/bin/env bash
# Default aws CLI wrapper for rules_cloudformation. Shells out to
# whatever `aws` is on PATH. Swap by registering an alternate
# toolchain for `@rules_cloudformation//cloudformation/aws_cli:toolchain_type`.
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
    echo "rules_cloudformation: default aws CLI toolchain expected \`aws\` on PATH but none found." >&2
    echo "  Install AWS CLI (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)" >&2
    echo "  or register a hermetic toolchain for @rules_cloudformation//cloudformation/aws_cli:toolchain_type." >&2
    exit 127
fi

exec aws "$@"
