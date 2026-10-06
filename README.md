# Serverless Data Processing Pipeline

A resilient, event-driven data processing pipeline on AWS built with S3, SQS, Lambda, and CloudWatch, provisioned entirely through Terraform. The project demonstrates production-grade patterns including Dead-Letter Queues for fault tolerance and weighted canary deployments for safe rollouts.

## Architecture Overview

The pipeline follows an event-driven architecture where each component is decoupled through messaging:

1. **Ingestion** -- A file uploaded to the input S3 bucket triggers an `s3:ObjectCreated:*` event notification.
2. **Buffering** -- The event is delivered to an SQS queue, which absorbs traffic spikes and guarantees at-least-once delivery.
3. **Processing** -- A Lambda function (invoked via an SQS event source mapping) downloads the file, transforms its contents, and writes the result to the output S3 bucket.
4. **Error handling** -- Messages that fail processing after three attempts are automatically redirected to a Dead-Letter Queue for inspection.
5. **Deployment** -- Lambda aliases (`PROD`, `CANARY`, `LIVE`) enable weighted traffic splitting so new code versions can be validated against a fraction of real traffic before full promotion.
6. **Observability** -- A CloudWatch dashboard tracks Lambda invocations, errors, duration, and SQS queue depths.

## Project Structure

```
serverless-data-pipeline/
|-- terraform/              # Infrastructure as Code
|   |-- main.tf             # Resource definitions
|   |-- variables.tf        # Input variables
|   |-- outputs.tf          # Exported values
|   |-- providers.tf        # Provider and backend config
|   +-- versions.tf         # Version constraints
|-- lambda/                 # Application code
|   |-- data_processor.py   # Lambda handler
|   +-- requirements.txt    # Python dependencies
|-- tests/
|   |-- unit/               # Isolated unit tests
|   +-- integration/        # End-to-end AWS tests
|-- deployment_scripts/
|   +-- deploy_canary.sh    # Traffic-shifting script
|-- docker-compose.yml      # Dockerized test runner
|-- Dockerfile.tester       # Test container image
|-- .env.example            # Environment variable template
+-- README.md
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- [AWS CLI](https://aws.amazon.com/cli/) v2
- Python 3.9+
- Docker and Docker Compose (for the containerized test runner)
- An AWS account with IAM credentials that have permissions to manage S3, SQS, Lambda, IAM, and CloudWatch resources.

## Getting Started

### 1. Configure Environment Variables

```bash
cp .env.example .env
```

Open `.env` and replace the placeholder values with your AWS credentials and a unique project identifier. The `UNIQUE_ID` value is appended to all resource names to prevent global naming collisions.

### 2. Provision Infrastructure

```bash
cd terraform

# Initialize Terraform. For local state (testing only):
terraform init

# For remote state with an S3 backend (recommended for collaboration):
terraform init \
  -backend-config="bucket=your-tf-state-bucket" \
  -backend-config="key=data-pipeline/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=terraform-locks"

# Review the execution plan:
terraform plan -var="unique_id=your-initials-date"

# Apply:
terraform apply -var="unique_id=your-initials-date"
```

After a successful apply, Terraform prints the names and ARNs of all provisioned resources.

### 3. Verify the Pipeline

Upload a test file to the input bucket:

```bash
aws s3 cp - s3://input-data-bucket-<YOUR_ID>/test/hello.json <<< '{"message": "hello"}'
```

Check the output bucket after a few seconds:

```bash
aws s3 cp s3://processed-data-bucket-<YOUR_ID>/processed/test/hello.json -
```

The response should contain the original fields plus `processed_timestamp`, `source_bucket`, `source_key`, and `pipeline_version`.

### 4. Test the Dead-Letter Queue

Upload a file whose key matches the `SIMULATE_ERROR_KEY` variable:

```bash
aws s3 cp - s3://input-data-bucket-<YOUR_ID>/error-file.json <<< '{"trigger": "dlq"}'
```

After the message exhausts its three retry attempts, it will appear in the DLQ. Check with:

```bash
aws sqs receive-message --queue-url $(aws sqs get-queue-url --queue-name data-processing-dlq-<YOUR_ID> --query QueueUrl --output text)
```

## Canary Deployments

The `deploy_canary.sh` script automates weighted traffic shifting between Lambda versions.

### Shift 10% of traffic to a new version

```bash
# First, publish a new version after code changes:
aws lambda publish-version --function-name data-processor-lambda-<YOUR_ID>

# Then deploy the canary:
chmod +x deployment_scripts/deploy_canary.sh
./deployment_scripts/deploy_canary.sh data-processor-lambda-<YOUR_ID> 0.1
```

This updates the `CANARY` alias to the latest published version and configures the `LIVE` alias to route 90% of traffic to `PROD` and 10% to `CANARY`.

### Promote the canary to full production

Once the canary version is validated (low error rate on the CloudWatch dashboard):

```bash
./deployment_scripts/deploy_canary.sh data-processor-lambda-<YOUR_ID> 0
```

Setting the weight to `0` promotes the canary: the `PROD` alias is updated to the latest version and the `LIVE` alias routes 100% of traffic there.

### Rollback

If the canary shows elevated errors, you can remove it from the routing entirely by pointing `LIVE` back to the current `PROD` version:

```bash
PROD_VERSION=$(aws lambda get-alias --function-name data-processor-lambda-<YOUR_ID> --name PROD --query FunctionVersion --output text)
aws lambda update-alias --function-name data-processor-lambda-<YOUR_ID> --name LIVE --function-version "$PROD_VERSION" --routing-config 'AdditionalVersionWeights={}'
```

## Running Tests

### Unit Tests

Unit tests mock all AWS SDK calls and validate the transformation logic in isolation:

```bash
cd lambda
python -m pytest ../tests/unit/ -v
```

Or with unittest directly:

```bash
PYTHONPATH=lambda python -m unittest discover -s tests/unit -v
```

### Integration Tests (Docker)

The Dockerized runner ensures a consistent environment:

```bash
# Ensure your .env file is configured.
docker-compose up --build integration-tester
```

The container uploads test files to real AWS resources and verifies both the happy path and the DLQ error path. A non-zero exit code indicates failure.

### Integration Tests (Local)

If you prefer running outside Docker:

```bash
source .env
export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY UNIQUE_ID SIMULATE_ERROR_KEY
python tests/integration/test_pipeline.py
```

## Monitoring

The CloudWatch dashboard (`data-pipeline-dashboard-<YOUR_ID>`) is provisioned automatically and tracks:

- **Lambda Invocations** -- total function calls per minute.
- **Lambda Errors** -- failed invocations (watch for spikes after a canary deployment).
- **Lambda Duration** -- average execution time.
- **Main Queue Depth** -- messages waiting to be processed.
- **DLQ Depth** -- messages that exhausted their retry budget.
- **Messages in Flight** -- messages currently being processed.

Open the dashboard in the AWS Console under CloudWatch > Dashboards.

## Teardown

To destroy all provisioned resources:

```bash
cd terraform
terraform destroy -var="unique_id=your-initials-date"
```

Empty the S3 buckets first if Terraform reports a deletion error:

```bash
aws s3 rm s3://input-data-bucket-<YOUR_ID> --recursive
aws s3 rm s3://processed-data-bucket-<YOUR_ID> --recursive
```

## Troubleshooting

**State lock errors** -- If `terraform apply` is interrupted, the DynamoDB lock may persist. Release it with `terraform force-unlock <LOCK_ID>` after confirming no other operations are running.

**DLQ messages take too long to appear** -- The default SQS visibility timeout is 60 seconds. With `maxReceiveCount` set to 3, a message may take up to three minutes to reach the DLQ. Reduce `sqs_visibility_timeout` in `variables.tf` for faster feedback during development.

**Lambda permissions errors** -- Verify the IAM policy grants `s3:GetObject` on the input bucket and `s3:PutObject` on the processed bucket. Check CloudWatch Logs for the exact error.
