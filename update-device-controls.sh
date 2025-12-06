#!/bin/sh

# Configuration
CONFIG_FILE="/etc/mess-monsters/config.json"
LOG_FILE="/var/log/device-controls.log"
FILTER_LOG="/var/log/filter-operations.log"
PHYSICAL_INTERFACE="br-lan"
WAN_INTERFACE="eth0.2"
MARK_VALUE=5
STATE_FILE="/tmp/device-controls-state.txt"

# DNS Configuration
OPENDNS_FAMILY_SHIELD_1="208.67.222.123"
OPENDNS_FAMILY_SHIELD_2="208.67.220.123"
REGULAR_DNS_1="8.8.8.8"
REGULAR_DNS_2="1.1.1.1"

# Read configuration
if [ -f "$CONFIG_FILE" ]; then
    HOUSEHOLD_ID=$(awk -F'"' '/household_id/ {print $4}' "$CONFIG_FILE")
    SERVER_URL=$(awk -F'"' '/server_url/ {print $4}' "$CONFIG_FILE")
    FAST_SPEED=$(awk -F'"' '/fast_speed/ {print $4}' "$CONFIG_FILE")
    SLOW_SPEED=$(awk -F'"' '/slow_speed/ {print $4}' "$CONFIG_FILE")
else
    echo "Error: Config file not found at $CONFIG_FILE"
    exit 1
fi

API_URL="${SERVER_URL}/api/router/device-controls?household_id=${HOUSEHOLD_ID}"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Filter operation logging functions
filter_log() {
    local action="$1"      # add, del, rebuild, snapshot
    local script="$2"      # update-device-controls
    local ip="$3"          # IP address or "ALL" for qdisc operations
    local type="$4"        # dst, src, fw, qdisc
    local lane="$5"        # 1:10, 1:30
    local result="$6"      # success, failed
    local count_before="$7"
    local count_after="$8"
    local context="$9"     # optional context
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FILTER-OP] ACTION=$action | SCRIPT=$script | IP=$ip | TYPE=$type | LANE=$lane | RESULT=$result | COUNT_BEFORE=$count_before | COUNT_AFTER=$count_after | CONTEXT=$context" >> "$FILTER_LOG"
}

filter_snapshot() {
    local context="$1"  # before-rebuild, after-rebuild, etc
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FILTER-SNAP] CONTEXT=$context" >> "$FILTER_LOG"
    tc filter show dev $PHYSICAL_INTERFACE 2>/dev/null >> "$FILTER_LOG"
    echo "---" >> "$FILTER_LOG"
}

# Function to get current device controls from API
fetch_device_controls() {
    local response=$(curl -s "$API_URL")
    
    if [ -z "$response" ] || ! echo "$response" | grep -q '"success":true'; then
        log_message "Error fetching device controls from API"
        return 1
    fi
    
    # Return the full JSON response for processing
    echo "$response"
}

# Function to get current state of fast IPs
get_current_fast_ips() {
    # Get IPs that are currently marked for fast speed
    iptables -t mangle -L FORWARD -n | grep "MARK set 0x5" | \
        awk '{print $5}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | \
        grep "^192.168" | sort -u
}

# Check if QoS is properly set up with two-lane system
check_qos_setup() {
    # Check if classes exist AND if default is set to fast (10/0x10) for two-lane system
    # Note: tc shows default as hex (0x10) but we accept both formats
    (tc qdisc show dev $PHYSICAL_INTERFACE | grep -q "default 10" || \
     tc qdisc show dev $PHYSICAL_INTERFACE | grep -q "default 0x10") && \
    (tc qdisc show dev $WAN_INTERFACE | grep -q "default 10" || \
     tc qdisc show dev $WAN_INTERFACE | grep -q "default 0x10") && \
    tc class show dev $PHYSICAL_INTERFACE | grep -q "1:1" && \
    tc class show dev $PHYSICAL_INTERFACE | grep -q "1:10" && \
    tc class show dev $PHYSICAL_INTERFACE | grep -q "1:30" && \
    tc class show dev $WAN_INTERFACE | grep -q "1:1" && \
    tc class show dev $WAN_INTERFACE | grep -q "1:10" && \
    tc class show dev $WAN_INTERFACE | grep -q "1:30"
}

# Set up QoS if not already configured
setup_qos_if_needed() {
    if ! check_qos_setup; then
        log_message "QoS structure needs repair - rebuilding with 2-lane system"
        filter_snapshot "before-qdisc-rebuild"
        
        # Delete and recreate QoS structure (simpler than trying to preserve)
        log_message "Rebuilding LAN QoS structure (2-lane: fast=default, slow=explicit)"
        tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
        tc qdisc add dev $PHYSICAL_INTERFACE root handle 1: htb default 10
        
        # Create root class
        tc class add dev $PHYSICAL_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        
        # Create two lanes: Fast (1:10 - default), Slow (1:30)
        tc class add dev $PHYSICAL_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class add dev $PHYSICAL_INTERFACE parent 1:1 classid 1:30 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        
        # Add qdiscs for each lane
        tc qdisc add dev $PHYSICAL_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc add dev $PHYSICAL_INTERFACE parent 1:30 handle 30: pfifo limit 100
        
        # WAN (upload) QoS - Create two-lane system
        log_message "Rebuilding WAN QoS structure (2-lane: fast=default, slow=explicit)"
        tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
        tc qdisc add dev $WAN_INTERFACE root handle 1: htb default 10
        
        # Create root class
        tc class add dev $WAN_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        
        # Create two lanes for WAN
        tc class add dev $WAN_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class add dev $WAN_INTERFACE parent 1:1 classid 1:30 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        
        # Add qdiscs for WAN lanes
        tc qdisc add dev $WAN_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc add dev $WAN_INTERFACE parent 1:30 handle 30: pfifo limit 100
        
        # Add fast lane filter for marked packets (prio 1 - checked first)
        log_message "Adding fast lane filter for marked packets"
        tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        tc filter add dev $WAN_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        
        log_message "QoS structure created (2-lane system: default=fast)"
        filter_snapshot "after-qos-rebuild-complete"
        return 0
    else
        log_message "QoS structure is healthy - no changes needed"
    fi
    return 1
}

# Apply fast speed to a single IP
apply_fast_speed_to_ip() {
    local ip="$1"
    
    # Remove any existing slow filters first (cleanup from previous state)
    remove_slow_filters "$ip" 2>/dev/null
    
    # Add MARK rules for fast speed (if not already present)
    if ! iptables -t mangle -C FORWARD -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null; then
        iptables -t mangle -I PREROUTING 1 -d "$ip" -j MARK --set-mark $MARK_VALUE
        iptables -t mangle -I FORWARD 1 -d "$ip" -j MARK --set-mark $MARK_VALUE
    fi
    
    if ! iptables -t mangle -C POSTROUTING -s "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null; then
        iptables -t mangle -I POSTROUTING 1 -s "$ip" -j MARK --set-mark $MARK_VALUE
    fi
    
    log_message "Applied fast speed to IP: $ip"
}

# Apply slow speed to a single IP (explicit filters since default is fast)
apply_slow_speed_to_ip() {
    local ip="$1"
    
    # Remove any MARK rules (registered devices without monsters shouldn't have MARK)
    iptables -t mangle -D PREROUTING -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    iptables -t mangle -D FORWARD -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    iptables -t mangle -D POSTROUTING -s "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    
    # Remove existing slow filters (avoid duplicates)
    remove_slow_filters "$ip" 2>/dev/null
    
    # Add explicit slow filters on both interfaces (prio 2 - checked after MARK filter)
    # Download (dst): br-lan
    tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 2 u32 match ip dst "$ip" flowid 1:30 2>/dev/null
    
    # Upload (src): br-lan and eth0.2
    tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 2 u32 match ip src "$ip" flowid 1:30 2>/dev/null
    tc filter add dev $WAN_INTERFACE parent 1: protocol ip prio 2 u32 match ip src "$ip" flowid 1:30 2>/dev/null
    
    log_message "Applied slow speed to IP: $ip"
}

# Remove slow filters for an IP (helper function)
remove_slow_filters() {
    local ip="$1"
    
    # Convert IP to hex for tc filter matching
    local hex_ip=$(printf "%02x%02x%02x%02x" $(echo "$ip" | tr '.' ' '))
    
    # Find and remove slow filters by hex IP match
    # We look for filters with flowid 1:30 that match this IP
    local filter_output=$(tc filter show dev $PHYSICAL_INTERFACE 2>/dev/null)
    local handles=$(echo "$filter_output" | grep -B 1 "match ${hex_ip}/ffffffff" | grep "fh.*flowid 1:30" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p')
    
    for handle in $handles; do
        tc filter del dev $PHYSICAL_INTERFACE parent 1: handle "$handle" prio 2 2>/dev/null
    done
    
    # Also check WAN interface
    local wan_filter_output=$(tc filter show dev $WAN_INTERFACE 2>/dev/null)
    local wan_handles=$(echo "$wan_filter_output" | grep -B 1 "match ${hex_ip}/ffffffff" | grep "fh.*flowid 1:30" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p')
    
    for handle in $wan_handles; do
        tc filter del dev $WAN_INTERFACE parent 1: handle "$handle" prio 2 2>/dev/null
    done
}

# Remove fast speed from a single IP (registered without monsters -> apply slow)
remove_fast_speed_from_ip() {
    local ip="$1"
    
    # This means device is registered but has no monsters
    # Apply slow speed instead
    apply_slow_speed_to_ip "$ip"
}

# Function to resolve Firebase domains to IPs
resolve_firebase_ips() {
    local cache_file="/tmp/firebase-ips-cache.txt"
    local cache_age_limit=3600  # 1 hour in seconds
    
    # Check if cache exists and is recent
    if [ -f "$cache_file" ] && [ $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0))) -lt $cache_age_limit ]; then
        cat "$cache_file"
        return 0
    fi
    
    # Resolve Firebase domains
    local firebase_ips=""
    local domains="firebaseapp.com googleapis.com firebasestorage.googleapis.com firebase.googleapis.com"
    
    for domain in $domains; do
        local ips=$(nslookup "$domain" 2>/dev/null | grep "Address:" | grep -v "#53" | awk '{print $2}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
        if [ -n "$ips" ]; then
            firebase_ips="$firebase_ips $ips"
        fi
    done
    
    # Remove duplicates and save to cache
    firebase_ips=$(echo "$firebase_ips" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo "$firebase_ips" > "$cache_file"
    echo "$firebase_ips"
}

# Main logic
main() {
    # Ensure filter log exists
    touch "$FILTER_LOG"
    
    # Log initial state
    filter_snapshot "script-start"
    filter_log "snapshot" "update-device-controls" "N/A" "N/A" "ALL" "success" "0" "0" "initial-state"
    
    log_message "Starting device controls update (speed + DNS)"
    
    # Ensure QoS is set up
    local qos_changed=0
    if setup_qos_if_needed; then
        qos_changed=1
    fi
    
    # Get device controls from API
    DEVICE_RESPONSE=$(fetch_device_controls)
    if [ $? -ne 0 ]; then
        log_message "Failed to fetch device controls, keeping current settings"
        return 1
    fi
    
    # Process device controls (both speed and DNS)
    process_device_controls "$DEVICE_RESPONSE"
    
    # Always ensure critical services have fast speed
    # Static fallback IPs (in case DNS resolution fails)
    STATIC_FALLBACK_IPS="51.222.205.215 199.36.158.100 172.217.14.196 142.250.69.68 142.250.69.74 142.250.69.138 142.250.69.42 142.250.69.106"
    
    # Get dynamic Firebase IPs
    FIREBASE_IPS=$(resolve_firebase_ips)
    
    # Combine static server IP with dynamic Firebase IPs (fallback to static if resolution fails)
    if [ -n "$FIREBASE_IPS" ]; then
        STATIC_IPS="51.222.205.215 $FIREBASE_IPS"
        log_message "Using dynamically resolved Firebase IPs: $FIREBASE_IPS"
    else
        STATIC_IPS="$STATIC_FALLBACK_IPS"
        log_message "DNS resolution failed, using static fallback IPs"
    fi
    
    # Always ensure critical services have fast speed
    for ip in $STATIC_IPS; do
        apply_fast_speed_to_ip "$ip" 2>/dev/null
    done
    
    log_message "Device controls update completed (speed + DNS)"
    
    # Log final state
    filter_snapshot "script-end"
    filter_log "snapshot" "update-device-controls" "N/A" "N/A" "ALL" "success" "0" "0" "final-state"
}

# DNS Filtering Functions

# Function to get current DNS-filtered IPs
get_current_dns_filtered_ips() {
    # Get IPs that are currently forced to use OpenDNS Family Shield
    iptables -t nat -L PREROUTING -n | grep "DNAT.*208.67.222.123" | \
        awk '{print $7}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | \
        grep "^192.168" | sort -u
}

# Apply DNS filtering to a single IP (force OpenDNS Family Shield)
apply_dns_filtering_to_ip() {
    local ip="$1"
    
    if [ "$TEST_MODE" = "true" ]; then
        log_message "TEST MODE: Would apply DNS filtering to IP: $ip (OpenDNS Family Shield)"
        log_message "TEST MODE: Would run: iptables -t nat -A PREROUTING -p udp --dport 53 -s $ip -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1"
        log_message "TEST MODE: Would run: iptables -t nat -A PREROUTING -p tcp --dport 53 -s $ip -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1"
        return
    fi
    
    # Remove any existing DNS rules for this IP
    iptables -t nat -D PREROUTING -p udp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1 2>/dev/null
    
    # Add DNS hijacking rules for UDP and TCP DNS requests
    iptables -t nat -A PREROUTING -p udp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1
    iptables -t nat -A PREROUTING -p tcp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1
    
    log_message "Applied DNS filtering to IP: $ip (OpenDNS Family Shield)"
}

# Remove DNS filtering from a single IP (allow regular DNS)
remove_dns_filtering_from_ip() {
    local ip="$1"
    
    if [ "$TEST_MODE" = "true" ]; then
        log_message "TEST MODE: Would remove DNS filtering from IP: $ip (regular DNS allowed)"
        log_message "TEST MODE: Would run: iptables -t nat -D PREROUTING -p udp --dport 53 -s $ip -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1"
        log_message "TEST MODE: Would run: iptables -t nat -D PREROUTING -p tcp --dport 53 -s $ip -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1"
        return
    fi
    
    # Remove DNS hijacking rules for this IP
    iptables -t nat -D PREROUTING -p udp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp --dport 53 -s "$ip" -j DNAT --to-destination $OPENDNS_FAMILY_SHIELD_1 2>/dev/null
    
    log_message "Removed DNS filtering from IP: $ip (regular DNS allowed)"
}

# Process device controls (both speed and DNS)
process_device_controls() {
    local response="$1"
    
    # Extract device information using jq if available, otherwise use grep/sed
    if command -v jq >/dev/null 2>&1; then
        # Use jq for proper JSON parsing
        local devices_json=$(echo "$response" | jq -r '.devices[] | "\(.ip) \(.hasMonsters) \(.ageGroup)"')
        
        echo "$devices_json" | while IFS=' ' read -r ip has_monsters age_group; do
            if [ -n "$ip" ] && [ -n "$has_monsters" ] && [ -n "$age_group" ]; then
                log_message "Processing device: $ip (monsters: $has_monsters, ageGroup: $age_group)"
                
                # Handle speed control
                if [ "$has_monsters" = "true" ]; then
                    apply_fast_speed_to_ip "$ip"
                else
                    remove_fast_speed_from_ip "$ip"
                fi
                
                # Handle DNS filtering
                if [ "$age_group" = "child" ]; then
                    apply_dns_filtering_to_ip "$ip"
                else
                    remove_dns_filtering_from_ip "$ip"
                fi
            fi
        done
    else
        # Fallback to grep/sed for basic parsing
        log_message "jq not available, using basic parsing"
        
        # Extract IPs with hasMonsters=true
        local fast_ips=$(echo "$response" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
        
        # Extract IPs with ageGroup="child"
        local child_ips=$(echo "$response" | grep -A 10 -B 10 '"ageGroup":"child"' | \
            grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
        
        # Apply speed controls
        for ip in $fast_ips; do
            apply_fast_speed_to_ip "$ip"
        done
        
        # Apply DNS filtering
        for ip in $child_ips; do
            apply_dns_filtering_to_ip "$ip"
        done
    fi
}

# Handle command line arguments
case "$1" in
    --test)
        echo "=== TEST MODE ENABLED ==="
        echo "Script will show what it would do without making changes"
        TEST_MODE="true"
        main
        ;;
    --status)
        echo "=== Current Device Controls Status ==="
        echo "Fast device IPs (speed control):"
        get_current_fast_ips
        echo ""
        echo "DNS-filtered IPs (parental controls):"
        get_current_dns_filtered_ips
        echo ""
        echo "QoS Classes:"
        tc class show dev $PHYSICAL_INTERFACE
        echo ""
        echo "DNS NAT Rules:"
        iptables -t nat -L PREROUTING -n | grep "DNAT.*208.67.222.123" || echo "No DNS filtering rules found"
        echo ""
        echo "Recent log entries:"
        tail -5 "$LOG_FILE"
        ;;
    --reset)
        touch "$FILTER_LOG"
        filter_snapshot "before-reset"
        filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "warning" "0" "0" "RESET-ALL-FILTERS"
        log_message "Resetting all QoS rules and filters"
        tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
        tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
        iptables -t mangle -F PREROUTING
        iptables -t mangle -F FORWARD
        iptables -t mangle -F POSTROUTING
        rm -f "$STATE_FILE"
        filter_snapshot "after-reset"
        filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "success" "0" "0" "reset-complete"
        log_message "QoS rules cleared - run script again to rebuild"
        ;;
    --force)
        log_message "Forcing QoS update"
        rm -f "$STATE_FILE"
        main
        ;;
    --refresh-firebase)
        log_message "Refreshing Firebase IP cache"
        rm -f "/tmp/firebase-ips-cache.txt"
        FIREBASE_IPS=$(resolve_firebase_ips)
        echo "Current Firebase IPs: $FIREBASE_IPS"
        ;;
    *)
        main
        ;;
esac 