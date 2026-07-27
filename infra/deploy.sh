#!/usr/bin/env bash
#
# Deploys the Smart Pharmacy Cold Storage backend to an AWS Academy
# Learner Lab account. Designed around Learner Lab's constraints:
#   - No IAM role/policy/user creation allowed -> reuses the built-in
#     "LabRole" for every Lambda function.
#   - Session credentials from the Learner Lab "AWS Details" panel
#     (Access Key, Secret Key, Session Token) must already be exported
#     as environment variables before running this script:
#       export AWS_ACCESS_KEY_ID=...
#       export AWS_SECRET_ACCESS_KEY=...
#       export AWS_SESSION_TOKEN=...
#       export AWS_DEFAULT_REGION=us-east-1
#
# Safe to re-run: every step checks whether the resource already
# exists before creating it (so a fresh Learner Lab session that
# rotated credentials can just re-run this to pick up where it left
# off, or to push updated Lambda code).
#
# Requires: aws cli v2, jq, zip.

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROJECT="coldchain"
TELEMETRY_TABLE="ColdChainTelemetry"
ALERTS_TABLE="ColdChainAlerts"
TELEMETRY_QUEUE="${PROJECT}-telemetry-queue"
ALERTS_QUEUE="${PROJECT}-alerts-queue"
SNS_TOPIC="${PROJECT}-alerts"
API_NAME="${PROJECT}-api"
STAGE="prod"
RUNTIME="python3.12"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/../backend"
BUILD_DIR="$SCRIPT_DIR/.build"
mkdir -p "$BUILD_DIR"

echo "== Checking AWS identity =="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
echo "Account: $ACCOUNT_ID"
echo "Using execution role: $LAB_ROLE_ARN"
echo "Region: $REGION"

# ---------------------------------------------------------------------------
# 1. DynamoDB tables
# ---------------------------------------------------------------------------
create_table_if_missing() {
  local name="$1" pk="$2" sk="$3"
  if aws dynamodb describe-table --table-name "$name" --region "$REGION" >/dev/null 2>&1; then
    echo "DynamoDB table $name already exists, skipping."
  else
    echo "Creating DynamoDB table $name..."
    aws dynamodb create-table \
      --table-name "$name" \
      --attribute-definitions AttributeName="$pk",AttributeType=S AttributeName="$sk",AttributeType=S \
      --key-schema AttributeName="$pk",KeyType=HASH AttributeName="$sk",KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION" >/dev/null
    aws dynamodb wait table-exists --table-name "$name" --region "$REGION"
  fi
}

echo "== DynamoDB =="
create_table_if_missing "$TELEMETRY_TABLE" "sensor_type" "timestamp"
create_table_if_missing "$ALERTS_TABLE" "pk" "sk"

# ---------------------------------------------------------------------------
# 2. SQS queues
# ---------------------------------------------------------------------------
get_or_create_queue() {
  local name="$1"
  local url
  url=$(aws sqs get-queue-url --queue-name "$name" --region "$REGION" --query QueueUrl --output text 2>/dev/null || true)
  if [ -z "$url" ] || [ "$url" == "None" ]; then
    echo "Creating SQS queue $name..." >&2
    url=$(aws sqs create-queue --queue-name "$name" --region "$REGION" --query QueueUrl --output text)
  else
    echo "SQS queue $name already exists, skipping." >&2
  fi
  echo "$url"
}

echo "== SQS =="
TELEMETRY_QUEUE_URL=$(get_or_create_queue "$TELEMETRY_QUEUE")
ALERTS_QUEUE_URL=$(get_or_create_queue "$ALERTS_QUEUE")
TELEMETRY_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$TELEMETRY_QUEUE_URL" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text)
ALERTS_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$ALERTS_QUEUE_URL" --attribute-names QueueArn --region "$REGION" --query 'Attributes.QueueArn' --output text)
echo "Telemetry queue: $TELEMETRY_QUEUE_URL"
echo "Alerts queue:    $ALERTS_QUEUE_URL"

# ---------------------------------------------------------------------------
# 3. SNS topic (early-warning notifications, optional but cheap to include)
# ---------------------------------------------------------------------------
echo "== SNS =="
SNS_TOPIC_ARN=$(aws sns create-topic --name "$SNS_TOPIC" --region "$REGION" --query TopicArn --output text)
echo "Alerts topic: $SNS_TOPIC_ARN"
echo "(Optional) subscribe your email:"
echo "  aws sns subscribe --topic-arn $SNS_TOPIC_ARN --protocol email --notification-endpoint you@example.com --region $REGION"

# ---------------------------------------------------------------------------
# 4. Lambda functions
# ---------------------------------------------------------------------------
package_lambda() {
  local src_file="$1" zip_name="$2"
  (cd "$BACKEND_DIR" && zip -q -j "$BUILD_DIR/$zip_name" "$src_file")
}

deploy_lambda() {
  local fn_name="$1" handler="$2" zip_name="$3" env_json="$4"
  if aws lambda get-function --function-name "$fn_name" --region "$REGION" >/dev/null 2>&1; then
    echo "Updating code for $fn_name..."
    aws lambda update-function-code \
      --function-name "$fn_name" \
      --zip-file "fileb://$BUILD_DIR/$zip_name" \
      --region "$REGION" >/dev/null
    aws lambda wait function-updated --function-name "$fn_name" --region "$REGION"
    aws lambda update-function-configuration \
      --function-name "$fn_name" \
      --environment "$env_json" \
      --region "$REGION" >/dev/null
  else
    echo "Creating $fn_name..."
    aws lambda create-function \
      --function-name "$fn_name" \
      --runtime "$RUNTIME" \
      --role "$LAB_ROLE_ARN" \
      --handler "$handler" \
      --timeout 30 \
      --memory-size 256 \
      --zip-file "fileb://$BUILD_DIR/$zip_name" \
      --environment "$env_json" \
      --region "$REGION" >/dev/null
  fi
  aws lambda wait function-active --function-name "$fn_name" --region "$REGION"
}

echo "== Lambda: packaging =="
package_lambda "lambda_ingest_telemetry.py" "ingest_telemetry.zip"
package_lambda "lambda_ingest_alerts.py" "ingest_alerts.zip"
package_lambda "lambda_api_handler.py" "api_handler.zip"

echo "== Lambda: deploying =="
INGEST_TELEMETRY_FN="${PROJECT}-ingest-telemetry"
INGEST_ALERTS_FN="${PROJECT}-ingest-alerts"
API_HANDLER_FN="${PROJECT}-api-handler"

deploy_lambda "$INGEST_TELEMETRY_FN" "lambda_ingest_telemetry.handler" "ingest_telemetry.zip" \
  "{\"Variables\":{\"TELEMETRY_TABLE\":\"$TELEMETRY_TABLE\"}}"

deploy_lambda "$INGEST_ALERTS_FN" "lambda_ingest_alerts.handler" "ingest_alerts.zip" \
  "{\"Variables\":{\"ALERTS_TABLE\":\"$ALERTS_TABLE\",\"ALERTS_TOPIC_ARN\":\"$SNS_TOPIC_ARN\"}}"

deploy_lambda "$API_HANDLER_FN" "lambda_api_handler.handler" "api_handler.zip" \
  "{\"Variables\":{\"TELEMETRY_TABLE\":\"$TELEMETRY_TABLE\",\"ALERTS_TABLE\":\"$ALERTS_TABLE\"}}"

INGEST_TELEMETRY_ARN=$(aws lambda get-function --function-name "$INGEST_TELEMETRY_FN" --region "$REGION" --query 'Configuration.FunctionArn' --output text)
INGEST_ALERTS_ARN=$(aws lambda get-function --function-name "$INGEST_ALERTS_FN" --region "$REGION" --query 'Configuration.FunctionArn' --output text)
API_HANDLER_ARN=$(aws lambda get-function --function-name "$API_HANDLER_FN" --region "$REGION" --query 'Configuration.FunctionArn' --output text)

# ---------------------------------------------------------------------------
# 5. SQS -> Lambda event source mappings
# ---------------------------------------------------------------------------
create_mapping_if_missing() {
  local fn_name="$1" queue_arn="$2"
  local existing
  existing=$(aws lambda list-event-source-mappings --function-name "$fn_name" --region "$REGION" \
    --query "EventSourceMappings[?EventSourceArn=='$queue_arn'].UUID" --output text)
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    echo "Event source mapping for $fn_name already exists, skipping."
  else
    echo "Creating event source mapping: $queue_arn -> $fn_name"
    aws lambda create-event-source-mapping \
      --function-name "$fn_name" \
      --event-source-arn "$queue_arn" \
      --batch-size 10 \
      --function-response-types ReportBatchItemFailures \
      --region "$REGION" >/dev/null
  fi
}

echo "== SQS event source mappings =="
create_mapping_if_missing "$INGEST_TELEMETRY_FN" "$TELEMETRY_QUEUE_ARN"
create_mapping_if_missing "$INGEST_ALERTS_FN" "$ALERTS_QUEUE_ARN"

# ---------------------------------------------------------------------------
# 6. API Gateway (REST API, Lambda proxy integration)
# ---------------------------------------------------------------------------
echo "== API Gateway =="
API_ID=$(aws apigateway get-rest-apis --region "$REGION" --query "items[?name=='$API_NAME'].id" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
  echo "Creating REST API $API_NAME..."
  API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --region "$REGION" --query id --output text)
else
  echo "REST API $API_NAME already exists ($API_ID)."
fi

ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" --query "items[?path=='/'].id" --output text)

create_resource_if_missing() {
  local path_part="$1"
  local id
  id=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" --query "items[?pathPart=='$path_part'].id" --output text)
  if [ -z "$id" ] || [ "$id" == "None" ]; then
    id=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part "$path_part" --region "$REGION" --query id --output text)
  fi
  echo "$id"
}

wire_get_method() {
  local resource_id="$1" lambda_arn="$2"
  aws apigateway put-method \
    --rest-api-id "$API_ID" --resource-id "$resource_id" \
    --http-method GET --authorization-type NONE --region "$REGION" >/dev/null 2>&1 || true

  aws apigateway put-integration \
    --rest-api-id "$API_ID" --resource-id "$resource_id" \
    --http-method GET --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${lambda_arn}/invocations" \
    --region "$REGION" >/dev/null

  aws lambda add-permission \
    --function-name "$lambda_arn" \
    --statement-id "apigw-${API_ID}-$(basename "$resource_id")" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/GET/*" \
    --region "$REGION" >/dev/null 2>&1 || true
}

TELEMETRY_RESOURCE_ID=$(create_resource_if_missing "telemetry")
ALERTS_RESOURCE_ID=$(create_resource_if_missing "alerts")

wire_get_method "$TELEMETRY_RESOURCE_ID" "$API_HANDLER_ARN"
wire_get_method "$ALERTS_RESOURCE_ID" "$API_HANDLER_ARN"

echo "Deploying API stage '$STAGE'..."
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" --region "$REGION" >/dev/null

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE}"

# ---------------------------------------------------------------------------
# 7. Dashboard hosting (S3 static website)
# ---------------------------------------------------------------------------
echo "== S3 dashboard hosting =="
DASHBOARD_BUCKET="${PROJECT}-dashboard-${ACCOUNT_ID}"
DASHBOARD_DIR="$SCRIPT_DIR/../dashboard"

if aws s3api head-bucket --bucket "$DASHBOARD_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "S3 bucket $DASHBOARD_BUCKET already exists, skipping creation."
else
  echo "Creating S3 bucket $DASHBOARD_BUCKET..."
  if [ "$REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$DASHBOARD_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$DASHBOARD_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
fi

# Static website hosting serves plain HTML/JS over public HTTP; this bucket
# holds no sensitive data (the dashboard is a client that calls the already-
# public API Gateway endpoints), so public read access is acceptable here.
aws s3api put-public-access-block --bucket "$DASHBOARD_BUCKET" --region "$REGION" \
  --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false >/dev/null

aws s3 website "s3://$DASHBOARD_BUCKET/" --index-document dashboard.html --region "$REGION"

cat > "$BUILD_DIR/dashboard-bucket-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${DASHBOARD_BUCKET}/*"
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$DASHBOARD_BUCKET" --region "$REGION" \
  --policy "file://$BUILD_DIR/dashboard-bucket-policy.json"

aws s3 cp "$DASHBOARD_DIR/dashboard.html" "s3://$DASHBOARD_BUCKET/dashboard.html" --region "$REGION" >/dev/null
aws s3 cp "$DASHBOARD_DIR/chart.umd.min.js" "s3://$DASHBOARD_BUCKET/chart.umd.min.js" --region "$REGION" >/dev/null

if [ "$REGION" == "us-east-1" ]; then
  DASHBOARD_URL="http://${DASHBOARD_BUCKET}.s3-website-${REGION}.amazonaws.com/dashboard.html"
else
  DASHBOARD_URL="http://${DASHBOARD_BUCKET}.s3-website.${REGION}.amazonaws.com/dashboard.html"
fi
echo "Dashboard hosted at: $DASHBOARD_URL"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
DEPLOYMENT COMPLETE
============================================================
DynamoDB tables:   $TELEMETRY_TABLE, $ALERTS_TABLE
SQS telemetry:     $TELEMETRY_QUEUE_URL
SQS alerts:        $ALERTS_QUEUE_URL
SNS alerts topic:  $SNS_TOPIC_ARN
API base URL:      $API_URL
  GET $API_URL/telemetry
  GET $API_URL/alerts
Dashboard URL:     $DASHBOARD_URL

Next steps:
1. Update sensors/config.json "aws" block:
     "telemetry_queue_url": "$TELEMETRY_QUEUE_URL"
     "alerts_queue_url":    "$ALERTS_QUEUE_URL"
2. Run the fog node for real:
     cd ../sensors && python3 fog_node.py --live --duration 300
3. Open the hosted dashboard (no local file needed):
     $DASHBOARD_URL
============================================================
EOF

# Persist outputs for other scripts / the dashboard
cat > "$BUILD_DIR/outputs.json" <<EOF
{
  "api_url": "$API_URL",
  "telemetry_queue_url": "$TELEMETRY_QUEUE_URL",
  "alerts_queue_url": "$ALERTS_QUEUE_URL",
  "sns_topic_arn": "$SNS_TOPIC_ARN",
  "region": "$REGION",
  "dashboard_url": "$DASHBOARD_URL",
  "dashboard_bucket": "$DASHBOARD_BUCKET"
}
EOF
echo "Saved to $BUILD_DIR/outputs.json"
