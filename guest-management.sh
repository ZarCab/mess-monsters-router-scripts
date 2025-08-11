#!/bin/sh
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
    log "DEBUG: Checking household ID file: $HOUSEHOLD_ID_FILE"
    
    if [ -f "$HOUSEHOLD_ID_FILE" ]; then
        log "DEBUG: Household ID file exists"
        
        # Try the original parsing method
        local household_id=$(grep -o '"household_id":"[^"]*"' "$HOUSEHOLD_ID_FILE" | cut -d'"' -f4)
        log "DEBUG: Original parsing result: '$household_id' (length: ${#household_id})"
        
        # If that fails, try alternative parsing for JSON with spaces
        if [ -z "$household_id" ]; then
            log "DEBUG: Original parsing failed, trying alternative method"
            household_id=$(awk -F'"' '/household_id/ {print $4}' "$HOUSEHOLD_ID_FILE")
            log "DEBUG: Alternative parsing result: '$household_id' (length: ${#household_id})"
        fi
        
        # If still empty, try sed method
        if [ -z "$household_id" ]; then
            log "DEBUG: Alternative parsing failed, trying sed method"
            household_id=$(sed -n 's/.*"household_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOUSEHOLD_ID_FILE")
            log "DEBUG: Sed parsing result: '$household_id' (length: ${#household_id})"
        fi
        
        echo "$household_id"
    else
        log "DEBUG: Household ID file not found: $HOUSEHOLD_ID_FILE"
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

# Real-time daemon mode
daemon_mode() {
    log "Starting real-time guest monitoring daemon..."
    echo "Real-time guest monitoring started. Press Ctrl+C to stop."
    
    # Check if inotifywait is available
    if ! command -v inotifywait >/dev/null 2>&1; then
        log "ERROR: inotifywait not found. Install inotify-tools package."
        echo "Error: inotify-tools package required for real-time monitoring"
        echo "Install with: opkg update && opkg install inotify-tools"
        exit 1
    fi
    
    # Monitor DHCP leases file for changes
    inotifywait -m "$DHCP_LEASES" -e modify --format '%w %e %T' --timefmt '%Y-%m-%d %H:%M:%S' | while read file event time; do
        log "Real-time trigger: DHCP lease file modified at $time"
        echo "[$time] DHCP lease change detected - running guest management..."
        
        # Run guest management scan
        scan_guests_only
        
        log "Real-time scan completed"
    done
}

# Guest management scan only (for daemon mode)
scan_guests_only() {
    # Check dependencies
    check_dependencies
    
    # Run guest management
    manage_guests
}

# Display usage information
show_usage() {
    echo "Guest Management Script - Usage:"
    echo ""
    echo "Manual Mode:"
    echo "  $0                Run guest management scan once"
    echo ""
    echo "Real-Time Mode:"
    echo "  $0 --daemon       Start real-time monitoring daemon"
    echo "  $0 -d             Start real-time monitoring daemon (short)"
    echo ""
    echo "Other Options:"
    echo "  $0 --help         Show this help message"
    echo "  $0 -h             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                # Run manual scan"
    echo "  $0 --daemon       # Start real-time monitoring"
}

# Main execution logic
case "$1" in
    --daemon|-d)
        daemon_mode
        ;;
    --help|-h)
        show_usage
        ;;
    "")
        # No arguments - run manual mode
        main
        ;;
    *)
        echo "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac