#!/bin/bash
# Mieru (mita) one-click installer
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Установка Mieru...${NC}"

sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq curl wget openssl chrony iproute2 >/dev/null 2>&1
sudo systemctl enable --now chrony >/dev/null 2>&1 || true

LATEST_VERSION=$(curl -s --max-time 8 https://api.github.com/repos/enfein/mieru/releases/latest | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "3.34.0")
[ -z "$LATEST_VERSION" ] && LATEST_VERSION="3.34.0"

ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == "amd64" ]] && DEB_FILE="mita_${LATEST_VERSION}_amd64.deb" || DEB_FILE="mita_${LATEST_VERSION}_arm64.deb"

cd /tmp
curl -LS --max-time 30 -o "${DEB_FILE}" "https://github.com/enfein/mieru/releases/download/v${LATEST_VERSION}/${DEB_FILE}" >/dev/null 2>&1
sudo dpkg -i "${DEB_FILE}" >/dev/null 2>&1 || sudo apt-get install -f -y -qq >/dev/null 2>&1
rm -f "${DEB_FILE}"

sudo usermod -aG mita "$USER" >/dev/null 2>&1 || true

USERNAME="u$(openssl rand -hex 5)"
PASSWORD=$(openssl rand -base64 28 | tr -d '/+=' | cut -c1-24)

PORT=443
if ss -tlnp 2>/dev/null | grep -q ":443 "; then
    echo -e "${YELLOW}⚠️ Порт 443 занят${NC}"
fi

cat > /tmp/mita_config.json <<EOF
{
  "portBindings": [{"port": 443, "protocol": "TCP"}],
  "users": [{"name": "${USERNAME}", "password": "${PASSWORD}"}],
  "loggingLevel": "ERROR",
  "mtu": 1400
}
EOF

sg mita -c "
    mita apply config /tmp/mita_config.json >/dev/null 2>&1 || true
    mita start >/dev/null 2>&1 || true
" 2>/dev/null || true

sudo systemctl enable mita >/dev/null 2>&1 || true

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}' || echo "YOUR_VPS_IP")

MIERU_LINK="mierus://${USERNAME}:${PASSWORD}@${SERVER_IP}?transport=tcp&port=443&profile=見える"

echo ""
echo -e "${GREEN}Готово${NC}"
echo ""
echo "${MIERU_LINK}"
echo ""
