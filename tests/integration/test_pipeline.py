"""End-to-end integration tests for the serverless data processing pipeline.

These tests run against real AWS infrastructure provisioned by Terraform.
Required environment variables:
    AWS_REGION              - AWS region (e.g. us-east-1)
    UNIQUE_ID               - The same identifier used during terraform apply
    SIMULATE_ERROR_KEY      - Object key that triggers the DLQ error path
"""

import json
import os
import sys
import time
import uuid
import logging

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def _env(name):
    """Return an environment variable or exit with a clear error."""
    value = os.environ.get(name)
    if not value:
        logger.error("Required environment variable %s is not set.", name)
        sys.exit(1)
    return value


REGION = _env("AWS_REGION")
UNIQUE_ID = _env("UNIQUE_ID")
SIMULATE_ERROR_KEY = _env("SIMULATE_ERROR_KEY")

INPUT_BUCKET = f"input-data-bucket-{UNIQUE_ID}"
PROCESSED_BUCKET = f"processed-data-bucket-{UNIQUE_ID}"
DLQ_NAME = f"data-processing-dlq-{UNIQUE_ID}"

s3 = boto3.client("s3", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)


def _poll_s3_object(bucket, key, timeout_seconds=60, interval=3):
    """Wait for an S3 object to appear, returning its body as a string."""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            response = s3.get_object(Bucket=bucket, Key=key)
            return response["Body"].read().decode("utf-8")
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "NoSuchKey":
                time.sleep(interval)
            else:
                raise
    return None


def _get_queue_url(queue_name):
    """Resolve an SQS queue name to its URL."""
    response = sqs.get_queue_url(QueueName=queue_name)
    return response["QueueUrl"]


def _poll_dlq(queue_url, timeout_seconds=120, interval=5):
    """Wait for at least one message to appear in the Dead-Letter Queue."""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=5,
        )
        messages = response.get("Messages", [])
        if messages:
            return messages
        time.sleep(interval)
    return []


def test_happy_path():
    """Upload a valid file and verify it appears transformed in the output bucket."""
    test_id = str(uuid.uuid4())
    object_key = f"test-input/{test_id}.json"
    payload = {"test_id": test_id, "data": "integration test payload"}

    logger.info("Uploading test object to s3://%s/%s", INPUT_BUCKET, object_key)
    s3.put_object(
        Bucket=INPUT_BUCKET,
        Key=object_key,
        Body=json.dumps(payload),
        ContentType="application/json",
    )

    expected_output_key = f"processed/{object_key}"
    logger.info(
        "Polling for output at s3://%s/%s", PROCESSED_BUCKET, expected_output_key
    )
    result_body = _poll_s3_object(PROCESSED_BUCKET, expected_output_key)

    if result_body is None:
        logger.error(
            "FAIL - Transformed object did not appear within the timeout window."
        )
        return False

    result = json.loads(result_body)

    checks = [
        (result.get("test_id") == test_id, "test_id matches"),
        ("processed_timestamp" in result, "processed_timestamp present"),
        (result.get("source_bucket") == INPUT_BUCKET, "source_bucket matches"),
        (result.get("source_key") == object_key, "source_key matches"),
        (result.get("pipeline_version") == "1.0.0", "pipeline_version matches"),
    ]

    all_passed = True
    for passed, label in checks:
        status = "PASS" if passed else "FAIL"
        logger.info("  %s - %s", status, label)
        if not passed:
            all_passed = False

    return all_passed


def test_error_path_dlq():
    """Upload the error-trigger file and verify it lands in the DLQ."""
    logger.info(
        "Uploading error-trigger object to s3://%s/%s",
        INPUT_BUCKET,
        SIMULATE_ERROR_KEY,
    )
    s3.put_object(
        Bucket=INPUT_BUCKET,
        Key=SIMULATE_ERROR_KEY,
        Body=json.dumps({"trigger": "dlq-test"}),
        ContentType="application/json",
    )

    dlq_url = _get_queue_url(DLQ_NAME)
    logger.info("Polling DLQ at %s for failed message...", dlq_url)
    messages = _poll_dlq(dlq_url)

    if not messages:
        logger.error(
            "FAIL - No message appeared in the DLQ within the timeout window."
        )
        return False

    logger.info("PASS - Message received in DLQ: %s", messages[0]["Body"][:200])
    return True


def main():
    """Run all integration tests and exit with an appropriate status code."""
    results = []

    logger.info("=" * 60)
    logger.info("TEST 1: Happy Path")
    logger.info("=" * 60)
    results.append(test_happy_path())

    logger.info("")
    logger.info("=" * 60)
    logger.info("TEST 2: Error Path (DLQ Verification)")
    logger.info("=" * 60)
    results.append(test_error_path_dlq())

    logger.info("")
    logger.info("=" * 60)
    if all(results):
        logger.info("ALL TESTS PASSED")
    else:
        logger.error("SOME TESTS FAILED")
        sys.exit(1)


if __name__ == "__main__":
    main()
