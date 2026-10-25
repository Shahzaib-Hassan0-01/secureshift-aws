"""SecureShift incident processor.

Triggered by SQS. Each SQS message carries an S3 "object created" event for an
incident photo uploaded under incidents/. For every photo the function:
  1. stores an incident record in DynamoDB
  2. sends an alert to the supervisor through SNS

Messages that fail are reported back to SQS individually (partial batch
response), so only the failed ones are retried and, after 3 attempts, moved
to the dead-letter queue.
"""

import json
import os
import uuid
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
TOPIC_ARN = os.environ["TOPIC_ARN"]

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
table = dynamodb.Table(TABLE_NAME)


def lambda_handler(event, context):
    failures = []

    for message in event.get("Records", []):
        try:
            process_message(message)
        except Exception as error:  # report this message only, keep the rest
            print(f"FAILED message {message.get('messageId')}: {error}")
            failures.append({"itemIdentifier": message["messageId"]})

    return {"batchItemFailures": failures}


def process_message(message):
    body = json.loads(message["body"])

    # S3 sends one test message when the event notification is created.
    if body.get("Event") == "s3:TestEvent":
        print("Skipping s3:TestEvent")
        return

    for record in body.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = unquote_plus(record["s3"]["object"]["key"])
        size = record["s3"]["object"].get("size", 0)

        # Creating a folder in the console uploads an empty "incidents/" object.
        if key.endswith("/"):
            print(f"Skipping folder marker {key}")
            continue

        # Test hook for the dead-letter queue: any file with "force-fail" in
        # its name raises an error on purpose.
        if "force-fail" in key:
            raise ValueError(f"Forced failure for DLQ test: {key}")

        incident = {
            "incidentId": str(uuid.uuid4()),
            "photoBucket": bucket,
            "photoKey": key,
            "photoSizeBytes": size,
            "uploadedAt": record.get("eventTime", ""),
            "processedAt": datetime.now(timezone.utc).isoformat(),
            "status": "NEW",
        }

        table.put_item(Item=incident)

        sns.publish(
            TopicArn=TOPIC_ARN,
            Subject="SecureShift: new incident reported",
            Message=(
                "A new incident photo was uploaded.\n\n"
                f"Incident ID: {incident['incidentId']}\n"
                f"Photo: s3://{bucket}/{key}\n"
                f"Uploaded at: {incident['uploadedAt']}\n"
                f"Status: {incident['status']}"
            ),
        )

        print(f"Stored and alerted incident {incident['incidentId']} for {key}")
