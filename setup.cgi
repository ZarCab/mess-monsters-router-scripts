#!/bin/sh

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

# Function to extract household ID from JSON response
extract_household_id() {
    echo "$1" | grep -o '"household_id":"[^"]*"' | cut -d'"' -f4
}

# If the request method is GET, display the setup form.
if [ "$REQUEST_METHOD" = "GET" ]; then
    cat <<'EOF'
<html>
<head>
  <title>Router Setup - Mess Monsters</title>
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

    input[type="email"] {
      padding: 0.75rem 1rem;
      border: 2px solid #E2E8F0;
      border-radius: 8px;
      font-size: 1rem;
      transition: border-color 0.2s;
    }

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
      text-align: center;
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
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://i.imgur.com/ngS2ybs.png" alt="Mess Monster" class="monster-image">
      <h1>Router Setup</h1>
      <p class="subtitle">Enter your email to configure this router</p>
    </div>
    <form method="post" action="">
      <div class="form-group">
        <label for="email">Parent's Email Address</label>
        <input type="email" name="email" id="email" required placeholder="Enter your email">
      </div>
      <input type="submit" value="Configure Router">
    </form>
  </div>
</body>
</html>
EOF
    exit 0
fi

# If the request method is POST, process the setup.
if [ "$REQUEST_METHOD" = "POST" ]; then
    # Read POST data from stdin using CONTENT_LENGTH.
    read -n "$CONTENT_LENGTH" POST_DATA

    # Initialize variables.
    email=""

    # Parse POST data (assumes application/x-www-form-urlencoded).
    for pair in $(echo "$POST_DATA" | tr '&' '\n'); do
        key=$(echo "$pair" | cut -d '=' -f1)
        value=$(echo "$pair" | cut -d '=' -f2-)
        value=$(urldecode "$value")
        case "$key" in
            email)
                email="$value"
                ;;
        esac
    done

    # Get router's MAC address for identification
    router_mac=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null)
    [ -z "$router_mac" ] && router_mac="unknown"

    # Send the data to the server using curl
    SERVER_URL="http://messmonsters.kunovo.ai:3456/api/routers/setup"
    
    # Create JSON payload
    json_data=$(printf '{"email":"%s","router_mac":"%s"}' "$email" "$router_mac")
    
    # Send the request to the server
    echo "Sending request to $SERVER_URL with payload: $json_data" >&2
    response=$(curl -s -X POST -H "Content-Type: application/json" -d "$json_data" "$SERVER_URL")
    echo "Received response: $response" >&2
    
    # Extract error message if any
    error_message=$(extract_error "$response")
    
    # Check if the request was successful
    if echo "$response" | grep -q '"success":true'; then
        # Extract household ID
        household_id=$(extract_household_id "$response")
        
        # Create config directory if it doesn't exist
        mkdir -p /etc/mess-monsters
        
        # Create config file
        cat > /etc/mess-monsters/config.json <<EOF
{
  "household_id": "$household_id",
  "server_url": "http://messmonsters.kunovo.ai:3456",
  "check_interval": 300,
  "fast_speed": "50mbit",
  "slow_speed": "512kbit"
}
EOF
        
        cat <<EOF
<html>
<head>
  <title>Setup Successful - Mess Monsters</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    /* Same styles as above */
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://imgur.com/U8efVMW.png" alt="Happy Monster" class="monster-image">
      <h1>Setup Successful!</h1>
    </div>
    <div class="success">Your router has been configured successfully!</div>
    <div class="details">
      <p>Household ID: ${household_id}</p>
      <p>You can now register devices for your household.</p>
    </div>
  </div>
</body>
</html>
EOF
    else
        # Determine the specific error message to display
        case "$error_message" in
            "Email not found")
                error_display="The email address you entered is not registered in our system. Please check your email or contact support."
                ;;
            "Invalid payload")
                error_display="There was a problem with the setup data. Please try again."
                ;;
            "Internal server error")
                error_display="Our server is experiencing issues. Please try again later."
                ;;
            *)
                error_display="Unable to configure your router. Please try again later."
                ;;
        esac

        cat <<EOF
<html>
<head>
  <title>Setup Failed - Mess Monsters</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    /* Same styles as above */
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://i.imgur.com/Jx8xm6j.png" alt="Sad Monster" class="monster-image">
      <h1>Setup Failed</h1>
    </div>
    <div class="error">${error_display}</div>
    <div class="details">
      <p>Error details: ${error_message}</p>
      <p>Please check your email address and try again.</p>
    </div>
    <a href="setup.cgi" class="button">Try Again</a>
  </div>
</body>
</html>
EOF
    fi
fi 