"""
Edge/sensor layer for the Smart Pharmacy Cold Storage project.

Simulates 5 sensor types attached to a pharmacy fridge/freezer unit:
  - temperature   (C)
  - humidity      (%)
  - door_status   (0 = closed, 1 = open)
  - battery_level (%)
  - vibration     (g)

Each sensor runs on its own thread at a configurable frequency
(frequency_sec) and pushes readings onto a shared thread-safe queue,
which the fog node (fog_node.py) consumes. This models independent,
asynchronous edge devices dispatching at their own rates, as required
by the brief ("generate data from 3-5 different sensor types with
configurable frequency & dispatch rates").

Occasional anomalies are injected (e.g. a temperature excursion, a
door left open, a battery drain) so the fog node's early-warning logic
has something to catch.
"""

import json
import queue
import random
import threading
import time
import uuid
from datetime import datetime, timezone


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class Sensor(threading.Thread):
    """A single simulated sensor. Generates one reading every
    `frequency_sec` seconds and puts it on the shared output queue."""

    def __init__(self, device_id, spec, out_queue, stop_event):
        super().__init__(daemon=True)
        self.device_id = device_id
        self.spec = spec
        self.out_queue = out_queue
        self.stop_event = stop_event
        self.sensor_type = spec["type"]
        self.frequency_sec = spec.get("frequency_sec", 5)

        # internal state per sensor type
        if self.sensor_type == "battery_level":
            self.value = spec.get("start_value", 100.0)
        elif self.sensor_type == "door_status":
            self.value = spec.get("normal_value", 0)
        else:
            lo, hi = spec.get("normal_range", [0, 1])
            self.value = (lo + hi) / 2.0

        self._anomaly_ticks_remaining = 0

    def _next_value(self):
        spec = self.spec
        t = self.sensor_type

        if t == "battery_level":
            if self._anomaly_ticks_remaining <= 0 and random.random() < spec.get("recharge_chance", 0.0):
                self.value = 100.0
            else:
                self.value = max(0.0, self.value - spec.get("drain_per_tick", 0.1))
            return round(self.value, 2)

        if t == "door_status":
            if self._anomaly_ticks_remaining > 0:
                self._anomaly_ticks_remaining -= 1
                self.value = spec.get("anomaly_value", 1)
            elif random.random() < spec.get("anomaly_chance", 0.0):
                self._anomaly_ticks_remaining = spec.get("anomaly_duration_ticks", 3) - 1
                self.value = spec.get("anomaly_value", 1)
            else:
                self.value = spec.get("normal_value", 0)
            return int(self.value)

        # continuous-valued sensors: temperature, humidity, vibration
        lo, hi = spec["normal_range"]
        step = spec.get("step", 0.2)

        if self._anomaly_ticks_remaining > 0:
            self._anomaly_ticks_remaining -= 1
            a_lo, a_hi = spec["anomaly_range"]
            self.value += random.uniform(-step, step)
            self.value = min(max(self.value, a_lo), a_hi)
        elif random.random() < spec.get("anomaly_chance", 0.0):
            a_lo, a_hi = spec["anomaly_range"]
            self._anomaly_ticks_remaining = spec.get("anomaly_duration_ticks", 3) - 1
            self.value = random.uniform(a_lo, a_hi)
        else:
            self.value += random.uniform(-step, step)
            self.value = min(max(self.value, lo), hi)

        return round(self.value, 2)

    def run(self):
        while not self.stop_event.is_set():
            reading = {
                "reading_id": str(uuid.uuid4()),
                "device_id": self.device_id,
                "sensor_type": self.sensor_type,
                "unit": self.spec.get("unit"),
                "value": self._next_value(),
                "timestamp": _now_iso(),
            }
            self.out_queue.put(reading)
            self.stop_event.wait(self.frequency_sec)


def load_config(path):
    with open(path) as f:
        return json.load(f)


def start_sensors(config, out_queue, stop_event):
    """Instantiate and start one Sensor thread per configured sensor.
    Returns the list of running threads."""
    device_id = config.get("device_id", "device-01")
    threads = []
    for spec in config["sensors"]:
        s = Sensor(device_id, spec, out_queue, stop_event)
        s.start()
        threads.append(s)
    return threads


if __name__ == "__main__":
    # Standalone smoke test: run sensors for 15s and print readings.
    cfg = load_config("config.json")
    q = queue.Queue()
    stop = threading.Event()
    start_sensors(cfg, q, stop)
    try:
        end = time.time() + 15
        while time.time() < end:
            try:
                r = q.get(timeout=1)
                print(r)
            except queue.Empty:
                pass
    finally:
        stop.set()
