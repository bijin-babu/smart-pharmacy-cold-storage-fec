"""
lambda_api_handler.py

Backs the API Gateway REST API that the dashboard polls. Implements
the 'responsive dashboards for the sensor types' requirement of the
scalable backend layer.

Routes (Lambda proxy integration, so this one function handles both):
  GET /telemetry                -> latest N readings for every sensor type
  GET /telemetry?sensor_type=X  -> latest N readings for sensor type X
  GET /telemetry?sensor_type=X&limit=100
  GET /alerts                   -> latest N alerts across all sensor types
  GET /alerts?limit=50

Returns JSON with permissive CORS headers so the standalone
dashboard.html (opened from a local file or any static host) can call
it directly.
"""

import json
import os
import boto3
from boto3.dynamodb.conditions import Key

TELEMETRY_TABLE = os.environ.get("TELEMETRY_TABLE", "ColdChainTelemetry")
ALERTS_TABLE = os.environ.get("ALERTS_TABLE", "ColdChainAlerts")
SENSOR_TYPES = ["temperature", "humidity", "door_status", "battery_level", "vibration"]
DEFAULT_LIMIT = 50

dynamodb = boto3.resource("dynamodb")
telemetry_table = dynamodb.Table(TELEMETRY_TABLE)
alerts_table = dynamodb.Table(ALERTS_TABLE)

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
}


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _query_latest(table, pk_name, pk_value, limit):
    resp = table.query(
        KeyConditionExpression=Key(pk_name).eq(pk_value),
        ScanIndexForward=False,  # newest first
        Limit=limit,
    )
    items = resp.get("Items", [])
    items.reverse()  # return chronological order for charting
    return items


def get_telemetry(qs):
    limit = int(qs.get("limit", DEFAULT_LIMIT))
    sensor_type = qs.get("sensor_type")

    if sensor_type:
        if sensor_type not in SENSOR_TYPES:
            return _response(400, {"error": f"unknown sensor_type '{sensor_type}'", "valid": SENSOR_TYPES})
        return _response(200, {sensor_type: _query_latest(telemetry_table, "sensor_type", sensor_type, limit)})

    result = {}
    for t in SENSOR_TYPES:
        result[t] = _query_latest(telemetry_table, "sensor_type", t, limit)
    return _response(200, result)


def get_alerts(qs):
    limit = int(qs.get("limit", DEFAULT_LIMIT))
    items = _query_latest(alerts_table, "pk", "ALERT", limit)
    return _response(200, {"alerts": items})


def handler(event, context):
    method = event.get("httpMethod", "GET")
    if method == "OPTIONS":
        return _response(200, {})

    path = event.get("path") or event.get("resource") or ""
    qs = event.get("queryStringParameters") or {}

    try:
        if path.rstrip("/").endswith("alerts"):
            return get_alerts(qs)
        return get_telemetry(qs)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}")
        return _response(500, {"error": str(exc)})
