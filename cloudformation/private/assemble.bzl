"""Custom rule that runs the upstream Java assembler at build time.

The assembler (`aws.cfn.codegen.json.Main`) reads:
  - a CloudFormation Resource Specification file (sha-pinned by
    `cfn_sources_extension`), and
  - a YAML config describing region → spec URL + the group(s) of
    resources to emit.

It writes `<output-dir>/<region>/<group>-spec.json` for each
configured group. We synthesize the YAML config inline so the spec
URL points at the local file (the upstream bundled config.yml has
all 25 region URLs hard-coded to the AWS CDN, which would defeat
build-time reproducibility).

The rule takes one group name + a list of `AWS::*` includes/excludes
patterns and exposes the single emitted `<group>-spec.json` as its
output. Consumers pipe that file into
`jsonschema_starlark_codegen`.

Why not pass `--cfn-spec-url` to Main? The upstream Main accepts
the flag but never threads it through to Codegen — Codegen reads
the URL only from the config's `specifications:` map (keyed by
region). The synthesized config.yml below sets that map.
"""

_CONFIG_TEMPLATE = """settings:
  draft: draft07
  regions:
    - us-east-1
  output: {output_dir}
  single: false
  intrinsics: true

specifications:
  us-east-1: {spec_uri}

groups:
  {group_name}:
    includes:
{includes_yaml}{excludes_yaml}
"""

def _yaml_list(items, indent):
    if not items:
        return ""
    return "\n".join([indent + "- " + s for s in items])

def _cfn_assemble_impl(ctx):
    spec_file = ctx.file.spec
    group_name = ctx.attr.group_name
    includes = ctx.attr.includes
    excludes = ctx.attr.excludes

    if not includes:
        fail("cfn_assemble: `includes` must be non-empty")

    out_dir = ctx.actions.declare_directory(ctx.label.name + "_out")
    config_file = ctx.actions.declare_file(ctx.label.name + "_config.yml")
    schema_out = ctx.actions.declare_file(
        ctx.label.name + "/" + group_name + "-spec.json",
    )

    includes_yaml = _yaml_list(includes, "      ")
    excludes_yaml = ""
    if excludes:
        excludes_yaml = "\n    excludes:\n" + _yaml_list(excludes, "      ")

    # Spec URI is a file:// URI computed at action time so the path
    # resolves inside the sandbox. We do this via a wrapper shell
    # script because $(rootpath) doesn't expand inside ctx.actions.write.
    ctx.actions.write(
        output = config_file,
        content = _CONFIG_TEMPLATE.format(
            output_dir = out_dir.path,
            spec_uri = "file://__SPEC_PATH__",
            group_name = group_name,
            includes_yaml = includes_yaml,
            excludes_yaml = excludes_yaml,
        ),
    )

    assembler = ctx.executable._assembler

    # Wrapper script: substitute the absolute spec path into the
    # config file, then invoke the assembler, then copy the named
    # group's output into the rule's declared file.
    runner = ctx.actions.declare_file(ctx.label.name + "_run.sh")
    ctx.actions.write(
        output = runner,
        content = """#!/usr/bin/env bash
set -euo pipefail
ASSEMBLER="$1"; CONFIG_IN="$2"; SPEC="$3"; OUT_DIR="$4"; GROUP="$5"; DEST="$6"
CONFIG_OUT="${OUT_DIR}.config.yml"
SPEC_ABS="$(cd "$(dirname "$SPEC")" && pwd)/$(basename "$SPEC")"
mkdir -p "$OUT_DIR"
sed "s|__SPEC_PATH__|${SPEC_ABS}|" "$CONFIG_IN" > "$CONFIG_OUT"
"$ASSEMBLER" \\
  --config-file="$CONFIG_OUT" \\
  --aws-region=us-east-1 \\
  --json-schema-version=draft07 \\
  --output-dir="$OUT_DIR" \\
  --intrinsics
cp "$OUT_DIR/us-east-1/$GROUP-spec.json" "$DEST"
""",
        is_executable = True,
    )

    ctx.actions.run(
        executable = runner,
        arguments = [
            assembler.path,
            config_file.path,
            spec_file.path,
            out_dir.path,
            group_name,
            schema_out.path,
        ],
        inputs = depset([spec_file, config_file]),
        outputs = [out_dir, schema_out],
        tools = [ctx.attr._assembler[DefaultInfo].files_to_run],
        mnemonic = "CfnAssemble",
        progress_message = "Assembling CFN schema group '%s' for %s" % (group_name, ctx.label),
    )

    return [DefaultInfo(files = depset([schema_out]))]

cfn_assemble = rule(
    implementation = _cfn_assemble_impl,
    doc = """Run the upstream CFN Java assembler against a pinned spec
and emit a single `<group>-spec.json`.

The output file is consumable by
`@rules_jsonschema//starlark:defs.bzl#jsonschema_starlark_codegen`.
Resource definitions appear at JSON pointer
`#/definitions/AWS_<Service>_<Resource>` (the assembler rewrites
the `::` separator to `_`).""",
    attrs = {
        "spec": attr.label(
            allow_single_file = [".json"],
            mandatory = True,
            doc = "CloudFormation Resource Specification JSON file. " +
                  "Typically `@cfn_resource_spec//file`.",
        ),
        "group_name": attr.string(
            mandatory = True,
            doc = "Logical group name. Becomes part of the emitted " +
                  "filename: `<group_name>-spec.json`.",
        ),
        "includes": attr.string_list(
            mandatory = True,
            doc = "List of `AWS::*` regex patterns that the group " +
                  "includes. E.g. `[\"AWS::S3.*\"]`.",
        ),
        "excludes": attr.string_list(
            default = [],
            doc = "Optional regex excludes applied after `includes`.",
        ),
        "_assembler": attr.label(
            default = "//cloudformation/private:assembler",
            executable = True,
            cfg = "exec",
        ),
    },
)
