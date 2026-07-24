#!/bin/bash
# Get mini-server public IP
REGION=us-east-1
CLUSTER=wolof-asr-cluster
SERVICE=wolof-mini-service

TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --region $REGION --query 'taskArns[0]' --output text)
echo "Task: $TASK_ARN"

STATUS=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].lastStatus' --output text)
echo "Status: $STATUS"

if [ "$STATUS" == "RUNNING" ]; then
  ENI=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$TASK_ARN" --region $REGION --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
  PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region $REGION --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
  echo ""
  echo "PUBLIC IP: $PUBLIC_IP"
  echo "URL: http://$PUBLIC_IP:8080"
  echo "Health: http://$PUBLIC_IP:8080/health"
  echo ""
  echo "Test: curl http://$PUBLIC_IP:8080/health"
else
  echo "Task not running yet. Wait and retry."
fi
