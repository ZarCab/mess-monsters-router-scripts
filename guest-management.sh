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
LOCK_FILE="/var/lock/guest-management.lock"
DHCP_LEASES="/tmp/dhcp.leases"
DHCP_CONFIG="/etc/config/dhcp"
GUEST_BANDWIDTH="10mbit"
API_SERVER="http://messmonsters.kunovo.ai:3456"
HOUSEHOLD_ID_FILE="/etc/mess-monsters/config.json"

# Temporary files for session tracking (POSIX-compliant alternative to associative arrays)
HANDLES_FILE="/tmp/guest-handles.$$"
NOTIFIED_FILE="/tmp/guest-notified.$$"

# Cleanup function for temp files
cleanup_temp_files() {
    rm -f "$HANDLES_FILE" "$NOTIFIED_FILE"
}
trap cleanup_temp_files EXIT

# Helper functions for file-based "associative array" operations
get_handle() {
    local mac="$1"
    grep "^${mac}:" "$HANDLES_FILE" 2>/dev/null | cut -d: -f2-
}

set_handle() {
    local mac="$1"
    local handles="$2"
    # Remove old entry if exists
    grep -v "^${mac}:" "$HANDLES_FILE" > "${HANDLES_FILE}.tmp" 2>/dev/null || true
    # Add new entry
    echo "${mac}:${handles}" >> "${HANDLES_FILE}.tmp"
    mv "${HANDLES_FILE}.tmp" "$HANDLES_FILE"
}

is_notified() {
    local mac="$1"
    grep -q "^${mac}:" "$NOTIFIED_FILE" 2>/dev/null
}

mark_notified() {
    local mac="$1"
    local value="$2"
    echo "${mac}:${value}" >> "$NOTIFIED_FILE"
}

unmark_notified() {
    local mac="$1"
    grep -v "^${mac}:" "$NOTIFIED_FILE" > "${NOTIFIED_FILE}.tmp" 2>/dev/null || true
    mv "${NOTIFIED_FILE}.tmp" "$NOTIFIED_FILE"
}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"  # Also echo to screen
}

# Enhanced debug logging
debug_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >&2  # Also echo to stderr (not stdout)
}

# JSON string escaping function
json_escape() {
    local string="$1"
    # Escape backslashes first, then quotes
    string=$(echo "$string" | sed 's/\\/\\\\/g')
    string=$(echo "$string" | sed 's/"/\\"/g')
    echo "$string"
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
    # Remove any existing filters for this IP first (by handle for precision)
    local count_before=$(get_filter_count)
    filter_snapshot "before-del-ip-$ip"
    debug_log "Removing existing filters for IP $ip..."

    # Convert IP to hex for matching (tc shows IPs in hex format)
    local hex_ip=$(printf "%02x%02x%02x%02x" $(echo "$ip" | tr '.' ' '))

    # Try cached handles first (from previous runs in this session)
    local cached_handles=$(get_handle "$mac")
    local dst_handle=""
    local src_handle=""

    if [ -n "$cached_handles" ]; then
        debug_log "Using cached handles for $mac: $cached_handles"
        dst_handle=$(echo "$cached_handles" | cut -d: -f1)
        src_handle=$(echo "$cached_handles" | cut -d: -f2)
    else
        debug_log "No cached handles for $mac, searching tc output..."
        # Find handles from tc filter show
        # Handle format: fh 800::800 (on same line as flowid 1:20, before match line)
        # We need to find the match line, then look at previous line for handle
        local filter_output=$(tc filter show dev br-lan 2>/dev/null)
        # Extract handle: look for line with "fh" and "flowid 1:20" that comes before the match line
        dst_handle=$(echo "$filter_output" | grep -B 1 "match ${hex_ip}/ffffffff at 16" | grep "fh.*flowid 1:20" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p' | head -1)
        src_handle=$(echo "$filter_output" | grep -B 1 "match ${hex_ip}/ffffffff at 12" | grep "fh.*flowid 1:20" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p' | head -1)
        debug_log "Extracted handles: dst=$dst_handle, src=$src_handle"
    fi

    # Find and delete dst filter by handle (precise deletion)
    filter_log "del" "guest-management" "$ip" "dst" "1:20" "attempt" "$count_before" "$count_before" "removing-dst-filter"
    local del_result=1
    if [ -n "$dst_handle" ]; then
        debug_log "Deleting dst filter handle: $dst_handle for IP $ip"
        tc filter del dev br-lan protocol ip parent 1:0 handle "$dst_handle" prio 2 2>/dev/null
        del_result=$?
    else
        debug_log "No existing dst filter found for IP $ip (handle not found)"
        del_result=0  # Not an error if filter doesn't exist
    fi
    filter_log "del" "guest-management" "$ip" "dst" "1:20" "$([ $del_result -eq 0 ] && echo "success" || echo "failed")" "$count_before" "$(get_filter_count)" "dst-deleted-by-handle-$dst_handle"

    # Find and delete src filter by handle (precise deletion)
    local count_after_dst=$(get_filter_count)
    filter_log "del" "guest-management" "$ip" "src" "1:20" "attempt" "$count_after_dst" "$count_after_dst" "removing-src-filter"
    local del_result2=1
    if [ -n "$src_handle" ]; then
        debug_log "Deleting src filter handle: $src_handle for IP $ip"
        tc filter del dev br-lan protocol ip parent 1:0 handle "$src_handle" prio 2 2>/dev/null
        del_result2=$?
    else
        debug_log "No existing src filter found for IP $ip (handle not found)"
        del_result2=0  # Not an error if filter doesn't exist
    fi
    local count_after_del=$(get_filter_count)
    filter_log "del" "guest-management" "$ip" "src" "1:20" "$([ $del_result2 -eq 0 ] && echo "success" || echo "failed")" "$count_after_dst" "$count_after_del" "src-deleted-by-handle-$src_handle"
    filter_snapshot "after-del-ip-$ip"
    debug_log "✅ Existing filters removed (precise deletion by handle)"
    
    # Add new filters to assign guest to lane 1:20 (10 Mbps)
    local count_before_add=$(get_filter_count)
    filter_snapshot "before-add-dst-ip-$ip"
    debug_log "Adding download filter (dst) for IP $ip to lane 1:20..."
    filter_log "add" "guest-management" "$ip" "dst" "1:20" "attempt" "$count_before_add" "$count_before_add" "adding-dst-filter"
    if tc filter add dev br-lan protocol ip parent 1:0 prio 2 u32 match ip dst "$ip" flowid 1:20; then
        local count_after_dst=$(get_filter_count)
        # Get the handle of the newly added filter
        local filter_output=$(tc filter show dev br-lan 2>/dev/null)
        dst_handle=$(echo "$filter_output" | grep -B 1 "match ${hex_ip}/ffffffff at 16" | grep "fh.*flowid 1:20" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p' | head -1)
        filter_log "add" "guest-management" "$ip" "dst" "1:20" "success" "$count_before_add" "$count_after_dst" "dst-filter-added-handle-$dst_handle"
        filter_snapshot "after-add-dst-ip-$ip"
        debug_log "✅ Download filter added successfully (handle: $dst_handle)"
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
        # Get the handle of the newly added filter
        local filter_output=$(tc filter show dev br-lan 2>/dev/null)
        src_handle=$(echo "$filter_output" | grep -B 1 "match ${hex_ip}/ffffffff at 12" | grep "fh.*flowid 1:20" | sed -n 's/.*fh \([0-9a-f:]\+\)[[:space:]].*/\1/p' | head -1)
        # Cache the handles for this device (MAC -> "dst_handle:src_handle")
        set_handle "$mac" "$dst_handle:$src_handle"
        filter_log "add" "guest-management" "$ip" "src" "1:20" "success" "$count_before_src" "$count_after_src" "src-filter-added-handle-$src_handle"
        filter_snapshot "after-add-src-ip-$ip"
        debug_log "✅ Upload filter added successfully (handle: $src_handle)"
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

# Send notification to parent app (with deduplication)
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

    # Check for deduplication - skip if already notified in this session
    if is_notified "$mac"; then
        local already_notified=$(grep "^${mac}:" "$NOTIFIED_FILE" 2>/dev/null | cut -d: -f2-)
        debug_log "✅ Skipping notification - already notified this session: $already_notified"
        return
    fi

    # Mark as notified for this session
    mark_notified "$mac" "$ip:$hostname"
    debug_log "📝 Marked as notified for session: $mac -> $ip:$hostname"

    # Prepare JSON payload with proper escaping
    local escaped_hostname=$(json_escape "$hostname")
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Use jq if available for better JSON construction, fallback to manual
    local json_data
    if command -v jq >/dev/null 2>&1; then
        json_data=$(jq -n \
            --arg householdId "$household_id" \
            --arg deviceInfo "$escaped_hostname" \
            --arg deviceIP "$ip" \
            --arg deviceMAC "$mac" \
            --arg timestamp "$timestamp" \
            '{householdId: $householdId, deviceInfo: $deviceInfo, deviceIP: $deviceIP, deviceMAC: $deviceMAC, timestamp: $timestamp}')
        debug_log "✅ Used jq for JSON construction"
    else
        # Manual JSON construction with escaping
        json_data="{\"householdId\":\"$household_id\",\"deviceInfo\":\"$escaped_hostname\",\"deviceIP\":\"$ip\",\"deviceMAC\":\"$mac\",\"timestamp\":\"$timestamp\"}"
        debug_log "⚠️ jq not available, using manual JSON construction"
    fi

    debug_log "JSON payload: $json_data"

    # Send notification to API with timeout
    debug_log "Sending POST request to $API_SERVER/api/router/new-guest"
    local response=$(curl -s --max-time 30 -X POST \
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
        # Remove from notified list on failure (allow retry)
        unmark_notified "$mac"
        debug_log "🔄 Removed from notified list due to failure (will retry next time)"
    fi

    debug_log "=== PARENT NOTIFICATION COMPLETE ==="
}

# Clean up stale filters for disconnected devices
cleanup_stale_filters() {
    debug_log "=== CLEANING UP STALE FILTERS ==="

    # Get current MACs from DHCP leases
    local current_macs=""
    if [ -f "$DHCP_LEASES" ]; then
        current_macs=$(awk '{print $2}' "$DHCP_LEASES" | sort -u)
        debug_log "Found $(echo "$current_macs" | wc -l) current MACs in DHCP leases"
    else
        debug_log "❌ DHCP leases file not found, skipping cleanup"
        return
    fi

    # Get all guest filters (flowid 1:20)
    local filter_output=$(tc filter show dev br-lan 2>/dev/null)
    local stale_count=0

    # Process each guest filter
    echo "$filter_output" | grep -A 2 "flowid 1:20" | while read -r line1; do
        # Look for the match line with hex IP
        if echo "$line1" | grep -q "match.*at 16\|match.*at 12"; then
            # Extract hex IP from match line
            local hex_ip=$(echo "$line1" | grep -o 'match [0-9a-f]*/ffffffff' | cut -d' ' -f2 | cut -d'/' -f1)
            if [ -n "$hex_ip" ]; then
                # Convert hex back to decimal IP (POSIX-compliant)
                local ip=""
                if [ $(echo "$hex_ip" | wc -c) -eq 9 ]; then  # 8 chars + newline
                    local h1=$(echo "$hex_ip" | cut -c1-2)
                    local h2=$(echo "$hex_ip" | cut -c3-4)
                    local h3=$(echo "$hex_ip" | cut -c5-6)
                    local h4=$(echo "$hex_ip" | cut -c7-8)
                    local ip1=$((0x$h1))
                    local ip2=$((0x$h2))
                    local ip3=$((0x$h3))
                    local ip4=$((0x$h4))
                    ip="$ip1.$ip2.$ip3.$ip4"
                fi

                if [ -n "$ip" ]; then
                    debug_log "Checking filter for IP: $ip (hex: $hex_ip)"

                    # Check if this IP belongs to a current device
                    local mac_for_ip=""
                    while read -r lease_line; do
                        local lease_mac=$(echo "$lease_line" | awk '{print $2}')
                        local lease_ip=$(echo "$lease_line" | awk '{print $3}')
                        if [ "$lease_ip" = "$ip" ]; then
                            mac_for_ip="$lease_mac"
                            break
                        fi
                    done < "$DHCP_LEASES"

                    if [ -z "$mac_for_ip" ]; then
                        debug_log "❌ STALE FILTER: IP $ip has filters but no matching DHCP lease"
                        # This is a stale filter - remove it
                        local handle=$(tc filter show dev br-lan 2>/dev/null | grep -B 1 "match ${hex_ip}/ffffffff" | grep "fh" | awk '{print $NF}' | head -1)
                        if [ -n "$handle" ]; then
                            debug_log "Removing stale filter handle: $handle for IP: $ip"
                            filter_log "cleanup" "guest-management" "$ip" "stale" "1:20" "attempt" "$(get_filter_count)" "$(get_filter_count)" "removing-stale-filter-handle-$handle"
                            tc filter del dev br-lan protocol ip parent 1:0 handle "$handle" prio 2 2>/dev/null
                            local cleanup_result=$?
                            filter_log "cleanup" "guest-management" "$ip" "stale" "1:20" "$([ $cleanup_result -eq 0 ] && echo "success" || echo "failed")" "$(get_filter_count)" "$(get_filter_count)" "stale-filter-removed-handle-$handle"
                            if [ $cleanup_result -eq 0 ]; then
                                stale_count=$((stale_count + 1))
                                log "Cleaned up stale filter for disconnected device: $ip"
                            fi
                        fi
                    else
                        debug_log "✅ Filter for IP $ip belongs to current device: $mac_for_ip"
                    fi
                fi
            fi
        fi
    done

    if [ $stale_count -gt 0 ]; then
        log "Cleaned up $stale_count stale filter(s) for disconnected devices"
        debug_log "✅ Cleaned up $stale_count stale filter(s)"
    else
        debug_log "✅ No stale filters found"
    fi

    debug_log "=== STALE FILTER CLEANUP COMPLETE ==="
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
    
    # Clean up stale filters for disconnected devices
    debug_log "Calling cleanup_stale_filters..."
    cleanup_stale_filters

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

    # Acquire global lock to prevent concurrent execution
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: Another instance is already running. Exiting to prevent conflicts."
        debug_log "❌ Lock acquisition failed - another instance running"
        exit 1
    fi
    trap "rm -f $LOCK_FILE" EXIT
    debug_log "✅ Global lock acquired"

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

    # Acquire global lock for the entire daemon session
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR: Another instance is already running. Daemon exiting."
        debug_log "❌ Lock acquisition failed - another daemon running"
        exit 1
    fi
    trap "rm -f $LOCK_FILE" EXIT
    debug_log "✅ Global lock acquired for daemon mode"

    # Initial scan
    debug_log "Running initial guest scan..."
    # Don't call main() directly as it tries to acquire lock again
    # Call the core functions directly
    debug_log "=== GUEST MANAGEMENT SCRIPT STARTED (DAEMON) ==="
    debug_log "Script version: Enhanced with debug logging"
    debug_log "Current working directory: $(pwd)"
    debug_log "Script PID: $$"

    touch "$LOG_FILE"
    touch "$FILTER_LOG"
    debug_log "Log file: $LOG_FILE"
    debug_log "Filter log: $FILTER_LOG"

    # Log initial filter state
    filter_snapshot "daemon-start"
    filter_log "snapshot" "guest-management" "N/A" "N/A" "1:20" "success" "$(get_filter_count)" "$(get_filter_count)" "initial-state"

    check_dependencies
    cleanup_logs
    manage_guests

    filter_snapshot "initial-scan-complete"
    filter_log "snapshot" "guest-management" "N/A" "N/A" "1:20" "success" "$(get_filter_count)" "$(get_filter_count)" "after-initial-scan"

    debug_log "✅ Initial guest scan completed"

    # Monitor DHCP leases file for changes
    debug_log "Starting inotifywait monitoring on $DHCP_LEASES"
    inotifywait -m -e modify,create,delete "$DHCP_LEASES" | while read -r directory events filename; do
        debug_log "DHCP leases change detected: $events $filename"
        log "DHCP lease change detected - running guest management..."

        # Wait a moment for DHCP to complete
        sleep 2

        # Run guest management (without lock since daemon already holds it)
        debug_log "=== GUEST MANAGEMENT SCAN (DAEMON) ==="
        manage_guests
        filter_log "snapshot" "guest-management" "N/A" "N/A" "1:20" "success" "$(get_filter_count)" "$(get_filter_count)" "after-dhcp-change"

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