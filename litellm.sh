#!/usr/bin/env bash

# LiteLLM Proxmox VE Container Script
# License: MIT
# Source: https://docs.litellm.ai/

# Define variables with defaults
APP="LiteLLM"
CTID=""
ECHO="/bin/echo"
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m' # No Color

# Function to display colored text
function msg() {
  local color="$1"
  local text="$2"
  $ECHO -e "${color}${text}${C_NC}"
}

function msg_info() {
  local text="$1"
  msg "${C_BLUE}[INFO]${C_NC} ${text}"
}

function msg_ok() {
  local text="$1"
  msg "${C_GREEN}[OK]${C_NC} ${text}"
}

function msg_error() {
  local text="$1"
  msg "${C_RED}[ERROR]${C_NC} ${text}"
}

function check_dependencies() {
  which pveversion >/dev/null 2>&1 || { msg_error "This script requires Proxmox VE to run. Exiting..."; exit 1; }
  which pvesm >/dev/null 2>&1 || { msg_error "Unable to detect Proxmox storage manager. Exiting..."; exit 1; }
  which pct >/dev/null 2>&1 || { msg_error "Unable to detect Proxmox container tools. Exiting..."; exit 1; }
}

function get_storage_type() {
  local storage_name="$1"
  local storage_type=$(pvesm status -storage "$storage_name" 2>/dev/null | awk 'NR>1 {print $2}')
  echo "$storage_type"
}

function create_container() {
  msg_info "Creating LXC Container..."
  
  # Get the next available container ID
  CTID=$(pvesh get /cluster/nextid)
  
  # Set up storage location with local-lvm as default
  local STORAGE_LOCATION="local-lvm"
  local storage_list=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
  
  if [ -z "$storage_list" ]; then
    msg_error "No valid storage locations found."
    exit 1
  fi
  
  $ECHO -e "${C_YELLOW}Available storage locations:${C_NC}"
  $ECHO "$storage_list"
  $ECHO -e "${C_GREEN}Using default storage: $STORAGE_LOCATION${C_NC}"
  read -p "Change storage location? (y/n) [default: n]: " change_storage
  
  if [[ "$change_storage" =~ ^[Yy]$ ]]; then
    read -p "Enter storage location: " custom_storage
    if [ ! -z "$custom_storage" ]; then
      # Check if the entered storage exists
      if echo "$storage_list" | grep -q "$custom_storage"; then
        STORAGE_LOCATION="$custom_storage"
      else
        msg_error "Invalid storage location. Using default: $STORAGE_LOCATION"
      fi
    fi
  fi
  
  # Check storage type
  local STORAGE_TYPE=$(get_storage_type $STORAGE_LOCATION)
  if [ -z "$STORAGE_TYPE" ]; then
    msg_error "Invalid storage selected."
    exit 1
  fi
  
  # Default settings
  local ARCH="amd64"
  local MEMORY="2048"
  local SWAP="512"
  local DISK_SIZE="8"  # Just the number for LVM storage
  local CPU="2"
  local HOSTNAME="litellm"
  local PASSWORD=""
  
  # Ask if user wants custom settings
  read -p "Use default container settings? (y/n): " use_default
  if [[ "$use_default" =~ ^[Nn]$ ]]; then
    read -p "CPU cores (default: 2): " custom_cpu
    read -p "Memory in MB (default: 2048): " custom_memory
    read -p "Disk size in GB (default: 8): " custom_disk
    read -p "Hostname (default: litellm): " custom_hostname
    
    # Update with custom settings if provided
    [[ ! -z "$custom_cpu" ]] && CPU="$custom_cpu"
    [[ ! -z "$custom_memory" ]] && MEMORY="$custom_memory"
    [[ ! -z "$custom_disk" ]] && DISK_SIZE="$custom_disk"
    [[ ! -z "$custom_hostname" ]] && HOSTNAME="$custom_hostname"
  fi
  
  # Generate a random password or ask for one (required)
  while true; do
    read -p "Set container root password: " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
      echo -e "${C_YELLOW}Password is required.${C_NC}"
    else
      break
    fi
  done
  
  # Choose network configuration
  local BRIDGE="vmbr0"
  read -p "Network bridge (default: vmbr0): " custom_bridge
  [[ ! -z "$custom_bridge" ]] && BRIDGE="$custom_bridge"
  
  # Choose IP configuration (DHCP or static)
  read -p "Use DHCP for IP configuration? (y/n): " use_dhcp
  local NET_CONFIG=""
  if [[ "$use_dhcp" =~ ^[Nn]$ ]]; then
    read -p "IP address (CIDR format, e.g., 192.168.1.100/24): " IP_CIDR
    read -p "Gateway IP: " GATEWAY
    NET_CONFIG="ip=${IP_CIDR},gw=${GATEWAY}"
  else
    NET_CONFIG="ip=dhcp"
  fi
  
  # Create the container
  msg_info "Creating container with ID: $CTID"
  
  # Download the Debian template if not already present
  local TEMPLATE_PATH="/var/lib/vz/template/cache/debian-12-standard_12.*_amd64.tar.zst"
  if [ ! -f $TEMPLATE_PATH ]; then
    msg_info "Downloading Debian 12 template..."
    pveam update
    pveam download local debian-12-standard_12.2-1_amd64.tar.zst
  fi
  
  # Get the actual template file
  TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_12.*_amd64.tar.zst | sort -V | tail -n1)
  
  # Create the container with the specified settings
  # For LVM storage, add G suffix if using local-lvm
  if [[ "$STORAGE_LOCATION" == "local-lvm" ]]; then
    pct create $CTID $TEMPLATE \
      -hostname $HOSTNAME \
      -cores $CPU \
      -memory $MEMORY \
      -swap $SWAP \
      -rootfs $STORAGE_LOCATION:${DISK_SIZE} \
      -net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG \
      -features nesting=1 \
      -password "$PASSWORD" \
      -unprivileged 1
  else
    # For other storage types, add G suffix
    pct create $CTID $TEMPLATE \
      -hostname $HOSTNAME \
      -cores $CPU \
      -memory $MEMORY \
      -swap $SWAP \
      -rootfs $STORAGE_LOCATION:${DISK_SIZE}G \
      -net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG \
      -features nesting=1 \
      -password "$PASSWORD" \
      -unprivileged 1
  fi
  
  if [ $? -ne 0 ]; then
    msg_error "Failed to create container."
    exit 1
  fi
  
  # Set a description for the container
  pct set $CTID -description "LiteLLM Proxy Server - OpenAI compatible API"
  
  msg_ok "Container created successfully."
  
  # Start the container
  msg_info "Starting the container..."
  pct start $CTID
  if [ $? -ne 0 ]; then
    msg_error "Failed to start container."
    exit 1
  fi
  sleep 5  # Give it some time to start up
  
  # Install LiteLLM
  install_litellm
}

function install_litellm() {
  msg_info "Installing LiteLLM in container $CTID..."
  
  # Create the installation script
  cat > /tmp/litellm_install.sh << 'EOF'
#!/bin/bash

# Update system
apt-get update
apt-get upgrade -y

# Install dependencies
apt-get install -y curl gnupg ca-certificates python3 python3-pip python3-venv python3-full git build-essential

# Create virtual environment for LiteLLM
mkdir -p /opt/litellm
python3 -m venv /opt/litellm/venv

# Activate virtual environment and install LiteLLM
source /opt/litellm/venv/bin/activate
pip install --upgrade pip
pip install 'litellm[proxy]'

# Create config file
cat <<'EOT' > /opt/litellm/config.yaml
model_list:
  - model_name: gpt-3.5-turbo
    litellm_params:
      model: gpt-3.5-turbo

# Uncomment and modify for your specific needs
# router_settings:
#   redis_host: your_redis_host
#   redis_password: your_redis_password
#   redis_port: 6379
EOT

# Set permissions
chmod 600 /opt/litellm/config.yaml

# Create .env file for keys
cat <<'EOT' > /opt/litellm/.env
LITELLM_MASTER_KEY="sk-litellm-changeme"
LITELLM_SALT_KEY="sk-litellm-changeme-salt"
EOT

chmod 600 /opt/litellm/.env

# Create systemd service with correct path to virtual environment
cat <<'EOT' > /etc/systemd/system/litellm.service
[Unit]
Description=LiteLLM Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/litellm
ExecStart=/opt/litellm/venv/bin/python -m litellm --port 4000 --config /opt/litellm/config.yaml --num_workers 2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOT

# Enable and start service
systemctl daemon-reload
systemctl enable litellm.service
systemctl start litellm.service

# Check service status
SERVICE_STATUS=$(systemctl is-active litellm)
if [ "$SERVICE_STATUS" != "active" ]; then
  echo "LiteLLM service failed to start. Check logs with: journalctl -u litellm"
  echo "Service status: $(systemctl status litellm | grep 'Active:')"
  exit 1
fi

# Display MOTD for info
IP=$(hostname -I | awk '{print $1}')
cat <<EOT > /etc/motd

─────────────────────────────────────────────────────────
    LiteLLM Proxy Server
─────────────────────────────────────────────────────────
    API Endpoint : http://${IP}:4000
    Documentation: https://docs.litellm.ai/docs/proxy
─────────────────────────────────────────────────────────
 The config is located at: /opt/litellm/config.yaml
 API Keys are managed in: /opt/litellm/.env
─────────────────────────────────────────────────────────
 To generate a new API key:
 curl -X POST http://${IP}:4000/key/generate \
  -H "Authorization: Bearer sk-litellm-changeme" \
  -H "Content-Type: application/json" \
  -d '{"models": ["gpt-3.5-turbo"], "duration": "365d"}'
─────────────────────────────────────────────────────────
 To test the API:
 curl -X POST http://${IP}:4000/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-litellm-changeme" \
  -d '{"model": "gpt-3.5-turbo", "messages": [{"role": "user", "content": "Hello"}]}'
─────────────────────────────────────────────────────────
 Management commands:
 litellm-manage status  - Check service status
 litellm-manage restart - Restart the service
 litellm-manage logs    - View service logs
 litellm-manage update  - Update LiteLLM
─────────────────────────────────────────────────────────
EOT

# Install a simple management script
cat <<'EOT' > /usr/local/bin/litellm-manage
#!/bin/bash
case "$1" in
  restart)
    systemctl restart litellm
    echo "LiteLLM service restarted."
    ;;
  stop)
    systemctl stop litellm
    echo "LiteLLM service stopped."
    ;;
  start)
    systemctl start litellm
    echo "LiteLLM service started."
    ;;
  status)
    systemctl status litellm
    ;;
  logs)
    journalctl -u litellm -f
    ;;
  update)
    systemctl stop litellm
    source /opt/litellm/venv/bin/activate
    pip install 'litellm[proxy]' --upgrade
    systemctl start litellm
    echo "LiteLLM updated and restarted."
    ;;
  *)
    echo "Usage: $0 {restart|stop|start|status|logs|update}"
    exit 1
    ;;
esac
exit 0
EOT

chmod +x /usr/local/bin/litellm-manage

# Return the IP for display
hostname -I | awk '{print $1}'
EOF

  # Make the script executable and transfer to the container
  chmod +x /tmp/litellm_install.sh
  pct push $CTID /tmp/litellm_install.sh /tmp/litellm_install.sh
  
  # Execute the installation script in the container
  msg_info "Running installation script inside container..."
  local CONTAINER_IP=$(pct exec $CTID -- bash /tmp/litellm_install.sh)
  
  # Cleanup
  rm -f /tmp/litellm_install.sh
  pct exec $CTID -- rm -f /tmp/litellm_install.sh
  
  msg_ok "LiteLLM installation completed!"
  
  # Display access information
  $ECHO -e "\n${C_GREEN}LiteLLM Proxy Server is now installed!${C_NC}"
  $ECHO -e "${C_YELLOW}Access the API at:${C_NC} http://$CONTAINER_IP:4000"
  $ECHO -e "${C_YELLOW}Default API Key:${C_NC} sk-litellm-changeme"
  $ECHO -e "${C_YELLOW}Container ID:${C_NC} $CTID"
  $ECHO -e "${C_YELLOW}Container Password:${C_NC} $PASSWORD"
  $ECHO -e "\n${C_BLUE}Login instructions:${C_NC}"
  $ECHO -e "1. Connect to the container: ${C_GREEN}pct enter $CTID${C_NC}"
  $ECHO -e "2. Login with username ${C_GREEN}root${C_NC} and your password"
  $ECHO -e "\n${C_BLUE}Management commands (inside container):${C_NC}"
  $ECHO -e "- Check service status: ${C_GREEN}litellm-manage status${C_NC}"
  $ECHO -e "- View service logs: ${C_GREEN}litellm-manage logs${C_NC}"
  $ECHO -e "- Restart service: ${C_GREEN}litellm-manage restart${C_NC}"
  $ECHO -e "- Edit config: ${C_GREEN}nano /opt/litellm/config.yaml${C_NC}"
  $ECHO -e "\n${C_BLUE}For more details, log into the container and check the welcome message.${C_NC}"
}

# Main script execution
clear
$ECHO -e "${C_GREEN}╔════════════════════════════════════════╗${C_NC}"
$ECHO -e "${C_GREEN}║      LiteLLM Proxmox VE Installer      ║${C_NC}"
$ECHO -e "${C_GREEN}╚════════════════════════════════════════╝${C_NC}"
$ECHO -e "This script will create a Proxmox container and install LiteLLM.\n"

check_dependencies
create_container

exit 0
