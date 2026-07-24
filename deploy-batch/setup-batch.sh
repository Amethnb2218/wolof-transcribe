#!/bin/bash
# Setup complet AWS Batch pour transcription Wolof (GPU Spot + On-Demand + CPU fallback)
# A executer sur CloudShell une seule fois
set -e

REGION=us-east-1
ACCOUNT=335596040822
S3_BUCKET="wolof-transcriber-audio"
ECR_GPU_REPO="wolof-asr-batch-gpu"
ECR_CPU_REPO="wolof-asr-batch-cpu"

echo "=== WOLOF BATCH SETUP ==="
echo ""

# ============================================
echo "[1/12] Création bucket S3..."
aws s3api create-bucket --bucket $S3_BUCKET --region $REGION 2>/dev/null || echo "  (bucket existe déjà)"

aws s3api put-bucket-cors --bucket $S3_BUCKET --cors-configuration '{
  "CORSRules": [{
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["PUT", "POST", "GET"],
    "AllowedOrigins": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3600
  }]
}'

aws s3api put-bucket-lifecycle-configuration --bucket $S3_BUCKET --lifecycle-configuration '{
  "Rules": [
    {"ID": "delete-uploads-7d", "Prefix": "uploads/", "Status": "Enabled", "Expiration": {"Days": 7}},
    {"ID": "delete-results-30d", "Prefix": "results/", "Status": "Enabled", "Expiration": {"Days": 30}}
  ]
}'
echo "  Bucket: $S3_BUCKET (CORS + lifecycle)"

# ============================================
echo ""
echo "[2/12] Création repos ECR..."
aws ecr create-repository --repository-name $ECR_GPU_REPO --region $REGION > /dev/null 2>&1 || echo "  (GPU repo existe)"
aws ecr create-repository --repository-name $ECR_CPU_REPO --region $REGION > /dev/null 2>&1 || echo "  (CPU repo existe)"
echo "  GPU: $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_GPU_REPO"
echo "  CPU: $ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_CPU_REPO"

# ============================================
echo ""
echo "[3/12] Création rôles IAM..."

# Batch Job Role (container needs S3 access)
aws iam create-role --role-name wolof-batch-job-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null 2>&1 || true

aws iam put-role-policy --role-name wolof-batch-job-role --policy-name s3-access --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:ListBucket\"],
    \"Resource\": [\"arn:aws:s3:::$S3_BUCKET\", \"arn:aws:s3:::$S3_BUCKET/*\"]
  }]
}"

# EC2 Instance Profile (for GPU Batch compute)
aws iam create-role --role-name wolof-batch-ec2-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name wolof-batch-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role 2>/dev/null || true
aws iam attach-role-policy --role-name wolof-batch-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true

aws iam create-instance-profile --instance-profile-name wolof-batch-ec2-profile > /dev/null 2>&1 || true
aws iam add-role-to-instance-profile --instance-profile-name wolof-batch-ec2-profile --role-name wolof-batch-ec2-role 2>/dev/null || true

# Spot Fleet Role
aws iam create-role --role-name AmazonEC2SpotFleetTaggingRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"spotfleet.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name AmazonEC2SpotFleetTaggingRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole 2>/dev/null || true

# Lambda Role
aws iam create-role --role-name wolof-batch-lambda-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null 2>&1 || true
aws iam attach-role-policy --role-name wolof-batch-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam put-role-policy --role-name wolof-batch-lambda-role --policy-name batch-submit --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["batch:SubmitJob"], "Resource": "*"},
    {"Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"], "Resource": "arn:aws:s3:::wolof-transcriber-audio/*"}
  ]
}'

echo "  Roles created (batch-job, ec2, spot-fleet, lambda)"
sleep 10

# ============================================
echo ""
echo "[4/12] CloudWatch Log Group..."
aws logs create-log-group --log-group-name /aws/batch/wolof-asr --region $REGION 2>/dev/null || true
echo "  /aws/batch/wolof-asr"

# ============================================
echo ""
echo "[5/12] Récupération VPC/Subnets/SG..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --region $REGION --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')
SUBNET_LIST=$(echo $SUBNETS | tr ',' '\n' | head -2 | tr '\n' ',' | sed 's/,$//')

# Create security group for Batch
SG_ID=$(aws ec2 create-security-group --group-name wolof-batch-sg --description "Wolof Batch SG" --vpc-id $VPC_ID --region $REGION --query 'GroupId' --output text 2>/dev/null || \
  aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-batch-sg" --region $REGION --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-egress --group-id $SG_ID --protocol -1 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true

echo "  VPC: $VPC_ID"
echo "  Subnets: $SUBNET_LIST"
echo "  SG: $SG_ID"

# ============================================
echo ""
echo "[6/12] Launch Template GPU..."
GPU_AMI=$(aws ssm get-parameters --names /aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended --region $REGION --query 'Parameters[0].Value' --output text | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["image_id"])')

aws ec2 create-launch-template \
  --launch-template-name wolof-batch-gpu-lt \
  --launch-template-data "{
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {\"VolumeSize\": 80, \"VolumeType\": \"gp3\"}
    }]
  }" --region $REGION > /dev/null 2>&1 || echo "  (template existe)"
echo "  GPU AMI: $GPU_AMI"
echo "  Launch template: wolof-batch-gpu-lt (80GB gp3)"

# ============================================
echo ""
echo "[7/12] Compute Environments..."

# GPU Spot
aws batch create-compute-environment \
  --compute-environment-name wolof-gpu-spot \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "{
    \"type\": \"SPOT\",
    \"allocationStrategy\": \"SPOT_PRICE_CAPACITY_OPTIMIZED\",
    \"minvCpus\": 0,
    \"maxvCpus\": 4,
    \"desiredvCpus\": 0,
    \"instanceTypes\": [\"g4dn.xlarge\"],
    \"imageId\": \"$GPU_AMI\",
    \"launchTemplate\": {\"launchTemplateName\": \"wolof-batch-gpu-lt\", \"version\": \"\$Latest\"},
    \"subnets\": [$(echo $SUBNET_LIST | sed 's/\([^,]*\)/\"\1\"/g')],
    \"securityGroupIds\": [\"$SG_ID\"],
    \"instanceRole\": \"arn:aws:iam::$ACCOUNT:instance-profile/wolof-batch-ec2-profile\",
    \"spotIamFleetRole\": \"arn:aws:iam::$ACCOUNT:role/AmazonEC2SpotFleetTaggingRole\"
  }" \
  --region $REGION > /dev/null 2>&1 || echo "  (gpu-spot existe)"

# GPU On-Demand
aws batch create-compute-environment \
  --compute-environment-name wolof-gpu-ondemand \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "{
    \"type\": \"EC2\",
    \"allocationStrategy\": \"BEST_FIT_PROGRESSIVE\",
    \"minvCpus\": 0,
    \"maxvCpus\": 4,
    \"desiredvCpus\": 0,
    \"instanceTypes\": [\"g4dn.xlarge\"],
    \"imageId\": \"$GPU_AMI\",
    \"launchTemplate\": {\"launchTemplateName\": \"wolof-batch-gpu-lt\", \"version\": \"\$Latest\"},
    \"subnets\": [$(echo $SUBNET_LIST | sed 's/\([^,]*\)/\"\1\"/g')],
    \"securityGroupIds\": [\"$SG_ID\"],
    \"instanceRole\": \"arn:aws:iam::$ACCOUNT:instance-profile/wolof-batch-ec2-profile\"
  }" \
  --region $REGION > /dev/null 2>&1 || echo "  (gpu-ondemand existe)"

# Fargate CPU (last resort)
aws batch create-compute-environment \
  --compute-environment-name wolof-fargate-cpu \
  --type MANAGED \
  --state ENABLED \
  --compute-resources "{
    \"type\": \"FARGATE\",
    \"maxvCpus\": 4,
    \"subnets\": [$(echo $SUBNET_LIST | sed 's/\([^,]*\)/\"\1\"/g')],
    \"securityGroupIds\": [\"$SG_ID\"]
  }" \
  --region $REGION > /dev/null 2>&1 || echo "  (fargate-cpu existe)"

echo "  GPU Spot + GPU On-Demand + Fargate CPU"
echo "  Waiting for VALID state..."
sleep 30

# ============================================
echo ""
echo "[8/12] Job Queue..."
aws batch create-job-queue \
  --job-queue-name wolof-transcription-queue \
  --state ENABLED \
  --priority 1 \
  --compute-environment-order \
    "order=1,computeEnvironment=wolof-gpu-spot" \
    "order=2,computeEnvironment=wolof-gpu-ondemand" \
    "order=3,computeEnvironment=wolof-fargate-cpu" \
  --region $REGION > /dev/null 2>&1 || echo "  (queue existe)"
echo "  wolof-transcription-queue (GPU Spot > GPU OD > Fargate CPU)"

# ============================================
echo ""
echo "[9/12] Job Definitions..."

# GPU Job
aws batch register-job-definition \
  --job-definition-name wolof-transcribe-gpu \
  --type container \
  --container-properties "{
    \"image\": \"$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_GPU_REPO:latest\",
    \"resourceRequirements\": [
      {\"type\": \"VCPU\", \"value\": \"4\"},
      {\"type\": \"MEMORY\", \"value\": \"14000\"},
      {\"type\": \"GPU\", \"value\": \"1\"}
    ],
    \"jobRoleArn\": \"arn:aws:iam::$ACCOUNT:role/wolof-batch-job-role\",
    \"executionRoleArn\": \"arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole\",
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"/aws/batch/wolof-asr\",
        \"awslogs-region\": \"$REGION\",
        \"awslogs-stream-prefix\": \"gpu\"
      }
    },
    \"environment\": [
      {\"name\": \"S3_BUCKET\", \"value\": \"$S3_BUCKET\"}
    ]
  }" \
  --retry-strategy '{"attempts": 3, "evaluateOnExit": [{"onExitCode": "137", "action": "RETRY"}, {"onExitCode": "1", "action": "EXIT"}, {"action": "RETRY"}]}' \
  --timeout '{"attemptDurationSeconds": 10800}' \
  --region $REGION > /dev/null
echo "  wolof-transcribe-gpu (4 vCPU, 14GB, 1 GPU, 3h timeout, 3 retries on crash/spot)"

# CPU/Fargate Job
aws batch register-job-definition \
  --job-definition-name wolof-transcribe-cpu \
  --type container \
  --platform-capabilities FARGATE \
  --container-properties "{
    \"image\": \"$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_CPU_REPO:latest\",
    \"resourceRequirements\": [
      {\"type\": \"VCPU\", \"value\": \"4\"},
      {\"type\": \"MEMORY\", \"value\": \"16384\"}
    ],
    \"jobRoleArn\": \"arn:aws:iam::$ACCOUNT:role/wolof-batch-job-role\",
    \"executionRoleArn\": \"arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole\",
    \"fargatePlatformConfiguration\": {\"platformVersion\": \"LATEST\"},
    \"networkConfiguration\": {\"assignPublicIp\": \"ENABLED\"},
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"/aws/batch/wolof-asr\",
        \"awslogs-region\": \"$REGION\",
        \"awslogs-stream-prefix\": \"cpu\"
      }
    },
    \"environment\": [
      {\"name\": \"S3_BUCKET\", \"value\": \"$S3_BUCKET\"}
    ]
  }" \
  --retry-strategy "{\"attempts\": 2}" \
  --timeout "{\"attemptDurationSeconds\": 14400}" \
  --region $REGION > /dev/null
echo "  wolof-transcribe-cpu (4 vCPU, 16GB Fargate, 4h timeout)"

# ============================================
echo ""
echo "[10/12] Lambda Trigger..."

cd /tmp
rm -rf wolof-lambda-batch
mkdir wolof-lambda-batch && cd wolof-lambda-batch
cat > index.py << 'PYEOF'
import json
import os
import boto3
import uuid

batch = boto3.client("batch")
s3 = boto3.client("s3")

JOB_QUEUE = os.environ.get("JOB_QUEUE", "wolof-transcription-queue")
JOB_DEFINITION = os.environ.get("JOB_DEFINITION", "wolof-transcribe-gpu")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")

def lambda_handler(event, context):
    record = event["Records"][0]
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]
    parts = key.split("/")
    job_id = parts[1] if len(parts) >= 3 else str(uuid.uuid4())
    result_key = f"results/{job_id}.json"

    s3.put_object(
        Bucket=bucket,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({"status": "submitted", "audio_key": key, "job_id": job_id}),
        ContentType="application/json",
    )

    response = batch.submit_job(
        jobName=f"wolof-{job_id[:8]}",
        jobQueue=JOB_QUEUE,
        jobDefinition=JOB_DEFINITION,
        containerOverrides={
            "environment": [
                {"name": "AUDIO_KEY", "value": key},
                {"name": "RESULT_KEY", "value": result_key},
                {"name": "JOB_ID", "value": job_id},
                {"name": "S3_BUCKET", "value": bucket},
            ]
        },
    )

    s3.put_object(
        Bucket=bucket,
        Key=f"jobs/{job_id}/status.json",
        Body=json.dumps({
            "status": "submitted",
            "batch_job_id": response["jobId"],
            "audio_key": key,
            "job_id": job_id,
            "result_key": result_key,
        }),
        ContentType="application/json",
    )
    return {"statusCode": 200, "body": json.dumps({"job_id": job_id})}
PYEOF

zip -j lambda.zip index.py

aws lambda create-function \
  --function-name wolof-batch-trigger \
  --runtime python3.12 \
  --role "arn:aws:iam::$ACCOUNT:role/wolof-batch-lambda-role" \
  --handler index.lambda_handler \
  --zip-file fileb://lambda.zip \
  --timeout 30 \
  --environment "Variables={JOB_QUEUE=wolof-transcription-queue,JOB_DEFINITION=wolof-transcribe-gpu,S3_BUCKET=$S3_BUCKET}" \
  --region $REGION > /dev/null 2>&1 || \
aws lambda update-function-code \
  --function-name wolof-batch-trigger \
  --zip-file fileb://lambda.zip \
  --region $REGION > /dev/null

LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:wolof-batch-trigger"
echo "  Lambda: wolof-batch-trigger"

# ============================================
echo ""
echo "[11/12] S3 Event Notification..."

aws lambda add-permission \
  --function-name wolof-batch-trigger \
  --statement-id s3-trigger \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$S3_BUCKET" \
  --region $REGION 2>/dev/null || true

aws s3api put-bucket-notification-configuration --bucket $S3_BUCKET --notification-configuration "{
  \"LambdaFunctionConfigurations\": [{
    \"Id\": \"TriggerBatchJob\",
    \"LambdaFunctionArn\": \"$LAMBDA_ARN\",
    \"Events\": [\"s3:ObjectCreated:*\"],
    \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"prefix\", \"Value\": \"uploads/\"}]}}
  }]
}"
echo "  S3 -> Lambda trigger on uploads/ prefix"

# ============================================
echo ""
echo "[12/14] API Lambda (pour le frontend)..."

cd /tmp
rm -rf wolof-api-lambda
mkdir wolof-api-lambda && cd wolof-api-lambda
cat > index.py << 'PYEOF'
import json
import os
import uuid
import boto3

s3 = boto3.client("s3")
S3_BUCKET = os.environ.get("S3_BUCKET", "wolof-transcriber-audio")

def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "*",
    }
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": headers, "body": ""}

    if method == "POST" and "/upload" in path:
        body = json.loads(event.get("body", "{}"))
        filename = body.get("filename", "audio.mp3")
        ext = filename.rsplit(".", 1)[-1] if "." in filename else "mp3"
        job_id = str(uuid.uuid4())
        audio_key = f"uploads/{job_id}/audio.{ext}"
        presigned = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": S3_BUCKET, "Key": audio_key, "ContentType": "audio/*"},
            ExpiresIn=3600,
        )
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"job_id": job_id, "upload_url": presigned, "audio_key": audio_key})}

    if "/status/" in path:
        job_id = path.split("/status/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"jobs/{job_id}/status.json")
            return {"statusCode": 200, "headers": headers, "body": obj["Body"].read().decode()}
        except:
            return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "pending", "job_id": job_id})}

    if "/result/" in path:
        job_id = path.split("/result/")[-1].strip("/")
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=f"results/{job_id}.json")
            return {"statusCode": 200, "headers": headers, "body": obj["Body"].read().decode()}
        except:
            return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Not ready"})}

    if "/health" in path:
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"status": "ok", "mode": "batch-gpu"})}

    return {"statusCode": 404, "headers": headers, "body": json.dumps({"error": "Not found"})}
PYEOF

zip -j api-lambda.zip index.py

# Create or update API Lambda
aws lambda create-function \
  --function-name wolof-batch-api \
  --runtime python3.12 \
  --role "arn:aws:iam::$ACCOUNT:role/wolof-batch-lambda-role" \
  --handler index.lambda_handler \
  --zip-file fileb://api-lambda.zip \
  --timeout 30 \
  --environment "Variables={S3_BUCKET=$S3_BUCKET}" \
  --region $REGION > /dev/null 2>&1 || \
aws lambda update-function-code \
  --function-name wolof-batch-api \
  --zip-file fileb://api-lambda.zip \
  --region $REGION > /dev/null

# Add S3 permissions to Lambda role
aws iam put-role-policy --role-name wolof-batch-lambda-role --policy-name s3-full --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"s3:*\"],
    \"Resource\": [\"arn:aws:s3:::$S3_BUCKET\", \"arn:aws:s3:::$S3_BUCKET/*\"]
  }]
}"

# Create Function URL (public, no auth)
aws lambda create-function-url-config \
  --function-name wolof-batch-api \
  --auth-type NONE \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["*"],"AllowHeaders":["*"]}' \
  --region $REGION > /dev/null 2>&1 || true

aws lambda add-permission \
  --function-name wolof-batch-api \
  --statement-id public-access \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE \
  --region $REGION 2>/dev/null || true

API_URL=$(aws lambda get-function-url-config --function-name wolof-batch-api --region $REGION --query 'FunctionUrl' --output text)
echo "  API URL: $API_URL"
echo "  Endpoints: POST /upload, GET /status/{id}, GET /result/{id}"

# ============================================
echo ""
echo "[13/14] Suppression ancien service Fargate (économie $185/mois)..."
aws ecs delete-service --cluster wolof-asr-cluster --service wolof-asr-service --force --region $REGION > /dev/null 2>&1 || true
echo "  Service ECS supprimé"
# Delete ALB
ALB_ARN=$(aws elbv2 describe-load-balancers --names wolof-asr-alb --region $REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")
if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $REGION 2>/dev/null || true
  echo "  ALB supprimé"
fi
TG_ARN=$(aws elbv2 describe-target-groups --names wolof-asr-tg --region $REGION --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")
if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region $REGION 2>/dev/null || true
  echo "  Target Group supprimé"
fi

# ============================================
echo ""
echo "[14/14] Build GPU Docker Image (CodeBuild)..."

aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/Amethnb2218/wolof-transcribe.git",
    "buildspec": "deploy-batch/buildspec-gpu.yml",
    "gitCloneDepth": 1
  }' \
  --source-version "main" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null

BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build started: $BUILD_ID"
echo "  This takes ~20 min (CUDA + models download)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  GPU image pushed to ECR!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  BUILD FAILED"
    LOG_STREAM=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
    aws logs get-log-events --log-group-name "/aws/codebuild/wolof-fargate-build" --log-stream-name "$LOG_STREAM" --region $REGION --query 'events[-20:].message' --output text
    echo ""
    echo "  Fix the build and re-run: aws codebuild start-build --project-name wolof-fargate-build"
    break
  fi
done

# ============================================
echo ""
echo "============================================"
echo "=== SETUP COMPLETE ==="
echo "============================================"
echo ""
echo "Architecture:"
echo "  Frontend -> API ($API_URL) -> S3 -> Lambda -> Batch GPU"
echo ""
echo "API URL (pour le frontend):"
echo "  $API_URL"
echo ""
echo "Test en ligne de commande:"
echo "  1. Upload audio: aws s3 cp test.mp3 s3://$S3_BUCKET/uploads/test-001/audio.mp3"
echo "  2. Check status: aws s3 cp s3://$S3_BUCKET/jobs/test-001/status.json -"
echo "  3. Get result:   aws s3 cp s3://$S3_BUCKET/results/test-001.json -"
echo ""
echo "Costs:"
echo "  GPU Spot:    ~\$0.045 per 6h audio (15 min processing)"
echo "  GPU OD:      ~\$0.13  per 6h audio (15 min processing)"
echo "  CPU Fargate: ~\$0.20  per 6h audio (2h processing)"
echo "  Idle:        \$0/month (scale to zero)"
echo ""
echo "Ancien service Fargate supprimé (-\$185/mois)"
