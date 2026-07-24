"""
lambda_ingest_telemetry.py

Triggered by the SQS 'telemetry-queue' (event source mapping set up in
infra/deploy.sh). Each SQS message body is a batch payload dispatched
by the fog node:

    {
      "device_id": "...",
      "batch_size": N,
      "dispatched_at": "...",
      "readings": [ {reading_id, device_id, sensor_type, unit, value,
                     timestamp, is_alert, ...}, ... ]
    }

Writes every reading into the DynamoDB Telemetry table:
    PK: sensor_type   SK: timestamp (ISO-8601, sorts correctly as text)

This is the 'process data from the fog node(s)' + persistence half of
the scalable backend layer. Lambda + SQS gives automatic, elastic
scaling of ingestion without managing servers.
"""

import json
import os
import boto3

TABLE_NAME = os.environ.get("TELEMETRY_TABLE", "ColdChainTelemetry")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    processed = 0
    failures = []

    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            readings = body.get("readings", [])
            with table.batch_writer() as batch:
                for r in readings:
                    item = {
                        "sensor_type": r["sensor_type"],
                        "timestamp": r["timestamp"],
                        "device_id": r.get("device_id"),
                        "reading_id": r.get("reading_id"),
                        "unit": r.get("unit"),
                        "value": str(r.get("value")),
                        "is_alert": bool(r.get("is_alert", False)),
                    }
                    if r.get("alert_reason"):
                        item["alert_reason"] = r["alert_reason"]
                    batch.put_item(Item=item)
                    processed += 1
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR processing record: {exc}")
            failures.append({"itemIdentifier": record.get("messageId")})

    print(f"Ingested {processed} telemetry readings")
    # Partial batch failure reporting for the SQS event source mapping
    return {"batchItemFailures": failures}
