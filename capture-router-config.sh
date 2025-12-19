#!/bin/sh
# Router Configuration Capture Script
# Run this on the CURRENT router to document all settings needed for replacement

OUTPUT_FILE="/mnt/usb/router-config-backup.txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "==========================================" > "$OUTPUT_FILE"
echo "Router Configuration Backup" >> "$OUTPUT_FILE"
echo "Captured: $TIMESTAMP" >> "$OUTPUT_FILE"
echo "==========================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 1. Config File Values
echo "1. CONFIG FILE VALUES (/etc/mess-monsters/config.json):" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
if [ -f "/etc/mess-monsters/config.json" ]; then
    cat /etc/mess-monsters/config.json >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    
    # Extract key values
    HOUSEHOLD_ID=$(awk -F'"' '/household_id/ {print $4}' /etc/mess-monsters/config.json)
    SERVER_URL=$(awk -F'"' '/server_url/ {print $4}' /etc/mess-monsters/config.json)
    FAST_SPEED=$(awk -F'"' '/fast_speed/ {print $4}' /etc/mess-monsters/config.json)
    SLOW_SPEED=$(awk -F'"' '/slow_speed/ {print $4}' /etc/mess-monsters/config.json)
    
    echo "KEY VALUES:" >> "$OUTPUT_FILE"
    echo "  household_id: $HOUSEHOLD_ID" >> "$OUTPUT_FILE"
    echo "  server_url: $SERVER_URL" >> "$OUTPUT_FILE"
    echo "  fast_speed: $FAST_SPEED" >> "$OUTPUT_FILE"
    echo "  slow_speed: $SLOW_SPEED" >> "$OUTPUT_FILE"
else
    echo "ERROR: Config file not found!" >> "$OUTPUT_FILE"
fi
echo "" >> "$OUTPUT_FILE"

# 2. Network Settings
echo "2. NETWORK SETTINGS:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "Router IP:" >> "$OUTPUT_FILE"
ip addr show br-lan | grep "inet " >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "DHCP Range:" >> "$OUTPUT_FILE"
uci show dhcp.lan | grep -E "(start|limit)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 3. WiFi Settings
echo "3. WIFI SETTINGS:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "WiFi SSID and Password:" >> "$OUTPUT_FILE"
uci show wireless | grep -E "(ssid|key)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 4. Static DHCP Reservations
echo "4. STATIC DHCP RESERVATIONS:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
uci show dhcp | grep -A 5 "host" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 5. All Scripts
echo "5. ALL SCRIPTS:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "Scripts in /mnt/usb/:" >> "$OUTPUT_FILE"
ls -la /mnt/usb/*.sh 2>/dev/null | awk '{print "  " $9 " (" $5 " bytes)"}' >> "$OUTPUT_FILE" || echo "  No scripts found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "Scripts in /usr/bin/ (mess-monsters related):" >> "$OUTPUT_FILE"
ls -la /usr/bin/*mess* /usr/bin/*router* /usr/bin/*guest* 2>/dev/null | awk '{print "  " $9}' >> "$OUTPUT_FILE" || echo "  No scripts found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "Scripts in /root/ (if any):" >> "$OUTPUT_FILE"
ls -la /root/*.sh 2>/dev/null | awk '{print "  " $9}' >> "$OUTPUT_FILE" || echo "  No scripts found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 6. All Cron Jobs
echo "6. ALL CRON JOBS:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
crontab -l >> "$OUTPUT_FILE" 2>/dev/null || echo "No cron jobs found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 7. VPN Configuration
echo "7. VPN CONFIGURATION:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "WireGuard Interfaces:" >> "$OUTPUT_FILE"
uci show network | grep -E "wireguard|wg" >> "$OUTPUT_FILE" || echo "  No WireGuard config found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "OpenVPN Configuration:" >> "$OUTPUT_FILE"
uci show openvpn >> "$OUTPUT_FILE" 2>/dev/null || echo "  No OpenVPN config found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "VPN/Tunnel Network Interfaces:" >> "$OUTPUT_FILE"
ip link show | grep -E "tun|wg|ppp" >> "$OUTPUT_FILE" || echo "  No VPN interfaces found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 8. SSH Tunnel/Connection Scripts
echo "8. SSH TUNNEL/CONNECTION SETUP:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "SSH Keys:" >> "$OUTPUT_FILE"
ls -la /root/.ssh/ 2>/dev/null | grep -E "id_rsa|id_ed25519" >> "$OUTPUT_FILE" || echo "  No SSH keys found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "SSH Config:" >> "$OUTPUT_FILE"
cat /root/.ssh/config 2>/dev/null >> "$OUTPUT_FILE" || echo "  No SSH config found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "Router Connection Scripts:" >> "$OUTPUT_FILE"
find /mnt/usb /usr/bin /root -name "*connect*" -o -name "*tunnel*" -o -name "*router-connect*" 2>/dev/null >> "$OUTPUT_FILE" || echo "  No connection scripts found" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 9. USB Mount Info
echo "9. USB MOUNT INFO:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "USB Mount Point:" >> "$OUTPUT_FILE"
mount | grep "/mnt/usb" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 10. QoS Current State (for reference)
echo "10. CURRENT QoS STATE (for reference):" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "QoS Classes:" >> "$OUTPUT_FILE"
tc class show dev br-lan >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 11. OpenWrt Version
echo "11. SYSTEM INFO:" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"
echo "OpenWrt Version:" >> "$OUTPUT_FILE"
cat /etc/openwrt_release 2>/dev/null || echo "Not available" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "Router Model:" >> "$OUTPUT_FILE"
cat /tmp/sysinfo/model 2>/dev/null || echo "Not available" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "==========================================" >> "$OUTPUT_FILE"
echo "Backup Complete!" >> "$OUTPUT_FILE"
echo "File saved to: $OUTPUT_FILE" >> "$OUTPUT_FILE"
echo "==========================================" >> "$OUTPUT_FILE"

# Display the file
echo "Configuration captured! Contents:"
echo ""
cat "$OUTPUT_FILE"

