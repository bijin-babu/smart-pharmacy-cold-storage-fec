# Edge-Assisted Smart Pharmacy Cold Storage Monitoring
### Fog-Based Early Warning + AWS Cloud Analytics
H9FECC Fog and Edge Computing — CA Project

## Architecture

```
[Edge: 5 mock sensors]  --readings-->  [Fog node]  --batches (10s)-->  [SQS telemetry-queue] --> [Lambda ingest] --> [DynamoDB Telemetry]
   temperature                          - threshold                                                                        |
   humidity                              checks                     --alert (instant)--->  [SQS alerts-queue]  --> [Lambda ingest] --> [DynamoDB Alerts] --> [SNS topic]
   door_status                         - batching                                                                          |
   battery_level                       - dispatch                                                                         v
   vibration                                                                                            [API Gateway] --> [Lambda API handler] --> dashboard.html (Chart.js)
```

- **Edge layer** (`sensors/sensor_simulator.py`): 5 independent threads, each generating one sensor type at its own configurable frequency, with occasional injected anomalies.
- **Fog layer** (`sensors/fog_node.py`): consumes edge readings, evaluates each against thresholds (early-warning), immediately dispatches any breach to the alerts queue, and separately batches normal telemetry for periodic bulk dispatch. This is the "processing at the fog" that avoids waiting on a cloud round-trip for safety-critical anomalies.
- **Cloud backend** (`backend/*.py` + `infra/deploy.sh`): serverless — SQS decouples ingestion, Lambda scales automatically per queue depth, DynamoDB is on-demand (no capacity planning), API Gateway + Lambda serve the dashboard. This is the "scalable backend" story for the report (autoscaling via FaaS, queue-based decoupling, on-demand storage).
- **Dashboard** (`dashboard/dashboard.html`): standalone HTML/JS file (Chart.js from CDN), polls the API every 5s. Open it directly in a browser — no hosting required.

## Project layout

```
coldchain-fec/
  sensors/
    config.json          sensor + fog + AWS config
    sensor_simulator.py   edge layer
    fog_node.py            fog layer (run this)
    requirements.txt
  backend/
    lambda_ingest_telemetry.py   SQS(telemetry) -> DynamoDB
    lambda_ingest_alerts.py      SQS(alerts) -> DynamoDB + SNS
    lambda_api_handler.py        API Gateway -> DynamoDB reads
  infra/
    deploy.sh             provisions everything on AWS (idempotent)
    teardown.sh           tears everything down
  dashboard/
    dashboard.html        open in any browser
```

## 1. Run locally first (no AWS needed)

```bash
cd sensors
pip install -r requirements.txt --break-system-packages   # only boto3
python3 fog_node.py --duration 60
```

This runs in dry-run mode: sensors generate readings, the fog node evaluates thresholds and prints what it *would* send to SQS. Confirms the sensor/fog logic works before touching AWS. You should see periodic `[FOG] Dispatching telemetry batch...` lines and occasional `[FOG][EARLY-WARNING]` lines when an anomaly is injected.

## 2. Deploy the AWS backend (AWS Academy Learner Lab)

AWS Academy Learner Lab gives temporary session credentials and only lets you use the pre-existing **LabRole** (you cannot create IAM roles/users). `deploy.sh` is written around that constraint.

1. Start your Learner Lab session, click **AWS Details**, copy the credentials block.
2. In your terminal:
   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   export AWS_SESSION_TOKEN=...
   export AWS_DEFAULT_REGION=us-east-1
   ```
3. Run the deploy script:
   ```bash
   cd infra
   chmod +x deploy.sh
   ./deploy.sh
   ```
4. It prints the API base URL and queue URLs at the end, and saves them to `infra/.build/outputs.json`. Copy the `telemetry_queue_url` / `alerts_queue_url` into `sensors/config.json`'s `aws` block.

If your session credentials expire (~3-4 hours), just re-export new ones and re-run `./deploy.sh` — it detects existing resources and only updates Lambda code / fills in anything missing.

## 3. Send real data to AWS

```bash
cd sensors
python3 fog_node.py --live --duration 300
```

## 4. Open the dashboard

Open `dashboard/dashboard.html` in a browser, paste the API base URL from step 2 into the input box, click **Connect**. Charts and the alerts panel update every 5 seconds.

## 5. Tear down (save Learner Lab budget)

```bash
cd infra
./teardown.sh
```

## Mapping to the grading rubric

- **Sensor & fog layers (30%)**: 5 sensor types, configurable frequency (`config.json`), fog node batching + immediate early-warning dispatch — see `fog_node.py`.
- **Scalable backend (30%)**: SQS (decoupled ingress) + Lambda (FaaS/autoscaling) + DynamoDB (on-demand) + API Gateway, deployed to AWS — see `infra/deploy.sh`.
- **Report**: use this README's architecture section as the basis for your Architecture & Design section; cite the specific AWS scaling mechanisms (SQS buffering under load, Lambda concurrency scaling, DynamoDB on-demand capacity) when justifying "scalable."
- **Presentation/demo**: run `fog_node.py --live`, show an anomaly triggering the alerts panel live on the dashboard within a few seconds — that's your strongest demo moment.

## Notes / things to still decide

- SNS email alerts are wired up but **not subscribed** — subscribe your own email if you want live notifications (command printed by `deploy.sh`).
- No authentication on the API Gateway endpoints — fine for a class project scoped to a Learner Lab account; call this out as a known limitation / future work in the report if asked to critically analyze security.
- Consider adding CloudWatch Alarms on Lambda errors/DLQ depth if you want an extra scalability/observability talking point for the "critically analyse and justify" part of the report.
