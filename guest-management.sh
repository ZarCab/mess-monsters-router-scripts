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
FILTER_LOG="/var/log/filter-operations.log"
DHCP_LEASES="/tmp/dhcp.leases"
DHCP_CONFIG="/etc/config/dhcp"
GUEST_BANDWIDTH="10mbit"
API_SERVER="http://messmonsters.kunovo.ai:3456"
HOUSEHOLD_ID_FILE="/etc/mess-monsters/config.json"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"  # Also echo to screen
}

# Enhanced debug logging
debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1"  # Also echo to screen
}

# Filter operation logging functions
get_filter_count() {
    tc filter show dev br-lan 2>/dev/null | grep -c "flowid 1:20" || echo "0"
}

filter_log() {
    local action="$1"      # add, del, verify, snapshot
    local script="$2"       # guest-management
    local ip="$3"           # IP address
    local type="$4"         # dst, src, both
    local lane="$5"         # 1:20
    local result="$6"       # success, failed
    local count_before="$7"
    local count_after="$8"
    local context="$9"      # optional context
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FILTER-OP] ACTION=$action | SCRIPT=$script | IP=$ip | TYPE=$type | LANE=$lane | RESULT=$result | COUNT_BEFORE=$count_before | COUNT_AFTER=$count_after | CONTEXT=$context" >> "$FILTER_LOG"
}

filter_snapshot() {
    local context="$1"  # before-add, after-add, before-del, after-del, etc
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FILTER-SNAP] CONTEXT=$context" >> "$FILTER_LOG"
    tc filter show dev br-lan 2>/dev/null | grep -A 1 "flowid 1:20" >> "$FILTER_LOG" || echo "No guest filters found" >> "$FILTER_LOG"
    echo "---" >> "$FILTER_LOG"
}

# Check if required files exist
check_dependencies() {
    debug_log "=== CHECKING DEPENDENCIES ==="
    
    if [ ! -f "$DHCP_LEASES" ]; then
        log "ERROR: DHCP leases file not found: $DHCP_LEASES"
        exit 1
    else
        debug_log "✅ DHCP leases file found: $DHCP_LEASES"
    fi
    
    if [ ! -f "$DHCP_CONFIG" ]; then
        log "ERROR: DHCP config file not found: $DHCP_CONFIG"
        exit 1
    else
        debug_log "✅ DHCP config file found: $DHCP_CONFIG"
    fi
    
    if [ ! -f "$HOUSEHOLD_ID_FILE" ]; then
        log "WARNING: Household ID file not found: $HOUSEHOLD_ID_FILE"
        log "Guest notifications will not be sent"
    else
        debug_log "✅ Household ID file found: $HOUSEHOLD_ID_FILE"
    fi
    
    debug_log "=== DEPENDENCIES CHECK COMPLETE ==="
}

# Get household ID for API calls
get_household_id() {
    debug_log "=== GETTING HOUSEHOLD ID ==="
    debug_log "Checking household ID file: $HOUSEHOLD_ID_FILE"
    
    if [ -f "$HOUSEHOLD_ID_FILE" ]; then
        debug_log "Household ID file exists"
        
        # Try the original parsing method
        local household_id=$(grep -o '"household_id":"[^"]*"' "$HOUSEHOLD_ID_FILE" | cut -d'"' -f4)
        debug_log "Original parsing result: '$household_id' (length: ${#household_id})"
        
        # If that fails, try alternative parsing for JSON with spaces
        if [ -z "$household_id" ]; then
            debug_log "Original parsing failed, trying alternative method"
            household_id=$(awk -F'"' '/household_id/ {print $4}' "$HOUSEHOLD_ID_FILE")
            debug_log "Alternative parsing result: '$household_id' (length: ${#household_id})"
        fi
        
        # If still empty, try sed method
        if [ -z "$household_id" ]; then
            debug_log "Alternative parsing failed, trying sed method"
            household_id=$(sed -n 's/.*"household_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOUSEHOLD_ID_FILE")
            debug_log "Sed parsing result: '$household_id' (length: ${#household_id})"
        fi
        
        debug_log "Final household ID: '$household_id'"
        echo "$household_id"
    else
        debug_log "Household ID file not found: $HOUSEHOLD_ID_FILE"
        echo ""
    fi
    
    debug_log "=== HOUSEHOLD ID CHECK COMPLETE ==="
}

# Check if MAC address is registered (has static DHCP)
is_registered_device() {
    local mac="$1"
    debug_log "Checking if MAC $mac is registered in DHCP config"
    
    if grep -q "option mac '$mac'" "$DHCP_CONFIG" 2>/dev/null; then
        debug_log "✅ MAC $mac is registered (Mess Monster device)"
        return 0
    else
        debug_log "❌ MAC $mac is NOT registered (Guest device)"
        return 1
    fi
}

# Apply guest bandwidth limit using existing three-lane traffic control
apply_guest_bandwidth() {
    local ip="$1"
    local mac="$2"
    
    debug_log "=== APPLYING GUEST BANDWIDTH ==="
    debug_log "Device: IP=$ip, MAC=$mac"
    
    # Check if three-lane QoS structure exists
    debug_log "Checking QoS structure..."
    if ! tc class show dev br-lan | grep -q "1:20"; then
        log "WARNING: Three-lane QoS structure not found. Guest may get slow speed."
        debug_log "❌ QoS structure check failed"
        return 1
    else
        debug_log "✅ QoS structure check passed"
    fi
    
    # Add filter to assign guest device to guest lane (1:20)
    # Remove any existing filters for this IP first
    local count_before=$(get_filter_count)
    filter_snapshot "before-del-ip-$ip"
    debug_log "Removing existing filters for IP $ip..."
    filter_log "del" "guest-management" "$ip" "dst" "1:20" "attempt" "$count_before" "$count_before" "removing-dst-filter"
    tc filter del dev br-lan protocol ip parent 1:0 prio 2 u32 match ip dst "$ip" 2>/dev/null
    local del_result=$?
    filter_log "del" "guest-management" "$ip" "dst" "1:20" "$([ $del_result -eq 0 ] && echo "success" || echo "failed")" "$count_before" "$(get_filter_count)" "dst-deleted"
    
    filter_log "del" "guest-management" "$ip" "src" "1:20" "attempt" "$(get_filter_count)" "$(get_filter_count)" "removing-src-filter"
    tc filter del dev br-lan protocol ip parent 1:0 prio 2 u32 match ip src "$ip" 2>/dev/null
    local del_result2=$?
    local count_after_del=$(get_filter_count)
    filter_log "del" "guest-management" "$ip" "src" "1:20" "$([ $del_result2 -eq 0 ] && echo "success" || echo "failed")" "$count_before" "$count_after_del" "src-deleted"
    filter_snapshot "after-del-ip-$ip"
    debug_log "✅ Existing filters removed"
    
    # Add new filters to assign guest to lane 1:20 (10 Mbps)
    local count_before_add=$(get_filter_count)
    filter_snapshot "before-add-dst-ip-$ip"
    debug_log "Adding download filter (dst) for IP $ip to lane 1:20..."
    filter_log "add" "guest-management" "$ip" "dst" "1:20" "attempt" "$count_before_add" "$count_before_add" "adding-dst-filter"
    if tc filter add dev br-lan protocol ip parent 1:0 prio 2 u32 match ip dst "$ip" flowid 1:20; then
        local count_after_dst=$(get_filter_count)
        filter_log "add" "guest-management" "$ip" "dst" "1:20" "success" "$count_before_add" "$count_after_dst" "dst-filter-added"
        filter_snapshot "after-add-dst-ip-$ip"
        debug_log "✅ Download filter added successfully"
    else
        local count_after_fail=$(get_filter_count)
        filter_log "add" "guest-management" "$ip" "dst" "1:20" "failed" "$count_before_add" "$count_after_fail" "dst-filter-failed"
        log "ERROR: Failed to add download filter for IP $ip"
        debug_log "❌ Download filter failed"
        return 1
    fi
    
    local count_before_src=$(get_filter_count)
    filter_snapshot "before-add-src-ip-$ip"
    debug_log "Adding upload filter (src) for IP $ip to lane 1:20..."
    filter_log "add" "guest-management" "$ip" "src" "1:20" "attempt" "$count_before_src" "$count_before_src" "adding-src-filter"
    if tc filter add dev br-lan protocol ip parent 1:0 prio 2 u32 match ip src "$ip" flowid 1:20; then
        local count_after_src=$(get_filter_count)
        filter_log "add" "guest-management" "$ip" "src" "1:20" "success" "$count_before_src" "$count_after_src" "src-filter-added"
        filter_snapshot "after-add-src-ip-$ip"
        debug_log "✅ Upload filter added successfully"
    else
        local count_after_fail=$(get_filter_count)
        filter_log "add" "guest-management" "$ip" "src" "1:20" "failed" "$count_before_src" "$count_after_fail" "src-filter-failed"
        log "ERROR: Failed to add upload filter for IP $ip"
        debug_log "❌ Upload filter failed"
        return 1
    fi
    
    # Verify filters were created
    local count_after_all=$(get_filter_count)
    filter_snapshot "after-all-filters-ip-$ip"
    debug_log "Verifying filters were created..."
    # Convert IP to hex for verification (tc filter show displays IPs in hex format)
    hex_ip=$(printf "%02x%02x%02x%02x" $(echo "$ip" | tr '.' ' '))
    debug_log "Checking for filter with hex IP: $hex_ip"
    # Check if hex IP exists in filters AND if there's a flowid 1:20 nearby
    # (hex IP and flowid are on separate lines in tc output)
    if tc filter show dev br-lan | grep -A 1 "flowid 1:20" | grep -q "$hex_ip"; then
        filter_log "verify" "guest-management" "$ip" "both" "1:20" "success" "$count_after_all" "$count_after_all" "filters-exist"
        debug_log "✅ Filters verified for IP $ip (hex: $hex_ip)"
        log "Applied guest lane (10mbit) to device: $ip ($mac)"
    else
        filter_log "verify" "guest-management" "$ip" "both" "1:20" "failed" "$count_after_all" "$count_after_all" "filters-not-found"
        log "ERROR: Filters not found after creation for IP $ip"
        debug_log "❌ Filter verification failed (checked for hex: $hex_ip)"
        return 1
    fi
    
    debug_log "=== GUEST BANDWIDTH APPLICATION COMPLETE ==="
    return 0
}

# Send notification to parent app
notify_parent() {
    local ip="$1"
    local mac="$2"
    local hostname="$3"
    local household_id="$4"
    
    debug_log "=== SENDING PARENT NOTIFICATION ==="
    debug_log "Device: IP=$ip, MAC=$mac, Hostname=$hostname, HouseholdID=$household_id"
    
    if [ -z "$household_id" ]; then
        log "Skipping parent notification - no household ID"
        debug_log "❌ No household ID, skipping notification"
        return
    fi
    
    # Prepare JSON payload to match server endpoint
    local json_data="{\"householdId\":\"$household_id\",\"deviceInfo\":\"$hostname\",\"deviceIP\":\"$ip\",\"deviceMAC\":\"$mac\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    debug_log "JSON payload: $json_data"
    
    # Send notification to API
    debug_log "Sending POST request to $API_SERVER/api/router/new-guest"
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        "$API_SERVER/api/router/new-guest" \
        2>&1)
    
    local curl_exit_code=$?
    debug_log "Curl exit code: $curl_exit_code"
    debug_log "API response: $response"
    
    if [ $curl_exit_code -eq 0 ]; then
        log "Parent notification sent for guest: $ip ($mac)"
        debug_log "✅ Notification sent successfully"
    else
        log "Failed to send parent notification for guest: $ip ($mac)"
        debug_log "❌ Notification failed with exit code $curl_exit_code"
    fi
    
    debug_log "=== PARENT NOTIFICATION COMPLETE ==="
}

# Main guest detection and management function
manage_guests() {
    local household_id=$(get_household_id)
    local new_guests=0
    
    debug_log "=== STARTING GUEST MANAGEMENT SCAN ==="
    log "Starting guest management scan..."
    debug_log "Household ID: '$household_id'"
    
    # Read DHCP leases and process each connected device
    debug_log "Reading DHCP leases from $DHCP_LEASES"
    local lease_count=0
    
    while read -r line; do
        # Skip empty lines
        [ -z "$line" ] && continue
        
        lease_count=$((lease_count + 1))
        debug_log "Processing lease line $lease_count: $line"
        
        # Parse DHCP lease line: timestamp mac ip hostname client-id
        timestamp=$(echo "$line" | awk '{print $1}')
        mac=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        hostname=$(echo "$line" | awk '{print $4}')
        
        debug_log "Parsed: timestamp=$timestamp, mac=$mac, ip=$ip, hostname=$hostname"
        
        # Skip if essential data is missing
        if [ -z "$mac" ] || [ -z "$ip" ]; then
            debug_log "❌ Skipping line - missing MAC or IP"
            continue
        fi
        
        # Clean hostname (replace * with Unknown)
        if [ "$hostname" = "*" ]; then
            hostname="Unknown"
            debug_log "Hostname was *, changed to 'Unknown'"
        fi
        
        # Check if this is a registered device
        debug_log "Checking if device is registered..."
        if is_registered_device "$mac"; then
            # This is a known family device - skip
            debug_log "Skipping registered device: $ip ($mac)"
            continue
        else
            # This is a new/guest device
            debug_log "🎯 NEW GUEST DEVICE DETECTED: $ip ($mac) - $hostname"
            log "New guest device detected: $ip ($mac) - $hostname"
            
            # Apply guest bandwidth limit
            debug_log "Calling apply_guest_bandwidth for $ip..."
            if apply_guest_bandwidth "$ip" "$mac"; then
                debug_log "✅ Guest bandwidth applied successfully"
                
                # Notify parent
                debug_log "Calling notify_parent for $ip..."
                notify_parent "$ip" "$mac" "$hostname" "$household_id"
                
                new_guests=$((new_guests + 1))
                debug_log "Guest count: $new_guests"
            else
                log "ERROR: Failed to apply guest bandwidth to $ip ($mac)"
                debug_log "❌ Guest bandwidth application failed"
            fi
        fi
        
    done < "$DHCP_LEASES"
    
    debug_log "Total leases processed: $lease_count"
    
    if [ $new_guests -eq 0 ]; then
        log "No new guest devices detected"
        debug_log "✅ No new guests found"
    else
        log "Processed $new_guests new guest device(s)"
        debug_log "✅ Processed $new_guests new guest(s)"
    fi
    
    debug_log "=== GUEST MANAGEMENT SCAN COMPLETE ==="
}

# Clean up old log entries (keep last 1000 lines)
cleanup_logs() {
    debug_log "=== CLEANING UP LOGS ==="
    if [ -f "$LOG_FILE" ] && [ $(wc -l < "$LOG_FILE") -gt 1000 ]; then
        tail -1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log file cleaned up"
        debug_log "✅ Log cleanup completed"
    else
        debug_log "No log cleanup needed"
    fi
    
    # Clean up filter log (keep last 500 lines - more detailed)
    if [ -f "$FILTER_LOG" ] && [ $(wc -l < "$FILTER_LOG") -gt 500 ]; then
        tail -500 "$FILTER_LOG" > "${FILTER_LOG}.tmp"
        mv "${FILTER_LOG}.tmp" "$FILTER_LOG"
        debug_log "✅ Filter log cleaned up"
    fi
    
    debug_log "=== LOG CLEANUP COMPLETE ==="
}

# Main execution
main() {
    debug_log "=== GUEST MANAGEMENT SCRIPT STARTED ==="
    debug_log "Script version: Enhanced with debug logging"
    debug_log "Current working directory: $(pwd)"
    debug_log "Script PID: $$"
    
    # Ensure log files exist
    touch "$LOG_FILE"
    touch "$FILTER_LOG"
    debug_log "Log file: $LOG_FILE"
    debug_log "Filter log: $FILTER_LOG"
    
    # Log initial filter state
    filter_snapshot "script-start"
    filter_log "snapshot" "guest-management" "N/A" "N/A" "1:20" "success" "$(get_filter_count)" "$(get_filter_count)" "initial-state"
    
    # Check dependencies
    debug_log "Calling check_dependencies..."
    check_dependencies
    
    # Clean up old logs
    debug_log "Calling cleanup_logs..."
    cleanup_logs
    
    # Main guest management
    debug_log "Calling manage_guests..."
    manage_guests
    
    # Log final filter state
    filter_snapshot "script-end"
    filter_log "snapshot" "guest-management" "N/A" "N/A" "1:20" "success" "$(get_filter_count)" "$(get_filter_count)" "final-state"
    
    debug_log "=== GUEST MANAGEMENT SCRIPT COMPLETED SUCCESSFULLY ==="
}

# Daemon mode - monitor DHCP leases for changes
daemon_mode() {
    debug_log "=== STARTING DAEMON MODE ==="
    debug_log "Monitoring DHCP leases for changes..."
    
    # Check if inotifywait is available
    if ! command -v inotifywait >/dev/null 2>&1; then
        log "ERROR: inotifywait not found. Please install inotify-tools package."
        debug_log "❌ inotifywait not available"
        exit 1
    fi
    
    debug_log "✅ inotifywait available"
    
    # Initial scan
    debug_log "Running initial guest scan..."
    main
    
    # Monitor DHCP leases file for changes
    debug_log "Starting inotifywait monitoring on $DHCP_LEASES"
    inotifywait -m -e modify,create,delete "$DHCP_LEASES" | while read -r directory events filename; do
        debug_log "DHCP leases change detected: $events $filename"
        log "DHCP lease change detected - running guest management..."
        
        # Wait a moment for DHCP to complete
        sleep 2
        
        # Run guest management
        debug_log "Calling main() after DHCP change..."
        main
        
        debug_log "Guest management completed after DHCP change"
    done
}

# Command line argument handling
case "${1:-}" in
    --daemon)
        debug_log "Starting in daemon mode"
        daemon_mode
        ;;
    --apply-guest)
        if [ -z "$2" ]; then
            echo "Usage: $0 --apply-guest <IP_ADDRESS>"
            exit 1
        fi
        debug_log "Manual guest application for IP: $2"
        apply_guest_bandwidth "$2" "manual"
        ;;
    --test)
        debug_log "Running in test mode"
        main
        ;;
    *)
        echo "Usage: $0 [--daemon|--apply-guest <IP>|--test]"
        echo "  --daemon: Run as daemon monitoring DHCP changes"
        echo "  --apply-guest <IP>: Manually apply guest settings to IP"
        echo "  --test: Run once and exit"
        exit 1
        ;;
esac