#!/bin/bash
# Fix Lambda URL "Forbidden" error
aws lambda remove-permission --function-name wolof-asr-api-v2 --statement-id public-url --region us-east-1 2>/dev/null
aws lambda remove-permission --function-name wolof-asr-api-v2 --statement-id public-url-access --region us-east-1 2>/dev/null
aws lambda add-permission --function-name wolof-asr-api-v2 --statement-id FunctionURLAllowPublicAccess --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE --region us-east-1
aws lambda update-function-url-config --function-name wolof-asr-api-v2 --auth-type NONE --region us-east-1
echo ""
echo "Testing..."
curl -s -X POST "https://aqbv646vz37vym427r4hmeoltu0kyupc.lambda-url.us-east-1.on.aws/upload" -H "Content-Type: application/json" -d '{"filename":"test.mp3"}'
