#!/bin/bash
echo "=== DIAGNOSE LAMBDA URL FORBIDDEN ==="
echo ""
echo "[1] Function state:"
aws lambda get-function --function-name wolof-asr-api-v2 --region us-east-1 --query 'Configuration.{State:State,LastUpdateStatus:LastUpdateStatus,Runtime:Runtime,Handler:Handler}'
echo ""
echo "[2] Direct invoke test:"
aws lambda invoke --function-name wolof-asr-api-v2 --region us-east-1 --payload '{}' /tmp/out.json 2>&1
echo ""
echo "Response:"
cat /tmp/out.json
echo ""
echo ""
echo "[3] Full policy:"
aws lambda get-policy --function-name wolof-asr-api-v2 --region us-east-1 2>&1
echo ""
echo "[4] Curl verbose:"
curl -s -w "\nHTTP_CODE: %{http_code}\n" https://aqbv646vz37vym427r4hmeoltu0kyupc.lambda-url.us-east-1.on.aws/health
