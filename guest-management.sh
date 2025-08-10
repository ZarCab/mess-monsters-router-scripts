#!/bin/bash
#
# Guest Management Script for Mess Monsters Router
# Automatically detects new devices and applies guest bandwidth limits
#
# This script:
# 1. Monitors connected devices via DHCP leases
# 2. Identifies new devices (not in static DHCP config)
# 3. Applies 10 Mbps bandwidth limit to new devices
# 4. Notifies parent via API about new guests
# 5. Logs all activities
#

# Configuration
LOG_FILE="/var/log/guest-management.log"
DHCP_LEASES="/tmp/dhcp.leases"
DHCP_CONFIG="/etc/config/dhcp"
GUEST_BANDWIDTH="10mbit"
API_SERVER="http://messmonsters.kunovo.ai:3456"
HOUSEHOLD_ID_FILE="/etc/mess-monsters/config.json"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if required files exist
check_dependencies() {
    if [ ! -f "$DHCP_LEASES" ]; then
        log "ERROR: DHCP leases file not found: $DHCP_LEASES"
        exit 1
    fi
    
    if [ ! -f "$DHCP_CONFIG" ]; then
        log "ERROR: DHCP config file not found: $DHCP_CONFIG"
        exit 1
    fi
    
    if [ ! -f "$HOUSEHOLD_ID_FILE" ]; then
        log "WARNING: Household ID file not found: $HOUSEHOLD_ID_FILE"
        log "Guest notifications will not be sent"
    fi
}

# Get household ID for API calls
get_household_id() {
    if [ -f "$HOUSEHOLD_ID_FILE" ]; then
        # Extract household_id from JSON config file
        grep -o '"household_id":"[^"]*"' "$HOUSEHOLD_ID_FILE" | cut -d'"' -f4
    else
        echo ""
    fi
}

# Check if MAC address is registered (has static DHCP)
is_registered_device() {
    local mac="$1"
    grep -q "option mac '$mac'" "$DHCP_CONFIG" 2>/dev/null
}

# Apply guest bandwidth limit using tc (traffic control)
apply_guest_bandwidth() {
    local ip="$1"
    local mac="$2"
    
    # Remove any existing rules for this IP
    tc qdisc del dev br-lan root handle 1: 2>/dev/null
    
    # Create root qdisc
    tc qdisc add dev br-lan root handle 1: htb default 30
    
    # Create class for guest traffic
    tc class add dev br-lan parent 1: classid 1:1 htb rate "$GUEST_BANDWIDTH" ceil "$GUEST_BANDWIDTH"
    
    # Add filter to match guest IP
    tc filter add dev br-lan protocol ip parent 1:0 prio 1 u32 match ip dst "$ip" flowid 1:1
    tc filter add dev br-lan protocol ip parent 1:0 prio 1 u32 match ip src "$ip" flowid 1:1
    
    log "Applied $GUEST_BANDWIDTH limit to guest device: $ip ($mac)"
}

# Send notification to parent app
notify_parent() {
    local ip="$1"
    local mac="$2"
    local hostname="$3"
    local household_id="$4"
    
    if [ -z "$household_id" ]; then
        log "Skipping parent notification - no household ID"
        return
    fi
    
    # Prepare JSON payload
    local json_data="{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hostname\",\"householdId\":\"$household_id\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    
    # Send notification to API
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$API_SERVER/api/router/new-guest" \
        >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        log "Parent notification sent for guest: $ip ($mac)"
    else
        log "Failed to send parent notification for guest: $ip ($mac)"
    fi
}

# Main guest detection and management function
manage_guests() {
    local household_id=$(get_household_id)
    local new_guests=0
    
    log "Starting guest management scan..."
    
    # Read DHCP leases and process each connected device
    while read -r line; do
        # Skip empty lines
        [ -z "$line" ] && continue
        
        # Parse DHCP lease line: timestamp mac ip hostname client-id
        timestamp=$(echo "$line" | awk '{print $1}')
        mac=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        hostname=$(echo "$line" | awk '{print $4}')
        
        # Skip if essential data is missing
        [ -z "$mac" ] || [ -z "$ip" ] && continue
        
        # Clean hostname (replace * with Unknown)
        [ "$hostname" = "*" ] && hostname="Unknown"
        
        # Check if this is a registered device
        if is_registered_device "$mac"; then
            # This is a known family device - skip
            continue
        else
            # This is a new/guest device
            log "New guest device detected: $ip ($mac) - $hostname"
            
            # Apply guest bandwidth limit
            apply_guest_bandwidth "$ip" "$mac"
            
            # Notify parent
            notify_parent "$ip" "$mac" "$hostname" "$household_id"
            
            new_guests=$((new_guests + 1))
        fi
        
    done < "$DHCP_LEASES"
    
    if [ $new_guests -eq 0 ]; then
        log "No new guest devices detected"
    else
        log "Processed $new_guests new guest device(s)"
    fi
}

# Clean up old log entries (keep last 1000 lines)
cleanup_logs() {
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 1000 ]; then
        tail -1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log file cleaned up"
    fi
}

# Main execution
main() {
    # Ensure log file exists
    touch "$LOG_FILE"
    
    # Check dependencies
    check_dependencies
    
    # Run guest management
    manage_guests
    
    # Clean up logs
    cleanup_logs
    
    log "Guest management scan completed"
}

# Run main function
main "$@"