"""User-facing rules for rules_cloudformation.

The typed schema-derived rules live in the auto-generated files
(one per resource type). This file is the public entry point —
re-exports the generated rules + providers, and will host the
hand-written orchestration (`cloudformation_stack` aggregator,
`cloudformation_resource_ref` for cross-stack refs,
`cloudformation_up` / `_down`) when those land in v0.2 / v0.3.

v0.1 covers one resource type as a codegen smoke. Pulling in
`rules_cloudformation` today gets you:

```python
load("@rules_cloudformation//cloudformation:defs.bzl",
     "cloudformation_aws_s3_bucket",
     "CloudformationAwsS3BucketInfo")

cloudformation_aws_s3_bucket(
    name = "my_bucket",
    BucketName = "my-app-assets",
    VersioningConfiguration = '{"Status": "Enabled"}',
)
```

Adding a new resource type: drop its schema into
`//cloudformation/private:extensions.bzl#_PINNED_SCHEMAS`, add it
to `kinds` in `//cloudformation:BUILD.bazel`, re-run
`bazel run //cloudformation:update`, and re-export here.
"""

load(
    "//cloudformation:aws_s3_bucket.bzl",
    _CloudformationAwsS3BucketInfo = "CloudformationAwsS3BucketInfo",
    _cloudformation_aws_s3_bucket = "cloudformation_aws_s3_bucket",
)

cloudformation_aws_s3_bucket = _cloudformation_aws_s3_bucket
CloudformationAwsS3BucketInfo = _CloudformationAwsS3BucketInfo
