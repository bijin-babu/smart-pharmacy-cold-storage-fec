# AWS Setup Notes

These are my own notes from setting up the AWS side of this project on an AWS Academy Learner Lab account. Keeping them here in case the Learner Lab quirks below trip up anyone else running this (or future me, next semester).

## What's actually happening

Five mock sensors (temperature, humidity, door, battery, vibration) generate readings locally. A fog node — just a Python process standing in for an on-site fog server — reads those, checks each one against a threshold, and does two things with it: batches the normal data every 10 seconds for the cloud, and immediately fires off anything that breaches a threshold as its own low-latency alert. Both paths go through SQS. Lambda picks messages off the queues and writes them into DynamoDB. A third Lambda sits behind API Gateway and serves that data to the dashboard.

## Before starting

- Python 3.9+ (`python3 --version`)
- AWS CLI v2 (`aws --version`)
- `zip` (Git Bash or WSL on Windows)

No Docker, Terraform, or CDK needed — `deploy.sh` is just plain AWS CLI calls, mainly because Terraform/CDK both try to manage IAM by default, which the Learner Lab account won't allow.

## Getting into the Learner Lab

Start the lab from the course page, wait for the AWS status dot to go green, then open "AWS Details" — there's a "Show" link next to AWS CLI that reveals a temporary credentials block (access key, secret key, session token).

This is a temporary account. Everything in it, including the credentials, expires — usually after a few hours of inactivity or whenever the lab session times out. That's expected, not a bug on my end; I just re-copy fresh credentials when it happens.

The big restriction: no creating IAM users, roles, or policies. There's exactly one usable execution role already sitting there, `LabRole`. Every Lambda in this project runs as `LabRole` because of that, not because it was the "best practice" choice — I call this out directly in the report since it affects the security story too (no least-privilege separation between the three functions).

Export the credentials into the terminal:

```bash
export AWS_ACCESS_KEY_ID=ASIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity   # sanity check — should return an assumed-role arn
```

## Testing locally before touching AWS at all

```bash
cd sensors
pip install -r requirements.txt --break-system-packages
python3 fog_node.py --duration 60
```

This is dry-run mode, so nothing hits AWS yet — it just prints what it would send. I ran this first specifically so that if something broke, I'd know it was a Python bug and not an AWS permissions problem. Anomalies are injected randomly (a 3-4% chance per tick), so if you don't see an `[FOG][EARLY-WARNING]` line within a minute, just run it again with a longer `--duration`.

## Deploying

```bash
cd infra
chmod +x deploy.sh
./deploy.sh
```

It's idempotent — I ended up re-running it a lot as my Learner Lab credentials kept expiring mid-session, and it just skips anything already created and pushes updated Lambda code on top.

Roughly what it creates: two DynamoDB tables on-demand billing (`ColdChainTelemetry` keyed by `sensor_type`/`timestamp`, `ColdChainAlerts` keyed by a fixed partition so the most recent alerts across every sensor are a single Query), two SQS queues (telemetry and alerts), an SNS topic, three Lambda functions on `LabRole`, the SQS-to-Lambda event source mappings, and an API Gateway with `/telemetry` and `/alerts` routes.

It prints an API base URL at the end — I copied that (and the two queue URLs) into `sensors/config.json`'s `"aws"` block.

If it fails partway: re-exporting credentials and re-running usually fixes it, since it picks up where it left off. The one error I actually hit was an `AccessDenied` on `iam:CreateRole` the very first time I tried creating a Lambda through the console instead of the script — turned out the console defaults to creating a new execution role unless you explicitly pick "use an existing role" and select `LabRole`. Wasted a good half hour on that one before I figured out what was going on.

## Sending real data and checking it landed

```bash
cd sensors
python3 fog_node.py --live --duration 300
```

To actually check DynamoDB rather than just trusting the dashboard:

```bash
aws dynamodb scan --table-name ColdChainTelemetry --limit 5 --region us-east-1
```

If that comes back empty, it's almost always the queue URLs in `config.json` still being placeholders, or the event source mapping not having been created properly.

## Dashboard

Just open `dashboard/dashboard.html` in a browser — no server needed. If the status pill says "connection error," check the browser console first; in my case it turned out to be the tracking-prevention feature in Edge silently blocking the CDN-hosted Chart.js script, fixed by vendoring the library locally instead of loading it from a CDN.

## Forcing an alert for the demo

Since anomalies are random, I temporarily narrowed a threshold in `config.json` (e.g. tightening the temperature band to 4.0–5.5°C) right before demoing, so ordinary sensor drift trips it within seconds instead of waiting on chance. Reverted it afterward so the actual report figures reflect the real thresholds.

## Cleaning up

```bash
cd infra
./teardown.sh
```

Everything here is billed per-use so idle cost is small, but I ran this between sessions anyway to stay well within the Learner Lab budget cap. `deploy.sh` rebuilds everything from scratch afterward if needed.

## Quick reference

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=... AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity

cd sensors && python3 fog_node.py --duration 60        # local dry run
cd infra && ./deploy.sh                                  # deploy/update
cd sensors && python3 fog_node.py --live --duration 300  # send real data
aws dynamodb scan --table-name ColdChainTelemetry --limit 5 --region us-east-1
cd infra && ./teardown.sh                                # clean up
```
