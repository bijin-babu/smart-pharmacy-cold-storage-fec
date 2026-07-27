#!/usr/bin/env bash
#
# Pushes the latest dashboard.html / chart.umd.min.js to the EC2 instance
# that's standing in for the on-site fog node, and restarts the small
# Python web server that serves them on port 80 behind the instance's
# Elastic IP.
#
# This is a separate script from deploy.sh because it talks to the
# instance over SSH rather than the AWS API, and needs its own inputs
# (an SSH target and a private key) that deploy.sh has no use for.
#
# Required environment variables:
#   EC2_HOST      - public DNS name or Elastic IP of the EC2 instance
#   EC2_KEY_PATH  - path to the private key (.pem) matching its key pair
# Optional:
#   EC2_USER              (default: ec2-user)
#   REMOTE_DASHBOARD_DIR  (default: dashboard, relative to the ec2-user home dir)

set -euo pipefail

: "${EC2_HOST:?Set EC2_HOST to the EC2 public DNS or Elastic IP}"
: "${EC2_KEY_PATH:?Set EC2_KEY_PATH to the path of the .pem key}"
EC2_USER="${EC2_USER:-ec2-user}"
REMOTE_DIR="${REMOTE_DASHBOARD_DIR:-dashboard}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$SCRIPT_DIR/../dashboard"

chmod 600 "$EC2_KEY_PATH" 2>/dev/null || true
SSH_OPTS=(-i "$EC2_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes)
TARGET="$EC2_USER@$EC2_HOST"

# Temporary diagnostic: prints verbose SSH negotiation/auth details so a
# connection failure in CI shows the real reason instead of a bare exit
# code. Safe to remove once the pipeline is confirmed working.
echo "== Diagnostic: verbose SSH connection test =="
ssh -v "${SSH_OPTS[@]}" "$TARGET" "echo remote-auth-ok" || true

echo "== Stopping any web server already on port 80 =="
ssh -v "${SSH_OPTS[@]}" "$TARGET" "sudo pkill -f 'http.server 80' || true"

echo "== Copying dashboard files to $EC2_HOST:~/$REMOTE_DIR =="
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/$REMOTE_DIR"
scp "${SSH_OPTS[@]}" "$DASHBOARD_DIR/dashboard.html" "$DASHBOARD_DIR/chart.umd.min.js" "$TARGET:~/$REMOTE_DIR/"

echo "== Starting the web server on port 80 =="
# nohup + redirected stdin/stdout/stderr so the process survives the SSH
# session closing, same as how the fog node itself is kept alive on this box.
ssh "${SSH_OPTS[@]}" "$TARGET" \
  "cd ~/$REMOTE_DIR && sudo nohup python3 -m http.server 80 > ~/dashboard.log 2>&1 < /dev/null &"

sleep 2

echo "== Verifying it's actually serving =="
ssh "${SSH_OPTS[@]}" "$TARGET" \
  "curl -sf -o /dev/null http://localhost/dashboard.html && echo 'dashboard.html is serving OK' || (echo 'WARNING: dashboard did not respond on port 80' && exit 1)"

echo "Dashboard redeployed: http://$EC2_HOST/dashboard.html"
