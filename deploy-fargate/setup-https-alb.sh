#!/bin/bash
# Setup HTTPS on ALB with ACM certificate for transcribe.4ura.tech
set -e

REGION=us-east-1
ALB_ARN="arn:aws:elasticloadbalancing:us-east-1:335596040822:loadbalancer/app/wolof-asr-alb/ae0b94c1584daa2e"
TG_NAME=wolof-asr-tg
DOMAIN="transcribe.4ura.tech"

echo "=== HTTPS Setup for $DOMAIN ==="

# Step 1: Request ACM certificate
echo ""
echo "[1/3] Requesting ACM certificate for $DOMAIN..."
CERT_ARN=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" --output text --region $REGION)

if [ "$CERT_ARN" = "None" ] || [ -z "$CERT_ARN" ]; then
  CERT_ARN=$(aws acm request-certificate \
    --domain-name $DOMAIN \
    --validation-method DNS \
    --query 'CertificateArn' --output text --region $REGION)
  echo "  Certificate requested: $CERT_ARN"
  echo ""
  echo "  WAITING for DNS validation record..."
  sleep 10
else
  echo "  Certificate exists: $CERT_ARN"
fi

# Get DNS validation record
echo ""
echo "[2/3] DNS Validation required!"
echo ""

for i in $(seq 1 6); do
  VALIDATION=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json --region $REGION 2>/dev/null)
  if [ "$VALIDATION" != "null" ] && [ -n "$VALIDATION" ]; then
    break
  fi
  sleep 5
done

CNAME_NAME=$(echo $VALIDATION | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['Name'])")
CNAME_VALUE=$(echo $VALIDATION | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['Value'])")

echo "  ============================================"
echo "  ADD THIS DNS RECORD on your domain provider:"
echo "  ============================================"
echo ""
echo "  Type:  CNAME"
echo "  Name:  $CNAME_NAME"
echo "  Value: $CNAME_VALUE"
echo ""
echo "  ============================================"
echo ""
echo "  After adding the DNS record, wait 1-5 min for validation."
echo "  Then run this script again to complete step 3."
echo ""

# Check if already validated
STATUS=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query 'Certificate.Status' --output text --region $REGION)
echo "  Current status: $STATUS"

if [ "$STATUS" != "ISSUED" ]; then
  echo ""
  echo "  Certificate not yet validated. Add the CNAME above,"
  echo "  wait a few minutes, then run this script again."
  exit 0
fi

# Step 3: Add HTTPS listener to ALB
echo ""
echo "[3/3] Adding HTTPS listener to ALB..."

TG_ARN=$(aws elbv2 describe-target-groups --names $TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION)

# Check if HTTPS listener exists
HTTPS_LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text --region $REGION 2>/dev/null)

if [ "$HTTPS_LISTENER" = "None" ] || [ -z "$HTTPS_LISTENER" ]; then
  aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS --port 443 \
    --certificates CertificateArn=$CERT_ARN \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --region $REGION > /dev/null
  echo "  HTTPS listener created!"
else
  echo "  HTTPS listener exists"
fi

# Open port 443 on ALB security group
ALB_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wolof-asr-alb-sg" --query 'SecurityGroups[0].GroupId' --output text --region $REGION)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || echo "  Port 443 already open"

echo ""
echo "=========================================="
echo "  HTTPS READY!"
echo "=========================================="
echo ""
echo "  Now update DNS:"
echo "  transcribe.4ura.tech -> CNAME -> wolof-asr-alb-2025108882.us-east-1.elb.amazonaws.com"
echo ""
echo "  Then set on Render:"
echo "  VITE_API_URL=https://transcribe.4ura.tech/"
echo ""
echo "  Test: curl https://transcribe.4ura.tech/health"
echo "=========================================="
