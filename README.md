# Edge-Assisted Smart Pharmacy Cold Storage Monitoring

H9FECC (Fog and Edge Computing) CA project — MSc Cloud Computing, National College of Ireland.

This is my implementation of a fog-assisted IoT monitoring setup for a pharmacy cold storage fridge/freezer. Five simulated sensors (temperature, humidity, door, battery, vibration) feed a fog node that checks each reading against a threshold locally, and forwards everything to a serverless AWS backend that a small dashboard polls.

## How it fits together

```
[Edge: 5 mock sensors]  --readings-->  [Fog node]  --batches (10s)-->  [SQS telemetry-queue] --> [Lambda ingest] --> [DynamoDB Telemetry]
   temperature                          - threshold                                                                        |
   humidity                              checks                     --alert (instant)--->  [SQS alerts-queue]  --> [Lambda ingest] --> [DynamoDB Alerts] --> [SNS topic]
   door_status                         - batching                                                                          |
   battery_level                       - dispatch                                                                         v
   vibration                                                                                            [API Gateway] --> [Lambda API handler] --> dashboard.html (Chart.js)
```

**Edge layer** (`sensors/sensor_simulator.py`) — 5 threads, one per sensor type, each generating readings at its own frequency with the occasional random anomaly so there's actually something for the fog node to catch.

**Fog layer** (`sensors/fog_node.py`) — this is really the core of the project. It reads from the sensors, checks each value against a threshold, and splits the response in two: anything that breaches a threshold gets fired off to the alerts queue immediately, and everything else gets batched and sent to the telemetry queue every 10 seconds. That split is the whole point of doing this at the fog layer instead of the cloud — the urgent stuff doesn't have to wait on a batch interval or a network round trip.

**Cloud backend** (`backend/*.py`, `infra/deploy.sh`) — SQS → Lambda → DynamoDB for both telemetry and alerts, plus a third Lambda behind API Gateway that the dashboard calls. Everything here is serverless, so it scales without me managing any servers.

**Dashboard** (`dashboard/dashboard.html`) — one self-contained HTML file with Chart.js, no build step needed. `deploy.sh` publishes it to an S3 static website automatically, so it's reachable from a public URL rather than only as a local file, and it polls the API every 5 seconds.

## Project layout

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
  report/
    H9FECC_Report_Bijin_Babu.docx / .pdf
```

## Running it

**1. Test locally first, no AWS needed:**
```bash
cd sensors
pip install -r requirements.txt --break-system-packages   # just boto3
python3 fog_node.py --duration 60
```
This runs in dry-run mode — it prints what it *would* send instead of actually calling AWS. Good way to check the sensor/fog logic before dealing with real credentials. You should see periodic `[FOG] Dispatching telemetry batch...` lines and, less often, `[FOG][EARLY-WARNING]` lines when an anomaly gets injected.

**2. Deploy the backend.** I used an AWS Academy Learner Lab account, which only hands out temporary session credentials and a single pre-made `LabRole` (no creating your own IAM roles), so `deploy.sh` is built around that constraint. Export the session credentials from the Learner Lab's "AWS Details" panel, then:
```bash
cd infra
chmod +x deploy.sh
./deploy.sh
```
It prints the API base URL, queue URLs, and the dashboard's public S3 URL at the end — I copied the queue URLs into `sensors/config.json`. The script is idempotent, so if the Learner Lab credentials expire mid-session (they do, every few hours) I just re-export fresh ones and run it again; it skips anything already created.

**3. Send real data to AWS:**
```bash
cd sensors
python3 fog_node.py --live --duration 300
```

**4. Open the dashboard** — `deploy.sh` publishes `dashboard.html` to an S3 static website and prints the URL (something like `http://coldchain-dashboard-<account-id>.s3-website-us-east-1.amazonaws.com/dashboard.html`). It's already pointed at the deployed API, so it connects and starts drawing live charts right away, no local file needed. `dashboard/dashboard.html` still works fine opened locally too, if preferred.

**5. Tear down when done**, to stay inside the Learner Lab budget:
```bash
cd infra
./teardown.sh
```

## A few things worth knowing

- The SNS alerts topic exists but I never subscribed an email to it — an easy follow-up if I wanted real notifications instead of just the dashboard panel.
- No authentication on the API Gateway endpoints. Fine for a scoped class project with no real data behind it, but I've flagged it as a limitation in the report.
- `.github/workflows/ci.yml` runs a syntax check plus the dry-run test on every push, and a second job then runs `deploy.sh` against AWS using session credentials stored as GitHub Actions secrets, so a push to `main` automatically redeploys the backend and republishes the dashboard. Those secrets have to be refreshed manually whenever a new Learner Lab session starts, since Learner Lab only issues temporary, session-scoped credentials rather than long-lived ones.

Full report and reflection are in `report/`. `AWS_Implementation_Guide.md` has my own step-by-step notes from actually setting the AWS side up, in case any of the Learner Lab quirks trip someone else up too.
