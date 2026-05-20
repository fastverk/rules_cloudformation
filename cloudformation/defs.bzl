"""User-facing rules for rules_cloudformation.

Re-exports the schema-derived typed Bazel rules + their info
providers from the per-group `.bzl` files. v0.2 ships 6 groups
covering ~25 of the most common AWS resource types:

| Group | Resources |
|---|---|
| storage | S3 Bucket, BucketPolicy, AccessPoint |
| compute | Lambda Function/Permission, ECS Service/Cluster/TaskDefinition, ECR Repository |
| identity | IAM Role, Policy, ManagedPolicy, User, Group |
| messaging | SQS Queue/QueuePolicy, SNS Topic/Subscription/TopicPolicy, EventBridge EventBus/Rule |
| observability | CloudWatch Logs LogGroup/LogStream, CloudWatch Alarm |
| database | DynamoDB Table/GlobalTable |

Each resource becomes a typed Bazel rule with one `attr.*` per
JSON-Schema property:

```python
load("@rules_cloudformation//cloudformation:defs.bzl",
     "cloudformation_aws_s3_bucket",
     "cloudformation_aws_lambda_function",
     "cloudformation_aws_iam_role")

cloudformation_aws_s3_bucket(
    name = "assets",
    BucketName = "my-app-assets",
    VersioningConfiguration = '{"Status": "Enabled"}',
)
```

Adding a resource type: extend the corresponding group's
`includes` list and `kinds` table in
[`cloudformation/BUILD.bazel`](BUILD.bazel), then
`bazel run //cloudformation:update`. Adding a new group:
copy any existing `cfn_assemble` + `jsonschema_starlark_codegen`
pair and add re-exports here.

The hand-written orchestration (`cloudformation_stack` aggregator,
`cloudformation_resource_ref` cross-stack refs, `cloudformation_up`
/ `_down` deploy wrappers) is v0.3+.
"""

load(
    "//cloudformation:compute.bzl",
    _CloudformationAwsEcrRepositoryInfo = "CloudformationAwsEcrRepositoryInfo",
    _CloudformationAwsEcsClusterInfo = "CloudformationAwsEcsClusterInfo",
    _CloudformationAwsEcsServiceInfo = "CloudformationAwsEcsServiceInfo",
    _CloudformationAwsEcsTaskDefinitionInfo = "CloudformationAwsEcsTaskDefinitionInfo",
    _CloudformationAwsLambdaFunctionInfo = "CloudformationAwsLambdaFunctionInfo",
    _CloudformationAwsLambdaPermissionInfo = "CloudformationAwsLambdaPermissionInfo",
    _cloudformation_aws_ecr_repository = "cloudformation_aws_ecr_repository",
    _cloudformation_aws_ecs_cluster = "cloudformation_aws_ecs_cluster",
    _cloudformation_aws_ecs_service = "cloudformation_aws_ecs_service",
    _cloudformation_aws_ecs_task_definition = "cloudformation_aws_ecs_task_definition",
    _cloudformation_aws_lambda_function = "cloudformation_aws_lambda_function",
    _cloudformation_aws_lambda_permission = "cloudformation_aws_lambda_permission",
)
load(
    "//cloudformation:database.bzl",
    _CloudformationAwsDynamodbGlobalTableInfo = "CloudformationAwsDynamodbGlobalTableInfo",
    _CloudformationAwsDynamodbTableInfo = "CloudformationAwsDynamodbTableInfo",
    _cloudformation_aws_dynamodb_global_table = "cloudformation_aws_dynamodb_global_table",
    _cloudformation_aws_dynamodb_table = "cloudformation_aws_dynamodb_table",
)
load(
    "//cloudformation:identity.bzl",
    _CloudformationAwsIamGroupInfo = "CloudformationAwsIamGroupInfo",
    _CloudformationAwsIamManagedPolicyInfo = "CloudformationAwsIamManagedPolicyInfo",
    _CloudformationAwsIamPolicyInfo = "CloudformationAwsIamPolicyInfo",
    _CloudformationAwsIamRoleInfo = "CloudformationAwsIamRoleInfo",
    _CloudformationAwsIamUserInfo = "CloudformationAwsIamUserInfo",
    _cloudformation_aws_iam_group = "cloudformation_aws_iam_group",
    _cloudformation_aws_iam_managed_policy = "cloudformation_aws_iam_managed_policy",
    _cloudformation_aws_iam_policy = "cloudformation_aws_iam_policy",
    _cloudformation_aws_iam_role = "cloudformation_aws_iam_role",
    _cloudformation_aws_iam_user = "cloudformation_aws_iam_user",
)
load(
    "//cloudformation:messaging.bzl",
    _CloudformationAwsEventsEventBusInfo = "CloudformationAwsEventsEventBusInfo",
    _CloudformationAwsEventsRuleInfo = "CloudformationAwsEventsRuleInfo",
    _CloudformationAwsSnsSubscriptionInfo = "CloudformationAwsSnsSubscriptionInfo",
    _CloudformationAwsSnsTopicInfo = "CloudformationAwsSnsTopicInfo",
    _CloudformationAwsSnsTopicPolicyInfo = "CloudformationAwsSnsTopicPolicyInfo",
    _CloudformationAwsSqsQueueInfo = "CloudformationAwsSqsQueueInfo",
    _CloudformationAwsSqsQueuePolicyInfo = "CloudformationAwsSqsQueuePolicyInfo",
    _cloudformation_aws_events_event_bus = "cloudformation_aws_events_event_bus",
    _cloudformation_aws_events_rule = "cloudformation_aws_events_rule",
    _cloudformation_aws_sns_subscription = "cloudformation_aws_sns_subscription",
    _cloudformation_aws_sns_topic = "cloudformation_aws_sns_topic",
    _cloudformation_aws_sns_topic_policy = "cloudformation_aws_sns_topic_policy",
    _cloudformation_aws_sqs_queue = "cloudformation_aws_sqs_queue",
    _cloudformation_aws_sqs_queue_policy = "cloudformation_aws_sqs_queue_policy",
)
load(
    "//cloudformation:observability.bzl",
    _CloudformationAwsCloudwatchAlarmInfo = "CloudformationAwsCloudwatchAlarmInfo",
    _CloudformationAwsLogsLogGroupInfo = "CloudformationAwsLogsLogGroupInfo",
    _CloudformationAwsLogsLogStreamInfo = "CloudformationAwsLogsLogStreamInfo",
    _cloudformation_aws_cloudwatch_alarm = "cloudformation_aws_cloudwatch_alarm",
    _cloudformation_aws_logs_log_group = "cloudformation_aws_logs_log_group",
    _cloudformation_aws_logs_log_stream = "cloudformation_aws_logs_log_stream",
)
load(
    "//cloudformation:storage.bzl",
    _CloudformationAwsS3AccessPointInfo = "CloudformationAwsS3AccessPointInfo",
    _CloudformationAwsS3BucketInfo = "CloudformationAwsS3BucketInfo",
    _CloudformationAwsS3BucketPolicyInfo = "CloudformationAwsS3BucketPolicyInfo",
    _cloudformation_aws_s3_access_point = "cloudformation_aws_s3_access_point",
    _cloudformation_aws_s3_bucket = "cloudformation_aws_s3_bucket",
    _cloudformation_aws_s3_bucket_policy = "cloudformation_aws_s3_bucket_policy",
)

# Rules
cloudformation_aws_s3_bucket = _cloudformation_aws_s3_bucket
cloudformation_aws_s3_bucket_policy = _cloudformation_aws_s3_bucket_policy
cloudformation_aws_s3_access_point = _cloudformation_aws_s3_access_point
cloudformation_aws_lambda_function = _cloudformation_aws_lambda_function
cloudformation_aws_lambda_permission = _cloudformation_aws_lambda_permission
cloudformation_aws_ecs_service = _cloudformation_aws_ecs_service
cloudformation_aws_ecs_cluster = _cloudformation_aws_ecs_cluster
cloudformation_aws_ecs_task_definition = _cloudformation_aws_ecs_task_definition
cloudformation_aws_ecr_repository = _cloudformation_aws_ecr_repository
cloudformation_aws_iam_role = _cloudformation_aws_iam_role
cloudformation_aws_iam_policy = _cloudformation_aws_iam_policy
cloudformation_aws_iam_managed_policy = _cloudformation_aws_iam_managed_policy
cloudformation_aws_iam_user = _cloudformation_aws_iam_user
cloudformation_aws_iam_group = _cloudformation_aws_iam_group
cloudformation_aws_sqs_queue = _cloudformation_aws_sqs_queue
cloudformation_aws_sqs_queue_policy = _cloudformation_aws_sqs_queue_policy
cloudformation_aws_sns_topic = _cloudformation_aws_sns_topic
cloudformation_aws_sns_subscription = _cloudformation_aws_sns_subscription
cloudformation_aws_sns_topic_policy = _cloudformation_aws_sns_topic_policy
cloudformation_aws_events_event_bus = _cloudformation_aws_events_event_bus
cloudformation_aws_events_rule = _cloudformation_aws_events_rule
cloudformation_aws_logs_log_group = _cloudformation_aws_logs_log_group
cloudformation_aws_logs_log_stream = _cloudformation_aws_logs_log_stream
cloudformation_aws_cloudwatch_alarm = _cloudformation_aws_cloudwatch_alarm
cloudformation_aws_dynamodb_table = _cloudformation_aws_dynamodb_table
cloudformation_aws_dynamodb_global_table = _cloudformation_aws_dynamodb_global_table

# Providers
CloudformationAwsS3BucketInfo = _CloudformationAwsS3BucketInfo
CloudformationAwsS3BucketPolicyInfo = _CloudformationAwsS3BucketPolicyInfo
CloudformationAwsS3AccessPointInfo = _CloudformationAwsS3AccessPointInfo
CloudformationAwsLambdaFunctionInfo = _CloudformationAwsLambdaFunctionInfo
CloudformationAwsLambdaPermissionInfo = _CloudformationAwsLambdaPermissionInfo
CloudformationAwsEcsServiceInfo = _CloudformationAwsEcsServiceInfo
CloudformationAwsEcsClusterInfo = _CloudformationAwsEcsClusterInfo
CloudformationAwsEcsTaskDefinitionInfo = _CloudformationAwsEcsTaskDefinitionInfo
CloudformationAwsEcrRepositoryInfo = _CloudformationAwsEcrRepositoryInfo
CloudformationAwsIamRoleInfo = _CloudformationAwsIamRoleInfo
CloudformationAwsIamPolicyInfo = _CloudformationAwsIamPolicyInfo
CloudformationAwsIamManagedPolicyInfo = _CloudformationAwsIamManagedPolicyInfo
CloudformationAwsIamUserInfo = _CloudformationAwsIamUserInfo
CloudformationAwsIamGroupInfo = _CloudformationAwsIamGroupInfo
CloudformationAwsSqsQueueInfo = _CloudformationAwsSqsQueueInfo
CloudformationAwsSqsQueuePolicyInfo = _CloudformationAwsSqsQueuePolicyInfo
CloudformationAwsSnsTopicInfo = _CloudformationAwsSnsTopicInfo
CloudformationAwsSnsSubscriptionInfo = _CloudformationAwsSnsSubscriptionInfo
CloudformationAwsSnsTopicPolicyInfo = _CloudformationAwsSnsTopicPolicyInfo
CloudformationAwsEventsEventBusInfo = _CloudformationAwsEventsEventBusInfo
CloudformationAwsEventsRuleInfo = _CloudformationAwsEventsRuleInfo
CloudformationAwsLogsLogGroupInfo = _CloudformationAwsLogsLogGroupInfo
CloudformationAwsLogsLogStreamInfo = _CloudformationAwsLogsLogStreamInfo
CloudformationAwsCloudwatchAlarmInfo = _CloudformationAwsCloudwatchAlarmInfo
CloudformationAwsDynamodbTableInfo = _CloudformationAwsDynamodbTableInfo
CloudformationAwsDynamodbGlobalTableInfo = _CloudformationAwsDynamodbGlobalTableInfo
