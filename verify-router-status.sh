#!/bin/sh
# Router Status Verification Script
# Run this to verify everything is working correctly before moving to next router

CONFIG_FILE="/etc/mess-monsters/config.json"
LOG_FILE="/var/log/device-controls.log"

echo "=========================================="
echo "Router QoS System Verification"
echo "=========================================="
echo ""

# 1. Check configuration
echo "1. Configuration Check:"
if [ -f "$CONFIG_FILE" ]; then
    HOUSEHOLD_ID=$(awk -F'"' '/household_id/ {print $4}' "$CONFIG_FILE")
    SERVER_URL=$(awk -F'"' '/server_url/ {print $4}' "$CONFIG_FILE")
    echo "   ✓ Config file exists"
    echo "   ✓ Household ID: $HOUSEHOLD_ID"
    echo "   ✓ Server URL: $SERVER_URL"
else
    echo "   ✗ Config file missing!"
    exit 1
fi
echo ""

# 2. Check QoS structure
echo "2. QoS Structure Check:"
if tc qdisc show dev br-lan | grep -q "default.*10\|default.*0x10"; then
    echo "   ✓ Default routing is fast lane (1:10)"
else
    echo "   ✗ Default routing issue!"
fi

if tc class show dev br-lan | grep -q "1:10"; then
    echo "   ✓ Fast lane class (1:10) exists"
else
    echo "   ✗ Fast lane class missing!"
fi

if tc class show dev br-lan | grep -q "1:30"; then
    echo "   ✓ Slow lane class (1:30) exists"
else
    echo "   ✗ Slow lane class missing!"
fi

if ! tc class show dev br-lan | grep -q "1:20"; then
    echo "   ✓ Old guest lane (1:20) removed"
else
    echo "   ⚠ Old guest lane (1:20) still exists"
fi
echo ""

# 3. Check filters
echo "3. Filter Check:"
FILTERS_LAN=$(tc filter show dev br-lan 2>/dev/null | wc -l)
FILTERS_WAN=$(tc filter show dev eth0.2 2>/dev/null | wc -l)
echo "   Filters on br-lan: $FILTERS_LAN"
echo "   Filters on eth0.2: $FILTERS_WAN"

# Check for bad filter
if tc filter show dev br-lan 2>/dev/null | grep -q "handle.*0x5.*classid 1:30"; then
    echo "   ⚠ Bad filter detected: handle 0x5 → 1:30 (but may not be causing issues)"
else
    echo "   ✓ No bad filter detected"
fi

# Check for fast lane filter
if tc filter show dev br-lan 2>/dev/null | grep -q "handle.*0x5.*classid 1:10\|handle.*5.*classid 1:10"; then
    echo "   ✓ Fast lane filter exists (handle 0x5 → 1:10)"
else
    echo "   ⚠ Fast lane filter missing (but default may handle it)"
fi

# Check for slow lane filter
if tc filter show dev br-lan 2>/dev/null | grep -q "handle.*0x6.*classid 1:30\|handle.*6.*classid 1:30"; then
    echo "   ✓ Slow lane filter exists (handle 0x6 → 1:30)"
else
    echo "   ⚠ Slow lane filter missing (but may not be needed if working)"
fi
echo ""

# 4. Check API connectivity
echo "4. API Connectivity Check:"
API_RESPONSE=$(curl -s "${SERVER_URL}/api/router/device-controls?household_id=${HOUSEHOLD_ID}" 2>/dev/null)
if echo "$API_RESPONSE" | grep -q '"success":true'; then
    echo "   ✓ API is responding"
    DEVICE_COUNT=$(echo "$API_RESPONSE" | jq '.devices | length' 2>/dev/null || echo "0")
    echo "   ✓ Found $DEVICE_COUNT registered devices"
else
    echo "   ✗ API not responding!"
fi
echo ""

# 5. Check device marks
echo "5. Device Marks Check:"
FAST_MARKS=$(iptables -t mangle -L FORWARD -n | grep "MARK set 0x5" | grep "192.168" | wc -l)
SLOW_MARKS=$(iptables -t mangle -L FORWARD -n | grep "MARK set 0x6" | grep "192.168" | wc -l)
echo "   Devices with fast mark (MARK 0x5): $FAST_MARKS"
echo "   Devices with slow mark (MARK 0x6): $SLOW_MARKS"
echo ""

# 6. Check script execution
echo "6. Script Execution Check:"
if [ -f "$LOG_FILE" ]; then
    LAST_RUN=$(tail -1 "$LOG_FILE" 2>/dev/null | awk '{print $1, $2}')
    if [ -n "$LAST_RUN" ]; then
        echo "   ✓ Script has run (last: $LAST_RUN)"
    else
        echo "   ⚠ No log entries found"
    fi
else
    echo "   ⚠ Log file doesn't exist"
fi

# Check cron
if crontab -l 2>/dev/null | grep -q "update-device-controls"; then
    echo "   ✓ Script is in cron"
else
    echo "   ⚠ Script not found in cron"
fi
echo ""

# 7. Summary
echo "=========================================="
echo "Summary:"
echo "=========================================="
echo ""
echo "If all checks show ✓, system is ready!"
echo ""
echo "To test manually:"
echo "  1. Registered device with monsters → should get fast speed (~50 Mbps)"
echo "  2. Registered device without monsters → should get slow speed (~512 kbps)"
echo "  3. Guest device (not registered) → should get fast speed (default)"
echo ""
echo "Run: /mnt/usb/update-device-controls.sh to manually trigger script"
echo ""

