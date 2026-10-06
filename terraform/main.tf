# ---------------------------------------------------------------------------
# S3 Buckets
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "input_data" {
  bucket = "input-data-bucket-${var.unique_id}"
}

resource "aws_s3_bucket" "processed_data" {
  bucket = "processed-data-bucket-${var.unique_id}"
}

# ---------------------------------------------------------------------------
# SQS Queues
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "data_processing_dlq" {
  name                      = "data-processing-dlq-${var.unique_id}"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "data_processing_queue" {
  name                       = "data-processing-queue-${var.unique_id}"
  visibility_timeout_seconds = var.sqs_visibility_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.data_processing_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

# Allow S3 to publish event notifications to the main SQS queue.
resource "aws_sqs_queue_policy" "allow_s3_to_sqs" {
  queue_url = aws_sqs_queue.data_processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "AllowS3ToSendMessage"
    Statement = [
      {
        Sid       = "AllowS3BucketNotification"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.data_processing_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.input_data.arn
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# S3 Event Notification -> SQS
# ---------------------------------------------------------------------------

resource "aws_s3_bucket_notification" "input_data_notification" {
  bucket = aws_s3_bucket.input_data.id

  queue {
    queue_arn = aws_sqs_queue.data_processing_queue.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.allow_s3_to_sqs]
}

# ---------------------------------------------------------------------------
# IAM Role and Policy for Lambda
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "data-processor-role-${var.unique_id}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  # CloudWatch Logs
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Read from the input bucket
  statement {
    sid     = "AllowS3GetInputObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.input_data.arn}/*"
    ]
  }

  # Write to the processed bucket
  statement {
    sid     = "AllowS3PutProcessedObject"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.processed_data.arn}/*"
    ]
  }

  # Consume messages from the main SQS queue
  statement {
    sid    = "AllowSQSConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    resources = [
      aws_sqs_queue.data_processing_queue.arn
    ]
  }
}

resource "aws_iam_role_policy" "lambda_exec_policy" {
  name   = "data-processor-policy-${var.unique_id}"
  role   = aws_iam_role.lambda_exec_role.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ---------------------------------------------------------------------------
# Lambda Function
# ---------------------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda_payload.zip"
}

resource "aws_lambda_function" "data_processor" {
  function_name    = "data-processor-lambda-${var.unique_id}"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "data_processor.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  publish          = true

  environment {
    variables = {
      PROCESSED_DATA_BUCKET = aws_s3_bucket.processed_data.bucket
      SIMULATE_ERROR_KEY    = var.simulate_error_key
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda Aliases (Canary Deployment)
# ---------------------------------------------------------------------------

resource "aws_lambda_alias" "prod_alias" {
  name             = "PROD"
  function_name    = aws_lambda_function.data_processor.function_name
  function_version = aws_lambda_function.data_processor.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

resource "aws_lambda_alias" "canary_alias" {
  name             = "CANARY"
  function_name    = aws_lambda_function.data_processor.function_name
  function_version = aws_lambda_function.data_processor.version

  lifecycle {
    ignore_changes = [function_version]
  }
}

resource "aws_lambda_alias" "live_alias" {
  name             = "LIVE"
  function_name    = aws_lambda_function.data_processor.function_name
  function_version = aws_lambda_alias.prod_alias.function_version

  dynamic "routing_config" {
    for_each = var.canary_traffic_weight > 0 ? [1] : []
    content {
      additional_version_weights = {
        (aws_lambda_alias.canary_alias.function_version) = var.canary_traffic_weight
      }
    }
  }

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}

# ---------------------------------------------------------------------------
# SQS -> Lambda Event Source Mapping (targets LIVE alias)
# ---------------------------------------------------------------------------

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.data_processing_queue.arn
  function_name    = aws_lambda_alias.live_alias.arn
  batch_size       = var.lambda_batch_size
  enabled          = true
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "pipeline_dashboard" {
  dashboard_name = "data-pipeline-dashboard-${var.unique_id}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Lambda Invocations"
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.data_processor.function_name, { stat = "Sum", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Lambda Errors"
          metrics = [["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.data_processor.function_name, { stat = "Sum", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Lambda Duration (ms)"
          metrics = [["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.data_processor.function_name, { stat = "Average", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Main Queue - Messages Visible"
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.data_processing_queue.name, { stat = "Maximum", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "DLQ - Messages Visible"
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.data_processing_dlq.name, { stat = "Maximum", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Main Queue - Messages in Flight"
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesNotVisible", "QueueName", aws_sqs_queue.data_processing_queue.name, { stat = "Maximum", period = 60 }]]
          view    = "timeSeries"
          region  = var.aws_region
          period  = 60
        }
      }
    ]
  })
}
