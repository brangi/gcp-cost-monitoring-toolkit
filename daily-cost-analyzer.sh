#!/bin/bash

# Daily Cost Analysis Script for GCP
# Provides comprehensive cost breakdown and analysis

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "Error: config.sh not found. Please copy config.example.sh to config.sh and configure it."
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Function to get current date
get_date() {
    date '+%Y-%m-%d'
}

# Function to calculate daily cost from monthly
monthly_to_daily() {
    echo "scale=2; $1 / 30" | bc
}

# Initialize variables
TOTAL_DAILY_COST=0
COST_BREAKDOWN=""

echo "======================================="
print_color $BLUE "GCP Daily Cost Analysis - $(date '+%B %d, %Y')"
echo "======================================="
echo ""

# Set the project
gcloud config set project "$PROJECT_ID" 2>/dev/null

# 1. INSTANCE ANALYSIS
if [ "$MONITOR_COMPUTE" = "true" ]; then
    print_color $YELLOW "1. COMPUTE ENGINE INSTANCES:"
    echo "----------------------------"
    
    INSTANCE_COST=0
    for instance in $INSTANCE_NAMES; do
        # Get instance details
        INSTANCE_INFO=$(gcloud compute instances describe "$instance" \
            --zone="$ZONE" \
            --format="csv[no-heading](name,status,machineType.scope().segment(-1),creationTimestamp)" 2>/dev/null)
        
        if [ -n "$INSTANCE_INFO" ]; then
            IFS=',' read -r name status type created <<< "$INSTANCE_INFO"
            echo "Instance: $name"
            echo "  Status: $status"
            echo "  Type: $type"
            echo "  Created: ${created:0:10}"
            
            # Calculate cost based on machine type
            case "$type" in
                "e2-micro")
                    daily_cost=$(monthly_to_daily $E2_MICRO_MONTHLY)
                    ;;
                "e2-small")
                    daily_cost=$(monthly_to_daily $E2_SMALL_MONTHLY)
                    ;;
                "e2-medium")
                    daily_cost=$(monthly_to_daily $E2_MEDIUM_MONTHLY)
                    ;;
                *)
                    daily_cost="0.00"
                    echo "  Cost: Unknown machine type"
                    ;;
            esac
            
            if [ "$status" = "RUNNING" ]; then
                echo "  Daily Cost: \$$daily_cost"
                INSTANCE_COST=$(echo "$INSTANCE_COST + $daily_cost" | bc)
            else
                echo "  Daily Cost: \$0.00 (not running)"
            fi
            echo ""
        else
            echo "Warning: Could not fetch details for instance: $instance"
        fi
    done
    
    TOTAL_DAILY_COST=$(echo "$TOTAL_DAILY_COST + $INSTANCE_COST" | bc)
    COST_BREAKDOWN="${COST_BREAKDOWN}Compute: \$$INSTANCE_COST\n"
fi

# 2. STATIC IP ANALYSIS
if [ "$MONITOR_STATIC_IP" = "true" ]; then
    print_color $YELLOW "2. STATIC IP ADDRESSES:"
    echo "----------------------"
    
    STATIC_IPS=$(gcloud compute addresses list --format="csv[no-heading](name,address,status,region.scope().segment(-1))")
    STATIC_IP_COST=0
    
    if [ -n "$STATIC_IPS" ]; then
        while IFS=',' read -r name address status region; do
            echo "IP: $name ($address)"
            echo "  Status: $status"
            echo "  Region: $region"
            
            if [ "$status" = "IN_USE" ]; then
                daily_cost=$(monthly_to_daily $STATIC_IP_MONTHLY)
                echo "  Daily Cost: \$$daily_cost"
                STATIC_IP_COST=$(echo "$STATIC_IP_COST + $daily_cost" | bc)
            else
                # Unused static IPs still cost money!
                daily_cost=$(monthly_to_daily $STATIC_IP_MONTHLY)
                echo "  Daily Cost: \$$daily_cost (WARNING: Not in use!)"
                STATIC_IP_COST=$(echo "$STATIC_IP_COST + $daily_cost" | bc)
            fi
            echo ""
        done <<< "$STATIC_IPS"
    else
        echo "No static IPs found"
        echo ""
    fi
    
    TOTAL_DAILY_COST=$(echo "$TOTAL_DAILY_COST + $STATIC_IP_COST" | bc)
    COST_BREAKDOWN="${COST_BREAKDOWN}Static IPs: \$$STATIC_IP_COST\n"
fi

# 3. DISK ANALYSIS
if [ "$MONITOR_STORAGE" = "true" ]; then
    print_color $YELLOW "3. PERSISTENT DISKS:"
    echo "-------------------"
    
    DISKS=$(gcloud compute disks list --format="csv[no-heading](name,sizeGb,type.scope().segment(-1),zone.scope().segment(-1))")
    DISK_COST=0
    
    if [ -n "$DISKS" ]; then
        while IFS=',' read -r name size type zone; do
            echo "Disk: $name"
            echo "  Size: ${size}GB"
            echo "  Type: $type"
            echo "  Zone: $zone"
            
            if [[ "$type" == *"ssd"* ]]; then
                monthly_cost=$(echo "$size * $SSD_DISK_GB_MONTHLY" | bc)
            else
                monthly_cost=$(echo "$size * $STANDARD_DISK_GB_MONTHLY" | bc)
            fi
            
            daily_cost=$(monthly_to_daily $monthly_cost)
            echo "  Daily Cost: \$$daily_cost"
            DISK_COST=$(echo "$DISK_COST + $daily_cost" | bc)
            echo ""
        done <<< "$DISKS"
    else
        echo "No persistent disks found"
        echo ""
    fi
    
    TOTAL_DAILY_COST=$(echo "$TOTAL_DAILY_COST + $DISK_COST" | bc)
    COST_BREAKDOWN="${COST_BREAKDOWN}Storage: \$$DISK_COST\n"
fi

# 4. NETWORK USAGE ESTIMATE
if [ "$MONITOR_NETWORK" = "true" ]; then
    print_color $YELLOW "4. NETWORK USAGE ESTIMATE:"
    echo "-------------------------"
    echo "Note: This is an estimate. Check billing for exact network costs."
    echo "Network egress: \$$NETWORK_EGRESS_PER_GB/GB after ${NETWORK_FREE_TIER_GB}GB free"
    echo ""
    
    # Add placeholder for network costs
    NETWORK_COST="0.00"
    COST_BREAKDOWN="${COST_BREAKDOWN}Network: ~\$$NETWORK_COST (see billing)\n"
fi

# 5. SUMMARY
print_color $GREEN "5. DAILY COST SUMMARY:"
echo "---------------------"
echo -e "$COST_BREAKDOWN"
print_color $GREEN "TOTAL ESTIMATED DAILY COST: \$$TOTAL_DAILY_COST"
echo ""

# 6. COST OPTIMIZATION TIPS
print_color $YELLOW "6. OPTIMIZATION OPPORTUNITIES:"
echo "-----------------------------"

# Check for unused static IPs
UNUSED_IPS=$(gcloud compute addresses list --filter="status=RESERVED" --format="csv[no-heading](name)" | wc -l)
if [ "$UNUSED_IPS" -gt 0 ]; then
    print_color $RED "⚠️  Found $UNUSED_IPS unused static IP(s) - Release to save \$$(echo "$UNUSED_IPS * $(monthly_to_daily $STATIC_IP_MONTHLY)" | bc)/day"
fi

# Check for stopped instances
STOPPED_INSTANCES=$(gcloud compute instances list --filter="status=TERMINATED" --format="csv[no-heading](name)" | wc -l)
if [ "$STOPPED_INSTANCES" -gt 0 ]; then
    print_color $YELLOW "💡 $STOPPED_INSTANCES instance(s) are stopped but still incur disk costs"
fi

echo ""
echo "✓ Enable instance auto-shutdown for dev/test environments"
echo "✓ Use preemptible instances for batch workloads"
echo "✓ Implement lifecycle policies for storage"
echo "✓ Monitor and optimize network egress"
echo ""

# 7. LINKS AND ACTIONS
print_color $BLUE "7. QUICK ACTIONS:"
echo "----------------"
echo "📊 Detailed billing: https://console.cloud.google.com/billing/projects/$PROJECT_ID"
echo "🖥️  Instance metrics: https://console.cloud.google.com/compute/instances?project=$PROJECT_ID"
echo "💾 Disk management: https://console.cloud.google.com/compute/disks?project=$PROJECT_ID"
echo "🌐 Network details: https://console.cloud.google.com/networking/addresses?project=$PROJECT_ID"
echo ""

# Save results
LOG_FILE="$SCRIPT_DIR/logs/cost-analysis-$(get_date).log"
mkdir -p "$SCRIPT_DIR/logs"

{
    echo "Cost Analysis Report - $(date)"
    echo "=============================="
    echo "Total Daily Cost: \$$TOTAL_DAILY_COST"
    echo ""
    echo "Breakdown:"
    echo -e "$COST_BREAKDOWN"
} > "$LOG_FILE"

echo "======================================="
echo "Report saved to: $LOG_FILE"
echo "======================================="

# Export for other scripts
export TOTAL_DAILY_COST
export COST_BREAKDOWN