# Edge-Assisted Smart Pharmacy Cold Storage Monitoring

Fog and Edge Computing, CA project — MSc Cloud Computing, National College of Ireland.

This is my implementation of a fog-assisted IoT monitoring setup for a pharmacy cold storage fridge/freezer. Five simulated sensors (temperature, humidity, door, battery, vibration) feed a fog node that checks each reading against a threshold locally, and forwards everything to a serverless AWS backend that a small dashboard polls.

## How it fits together

```
coldchain-fec/
  sensors/
    config.json           sensor + fog + AWS config
    sensor_simulator.py   edge layer
    fog_node.py           fog layer (run this)
    requirements.txt
  backend/
    lambda_ingest_telemetry.py   SQS(telemetry) -> DynamoDB
    lambda_ingest_alerts.py      SQS(alerts) -> DynamoDB + SNS
    lambda_api_handler.py        API Gateway -> DynamoDB reads
  infra/
    deploy.sh             provisions everything on AWS (idempotent)
    teardown.sh           tears it all back down
  dashboard/
    dashboard.html        open in any browser
```

**Edge layer** (`sensors/sensor_simulator.py`) — 5 threads, one per sensor type, each generating readings at its own frequency with the occasional random anomaly so there's actually something for the fog node to catch.

**Fog layer** (`sensors/fog_node.py`) — this is really the core of the project. It reads from the sensors, checks each value against a threshold, and splits the response in two: anything that breaches a threshold gets fired off to the alerts queue immediately, and everything else gets batched and sent to the telemetry queue every 10 seconds. That split is the whole point of doing this at the fog layer instead of the cloud — the urgent stuff doesn't have to wait on a batch interval or a network round trip.

**Cloud backend** (`backend/*.py`, `infra/deploy.sh`) — SQS → Lambda → DynamoDB for both telemetry and alerts, plus a third Lambda behind API Gateway that the dashboard calls. Everything here is serverless, so it scales without me managing any servers.

**Dashboard** (`dashboard/dashboard.html`) — one self-contained HTML file with Chart.js, no build step needed. `deploy.sh` publishes it to an S3 static website automatically, so it's reachable from a public URL rather than only as a local file, and it polls the API every 5 seconds. There's also a second copy running directly on the EC2 instance (behind its Elastic IP, on port 80), served by a plain Python `http.server` process — `infra/deploy_dashboard_ec2.sh` pushes fresh copies of the two dashboard files over SSH and restarts that process, and CI runs it automatically on every push too.



## Running it

**1. Test locally, no AWS needed:**
```bash
cd sensors
pip install -r requirements.txt --break-system-packages
python3 fog_node.py --duration 60
```
Dry-run mode — prints what it would send instead of calling AWS.

**2. Deploy the backend** (requires an AWS account with a usable IAM role, e.g. AWS Academy Learner Lab's `LabRole`):
```bash
cd infra
chmod +x deploy.sh
./deploy.sh
```
Prints the API base URL, queue URLs, and the dashboard's S3 URL. Copy the queue URLs into `sensors/config.json`.

**3. Send real data to AWS:**
```bash
cd sensors
python3 fog_node.py --live --duration 300
```

**4. Open the dashboard** at the S3 URL printed by `deploy.sh`, or open `dashboard/dashboard.html` locally.

**5. Tear down when done:**
```bash
cd infra
./teardown.sh
```

## CI/CD

`.github/workflows/ci.yml` runs a syntax check and a dry-run test on every push, then deploys the backend to AWS automatically on a successful push to `main`, using session credentials stored as GitHub Actions secrets.
