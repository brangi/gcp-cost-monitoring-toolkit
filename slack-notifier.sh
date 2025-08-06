#!/bin/bash

# Slack Notifier for GCP Cost Monitoring
# Sends formatted messages to Slack via webhook

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "Error: config.sh not found. Please copy config.example.sh to config.sh and configure it."
    exit 1
fi

# Check if webhook URL is configured
if [ -z "$SLACK_WEBHOOK_URL" ] || [ "$SLACK_WEBHOOK_URL" = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" ]; then
    echo "Error: Slack webhook URL not configured in config.sh"
    echo "Please set SLACK_WEBHOOK_URL with your webhook URL"
    exit 1
fi

# Function to send Slack message
send_slack_message() {
    local message="$1"
    local color="${2:-#36a64f}"  # Default to green
    local title="${3:-GCP Cost Monitor}"
    local icon="${4:-$SLACK_ICON}"
    local username="${5:-$SLACK_USERNAME}"
    
    # Build JSON payload
    local payload=$(cat <<EOF
{
    "username": "$username",
    "icon_emoji": "$icon",
    "channel": "$SLACK_CHANNEL",
    "attachments": [
        {
            "color": "$color",
            "title": "$title",
            "text": "$message",
            "footer": "GCP Cost Monitor",
            "footer_icon": "https://www.gstatic.com/devrel-devsite/prod/v1241c04ebcb2127897d6c18221acbd64e7ed5c46e5217fd83dd808e592c47bf6/cloud/images/favicons/onecloud/super_cloud.png",
            "ts": $(date +%s)
        }
    ]
}
EOF
)
    
    # Send to Slack
    local response=$(curl -s -X POST \
        -H 'Content-type: application/json' \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL")
    
    if [ "$response" = "ok" ]; then
        echo "Message sent successfully to Slack"
        return 0
    else
        echo "Error sending message to Slack: $response"
        return 1
    fi
}

# Function to send rich cost report
send_cost_report() {
    local daily_cost="$1"
    local breakdown="$2"
    local status="${3:-ok}"
    
    # Determine color based on status
    local color="#36a64f"  # Green for OK
    local emoji="✅"
    
    if [ "$status" = "warning" ]; then
        color="#ff9500"  # Orange for warning
        emoji="⚠️"
    elif [ "$status" = "alert" ]; then
        color="#ff0000"  # Red for alert
        emoji="🚨"
    fi
    
    # Format the message
    local message="$emoji *Daily Cost: \$$daily_cost*\n\n"
    message="${message}*Cost Breakdown:*\n$breakdown"
    
    # Build JSON payload with blocks for rich formatting
    local payload=$(cat <<EOF
{
    "username": "$SLACK_USERNAME",
    "icon_emoji": "$SLACK_ICON",
    "channel": "$SLACK_CHANNEL",
    "blocks": [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "💰 GCP Daily Cost Report - $PROJECT_ID",
                "emoji": true
            }
        },
        {
            "type": "divider"
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": "*Date:*\n$(date '+%Y-%m-%d')"
                },
                {
                    "type": "mrkdwn",
                    "text": "*Total Cost:*\n\$$daily_cost"
                }
            ]
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*📊 Breakdown:*\n$breakdown"
            }
        },
        {
            "type": "divider"
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": "View detailed billing: <https://console.cloud.google.com/billing/projects/$PROJECT_ID|GCP Console>"
                }
            ]
        }
    ],
    "attachments": [
        {
            "color": "$color",
            "fields": [
                {
                    "title": "Status",
                    "value": "$emoji ${status^}",
                    "short": true
                },
                {
                    "title": "Threshold",
                    "value": "\$$DAILY_COST_THRESHOLD",
                    "short": true
                }
            ]
        }
    ]
}
EOF
)
    
    # Send to Slack
    local response=$(curl -s -X POST \
        -H 'Content-type: application/json' \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL")
    
    if [ "$response" = "ok" ]; then
        echo "Cost report sent successfully to Slack"
        return 0
    else
        echo "Error sending cost report to Slack: $response"
        return 1
    fi
}

# Function to send alert
send_alert() {
    local alert_type="$1"
    local message="$2"
    local current_value="$3"
    local threshold="$4"
    
    # Build alert message with mentions
    local alert_message="$ALERT_MENTIONS\n\n"
    alert_message="${alert_message}🚨 *GCP COST ALERT* - $PROJECT_ID\n"
    alert_message="${alert_message}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
    alert_message="${alert_message}*Alert Type:* $alert_type\n"
    alert_message="${alert_message}*Message:* $message\n"
    alert_message="${alert_message}*Current Value:* $current_value\n"
    alert_message="${alert_message}*Threshold:* $threshold\n\n"
    alert_message="${alert_message}*Time:* $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
    
    # Send as high priority alert
    send_slack_message "$alert_message" "#ff0000" "⚠️ Cost Alert - Immediate Action Required" ":rotating_light:"
}

# Main execution
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <message> [color] [title]"
    echo ""
    echo "Examples:"
    echo "  $0 \"Test message\""
    echo "  $0 \"Warning message\" \"#ff9500\" \"Warning\""
    echo ""
    echo "Functions available when sourced:"
    echo "  send_slack_message <message> [color] [title] [icon] [username]"
    echo "  send_cost_report <daily_cost> <breakdown> [status]"
    echo "  send_alert <type> <message> <current> <threshold>"
    exit 0
fi

# If called with arguments, send a simple message
if [ "$#" -ge 1 ]; then
    MESSAGE="$1"
    COLOR="${2:-#36a64f}"
    TITLE="${3:-GCP Cost Monitor}"
    
    send_slack_message "$MESSAGE" "$COLOR" "$TITLE"
fi