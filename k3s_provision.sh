#!/bin/bash
set -e

# Default Variables
INSTANCE_TYPE="t3.medium"
AWS_PROFILE="default"
USER_DATA_FILE="userdata.sh"

# Required arguments (will be validated)
AMI_ID=""
VPC_ID=""
SUBNET_ID=""
REGION=""
KEY_NAME=""
SECURITY_GROUP_ID=""

#######################
# Usage Function
#######################
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Required options:
  --region <aws-region>       AWS region (e.g., us-west-2)
  --ami <ami-id>              AMI ID for EC2 instance
  --key-pair <key-name>       EC2 key pair name
  --vpc-id <vpc-id>           VPC ID where instance will be launched
  --subnet-id <subnet-id>     Public subnet ID within the VPC

Optional options:
  --profile <aws-profile>     AWS CLI profile (default: default)
  --security-group-id <sg-id> Security Group ID (creates new if not specified)
  --instance-type <type>      EC2 instance type (default: t3.medium)

Example:
  $0 --region us-west-2 --ami ami-12345 --key-pair my-key --vpc-id vpc-12345 --subnet-id subnet-12345
EOF
}

#######################
# Parse CLI Arguments
#######################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --ami) AMI_ID="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --key-pair) KEY_NAME="$2"; shift 2 ;;
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --subnet-id) SUBNET_ID="$2"; shift 2 ;;
    --security-group-id) SECURITY_GROUP_ID="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown parameter: $1"; echo; usage; exit 1 ;;
  esac
done

############################################
# Validation Functions
############################################
validate_param() {
  local name="$1" value="$2" pattern="$3" required="$4"
  
  # Check if required parameter is empty
  if [[ "$required" == "true" && -z "${value// /}" ]]; then
    echo "ERROR: $name is required"; return 1
  fi
  
  # Skip format check if empty (for optional params)
  [[ -z "$value" ]] && return 0
  
  # Validate format if pattern provided
  if [[ -n "$pattern" && ! "$value" =~ $pattern ]]; then
    echo "ERROR: $name has invalid format: $value (expected: $pattern)"; return 1
  fi
  return 0
}

verify_aws_resource() {
  local resource_type="$1" resource_id="$2" vpc_id="$3"
  
  case "$resource_type" in
    "vpc")
      local state=$(aws ec2 describe-vpcs --profile "$AWS_PROFILE" --region "$REGION" \
        --vpc-ids "$resource_id" --query "Vpcs[0].State" --output text 2>/dev/null || echo "NOT_FOUND")
      
      [[ "$state" == "NOT_FOUND" || "$state" == "None" ]] && { echo "ERROR: VPC $resource_id not found"; return 1; }
      [[ "$state" != "available" ]] && { echo "ERROR: VPC $resource_id not available (state: $state)"; return 1; }
      echo "VPC $resource_id verified"
      ;;
      
    "subnet")
      local info=$(aws ec2 describe-subnets --profile "$AWS_PROFILE" --region "$REGION" \
        --subnet-ids "$resource_id" --query "Subnets[0].[VpcId,State]" --output text 2>/dev/null || echo "NOT_FOUND")
      
      [[ "$info" == "NOT_FOUND" ]] && { echo "ERROR: Subnet $resource_id not found"; return 1; }
      
      read -r subnet_vpc_id subnet_state <<< "$info"
      [[ "$subnet_vpc_id" != "$vpc_id" ]] && { echo "ERROR: Subnet $resource_id in wrong VPC ($subnet_vpc_id vs $vpc_id)"; return 1; }
      [[ "$subnet_state" != "available" ]] && { echo "ERROR: Subnet $resource_id not available"; return 1; }
      
      # Check if public subnet
      local igw=$(aws ec2 describe-route-tables --profile "$AWS_PROFILE" --region "$REGION" \
        --filters "Name=association.subnet-id,Values=$resource_id" "Name=route.destination-cidr-block,Values=0.0.0.0/0" \
        --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "None")
      
      [[ "$igw" == "None" || -z "$igw" ]] && { echo "ERROR: Subnet $resource_id is not public"; return 1; }
      echo "Subnet $resource_id verified as public"
      ;;
      
    "security-group")
      local sg_vpc=$(aws ec2 describe-security-groups --profile "$AWS_PROFILE" --region "$REGION" \
        --group-ids "$resource_id" --query "SecurityGroups[0].VpcId" --output text 2>/dev/null || echo "NOT_FOUND")
      
      [[ "$sg_vpc" == "NOT_FOUND" || "$sg_vpc" == "None" ]] && { echo "ERROR: Security group $resource_id not found"; return 1; }
      [[ "$sg_vpc" != "$vpc_id" ]] && { echo "ERROR: Security group $resource_id in wrong VPC ($sg_vpc vs $vpc_id)"; return 1; }
      echo "Security group $resource_id verified"
      ;;
  esac
}

############################################
# Main Validation
############################################
echo "=== Validating Parameters ==="
errors=0

validate_param "--profile" "$AWS_PROFILE" "" "true" || errors=$((errors + 1))
validate_param "--region" "$REGION" "^[a-z0-9-]+$" "true" || errors=$((errors + 1))
validate_param "--ami" "$AMI_ID" "^ami-[a-z0-9]+$" "true" || errors=$((errors + 1))
validate_param "--key-pair" "$KEY_NAME" "" "true" || errors=$((errors + 1))
validate_param "--vpc-id" "$VPC_ID" "^vpc-[a-z0-9]+$" "true" || errors=$((errors + 1))
validate_param "--subnet-id" "$SUBNET_ID" "^subnet-[a-z0-9]+$" "true" || errors=$((errors + 1))
validate_param "--security-group-id" "$SECURITY_GROUP_ID" "^sg-[a-z0-9]+$" "false" || errors=$((errors + 1))
validate_param "--instance-type" "$INSTANCE_TYPE" "" "true" || errors=$((errors + 1))

[[ $errors -gt 0 ]] && { echo; echo "Validation failed with $errors error(s)."; usage; exit 1; }
echo "All parameters are non-empty and follow correct format"

echo "=== Verifying AWS Resources ==="
verify_aws_resource "vpc" "$VPC_ID" || exit 1
verify_aws_resource "subnet" "$SUBNET_ID" "$VPC_ID" || exit 1

# Handle security group
if [[ -n "$SECURITY_GROUP_ID" ]]; then
  verify_aws_resource "security-group" "$SECURITY_GROUP_ID" "$VPC_ID" || exit 1
else
  echo "Creating new security group..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group --profile "$AWS_PROFILE" --region "$REGION" \
    --group-name "k3s-provision-sg-$(date +%Y%m%d-%H%M%S)" \
    --description "Security group for k3s EC2 instance" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  echo "Created security group: $SECURITY_GROUP_ID"
  
  # Add ingress rules
  for port in 22 80 6443 "30000-32767"; do
    aws ec2 authorize-security-group-ingress --profile "$AWS_PROFILE" --region "$REGION" \
      --group-id "$SECURITY_GROUP_ID" --protocol tcp --port "$port" --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  done
  echo "Security group rules configured for port 22, 80, 6443, and 30000-32767"
fi

############################################
# Handle Key Pair
############################################
KEY_NAME="${KEY_NAME%.pem}"  # Remove .pem if present

if ! aws ec2 describe-key-pairs --profile "$AWS_PROFILE" --region "$REGION" \
  --key-names "$KEY_NAME" --query "KeyPairs[0].KeyName" --output text &>/dev/null; then
  
  echo "Creating new key pair: $KEY_NAME"
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair --profile "$AWS_PROFILE" --region "$REGION" \
    --key-name "$KEY_NAME" --query "KeyMaterial" --output text > "$HOME/.ssh/$KEY_NAME.pem"
  chmod 400 "$HOME/.ssh/$KEY_NAME.pem"
  echo "Key pair created and saved to: $HOME/.ssh/$KEY_NAME.pem"
else
  echo "Key pair $KEY_NAME exists"
fi

############################################
# Launch EC2 Instance
############################################
echo "Launching EC2 instance..."

INSTANCE_ID=$(aws ec2 run-instances --profile "$AWS_PROFILE" --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP_ID" --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address --user-data "file://$USER_DATA_FILE" \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance created: $INSTANCE_ID"

# Wait for public DNS
echo "Waiting for public DNS..."
for i in {1..40}; do
  PUBLIC_DNS=$(aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$REGION" \
    --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicDnsName" --output text 2>/dev/null || echo "None")
  [[ -n "$PUBLIC_DNS" && "$PUBLIC_DNS" != "None" ]] && break
  sleep 5
done

[[ -z "$PUBLIC_DNS" || "$PUBLIC_DNS" == "None" ]] && { echo "ERROR: Could not get public DNS"; exit 1; }

############################################
# Output
############################################
cat << EOF
===============================================================================
 The script successfully launched an EC2 instance.
 The script installed K3s in EC2 Instance
 Helm charts for Prometheus and Nginx deployed in K3s cluster
===============================================================================

 Instance ID: $INSTANCE_ID
 Public DNS: $PUBLIC_DNS

 SSH Command:
   ssh -i $KEY_NAME.pem ubuntu@$PUBLIC_DNS

 Please refer README.md for further instructions.

===============================================================================
EOF
