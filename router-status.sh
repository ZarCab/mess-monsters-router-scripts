#!/bin/sh

# Router Status Script for OpenWRT - GIT UPDATE TEST
# Displays comprehensive router information

# Colors for output (if supported)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local label="$1"
    local value="$2"
    local color="$3"
    
    if [ -t 1 ]; then
        # Terminal supports colors
        printf "${color}%-20s${NC}: %s\n" "$label" "$value"
    else
        # No color support
        printf "%-20s: %s\n" "$label" "$value"
    fi
}

# Function to format bytes to human readable
format_bytes() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        printf "%.2f GB" "$(echo "$bytes / 1073741824" | bc -l 2>/dev/null || echo "$bytes / 1073741824" | awk '{printf "%.2f", $1}')"
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%.2f MB" "$(echo "$bytes / 1048576" | bc -l 2>/dev/null || echo "$bytes / 1048576" | awk '{printf "%.2f", $1}')"
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.2f KB" "$(echo "$bytes / 1024" | bc -l 2>/dev/null || echo "$bytes / 1024" | awk '{printf "%.2f", $1}')"
    else
        printf "%d B" "$bytes"
    fi
}

# Function to calculate percentage
calculate_percentage() {
    local used="$1"
    local total="$2"
    if [ "$total" -gt 0 ]; then
        printf "%.1f%%" "$(echo "$used * 100 / $total" | bc -l 2>/dev/null || echo "$used * 100 / $total" | awk '{printf "%.1f", $1}')"
    else
        printf "0.0%%"
    fi
}

# Clear screen
clear

# GIT UPDATE TEST - This line was added to test the update system
echo "🚀 GIT UPDATE TEST: Script updated via GitHub at $(date)"

# Header
echo "=========================================="
echo "           ROUTER STATUS REPORT"
echo "=========================================="
echo ""

# Timestamp
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")
print_status "Timestamp" "$TIMESTAMP" "$CYAN"

# Router name (hostname)
HOSTNAME=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "Unknown")
print_status "Router Name" "$HOSTNAME" "$GREEN"

# MAC Address from br-lan interface
MAC_ADDRESS=$(ip link show br-lan 2>/dev/null | grep -o -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 2>/dev/null || echo "Not found")
if [ "$MAC_ADDRESS" = "Not found" ]; then
    # Fallback to eth0 if br-lan doesn't exist
    MAC_ADDRESS=$(ip link show eth0 2>/dev/null | grep -o -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 2>/dev/null || echo "Unknown")
fi
print_status "MAC Address" "$MAC_ADDRESS" "$YELLOW"

# LAN IP address
LAN_IP=$(ip addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1 2>/dev/null || echo "Not found")
if [ "$LAN_IP" = "Not found" ]; then
    # Fallback to eth0 if br-lan doesn't exist
    LAN_IP=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1 2>/dev/null || echo "Unknown")
fi
print_status "LAN IP" "$LAN_IP" "$BLUE"

# Connected devices count
CONNECTED_DEVICES=$(cat /proc/net/arp 2>/dev/null | grep -v "incomplete" | grep -v "IP address" | wc -l 2>/dev/null || echo "0")
# Subtract 1 for the router itself
CONNECTED_DEVICES=$((CONNECTED_DEVICES - 1))
if [ "$CONNECTED_DEVICES" -lt 0 ]; then
    CONNECTED_DEVICES=0
fi
print_status "Connected Devices" "$CONNECTED_DEVICES" "$PURPLE"

# Uptime
UPTIME=$(uptime 2>/dev/null | sed 's/.*up \([^,]*\),.*/\1/' 2>/dev/null || echo "Unknown")
print_status "Uptime" "$UPTIME" "$GREEN"

# Memory usage
MEMORY_INFO=$(cat /proc/meminfo 2>/dev/null)
if [ -n "$MEMORY_INFO" ]; then
    TOTAL_MEM=$(echo "$MEMORY_INFO" | grep '^MemTotal:' | awk '{print $2}' 2>/dev/null || echo "0")
    FREE_MEM=$(echo "$MEMORY_INFO" | grep '^MemAvailable:' | awk '{print $2}' 2>/dev/null || echo "0")
    if [ "$FREE_MEM" = "0" ]; then
        # Fallback to MemFree if MemAvailable not available
        FREE_MEM=$(echo "$MEMORY_INFO" | grep '^MemFree:' | awk '{print $2}' 2>/dev/null || echo "0")
    fi
    USED_MEM=$((TOTAL_MEM - FREE_MEM))
    MEMORY_USAGE=$(format_bytes $((USED_MEM * 1024)))
    MEMORY_PERCENT=$(calculate_percentage "$USED_MEM" "$TOTAL_MEM")
    print_status "Memory Usage" "$MEMORY_USAGE ($MEMORY_PERCENT)" "$YELLOW"
else
    print_status "Memory Usage" "Unknown" "$YELLOW"
fi

# Disk usage
DISK_USAGE=$(df / 2>/dev/null | tail -1 | awk '{print $5}' 2>/dev/null || echo "Unknown")
if [ "$DISK_USAGE" != "Unknown" ]; then
    print_status "Disk Usage" "$DISK_USAGE" "$RED"
else
    # Try alternative mount points
    DISK_USAGE=$(df /overlay 2>/dev/null | tail -1 | awk '{print $5}' 2>/dev/null || echo "Unknown")
    print_status "Disk Usage" "$DISK_USAGE" "$RED"
fi

# Additional useful information
echo ""
echo "=========================================="
echo "           ADDITIONAL INFO"
echo "=========================================="
echo ""

# CPU load
CPU_LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' 2>/dev/null || echo "Unknown")
print_status "CPU Load (1/5/15min)" "$CPU_LOAD" "$CYAN"

# CPU temperature (if available)
CPU_TEMP=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 2>/dev/null || echo "N/A")
if [ "$CPU_TEMP" != "N/A" ] && [ "$CPU_TEMP" -gt 0 ]; then
    CPU_TEMP_C=$(echo "$CPU_TEMP / 1000" | bc -l 2>/dev/null || echo "$CPU_TEMP / 1000" | awk '{printf "%.1f", $1}')
    print_status "CPU Temperature" "${CPU_TEMP_C}°C" "$RED"
else
    print_status "CPU Temperature" "N/A" "$RED"
fi

# Wireless status (if available)
WIFI_INTERFACES=$(iwconfig 2>/dev/null | grep -E "^[[:space:]]*[a-zA-Z0-9]+" | awk '{print $1}' 2>/dev/null || echo "")
if [ -n "$WIFI_INTERFACES" ]; then
    for interface in $WIFI_INTERFACES; do
        WIFI_STATUS=$(iwconfig "$interface" 2>/dev/null | grep -o "ESSID:\"[^\"]*\"" 2>/dev/null || echo "Not configured")
        print_status "WiFi ($interface)" "$WIFI_STATUS" "$GREEN"
    done
else
    print_status "WiFi Status" "No wireless interfaces" "$GREEN"
fi

# Network interfaces status
echo ""
echo "=========================================="
echo "         NETWORK INTERFACES"
echo "=========================================="
echo ""

# Get all network interfaces
INTERFACES=$(ip link show 2>/dev/null | grep -E "^[0-9]+:" | awk -F: '{print $2}' | tr -d ' ' 2>/dev/null || echo "")

for interface in $INTERFACES; do
    # Skip loopback
    if [ "$interface" = "lo" ]; then
        continue
    fi
    
    # Get interface status
    STATUS=$(ip link show "$interface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}' 2>/dev/null || echo "Unknown")
    
    # Get IP address
    IP_ADDR=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1 2>/dev/null || echo "No IP")
    
    if [ -t 1 ]; then
        printf "${BLUE}%-15s${NC}: ${GREEN}%s${NC} - ${YELLOW}%s${NC}\n" "$interface" "$STATUS" "$IP_ADDR"
    else
        printf "%-15s: %s - %s\n" "$interface" "$STATUS" "$IP_ADDR"
    fi
done

echo ""
echo "=========================================="
echo "Report generated at: $(date)"
echo "=========================================="