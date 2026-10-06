variable "aws_region" {
  description = "AWS region where all resources will be provisioned."
  type        = string
  default     = "us-east-1"
}

variable "unique_id" {
  description = "A short, unique identifier appended to resource names to prevent global naming collisions (e.g. initials-date like 'sd-20261006')."
  type        = string
}

variable "simulate_error_key" {
  description = "The S3 object key that triggers an intentional processing failure for DLQ testing."
  type        = string
  default     = "error-file.json"
}

variable "lambda_runtime" {
  description = "The Python runtime version for the Lambda function."
  type        = string
  default     = "python3.9"
}

variable "lambda_timeout" {
  description = "Maximum execution time in seconds for the Lambda function."
  type        = number
  default     = 30
}

variable "sqs_visibility_timeout" {
  description = "Number of seconds a message remains hidden from other consumers after being received. Should exceed the Lambda timeout to prevent duplicate processing."
  type        = number
  default     = 60
}

variable "sqs_max_receive_count" {
  description = "Number of times a message can be received before being redirected to the Dead-Letter Queue."
  type        = number
  default     = 3
}

variable "canary_traffic_weight" {
  description = "Fraction of traffic routed to the canary Lambda version (0.0 to 1.0). Set to 0 to disable canary routing."
  type        = number
  default     = 0.0

  validation {
    condition     = var.canary_traffic_weight >= 0 && var.canary_traffic_weight <= 1
    error_message = "canary_traffic_weight must be between 0.0 and 1.0."
  }
}

variable "lambda_batch_size" {
  description = "Maximum number of SQS messages delivered to the Lambda function in a single invocation."
  type        = number
  default     = 10
}
