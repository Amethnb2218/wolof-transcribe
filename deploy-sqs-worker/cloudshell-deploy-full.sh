#!/bin/bash
# ============================================================
# WOLOF ASR — ARCHITECTURE SQS + WORKER ECS + DYNAMODB
#
# Frontend -> API Lambda -> SQS -> ECS Worker -> S3/DynamoDB
#
# Zero timeout issues. Worker processes at its own pace.
# Cost: ~$85-95/mois (4 vCPU always-on + SQS + DynamoDB)
# ============================================================
set -e

ACCOUNT=335596040822
REGION=us-east-1
BUCKET="wolof-asr-audio-${ACCOUNT}"
QUEUE_NAME="wolof-asr-jobs.fifo"
DLQ_NAME="wolof-asr-jobs-dlq.fifo"
TABLE_NAME="wolof-asr-jobs"
CLUSTER_NAME="wolof-asr-cluster"
SERVICE_NAME="wolof-asr-worker"
TASK_FAMILY="wolof-asr-worker-task"
REPO_NAME="wolof-asr-worker"
API_LAMBDA_NAME="wolof-asr-api-v2"
ROLE_NAME="wolof-asr-worker-role"
LAMBDA_ROLE_NAME="wolof-asr-api-v2-role"
LOG_GROUP="/ecs/wolof-asr-worker"
CONTAINER_NAME="wolof-asr-worker"
PORT=8080

echo "=========================================="
echo "  WOLOF ASR — SQS + WORKER ARCHITECTURE"
echo "  4 vCPU / 8 GB — beam_size=5 — qualite max"
echo "=========================================="

# ==========================================================
# STEP 1: SQS Queues (FIFO for exactly-once processing)
# ==========================================================
echo ""
echo "[1/9] SQS Queues..."

# Dead Letter Queue
DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --region $REGION --query 'QueueUrl' --output text 2>/dev/null || echo "")
if [ -z "$DLQ_URL" ] || [ "$DLQ_URL" = "None" ]; then
  DLQ_URL=$(aws sqs create-queue \
    --queue-name "$DLQ_NAME" \
    --attributes '{"FifoQueue":"true","ContentBasedDeduplication":"false","MessageRetentionPeriod":"1209600"}' \
    --region $REGION --query 'QueueUrl' --output text)
  echo "  DLQ created: $DLQ_URL"
else
  echo "  DLQ exists: $DLQ_URL"
fi

DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --region $REGION --query 'Attributes.QueueArn' --output text)

# Main Queue
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --region $REGION --query 'QueueUrl' --output text 2>/dev/null || echo "")
if [ -z "$QUEUE_URL" ] || [ "$QUEUE_URL" = "None" ]; then
  QUEUE_URL=$(aws sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --attributes "{
      \"FifoQueue\":\"true\",
      \"ContentBasedDeduplication\":\"false\",
      \"VisibilityTimeout\":\"900\",
      \"MessageRetentionPeriod\":\"86400\",
      \"ReceiveMessageWaitTimeSeconds\":\"20\",
      \"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"
    }" \
    --region $REGION --query 'QueueUrl' --output text)
  echo "  Queue created: $QUEUE_URL"
else
  echo "  Queue exists: $QUEUE_URL"
fi

QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --region $REGION --query 'Attributes.QueueArn' --output text)
echo "  Queue ARN: $QUEUE_ARN"

# ==========================================================
# STEP 2: DynamoDB Table
# ==========================================================
echo ""
echo "[2/9] DynamoDB table..."

aws dynamodb describe-table --table-name "$TABLE_NAME" --region $REGION 2>/dev/null && echo "  Table exists" || \
aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions '[{"AttributeName":"job_id","AttributeType":"S"}]' \
  --key-schema '[{"AttributeName":"job_id","KeyType":"HASH"}]' \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION && echo "  Table created (on-demand billing)"

# Wait for table to be active
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region $REGION
echo "  Table active"

# Set TTL (auto-delete old jobs after 30 days)
aws dynamodb update-time-to-live \
  --table-name "$TABLE_NAME" \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" \
  --region $REGION 2>/dev/null || true

# ==========================================================
# STEP 3: S3 Bucket (reuse existing)
# ==========================================================
echo ""
echo "[3/9] S3 bucket..."
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null && echo "  Bucket exists" || \
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" && echo "  Bucket created"

aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
  "CORSRules":[{"AllowedHeaders":["*"],"AllowedMethods":["PUT","GET","HEAD"],"AllowedOrigins":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3600}]
}'

aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules":[
    {"ID":"cleanup-uploads","Status":"Enabled","Filter":{"Prefix":"uploads/"},"Expiration":{"Days":3}},
    {"ID":"cleanup-results","Status":"Enabled","Filter":{"Prefix":"results/"},"Expiration":{"Days":30}},
    {"ID":"cleanup-jobs","Status":"Enabled","Filter":{"Prefix":"jobs/"},"Expiration":{"Days":30}}
  ]
}'
echo "  S3 ready (CORS + lifecycle)"

# ==========================================================
# STEP 4: IAM Roles
# ==========================================================
echo ""
echo "[4/9] IAM roles..."

# ECS Task Role (worker needs S3, SQS, DynamoDB)
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Worker role exists"

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name worker-policy --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\",\"sqs:ChangeMessageVisibility\"],\"Resource\":\"${QUEUE_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",\"dynamodb:Query\"],\"Resource\":\"arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${TABLE_NAME}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"ecr:GetAuthorizationToken\",\"ecr:BatchGetImage\",\"ecr:GetDownloadUrlForLayer\"],\"Resource\":\"*\"}
  ]
}"
echo "  Worker role ready"

# Lambda API Role
aws iam create-role --role-name "$LAMBDA_ROLE_NAME" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Lambda role exists"

aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name api-policy --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:SendMessage\"],\"Resource\":\"${QUEUE_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\"],\"Resource\":\"arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${TABLE_NAME}\"}
  ]
}"
echo "  Lambda role ready"
sleep 10

# ==========================================================
# STEP 5: API Lambda (lightweight, no ML)
# ==========================================================
echo ""
echo "[5/9] API Lambda..."

cd /tmp
rm -f api_lambda.py api_lambda.zip 2>/dev/null
curl -sL -o api_lambda.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/api_lambda.py
zip -j api_lambda.zip api_lambda.py

LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${LAMBDA_ROLE_NAME}"

aws lambda get-function --function-name "$API_LAMBDA_NAME" --region $REGION 2>/dev/null && \
  aws lambda update-function-code --function-name "$API_LAMBDA_NAME" --zip-file fileb://api_lambda.zip --region $REGION > /dev/null || \
  aws lambda create-function \
    --function-name "$API_LAMBDA_NAME" \
    --runtime python3.11 \
    --handler "api_lambda.lambda_handler" \
    --zip-file fileb://api_lambda.zip \
    --role "$LAMBDA_ROLE_ARN" \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={S3_BUCKET=$BUCKET,SQS_QUEUE_URL=$QUEUE_URL,DYNAMODB_TABLE=$TABLE_NAME,AWS_REGION_=$REGION}" \
    --region $REGION > /dev/null

sleep 5

# Update env vars (in case function already existed)
aws lambda update-function-configuration \
  --function-name "$API_LAMBDA_NAME" \
  --environment "Variables={S3_BUCKET=$BUCKET,SQS_QUEUE_URL=$QUEUE_URL,DYNAMODB_TABLE=$TABLE_NAME}" \
  --region $REGION > /dev/null 2>/dev/null || true

# Function URL
API_URL=$(aws lambda get-function-url-config --function-name "$API_LAMBDA_NAME" --region $REGION --query 'FunctionUrl' --output text 2>/dev/null || echo "")
if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
  aws lambda add-permission --function-name "$API_LAMBDA_NAME" --statement-id public-url --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE --region $REGION 2>/dev/null || true
  API_URL=$(aws lambda create-function-url-config --function-name "$API_LAMBDA_NAME" --auth-type NONE --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"],"AllowHeaders":["*"]}' --region $REGION --query 'FunctionUrl' --output text)
fi
echo "  API URL: $API_URL"

# ==========================================================
# STEP 6: ECR + Build Worker Image
# ==========================================================
echo ""
echo "[6/9] Build worker Docker image..."

aws ecr describe-repositories --repository-names $REPO_NAME --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name $REPO_NAME --region $REGION > /dev/null
REPO_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME
echo "  Repo: $REPO_URI"

BUILDSPEC=$(cat << 'BSEOF'
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
  build:
    commands:
      - mkdir -p /tmp/worker && cd /tmp/worker
      - curl -sL -o worker.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/worker.py
      - curl -sL -o health_server.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/health_server.py
      - curl -sL -o entrypoint.sh https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/entrypoint.sh
      - curl -sL -o Dockerfile https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/Dockerfile
      - chmod +x entrypoint.sh
      - docker build --platform linux/amd64 -t wolof-asr-worker .
  post_build:
    commands:
      - docker tag wolof-asr-worker:latest 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-worker:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-worker:latest
      - echo DONE
BSEOF
)

ENCODED_SPEC=$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

aws codebuild create-project \
  --name "wolof-worker-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::${ACCOUNT}:role/wolof-asr-codebuild-role" \
  --region $REGION 2>/dev/null && echo "  CodeBuild project created" || \
aws codebuild update-project \
  --name "wolof-worker-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::${ACCOUNT}:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null && echo "  CodeBuild project updated"

BUILD_ID=$(aws codebuild start-build --project-name "wolof-worker-build" --region $REGION --query 'build.id' --output text)
echo "  Build started: $BUILD_ID"
echo "  Waiting (~12 min for model downloads)..."

while true; do
  sleep 20
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Worker image ready!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED!"
    aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].phases[?phaseStatus==`FAILED`]'
    exit 1
  fi
done

# ==========================================================
# STEP 7: ECS Cluster + Task Definition
# ==========================================================
echo ""
echo "[7/9] ECS Task definition..."

aws logs create-log-group --log-group-name $LOG_GROUP --region $REGION 2>/dev/null || true
aws ecs create-cluster --cluster-name $CLUSTER_NAME --capacity-providers FARGATE_SPOT FARGATE --default-capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' --region $REGION 2>/dev/null || true

# Execution role (for pulling images)
EXEC_ROLE_NAME="wolof-asr-fargate-execution-role"
aws iam create-role --role-name $EXEC_ROLE_NAME --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || true
aws iam attach-role-policy --role-name $EXEC_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

TASK_DEF=$(cat << TASKEOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "8192",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT}:role/${EXEC_ROLE_NAME}",
  "taskRoleArn": "arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}",
  "containerDefinitions": [
    {
      "name": "$CONTAINER_NAME",
      "image": "$REPO_URI:latest",
      "portMappings": [{"containerPort": $PORT, "protocol": "tcp"}],
      "environment": [
        {"name": "SQS_QUEUE_URL", "value": "$QUEUE_URL"},
        {"name": "DYNAMODB_TABLE", "value": "$TABLE_NAME"},
        {"name": "RESULTS_BUCKET", "value": "$BUCKET"},
        {"name": "AWS_REGION", "value": "$REGION"},
        {"name": "KAGGLE_USERNAME", "value": "${KAGGLE_USERNAME:-}"},
        {"name": "KAGGLE_KEY", "value": "${KAGGLE_KEY:-}"},
        {"name": "KAGGLE_KERNEL_SLUG", "value": "${KAGGLE_KERNEL_SLUG:-}"},
        {"name": "OMP_NUM_THREADS", "value": "4"},
        {"name": "MKL_NUM_THREADS", "value": "4"},
        {"name": "OPENBLAS_NUM_THREADS", "value": "4"},
        {"name": "TOKENIZERS_PARALLELISM", "value": "false"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "worker"
        }
      },
      "essential": true
    }
  ]
}
TASKEOF
)

aws ecs register-task-definition --cli-input-json "$TASK_DEF" --region $REGION > /dev/null
echo "  Task: 4 vCPU + 8 GB RAM + SQS worker"

# ==========================================================
# STEP 8: ECS Service
# ==========================================================
echo ""
echo "[8/9] ECS Service..."

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $REGION | tr '\t' ' ')
FIRST_SUBNET=$(echo $SUBNETS | awk '{print $1}')
SECOND_SUBNET=$(echo $SUBNETS | awk '{print $2}')

# Security group for worker (only needs outbound for SQS/S3/DynamoDB)
WORKER_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-worker-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region $REGION 2>/dev/null)
if [ "$WORKER_SG_ID" = "None" ] || [ -z "$WORKER_SG_ID" ]; then
  WORKER_SG_ID=$(aws ec2 create-security-group --group-name wolof-asr-worker-sg --description "Wolof ASR Worker" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
  echo "  Worker SG created: $WORKER_SG_ID"
else
  echo "  Worker SG exists: $WORKER_SG_ID"
fi

# Delete old service if exists
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 --region $REGION 2>/dev/null || true
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force --region $REGION 2>/dev/null || true
sleep 10

aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY \
  --desired-count 1 \
  --capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]' \
  --network-configuration "{\"awsvpcConfiguration\":{\"subnets\":[\"$FIRST_SUBNET\",\"$SECOND_SUBNET\"],\"securityGroups\":[\"$WORKER_SG_ID\"],\"assignPublicIp\":\"ENABLED\"}}" \
  --deployment-configuration '{"deploymentCircuitBreaker":{"enable":true,"rollback":true},"maximumPercent":200,"minimumHealthyPercent":100}' \
  --region $REGION > /dev/null

echo "  Worker service created (1 task, 4 vCPU, 8 GB)"

# ==========================================================
# STEP 9: CloudWatch Alarms
# ==========================================================
echo ""
echo "[9/9] CloudWatch alarms..."

# Alarm: messages stuck in DLQ
aws cloudwatch put-metric-alarm \
  --alarm-name "wolof-asr-dlq-messages" \
  --metric-name ApproximateNumberOfMessagesVisible \
  --namespace AWS/SQS \
  --dimensions "Name=QueueName,Value=$DLQ_NAME" \
  --statistic Sum \
  --period 300 \
  --evaluation-periods 1 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --region $REGION 2>/dev/null || true
echo "  DLQ alarm set"

# Alarm: queue backing up (messages waiting > 5 min)
aws cloudwatch put-metric-alarm \
  --alarm-name "wolof-asr-queue-backlog" \
  --metric-name ApproximateAgeOfOldestMessage \
  --namespace AWS/SQS \
  --dimensions "Name=QueueName,Value=$QUEUE_NAME" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 5 \
  --threshold 300 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --region $REGION 2>/dev/null || true
echo "  Backlog alarm set"

# ==========================================================
# DONE
# ==========================================================
echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE!"
echo "=========================================="
echo ""
echo "  API URL:       $API_URL"
echo "  SQS Queue:     $QUEUE_URL"
echo "  DynamoDB:      $TABLE_NAME"
echo "  Worker:        $SERVICE_NAME (4 vCPU / 8 GB)"
echo ""
echo "  USAGE:"
echo "  1. POST ${API_URL}upload"
echo "     Body: {\"filename\":\"audio.mp3\"}"
echo "     -> {job_id, upload_url}"
echo ""
echo "  2. PUT audio to upload_url"
echo ""
echo "  3. GET ${API_URL}status/{job_id}"
echo "     -> {status, stage, progress}"
echo ""
echo "  4. GET ${API_URL}result/{job_id}"
echo "     -> {text, segments, translation}"
echo ""
echo "  ARCHITECTURE:"
echo "    Upload -> S3 -> SQS FIFO -> Worker -> S3/DynamoDB"
echo "    No timeouts. Worker takes as long as needed."
echo "    beam_size=5, 4 cpu_threads, quality max."
echo ""
echo "  COST ESTIMATE: ~\$85-95/mois"
echo "    - Fargate 4 vCPU/8GB Spot: ~\$75/mois"
echo "    - SQS FIFO: ~\$1/mois (< 1M requests)"
echo "    - DynamoDB on-demand: ~\$2-5/mois"
echo "    - S3: ~\$2/mois"
echo "    - Lambda (API): ~\$1/mois"
echo "    - CloudWatch: ~\$2/mois"
echo ""
echo "  NEXT STEPS:"
echo "  1. Update frontend VITE_API_URL to: $API_URL"
echo "  2. (Optional) Add autoscaling for peak load"
echo "  3. (Optional) Request SageMaker GPU quota"
echo "=========================================="
