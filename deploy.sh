#!/bin/bash
set -euo pipefail

# Production script to deploy fleet_agent to an target node
# Usage: ./deploy.sh <user@hostname>

if [ -z "${1-}" ]; then
  echo "Usage: $0 <user@hostname>"
  exit 1
fi

TARGET=$1
BIN_PATH="/home/curious/antimony-labs-org/fleet/target/x86_64-unknown-linux-musl/release/fleet_agent"
PRIVATE_KEY_PATH="/home/curious/antimony-labs-org/core/fleet_api/private_key.pem"

USER_TARGET="curious@$TARGET"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: Binary not found at $BIN_PATH. Run cargo build --release first."
    exit 1
fi

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo "Error: Private key not found at $PRIVATE_KEY_PATH."
    exit 1
fi

echo "Deploying to $TARGET..."

# 1. Copy the binary
echo "Copying binary..."
scp -o StrictHostKeyChecking=accept-new "$BIN_PATH" "$TARGET:/tmp/fleet_agent"
ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "sudo mv /tmp/fleet_agent /usr/local/bin/fleet_agent && sudo chown root:root /usr/local/bin/fleet_agent && sudo chmod +x /usr/local/bin/fleet_agent"

# 2. Copy the private key securely directly to /etc/fleet_agent/
echo "Copying private key..."
ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "sudo mkdir -p /etc/fleet_agent && sudo chown root:root /etc/fleet_agent && sudo chmod 700 /etc/fleet_agent"
scp -o StrictHostKeyChecking=accept-new "$PRIVATE_KEY_PATH" "$TARGET:/tmp/private_key.pem"
ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "sudo mv /tmp/private_key.pem /etc/fleet_agent/private_key.pem && sudo chown root:root /etc/fleet_agent/private_key.pem && sudo chmod 600 /etc/fleet_agent/private_key.pem"

# 3. Create the wrapper script to load the multi-line PEM properly
echo "Creating wrapper script..."
ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "cat << 'EOF' > /tmp/fleet_agent_wrapper.sh
#!/bin/bash
export FLEET_PRIVATE_KEY=\"\$(sudo cat /etc/fleet_agent/private_key.pem)\"
export FLEET_NODE_NAME=\"$TARGET\"
exec /usr/local/bin/fleet_agent
EOF"

ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "sudo mv /tmp/fleet_agent_wrapper.sh /usr/local/bin/fleet_agent_wrapper.sh && sudo chmod +x /usr/local/bin/fleet_agent_wrapper.sh"

# 3. Create the systemd service
echo "Creating systemd service..."
cat << 'EOF' > /tmp/fleet-agent.service
[Unit]
Description=Antimony Labs Fleet Telemetry Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/fleet_agent_wrapper.sh
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

scp -o StrictHostKeyChecking=accept-new /tmp/fleet-agent.service "$TARGET:/tmp/fleet-agent.service"
ssh -o StrictHostKeyChecking=accept-new -t "$TARGET" "sudo mv /tmp/fleet-agent.service /etc/systemd/system/fleet-agent.service && sudo systemctl daemon-reload && sudo systemctl enable --now fleet-agent.service && sudo systemctl status fleet-agent.service --no-pager"

echo "Deployed successfully to $TARGET"
