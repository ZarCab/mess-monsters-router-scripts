#!/bin/sh

# Configuration
CONFIG_FILE="/etc/mess-monsters/config.json"
LOG_FILE="/var/log/device-controls.log"
FILTER_LOG="/var/log/filter-operations.log"
PHYSICAL_INTERFACE="br-lan"
WAN_INTERFACE="eth1"
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
    local action="$1"      # add, del, rebuild, save, restore, snapshot
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
    tc filter show dev $PHYSICAL_INTERFACE 2>/dev/null | grep -A 1 "flowid 1:10\|flowid 1:30" >> "$FILTER_LOG" || echo "No filters found" >> "$FILTER_LOG"
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
    ! tc class show dev $PHYSICAL_INTERFACE | grep -q "1:20" && \
    tc class show dev $WAN_INTERFACE | grep -q "1:1"
}

# Set up QoS if not already configured
setup_qos_if_needed() {
    if ! check_qos_setup; then
        log_message "QoS structure needs repair - implementing 2-lane system"
        
        # LAN (download) QoS - Create two-lane system
        # Only delete if absolutely necessary (preserve existing rules when possible)
        if ! tc qdisc show dev $PHYSICAL_INTERFACE | grep -q "htb.*default" | grep -E "(10|0x10)"; then
            filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "warning" "0" "0" "DELETING-ALL-FILTERS-LAN"
            log_message "Rebuilding LAN QoS structure (default routing issue detected)"
            log_message "WARNING: This will delete ALL existing filters!"
            tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
            filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "success" "0" "0" "qdisc-deleted-lan"
            tc qdisc add dev $PHYSICAL_INTERFACE root handle 1: htb default 10
        else
            log_message "LAN default routing is correct - preserving existing structure"
        fi
        
        # Ensure root class exists
        if ! tc class show dev $PHYSICAL_INTERFACE | grep -q "1:1 root"; then
            tc class add dev $PHYSICAL_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        fi
        
        # Create two lanes: Fast (1:10), Slow (1:30)
        tc class replace dev $PHYSICAL_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class replace dev $PHYSICAL_INTERFACE parent 1:1 classid 1:30 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        
        # Add qdiscs for each lane
        tc qdisc replace dev $PHYSICAL_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc replace dev $PHYSICAL_INTERFACE parent 1:30 handle 30: pfifo limit 100
        
        # WAN (upload) QoS - Create two-lane system
        if ! tc qdisc show dev $WAN_INTERFACE | grep -q "htb.*default" | grep -E "(10|0x10)"; then
            filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "warning" "0" "0" "DELETING-ALL-FILTERS-WAN"
            log_message "Rebuilding WAN QoS structure (default routing issue detected)"
            log_message "WARNING: This will delete ALL existing filters!"
            tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
            filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "success" "0" "0" "qdisc-deleted-wan"
            tc qdisc add dev $WAN_INTERFACE root handle 1: htb default 10
        else
            log_message "WAN default routing is correct - preserving existing structure"
        fi
        
        # Ensure root class exists
        if ! tc class show dev $WAN_INTERFACE | grep -q "1:1 root"; then
            tc class add dev $WAN_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        fi
        
        # Create two lanes for WAN
        tc class replace dev $WAN_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class replace dev $WAN_INTERFACE parent 1:1 classid 1:30 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        
        # Add qdiscs for WAN lanes
        tc qdisc replace dev $WAN_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc replace dev $WAN_INTERFACE parent 1:30 handle 30: pfifo limit 100
        
        # Add base filters for fast lane (MARK 0x5)
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:10" "attempt" "0" "0" "adding-fast-lane-filter-lan"
        tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        local add_result=$?
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:10" "$([ $add_result -eq 0 ] && echo "success" || echo "failed")" "0" "0" "fast-lane-filter-lan-added"
        
        # Add filter for WAN (upload) fast lane marked packets
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:10" "attempt" "0" "0" "adding-fast-lane-filter-wan"
        tc filter add dev $WAN_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        local add_result2=$?
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:10" "$([ $add_result2 -eq 0 ] && echo "success" || echo "failed")" "0" "0" "fast-lane-filter-wan-added"
        
        # Add base filters for slow lane (MARK 0x6)
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:30" "attempt" "0" "0" "adding-slow-lane-filter-lan"
        tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 1 handle 6 fw flowid 1:30
        local add_result3=$?
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:30" "$([ $add_result3 -eq 0 ] && echo "success" || echo "failed")" "0" "0" "slow-lane-filter-lan-added"
        
        # Add filter for WAN (upload) slow lane marked packets
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:30" "attempt" "0" "0" "adding-slow-lane-filter-wan"
        tc filter add dev $WAN_INTERFACE parent 1: protocol ip prio 1 handle 6 fw flowid 1:30
        local add_result4=$?
        filter_log "add" "update-device-controls" "MARKED" "fw" "1:30" "$([ $add_result4 -eq 0 ] && echo "success" || echo "failed")" "0" "0" "slow-lane-filter-wan-added"
        
        log_message "QoS structure created/repaired with 2-lane system (fast default)"
        return 0
    else
        log_message "QoS structure is healthy - no changes needed"
    fi
    return 1
}

# Apply fast speed to a single IP
apply_fast_speed_to_ip() {
    local ip="$1"
    
    # Check and add download rules if missing
    if ! iptables -t mangle -C FORWARD -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null; then
        iptables -t mangle -I PREROUTING 1 -d "$ip" -j MARK --set-mark $MARK_VALUE
        iptables -t mangle -I FORWARD 1 -d "$ip" -j MARK --set-mark $MARK_VALUE
    fi
    
    # Check and add upload rules if missing
    if ! iptables -t mangle -C POSTROUTING -s "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null; then
        iptables -t mangle -I POSTROUTING 1 -s "$ip" -j MARK --set-mark $MARK_VALUE
    fi
    
    log_message "Added fast speed for IP: $ip"
}

# Remove fast speed from a single IP
remove_fast_speed_from_ip() {
    local ip="$1"
    
    # Remove marking rules for DOWNLOAD (to this IP)
    iptables -t mangle -D PREROUTING -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    iptables -t mangle -D FORWARD -d "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    
    # Remove marking rules for UPLOAD (from this IP)
    iptables -t mangle -D POSTROUTING -s "$ip" -j MARK --set-mark $MARK_VALUE 2>/dev/null
    
    log_message "Removed fast speed for IP: $ip"
}

# Apply slow speed to a single IP (MARK 0x6)
apply_slow_speed_to_ip() {
    local ip="$1"
    local slow_mark=6
    
    # Check and add download rules if missing
    if ! iptables -t mangle -C FORWARD -d "$ip" -j MARK --set-mark $slow_mark 2>/dev/null; then
        iptables -t mangle -I PREROUTING 1 -d "$ip" -j MARK --set-mark $slow_mark
        iptables -t mangle -I FORWARD 1 -d "$ip" -j MARK --set-mark $slow_mark
    fi
    
    # Check and add upload rules if missing
    if ! iptables -t mangle -C POSTROUTING -s "$ip" -j MARK --set-mark $slow_mark 2>/dev/null; then
        iptables -t mangle -I POSTROUTING 1 -s "$ip" -j MARK --set-mark $slow_mark
    fi
    
    log_message "Added slow speed for IP: $ip"
}

# Remove slow speed from a single IP
remove_slow_speed_from_ip() {
    local ip="$1"
    local slow_mark=6
    
    # Remove marking rules for DOWNLOAD (to this IP)
    iptables -t mangle -D PREROUTING -d "$ip" -j MARK --set-mark $slow_mark 2>/dev/null
    iptables -t mangle -D FORWARD -d "$ip" -j MARK --set-mark $slow_mark 2>/dev/null
    
    # Remove marking rules for UPLOAD (from this IP)
    iptables -t mangle -D POSTROUTING -s "$ip" -j MARK --set-mark $slow_mark 2>/dev/null
    
    log_message "Removed slow speed for IP: $ip"
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
    
    # Get list of IPs from API response for stale mark cleanup
    local api_ips=""
    local api_ips_file="/tmp/api-ips-$$.txt"
    > "$api_ips_file"  # Create empty file
    
    # Extract device information using jq if available, otherwise use grep/sed
    if command -v jq >/dev/null 2>&1; then
        # Use jq for proper JSON parsing
        local devices_json=$(echo "$response" | jq -r '.devices[] | "\(.ip) \(.hasMonsters) \(.ageGroup)"')
        
        echo "$devices_json" | while IFS=' ' read -r ip has_monsters age_group; do
            if [ -n "$ip" ] && [ -n "$has_monsters" ] && [ -n "$age_group" ]; then
                log_message "Processing device: $ip (monsters: $has_monsters, ageGroup: $age_group)"
                
                # Track IPs in API response (write to file to avoid subshell issue)
                echo "$ip" >> "$api_ips_file"
                
                # Handle speed control
                if [ "$has_monsters" = "true" ]; then
                    # Remove slow mark if exists, then apply fast mark
                    remove_slow_speed_from_ip "$ip" 2>/dev/null
                    apply_fast_speed_to_ip "$ip"
                else
                    # Remove fast mark if exists, then apply slow mark
                    remove_fast_speed_from_ip "$ip" 2>/dev/null
                    apply_slow_speed_to_ip "$ip"
                fi
                
                # Handle DNS filtering
                if [ "$age_group" = "child" ]; then
                    apply_dns_filtering_to_ip "$ip"
                else
                    remove_dns_filtering_from_ip "$ip"
                fi
            fi
        done
        
        # Clean up stale marks for devices not in API response
        # Get all IPs with fast marks (MARK 0x5)
        get_current_fast_ips | while read -r marked_ip; do
            if ! grep -q "^${marked_ip}$" "$api_ips_file" 2>/dev/null; then
                log_message "Removing stale fast mark (MARK 0x5) for IP not in API: $marked_ip"
                remove_fast_speed_from_ip "$marked_ip" 2>/dev/null
            fi
        done
        
        # Get all IPs with slow marks (MARK 0x6)
        iptables -t mangle -L FORWARD -n | grep "MARK set 0x6" | \
            awk '{print $5}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | \
            grep "^192.168" | sort -u | while read -r marked_ip; do
            if ! grep -q "^${marked_ip}$" "$api_ips_file" 2>/dev/null; then
                log_message "Removing stale slow mark (MARK 0x6) for IP not in API: $marked_ip"
                remove_slow_speed_from_ip "$marked_ip" 2>/dev/null
            fi
        done
        
        # Clean up temp file
        rm -f "$api_ips_file"
    else
        # Fallback to grep/sed for basic parsing
        log_message "jq not available, using basic parsing"
        
        # Extract IPs with hasMonsters=true
        local fast_ips=$(echo "$response" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
        
        # Extract IPs with hasMonsters=false
        local slow_ips=$(echo "$response" | grep -A 5 -B 5 '"hasMonsters":false' | \
            grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
        
        # Extract IPs with ageGroup="child"
        local child_ips=$(echo "$response" | grep -A 10 -B 10 '"ageGroup":"child"' | \
            grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
            grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
        
        # Track all API IPs for stale cleanup (write to file to avoid subshell issue)
        local api_ips_file="/tmp/api-ips-$$.txt"
        > "$api_ips_file"  # Create empty file
        for ip in $fast_ips $slow_ips; do
            echo "$ip" >> "$api_ips_file"
        done
        
        # Apply speed controls
        for ip in $fast_ips; do
            remove_slow_speed_from_ip "$ip" 2>/dev/null
            apply_fast_speed_to_ip "$ip"
        done
        
        for ip in $slow_ips; do
            remove_fast_speed_from_ip "$ip" 2>/dev/null
            apply_slow_speed_to_ip "$ip"
        done
        
        # Clean up stale marks
        get_current_fast_ips | while read -r marked_ip; do
            if ! grep -q "^${marked_ip}$" "$api_ips_file" 2>/dev/null; then
                log_message "Removing stale fast mark (MARK 0x5) for IP not in API: $marked_ip"
                remove_fast_speed_from_ip "$marked_ip" 2>/dev/null
            fi
        done
        
        iptables -t mangle -L FORWARD -n | grep "MARK set 0x6" | \
            awk '{print $5}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | \
            grep "^192.168" | sort -u | while read -r marked_ip; do
            if ! grep -q "^${marked_ip}$" "$api_ips_file" 2>/dev/null; then
                log_message "Removing stale slow mark (MARK 0x6) for IP not in API: $marked_ip"
                remove_slow_speed_from_ip "$marked_ip" 2>/dev/null
            fi
        done
        
        # Clean up temp file
        rm -f "$api_ips_file"
        
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
        log_message "Resetting all QoS rules"
        log_message "WARNING: This will delete ALL existing filters!"
        tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
        tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
        iptables -t mangle -F PREROUTING
        iptables -t mangle -F FORWARD
        iptables -t mangle -F POSTROUTING
        rm -f "$STATE_FILE"
        filter_snapshot "after-reset"
        filter_log "rebuild" "update-device-controls" "ALL" "qdisc" "ALL" "success" "0" "0" "reset-complete"
        log_message "QoS rules cleared"
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