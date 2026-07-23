#!/bin/bash
# Diagnose failed build + rebuild with inline Dockerfile (no GitHub cache issues)
set -e

REGION=us-east-1
ACCOUNT=335596040822
CLUSTER=wolof-asr-cluster
SERVICE=wolof-asr-service

echo "=== REBUILD WITH INLINE DOCKERFILE ==="

# The buildspec writes both Dockerfile and app.py inline to avoid GitHub raw cache issues
BUILDSPEC=$(cat << 'BSEOF'
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 335596040822.dkr.ecr.us-east-1.amazonaws.com
      - mkdir -p /tmp/build && cd /tmp/build
  build:
    commands:
      - |
        cd /tmp/build
        cat > Dockerfile << 'DEOF'
        FROM python:3.11-slim
        RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
        WORKDIR /app
        RUN pip install --no-cache-dir flask flask-cors faster-whisper gunicorn transformers torch --extra-index-url https://download.pytorch.org/whl/cpu
        RUN pip install --no-cache-dir sentencepiece protobuf ctranslate2
        RUN mkdir -p /opt/model && \
            curl -sL -o /opt/model/config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/config.json && \
            curl -sL -o /opt/model/vocabulary.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/vocabulary.json && \
            curl -sL -o /opt/model/tokenizer_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/tokenizer_config.json && \
            curl -sL -o /opt/model/vocab.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/vocab.json && \
            curl -sL -o /opt/model/merges.txt https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/merges.txt && \
            curl -sL -o /opt/model/added_tokens.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/added_tokens.json && \
            curl -sL -o /opt/model/special_tokens_map.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/special_tokens_map.json && \
            curl -sL -o /opt/model/normalizer.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/normalizer.json && \
            curl -sL -o /opt/model/preprocessor_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/preprocessor_config.json && \
            curl -sL -o /opt/model/generation_config.json https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/generation_config.json && \
            curl --http1.1 --retry 3 --retry-delay 5 -L -o /opt/model/model.bin https://huggingface.co/momosl/whisper-wolof-v2-ct2/resolve/main/model.bin
        RUN python3 -c "from transformers import AutoTokenizer, AutoModelForSeq2SeqLM; \
            t = AutoTokenizer.from_pretrained('facebook/nllb-200-distilled-600M'); \
            m = AutoModelForSeq2SeqLM.from_pretrained('facebook/nllb-200-distilled-600M'); \
            t.save_pretrained('/opt/nllb-hf'); \
            m.save_pretrained('/opt/nllb-hf')"
        RUN ct2-transformers-converter --model /opt/nllb-hf --output_dir /opt/nllb \
              --quantization int8 --force && \
            cp /opt/nllb-hf/sentencepiece.bpe.model /opt/nllb/ && \
            rm -rf /opt/nllb-hf
        COPY app.py .
        EXPOSE 8080
        CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--timeout", "300", "--workers", "1", "app:app"]
        DEOF
        curl -sL -o app.py "https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-fargate/app.py"
        cat Dockerfile
        docker build --platform linux/amd64 --no-cache -t wolof-asr-fargate .
  post_build:
    commands:
      - docker tag wolof-asr-fargate:latest 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - docker push 335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest
      - echo DONE
BSEOF
)

ENCODED_SPEC=$(echo "$BUILDSPEC" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

aws codebuild update-project \
  --name "wolof-fargate-build" \
  --source "{\"type\":\"NO_SOURCE\",\"buildspec\":$ENCODED_SPEC}" \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_LARGE","privilegedMode":true}' \
  --service-role "arn:aws:iam::335596040822:role/wolof-asr-codebuild-role" \
  --region $REGION > /dev/null && echo "  Project updated"

NEW_BUILD_ID=$(aws codebuild start-build --project-name "wolof-fargate-build" --region $REGION --query 'build.id' --output text)
echo "  Build: $NEW_BUILD_ID"
echo "  Waiting (~15 min)..."

while true; do
  sleep 30
  STATUS=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].buildStatus' --output text)
  PHASE=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].currentPhase' --output text)
  echo "  [$PHASE] $STATUS"
  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "  Image pushed!"
    break
  elif [ "$STATUS" != "IN_PROGRESS" ]; then
    echo "  FAILED - getting logs..."
    LOG_GROUP="/aws/codebuild/wolof-fargate-build"
    NEW_STREAM=$(aws codebuild batch-get-builds --ids "$NEW_BUILD_ID" --region $REGION --query 'builds[0].logs.streamName' --output text)
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$NEW_STREAM" --region $REGION --query 'events[-40:].message' --output text
    exit 1
  fi
done

echo ""
echo "=== DEPLOYING ==="

aws ecs register-task-definition --cli-input-json '{
  "family": "wolof-asr-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "4096",
  "memory": "16384",
  "executionRoleArn": "arn:aws:iam::335596040822:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "wolof-asr",
    "image": "335596040822.dkr.ecr.us-east-1.amazonaws.com/wolof-asr-fargate:latest",
    "portMappings": [{"containerPort": 8080, "protocol": "tcp"}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/wolof-asr",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true
  }]
}' --region $REGION > /dev/null
echo "  Task definition updated (4 vCPU / 16 GB)"

aws ecs update-service \
  --cluster $CLUSTER \
  --service $SERVICE \
  --task-definition wolof-asr-task \
  --force-new-deployment \
  --region $REGION > /dev/null
echo "  Service redeploying..."

echo ""
echo "=== WAITING FOR HEALTHY (~3 min) ==="
sleep 90
for i in $(seq 1 8); do
  HEALTH=$(curl -s https://transcribe.4ura.tech/health 2>/dev/null || echo "waiting...")
  echo "  [$((i*15))s] $HEALTH"
  if echo "$HEALTH" | grep -q "model_loaded"; then
    echo ""
    echo "=== TEST TRADUCTION ==="
    curl -s -X POST https://transcribe.4ura.tech/api/translate \
      -H "Content-Type: application/json" \
      -d '{"text":"Jàmm nga am","src_lang":"wol_Latn","tgt_lang":"fra_Latn"}'
    echo ""
    echo ""
    echo "=== SUCCESS ==="
    exit 0
  fi
  sleep 15
done

echo ""
echo "=== Service pas encore ready - check logs: ==="
STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/wolof-asr" --order-by LastEventTime --descending --limit 1 --region $REGION --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "/ecs/wolof-asr" --log-stream-name "$STREAM" --limit 20 --region $REGION --query 'events[*].message' --output text
