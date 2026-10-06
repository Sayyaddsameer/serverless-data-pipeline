import json
import os
import unittest
from unittest.mock import patch, MagicMock
from io import BytesIO


class TestDataProcessor(unittest.TestCase):
    """Unit tests for the Lambda handler's transformation logic.

    All AWS SDK calls are mocked so these tests run without
    network access or real credentials.
    """

    @classmethod
    def setUpClass(cls):
        """Set required environment variables before importing the handler."""
        os.environ["PROCESSED_DATA_BUCKET"] = "test-processed-bucket"
        os.environ["SIMULATE_ERROR_KEY"] = "error-file.json"

    def _build_sqs_event(self, bucket, key):
        """Construct a minimal SQS event wrapping an S3 notification."""
        s3_notification = {
            "Records": [
                {
                    "s3": {
                        "bucket": {"name": bucket},
                        "object": {"key": key},
                    }
                }
            ]
        }
        return {
            "Records": [
                {"body": json.dumps(s3_notification)}
            ]
        }

    @patch("data_processor.s3_client")
    def test_happy_path_json_input(self, mock_s3):
        """A valid JSON file is enriched and uploaded to the output bucket."""
        import data_processor

        source_payload = {"sensor_id": "abc", "value": 42}
        mock_s3.get_object.return_value = {
            "Body": BytesIO(json.dumps(source_payload).encode("utf-8"))
        }
        mock_s3.put_object.return_value = {}

        event = self._build_sqs_event("input-bucket", "readings/sample.json")
        result = data_processor.lambda_handler(event, None)

        self.assertEqual(result["statusCode"], 200)
        mock_s3.get_object.assert_called_once_with(
            Bucket="input-bucket", Key="readings/sample.json"
        )

        put_call_kwargs = mock_s3.put_object.call_args[1]
        self.assertEqual(put_call_kwargs["Bucket"], "test-processed-bucket")
        self.assertEqual(put_call_kwargs["Key"], "processed/readings/sample.json")

        written_body = json.loads(put_call_kwargs["Body"])
        self.assertEqual(written_body["sensor_id"], "abc")
        self.assertEqual(written_body["value"], 42)
        self.assertIn("processed_timestamp", written_body)
        self.assertEqual(written_body["source_bucket"], "input-bucket")
        self.assertEqual(written_body["source_key"], "readings/sample.json")
        self.assertEqual(written_body["pipeline_version"], "1.0.0")

    @patch("data_processor.s3_client")
    def test_happy_path_plain_text_input(self, mock_s3):
        """Non-JSON content is wrapped in an envelope before enrichment."""
        import data_processor

        mock_s3.get_object.return_value = {
            "Body": BytesIO(b"just some plain text")
        }
        mock_s3.put_object.return_value = {}

        event = self._build_sqs_event("input-bucket", "notes/readme.txt")
        result = data_processor.lambda_handler(event, None)

        self.assertEqual(result["statusCode"], 200)
        put_call_kwargs = mock_s3.put_object.call_args[1]
        written_body = json.loads(put_call_kwargs["Body"])
        self.assertEqual(written_body["raw_content"], "just some plain text")
        self.assertIn("processed_timestamp", written_body)

    @patch("data_processor.s3_client")
    def test_error_simulation_raises(self, mock_s3):
        """Uploading a file matching SIMULATE_ERROR_KEY causes a ValueError."""
        import data_processor

        event = self._build_sqs_event("input-bucket", "error-file.json")

        with self.assertRaises(ValueError) as ctx:
            data_processor.lambda_handler(event, None)

        self.assertIn("Simulated processing error", str(ctx.exception))
        mock_s3.get_object.assert_not_called()

    @patch("data_processor.s3_client")
    def test_non_s3_message_skipped(self, mock_s3):
        """Messages that do not contain S3 Records are silently skipped."""
        import data_processor

        event = {
            "Records": [
                {"body": json.dumps({"Event": "s3:TestEvent"})}
            ]
        }
        result = data_processor.lambda_handler(event, None)

        self.assertEqual(result["statusCode"], 200)
        mock_s3.get_object.assert_not_called()
        mock_s3.put_object.assert_not_called()

    def test_missing_env_var_raises(self):
        """Handler raises when PROCESSED_DATA_BUCKET is not set."""
        import data_processor

        original = os.environ.pop("PROCESSED_DATA_BUCKET", None)
        try:
            event = self._build_sqs_event("input-bucket", "test.json")
            with self.assertRaises(EnvironmentError):
                data_processor.lambda_handler(event, None)
        finally:
            if original is not None:
                os.environ["PROCESSED_DATA_BUCKET"] = original

    @patch("data_processor.s3_client")
    def test_transform_preserves_original_fields(self, mock_s3):
        """Original fields in the source JSON are preserved after transformation."""
        import data_processor

        source = {"alpha": 1, "beta": [2, 3], "nested": {"gamma": True}}
        mock_s3.get_object.return_value = {
            "Body": BytesIO(json.dumps(source).encode("utf-8"))
        }
        mock_s3.put_object.return_value = {}

        event = self._build_sqs_event("input-bucket", "data.json")
        data_processor.lambda_handler(event, None)

        written = json.loads(mock_s3.put_object.call_args[1]["Body"])
        self.assertEqual(written["alpha"], 1)
        self.assertEqual(written["beta"], [2, 3])
        self.assertEqual(written["nested"], {"gamma": True})


if __name__ == "__main__":
    unittest.main()
