#!/bin/sh
#
# register.cgi - A simple CGI script to register a device.
#
# When accessed via a GET request, this script presents an HTML form.
# When accessed via POST, it extracts the 'username' and 'hostname' parameters,
# automatically detects the client's IP and MAC address, and sends this data
# to the central server for registration.

echo "Content-type: text/html"
echo ""

# Function to URL-decode a string
urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

# Function to extract error message from JSON response
extract_error() {
    echo "$1" | grep -o '"error":"[^"]*"' | cut -d'"' -f4
}

# Function to create static DHCP reservation
create_static_dhcp() {
    local mac="$1"
    local ip="$2"
    local hostname="$3"
    local email="$4"
    
    # Skip if MAC is unknown
    if [ "$mac" = "unknown" ] || [ -z "$mac" ]; then
        echo "Warning: Cannot create static DHCP reservation - MAC address unknown" >&2
        return 1
    fi
    
    # Create a safe hostname (remove spaces, special chars)
    local safe_hostname=$(echo "$hostname" | tr -cd '[:alnum:]_-' | cut -c1-30)
    [ -z "$safe_hostname" ] && safe_hostname="device_$(echo "$mac" | tr ':' '_')"
    
    # Check if reservation already exists
    if grep -q "option mac '$mac'" /etc/config/dhcp 2>/dev/null; then
        echo "DHCP reservation already exists for MAC $mac" >&2
        return 0
    fi
    
    # Add static DHCP reservation
    cat >> /etc/config/dhcp << EOF

config host
	option name '$safe_hostname'
	option mac '$mac'
	option ip '$ip'
	option tag 'registered_device'
EOF
    
    # Restart DHCP service to apply changes
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    
    echo "Created static DHCP reservation: $ip -> $mac ($safe_hostname)" >&2
    return 0
}

# If the request method is GET, display the registration form.
if [ "$REQUEST_METHOD" = "GET" ]; then
    cat <<'EOF'
<html>
<head>
  <title>Device Registration - Mess Monsters</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    :root {
      --primary-color: #6C63FF;
      --secondary-color: #FF6584;
      --background-color: #F8F9FA;
      --text-color: #2D3748;
      --success-color: #48BB78;
      --error-color: #F56565;
    }

    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 0;
      background-color: var(--background-color);
      color: var(--text-color);
      line-height: 1.5;
    }

    .container {
      max-width: 500px;
      margin: 2rem auto;
      padding: 2rem;
      background: white;
      border-radius: 16px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    }

    .header {
      text-align: center;
      margin-bottom: 2rem;
    }

    .monster-image {
      width: 120px;
      height: 120px;
      margin: 0 auto 1rem;
      display: block;
    }

    h1 {
      color: var(--primary-color);
      font-size: 2rem;
      margin: 0 0 0.5rem;
      font-weight: 700;
    }

    .subtitle {
      color: #718096;
      margin-bottom: 2rem;
      font-size: 1.1rem;
    }

    form {
      display: flex;
      flex-direction: column;
      gap: 1.5rem;
    }

    .form-group {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    label {
      font-weight: 600;
      color: var(--text-color);
    }

    input[type="text"],
    input[type="email"] {
      padding: 0.75rem 1rem;
      border: 2px solid #E2E8F0;
      border-radius: 8px;
      font-size: 1rem;
      transition: border-color 0.2s;
    }

    input[type="text"]:focus,
    input[type="email"]:focus {
      outline: none;
      border-color: var(--primary-color);
    }

    input[type="submit"] {
      background-color: var(--primary-color);
      color: white;
      padding: 0.75rem 1.5rem;
      border: none;
      border-radius: 8px;
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
      transition: background-color 0.2s;
    }

    input[type="submit"]:hover {
      background-color: #5A52D9;
    }

    .success {
      background-color: #C6F6D5;
      color: #2F855A;
      padding: 1rem;
      border-radius: 8px;
      margin-bottom: 1.5rem;
    }

    .error {
      background-color: #FED7D7;
      color: #C53030;
      padding: 1rem;
      border-radius: 8px;
      margin-bottom: 1.5rem;
    }

    .device-details {
      background-color: #F7FAFC;
      padding: 1.5rem;
      border-radius: 8px;
      margin-top: 1.5rem;
    }

    .device-details h2 {
      color: var(--text-color);
      font-size: 1.25rem;
      margin: 0 0 1rem;
    }

    .device-details ul {
      list-style: none;
      padding: 0;
      margin: 0;
    }

    .device-details li {
      display: flex;
      justify-content: space-between;
      padding: 0.5rem 0;
      border-bottom: 1px solid #E2E8F0;
    }

    .device-details li:last-child {
      border-bottom: none;
    }

    .device-details strong {
      color: #718096;
    }

    .button {
      display: inline-block;
      background-color: var(--primary-color);
      color: white;
      padding: 0.75rem 1.5rem;
      text-decoration: none;
      border-radius: 8px;
      font-weight: 600;
      transition: background-color 0.2s;
    }

    .button:hover {
      background-color: #5A52D9;
    }

    .details {
      margin-top: 1rem;
      font-size: 0.9rem;
      color: #718096;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://i.imgur.com/ngS2ybs.png" alt="Mess Monster" class="monster-image">
      <h1>Register Your Device</h1>
      <p class="subtitle">Connect your device to the Mess Monsters network</p>
    </div>
    <form method="post" action="">
      <div class="form-group">
        <label for="username">Email Address</label>
        <input type="email" name="username" id="username" required placeholder="Enter your email">
      </div>
      <div class="form-group">
        <label for="hostname">Device Name (optional)</label>
        <input type="text" name="hostname" id="hostname" placeholder="e.g., My Laptop">
      </div>
      <input type="submit" value="Register Device">
    </form>
  </div>
</body>
</html>
EOF
    exit 0
fi

# If the request method is POST, process the registration.
if [ "$REQUEST_METHOD" = "POST" ]; then
    # Read POST data from stdin using CONTENT_LENGTH.
    read -n "$CONTENT_LENGTH" POST_DATA

    # Initialize variables.
    username=""
    hostname=""

    # Parse POST data (assumes application/x-www-form-urlencoded).
    for pair in $(echo "$POST_DATA" | tr '&' '\n'); do
        key=$(echo "$pair" | cut -d '=' -f1)
        value=$(echo "$pair" | cut -d '=' -f2-)
        value=$(urldecode "$value")
        case "$key" in
            username)
                username="$value"
                ;;
            hostname)
                hostname="$value"
                ;;
        esac
    done

    # Get the client IP address from REMOTE_ADDR.
    ip_addr="$REMOTE_ADDR"

    # Attempt to determine the MAC address via the ARP table.
    mac=$(ip neigh show "$ip_addr" 2>/dev/null | awk '{print $5}')
    [ -z "$mac" ] && mac="unknown"

    # Send the data to the server using curl
    SERVER_URL="http://messmonsters.kunovo.ai:3456/api/devices/register"
    
    # Create JSON payload
    json_data=$(printf '{"email":"%s","macAddress":"%s","ipAddress":"%s","hostname":"%s"}' \
                "$username" "$mac" "$ip_addr" "$hostname")
    
    # Send the request to the server
    echo "Sending request to $SERVER_URL with payload: $json_data" >&2
    response=$(curl -s -X POST -H "Content-Type: application/json" -d "$json_data" "$SERVER_URL")
    echo "Received response: $response" >&2
    
    # Extract error message if any
    error_message=$(extract_error "$response")
    
    # Check if the request was successful
    if echo "$response" | grep -q '"success":true'; then
        # Create static DHCP reservation
        create_static_dhcp "$mac" "$ip_addr" "$hostname" "$username"

        cat <<EOF
<html>
<head>
  <title>Registration Successful - Mess Monsters</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    /* Same styles as above */
    :root {
      --primary-color: #6C63FF;
      --secondary-color: #FF6584;
      --background-color: #F8F9FA;
      --text-color: #2D3748;
      --success-color: #48BB78;
      --error-color: #F56565;
    }

    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 0;
      background-color: var(--background-color);
      color: var(--text-color);
      line-height: 1.5;
    }

    .container {
      max-width: 500px;
      margin: 2rem auto;
      padding: 2rem;
      background: white;
      border-radius: 16px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    }

    .header {
      text-align: center;
      margin-bottom: 2rem;
    }

    .monster-image {
      width: 120px;
      height: 120px;
      margin: 0 auto 1rem;
      display: block;
    }

    h1 {
      color: var(--primary-color);
      font-size: 2rem;
      margin: 0 0 0.5rem;
      font-weight: 700;
    }

    .success {
      background-color: #C6F6D5;
      color: #2F855A;
      padding: 1rem;
      border-radius: 8px;
      margin-bottom: 1.5rem;
      text-align: center;
    }

    .device-details {
      background-color: #F7FAFC;
      padding: 1.5rem;
      border-radius: 8px;
      margin-top: 1.5rem;
    }

    .device-details h2 {
      color: var(--text-color);
      font-size: 1.25rem;
      margin: 0 0 1rem;
    }

    .device-details ul {
      list-style: none;
      padding: 0;
      margin: 0;
    }

    .device-details li {
      display: flex;
      justify-content: space-between;
      padding: 0.5rem 0;
      border-bottom: 1px solid #E2E8F0;
    }

    .device-details li:last-child {
      border-bottom: none;
    }

    .device-details strong {
      color: #718096;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://imgur.com/U8efVMW.png" alt="Happy Monster" class="monster-image">
      <h1>Registration Successful!</h1>
    </div>
    <div class="success">Your device has been registered successfully!</div>
    <div class="device-details">
      <h2>Device Information</h2>
      <ul>
        <li><strong>Email:</strong> ${username}</li>
        <li><strong>IP Address:</strong> ${ip_addr} (now static)</li>
        <li><strong>MAC Address:</strong> ${mac}</li>
        <li><strong>Device Name:</strong> ${hostname}</li>
      </ul>
      <p style="margin-top: 1rem; font-size: 0.9rem; color: #718096;">
        Your device has been assigned a static IP address and will always use ${ip_addr} on this network.
      </p>
    </div>
  </div>
</body>
</html>
EOF
    else
        # Determine the specific error message to display
        case "$error_message" in
            "User not found")
                error_display="The email address you entered is not registered in our system. Please check your email or contact support."
                ;;
            "Invalid payload")
                error_display="There was a problem with the registration data. Please try again."
                ;;
            "Internal server error")
                error_display="Our server is experiencing issues. Please try again later."
                ;;
            *)
                error_display="Unable to register your device. Please try again later."
                ;;
        esac

        cat <<EOF
<html>
<head>
  <title>Registration Failed - Mess Monsters</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    /* Same styles as above */
    :root {
      --primary-color: #6C63FF;
      --secondary-color: #FF6584;
      --background-color: #F8F9FA;
      --text-color: #2D3748;
      --success-color: #48BB78;
      --error-color: #F56565;
    }

    body {
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 0;
      background-color: var(--background-color);
      color: var(--text-color);
      line-height: 1.5;
    }

    .container {
      max-width: 500px;
      margin: 2rem auto;
      padding: 2rem;
      background: white;
      border-radius: 16px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
    }

    .header {
      text-align: center;
      margin-bottom: 2rem;
    }

    .monster-image {
      width: 120px;
      height: 120px;
      margin: 0 auto 1rem;
      display: block;
    }

    h1 {
      color: var(--primary-color);
      font-size: 2rem;
      margin: 0 0 0.5rem;
      font-weight: 700;
    }

    .error {
      background-color: #FED7D7;
      color: #C53030;
      padding: 1rem;
      border-radius: 8px;
      margin-bottom: 1.5rem;
      text-align: center;
    }

    .details {
      margin-top: 1rem;
      font-size: 0.9rem;
      color: #718096;
      text-align: center;
    }

    .button {
      display: inline-block;
      background-color: var(--primary-color);
      color: white;
      padding: 0.75rem 1.5rem;
      text-decoration: none;
      border-radius: 8px;
      font-weight: 600;
      transition: background-color 0.2s;
      margin-top: 1.5rem;
    }

    .button:hover {
      background-color: #5A52D9;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://i.imgur.com/Jx8xm6j.png" alt="Sad Monster" class="monster-image">
      <h1>Registration Failed</h1>
    </div>
    <div class="error">${error_display}</div>
    <div class="details">
      <p>Error details: ${error_message}</p>
      <p>Please check your email address and try again.</p>
    </div>
    <a href="register.cgi" class="button">Try Again</a>
  </div>
</body>
</html>
EOF
    fi
fi
