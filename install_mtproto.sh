#!/bin/bash
set -e

apt-get update -y >/dev/null 2>&1
apt-get upgrade -y >/dev/null 2>&1
apt-get install -y python3 git curl ufw >/dev/null 2>&1

rm -rf /opt/mtprotoproxy
mkdir -p /opt/mtprotoproxy
cd /opt/mtprotoproxy
git clone https://github.com/alexbers/mtprotoproxy.git . >/dev/null 2>&1

cat > config.py << 'EOF'
PORT = 50373
USERS = {
    "main": "ee4cccf41e903698ce83ffe48da55aa65b7777772e766b2e636f6d"
}
TLS_DOMAIN = "vk.com"
MODES = { "classic": True, "secure": True, "tls": True }
EOF

cat > /etc/systemd/system/mtprotoproxy.service << 'EOF'
[Unit]
Description=MTProto Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/mtprotoproxy
ExecStart=/usr/bin/python3 /opt/mtprotoproxy/mtprotoproxy.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable mtprotoproxy >/dev/null 2>&1
systemctl restart mtprotoproxy >/dev/null 2>&1

ufw allow 50373/tcp >/dev/null 2>&1 || true

IP=$(curl -4s https://ifconfig.me || curl -4s https://api.ipify.org || echo "IP_NOT_DETECTED")

echo "tg://proxy?server=$IP&port=50373&secret=ee4cccf41e903698ce83ffe48da55aa65b7777772e766b2e636f6d"