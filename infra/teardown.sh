#!/usr/bin/env bash
# Tears down every resource created by deploy.sh. Useful to stay within
# AWS Academy Learner Lab budget/limits between work sessions.
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROJECT="coldchain"
TELEMETRY_TABLE="ColdChainTelemetry"
ALERTS_TABLE="ColdChainAlerts"
TELEMETRY_QUEUE="${PROJECT}-telemetry-queue"
ALERTS_QUEUE="${PROJECT}-alerts-queue"
SNS_TOPIC="${PROJECT}-alerts"
API_NAME="${PROJECT}-api"
INGEST_TELEMETRY_FN="${PROJECT}-ingest-telemetry"
INGEST_ALERTS_FN="${PROJECT}-ingest-alerts"
API_HANDLER_FN="${PROJECT}-api-handler"

echo "== Removing API Gateway =="
API_ID=$(aws apigateway get-rest-apis --region "$REGION" --query "items[?name=='$API_NAME'].id" --output text)
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$REGION"
  echo "Deleted API $API_ID"
fi

echo "== Removing event source mappings & Lambda functions =="
for fn in "$INGEST_TELEMETRY_FN" "$INGEST_ALERTS_FN" "$API_HANDLER_FN"; do
  uuids=$(aws lambda list-event-source-mappings --function-name "$fn" --region "$REGION" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true)
  for u in $uuids; do
    aws lambda delete-event-source-mapping --uuid "$u" --region "$REGION" >/dev/null || true
  done
  aws lambda delete-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1 && echo "Deleted $fn" || echo "$fn not found, skipping"
done

echo "== Removing SQS queues =="
for q in "$TELEMETRY_QUEUE" "$ALERTS_QUEUE"; do
  url=$(aws sqs get-queue-url --queue-name "$q" --region "$REGION" --query QueueUrl --output text 2>/dev/null || true)
  if [ -n "$url" ] && [ "$url" != "None" ]; then
    aws sqs delete-queue --queue-url "$url" --region "$REGION"
    echo "Deleted queue $q"
  fi
done

echo "== Removing SNS topic =="
topic_arn=$(aws sns list-topics --region "$REGION" --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC')].TopicArn" --output text)
if [ -n "$topic_arn" ] && [ "$topic_arn" != "None" ]; then
  aws sns delete-topic --topic-arn "$topic_arn" --region "$REGION"
  echo "Deleted topic $topic_arn"
fi

echo "== Removing DynamoDB tables =="
for t in "$TELEMETRY_TABLE" "$ALERTS_TABLE"; do
  if aws dynamodb describe-table --table-name "$t" --region "$REGION" >/dev/null 2>&1; then
    aws dynamodb delete-table --table-name "$t" --region "$REGION" >/dev/null
    echo "Deleted table $t"
  fi
done

echo "== Removing S3 dashboard bucket =="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DASHBOARD_BUCKET="${PROJECT}-dashboard-${ACCOUNT_ID}"
if aws s3api head-bucket --bucket "$DASHBOARD_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  aws s3 rm "s3://$DASHBOARD_BUCKET" --recursive --region "$REGION" >/dev/null
  aws s3api delete-bucket --bucket "$DASHBOARD_BUCKET" --region "$REGION"
  echo "Deleted bucket $DASHBOARD_BUCKET"
fi

echo "Teardown complete."
