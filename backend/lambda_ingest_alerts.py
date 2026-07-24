"""
lambda_ingest_alerts.py

Triggered by the SQS 'alerts-queue'. This is the low-latency
early-warning channel: the fog node sends a message here the instant
it detects a threshold breach (temperature excursion, door left open,
low battery, excess vibration, humidity spike), separate from the
periodic bulk telemetry batches.

Each message body is a single flagged reading:
    {reading_id, device_id, sensor_type, unit, value, timestamp,
     is_alert: true, alert_reason, raised_at}

Writes to the Alerts DynamoDB table (single fixed partition "ALERT" so
the dashboard/API can cheaply query "most recent alerts across all
sensor types" with one Query call), and publishes a notification to
the SNS alert topic if ALERTS_TOPIC_ARN is configured (e.g. for email
notification of pharmacy staff -- optional/stretch).
"""

import json
import os
import boto3

TABLE_NAME = os.environ.get("ALERTS_TABLE", "ColdChainAlerts")
TOPIC_ARN = os.environ.get("ALERTS_TOPIC_ARN")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
sns = boto3.client("sns") if TOPIC_ARN else None


def handler(event, context):
    processed = 0
    failures = []

    for record in event.get("Records", []):
        try:
            r = json.loads(record["body"])
            item = {
                "pk": "ALERT",
                "sk": r.get("raised_at") or r.get("timestamp"),
                "device_id": r.get("device_id"),
                "sensor_type": r.get("sensor_type"),
                "unit": r.get("unit"),
                "value": str(r.get("value")),
                "alert_reason": r.get("alert_reason"),
                "timestamp": r.get("timestamp"),
            }
            table.put_item(Item=item)
            processed += 1

            if sns:
                sns.publish(
                    TopicArn=TOPIC_ARN,
                    Subject=f"Cold storage alert: {item['sensor_type']}",
                    Message=(
                        f"Device {item['device_id']} - {item['sensor_type']} = "
                        f"{item['value']}{item.get('unit') or ''}\n"
                        f"Reason: {item['alert_reason']}\nAt: {item['timestamp']}"
                    ),
                )
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR processing alert record: {exc}")
            failures.append({"itemIdentifier": record.get("messageId")})

    print(f"Ingested {processed} alerts")
    return {"batchItemFailures": failures}
