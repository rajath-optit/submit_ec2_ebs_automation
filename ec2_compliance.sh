#!/bin/bash

# AWS EC2 Compliance Automation Script
# Version: 1.0

# Configuration and Constants
MAX_RETRIES=5
INITIAL_DELAY=5
DEFAULT_REGION="us-east-1"
LOG_FILE="ec2_compliance.log"
REPORT_FILE="ec2_compliance_report.json"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $1" >> "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $1" >> "$LOG_FILE"
}

# Dependency check function
check_dependencies() {
    local missing_deps=()
    
    # Check for AWS CLI
    if ! command -v aws &> /dev/null; then
        missing_deps+=("aws-cli")
    fi
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
        error "Please install the required dependencies and try again."
        exit 1
    fi
}

# Region handling
set_aws_region() {
    local region=${AWS_REGION:-$DEFAULT_REGION}
    export AWS_DEFAULT_REGION=$region
    log "Using AWS Region: $region"
}

# Audit functions
audit_instance() {
    local instance_id=$1
    local report="{\"instance_id\": \"$instance_id\""
    
    # Check encryption
    local ami_id=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].ImageId' --output text)
    local encryption_state=$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Encrypted' --output text)
    report+=", \"ami_encrypted\": \"$encryption_state\""
    
    # Check public IP
    local public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    report+=", \"has_public_ip\": \"$([ -n "$public_ip" ] && [ "$public_ip" != "None" ] && echo "true" || echo "false")\""
    
    # Check IMDSv2
    local imdsv2_state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)
    report+=", \"using_imdsv2\": \"$([ "$imdsv2_state" == "required" ] && echo "true" || echo "false")\""
    
    # Check IAM profile
    local iam_profile=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile' --output text)
    report+=", \"has_iam_profile\": \"$([ -n "$iam_profile" ] && [ "$iam_profile" != "None" ] && echo "true" || echo "false")\"}"
    
    echo "$report" >> "$REPORT_FILE"
    log "Completed audit for instance $instance_id"
}

audit_all_instances() {
    log "Starting comprehensive audit of all EC2 instances"
    echo "[" > "$REPORT_FILE"
    
    local instance_ids=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text)
    local first=true
    
    for instance_id in $instance_ids; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$REPORT_FILE"
        fi
        audit_instance "$instance_id"
    done
    
    echo "]" >> "$REPORT_FILE"
    log "Audit complete. Results saved to $REPORT_FILE"
}

# Your existing EC2 control functions here
#ec2_control1: Ensure AMIs are encrypted
ec2_control1() {
    log "Running EC2 Control 1: Ensure AMI is encrypted"
    
    # Loop through all AMIs in the region
    for ami_id in $(aws ec2 describe-images --query 'Images[*].ImageId' --output text); do
        local encryption_state=$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Encrypted' --output text)
        
        if [ "$encryption_state" == "false" ]; then
            error "AMI $ami_id is not encrypted"
        else
            log "AMI $ami_id is encrypted"
        fi
    done
}

#ec2_control2: Ensure AMIs are not older than 90 days
ec2_control2() {
    log "Running EC2 Control 2: Ensure AMI is not older than 90 days"
    
    local current_date=$(date +%s)
    local ninety_days_ago=$((current_date - 90 * 24 * 60 * 60))a

    # Loop through all AMIs in the region
    for ami_id in $(aws ec2 describe-images --query 'Images[*].ImageId' --output text); do
        local creation_date=$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].CreationDate' --output text)
        local creation_timestamp=$(date -d "$creation_date" +%s)

        if [ "$creation_timestamp" -lt "$ninety_days_ago" ]; then
            error "AMI $ami_id is older than 90 days"
        else
            log "AMI $ami_id is within 90 days"
        fi
    done
}

#ec2_control3: EC2 AMIs should restrict public access
ec2_control3() {
    log "Running EC2 Control 3: EC2 AMIs should restrict public access"

    # Loop through all AMIs in the region
    for ami_id in $(aws ec2 describe-images --query 'Images[*].ImageId' --output text); do
        local public_access=$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Public' --output text)
        
        if [ "$public_access" == "True" ]; then
            error "AMI $ami_id has public access enabled"
        else
            log "AMI $ami_id does not have public access"
        fi
    done
}

#ec2_control4: EC2 Client VPN endpoints should have client connection logging enabled
ec2_control4() {
    log "Running EC2 Control 4: EC2 Client VPN endpoints should have client connection logging enabled"
    
    # Loop through all Client VPN endpoints
    for vpn_id in $(aws ec2 describe-client-vpn-endpoints --query 'ClientVpnEndpoints[*].ClientVpnEndpointId' --output text); do
        local logging_status=$(aws ec2 describe-client-vpn-endpoints --client-vpn-endpoint-id "$vpn_id" --query 'ClientVpnEndpoints[0].ConnectionLogOptions.Enabled' --output text)
        
        if [ "$logging_status" == "False" ]; then
            error "Client VPN $vpn_id does not have logging enabled"
        else
            log "Client VPN $vpn_id has logging enabled"
        fi
    done
}

#ec2_control5: EBS default encryption should be enabled
ec2_control5() {
    log "Running EC2 Control 5: EBS default encryption should be enabled"

    local encryption_enabled=$(aws ec2 describe-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text)
    
    if [ "$encryption_enabled" == "false" ]; then
        error "EBS default encryption is not enabled"
    else
        log "EBS default encryption is enabled"
    fi
}

#ec2_control6: Ensure EBS volumes attached to an EC2 instance are marked for deletion upon instance termination
ec2_control6() {
    log "Running EC2 Control 6: Ensure EBS volumes attached to an EC2 instance are marked for deletion upon instance termination"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        # Get all EBS volumes attached to the instance
        for volume_id in $(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].Ebs.VolumeId' --output text); do
            local deletion_flag=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachment[0].DeleteOnTermination' --output text)
            
            if [ "$deletion_flag" != "True" ]; then
                error "Volume $volume_id attached to $instance_id is not marked for deletion upon termination"
            else
                log "Volume $volume_id attached to $instance_id is marked for deletion upon termination"
            fi
        done
    done
}

#ec2_control7: EC2 instance detailed monitoring should be enabled
ec2_control7() {
    log "Running EC2 Control 7: EC2 instance detailed monitoring should be enabled"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local monitoring_state=$(aws ec2 describe-instance-status --instance-ids "$instance_id" --query 'InstanceStatuses[0].InstanceMonitoring.State' --output text)
        
        if [ "$monitoring_state" != "monitoring" ]; then
            error "Detailed monitoring is not enabled for instance $instance_id"
        else
            log "Detailed monitoring is enabled for instance $instance_id"
        fi
    done
}

#ec2_control8: EC2 instance should have EBS optimization enabled
ec2_control8() {
    log "Running EC2 Control 8: EC2 instance should have EBS optimization enabled"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local ebs_optimized=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].EbsOptimized' --output text)
        
        if [ "$ebs_optimized" != "True" ]; then
            error "EBS optimization is not enabled for instance $instance_id"
        else
            log "EBS optimization is enabled for instance $instance_id"
        fi
    done
}

#ec2_control9: EC2 instances should have IAM profile attached
ec2_control9() {
    log "Running EC2 Control 9: EC2 instances should have IAM profile attached"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role" == "None" ]; then
            error "Instance $instance_id does not have an IAM profile attached"
        else
            log "Instance $instance_id has an IAM profile attached"
        fi
    done
}

#ec2_control10: EC2 instances should be in a VPC
ec2_control10() {
    log "Running EC2 Control 10: Ensure EC2 instances are in a VPC"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local vpc_id=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].VpcId' --output text)
        
        if [ "$vpc_id" == "None" ]; then
            error "EC2 instance $instance_id is not in a VPC"
        else
            log "EC2 instance $instance_id is in VPC $vpc_id"
        fi
    done
}

#ec2_control11: EC2 instances should not use key pairs in running state
ec2_control11() {
    log "Running EC2 Control 11: EC2 instances should not use key pairs in running state"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local key_pair=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].KeyName' --output text)
        
        if [ "$key_pair" != "None" ]; then
            error "EC2 instance $instance_id is using a key pair ($key_pair)"
        else
            log "EC2 instance $instance_id is not using a key pair"
        fi
    done
}

#ec2_control12: EC2 instances high-level findings should not be there in Inspector scans
ec2_control12() {
    log "Running EC2 Control 12: EC2 instances should not have high level findings in Inspector scans"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local findings=$(aws inspector2 list-findings --filter 'resourceType=EC2_INSTANCE' --query "findings[?resourceId=='$instance_id'].Severity" --output text)
        
        if [[ "$findings" == *"High"* ]]; then
            error "EC2 instance $instance_id has high severity findings in Inspector scans"
        else
            log "EC2 instance $instance_id has no high severity findings"
        fi
    done
}

#ec2_control13: EC2 instance IAM should not allow pass role and lambda invoke function access
ec2_control13() {
    log "Running EC2 Control 13: EC2 instance IAM should not allow pass role and lambda invoke function access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'PassRole' || echo "$policy" | grep -q 'InvokeFunction'; then
                error "IAM role for EC2 instance $instance_id has PassRole or Lambda InvokeFunction access"
            else
                log "IAM role for EC2 instance $instance_id does not have PassRole or Lambda InvokeFunction access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control14: EC2 instance IAM role should not be attached with credentials exposure access
ec2_control14() {
    log "Running EC2 Control 14: EC2 instance IAM role should not allow credentials exposure access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'sts:AssumeRole' || echo "$policy" | grep -q 'iam:PassRole'; then
                error "IAM role for EC2 instance $instance_id has credentials exposure access"
            else
                log "IAM role for EC2 instance $instance_id does not have credentials exposure access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control15: EC2 instance IAM role should not allow altering critical S3 permissions configuration
ec2_control15() {
    log "Running EC2 Control 15: EC2 instance IAM role should not allow altering critical S3 permissions configuration"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 's3:PutBucketAcl' || echo "$policy" | grep -q 's3:PutBucketPolicy'; then
                error "IAM role for EC2 instance $instance_id can alter critical S3 permissions"
            else
                log "IAM role for EC2 instance $instance_id does not allow altering critical S3 permissions"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control16: EC2 instance IAM role should not allow cloud log tampering access
ec2_control16() {
    log "Running EC2 Control 16: EC2 instance IAM role should not allow cloud log tampering access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'logs:DeleteLogStream' || echo "$policy" | grep -q 'logs:DeleteLogGroup'; then
                error "IAM role for EC2 instance $instance_id can tamper with CloudWatch logs"
            else
                log "IAM role for EC2 instance $instance_id does not allow CloudWatch log tampering"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control17: EC2 instance IAM role should not allow data destruction access
ec2_control17() {
    log "Running EC2 Control 17: EC2 instance IAM role should not allow data destruction access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 's3:DeleteObject' || echo "$policy" | grep -q 'ec2:TerminateInstances'; then
                error "IAM role for EC2 instance $instance_id allows data destruction"
            else
                log "IAM role for EC2 instance $instance_id does not allow data destruction"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control18: EC2 instance IAM role should not allow database management write access
ec2_control18() {
    log "Running EC2 Control 18: EC2 instance IAM role should not allow database management write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'rds:ModifyDBInstance' || echo "$policy" | grep -q 'dynamodb:UpdateItem'; then
                error "IAM role for EC2 instance $instance_id allows database management write access"
            else
                log "IAM role for EC2 instance $instance_id does not allow database management write access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control19: EC2 instance IAM role should not allow defense evasion impact of AWS security services access
ec2_control19() {
    log "Running EC2 Control 19: EC2 instance IAM role should not allow defense evasion impact of AWS security services access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'guardduty:DeclineInvitations' || echo "$policy" | grep -q 'macie:DeleteFindings'; then
                error "IAM role for EC2 instance $instance_id allows defense evasion actions"
            else
                log "IAM role for EC2 instance $instance_id does not allow defense evasion actions"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control20: EC2 instance IAM role should not allow destruction KMS access
ec2_control20() {
    log "Running EC2 Control 20: EC2 instance IAM role should not allow destruction KMS access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'kms:Delete*' || echo "$policy" | grep -q 'kms:ScheduleKeyDeletion'; then
                error "IAM role for EC2 instance $instance_id allows destruction of KMS keys"
            else
                log "IAM role for EC2 instance $instance_id does not allow destruction of KMS keys"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}
#ec2_control21: EC2 instance IAM role should not allow destruction RDS access
ec2_control21() {
    log "Running EC2 Control 21: EC2 instance IAM role should not allow destruction RDS access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'rds:DeleteDBInstance' || echo "$policy" | grep -q 'rds:DeleteDBCluster'; then
                error "IAM role for EC2 instance $instance_id allows destruction of RDS instances"
            else
                log "IAM role for EC2 instance $instance_id does not allow destruction of RDS instances"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}
#ec2_control22: EC2 instance IAM role should not allow elastic IP hijacking access
ec2_control22() {
    log "Running EC2 Control 22: EC2 instance IAM role should not allow elastic IP hijacking access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'ec2:AssociateAddress' || echo "$policy" | grep -q 'ec2:DisassociateAddress'; then
                error "IAM role for EC2 instance $instance_id allows Elastic IP hijacking"
            else
                log "IAM role for EC2 instance $instance_id does not allow Elastic IP hijacking"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}
#ec2_control23: EC2 instance IAM role should not allow management-level access
ec2_control23() {
    log "Running EC2 Control 23: EC2 instance IAM role should not allow management-level access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:Create*' || echo "$policy" | grep -q 'iam:Delete*' || echo "$policy" | grep -q 'iam:Update*'; then
                error "IAM role for EC2 instance $instance_id allows management-level access"
            else
                log "IAM role for EC2 instance $instance_id does not allow management-level access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control24: EC2 instance IAM role should not allow new group creation with attached policy access
ec2_control24() {
    log "Running EC2 Control 24: EC2 instance IAM role should not allow new group creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:CreateGroup' || echo "$policy" | grep -q 'iam:AttachGroupPolicy'; then
                error "IAM role for EC2 instance $instance_id allows new group creation with attached policy"
            else
                log "IAM role for EC2 instance $instance_id does not allow new group creation with attached policy"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control25: EC2 instance IAM role should not allow new role creation with attached policy access
ec2_control25() {
    log "Running EC2 Control 25: EC2 instance IAM role should not allow new role creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:CreateRole' || echo "$policy" | grep -q 'iam:AttachRolePolicy'; then
                error "IAM role for EC2 instance $instance_id allows new role creation with attached policy"
            else
                log "IAM role for EC2 instance $instance_id does not allow new role creation with attached policy"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control26: EC2 instance IAM role should not allow new user creation with attached policy access
ec2_control26() {
    log "Running EC2 Control 26: EC2 instance IAM role should not allow new user creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:CreateUser' || echo "$policy" | grep -q 'iam:AttachUserPolicy'; then
                error "IAM role for EC2 instance $instance_id allows new user creation with attached policy"
            else
                log "IAM role for EC2 instance $instance_id does not allow new user creation with attached policy"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control27: EC2 instance IAM role should not allow organization write access
ec2_control27() {
    log "Running EC2 Control 27: EC2 instance IAM role should not allow organization write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'organizations:Create*' || echo "$policy" | grep -q 'organizations:Update*' || echo "$policy" | grep -q 'organizations:Delete*'; then
                error "IAM role for EC2 instance $instance_id allows organization write access"
            else
                log "IAM role for EC2 instance $instance_id does not allow organization write access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control28: EC2 instance IAM role should not allow privilege escalation risk access
ec2_control28() {
    log "Running EC2 Control 28: EC2 instance IAM role should not allow privilege escalation risk access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:PassRole'; then
                error "IAM role for EC2 instance $instance_id has a privilege escalation risk"
            else
                log "IAM role for EC2 instance $instance_id does not have privilege escalation risk"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control29: EC2 instance IAM role should not allow security group write access
ec2_control29() {
    log "Running EC2 Control 29: EC2 instance IAM role should not allow security group write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'ec2:AuthorizeSecurityGroupIngress' || echo "$policy" | grep -q 'ec2:AuthorizeSecurityGroupEgress' || echo "$policy" | grep -q 'ec2:RevokeSecurityGroupIngress' || echo "$policy" | grep -q 'ec2:RevokeSecurityGroupEgress'; then
                error "IAM role for EC2 instance $instance_id allows security group write access"
            else
                log "IAM role for EC2 instance $instance_id does not allow security group write access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control30: EC2 instance IAM role should not allow write access to resource-based policies
ec2_control30() {
    log "Running EC2 Control 30: EC2 instance IAM role should not allow write access to resource-based policies"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:PutRolePolicy' || echo "$policy" | grep -q 'iam:PutUserPolicy'; then
                error "IAM role for EC2 instance $instance_id allows write access to resource-based policies"
            else
                log "IAM role for EC2 instance $instance_id does not allow write access to resource-based policies"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}

#ec2_control31: EC2 instance IAM role should not allow write permission on critical S3 configuration
ec2_control31() {
    log "Running EC2 Control 31: EC2 instance IAM role should not allow write permission on critical S3 configuration"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 's3:PutBucketPolicy' || echo "$policy" | grep -q 's3:PutBucketAcl'; then
                error "IAM role for EC2 instance $instance_id allows write permission on critical S3 configuration"
            else
                log "IAM role for EC2 instance $instance_id does not allow write permission on critical S3 configuration"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}
#ec2_control32: EC2 instance IAM role should not allow write-level access
ec2_control32() {
    log "Running EC2 Control 32: EC2 instance IAM role should not allow write-level access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_arn=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$iam_role_arn" != "None" ]; then
            local policy=$(aws iam get-role-policy --role-name "$(basename "$iam_role_arn")" --policy-name 'default' --query 'PolicyDocument.Statement')
            
            if echo "$policy" | grep -q 'iam:Put*' || echo "$policy" | grep -q 'iam:Delete*' || echo "$policy" | grep -q 'iam:Update*'; then
                error "IAM role for EC2 instance $instance_id allows write-level access"
            else
                log "IAM role for EC2 instance $instance_id does not allow write-level access"
            fi
        else
            log "EC2 instance $instance_id has no IAM role"
        fi
    done
}
#ec2_control33: EC2 instances should not be attached to 'launch wizard' security groups
ec2_control33() {
    log "Running EC2 Control 33: EC2 instances should not be attached to 'launch wizard' security groups"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local security_groups=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupName' --output text)
        
        if echo "$security_groups" | grep -q 'launch wizard'; then
            error "EC2 instance $instance_id is attached to a 'launch wizard' security group"
        else
            log "EC2 instance $instance_id is not attached to a 'launch wizard' security group"
        fi
    done
}
#ec2_control34: Ensure no AWS EC2 Instances are older than 180 days
ec2_control34() {
    log "Running EC2 Control 34: Ensure no AWS EC2 Instances are older than 180 days"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local launch_time=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].LaunchTime' --output text)
        local instance_age=$(( ( $(date +%s) - $(date -d "$launch_time" +%s) ) / 86400 ))
        
        if [ "$instance_age" -gt 180 ]; then
            error "EC2 instance $instance_id is older than 180 days"
        else
            log "EC2 instance $instance_id is not older than 180 days"
        fi
    done
}

#ec2_control35: EC2 instances should not have a public IP address
ec2_control35() {
    log "Running EC2 Control 35: EC2 instances should not have a public IP address"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        
        if [ "$public_ip" != "None" ]; then
            error "EC2 instance $instance_id has a public IP address"
        else
            log "EC2 instance $instance_id does not have a public IP address"
        fi
    done
}

#ec2_control36: EC2 instances should not use multiple ENIs
ec2_control36() {
    log "Running EC2 Control 36: EC2 instances should not use multiple ENIs"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local eni_count=$(aws ec2 describe-network-interfaces --filters Name=attachment.instance-id,Values="$instance_id" --query 'NetworkInterfaces[].[NetworkInterfaceId]' --output text | wc -l)
        
        if [ "$eni_count" -gt 1 ]; then
            error "EC2 instance $instance_id is using multiple ENIs"
        else
            log "EC2 instance $instance_id is not using multiple ENIs"
        fi
    done
}

#ec2_control37: EC2 instances should be protected by backup plan
ec2_control37() {
    log "Running EC2 Control 37: EC2 instances should be protected by backup plan"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local backup_plan=$(aws backup list-protected-resources --resource-type EC2 --query 'BackupPlans[*].BackupPlanName' --output text)
        
        if echo "$backup_plan" | grep -q "$instance_id"; then
            log "EC2 instance $instance_id is protected by a backup plan"
        else
            error "EC2 instance $instance_id is not protected by a backup plan"
        fi
    done
}

#ec2_control38: Public EC2 instances should have IAM profile attached
ec2_control38() {
    log "Running EC2 Control 38: Public EC2 instances should have IAM profile attached"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local public_ip=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        local iam_profile=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
        
        if [ "$public_ip" != "None" ] && [ "$iam_profile" == "None" ]; then
            error "Public EC2 instance $instance_id does not have an IAM profile attached"
        else
            log "Public EC2 instance $instance_id has IAM profile attached"
        fi
    done
}

#ec2_control39: AWS EC2 instances should have termination protection enabled
ec2_control39() {
    log "Running EC2 Control 39: AWS EC2 instances should have termination protection enabled"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local termination_protection=$(aws ec2 describe-instance-attribute --instance-id "$instance_id" --attribute disableApiTermination --query 'DisableApiTermination.Value' --output text)
        
        if [ "$termination_protection" == "false" ]; then
            error "EC2 instance $instance_id does not have termination protection enabled"
        else
            log "EC2 instance $instance_id has termination protection enabled"
        fi
    done
}

#ec2_control40: EC2 instances user data should not have secrets
ec2_control40() {
    log "Running EC2 Control 40: EC2 instances user data should not have secrets"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local user_data=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].UserData' --output text)
        
        # Check if user data contains sensitive information (this is a simple example, modify to your own needs)
        if echo "$user_data" | grep -iqE 'password|secret|api_key|aws_access_key|aws_secret_key'; then
            error "EC2 instance $instance_id user data contains secrets"
        else
            log "EC2 instance $instance_id user data does not contain secrets"
        fi
    done
}

#ec2_control41: EC2 instances should use IMDSv2
ec2_control41() {
    log "Running EC2 Control 41: EC2 instances should use IMDSv2"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local metadata_options=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)
        
        if [ "$metadata_options" != "required" ]; then
            error "EC2 instance $instance_id does not use IMDSv2"
        else
            log "EC2 instance $instance_id uses IMDSv2"
        fi
    done
}

#ec2_control42: Paravirtual EC2 instance types should not be used
ec2_control42() {
    log "Running EC2 Control 42: Paravirtual EC2 instance types should not be used"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local instance_type=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].InstanceType' --output text)
        
        # List of paravirtual instance types
        local paravirtual_types=("t1.micro" "m1.small" "m1.medium" "c1.medium" "cc2.8xlarge" "hi1.4xlarge" "hs1.8xlarge" "cr1.8xlarge")
        
        if [[ " ${paravirtual_types[@]} " =~ " $instance_type " ]]; then
            error "EC2 instance $instance_id is using a paravirtual instance type ($instance_type)"
        else
            log "EC2 instance $instance_id is not using a paravirtual instance type"
        fi
    done
}

#ec2_control43: AWS EC2 launch templates should not assign public IPs to network interfaces
ec2_control43() {
    log "Running EC2 Control 43: AWS EC2 launch templates should not assign public IPs to network interfaces"
    
    # Loop through all EC2 launch templates
    for launch_template_id in $(aws ec2 describe-launch-templates --query 'LaunchTemplates[*].LaunchTemplateId' --output text); do
        local associate_public_ip=$(aws ec2 describe-launch-template-versions --launch-template-id "$launch_template_id" --query 'LaunchTemplateVersions[*].VersionData.NetworkInterfaces[0].AssociatePublicIpAddress' --output text)
        
        if [ "$associate_public_ip" == "True" ]; then
            error "Launch template $launch_template_id assigns a public IP to network interfaces"
        else
            log "Launch template $launch_template_id does not assign a public IP to network interfaces"
        fi
    done
}

#ec2_control44: Ensure unused ENIs are removed
ec2_control44() {
    log "Running EC2 Control 44: Ensure unused ENIs are removed"
    
    # List all network interfaces
    for eni_id in $(aws ec2 describe-network-interfaces --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text); do
        local eni_attachment=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni_id" --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text)
        
        if [ "$eni_attachment" == "None" ]; then
            log "Network interface $eni_id is unused and should be removed"
            # Uncomment to delete unused ENIs (requires careful use)
            # aws ec2 delete-network-interface --network-interface-id "$eni_id"
        else
            log "Network interface $eni_id is in use"
        fi
    done
}

ec2_control45: EC2 stopped instances should be removed in 30 days
ec2_control45() {
    log "Running EC2 Control 45: EC2 stopped instances should be removed in 30 days"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text)
        
        if [ "$state" == "stopped" ]; then
            local launch_time=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].LaunchTime' --output text)
            local stopped_for=$(( ( $(date +%s) - $(date -d "$launch_time" +%s) ) / 86400 ))
            
            if [ "$stopped_for" -gt 30 ]; then
                error "EC2 instance $instance_id has been stopped for more than 30 days and should be removed"
            else
                log "EC2 instance $instance_id has been stopped for $stopped_for days"
            fi
        fi
    done
}

#ec2_control46: Ensure instances stopped for over 90 days are removed
ec2_control46() {
    log "Running EC2 Control 46: Ensure instances stopped for over 90 days are removed"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local state=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text)
        
        if [ "$state" == "stopped" ]; then
            local launch_time=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].LaunchTime' --output text)
            local stopped_for=$(( ( $(date +%s) - $(date -d "$launch_time" +%s) ) / 86400 ))
            
            if [ "$stopped_for" -gt 90 ]; then
                error "EC2 instance $instance_id has been stopped for more than 90 days and should be removed"
            else
                log "EC2 instance $instance_id has been stopped for $stopped_for days"
            fi
        fi
    done
}

#ec2_control47: EC2 transit gateways should have auto accept shared attachments disabled
ec2_control47() {
    log "Running EC2 Control 47: EC2 transit gateways should have auto accept shared attachments disabled"
    
    # Loop through all transit gateways
    for tgw_id in $(aws ec2 describe-transit-gateways --query 'TransitGateways[*].TransitGatewayId' --output text); do
        local auto_accept=$(aws ec2 describe-transit-gateway-attachments --transit-gateway-id "$tgw_id" --query 'TransitGatewayAttachments[*].AutoAccept' --output text)
        
        if [ "$auto_accept" == "true" ]; then
            error "EC2 transit gateway $tgw_id has auto accept shared attachments enabled"
        else
            log "EC2 transit gateway $tgw_id has auto accept shared attachments disabled"
        fi
    done
}

#ec2_control48: AWS EC2 instances should have termination protection enabled
ec2_control48() {
    log "Running EC2 Control 48: AWS EC2 instances should have termination protection enabled"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local termination_protection=$(aws ec2 describe-instance-attribute --instance-id "$instance_id" --attribute disableApiTermination --query 'DisableApiTermination.Value' --output text)
        
        if [ "$termination_protection" == "false" ]; then
            error "EC2 instance $instance_id does not have termination protection enabled"
        else
            log "EC2 instance $instance_id has termination protection enabled"
        fi
    done
}

#ec2_control49: AWS EC2 launch templates should not assign public IPs to network interfaces
ec2_control49() {
    log "Running EC2 Control 49: AWS EC2 launch templates should not assign public IPs to network interfaces"
    
    # Loop through all EC2 launch templates
    for launch_template_id in $(aws ec2 describe-launch-templates --query 'LaunchTemplates[*].LaunchTemplateId' --output text); do
        local associate_public_ip=$(aws ec2 describe-launch-template-versions --launch-template-id "$launch_template_id" --query 'LaunchTemplateVersions[*].VersionData.NetworkInterfaces[0].AssociatePublicIpAddress' --output text)
        
        if [ "$associate_public_ip" == "True" ]; then
            error "Launch template $launch_template_id assigns a public IP to network interfaces"
        else
            log "Launch template $launch_template_id does not assign a public IP to network interfaces"
        fi
    done
}

#ec2_control50: EBS default encryption should be enabled
ec2_control50() {
    log "Running EC2 Control 50: EBS default encryption should be enabled"
    
    # Check if EBS default encryption is enabled in the region
    local ebs_encryption_enabled=$(aws ec2 describe-volumes --query 'Volumes[0].Encrypted' --output text)
    
    if [ "$ebs_encryption_enabled" != "True" ]; then
        error "EBS default encryption is not enabled"
    else
        log "EBS default encryption is enabled"
    fi
}

#ec2_control51: EC2 AMIs should restrict public access
ec2_control51() {
    log "Running EC2 Control 51: EC2 AMIs should restrict public access"
    
    # Loop through all AMIs
    for ami_id in $(aws ec2 describe-images --query 'Images[*].ImageId' --output text); do
        local public_access=$(aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].Public' --output text)
        
        if [ "$public_access" == "true" ]; then
            error "EC2 AMI $ami_id has public access enabled"
        else
            log "EC2 AMI $ami_id has public access restricted"
        fi
    done
}

#ec2_control52: EC2 instance detailed monitoring should be enabled
ec2_control52() {
    log "Running EC2 Control 52: EC2 instance detailed monitoring should be enabled"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local detailed_monitoring=$(aws ec2 describe-instance-status --instance-id "$instance_id" --query 'InstanceStatuses[0].InstanceStatus.DetailedMonitoring' --output text)
        
        if [ "$detailed_monitoring" == "disabled" ]; then
            error "EC2 instance $instance_id does not have detailed monitoring enabled"
        else
            log "EC2 instance $instance_id has detailed monitoring enabled"
        fi
    done
}

#ec2_control53: EC2 instance IAM role should not allow cloud log tampering access
ec2_control53() {
    log "Running EC2 Control 53: EC2 instance IAM role should not allow cloud log tampering access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for cloud log tampering permissions
        local tampering_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'CloudWatchLogsPolicy' --query 'PolicyDocument.Statement[?Action==`logs:PutLogEvents`].Effect' --output text)
        
        if [ "$tampering_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows cloud log tampering access"
        else
            log "IAM role $iam_role_name does not allow cloud log tampering access"
        fi
    done
}

#ec2_control54: EC2 instance IAM role should not allow data destruction access
ec2_control54() {
    log "Running EC2 Control 54: EC2 instance IAM role should not allow data destruction access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for data destruction permissions
        local destruction_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'DataDestructionPolicy' --query 'PolicyDocument.Statement[?Action==`s3:DeleteObject` || Action==`ec2:TerminateInstances`].Effect' --output text)
        
        if [ "$destruction_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows data destruction access"
        else
            log "IAM role $iam_role_name does not allow data destruction access"
        fi
    done
}

#ec2_control55: EC2 instance IAM role should not allow database management write access
ec2_control55() {
    log "Running EC2 Control 55: EC2 instance IAM role should not allow database management write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for database management write permissions
        local db_management_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'DatabaseManagementPolicy' --query 'PolicyDocument.Statement[?Action==`rds:ModifyDBInstance`].Effect' --output text)
        
        if [ "$db_management_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows database management write access"
        else
            log "IAM role $iam_role_name does not allow database management write access"
        fi
    done
}

#ec2_control56: EC2 instance IAM role should not allow defense evasion impact of AWS security services access
ec2_control56() {
    log "Running EC2 Control 56: EC2 instance IAM role should not allow defense evasion impact of AWS security services access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for defense evasion permissions
        local evasion_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'DefenseEvasionPolicy' --query 'PolicyDocument.Statement[?Action==`securityhub:UpdateFindings`].Effect' --output text)
        
        if [ "$evasion_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows defense evasion access"
        else
            log "IAM role $iam_role_name does not allow defense evasion access"
        fi
    done
}

#ec2_control57: EC2 instance IAM role should not allow destruction KMS access
ec2_control57() {
    log "Running EC2 Control 57: EC2 instance IAM role should not allow destruction KMS access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for KMS destruction permissions
        local kms_destruction_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'KMSTerminationPolicy' --query 'PolicyDocument.Statement[?Action==`kms:ScheduleKeyDeletion`].Effect' --output text)
        
        if [ "$kms_destruction_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows KMS destruction access"
        else
            log "IAM role $iam_role_name does not allow KMS destruction access"
        fi
    done
}

#ec2_control58: EC2 instance IAM role should not allow destruction RDS access
ec2_control58() {
    log "Running EC2 Control 58: EC2 instance IAM role should not allow destruction RDS access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for RDS destruction permissions
        local rds_destruction_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'RDSDestructionPolicy' --query 'PolicyDocument.Statement[?Action==`rds:DeleteDBInstance`].Effect' --output text)
        
        if [ "$rds_destruction_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows RDS destruction access"
        else
            log "IAM role $iam_role_name does not allow RDS destruction access"
        fi
    done
}

#ec2_control59: EC2 instance IAM role should not allow elastic IP hijacking access
ec2_control59() {
    log "Running EC2 Control 59: EC2 instance IAM role should not allow elastic IP hijacking access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for elastic IP hijacking permissions
        local eip_hijacking_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'ElasticIPHijackingPolicy' --query 'PolicyDocument.Statement[?Action==`ec2:AssociateAddress`].Effect' --output text)
        
        if [ "$eip_hijacking_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows Elastic IP hijacking access"
        else
            log "IAM role $iam_role_name does not allow Elastic IP hijacking access"
        fi
    done
}

#ec2_control60: EC2 instance IAM role should not allow management level access
ec2_control60() {
    log "Running EC2 Control 60: EC2 instance IAM role should not allow management level access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for management level permissions
        local management_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'ManagementLevelPolicy' --query 'PolicyDocument.Statement[?Action==`iam:CreateGroup` || Action==`iam:CreateRole` || Action==`iam:CreateUser`].Effect' --output text)
        
        if [ "$management_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows management level access"
        else
            log "IAM role $iam_role_name does not allow management level access"
        fi
    done
}

#ec2_control61: EC2 instance IAM role should not allow new group creation with attached policy access
ec2_control61() {
    log "Running EC2 Control 61: EC2 instance IAM role should not allow new group creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for group creation permissions with policy
        local group_creation_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'GroupCreationPolicy' --query 'PolicyDocument.Statement[?Action==`iam:CreateGroup` && Action==`iam:AttachGroupPolicy`].Effect' --output text)
        
        if [ "$group_creation_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows new group creation with attached policy access"
        else
            log "IAM role $iam_role_name does not allow new group creation with attached policy access"
        fi
    done
}

#ec2_control62: EC2 instance IAM role should not allow new role creation with attached policy access
ec2_control62() {
    log "Running EC2 Control 62: EC2 instance IAM role should not allow new role creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for role creation with attached policy
        local role_creation_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'RoleCreationPolicy' --query 'PolicyDocument.Statement[?Action==`iam:CreateRole` && Action==`iam:AttachRolePolicy`].Effect' --output text)
        
        if [ "$role_creation_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows new role creation with attached policy access"
        else
            log "IAM role $iam_role_name does not allow new role creation with attached policy access"
        fi
    done
}

#ec2_control63: EC2 instance IAM role should not allow new user creation with attached policy access
ec2_control63() {
    log "Running EC2 Control 63: EC2 instance IAM role should not allow new user creation with attached policy access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for user creation with attached policy
        local user_creation_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'UserCreationPolicy' --query 'PolicyDocument.Statement[?Action==`iam:CreateUser` && Action==`iam:AttachUserPolicy`].Effect' --output text)
        
        if [ "$user_creation_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows new user creation with attached policy access"
        else
            log "IAM role $iam_role_name does not allow new user creation with attached policy access"
        fi
    done
}

#ec2_control64: EC2 instance IAM role should not allow organization write access
ec2_control64() {
    log "Running EC2 Control 64: EC2 instance IAM role should not allow organization write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for organization write permissions
        local org_write_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'OrganizationWritePolicy' --query 'PolicyDocument.Statement[?Action==`organizations:CreateAccount`].Effect' --output text)
        
        if [ "$org_write_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows organization write access"
        else
            log "IAM role $iam_role_name does not allow organization write access"
        fi
    done
}

ec2_control65() {
    log "Running EC2 Control 65: EC2 instance IAM role should not allow privilege escalation risk access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for privilege escalation permissions
        local escalation_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'EscalationPolicy' --query 'PolicyDocument.Statement[?Action==`iam:PassRole`].Effect' --output text)
        
        if [ "$escalation_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows privilege escalation risk access"
        else
            log "IAM role $iam_role_name does not allow privilege escalation risk access"
        fi
    done
}

ec2_control66() {
    log "Running EC2 Control 66: EC2 instance IAM role should not allow security group write access"
    
    # Loop through all EC2 instances
    for instance_id in $(aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text); do
        local iam_role_name=$(aws ec2 describe-instances --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | sed 's/.*\/\(.*\)/\1/')
        
        # Check IAM role for security group write permissions
        local sg_write_permission=$(aws iam get-role-policy --role-name "$iam_role_name" --policy-name 'SecurityGroupWritePolicy' --query 'PolicyDocument.Statement[?Action==`ec2:AuthorizeSecurityGroupIngress` || Action==`ec2:AuthorizeSecurityGroupEgress`].Effect' --output text)
        
        if [ "$sg_write_permission" == "Allow" ]; then
            error "IAM role $iam_role_name allows security group write access"
        else
            log "IAM role $iam_role_name does not allow security group write access"
        fi
    done
}
# Main function
main() {
    # Initialize logging
    > "$LOG_FILE"
    log "Starting AWS EC2 Compliance Automation Tool"
    
    # Check dependencies
    check_dependencies
    
    # Set AWS region
    set_aws_region

    echo "AWS EC2 Compliance Automation Tool"
    echo "======================================"
    
    echo "Select action to perform:"
    echo "1) Run individual control"
    echo "2) Audit all instances in the account/region"
    
    read -p "Enter choice (1-2): " choice

    case $choice in
        1)
            echo "Select control to run:"
            echo "1) Ensure AMIs are encrypted"
            echo "2) Ensure AMIs are not older than 90 days"
            echo "3) EC2 AMIs should restrict public access"
            echo "4) EC2 Client VPN endpoints should have client connection logging enabled"
            echo "5) EBS default encryption should be enabled"
            echo "6) Ensure EBS volumes attached to an EC2 instance are marked for deletion upon instance termination"
            echo "7) EC2 instance detailed monitoring should be enabled"
            echo "8) EC2 instance should have EBS optimization enabled"
            echo "9) EC2 instances should have IAM profile attached"
            echo "10) EC2 instances should be in a VPC"
            echo "11) EC2 instances should not use key pairs in running state"
            echo "12) EC2 instances high-level findings should not be there in Inspector scans"
            echo "13) EC2 instance IAM should not allow pass role and lambda invoke function access"
            echo "14) EC2 instance IAM role should not be attached with credentials exposure access"
            echo "15) EC2 instance IAM role should not allow altering critical S3 permissions"
            echo "16) EC2 instance IAM role should not allow cloud log tampering access"
            echo "17) EC2 instance IAM role should not allow data destruction access"
            echo "18) EC2 instance IAM role should not allow database management write access"
            echo "19) EC2 instance IAM role should not allow defense evasion impact of AWS security"
            echo "20) EC2 instance IAM role should not allow destruction KMS access"
            echo "21) EC2 instance IAM role should not allow destruction RDS access"
            echo "22) EC2 instance IAM role should not allow elastic IP hijacking access"
            echo "23) EC2 instance IAM role should not allow management-level access"
            echo "24) EC2 instance IAM role should not allow new group creation with attached policy access"
            echo "25) EC2 instance IAM role should not allow new role creation with attached policy access"
            echo "26) EC2 instance IAM role should not allow new user creation with attached policy access"
            echo "27) EC2 instance IAM role should not allow organization write access"
            echo "28) EC2 instance IAM role should not allow privilege escalation risk access"
            echo "29) EC2 instance IAM role should not allow security group write access"
            echo "30) EC2 instance IAM role should not allow write access to resource-based policies"
            echo "31) EC2 instance IAM role should not allow write permission on critical S3 configuration"
            echo "32) EC2 instance IAM role should not allow write-level access"
            echo "33) EC2 instances should not be attached to 'launch wizard' security groups"
            echo "34) Ensure no AWS EC2 Instances are older than 180 days"
            echo "35) EC2 instances should not have a public IP address"
            echo "36) EC2 instances should not use multiple ENIs"
            echo "37) EC2 instances should be protected by backup plan"
            echo "38) Public EC2 instances should have IAM profile attached"
            echo "39) AWS EC2 instances should have termination protection enabled"
            echo "40) EC2 instances user data should not have secrets"
            echo "41) EC2 instances should use IMDSv2"
            echo "42) Paravirtual EC2 instance types should not be used"
            echo "43) AWS EC2 launch templates should not assign public IPs to network interfaces"
            echo "44) Ensure unused ENIs are removed"
            echo "45) EC2 stopped instances should be removed in 30 days"
            echo "46) Ensure instances stopped for over 90 days are removed"
            echo "47) EC2 transit gateways should have auto accept shared attachments disabled"
            echo "48) AWS EC2 instances should have termination protection enabled"
            echo "49) AWS EC2 launch templates should not assign public IPs to network interfaces"
            echo "50) EBS default encryption should be enabled"
            echo "51) EC2 AMIs should restrict public access"
            echo "52) EC2 instance detailed monitoring should be enabled"
            echo "53) EC2 instance IAM role should not allow cloud log tampering access"
            echo "54) EC2 instance IAM role should not allow data destruction access"
            echo "55) EC2 instance IAM role should not allow database management write access"
            echo "56) EC2 instance IAM role should not allow defense evasion impact of AWS security services access"
            echo "57) EC2 instance IAM role should not allow destruction KMS access"
            echo "58) EC2 instance IAM role should not allow destruction RDS access"
            echo "59) EC2 instance IAM role should not allow elastic IP hijacking access"
            echo "60) EC2 instance IAM role should not allow management level access"
            echo "61) EC2 instance IAM role should not allow new group creation with attached policy access"
            echo "62) EC2 instance IAM role should not allow new role creation with attached policy access"
            echo "63) EC2 instance IAM role should not allow new user creation with attached policy access"
            echo "64) EC2 instance IAM role should not allow organization write access"
            echo "65) EC2 instance IAM role should not allow privilege escalation risk access"
            echo "66) EC2 instance IAM role should not allow security group write access"

            read -p "Enter control number (1-66): " control_choice
            
            case $control_choice in
                1) ec2_control1 ;;
                2) ec2_control2 ;;
                3) ec2_control3 ;;
                4) ec2_control4 ;;
                5) ec2_control5 ;;
                6) ec2_control6 ;;
                7) ec2_control7 ;;
                8) ec2_control8 ;;
                9) ec2_control9 ;;
                10) ec2_control10 ;;
                11) ec2_control11 ;;
                12) ec2_control12 ;;
                13) ec2_control13 ;;
                14) ec2_control14 ;;
                15) ec2_control15 ;;
                16) ec2_control16 ;;
                17) ec2_control17 ;;
                18) ec2_control18 ;;
                19) ec2_control19 ;;
                20) ec2_control20 ;;
                21) ec2_control21 ;;
                22) ec2_control22 ;;
                23) ec2_control23 ;;
                24) ec2_control24 ;;
                25) ec2_control25 ;;
                26) ec2_control26 ;;
                27) ec2_control27 ;;
                28) ec2_control28 ;;
                29) ec2_control29 ;;
                30) ec2_control30 ;;
                31) ec2_control31 ;;
                32) ec2_control32 ;;
                33) ec2_control33 ;;
                34) ec2_control34 ;;
                35) ec2_control35 ;;
                36) ec2_control36 ;;
                37) ec2_control37 ;;
                38) ec2_control38 ;;
                39) ec2_control39 ;;
                40) ec2_control40 ;;
                41) ec2_control41 ;;
                42) ec2_control42 ;;
                43) ec2_control43 ;;
                44) ec2_control44 ;;
                45) ec2_control45 ;;
                46) ec2_control46 ;;
                47) ec2_control47 ;;
                48) ec2_control48 ;;
                49) ec2_control49 ;;
                50) ec2_control50 ;;
                51) ec2_control51 ;;
                52) ec2_control52 ;;
                53) ec2_control53 ;;
                54) ec2_control54 ;;
                55) ec2_control55 ;;
                56) ec2_control56 ;;
                57) ec2_control57 ;;
                58) ec2_control58 ;;
                59) ec2_control59 ;;
                60) ec2_control60 ;;
                61) ec2_control61 ;;
                62) ec2_control62 ;;
                63) ec2_control63 ;;
                64) ec2_control64 ;;
                65) ec2_control65 ;;
                66) ec2_control66 ;;
                *) error "Invalid control selection" ;;
            esac
            ;;
        2)
            audit_all_instances
            ;;
        *)
            error "Invalid selection. Please choose a valid option."
            ;;
    esac
}

# Execute main function
main
