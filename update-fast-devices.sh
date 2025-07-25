#!/bin/sh

# Configuration
CONFIG_FILE="/etc/mess-monsters/config.json"
LOG_FILE="/var/log/fast-devices.log"
PHYSICAL_INTERFACE="br-lan"
WAN_INTERFACE="eth0.2"
MARK_VALUE=5
STATE_FILE="/tmp/fast-devices-state.txt"

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

API_URL="${SERVER_URL}/api/router/fast-devices?household_id=${HOUSEHOLD_ID}"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to get current fast devices from API
fetch_fast_devices() {
    local response=$(curl -s "$API_URL")
    
    if [ -z "$response" ] || ! echo "$response" | grep -q '"success":true'; then
        log_message "Error fetching devices from API"
        return 1
    fi
    
    # Extract IPs and sort them
    echo "$response" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4 | \
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

# Function to get current state of fast IPs
get_current_fast_ips() {
    # Get IPs that are currently marked for fast speed
    iptables -t mangle -L FORWARD -n | grep "MARK set 0x5" | \
        awk '{print $5}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | \
        grep "^192.168" | sort -u
}

# Check if QoS is properly set up
check_qos_setup() {
    # Check if classes exist AND if default is set to slow (20)
    tc qdisc show dev $PHYSICAL_INTERFACE | grep -q "default 20" && \
    tc qdisc show dev $WAN_INTERFACE | grep -q "default 20" && \
    tc class show dev $PHYSICAL_INTERFACE | grep -q "1:1" && \
    tc class show dev $WAN_INTERFACE | grep -q "1:1"
}

# Set up QoS if not already configured
setup_qos_if_needed() {
    if ! check_qos_setup; then
        log_message "Setting up QoS structure"
        
        # LAN (download) QoS
        tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
        tc qdisc add dev $PHYSICAL_INTERFACE root handle 1: htb default 20
        tc class add dev $PHYSICAL_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        tc class add dev $PHYSICAL_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class add dev $PHYSICAL_INTERFACE parent 1:1 classid 1:20 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        tc qdisc add dev $PHYSICAL_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc add dev $PHYSICAL_INTERFACE parent 1:20 handle 20: pfifo limit 100
        
        # WAN (upload) QoS - slow by default
        tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
        tc qdisc add dev $WAN_INTERFACE root handle 1: htb default 20
        tc class add dev $WAN_INTERFACE parent 1: classid 1:1 htb rate 1000mbit
        tc class add dev $WAN_INTERFACE parent 1:1 classid 1:10 htb rate "$FAST_SPEED" ceil "$FAST_SPEED"
        tc class add dev $WAN_INTERFACE parent 1:1 classid 1:20 htb rate "$SLOW_SPEED" ceil "$SLOW_SPEED"
        tc qdisc add dev $WAN_INTERFACE parent 1:10 handle 10: pfifo limit 100
        tc qdisc add dev $WAN_INTERFACE parent 1:20 handle 20: pfifo limit 100
        
        # Add base filters
        tc filter add dev $PHYSICAL_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        
        # Add filter for WAN (upload) marked packets
        tc filter add dev $WAN_INTERFACE parent 1: protocol ip prio 1 handle $MARK_VALUE fw flowid 1:10
        
        log_message "QoS structure created"
        return 0
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
    log_message "Starting speed update check"
    
    # Ensure QoS is set up
    local qos_changed=0
    if setup_qos_if_needed; then
        qos_changed=1
    fi
    
    # Get new device list from API
    NEW_IPS=$(fetch_fast_devices)
    if [ $? -ne 0 ]; then
        log_message "Failed to fetch devices, keeping current settings"
        return 1
    fi
    
    # Always include critical services - Mess Monsters server and Firebase services
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
    
    NEW_IPS=$(echo "$NEW_IPS $STATIC_IPS" | tr ' ' '\n' | sort -u)
    
    # Get current fast IPs
    CURRENT_IPS=$(get_current_fast_ips)
    
    # Compare lists using basic shell commands
    # Find IPs to add (in NEW_IPS but not in CURRENT_IPS)
    ADDED_IPS=""
    for ip in $NEW_IPS; do
        if ! echo "$CURRENT_IPS" | grep -q "^$ip$"; then
            ADDED_IPS="$ADDED_IPS$ip\n"
        fi
    done
    ADDED_IPS=$(echo -e "$ADDED_IPS" | grep -v '^$')
    
    # Find IPs to remove (in CURRENT_IPS but not in NEW_IPS)
    REMOVED_IPS=""
    for ip in $CURRENT_IPS; do
        if ! echo "$NEW_IPS" | grep -q "^$ip$"; then
            REMOVED_IPS="$REMOVED_IPS$ip\n"
        fi
    done
    REMOVED_IPS=$(echo -e "$REMOVED_IPS" | grep -v '^$')
    
    # Check if any changes needed
    if [ -z "$ADDED_IPS" ] && [ -z "$REMOVED_IPS" ] && [ $qos_changed -eq 0 ]; then
        log_message "No changes needed"
        return 0
    fi
    
    # Apply changes
    if [ -n "$REMOVED_IPS" ]; then
        log_message "Removing fast speed from: $(echo $REMOVED_IPS | tr '\n' ' ')"
        for ip in $REMOVED_IPS; do
            remove_fast_speed_from_ip "$ip"
        done
    fi
    
    if [ -n "$ADDED_IPS" ]; then
        log_message "Adding fast speed to: $(echo $ADDED_IPS | tr '\n' ' ')"
        for ip in $ADDED_IPS; do
            apply_fast_speed_to_ip "$ip"
        done
    fi
    
    # Always ensure critical services have fast speed
    for ip in $STATIC_IPS; do
        apply_fast_speed_to_ip "$ip" 2>/dev/null
    done
    
    # Always ensure all fast devices have both download AND upload rules
    for ip in $NEW_IPS; do
        apply_fast_speed_to_ip "$ip" 2>/dev/null
    done
    
    log_message "Speed update completed"
}

# Handle command line arguments
case "$1" in
    --status)
        echo "=== Current QoS Status ==="
        echo "Fast device IPs:"
        get_current_fast_ips
        echo ""
        echo "QoS Classes:"
        tc class show dev $PHYSICAL_INTERFACE
        echo ""
        echo "Recent log entries:"
        tail -5 "$LOG_FILE"
        ;;
    --reset)
        log_message "Resetting all QoS rules"
        tc qdisc del dev $PHYSICAL_INTERFACE root 2>/dev/null
        tc qdisc del dev $WAN_INTERFACE root 2>/dev/null
        iptables -t mangle -F PREROUTING
        iptables -t mangle -F FORWARD
        iptables -t mangle -F POSTROUTING
        rm -f "$STATE_FILE"
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