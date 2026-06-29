#!/bin/bash
set -e

# ============================================================
# VARIABLES - ajustar si cambian
# ============================================================
REGION="us-east-1"
ACCOUNT_ID="961812473040"
PROJECT="tienda-perritos"
LAB_ROLE="arn:aws:iam::961812473040:role/LabRole"

# VPC y Subnets
VPC_ID="vpc-002fde8c979931193"
SUBNET_PUB_A="subnet-0f021fc1a4e884d6a"
SUBNET_PUB_B="subnet-0e1611f2ebe742a4c"
SUBNET_APP_A="subnet-039d75e569388a136"
SUBNET_APP_B="subnet-03f3ca12d8ea8baae"

# ECR
ECR_BACKEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-backend:latest"
ECR_FRONTEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-frontend:latest"
ECR_DB="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/tienda-db:latest"

echo "============================================="
echo " Desplegando tienda-perritos en ECS Fargate"
echo "============================================="

# ============================================================
# 1. SECURITY GROUPS
# ============================================================
echo ""
echo "1. Creando Security Groups..."

# SG para ALB
SG_ALB=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-alb-sg" \
  --description "SG para ALB tienda-perritos" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ALB \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

echo "SG ALB: $SG_ALB"

# SG para ECS tasks
SG_ECS=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-ecs-sg" \
  --description "SG para ECS tasks tienda-perritos" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text)

# Frontend: recibe del ALB en puerto 80
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ECS \
  --protocol tcp --port 80 \
  --source-group $SG_ALB

# Backend: recibe del ALB en puerto 3001
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ECS \
  --protocol tcp --port 3001 \
  --source-group $SG_ALB

# DB: recibe del ECS en puerto 3306
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ECS \
  --protocol tcp --port 3306 \
  --source-group $SG_ECS

echo "SG ECS: $SG_ECS"

# ============================================================
# 2. CLOUDWATCH LOG GROUPS
# ============================================================
echo ""
echo "2. Creando Log Groups en CloudWatch..."

aws logs create-log-group --log-group-name "/ecs/${PROJECT}/frontend" --region $REGION || true
aws logs create-log-group --log-group-name "/ecs/${PROJECT}/backend" --region $REGION || true
aws logs create-log-group --log-group-name "/ecs/${PROJECT}/db" --region $REGION || true

echo "Log groups creados."

# ============================================================
# 3. ECS CLUSTER
# ============================================================
echo ""
echo "3. Creando ECS Cluster..."

aws ecs create-cluster \
  --cluster-name ${PROJECT}-cluster \
  --capacity-providers FARGATE \
  --region $REGION

echo "Cluster: ${PROJECT}-cluster"

# ============================================================
# 4. TASK DEFINITIONS
# ============================================================
echo ""
echo "4. Registrando Task Definitions..."

# --- DB ---
aws ecs register-task-definition \
  --family "${PROJECT}-db" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "512" --memory "1024" \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-db\",
      \"image\": \"${ECR_DB}\",
      \"portMappings\": [{\"containerPort\": 3306, \"protocol\": \"tcp\"}],
      \"environment\": [
        {\"name\": \"MYSQL_ROOT_PASSWORD\", \"value\": \"admin123\"},
        {\"name\": \"MYSQL_DATABASE\",      \"value\": \"tienda_perritos\"},
        {\"name\": \"MYSQL_USER\",          \"value\": \"alumno\"},
        {\"name\": \"MYSQL_PASSWORD\",      \"value\": \"alumno123\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT}/db\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null

echo "Task Definition DB registrada."

# --- BACKEND ---
aws ecs register-task-definition \
  --family "${PROJECT}-backend" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-backend\",
      \"image\": \"${ECR_BACKEND}\",
      \"portMappings\": [{\"containerPort\": 3001, \"protocol\": \"tcp\"}],
      \"environment\": [
        {\"name\": \"PORT\",        \"value\": \"3001\"},
        {\"name\": \"DB_HOST\",     \"value\": \"DB_HOST_PLACEHOLDER\"},
        {\"name\": \"DB_USER\",     \"value\": \"root\"},
        {\"name\": \"DB_PASSWORD\", \"value\": \"admin123\"},
        {\"name\": \"DB_NAME\",     \"value\": \"tienda_perritos\"},
        {\"name\": \"DB_PORT\",     \"value\": \"3306\"}
      ],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT}/backend\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null

echo "Task Definition Backend registrada."

# --- FRONTEND ---
aws ecs register-task-definition \
  --family "${PROJECT}-frontend" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "256" --memory "512" \
  --execution-role-arn $LAB_ROLE \
  --task-role-arn $LAB_ROLE \
  --container-definitions "[
    {
      \"name\": \"tienda-frontend\",
      \"image\": \"${ECR_FRONTEND}\",
      \"portMappings\": [{\"containerPort\": 80, \"protocol\": \"tcp\"}],
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"/ecs/${PROJECT}/frontend\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      }
    }
  ]" --region $REGION > /dev/null

echo "Task Definition Frontend registrada."

# ============================================================
# 5. ALB + TARGET GROUPS
# ============================================================
echo ""
echo "5. Creando ALB y Target Groups..."

# ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT}-alb" \
  --subnets $SUBNET_PUB_A $SUBNET_PUB_B \
  --security-groups $SG_ALB \
  --scheme internet-facing \
  --type application \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query "LoadBalancers[0].DNSName" --output text)

echo "ALB ARN: $ALB_ARN"
echo "ALB DNS: $ALB_DNS"

# Target Group Frontend
TG_FRONTEND=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-frontend" \
  --protocol HTTP --port 80 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path "/" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

echo "TG Frontend: $TG_FRONTEND"

# Target Group Backend
TG_BACKEND=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-backend" \
  --protocol HTTP --port 3001 \
  --vpc-id $VPC_ID \
  --target-type ip \
  --health-check-path "/api/health" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

echo "TG Backend: $TG_BACKEND"

# Listener con path-based routing
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_FRONTEND \
  --query "Listeners[0].ListenerArn" --output text)

# Regla para /api/*
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 10 \
  --conditions Field=path-pattern,Values="/api/*" \
  --actions Type=forward,TargetGroupArn=$TG_BACKEND > /dev/null

echo "Listener y reglas creadas."

# ============================================================
# 6. SERVICIOS ECS
# ============================================================
echo ""
echo "6. Creando servicios ECS..."

# Servicio DB
aws ecs create-service \
  --cluster "${PROJECT}-cluster" \
  --service-name "tienda-db" \
  --task-definition "${PROJECT}-db" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_APP_A,$SUBNET_APP_B],securityGroups=[$SG_ECS],assignPublicIp=DISABLED}" \
  --region $REGION > /dev/null

echo "Servicio DB creado."

# Servicio Backend
aws ecs create-service \
  --cluster "${PROJECT}-cluster" \
  --service-name "tienda-backend" \
  --task-definition "${PROJECT}-backend" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_APP_A,$SUBNET_APP_B],securityGroups=[$SG_ECS],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_BACKEND,containerName=tienda-backend,containerPort=3001" \
  --region $REGION > /dev/null

echo "Servicio Backend creado."

# Servicio Frontend
aws ecs create-service \
  --cluster "${PROJECT}-cluster" \
  --service-name "tienda-frontend" \
  --task-definition "${PROJECT}-frontend" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_APP_A,$SUBNET_APP_B],securityGroups=[$SG_ECS],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_FRONTEND,containerName=tienda-frontend,containerPort=80" \
  --region $REGION > /dev/null

echo "Servicio Frontend creado."

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo "============================================="
echo " DESPLIEGUE COMPLETADO"
echo "============================================="
echo " URL pública: http://${ALB_DNS}"
echo " SG ALB:      $SG_ALB"
echo " SG ECS:      $SG_ECS"
echo "============================================="
echo ""
echo "NOTA: La DB usa IP dinámica en ECS."
echo "Después de que el servicio DB esté RUNNING,"
echo "actualiza DB_HOST en el backend con su IP privada."
echo "============================================="
