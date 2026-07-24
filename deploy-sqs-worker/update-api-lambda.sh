#!/bin/bash
# Redeploy API Lambda with latest code
set -e
REGION=us-east-1
FUNC=wolof-asr-api-v2

cd /tmp
rm -f api_lambda.py api_lambda.zip 2>/dev/null
curl -sL -o api_lambda.py https://raw.githubusercontent.com/Amethnb2218/wolof-transcribe/main/deploy-sqs-worker/api_lambda.py
zip -j api_lambda.zip api_lambda.py
aws lambda update-function-code --function-name $FUNC --zip-file fileb://api_lambda.zip --region $REGION > /dev/null
echo "API Lambda updated."
echo "Test: curl -s https://6vc5h24e6d7pxjqyznfg4xwgzq0hjwww.lambda-url.us-east-1.on.aws/health"
curl -s "https://6vc5h24e6d7pxjqyznfg4xwgzq0hjwww.lambda-url.us-east-1.on.aws/health"
echo ""
