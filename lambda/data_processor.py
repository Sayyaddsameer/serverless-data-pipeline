import json
import os
import logging
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client("s3")


def lambda_handler(event, context):
    """Process S3 event notifications received via SQS.

    For each incoming message the handler downloads the referenced object
    from the input bucket, enriches it with processing metadata, and
    writes the result to the processed output bucket.

    If the object key matches the SIMULATE_ERROR_KEY environment variable
    the handler raises an exception so the message eventually lands in
    the Dead-Letter Queue after exhausting its retry budget.
    """
    processed_bucket = os.environ.get("PROCESSED_DATA_BUCKET")
    simulate_error_key = os.environ.get("SIMULATE_ERROR_KEY", "")

    if not processed_bucket:
        raise EnvironmentError("PROCESSED_DATA_BUCKET environment variable is not set")

    for sqs_record in event.get("Records", []):
        try:
            s3_event_body = json.loads(sqs_record["body"])

            # Guard against non-S3 messages (e.g. test events).
            if "Records" not in s3_event_body:
                logger.info("Skipping non-S3 event message")
                continue

            for s3_record in s3_event_body["Records"]:
                source_bucket = s3_record["s3"]["bucket"]["name"]
                object_key = unquote_plus(s3_record["s3"]["object"]["key"])

                logger.info(
                    "Processing object: bucket=%s key=%s",
                    source_bucket,
                    object_key,
                )

                # Intentional failure path for DLQ verification.
                if simulate_error_key and object_key == simulate_error_key:
                    error_msg = (
                        f"Simulated processing error triggered for key: {object_key}"
                    )
                    logger.error(error_msg)
                    raise ValueError(error_msg)

                # Download the source object.
                response = s3_client.get_object(
                    Bucket=source_bucket, Key=object_key
                )
                raw_content = response["Body"].read().decode("utf-8")

                # Transform the data.
                transformed = _transform(raw_content, source_bucket, object_key)

                # Upload the transformed payload to the output bucket.
                destination_key = f"processed/{object_key}"
                s3_client.put_object(
                    Bucket=processed_bucket,
                    Key=destination_key,
                    Body=json.dumps(transformed, indent=2),
                    ContentType="application/json",
                )

                logger.info(
                    "Successfully wrote transformed object: bucket=%s key=%s",
                    processed_bucket,
                    destination_key,
                )

        except Exception:
            # Re-raise so SQS marks the message as failed and eventually
            # moves it to the DLQ after maxReceiveCount attempts.
            logger.exception("Failed to process SQS record")
            raise

    return {"statusCode": 200, "body": "Batch processed successfully."}


def _transform(raw_content, source_bucket, object_key):
    """Parse raw content and enrich it with processing metadata.

    If the content is valid JSON it is parsed into a dict; otherwise
    the raw string is wrapped in a simple envelope.
    """
    try:
        data = json.loads(raw_content)
    except (json.JSONDecodeError, TypeError):
        data = {"raw_content": raw_content}

    data["processed_timestamp"] = datetime.now(timezone.utc).isoformat()
    data["source_bucket"] = source_bucket
    data["source_key"] = object_key
    data["pipeline_version"] = "1.0.0"

    return data
