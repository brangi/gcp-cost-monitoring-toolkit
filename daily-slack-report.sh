#!/bin/bash

# Daily Slack Report for GCP Cost Monitoring
# Sends automated daily cost summaries to Slack

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

# Check if daily reports are enabled
if [ "$ENABLE_DAILY_REPORTS" != "true" ]; then
    echo "Daily reports are disabled in config.sh"
    exit 0
fi

# Log file
LOG_FILE="$SCRIPT_DIR/logs/daily-reports.log"
mkdir -p "$SCRIPT_DIR/logs"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get trend emoji
get_trend_emoji() {
    local current=$1
    local previous=$2
    
    if [ -z "$previous" ] || [ "$previous" = "0" ]; then
        echo "➡️"
        return
    fi
    
    local change=$(echo "scale=2; (($current - $previous) / $previous) * 100" | bc 2>/dev/null || echo "0")
    
    if (( $(echo "$change > 5" | bc -l) )); then
        echo "📈"
    elif (( $(echo "$change < -5" | bc -l) )); then
        echo "📉"
    else
        echo "➡️"
    fi
}

log_message "Starting daily Slack report generation"

# Set the project
gcloud config set project "$PROJECT_ID" 2>/dev/null

# Run cost analysis
log_message "Running comprehensive cost analysis..."
COST_OUTPUT=$("$SCRIPT_DIR/daily-cost-analyzer.sh" 2>&1)

# Extract key metrics
TOTAL_COST=$(echo "$COST_OUTPUT" | grep "TOTAL ESTIMATED DAILY COST:" | grep -o '[0-9]*\.[0-9]*' | tail -1)
COMPUTE_COST=$(echo "$COST_OUTPUT" | grep "Compute:" | grep -o '[0-9]*\.[0-9]*' | head -1)
STORAGE_COST=$(echo "$COST_OUTPUT" | grep "Storage:" | grep -o '[0-9]*\.[0-9]*' | head -1)
STATIC_IP_COST=$(echo "$COST_OUTPUT" | grep "Static IPs:" | grep -o '[0-9]*\.[0-9]*' | head -1)
NETWORK_COST=$(echo "$COST_OUTPUT" | grep "Network:" | grep -o '[0-9]*\.[0-9]*' | head -1)

# Set defaults if not found
TOTAL_COST=${TOTAL_COST:-"0.00"}
COMPUTE_COST=${COMPUTE_COST:-"0.00"}
STORAGE_COST=${STORAGE_COST:-"0.00"}
STATIC_IP_COST=${STATIC_IP_COST:-"0.00"}
NETWORK_COST=${NETWORK_COST:-"0.00"}

# Get previous day's cost for comparison
YESTERDAY_COST="0.00"
if [ -f "$SCRIPT_DIR/logs/last-daily-total.txt" ]; then
    YESTERDAY_COST=$(cat "$SCRIPT_DIR/logs/last-daily-total.txt")
fi

# Calculate change
COST_CHANGE="0"
if [ "$YESTERDAY_COST" != "0.00" ]; then
    COST_CHANGE=$(echo "scale=2; (($TOTAL_COST - $YESTERDAY_COST) / $YESTERDAY_COST) * 100" | bc 2>/dev/null || echo "0")
fi

# Get trend emoji
TREND_EMOJI=$(get_trend_emoji "$TOTAL_COST" "$YESTERDAY_COST")

# Run network analysis
log_message "Analyzing network usage..."
NETWORK_OUTPUT=$("$SCRIPT_DIR/network-usage-monitor.sh" 2>&1)
TOTAL_EGRESS=$(echo "$NETWORK_OUTPUT" | grep "Total egress:" | head -1 | grep -oE '[0-9]+(\.[0-9]+)? [GMK]B' || echo "0 MB")

# Check for issues
ISSUES=""
ISSUE_COUNT=0
STATUS="ok"

# Check if over threshold
if (( $(echo "$TOTAL_COST > $DAILY_COST_THRESHOLD" | bc -l) )); then
    ISSUES="${ISSUES}• ⚠️ Daily cost exceeds threshold (\$$DAILY_COST_THRESHOLD)\n"
    ((ISSUE_COUNT++))
    STATUS="warning"
fi

# Check for unused resources
UNUSED_IPS=$(gcloud compute addresses list --filter="status=RESERVED" --format="csv[no-heading](name)" 2>/dev/null | wc -l)
if [ "$UNUSED_IPS" -gt 0 ]; then
    UNUSED_COST=$(echo "scale=2; $UNUSED_IPS * $(echo "scale=2; $STATIC_IP_MONTHLY / 30" | bc)" | bc)
    ISSUES="${ISSUES}• 💡 $UNUSED_IPS unused static IP(s) - \$$UNUSED_COST/day wasted\n"
    ((ISSUE_COUNT++))
fi

# Check for stopped instances with disks
STOPPED_INSTANCES=$(gcloud compute instances list --filter="status=TERMINATED" --format="csv[no-heading](name)" 2>/dev/null | wc -l)
if [ "$STOPPED_INSTANCES" -gt 0 ]; then
    ISSUES="${ISSUES}• 💾 $STOPPED_INSTANCES stopped instance(s) still incurring disk costs\n"
    ((ISSUE_COUNT++))
fi

# Build the Slack message
log_message "Building Slack message..."

# Create summary section
SUMMARY="📊 *Daily Cost:* \$$TOTAL_COST $TREND_EMOJI"
if [ "$COST_CHANGE" != "0" ]; then
    if (( $(echo "$COST_CHANGE > 0" | bc -l) )); then
        SUMMARY="$SUMMARY (↑ ${COST_CHANGE}%)"
    else
        SUMMARY="$SUMMARY (↓ ${COST_CHANGE#-}%)"
    fi
fi

# Create breakdown
BREAKDOWN="• Compute: \$$COMPUTE_COST\n• Storage: \$$STORAGE_COST\n• Static IPs: \$$STATIC_IP_COST\n• Network: ~\$$NETWORK_COST"

# Create the full message
MESSAGE="*💰 GCP Daily Cost Report*\n*Project:* $PROJECT_ID\n*Date:* $(date '+%Y-%m-%d')\n\n"
MESSAGE="${MESSAGE}$SUMMARY\n\n"
MESSAGE="${MESSAGE}*📈 Breakdown:*\n$BREAKDOWN\n\n"
MESSAGE="${MESSAGE}*🌐 Network:* $TOTAL_EGRESS egress\n"

if [ $ISSUE_COUNT -gt 0 ]; then
    MESSAGE="${MESSAGE}\n*⚠️ Issues Found ($ISSUE_COUNT):*\n$ISSUES"
else
    MESSAGE="${MESSAGE}\n*✅ Status:* All systems optimal"
fi

# Add monthly projection
MONTHLY_PROJECTION=$(echo "scale=2; $TOTAL_COST * 30" | bc)
MESSAGE="${MESSAGE}\n*📅 Monthly projection:* \$$MONTHLY_PROJECTION"

# Build JSON payload with rich formatting
PAYLOAD=$(cat <<EOF
{
    "username": "$SLACK_USERNAME",
    "icon_emoji": "$SLACK_ICON",
    "channel": "$SLACK_CHANNEL",
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "💰 GCP Daily Cost Report",
                "emoji": true
            }
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": "*Project:* $PROJECT_ID | *Date:* $(date '+%Y-%m-%d')"
                }
            ]
        },
        {
            "type": "divider"
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "$SUMMARY"
            },
            "accessory": {
                "type": "button",
                "text": {
                    "type": "plain_text",
                    "text": "View Details",
                    "emoji": true
                },
                "url": "https://console.cloud.google.com/billing/projects/$PROJECT_ID",
                "action_id": "view_details"
            }
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": "*💻 Compute:*\n\$$COMPUTE_COST"
                },
                {
                    "type": "mrkdwn",
                    "text": "*💾 Storage:*\n\$$STORAGE_COST"
                },
                {
                    "type": "mrkdwn",
                    "text": "*🌐 Static IPs:*\n\$$STATIC_IP_COST"
                },
                {
                    "type": "mrkdwn",
                    "text": "*📡 Network:*\n~\$$NETWORK_COST"
                }
            ]
        },
        {
            "type": "divider"
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": "*🌐 Network Egress:*\n$TOTAL_EGRESS"
                },
                {
                    "type": "mrkdwn",
                    "text": "*📅 Monthly Projection:*\n\$$MONTHLY_PROJECTION"
                }
            ]
        }
EOF
)

# Add issues section if any
if [ $ISSUE_COUNT -gt 0 ]; then
    PAYLOAD="${PAYLOAD},
        {
            \"type\": \"divider\"
        },
        {
            \"type\": \"section\",
            \"text\": {
                \"type\": \"mrkdwn\",
                \"text\": \"*⚠️ Issues Found ($ISSUE_COUNT):*\n$ISSUES\"
            }
        }"
fi

# Close the blocks
PAYLOAD="${PAYLOAD}
    ],
    \"attachments\": [
        {
            \"color\": \"$([ "$STATUS" = "ok" ] && echo "#36a64f" || echo "#ff9500")\",
            \"footer\": \"GCP Cost Monitor | <https://console.cloud.google.com/billing/projects/$PROJECT_ID|View in Console>\",
            \"footer_icon\": \"https://www.gstatic.com/devrel-devsite/prod/v1241c04ebcb2127897d6c18221acbd64e7ed5c46e5217fd83dd808e592c47bf6/cloud/images/favicons/onecloud/super_cloud.png\",
            \"ts\": $(date +%s)
        }
    ]
}"

# Send to Slack
log_message "Sending report to Slack..."
RESPONSE=$(curl -s -X POST \
    -H 'Content-type: application/json' \
    -d "$PAYLOAD" \
    "$SLACK_WEBHOOK_URL")

if [ "$RESPONSE" = "ok" ]; then
    log_message "Daily report sent successfully to Slack"
    
    # Save today's cost for tomorrow's comparison
    echo "$TOTAL_COST" > "$SCRIPT_DIR/logs/last-daily-total.txt"
    
    # Archive report
    ARCHIVE_FILE="$SCRIPT_DIR/logs/reports/$(date '+%Y-%m-%d')-report.txt"
    mkdir -p "$SCRIPT_DIR/logs/reports"
    {
        echo "Daily Report - $(date)"
        echo "======================="
        echo "Total Cost: \$$TOTAL_COST"
        echo "Change: ${COST_CHANGE}%"
        echo ""
        echo "Breakdown:"
        echo "- Compute: \$$COMPUTE_COST"
        echo "- Storage: \$$STORAGE_COST"
        echo "- Static IPs: \$$STATIC_IP_COST"
        echo "- Network: \$$NETWORK_COST"
        echo ""
        echo "Issues: $ISSUE_COUNT"
        echo "$ISSUES"
    } > "$ARCHIVE_FILE"
    
    log_message "Report archived to: $ARCHIVE_FILE"
else
    log_message "Error sending report to Slack: $RESPONSE"
    exit 1
fi

log_message "Daily report completed successfully"
log_message "====================================="