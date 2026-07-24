#!/bin/bash
BUCKET="wolof-asr-audio-335596040822"
REGION=us-east-1
ROLE="wolof-asr-api-v2-role"

echo "=== DIAGNOSE S3 PRESIGNED URL 403 ==="
echo ""
echo "[1] Bucket encryption:"
aws s3api get-bucket-encryption --bucket $BUCKET --region $REGION 2>&1
echo ""
echo "[2] Bucket policy:"
aws s3api get-bucket-policy --bucket $BUCKET --region $REGION --output text 2>&1 | python3 -m json.tool 2>/dev/null || echo "  No bucket policy"
echo ""
echo "[3] Lambda role policy:"
aws iam get-role-policy --role-name $ROLE --policy-name api-policy --region $REGION 2>&1
echo ""
echo "[4] Test presigned URL generation + upload:"
URL=$(aws lambda invoke --function-name wolof-asr-api-v2 --region $REGION --payload '{"requestContext":{"http":{"method":"POST","path":"/upload"}},"body":"{\"filename\":\"test.wav\"}"}' /tmp/lambda-out.json 2>&1 && cat /tmp/lambda-out.json | python3 -c "import sys,json; r=json.load(sys.stdin); b=json.loads(r['body']); print(b.get('upload_url','NO URL'))")
echo "  Presigned URL: ${URL:0:100}..."
echo ""
echo "[5] Test PUT with curl:"
echo "test" > /tmp/test-audio.wav
RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -T /tmp/test-audio.wav "$URL")
echo "  PUT result: HTTP $RESULT"
echo ""
if [ "$RESULT" = "200" ]; then
  echo "SUCCESS: S3 upload works from server side."
  echo "Problem is browser-specific (CORS on S3 bucket)."
  echo ""
  echo "[6] Checking S3 CORS:"
  aws s3api get-bucket-cors --bucket $BUCKET --region $REGION
else
  echo "FAILED from server too. Problem is IAM/encryption."
fi
