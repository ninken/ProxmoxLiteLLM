#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2025
# License: MIT
# Source: https://docs.litellm.ai/

APP="LiteLLM"
var_tags="${var_tags:-ai;llm;proxy}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_install="${var_install:-litellm}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /etc/systemd/system/litellm.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  
  msg_info "Stopping ${APP}"
  systemctl stop litellm
  
  msg_info "Updating Dependencies"
  $STD apt-get update
  $STD apt-get upgrade -y
  msg_ok "Updated Dependencies"
  
  msg_info "Updating ${APP}"
  $STD pip3 install --upgrade pip
  $STD pip3 install 'litellm[proxy]' --upgrade
  msg_ok "Updated ${APP}"
  
  msg_info "Starting ${APP}"
  systemctl start litellm
  msg_ok "Started ${APP}"
  
  msg_info "Cleaning Up"
  $STD apt-get autoremove -y
  $STD apt-get autoclean -y
  msg_ok "Cleaned Up"
  
  msg_ok "Update Completed"
  echo -e "\n"
  exit
}

start
build_container

cat <<EOF > /var/lib/vz/snippets/litellm.sh
#!/usr/bin/env bash

# Install dependencies
apt-get update
apt-get install -y curl gnupg ca-certificates python3 python3-pip python3-venv git build-essential

# Install LiteLLM
pip3 install --upgrade pip
pip3 install 'litellm[proxy]'

# Create configuration directory
mkdir -p /opt/litellm

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

# Create systemd service
cat <<'EOT' > /etc/systemd/system/litellm.service
[Unit]
Description=LiteLLM Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/litellm
ExecStart=/usr/bin/python3 -m litellm --port 4000 --config /opt/litellm/config.yaml --num_workers 2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOT

# Enable and start service
systemctl daemon-reload
systemctl enable litellm.service
systemctl start litellm.service

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
    pip3 install 'litellm[proxy]' --upgrade
    systemctl restart litellm
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
EOF

description=$(cat << EOF
LiteLLM Proxy LXC
(${var_os} ${var_version})
- Provides a standard OpenAI-compatible API interface
- Supports multiple LLM providers
- Features routing, fallbacks, caching & more

Default API Key: sk-litellm-changeme
EOF
)

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} LXC setup has been completed!${CL}"
echo -e "${INFO}${YW}The API is accessible at:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:4000${CL}"
echo -e "${INFO}${YW}Default API key:${CL}"
echo -e "${TAB}${BGN}sk-litellm-changeme${CL}"
