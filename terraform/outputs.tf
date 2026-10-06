output "input_bucket_name" {
  description = "Name of the S3 bucket that receives raw input files."
  value       = aws_s3_bucket.input_data.bucket
}

output "input_bucket_arn" {
  description = "ARN of the input S3 bucket."
  value       = aws_s3_bucket.input_data.arn
}

output "processed_bucket_name" {
  description = "Name of the S3 bucket that stores transformed output files."
  value       = aws_s3_bucket.processed_data.bucket
}

output "processed_bucket_arn" {
  description = "ARN of the processed S3 bucket."
  value       = aws_s3_bucket.processed_data.arn
}

output "main_queue_url" {
  description = "URL of the primary SQS queue that buffers S3 event notifications."
  value       = aws_sqs_queue.data_processing_queue.url
}

output "main_queue_arn" {
  description = "ARN of the primary SQS queue."
  value       = aws_sqs_queue.data_processing_queue.arn
}

output "dlq_url" {
  description = "URL of the Dead-Letter Queue that captures failed messages."
  value       = aws_sqs_queue.data_processing_dlq.url
}

output "dlq_arn" {
  description = "ARN of the Dead-Letter Queue."
  value       = aws_sqs_queue.data_processing_dlq.arn
}

output "lambda_function_name" {
  description = "Name of the data processor Lambda function."
  value       = aws_lambda_function.data_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the data processor Lambda function."
  value       = aws_lambda_function.data_processor.arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM execution role attached to the Lambda function."
  value       = aws_iam_role.lambda_exec_role.arn
}

output "live_alias_arn" {
  description = "ARN of the LIVE Lambda alias used as the SQS event target."
  value       = aws_lambda_alias.live_alias.arn
}

output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch dashboard tracking pipeline health."
  value       = aws_cloudwatch_dashboard.pipeline_dashboard.dashboard_name
}
