# Prerequisites
- AWS CLI configured with target profile and appropriate IAM role/user to create EC2 resources.
- A public subnet in VPC that auto-assigns public IPv4 address to EC2 instance (the script verifies the subnet is public).

# Executing the script to deploy EC2 instance and related AWS resources.

I performed below steps to execute the solution scrpt.

Step 1. Make the script executable:
```bash
chmod +x main_solution.sh
```

Step 2. Execute the script:
```bash
sh main_solution.sh \
--profile my-aws-profile \
--region us-west-2 \
--ami ami-123456 \
--key-pair my-key-name \
--vpc-id vpc-123456 \
--subnet-id subnet-123456 \
--security-group-id sg-123456
--instance-type t3.medium
```
  Required arguments:
  - **--region**: AWS region (e.g., us-west-2)
  - **--ami**: AMI id used for EC2 (must be SSHable as `ubuntu` user)
  - **--key-pair**: Key pair name (script will create and save `~/.ssh/<key-name>.pem` if it does not exist already in AWS)
  - **--vpc-id**: Target VPC id
  - **--subnet-id**: Public subnet-id inside the VPC

  Optional arguments:
  - **--profile**: AWS CLI profile (default: `default`)
  - **--security-group-id**: Use an existing SG (must be in the same VPC); if omitted a new SG is created
  - **--instance-type**: EC2 type (default: `t3.medium`)

# Validations Performed by Provisioning Script

> [!NOTE]
> Please refer screenshots in `screenshots/` directory

The script performs several validations to ensure safe and correct provisioning of the K3s environment on AWS.

1. **Required Argument Validation** <br>
Ensures all mandatory inputs are provided:
```bash
--region, --ami, --key-pair, --vpc-id, --subnet-id, --profile, --instance-type
```

2. **Input Format Validation**<br>
Validates parameter formats using regex:
```bash
AMI (ami-xxxx), VPC (vpc-xxxx), Subnet (subnet-xxxx), Security Group (sg-xxxx), Region (^[a-z0-9-]+$)
```

3. **AWS Resource Validation**<br>
Checks correctness and availability of AWS resources:
  - **VPC**: exists and is in available state
  - **Subnet**: exists, belongs to the VPC, is available, and is a public subnet
  - **Security Group**:
      - If provided → verified
      - If not provided → script creates one + configures ports (22, 80, 6443, 30000–32767)

4. **Key Pair Validation**
  - Normalizes key name
  - Verifies key pair exists
  - If missing → creates a new key pair and saves .pem securely

5. **Pre-Launch Checks**<br>
Ensures all validated resources are ready before launching EC2.

6. **Public DNS Validation**<br>
After launching the instance, script waits until the EC2 Public DNS becomes available (up to 40 retries).

# Troubleshooting Error (if any)
- If the script fails on AWS calls, verify `aws configure --profile <profile>` and that the profile has valid credentials.
- Check EC2 instance system logs from the EC2 Console.
- SSH into the instance and inspect:
  - K3s logs: `sudo journalctl -u k3s -b`
  - user-data output: `/var/log/cloud-init-output.log` or `/var/log/syslog`
  - Kube config on the instance: `/etc/rancher/k3s/k3s.yaml` or `/home/ubuntu/.kube/config`
- If Helm releases do not appear, SSH into the instance and run:
  ```bash
  kubectl get pods --all-namespaces
  ```

# Cleanup
- Terminate the EC2 instance from the console or with:
  ```bash
  aws ec2 terminate-instances --instance-ids <instance-id> --profile <profile> --region <region>
  ```
- If the script created a security group, delete it:
  ```bash
  aws ec2 delete-security-group --group-id <sg-id> --profile <profile> --region <region>
  ```
- If the key created a key-pair, delete it from AWS and local machine:
  ```bash
  # Delete key-pair from AWS
  aws ec2 delete-key-pair --key-name <KEY_NAME> --profile <profile> --region <region>
    
  # Delete from local machine
  rm -f ~/.ssh/<key-name>.pem
  ```
