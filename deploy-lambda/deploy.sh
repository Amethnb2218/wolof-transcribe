#!/bin/bash
# =====================================================
# DÉPLOIEMENT — Wolof ASR sur AWS Lambda
# Pas de quota GPU nécessaire !
# =====================================================
set -e

AWS_REGION="eu-west-3"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FUNCTION_NAME="wolof-asr"
ECR_REPO="wolof-asr"

echo "=== Déploiement Wolof ASR sur Lambda ==="
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT_ID"
echo ""

# 1. Créer repo ECR
echo "[1/5] Création repo ECR..."
aws ecr create-repository \
    --repository-name $ECR_REPO \
    --region $AWS_REGION 2>/dev/null || echo "  (existe déjà)"

# 2. Build Docker
echo "[2/5] Build Docker (ça télécharge le modèle ~3Go)..."
docker build -t $ECR_REPO:latest .

# 3. Push vers ECR
echo "[3/5] Push vers ECR..."
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

docker tag $ECR_REPO:latest \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

docker push \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest

# 4. Créer rôle IAM
echo "[4/5] Rôle IAM..."
aws iam create-role \
    --role-name lambda-wolof-asr \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "lambda.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }' 2>/dev/null || echo "  (existe déjà)"

aws iam attach-role-policy \
    --role-name lambda-wolof-asr \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
    2>/dev/null || true

echo "  Attente propagation IAM (10s)..."
sleep 10

# 5. Créer/update Lambda
echo "[5/5] Création Lambda (4 Go RAM, 120s timeout)..."
aws lambda create-function \
    --function-name $FUNCTION_NAME \
    --package-type Image \
    --code ImageUri=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest \
    --role arn:aws:iam::$AWS_ACCOUNT_ID:role/lambda-wolof-asr \
    --memory-size 4096 \
    --timeout 120 \
    --region $AWS_REGION \
    --architectures x86_64 \
    2>/dev/null || \
aws lambda update-function-code \
    --function-name $FUNCTION_NAME \
    --image-uri $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:latest \
    --region $AWS_REGION

# Créer Function URL (publique)
echo ""
echo "Création URL publique..."
aws lambda create-function-url-config \
    --function-name $FUNCTION_NAME \
    --auth-type NONE \
    --cors '{"AllowOrigins":["*"],"AllowMethods":["POST","GET"],"AllowHeaders":["*"]}' \
    --region $AWS_REGION 2>/dev/null || true

aws lambda add-permission \
    --function-name $FUNCTION_NAME \
    --statement-id FunctionURLPublic \
    --action lambda:InvokeFunctionURL \
    --principal "*" \
    --function-url-auth-type NONE \
    --region $AWS_REGION 2>/dev/null || true

# Récupérer l'URL
FUNCTION_URL=$(aws lambda get-function-url-config \
    --function-name $FUNCTION_NAME \
    --region $AWS_REGION \
    --query 'FunctionUrl' --output text)

echo ""
echo "=============================================="
echo "   DÉPLOIEMENT TERMINÉ !"
echo ""
echo "   URL: $FUNCTION_URL"
echo ""
echo "   Dans backend/.env, mets :"
echo "   WOLOF_API_URL=${FUNCTION_URL}transcribe"
echo "=============================================="
