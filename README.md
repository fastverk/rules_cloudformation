# rules_cloudformation

Bazel rules for AWS CloudFormation templates — schema-derived typed Bazel rules via rules_jsonschema, Java-based linter via rules_java + the official cloudformation-template-schema.

## Status: v0.0.1 — scaffold

No public surface yet. See `CHANGELOG.md` for what has shipped.

## Install

`.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/fastverk/bazel-registry/main/
common --registry=https://bcr.bazel.build/
```

`MODULE.bazel`:

```python
bazel_dep(name = "rules_cloudformation", version = "0.0.1")
```
