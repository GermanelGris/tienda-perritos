#!/bin/bash
set -e

PROJECT_NAME="tienda-perritos"
REGION="us-east-1"
ACCOUNT_ID="961812473040"
LAB_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

ECR_BACKEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-backend:latest"
ECR_FRONTEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-frontend:latest"
ECR_DB="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-db:latest"

echo "====================================="
echo "Creando infraestructura ECS Fargate"
echo "====================================="

#####################################
# 0. OBTENER RED
#####################################
echo "0. Obteniendo red existente..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=red-lab-vpc" \
  --query "Vpcs[0].VpcId" --output text)

SUBNET_PUB_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=red-lab-public-a" \
  --query "Subnets[0].SubnetId" --output text)
SUBNET_PUB_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=red-lab-public-b" \
  --query "Subnets[0].SubnetId" --output text)
SUBNET_APP_A=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=red-lab-app-a" \
  --query "Subnets[0].SubnetId" --output text)
SUBNET_APP_B=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=red-lab-app-b" \
  --query "Subnets[0].SubnetId" --output text)

echo "VPC: $VPC_ID"

#####################################
# 1. SECURITY GROUPS
#####################################
echo "1. Security Groups..."

SG_ALB=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text)

if [ "$SG_ALB" == "None" ] || [ -z "$SG_ALB" ]; then
  SG_ALB=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-alb-sg" \
    --description "SG ALB tienda-perritos" \
    --vpc-id $VPC_ID --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ALB --protocol tcp --port 80 --cidr 0.0.0.0/0 || true
fi
echo "SG ALB: $SG_ALB"

SG_ECS=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT_NAME}-ecs-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text)

if [ "$SG_ECS" == "None" ] || [ -z "$SG_ECS" ]; then
  SG_ECS=$(aws ec2 create-security-group \
    --group-name "${PROJECT_NAME}-ecs-sg" \
    --description "SG ECS tasks tienda-perritos" \
    --vpc-id $VPC_ID --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ECS --protocol tcp --port 80 --source-group $SG_ALB || true
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ECS --protocol tcp --port 3001 --source-group $SG_ALB || true
  # DB: permite trafico desde el mismo SG (backend -> db)
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ECS --protocol tcp --port 3306 --source-group $SG_ECS || true
fi
echo "SG ECS: $SG_ECS"

#####################################
# 2. CLOUDWATCH LOG GROUPS
#####################################
echo "2. CloudWatch Log Groups..."
aws logs create-log-group --log-group-name "/ecs/${PROJECT_NAME}/frontend" --region $REGION 2>/dev/null || true
aws logs create-log-group --log-group-name "/ecs/${PROJECT_NAME}/backend" --region $REGION 2>/dev/null || true
aws logs create-log-group --log-group-name "/ecs/${PROJECT_NAME}/db" --region $REGION 2>/dev/null || true

#####################################
# 3. ECS CLUSTER (con Service Connect namespace)
#####################################
echo "3. ECS Cluster..."
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters ${PROJECT_NAME}-cluster \
  --query "clusters[0].status" --output text 2>/dev/null || echo "None")

if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
  aws ecs create-cluster \
    --cluster-name ${PROJECT_NAME}-cluster \
    --capacity-providers FARGATE \
    --service-connect-defaults namespace=${PROJECT_NAME} \
    --region $REGION > /dev/null
fi
echo "Cluster: ${PROJECT_NAME}-cluster"

#####################################
# 4. TASK DEFINITIONS
#####################################
echo "4. Task Definitions..."

# DB
aws ecs register-task-definition \
  --family "tienda-db-td" \
  --network-mode awsvpc --requires-compatibilities FARGATE \
  --cpu "512" --memory "1024" \
  --execution-role-arn $LAB_ROLE --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-db\",
      \"image\": \"${ECR_DB}\",
      \"portMappings\": [{\"name\":\"db\",\"containerPort\": 3306,\"protocol\":\"tcp\"}],
      \"environment\": [
        {\"name\": \"MYSQL_ROOT_PASSWORD\", \"value\": \"admin123\"},
        {\"name\": \"MYSQL_DATABASE\", \"value\": \"tienda_perritos\"},
        {\"name\": \"MYSQL_USER\", \"value\": \"alumno\"},
        {\"name\": \"MYSQL_PASSWORD\", \"value\": \"alumno123\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT_NAME}/db\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null
echo "TD DB registrada."

# BACKEND
aws ecs register-task-definition \
  --family "tienda-backend-td" \
  --network-mode awsvpc --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn $LAB_ROLE --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-backend\",
      \"image\": \"${ECR_BACKEND}\",
      \"portMappings\": [{\"name\":\"backend\",\"containerPort\": 3001,\"protocol\":\"tcp\"}],
      \"environment\": [
        {\"name\": \"PORT\", \"value\": \"3001\"},
        {\"name\": \"DB_HOST\", \"value\": \"tienda-db\"},
        {\"name\": \"DB_USER\", \"value\": \"root\"},
        {\"name\": \"DB_PASSWORD\", \"value\": \"admin123\"},
        {\"name\": \"DB_NAME\", \"value\": \"tienda_perritos\"},
        {\"name\": \"DB_PORT\", \"value\": \"3306\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT_NAME}/backend\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null
echo "TD Backend registrada."

# FRONTEND
aws ecs register-task-definition \
  --family "tienda-frontend-td" \
  --network-mode awsvpc --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn $LAB_ROLE --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-frontend\",
      \"image\": \"${ECR_FRONTEND}\",
      \"portMappings\": [{\"name\":\"frontend\",\"containerPort\": 80,\"protocol\":\"tcp\"}],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT_NAME}/frontend\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null
echo "TD Frontend registrada."

#####################################
# 5. ALB + TARGET GROUPS
#####################################
echo "5. ALB + Target Groups..."

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT_NAME}-alb" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || echo "")
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" == "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "${PROJECT_NAME}-alb" \
    --subnets $SUBNET_PUB_A $SUBNET_PUB_B \
    --security-groups $SG_ALB \
    --scheme internet-facing --type application \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
fi
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query "LoadBalancers[0].DNSName" --output text)
echo "ALB DNS: $ALB_DNS"

TG_FRONTEND=$(aws elbv2 describe-target-groups \
  --names "${PROJECT_NAME}-tg-frontend" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")
if [ -z "$TG_FRONTEND" ] || [ "$TG_FRONTEND" == "None" ]; then
  TG_FRONTEND=$(aws elbv2 create-target-group \
    --name "${PROJECT_NAME}-tg-frontend" \
    --protocol HTTP --port 80 --vpc-id $VPC_ID \
    --target-type ip --health-check-path "/" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
fi

TG_BACKEND=$(aws elbv2 describe-target-groups \
  --names "${PROJECT_NAME}-tg-backend" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")
if [ -z "$TG_BACKEND" ] || [ "$TG_BACKEND" == "None" ]; then
  TG_BACKEND=$(aws elbv2 create-target-group \
    --name "${PROJECT_NAME}-tg-backend" \
    --protocol HTTP --port 3001 --vpc-id $VPC_ID \
    --target-type ip --health-check-path "/api/health" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
fi

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query "Listeners[0].ListenerArn" --output text 2>/dev/null || echo "")
if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" == "None" ]; then
  LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_FRONTEND \
    --query "Listeners[0].ListenerArn" --output text)
  aws elbv2 create-rule \
    --listener-arn $LISTENER_ARN --priority 10 \
    --conditions Field=path-pattern,Values="/api/*" \
    --actions Type=forward,TargetGroupArn=$TG_BACKEND > /dev/null
fi
echo "Listener configurado."

#####################################
# 6. SERVICIOS ECS (con Service Connect)
#####################################
echo "6. Servicios ECS..."
NET_CONFIG="awsvpcConfiguration={subnets=[$SUBNET_APP_A,$SUBNET_APP_B],securityGroups=[$SG_ECS],assignPublicIp=DISABLED}"

# DB (con Service Connect - expone "tienda-db" como DNS interno)
DB_EXISTS=$(aws ecs describe-services --cluster ${PROJECT_NAME}-cluster --services tienda-db --query "services[0].status" --output text 2>/dev/null || echo "None")
if [ "$DB_EXISTS" != "ACTIVE" ]; then
  aws ecs create-service \
    --cluster ${PROJECT_NAME}-cluster \
    --service-name tienda-db \
    --task-definition tienda-db-td \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NET_CONFIG" \
    --service-connect-configuration "enabled=true,services=[{portName=db,clientAliases=[{port=3306,dnsName=tienda-db}]}]" \
    --region $REGION > /dev/null
fi
echo "Servicio DB ok."

# Backend (con Service Connect como cliente)
BE_EXISTS=$(aws ecs describe-services --cluster ${PROJECT_NAME}-cluster --services tienda-backend --query "services[0].status" --output text 2>/dev/null || echo "None")
if [ "$BE_EXISTS" != "ACTIVE" ]; then
  aws ecs create-service \
    --cluster ${PROJECT_NAME}-cluster \
    --service-name tienda-backend \
    --task-definition tienda-backend-td \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NET_CONFIG" \
    --load-balancers "targetGroupArn=$TG_BACKEND,containerName=tienda-backend,containerPort=3001" \
    --service-connect-configuration "enabled=true" \
    --region $REGION > /dev/null
fi
echo "Servicio Backend ok."

# Frontend
FE_EXISTS=$(aws ecs describe-services --cluster ${PROJECT_NAME}-cluster --services tienda-frontend --query "services[0].status" --output text 2>/dev/null || echo "None")
if [ "$FE_EXISTS" != "ACTIVE" ]; then
  aws ecs create-service \
    --cluster ${PROJECT_NAME}-cluster \
    --service-name tienda-frontend \
    --task-definition tienda-frontend-td \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NET_CONFIG" \
    --load-balancers "targetGroupArn=$TG_FRONTEND,containerName=tienda-frontend,containerPort=80" \
    --service-connect-configuration "enabled=true" \
    --region $REGION > /dev/null
fi
echo "Servicio Frontend ok."

echo "====================================="
echo "INFRA ECS CREADA"
echo "====================================="
echo "URL publica: http://${ALB_DNS}"
echo "Cluster: ${PROJECT_NAME}-cluster"
echo "====================================="
