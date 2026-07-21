#!/bin/bash
# ============================================================
# Wolof ASR — S3 + Parallel Lambda Pipeline
# Partie 1: S3 bucket, IAM, API Lambda (pas de Docker)
# Partie 2: Orchestrator via CodeBuild (pas de limite disque)
# ============================================================
set -e

ACCOUNT=335596040822
REGION=us-east-1
BUCKET="wolof-asr-audio-${ACCOUNT}"
ORCHESTRATOR_NAME="wolof-asr-orchestrator"
API_NAME="wolof-asr-api"
ASR_FUNCTION="wolof-asr"
ROLE_NAME="wolof-asr-s3-pipeline-role"

echo "=========================================="
echo "  WOLOF ASR — S3 + PARALLEL PIPELINE"
echo "=========================================="

# --- STEP 1: S3 Bucket ---
echo ""
echo "[1/6] S3 bucket..."

aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null && echo "  Bucket exists" || \
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" && echo "  Bucket created"

aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
  "CORSRules":[{"AllowedHeaders":["*"],"AllowedMethods":["PUT","GET","HEAD"],"AllowedOrigins":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3600}]
}'

aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules":[
    {"ID":"cleanup-uploads","Status":"Enabled","Filter":{"Prefix":"uploads/"},"Expiration":{"Days":7}},
    {"ID":"cleanup-results","Status":"Enabled","Filter":{"Prefix":"results/"},"Expiration":{"Days":30}},
    {"ID":"cleanup-jobs","Status":"Enabled","Filter":{"Prefix":"jobs/"},"Expiration":{"Days":30}}
  ]
}'
echo "  S3 ready (CORS + lifecycle)"

# --- STEP 2: IAM Role ---
echo ""
echo "[2/6] IAM role..."

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' 2>/dev/null || echo "  Role exists"

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name s3-pipeline-policy --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"lambda:InvokeFunction\"],\"Resource\":\"arn:aws:lambda:${REGION}:${ACCOUNT}:function:${ASR_FUNCTION}\"}
  ]
}"
echo "  Role ready"
sleep 8

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"

# --- STEP 3: API Lambda (zip, pas Docker) ---
echo ""
echo "[3/6] API Lambda..."

cd /tmp
rm -f api_handler.py api_handler.zip 2>/dev/null
curl -sL -o api_handler.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-lambda/api_handler.py
zip -j api_handler.zip api_handler.py

aws lambda get-function --function-name "$API_NAME" --region $REGION 2>/dev/null && \
  aws lambda update-function-code --function-name "$API_NAME" --zip-file fileb://api_handler.zip --region $REGION || \
  aws lambda create-function \
    --function-name "$API_NAME" \
    --runtime python3.11 \
    --handler "api_handler.lambda_handler" \
    --zip-file fileb://api_handler.zip \
    --role "$ROLE_ARN" \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={S3_BUCKET=$BUCKET}" \
    --region $REGION

echo "  API Lambda deployed"

# Wait for function
sleep 5

# Function URL for API
API_URL=$(aws lambda get-function-url-config --function-name "$API_NAME" --region $REGION --query 'FunctionUrl' --output text 2>/dev/null || echo "")
if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
  aws lambda add-permission --function-name "$API_NAME" --statement-id public-url --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE --region $REGION 2>/dev/null || true
  API_URL=$(aws lambda create-function-url-config --function-name "$API_NAME" --auth-type NONE --cors '{"AllowOrigins":["*"],"AllowMethods":["GET","POST"],"AllowHeaders":["Content-Type"]}' --region $REGION --query 'FunctionUrl' --output text)
fi
echo "  API URL: $API_URL"

# --- STEP 4: Orchestrator via CodeBuild ---
echo ""
echo "[4/6] Orchestrator (CodeBuild)..."

# Create ECR repo for orchestrator
aws ecr describe-repositories --repository-names wolof-orchestrator --region $REGION 2>/dev/null || \
  aws ecr create-repository --repository-name wolof-orchestrator --region $REGION
echo "  ECR repo ready"

# Reuse the codebuild role or create orchestrator build project
CODEBUILD_ROLE="arn:aws:iam::${ACCOUNT}:role/wolof-asr-codebuild-role"

# Add ECR and Lambda permissions to codebuild role
aws iam put-role-policy --role-name wolof-asr-codebuild-role --policy-name orchestrator-build --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"ecr:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"lambda:*\"],\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:*\"],\"Resource\":\"*\"}
  ]
}" 2>/dev/null || true

ORCH_BUILDSPEC=$(cat << 'BSEOF'
version: 0.2
phases:
  pre_build:
    commands:
      - echo Logging in to ECR...
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
  build:
    commands:
      - mkdir -p /tmp/orch && cd /tmp/orch
      - curl -sL -o orchestrator.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-lambda/orchestrator.py
      - |
        cat > Dockerfile << 'DEOF'
        FROM public.ecr.aws/lambda/python:3.11
        RUN yum install -y tar xz && curl -sL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz | tar xJ --strip-components=1 -C /usr/local/bin/ --wildcards '*/ffmpeg' '*/ffprobe' && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && yum clean all
        RUN pip install --no-cache-dir boto3
        COPY orchestrator.py ${LAMBDA_TASK_ROOT}/
        CMD ["orchestrator.lambda_handler"]
        DEOF
      - docker build --platform linux/amd64 -t wolof-orchestrator .
  post_build:
    commands:
      - docker tag wolof-orchestrator:latest 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-orchestrator:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-orchestrator:latest
      - echo DONE
BSEOF
)

# Create/update CodeBuild project for orchestrator
ENCODED_SPEC=$(echo "$ORCH_BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

aws codebuild create-project \
  --name "wolof-orchestrator-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_MEDIUM","privilegedMode":true}' \
  --service-role "$CODEBUILD_ROLE" \
  --region $REGION 2>/dev/null && echo "  Project created" || \
aws codebuild update-project \
  --name "wolof-orchestrator-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_MEDIUM","privilegedMode":true}' \
  --service-role "$CODEBUILD_ROLE" \
  --region $REGION && echo "  Project updated"

# Start build
BUILD_ID=$(aws codebuild start-build --project-name "wolof-orchestrator-build" --region $REGION --query 'build.id' --output text)
echo "  Build started: $BUILD_ID"
echo "  Waiting (~5 min)..."

while true; do
  sleep 15
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Orchestrator image ready!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED!"
    aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].phases[?phaseStatus==`FAILED`]'
    exit 1
  fi
done

# --- STEP 5: Deploy Orchestrator Lambda ---
echo ""
echo "[5/6] Deploy Orchestrator Lambda..."

ORCH_REPO="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/wolof-orchestrator"

aws lambda get-function --function-name "$ORCHESTRATOR_NAME" --region $REGION 2>/dev/null && \
  aws lambda update-function-code --function-name "$ORCHESTRATOR_NAME" --image-uri "$ORCH_REPO:latest" --region $REGION || \
  aws lambda create-function \
    --function-name "$ORCHESTRATOR_NAME" \
    --package-type Image \
    --code "ImageUri=$ORCH_REPO:latest" \
    --role "$ROLE_ARN" \
    --timeout 900 \
    --memory-size 3008 \
    --ephemeral-storage '{"Size": 10240}' \
    --environment "Variables={S3_BUCKET=$BUCKET,ASR_FUNCTION_NAME=$ASR_FUNCTION}" \
    --region $REGION

echo "  Orchestrator deployed (15min timeout, 10GB /tmp)"

# Wait for function to be active
sleep 10

# --- STEP 6: S3 Trigger ---
echo ""
echo "[6/6] S3 trigger..."

ORCH_ARN=$(aws lambda get-function --function-name "$ORCHESTRATOR_NAME" --region $REGION --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission \
  --function-name "$ORCHESTRATOR_NAME" \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${BUCKET}" \
  --source-account "$ACCOUNT" \
  --region $REGION 2>/dev/null || echo "  Permission exists"

aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "{
  \"LambdaFunctionConfigurations\":[{
    \"Id\":\"TriggerOrchestrator\",
    \"LambdaFunctionArn\":\"$ORCH_ARN\",
    \"Events\":[\"s3:ObjectCreated:*\"],
    \"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"uploads/\"}]}}
  }]
}"

echo ""
echo "=========================================="
echo "  PIPELINE S3 DEPLOYE !"
echo "=========================================="
echo ""
echo "  API URL:  $API_URL"
echo ""
echo "  USAGE:"
echo "  1. POST ${API_URL}upload"
echo "     Body: {\"filename\":\"audio.mp3\"}"
echo "     -> Returns: {job_id, upload_url}"
echo ""
echo "  2. PUT fichier audio vers upload_url"
echo ""
echo "  3. GET ${API_URL}status/{job_id}"
echo "     -> Returns: {status, result}"
echo "=========================================="
