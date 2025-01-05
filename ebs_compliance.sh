#!/bin/bash

# AWS EBS Compliance Automation Script
# Version: 1.2

# Configuration and Constants
MAX_RETRIES=5
INITIAL_DELAY=5
DEFAULT_REGION="us-east-1"
LOG_FILE="ebs_compliance.log"
REPORT_FILE="compliance_report.json"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    
    # Check for GNU parallel
    if ! command -v parallel &> /dev/null; then
        missing_deps+=("parallel")
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

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Enhanced error handling function
handle_error() {
    local error_message=$1
    local error_code=$2
    echo -e "${RED}[ERROR]${NC} $error_message"
    exit $error_code
}

# Retry command with exponential backoff
retry_command() {
    local command="$1"
    local max_retries=5
    local attempt=1
    local delay=5 # initial delay in seconds

    while [ $attempt -le $max_retries ]; do
        echo -e "${GREEN}[INFO]${NC} Attempt $attempt: Running command '$command'"
        
        # Run the command
        eval "$command"

        # If the command was successful (exit code 0), break the loop
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[INFO]${NC} Command '$command' succeeded on attempt $attempt."
            return 0
        else
            # If the command failed, increment the attempt and apply delay
            echo -e "${YELLOW}[WARNING]${NC} Command '$command' failed. Retrying in $delay seconds..."
            sleep $delay
            ((attempt++))
            delay=$((delay * 2))  # Exponential backoff
        fi
    done

    # If we reached the max retries without success, print an error
    handle_error "Command '$command' failed after $max_retries attempts" 2
}

# Function to audit volumes in parallel
audit_volumes_parallel() {
    local volume_ids=($1)

    # Run `audit_volume` for each volume concurrently using parallel
    echo "${volume_ids[@]}" | tr ' ' '\n' | parallel -j 4 "audit_volume {}"
}

# Function to audit a single volume
audit_volume() {
    local volume_id=$1
    local report="{\"volume_id\": \"$volume_id\""
    
    # Check Delete on Termination
    local delete_on_termination=$(aws ec2 describe-volumes --volume-ids "$volume_id" \
        --query 'Volumes[0].Attachments[0].DeleteOnTermination' --output text 2>> "$LOG_FILE")
    report+=", \"delete_on_termination\": \"$delete_on_termination\""
    
    # Check Encryption
    local encryption_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" \
        --query 'Volumes[0].Encrypted' --output text 2>> "$LOG_FILE")
    report+=", \"encrypted\": \"$encryption_state\""
    
    # Check Backup Plan
    local backup_state=$(aws backup list-protected-resources \
        --query "ResourceArnList[?contains(@, '$volume_id')]" --output text 2>> "$LOG_FILE")
    report+=", \"backup_plan\": \"$([ -n "$backup_state" ] && echo "true" || echo "false")\""
    
    # Check Snapshots
    local snapshot_count=$(aws ec2 describe-snapshots --filters "Name=volume-id,Values=$volume_id" \
        --query 'length(Snapshots)' --output text 2>> "$LOG_FILE")
    report+=", \"has_snapshots\": \"$([ "$snapshot_count" -gt 0 ] && echo "true" || echo "false")\""
    
    # Check Attachment
    local attachment_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" \
        --query 'Volumes[0].Attachments[0].State' --output text 2>> "$LOG_FILE")
    report+=", \"attached\": \"$([ "$attachment_state" == "attached" ] && echo "true" || echo "false")\"}"
    
    echo "$report" >> "$REPORT_FILE"
    log "Completed audit for volume $volume_id"
}

audit_all_volumes() {
    log "Starting comprehensive audit of all EBS volumes"
    echo "[" > "$REPORT_FILE"
    
    local volume_ids=$(aws ec2 describe-volumes --query 'Volumes[*].VolumeId' --output text)
    local first=true
    
    for volume_id in $volume_ids; do
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$REPORT_FILE"
        fi
        audit_volume "$volume_id"
    done
    
    echo "]" >> "$REPORT_FILE"
    log "Audit complete. Results saved to $REPORT_FILE"
}

validate_orphaned_snapshots() {
    log "Validating orphaned snapshots"

    # Get all snapshots and check if their volume still exists
    local orphaned_snapshots=""
    local snapshots=$(aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[*].{ID:SnapshotId,VolumeId:VolumeId}' --output json)

    # Loop through snapshots and check for associated volume
    echo "$snapshots" | jq -c '.[]' | while read snapshot; do
        local snapshot_id=$(echo "$snapshot" | jq -r '.ID')
        local volume_id=$(echo "$snapshot" | jq -r '.VolumeId')

        # Check if volume exists
        if ! aws ec2 describe-volumes --volume-ids "$volume_id" >/dev/null 2>&1; then
            orphaned_snapshots+="$snapshot_id\n"
        fi
    done

    if [ -n "$orphaned_snapshots" ]; then
        log "Orphaned snapshots found:"
        echo -e "$orphaned_snapshots"
    else
        log "No orphaned snapshots found"
    fi
}

ebs_control_attach_instance() {
    local volume_id=$1
    log "Running Control: Checking instance attachment for volume $volume_id"

    local attachment_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachments[0].State' --output text)
    
    if [ "$attachment_state" == "attached" ]; then
        log "Volume $volume_id is already attached to an instance"
    else
        error "Volume $volume_id is not attached to any instance"
    fi
}

ebs_control_encryption_at_rest() {
    local volume_id=$1
    log "Running Control: Checking encryption at rest for volume $volume_id"

    local encryption_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Encrypted' --output text)
    
    if [ "$encryption_state" == "true" ]; then
        log "Volume $volume_id is encrypted at rest"
    else
        error "Volume $volume_id is not encrypted at rest"
    fi
}

ebs_control_attach_snapshots() {
    local snapshot_id=$1
    log "Running Control: Checking volume attachment for snapshot $snapshot_id"

    local volume_id=$(aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" --query 'Snapshots[0].VolumeId' --output text)
    if [ -n "$volume_id" ]; then
        ebs_control_attach_instance "$volume_id"
    else
        error "Snapshot $snapshot_id is not associated with any volume"
    fi
}

# EBS Control Functions
ebs_control1() {
    local volume_id=$1
    log "Running EBS Control 1: Checking Delete on Termination flag"
    
    if aws ec2 describe-volumes --volume-ids "$volume_id" >/dev/null 2>&1; then
        local attachment_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachments[0].State' --output text)
        
        if [ "$attachment_state" == "attached" ]; then
            log "Setting Delete on Termination flag for volume $volume_id"
            aws ec2 modify-instance-attribute --instance-id $(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachments[0].InstanceId' --output text) \
                --block-device-mappings "[{\"DeviceName\": \"$(aws ec2 describe-volumes --volume-ids \"$volume_id\" --query 'Volumes[0].Attachments[0].Device' --output text)\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
            log "Successfully updated Delete on Termination flag"
        else
            warning "Volume $volume_id is not attached to any instance"
        fi
    else
        error "Volume $volume_id not found"
        return 1
    fi
}

ebs_control2() {
    local volume_id=$1
    log "Running EBS Control 2: Checking Volume Encryption"
    
    local encryption_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Encrypted' --output text)
    
    if [ "$encryption_state" == "false" ]; then
        log "Volume $volume_id is not encrypted. Creating encrypted snapshot..."
        
        local snapshot_id=$(aws ec2 create-snapshot --volume-id "$volume_id" --description "Automated encryption snapshot" --query 'SnapshotId' --output text)
        
        aws ec2 wait snapshot-completed --snapshot-ids "$snapshot_id"
        
        log "Creating new encrypted volume from snapshot..."
        local new_volume_id=$(aws ec2 create-volume --snapshot-id "$snapshot_id" --encrypted --volume-type gp3 --availability-zone $(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].AvailabilityZone' --output text) --query 'VolumeId' --output text)
        
        aws ec2 wait volume-available --volume-ids "$new_volume_id"
        
        log "Successfully created encrypted volume $new_volume_id"
    else
        log "Volume $volume_id is already encrypted"
    fi
}

ebs_control3() {
    local snapshot_id=$1
    log "Running EBS Control 3: Checking if snapshot is encrypted"

    local encryption_state=$(aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" --query 'Snapshots[0].Encrypted' --output text)
    
    if [ "$encryption_state" == "false" ]; then
        error "Snapshot $snapshot_id is not encrypted"
    else
        log "Snapshot $snapshot_id is encrypted"
    fi
}

ebs_control4() {
    local snapshot_id=$1
    log "Running EBS Control 4: Checking if snapshot is publicly restorable"

    local public_state=$(aws ec2 describe-snapshot-attribute --snapshot-id "$snapshot_id" --attribute createVolumePermission --query 'CreateVolumePermissions' --output text)
    
    if [ -z "$public_state" ]; then
        log "Snapshot $snapshot_id is not publicly restorable"
    else
        error "Snapshot $snapshot_id is publicly restorable"
    fi
}

ebs_control5() {
    log "Running EBS Control 5: Ensuring EBS encryption by default is enabled"

    local encryption_default=$(aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text)
    
    if [ "$encryption_default" == "true" ]; then
        log "EBS encryption by default is enabled"
    else
        error "EBS encryption by default is not enabled"
    fi
}

ebs_control6() {
    local volume_id=$1
    log "Running EBS Control 6: Checking if volume is in a backup plan"

    local backup_state=$(aws backup list-protected-resources --query "ResourceArnList[?contains(@, '$volume_id')].ResourceArn" --output text)
    
    if [ -n "$backup_state" ]; then
        log "Volume $volume_id is protected by a backup plan"
    else
        error "Volume $volume_id is not protected by a backup plan"
    fi
}

ebs_control7() {
    local volume_id=$1
    log "Running EBS Control 7: Checking if snapshots exist for volume"

    local snapshot_count=$(aws ec2 describe-snapshots --filters "Name=volume-id,Values=$volume_id" --query 'Snapshots' --output text | wc -l)
    
    if [ "$snapshot_count" -gt 0 ]; then
        log "Snapshots exist for volume $volume_id"
    else
        error "No snapshots found for volume $volume_id"
    fi
}

ebs_control8() {
    local volume_id=$1
    log "Running EBS Control 8: Checking if volume is attached to an EC2 instance"

    local attachment_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachments[0].State' --output text)

    if [ "$attachment_state" == "attached" ]; then
        log "Volume $volume_id is attached to an EC2 instance"
    else
        error "Volume $volume_id is not attached to any EC2 instance"
    fi
}

ebs_control9() {
    local volume_id=$1
    log "Running EBS Control 9: Checking encryption at rest for volume"

    local encryption_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Encrypted' --output text)

    if [ "$encryption_state" == "true" ]; then
        log "Volume $volume_id is encrypted at rest"
    else
        error "Volume $volume_id is not encrypted at rest"
    fi
}

ebs_control10() {
    local volume_id=$1
    log "Running EBS Control 10: Ensuring volume is protected by a backup plan"

    local backup_state=$(aws backup list-protected-resources --query "ResourceArnList[?contains(@, '$volume_id')]" --output text)

    if [ -n "$backup_state" ]; then
        log "Volume $volume_id is protected by a backup plan"
    else
        error "Volume $volume_id is not protected by a backup plan"
    fi
}

ebs_control11() {
    local volume_id=$1
    log "Running Control: Ensure volume $volume_id is attached to an EC2 instance"

    # Check attachment state
    local attachment_state=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Attachments[0].State' --output text)

    if [ "$attachment_state" == "attached" ]; then
        log "Volume $volume_id is already attached to an EC2 instance"
    else
        # Attach logic
        error "Volume $volume_id is not attached. Please manually attach it to an instance."
    fi
}

ebs_control12() {
    local volume_id=$1
    log "Running Control: Ensure encryption at rest is enabled for volume $volume_id"

    local encrypted=$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].Encrypted' --output text)
    if [ "$encrypted" == "true" ]; then
        log "Encryption at rest is enabled for volume $volume_id"
    else
        error "Encryption at rest is not enabled for volume $volume_id. Consider migrating to an encrypted volume."
    fi
}

ebs_control13() {
    local snapshot_id=$1
    log "Running Control: Ensure snapshot $snapshot_id is attached to an instance (via volume)"

    local volume_id=$(aws ec2 describe-snapshots --snapshot-ids "$snapshot_id" --query 'Snapshots[0].VolumeId' --output text)
    if [ -n "$volume_id" ]; then
        log "Snapshot $snapshot_id belongs to volume $volume_id. Verifying attachment state..."
        ebs_control_attach_instance "$volume_id"
    else
        error "Snapshot $snapshot_id does not belong to any volume."
    fi
}

# Main execution
main() {
    # Initialize logging
    > "$LOG_FILE"
    log "Starting AWS EBS Compliance Automation Tool"
    
    # Check dependencies
    check_dependencies
    
    # Set AWS region
    set_aws_region

    echo "AWS EBS Compliance Automation Tool"
    echo "======================================"
    
        echo "Select action to perform:"
    echo "1) Run individual control"
    echo "2) Audit all volumes in the account/region"
    echo "3) Validate orphaned snapshots"

    read -p "Enter choice (1-3): " choice

    case $choice in
        1)
            echo "Select control to run:"
            echo "1) Attached EBS volumes should have delete on termination enabled"
            echo "2) Attached EBS volumes should have encryption enabled"
            echo "3) EBS snapshots should be encrypted"
            echo "4) EBS snapshots should not be publicly restorable"
            echo "5) EBS encryption by default should be enabled"
            echo "6) EBS volumes should be in a backup plan"
            echo "7) EBS volume snapshots should exist"
            echo "8) Ensure EBS volumes are attached to EC2 instances for proper usage and cost management."
            echo "9) Ensure EBS volumes are encrypted at rest to protect data confidentiality."
            echo "10) Ensure EBS volumes are part of a valid and automated backup plan."
            echo "11) Ensure volume is attached to an EC2 instance"
            echo "12) Ensure volume encryption at rest is enabled"
            echo "13) Ensure snapshots are attached (via volume)"

    read -p "Enter control number (1-10): " control_choice
    
    case $control_choice in
        1)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control1 "$volume_id" ;;
        2)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control2 "$volume_id" ;;
        3)
            read -p "Enter EBS Snapshot ID: " snapshot_id
            ebs_control3 "$snapshot_id" ;;
        4)
            read -p "Enter EBS Snapshot ID: " snapshot_id
            ebs_control4 "$snapshot_id" ;;
        5)
            ebs_control5 ;;
        6)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control6 "$volume_id" ;;
        7)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control7 "$volume_id" ;;
        8)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control8 "$volume_id" ;;
        9)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control9 "$volume_id" ;;
        10)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control10 "$volume_id" ;;
        11)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control_attach_instance "$volume_id" ;;
        12)
            read -p "Enter EBS Volume ID: " volume_id
            ebs_control_encryption_at_rest "$volume_id" ;;
        13)
            read -p "Enter EBS Snapshot ID: " snapshot_id
            ebs_control_attach_snapshots "$snapshot_id" ;;
                *)
            error "Invalid control selection" ;;
    esac
    ;;
2)
    audit_all_volumes  # Call the function to audit all volumes in the account/region
            ;;
3)
    validate_orphaned_snapshots  # Call the function to validate orphaned snapshots
            ;;
*)
    error "Invalid selection. Please choose a valid option." ;;
    esac
}

# Execute main function
main
