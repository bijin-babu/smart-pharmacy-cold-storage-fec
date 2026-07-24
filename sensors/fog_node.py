"""
Fog layer for the Smart Pharmacy Cold Storage project.

The FogNode sits between the edge sensors and the AWS cloud backend.
Responsibilities (per the H9FECC brief):
  1. Receive sensor data from the edge layer (via the shared queue
     populated by sensor_simulator.py).
  2. Process it locally: threshold checks for early-warning detection,
     so anomalies (temp excursion, door left open, low battery,
     shock/vibration, humidity spike) are caught at the fog layer
     instead of waiting on a cloud round-trip.
  3. Dispatch payloads to the backend:
       - Normal telemetry is batched and dispatched every
         `dispatch_interval_sec` to the telemetry SQS queue (bulk,
         cost-efficient, analytics-oriented).
       - Any reading that breaches a threshold is dispatched
         immediately, individually, to a separate alerts SQS queue
         (low-latency early-warning channel), in addition to being
         included in the next normal batch for historical record.

Runs in two modes:
  - dry_run=True  -> prints what would be sent (no AWS credentials needed)
  - dry_run=False -> sends real messages via boto3 to SQS
"""

import json
import queue
import threading
import time
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    boto3 = None


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class ThresholdEngine:
    """Evaluates a reading against the configured fog-layer thresholds
    and returns (is_alert, reason)."""

    def __init__(self, thresholds):
        self.thresholds = thresholds
        self._door_open_since = {}

    def evaluate(self, reading):
        t = reading["sensor_type"]
        v = reading["value"]
        rule = self.thresholds.get(t)
        if not rule:
            return False, None

        if t == "temperature":
            if v < rule["min"] or v > rule["max"]:
                return True, f"temperature {v}{reading.get('unit','')} outside safe range [{rule['min']}, {rule['max']}]"
        elif t == "humidity":
            if v > rule["max"]:
                return True, f"humidity {v}% above max {rule['max']}%"
        elif t == "vibration":
            if v > rule["max"]:
                return True, f"vibration {v}g exceeds shock threshold {rule['max']}g"
        elif t == "battery_level":
            if v < rule["min"]:
                return True, f"battery at {v}% below minimum {rule['min']}%"
        elif t == "door_status":
            device = reading["device_id"]
            if v == 1:
                opened_at = self._door_open_since.setdefault(device, time.time())
                open_secs = time.time() - opened_at
                if open_secs > rule.get("max_open_sec", 20):
                    return True, f"door open for {int(open_secs)}s (> {rule.get('max_open_sec',20)}s)"
            else:
                self._door_open_since.pop(device, None)

        return False, None


class FogNode:
    def __init__(self, config, in_queue, stop_event, dry_run=True):
        self.config = config
        self.in_queue = in_queue
        self.stop_event = stop_event
        self.dry_run = dry_run

        fog_cfg = config["fog"]
        self.dispatch_interval_sec = fog_cfg.get("dispatch_interval_sec", 10)
        self.batch_size_max = fog_cfg.get("batch_size_max", 50)
        self.threshold_engine = ThresholdEngine(fog_cfg["thresholds"])

        self._batch = []
        self._batch_lock = threading.Lock()

        aws_cfg = config.get("aws", {})
        self.region = aws_cfg.get("region", "us-east-1")
        self.telemetry_queue_url = aws_cfg.get("telemetry_queue_url")
        self.alerts_queue_url = aws_cfg.get("alerts_queue_url")

        self._sqs = None
        if not self.dry_run:
            if boto3 is None:
                raise RuntimeError("boto3 is required for non-dry-run mode (pip install boto3)")
            self._sqs = boto3.client("sqs", region_name=self.region)

    # ---- dispatch helpers -------------------------------------------------

    def _send_sqs(self, queue_url, body):
        if self.dry_run or not queue_url or queue_url.startswith("REPLACE"):
            print(f"[DRY-RUN] -> {queue_url or '(no queue configured)'}: {json.dumps(body)}")
            return
        self._sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(body))

    def _dispatch_alert(self, reading, reason):
        payload = {**reading, "alert_reason": reason, "raised_at": _now_iso()}
        print(f"[FOG][EARLY-WARNING] {payload['sensor_type']}={payload['value']} :: {reason}")
        self._send_sqs(self.alerts_queue_url, payload)

    def _dispatch_batch(self):
        with self._batch_lock:
            if not self._batch:
                return
            batch, self._batch = self._batch, []

        payload = {
            "device_id": self.config.get("device_id"),
            "batch_size": len(batch),
            "dispatched_at": _now_iso(),
            "readings": batch,
        }
        print(f"[FOG] Dispatching telemetry batch of {len(batch)} readings")
        self._send_sqs(self.telemetry_queue_url, payload)

    # ---- main loops --------------------------------------------------------

    def _ingest_loop(self):
        """Consume readings from the edge layer, run early-warning
        checks, and buffer normal readings for batch dispatch."""
        while not self.stop_event.is_set():
            try:
                reading = self.in_queue.get(timeout=1)
            except queue.Empty:
                continue

            is_alert, reason = self.threshold_engine.evaluate(reading)
            reading["is_alert"] = is_alert
            if is_alert:
                reading["alert_reason"] = reason
                self._dispatch_alert(reading, reason)

            with self._batch_lock:
                self._batch.append(reading)
                if len(self._batch) >= self.batch_size_max:
                    threading.Thread(target=self._dispatch_batch, daemon=True).start()

    def _dispatch_loop(self):
        """Every dispatch_interval_sec, flush the buffered batch to the
        cloud telemetry queue, regardless of size."""
        while not self.stop_event.is_set():
            self.stop_event.wait(self.dispatch_interval_sec)
            if not self.stop_event.is_set():
                self._dispatch_batch()
        # final flush on shutdown
        self._dispatch_batch()

    def run(self):
        ingest_thread = threading.Thread(target=self._ingest_loop, daemon=True)
        dispatch_thread = threading.Thread(target=self._dispatch_loop, daemon=True)
        ingest_thread.start()
        dispatch_thread.start()
        return ingest_thread, dispatch_thread


if __name__ == "__main__":
    import argparse
    from sensor_simulator import load_config, start_sensors

    parser = argparse.ArgumentParser(description="Run sensor + fog layers")
    parser.add_argument("--config", default="config.json")
    parser.add_argument("--dry-run", action="store_true", default=True)
    parser.add_argument("--live", action="store_true", help="Actually send to AWS (overrides --dry-run)")
    parser.add_argument("--duration", type=int, default=60, help="Seconds to run before stopping")
    args = parser.parse_args()

    cfg = load_config(args.config)
    q = queue.Queue()
    stop = threading.Event()

    start_sensors(cfg, q, stop)
    fog = FogNode(cfg, q, stop, dry_run=not args.live)
    fog.run()

    print(f"Running sensor+fog simulation for {args.duration}s (dry_run={not args.live})...")
    try:
        time.sleep(args.duration)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        time.sleep(1)
        print("Stopped.")
