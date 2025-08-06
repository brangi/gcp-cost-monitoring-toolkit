#!/bin/bash

# Cost Alert Monitor for GCP
# Monitors costs and sends alerts when thresholds are exceeded

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "Error: config.sh not found. Please copy config.example.sh to config.sh and configure it."
    exit 1
fi

# Source Slack notifier functions
source "$SCRIPT_DIR/slack-notifier.sh"

# Log file for tracking
LOG_FILE="$SCRIPT_DIR/logs/cost-alerts.log"
mkdir -p "$SCRIPT_DIR/logs"

# State file to track last alert
STATE_FILE="$SCRIPT_DIR/logs/.alert-state"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get last alert time for a specific alert type
get_last_alert_time() {
    local alert_type="$1"
    if [ -f "$STATE_FILE" ]; then
        grep "^$alert_type:" "$STATE_FILE" | cut -d: -f2 || echo "0"
    else
        echo "0"
    fi
}

# Function to update last alert time
update_alert_time() {
    local alert_type="$1"
    local timestamp=$(date +%s)
    
    # Create or update state file
    if [ -f "$STATE_FILE" ]; then
        grep -v "^$alert_type:" "$STATE_FILE" > "$STATE_FILE.tmp" || true
        mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi
    echo "$alert_type:$timestamp" >> "$STATE_FILE"
}

# Function to check if we should send alert (rate limiting)
should_send_alert() {
    local alert_type="$1"
    local last_alert=$(get_last_alert_time "$alert_type")
    local current_time=$(date +%s)
    local time_diff=$((current_time - last_alert))
    
    # Only send alert if more than 4 hours have passed
    if [ $time_diff -gt 14400 ]; then
        return 0
    else
        return 1
    fi
}

log_message "Starting cost alert monitoring for project: $PROJECT_ID"

# Set the project
gcloud config set project "$PROJECT_ID" 2>/dev/null

# Run daily cost analyzer and capture output
log_message "Running cost analysis..."
COST_OUTPUT=$("$SCRIPT_DIR/daily-cost-analyzer.sh" 2>&1)

# Extract total daily cost
TOTAL_COST=$(echo "$COST_OUTPUT" | grep "TOTAL ESTIMATED DAILY COST:" | grep -o '[0-9]*\.[0-9]*' | tail -1)

if [ -z "$TOTAL_COST" ]; then
    log_message "Error: Could not determine total cost"
    exit 1
fi

log_message "Current daily cost: \$$TOTAL_COST"

# Check against threshold
THRESHOLD_EXCEEDED=false
if (( $(echo "$TOTAL_COST > $DAILY_COST_THRESHOLD" | bc -l) )); then
    THRESHOLD_EXCEEDED=true
    log_message "WARNING: Daily cost threshold exceeded!"
fi

# Check for cost increase
if [ -f "$SCRIPT_DIR/logs/last-cost.txt" ]; then
    LAST_COST=$(cat "$SCRIPT_DIR/logs/last-cost.txt")
    INCREASE=$(echo "scale=2; (($TOTAL_COST - $LAST_COST) / $LAST_COST) * 100" | bc 2>/dev/null || echo "0")
    
    if (( $(echo "$INCREASE > $COST_INCREASE_PERCENT" | bc -l) )); then
        log_message "WARNING: Cost increased by ${INCREASE}% since last check"
        
        if should_send_alert "cost_increase"; then
            send_alert "Cost Increase" \
                "Daily costs increased by ${INCREASE}% since last check" \
                "\$$TOTAL_COST" \
                "\$$LAST_COST (previous)"
            update_alert_time "cost_increase"
        fi
    fi
fi

# Save current cost for next comparison
echo "$TOTAL_COST" > "$SCRIPT_DIR/logs/last-cost.txt"

# Check network usage if enabled
if [ "$MONITOR_NETWORK" = "true" ]; then
    log_message "Checking network usage..."
    
    # Run network monitor and extract total egress
    NETWORK_OUTPUT=$("$SCRIPT_DIR/network-usage-monitor.sh" 2>&1)
    TOTAL_EGRESS_GB=$(echo "$NETWORK_OUTPUT" | grep "Total egress:" | grep -oE '[0-9]+\.[0-9]+ GB' | awk '{print $1}')
    
    if [ -n "$TOTAL_EGRESS_GB" ] && [ -n "$NETWORK_THRESHOLD_GB" ]; then
        if (( $(echo "$TOTAL_EGRESS_GB > $NETWORK_THRESHOLD_GB" | bc -l) )); then
            log_message "WARNING: Network egress threshold exceeded!"
            
            if should_send_alert "network_threshold"; then
                send_alert "Network Threshold" \
                    "Network egress exceeded configured threshold" \
                    "${TOTAL_EGRESS_GB}GB" \
                    "${NETWORK_THRESHOLD_GB}GB"
                update_alert_time "network_threshold"
            fi
        fi
    fi
fi

# Send main cost alert if threshold exceeded
if [ "$THRESHOLD_EXCEEDED" = true ]; then
    if should_send_alert "cost_threshold"; then
        # Get cost breakdown
        BREAKDOWN=$(echo "$COST_OUTPUT" | grep -A10 "DAILY COST SUMMARY:" | grep -E "Compute:|Storage:|Static IPs:|Network:" | sed 's/^/• /')
        
        send_alert "Daily Cost Threshold" \
            "Daily costs have exceeded your configured threshold" \
            "\$$TOTAL_COST" \
            "\$$DAILY_COST_THRESHOLD"
        
        # Also send detailed breakdown
        send_cost_report "$TOTAL_COST" "$BREAKDOWN" "alert"
        update_alert_time "cost_threshold"
    else
        log_message "Alert already sent recently, skipping to avoid spam"
    fi
fi

# Check for specific resource anomalies
log_message "Checking for resource anomalies..."

# Check for unused static IPs
UNUSED_IPS=$(gcloud compute addresses list --filter="status=RESERVED" --format="csv[no-heading](name)" | wc -l)
if [ "$UNUSED_IPS" -gt 0 ]; then
    log_message "Found $UNUSED_IPS unused static IP(s)"
    
    if should_send_alert "unused_resources"; then
        UNUSED_COST=$(echo "scale=2; $UNUSED_IPS * $(echo "scale=2; $STATIC_IP_MONTHLY / 30" | bc)" | bc)
        send_alert "Unused Resources" \
            "Found $UNUSED_IPS unused static IP(s) costing \$$UNUSED_COST/day" \
            "$UNUSED_IPS IPs" \
            "0 unused IPs"
        update_alert_time "unused_resources"
    fi
fi

# Summary log
log_message "Alert monitoring completed"
log_message "====================================="

# If everything is OK and we should send OK status
if [ "$THRESHOLD_EXCEEDED" = false ] && [ "$SEND_OK_STATUS" = "true" ]; then
    # Only send OK status once per day
    if should_send_alert "daily_ok_status"; then
        BREAKDOWN=$(echo "$COST_OUTPUT" | grep -A10 "DAILY COST SUMMARY:" | grep -E "Compute:|Storage:|Static IPs:|Network:" | sed 's/^/• /')
        send_cost_report "$TOTAL_COST" "$BREAKDOWN" "ok"
        update_alert_time "daily_ok_status"
    fi
fi

# Exit with appropriate code
if [ "$THRESHOLD_EXCEEDED" = true ]; then
    exit 1
else
    exit 0
fi