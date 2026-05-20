# Schema source

Where `rules_cloudformation`'s typed rules ultimately come from.

## Choice (v0.1)

We run the upstream Java assembler
(`aws.cfn.codegen.json.Main` from
`aws-cloudformation/cloudformation-template-schema`) at build time
against a sha-pinned snapshot of the AWS CloudFormation Resource
Specification. The assembler emits one JSON Schema per resource
group; we feed the `storage` group's output (scoped to `AWS::S3.*`
in v0.1) through `rules_jsonschema`'s
`jsonschema_starlark_codegen` to produce the typed Bazel rules.

Two artifacts are pinned in
[`cloudformation/private/extensions.bzl`](../cloudformation/private/extensions.bzl):

- `aws-cloudformation/cloudformation-template-schema` at commit
  `5d7815b14fd533c15c30f9046a76cdcb89afd32a` (sha256
  `7f40b919bbea6109244903744262074f6afa32fdd780a6dca0540ef1b57bd774`).
  Fetched but not on the compile path — see the *Lombok wrinkle*
  section below. Vendored under
  [`cloudformation/private/assembler_src/`](../cloudformation/private/assembler_src/)
  in delomboked form.
- The us-east-1 `CloudFormationResourceSpecification.json` at
  sha256 `3bf0f8b5034b51c622da82f7cec9499112a40719f28fff5c6d2050a0c3a24459`.
  Endpoint: `https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json`.

## How the build composes

```
@cfn_resource_spec//file:CloudFormationResourceSpecification.json
                          │
                          ▼
                  //cloudformation:assembled_storage   (cfn_assemble)
                          │
                          │  storage-spec.json (JSON Schema, ~280 KB,
                          │   223 AWS::S3.* + Tag definitions)
                          ▼
              //cloudformation:aws_s3_bucket_gen        (jsonschema_starlark_codegen)
                          │
                          ▼
                  aws_s3_bucket.bzl                     (committed, diff_test-gated)
```

`cfn_assemble` synthesizes a YAML config that points the assembler
at the local pinned spec (the upstream bundled `config.yml` has all
25 region URLs hard-coded to the AWS CDN, which would defeat
build-time reproducibility), narrows the region set to us-east-1
(the source-of-truth region), and declares a single custom group
with the requested `includes`/`excludes`.

## Lombok wrinkle

The upstream sources use Lombok 1.16.22 (released 2018). That
release predates JDK 21+. The current Lombok release line (1.18.x)
fails to initialize under JDK 25 with
`com.sun.tools.javac.code.TypeTag :: UNKNOWN`, and Bazel 9.1.0's
rules_java toolchain runs the JavaBuilder on remotejdk25 by default
without an easy override.

After running the prompt's listed fallbacks (bump Lombok, pin
`--java_runtime_version=remotejdk_21`, pin Lombok 1.18.36 — none of
which sidestepped the issue because the JavaBuilder process itself
runs on remotejdk25), we took the documented nuclear option: ran
`lombok.jar delombok` against the upstream sources locally
(`java -jar lombok.jar delombok src/main/java -d cloudformation/private/assembler_src`),
stripped the `@lombok.Generated` annotations the delomboker leaves
on each generated method, and committed the result.

Trade-off: refreshing the assembler from a newer upstream commit
isn't a one-line bump anymore — it's a `delombok` + commit. In
exchange, the build has no annotation-processor at compile time and
no Lombok runtime dep, so it stays buildable on whichever JDK Bazel
ships with going forward.

The patched upstream Codegen has one rules_cloudformation-local
fix: newer CFN spec entries can have `Type: Json` with no
`PrimitiveType` set, which the upstream code treats as a primitive
but then NPEs on. The patch in `Codegen.addPrimitiveType` falls back
to "Json" when the primitive name is null.

### Known gap: registry-only resources

The legacy Resource Specification we pin covers ~1582 of the
~1600+ types AWS publishes. A handful of newer types
(post-2023 additions — e.g. `AWS::EC2::Image`,
`AWS::EC2::SnapshotBlockPublicAccess`) only ship via the newer
CloudFormation Registry schema source (per-resource JSON files at
`schema.cloudformation.us-east-1.amazonaws.com/`) and never
landed in the legacy spec. Surfacing them would mean pulling
from the Registry endpoint as a second source — same per-resource-
file shape as the v0.0.1 source, but only for the resources the
legacy spec is missing. v0.7+ work item; not on the current
roadmap because demand is low (savvi-ops, the design's stress
test, hits ~1 of 87 in-use AWS types as a registry-only).

### Alternatives considered

| Source | Why not chosen |
|---|---|
| Per-resource AWS endpoint (`schema.cloudformation.us-east-1.amazonaws.com/<resource>.json`) | The v0.0.1 / first-cut v0.1 used this. It works but it's a per-resource fetch (1200+ URLs to track for full coverage) and the schema content is the AWS resource-provider schema, which is divergent from the CloudFormation Resource Specification. Pivoting now keeps the same source-of-truth as cfn-lint and the CFN Linter docs. |
| `aws-cloudformation/cloudformation-cli` registry schemas | Same per-resource shape, different repository. No advantage. |
| Hand-curated subset | rules_jsonschema's whole point is avoiding drift between hand-written rules and upstream. Hard-no. |

## Refreshing

Three independent bumps:

1. **CFN Resource Specification** (typical: track AWS-published spec
   versions):
   ```sh
   curl -fsSL https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json | shasum -a 256
   # bump _RESOURCE_SPEC_SHA256 in cloudformation/private/extensions.bzl
   bazel run //cloudformation:update
   ```

2. **Upstream assembler source** (rare: only when upstream changes
   how groups are computed or fixes a Codegen bug):
   ```sh
   # Compute the new tarball hash
   curl -fsSL https://github.com/aws-cloudformation/cloudformation-template-schema/archive/<commit>.tar.gz | shasum -a 256
   # Re-delombok + commit
   curl -fsSL https://projectlombok.org/downloads/lombok-1.18.36.jar -o /tmp/lombok.jar
   java -jar /tmp/lombok.jar delombok \
        <unpacked-src>/src/main/java \
        -d cloudformation/private/assembler_src
   find cloudformation/private/assembler_src -name '*.java' -exec sed -i '' 's/@lombok\.Generated//g' {} +
   # Bump _TEMPLATE_SCHEMA_COMMIT + _TEMPLATE_SCHEMA_SHA256 in extensions.bzl
   bazel run //cloudformation:update
   ```

3. **Maven deps** (rare: only when upstream pom.xml shifts):
   ```sh
   # Edit MODULE.bazel's maven.install(artifacts=[...]) list
   REPIN=1 bazel run @cfn_assembler_maven//:pin
   ```

## Path to ~1200 resource types

v0.1 covers `AWS::S3::Bucket` as a codegen smoke. v0.2 lifts the
hard-coded resource set into a tag class:

```python
cfn_resources = use_extension(
    "@rules_cloudformation//cloudformation/private:extensions.bzl",
    "cfn_sources_extension",
)
cfn_resources.bundle(
    name = "storage",
    includes = ["AWS::S3.*", "AWS::DynamoDB.*"],
)
cfn_resources.bundle(
    name = "compute",
    includes = ["AWS::EC2.*", "AWS::Lambda.*"],
)
```

so consumers opt into the resource set they care about — declaring
1200 typed Bazel rules per consumer when they use 10 is wasted
analysis time. Bundling lands in v0.2 (see
[`ROADMAP.md`](ROADMAP.md)).
