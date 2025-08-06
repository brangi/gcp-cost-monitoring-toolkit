#!/bin/bash

# Network Usage Monitor for GCP
# Tracks network traffic and estimates egress costs

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

echo "==================================="
echo "GCP Network Usage Monitor"
echo "==================================="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Set the project
gcloud config set project "$PROJECT_ID" 2>/dev/null

# Function to convert bytes to human readable
bytes_to_human() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt 1048576 ]; then
        echo "$(echo "scale=2; $bytes/1024" | bc)KB"
    elif [ $bytes -lt 1073741824 ]; then
        echo "$(echo "scale=2; $bytes/1048576" | bc)MB"
    else
        echo "$(echo "scale=2; $bytes/1073741824" | bc)GB"
    fi
}

# Function to calculate network cost
calculate_network_cost() {
    local gb=$1
    if (( $(echo "$gb > $NETWORK_FREE_TIER_GB" | bc -l) )); then
        local billable_gb=$(echo "$gb - $NETWORK_FREE_TIER_GB" | bc)
        echo "scale=2; $billable_gb * $NETWORK_EGRESS_PER_GB" | bc
    else
        echo "0.00"
    fi
}

# Track totals
TOTAL_RX_BYTES=0
TOTAL_TX_BYTES=0

for instance in $CHECK_INSTANCE; do
    echo "INSTANCE: $instance"
    echo "-----------------------------------"
    
    # Check if instance is running
    STATUS=$(gcloud compute instances describe "$instance" --zone="$ZONE" \
        --format="value(status)" 2>/dev/null)
    
    if [ -z "$STATUS" ]; then
        echo "Error: Instance '$instance' not found"
        echo ""
        continue
    fi
    
    if [ "$STATUS" != "RUNNING" ]; then
        echo "Status: $STATUS (not running)"
        echo "Network monitoring requires running instance"
        echo ""
        continue
    fi
    
    echo "Status: $STATUS"
    echo ""
    
    # Create network monitoring script
    cat > /tmp/network-monitor.sh << 'SCRIPT'
#!/bin/bash

echo "1. NETWORK INTERFACES:"
echo "---------------------"

# Get primary interface (usually ens4 or eth0)
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Primary Interface: $PRIMARY_IF"
echo ""

# Get detailed statistics
if [ -n "$PRIMARY_IF" ]; then
    # Get interface statistics
    STATS=$(ip -s -j link show $PRIMARY_IF 2>/dev/null)
    
    if [ -n "$STATS" ]; then
        RX_BYTES=$(echo "$STATS" | jq -r '.[0].stats64.rx.bytes // 0')
        TX_BYTES=$(echo "$STATS" | jq -r '.[0].stats64.tx.bytes // 0')
        RX_PACKETS=$(echo "$STATS" | jq -r '.[0].stats64.rx.packets // 0')
        TX_PACKETS=$(echo "$STATS" | jq -r '.[0].stats64.tx.packets // 0')
        
        echo "Traffic Statistics:"
        echo "  RX (Received): $RX_BYTES bytes ($RX_PACKETS packets)"
        echo "  TX (Sent):     $TX_BYTES bytes ($TX_PACKETS packets)"
    else
        # Fallback to basic ip command
        ip -s link show $PRIMARY_IF | grep -A1 "RX:\|TX:"
        # Extract bytes for processing
        RX_BYTES=$(ip -s link show $PRIMARY_IF | grep -A1 "RX:" | tail -1 | awk '{print $1}')
        TX_BYTES=$(ip -s link show $PRIMARY_IF | grep -A1 "TX:" | tail -1 | awk '{print $1}')
    fi
fi

echo ""
echo "2. VNSTAT DATA (if available):"
echo "-----------------------------"

# Check if vnstat is installed and has data
if command -v vnstat &> /dev/null; then
    # Check if database exists
    if vnstat --dbiflist | grep -q "$PRIMARY_IF"; then
        echo "Today's usage:"
        vnstat -i $PRIMARY_IF --oneline | cut -d';' -f4,5,6,7,8,9,10,11
        
        echo ""
        echo "Last 5 days:"
        vnstat -i $PRIMARY_IF -d 5 2>/dev/null || echo "No daily data yet"
        
        echo ""
        echo "This month:"
        vnstat -i $PRIMARY_IF -m 1 2>/dev/null || echo "No monthly data yet"
    else
        echo "vnstat installed but no data collected yet"
        echo "Initializing vnstat for $PRIMARY_IF..."
        sudo vnstat -i $PRIMARY_IF -u
    fi
else
    echo "vnstat not installed. Installing..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y vnstat -qq
        sudo systemctl start vnstat
        echo "vnstat installed. Data collection started."
    else
        echo "Please install vnstat manually for detailed tracking"
    fi
fi

echo ""
echo "3. ACTIVE CONNECTIONS:"
echo "--------------------"

# Count active connections
ESTABLISHED=$(ss -s | grep -i established | awk '{print $2}')
echo "Established connections: ${ESTABLISHED:-0}"

# Show top talkers
echo ""
echo "Top external connections:"
ss -tn state established '( dport != 22 )' | grep -v Local | awk '{print $4}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -5

echo ""
echo "4. BANDWIDTH USAGE (real-time):"
echo "------------------------------"

# Quick bandwidth test using /proc/net/dev
if [ -f /proc/net/dev ]; then
    echo "Sampling 5 seconds..."
    RX1=$(cat /proc/net/dev | grep "$PRIMARY_IF" | awk '{print $2}')
    TX1=$(cat /proc/net/dev | grep "$PRIMARY_IF" | awk '{print $10}')
    sleep 5
    RX2=$(cat /proc/net/dev | grep "$PRIMARY_IF" | awk '{print $2}')
    TX2=$(cat /proc/net/dev | grep "$PRIMARY_IF" | awk '{print $10}')
    
    RX_RATE=$((($RX2 - $RX1) / 5))
    TX_RATE=$((($TX2 - $TX1) / 5))
    
    echo "Current bandwidth:"
    echo "  Download: $((RX_RATE / 1024)) KB/s"
    echo "  Upload: $((TX_RATE / 1024)) KB/s"
fi

# Export values for parent script
echo ""
echo "EXPORT_RX_BYTES=$RX_BYTES"
echo "EXPORT_TX_BYTES=$TX_BYTES"
SCRIPT

    # Execute monitoring script on instance
    echo "Collecting network statistics..."
    NETWORK_OUTPUT=$(gcloud compute ssh "$instance" --zone="$ZONE" \
        --command="bash -s" < /tmp/network-monitor.sh 2>/dev/null)
    
    if [ -n "$NETWORK_OUTPUT" ]; then
        echo "$NETWORK_OUTPUT" | grep -v "^EXPORT_"
        
        # Extract exported values
        INSTANCE_RX=$(echo "$NETWORK_OUTPUT" | grep "^EXPORT_RX_BYTES=" | cut -d= -f2)
        INSTANCE_TX=$(echo "$NETWORK_OUTPUT" | grep "^EXPORT_TX_BYTES=" | cut -d= -f2)
        
        if [ -n "$INSTANCE_RX" ] && [ -n "$INSTANCE_TX" ]; then
            TOTAL_RX_BYTES=$((TOTAL_RX_BYTES + INSTANCE_RX))
            TOTAL_TX_BYTES=$((TOTAL_TX_BYTES + INSTANCE_TX))
            
            echo ""
            echo "5. EGRESS COST ESTIMATE:"
            echo "-----------------------"
            
            # Convert to GB
            TX_GB=$(echo "scale=3; $INSTANCE_TX / 1073741824" | bc)
            echo "Total egress: $(bytes_to_human $INSTANCE_TX) ($TX_GB GB)"
            
            # Calculate cost
            EGRESS_COST=$(calculate_network_cost $TX_GB)
            echo "Estimated total cost: \$$EGRESS_COST"
            
            # Daily estimate (if instance has been running for more than a day)
            UPTIME_DAYS=$(gcloud compute instances describe "$instance" --zone="$ZONE" \
                --format="value(lastStartTimestamp)" | xargs -I {} bash -c 'echo $(( ($(date +%s) - $(date -d "{}" +%s 2>/dev/null || echo 0)) / 86400 ))')
            
            if [ "$UPTIME_DAYS" -gt 0 ]; then
                DAILY_GB=$(echo "scale=3; $TX_GB / $UPTIME_DAYS" | bc)
                DAILY_COST=$(calculate_network_cost $DAILY_GB)
                echo "Daily average: $(echo "scale=2; $DAILY_GB" | bc) GB (\$$DAILY_COST/day)"
            fi
        fi
    else
        echo "Could not connect to instance for network monitoring"
    fi
    
    echo ""
    echo "==================================="
    echo ""
done

# Cleanup
rm -f /tmp/network-monitor.sh

# Summary
if [ $(echo "$CHECK_INSTANCE" | wc -w) -gt 1 ]; then
    echo "TOTAL NETWORK SUMMARY:"
    echo "--------------------"
    echo "Total RX (all instances): $(bytes_to_human $TOTAL_RX_BYTES)"
    echo "Total TX (all instances): $(bytes_to_human $TOTAL_TX_BYTES)"
    
    TOTAL_TX_GB=$(echo "scale=3; $TOTAL_TX_BYTES / 1073741824" | bc)
    TOTAL_COST=$(calculate_network_cost $TOTAL_TX_GB)
    echo "Total egress cost: \$$TOTAL_COST"
    echo ""
fi

# Alerts
if [ -n "$NETWORK_THRESHOLD_GB" ]; then
    TOTAL_TX_GB=$(echo "scale=3; $TOTAL_TX_BYTES / 1073741824" | bc)
    if (( $(echo "$TOTAL_TX_GB > $NETWORK_THRESHOLD_GB" | bc -l) )); then
        echo "⚠️  ALERT: Network egress ($TOTAL_TX_GB GB) exceeds threshold ($NETWORK_THRESHOLD_GB GB)"
        echo ""
    fi
fi

echo "OPTIMIZATION TIPS:"
echo "-----------------"
echo "1. Enable compression (gzip) in your applications"
echo "2. Use Cloud CDN for static content"
echo "3. Keep traffic within the same region when possible"
echo "4. Batch API calls to reduce overhead"
echo "5. Monitor and optimize large data transfers"
echo ""

echo "For detailed network metrics:"
echo "https://console.cloud.google.com/networking/networks/list?project=$PROJECT_ID"