#!/bin/bash

# Instance Cost Checker for GCP
# Analyzes costs for specific compute instances

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "Error: config.sh not found. Please copy config.example.sh to config.sh and configure it."
    exit 1
fi

# Check if instance name provided as argument
if [ -n "$1" ]; then
    CHECK_INSTANCE="$1"
else
    CHECK_INSTANCE="$INSTANCE_NAMES"
fi

# Function to format uptime
format_uptime() {
    local start_time="$1"
    local now=$(date +%s)
    local start=$(date -d "$start_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$start_time" +%s 2>/dev/null)
    
    if [ -n "$start" ]; then
        local diff=$((now - start))
        local days=$((diff / 86400))
        local hours=$(((diff % 86400) / 3600))
        echo "${days}d ${hours}h"
    else
        echo "Unknown"
    fi
}

# Function to calculate instance cost
calculate_instance_cost() {
    local machine_type="$1"
    local status="$2"
    
    if [ "$status" != "RUNNING" ]; then
        echo "0.00"
        return
    fi
    
    case "$machine_type" in
        "e2-micro")
            echo "scale=2; $E2_MICRO_MONTHLY / 30" | bc
            ;;
        "e2-small")
            echo "scale=2; $E2_SMALL_MONTHLY / 30" | bc
            ;;
        "e2-medium")
            echo "scale=2; $E2_MEDIUM_MONTHLY / 30" | bc
            ;;
        *)
            echo "0.00"
            ;;
    esac
}

echo "==================================="
echo "GCP Instance Cost Analysis"
echo "==================================="
echo ""

# Set the project
gcloud config set project "$PROJECT_ID" 2>/dev/null

TOTAL_COST=0

for instance in $CHECK_INSTANCE; do
    echo "INSTANCE: $instance"
    echo "-----------------------------------"
    
    # Get comprehensive instance information
    INSTANCE_JSON=$(gcloud compute instances describe "$instance" \
        --zone="$ZONE" \
        --format=json 2>/dev/null)
    
    if [ -z "$INSTANCE_JSON" ]; then
        echo "Error: Instance '$instance' not found in zone '$ZONE'"
        echo ""
        continue
    fi
    
    # Parse instance details
    STATUS=$(echo "$INSTANCE_JSON" | jq -r '.status')
    MACHINE_TYPE=$(echo "$INSTANCE_JSON" | jq -r '.machineType' | awk -F/ '{print $NF}')
    CREATED=$(echo "$INSTANCE_JSON" | jq -r '.creationTimestamp')
    LAST_START=$(echo "$INSTANCE_JSON" | jq -r '.lastStartTimestamp // empty')
    ZONE_NAME=$(echo "$INSTANCE_JSON" | jq -r '.zone' | awk -F/ '{print $NF}')
    
    # Get disk information
    DISKS=$(echo "$INSTANCE_JSON" | jq -r '.disks[].source' | awk -F/ '{print $NF}')
    
    # Get network interfaces
    EXTERNAL_IP=$(echo "$INSTANCE_JSON" | jq -r '.networkInterfaces[0].accessConfigs[0].natIP // "None"')
    INTERNAL_IP=$(echo "$INSTANCE_JSON" | jq -r '.networkInterfaces[0].networkIP')
    
    # Display basic information
    echo "Status: $STATUS"
    echo "Machine Type: $MACHINE_TYPE"
    echo "Zone: $ZONE_NAME"
    echo "Created: ${CREATED:0:10}"
    
    if [ -n "$LAST_START" ]; then
        echo "Last Started: ${LAST_START:0:19}"
        echo "Uptime: $(format_uptime "$LAST_START")"
    fi
    
    echo "Internal IP: $INTERNAL_IP"
    echo "External IP: $EXTERNAL_IP"
    echo ""
    
    # Calculate instance cost
    echo "COST BREAKDOWN:"
    echo "---------------"
    
    # VM Cost
    VM_DAILY_COST=$(calculate_instance_cost "$MACHINE_TYPE" "$STATUS")
    echo "VM ($MACHINE_TYPE): \$$VM_DAILY_COST/day"
    TOTAL_COST=$(echo "$TOTAL_COST + $VM_DAILY_COST" | bc)
    
    # Static IP Cost (if external IP exists)
    if [ "$EXTERNAL_IP" != "None" ] && [ "$EXTERNAL_IP" != "null" ]; then
        IP_DAILY_COST=$(echo "scale=2; $STATIC_IP_MONTHLY / 30" | bc)
        echo "Static IP: \$$IP_DAILY_COST/day"
        TOTAL_COST=$(echo "$TOTAL_COST + $IP_DAILY_COST" | bc)
    fi
    
    # Disk Costs
    DISK_TOTAL=0
    for disk in $DISKS; do
        DISK_INFO=$(gcloud compute disks describe "$disk" --zone="$ZONE_NAME" \
            --format="csv[no-heading](sizeGb,type.scope().segment(-1))" 2>/dev/null)
        
        if [ -n "$DISK_INFO" ]; then
            IFS=',' read -r size type <<< "$DISK_INFO"
            
            if [[ "$type" == *"ssd"* ]]; then
                monthly_cost=$(echo "$size * $SSD_DISK_GB_MONTHLY" | bc)
            else
                monthly_cost=$(echo "$size * $STANDARD_DISK_GB_MONTHLY" | bc)
            fi
            
            daily_cost=$(echo "scale=2; $monthly_cost / 30" | bc)
            echo "Disk ($disk - ${size}GB $type): \$$daily_cost/day"
            DISK_TOTAL=$(echo "$DISK_TOTAL + $daily_cost" | bc)
        fi
    done
    
    TOTAL_COST=$(echo "$TOTAL_COST + $DISK_TOTAL" | bc)
    
    # Instance total
    INSTANCE_TOTAL=$(echo "$VM_DAILY_COST + $IP_DAILY_COST + $DISK_TOTAL" | bc 2>/dev/null || echo "0")
    echo ""
    echo "Instance Daily Total: \$$INSTANCE_TOTAL"
    echo ""
    
    # Performance metrics (if running)
    if [ "$STATUS" = "RUNNING" ]; then
        echo "PERFORMANCE METRICS:"
        echo "-------------------"
        
        # Get CPU utilization (requires monitoring API)
        echo "CPU/Memory metrics require Monitoring API access"
        echo "View in console: https://console.cloud.google.com/compute/instancesDetail/zones/$ZONE_NAME/instances/$instance?project=$PROJECT_ID"
    fi
    
    echo ""
    echo "==================================="
    echo ""
done

echo "TOTAL DAILY COST (all instances): \$$TOTAL_COST"
echo ""

# Cost optimization recommendations
if [ $(echo "$TOTAL_COST > $DAILY_COST_THRESHOLD" | bc) -eq 1 ]; then
    echo "⚠️  WARNING: Daily cost exceeds threshold of \$$DAILY_COST_THRESHOLD"
    echo ""
fi

echo "OPTIMIZATION TIPS:"
echo "-----------------"
echo "1. Use committed use discounts for predictable workloads"
echo "2. Schedule non-critical instances to shut down outside business hours"
echo "3. Right-size instances based on actual CPU/memory usage"
echo "4. Use preemptible instances for fault-tolerant workloads"
echo "5. Delete unattached disks and unused static IPs"