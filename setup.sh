#!/bin/bash

# Setup script for GCP Cost Monitoring Toolkit
# Initializes configuration and dependencies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Function to check command availability
check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

print_color $BLUE "======================================"
print_color $BLUE "GCP Cost Monitoring Toolkit Setup"
print_color $BLUE "======================================"
echo ""

# 1. Check prerequisites
print_color $YELLOW "1. Checking prerequisites..."

# Check for gcloud
if check_command gcloud; then
    print_color $GREEN "✓ gcloud CLI found"
    GCLOUD_VERSION=$(gcloud version | head -1)
    echo "  Version: $GCLOUD_VERSION"
else
    print_color $RED "✗ gcloud CLI not found"
    echo "  Please install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check for jq
if check_command jq; then
    print_color $GREEN "✓ jq found"
else
    print_color $YELLOW "⚠ jq not found (optional but recommended)"
    echo "  Install with: brew install jq (macOS) or apt-get install jq (Linux)"
fi

# Check for bc
if check_command bc; then
    print_color $GREEN "✓ bc found"
else
    print_color $RED "✗ bc not found (required for calculations)"
    echo "  Install with: brew install bc (macOS) or apt-get install bc (Linux)"
    exit 1
fi

# Check for curl
if check_command curl; then
    print_color $GREEN "✓ curl found"
else
    print_color $RED "✗ curl not found (required for Slack integration)"
    exit 1
fi

echo ""

# 2. Check gcloud authentication
print_color $YELLOW "2. Checking GCP authentication..."

if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    print_color $GREEN "✓ Authenticated as: $ACTIVE_ACCOUNT"
else
    print_color $RED "✗ Not authenticated with gcloud"
    echo "  Run: gcloud auth login"
    exit 1
fi

echo ""

# 3. Setup configuration
print_color $YELLOW "3. Setting up configuration..."

if [ -f "$SCRIPT_DIR/config.sh" ]; then
    print_color $GREEN "✓ config.sh already exists"
    read -p "Do you want to reconfigure? (y/N): " RECONFIGURE
    if [[ ! "$RECONFIGURE" =~ ^[Yy]$ ]]; then
        SKIP_CONFIG=true
    fi
fi

if [ ! -f "$SCRIPT_DIR/config.sh" ] || [ "$SKIP_CONFIG" != "true" ]; then
    cp "$SCRIPT_DIR/config.example.sh" "$SCRIPT_DIR/config.sh"
    print_color $GREEN "✓ Created config.sh from template"
    
    # Interactive configuration
    echo ""
    print_color $BLUE "Let's configure your settings:"
    echo ""
    
    # Get current project
    CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
    read -p "GCP Project ID [$CURRENT_PROJECT]: " PROJECT_INPUT
    PROJECT_ID=${PROJECT_INPUT:-$CURRENT_PROJECT}
    
    # Get instance names
    echo ""
    echo "Available instances in $PROJECT_ID:"
    gcloud compute instances list --format="table(name,zone,status)" 2>/dev/null || echo "Could not list instances"
    echo ""
    read -p "Instance name(s) to monitor (space-separated): " INSTANCE_NAMES
    
    # Get zone
    if [ -n "$INSTANCE_NAMES" ]; then
        FIRST_INSTANCE=$(echo $INSTANCE_NAMES | awk '{print $1}')
        DEFAULT_ZONE=$(gcloud compute instances list --filter="name=$FIRST_INSTANCE" --format="value(zone.basename())" 2>/dev/null | head -1)
    fi
    read -p "Default zone [$DEFAULT_ZONE]: " ZONE_INPUT
    ZONE=${ZONE_INPUT:-$DEFAULT_ZONE}
    
    # Slack configuration
    echo ""
    print_color $BLUE "Slack Configuration (optional):"
    read -p "Slack webhook URL: " SLACK_WEBHOOK_URL
    
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        read -p "Slack channel [#gcp-costs]: " SLACK_CHANNEL_INPUT
        SLACK_CHANNEL=${SLACK_CHANNEL_INPUT:-"#gcp-costs"}
    fi
    
    # Cost thresholds
    echo ""
    print_color $BLUE "Cost Thresholds:"
    read -p "Daily cost alert threshold in USD [10.00]: " THRESHOLD_INPUT
    DAILY_COST_THRESHOLD=${THRESHOLD_INPUT:-"10.00"}
    
    # Update config file
    sed -i.bak "s/PROJECT_ID=\"your-project-id\"/PROJECT_ID=\"$PROJECT_ID\"/" "$SCRIPT_DIR/config.sh"
    sed -i.bak "s/INSTANCE_NAMES=\"instance-1 instance-2\"/INSTANCE_NAMES=\"$INSTANCE_NAMES\"/" "$SCRIPT_DIR/config.sh"
    sed -i.bak "s/ZONE=\"us-central1-a\"/ZONE=\"$ZONE\"/" "$SCRIPT_DIR/config.sh"
    
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        sed -i.bak "s|SLACK_WEBHOOK_URL=\"https://hooks.slack.com/services/YOUR/WEBHOOK/URL\"|SLACK_WEBHOOK_URL=\"$SLACK_WEBHOOK_URL\"|" "$SCRIPT_DIR/config.sh"
        sed -i.bak "s/SLACK_CHANNEL=\"#gcp-costs\"/SLACK_CHANNEL=\"$SLACK_CHANNEL\"/" "$SCRIPT_DIR/config.sh"
    fi
    
    sed -i.bak "s/DAILY_COST_THRESHOLD=\"10.00\"/DAILY_COST_THRESHOLD=\"$DAILY_COST_THRESHOLD\"/" "$SCRIPT_DIR/config.sh"
    
    # Remove backup files
    rm -f "$SCRIPT_DIR/config.sh.bak"
    
    print_color $GREEN "✓ Configuration updated"
fi

echo ""

# 4. Create necessary directories
print_color $YELLOW "4. Creating directories..."

mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/logs/reports"
print_color $GREEN "✓ Created log directories"

echo ""

# 5. Make scripts executable
print_color $YELLOW "5. Setting permissions..."

chmod +x "$SCRIPT_DIR"/*.sh
print_color $GREEN "✓ Made all scripts executable"

echo ""

# 6. Test configuration
print_color $YELLOW "6. Testing configuration..."

# Source config
source "$SCRIPT_DIR/config.sh"

# Test gcloud access
if gcloud compute instances list --project="$PROJECT_ID" --limit=1 &>/dev/null; then
    print_color $GREEN "✓ GCP access verified"
else
    print_color $RED "✗ Could not access GCP project: $PROJECT_ID"
    echo "  Check your permissions and project ID"
fi

# Test Slack if configured
if [ -n "$SLACK_WEBHOOK_URL" ] && [ "$SLACK_WEBHOOK_URL" != "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" ]; then
    echo ""
    read -p "Send test message to Slack? (Y/n): " TEST_SLACK
    if [[ ! "$TEST_SLACK" =~ ^[Nn]$ ]]; then
        "$SCRIPT_DIR/slack-notifier.sh" "🎉 GCP Cost Monitor setup completed successfully!" "#36a64f" "Setup Complete"
    fi
fi

echo ""

# 7. Setup cron jobs (optional)
print_color $YELLOW "7. Cron job setup (optional)..."

read -p "Would you like to set up automated monitoring? (y/N): " SETUP_CRON
if [[ "$SETUP_CRON" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Choose your monitoring schedule:"
    echo "1. Daily report at 9 AM"
    echo "2. Hourly cost checks"
    echo "3. Both"
    echo "4. Skip"
    read -p "Your choice (1-4): " CRON_CHOICE
    
    CRON_ENTRIES=""
    
    case $CRON_CHOICE in
        1|3)
            CRON_ENTRIES="${CRON_ENTRIES}0 9 * * * $SCRIPT_DIR/daily-slack-report.sh\n"
            ;;
    esac
    
    case $CRON_CHOICE in
        2|3)
            CRON_ENTRIES="${CRON_ENTRIES}0 * * * * $SCRIPT_DIR/cost-alert-monitor.sh\n"
            ;;
    esac
    
    if [ -n "$CRON_ENTRIES" ]; then
        echo ""
        echo "Add these lines to your crontab (crontab -e):"
        echo ""
        echo -e "$CRON_ENTRIES"
        echo ""
        read -p "Would you like me to add them now? (y/N): " ADD_CRON
        if [[ "$ADD_CRON" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null; echo -e "$CRON_ENTRIES") | crontab -
            print_color $GREEN "✓ Cron jobs added"
        fi
    fi
fi

echo ""

# 8. Final summary
print_color $GREEN "======================================"
print_color $GREEN "✅ Setup Complete!"
print_color $GREEN "======================================"
echo ""
echo "Next steps:"
echo "1. Review and adjust settings in config.sh"
echo "2. Run ./daily-cost-analyzer.sh for your first analysis"
echo "3. Test Slack integration with ./slack-notifier.sh"
echo "4. Set up cron jobs for automation (if not done)"
echo ""
echo "For help, see README.md"
echo ""

# Create a quick start script
cat > "$SCRIPT_DIR/quick-check.sh" << 'EOF'
#!/bin/bash
# Quick cost check script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running quick cost check..."
echo ""

# Run daily analyzer
"$SCRIPT_DIR/daily-cost-analyzer.sh" | grep -E "TOTAL ESTIMATED DAILY COST:|WARNING:|Error:" | sed 's/^/  /'

echo ""
echo "For detailed analysis, run: ./daily-cost-analyzer.sh"
echo "For network details, run: ./network-usage-monitor.sh"
EOF

chmod +x "$SCRIPT_DIR/quick-check.sh"
print_color $BLUE "Created quick-check.sh for fast cost checks"

echo ""
print_color $GREEN "Happy monitoring! 💰"