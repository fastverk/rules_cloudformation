# Schema source

Design note explaining where `rules_cloudformation`'s typed rules
ultimately come from. Same role as
[`rules_docker_compose`'s compose-spec pin](https://github.com/compose-spec/compose-spec) —
one upstream artifact, content-addressed, no vendoring.

## Choice

We pin
[`aws-cloudformation/cloudformation-template-schema`](https://github.com/aws-cloudformation/cloudformation-template-schema)
at a specific commit, fetched via Bazel's `http_archive`. That repo
is AWS's official source for the master CloudFormation template
schema — the same artifact that powers the IDE syntax-validation and
autocompletion extensions in the CloudFormation team's tooling.

### Alternatives considered

| Source | Why not chosen |
|---|---|
| `https://schema.cloudformation.us-east-1.amazonaws.com/` per-region per-resource schemas | Live endpoint, no content-addressing, no SLA on URL stability. Reproducibility would require vendoring or a mirror anyway. |
| `aws-cloudformation/cloudformation-cli` registry schemas (one JSON per resource type) | Per-resource schemas exist but the canonical *combined* template schema isn't published as a single artifact there — assembling it would reimplement what the `cloudformation-template-schema` repo already produces. |
| Hand-curated subset of resource types | The whole point of `rules_jsonschema` is to avoid drift between hand-curated rules and upstream. Hard-no. |

## Pin

Pinned via `cloudformation/private/extensions.bzl` with two
single-line constants, same pattern as
`rules_docker_compose`'s `compose_spec_extension`:

```python
# https://github.com/aws-cloudformation/cloudformation-template-schema
_CFN_SCHEMA_COMMIT = "<commit sha>"
_CFN_SCHEMA_SHA256 = "<sha256 of the .tar.gz from GitHub's tarball endpoint>"
```

Refreshing the schema is two lines: bump the commit, bump the
sha256, re-run codegen, commit the regenerated
`cloudformation_rules.bzl`.

## Upstream layout

As of the most recent inspection, the upstream repo's relevant
contents are:

```
cloudformation-template-schema/
├── pom.xml                          # Maven build (Java) that assembles the master schema
├── src/main/resources/
│   ├── Schema.template              # The master JSON Schema describing every AWS::* resource type
│   ├── Intrinsics.json              # Intrinsic functions (Ref, Fn::GetAtt, …) reference data
│   └── config.yml                   # Build config for the assembly step
└── src/main/java/aws/cfn/           # The assembly tool — combines per-resource schemas into Schema.template
```

The canonical artifact `rules_jsonschema` consumes is
`src/main/resources/Schema.template`. It's a JSON Schema document
whose top-level `definitions` map contains one entry per `AWS::*`
resource type (and supporting type definitions for property shapes
shared across resources).

The fact that this is upstream-built (Maven assembles the final
`Schema.template` from inputs in the repo) means we have two
options:

1. **Consume the pre-assembled `Schema.template`** committed at the
   pinned commit. Simpler — same data path as compose-spec, just a
   single JSON Schema file.
2. **Re-run the upstream Maven build** under Bazel via `rules_java`
   to assemble `Schema.template` ourselves at build time. More
   reproducible (the assembly tool is itself pinned), but adds a
   build-time Java dep to the schema-fetch path.

v0.1 starts with option (1). v0.3 — when `rules_java` is wired up
for the linter anyway — may switch to option (2) for full
reproducibility from upstream sources.

## Codegen consumption

`rules_jsonschema`'s `jsonschema_starlark_codegen` reads the
master schema and emits one `.bzl` per resource type plus a
top-level loader. The committed layout:

```
cloudformation/
├── cloudformation_rules.bzl        # Top-level loader — re-exports every cloudformation_<resource_type>
└── private/
    └── rules/
        ├── aws_s3_bucket.bzl       # One file per AWS::* resource type
        ├── aws_lambda_function.bzl
        ├── aws_ec2_instance.bzl
        └── …                        # ~1000+ files
```

User code only ever loads from `cloudformation/defs.bzl` (hand-written,
re-exports the loader). The per-resource `.bzl` files are codegen
output, committed for IDE-friendliness and PR-reviewability.

### Why one file per resource type

Two reasons:

- **PR diffs stay small** when a single resource type gains a
  property. A monolithic `cloudformation_rules.bzl` listing
  ~1000 rules + ~10000 attrs would make any schema bump unreviewable.
- **Bazel loading is lazy at the `load()` granularity.** Users
  importing only `cloudformation_aws_s3_bucket` shouldn't pay the
  Starlark-evaluation cost for the Lambda or EC2 rule definitions.

The top-level `cloudformation_rules.bzl` aggregates them so the
`defs.bzl` user-facing surface is still a single load statement.

## Committed-vs-regenerated tradeoff

Identical to how `rules_docker_compose` handles `compose_rules.bzl`:

- **Codegen output is committed to source.** Reviewers see the typed
  attrs in the diff. IDE jump-to-definition works without running
  Bazel. No "did codegen run?" mystery in failures.
- **`diff_test` gates the commit.** A
  `//cloudformation:cloudformation_rules_up_to_date` target re-runs
  codegen on every CI build and diffs against the committed file.
  CI fails if they diverge.
- **`write_source_files` updates it.** A
  `bazel run //cloudformation:update_cloudformation_rules` target
  (pure Starlark, no hand-written shell) writes fresh codegen back
  to the source tree. Bumping the schema pin is:
  1. Edit `_CFN_SCHEMA_COMMIT` + `_CFN_SCHEMA_SHA256` in
     `cloudformation/private/extensions.bzl`.
  2. `bazel run //cloudformation:update_cloudformation_rules`.
  3. `bazel test //...` — the diff_test now passes, and any tests
     keyed off removed/renamed attrs fail loudly.

The schema itself is never copied into this repo: Bazel fetches it
from GitHub on first build and caches it like any other external
dep, same as the compose-spec.
