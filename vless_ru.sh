#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

get_public_ip() {
  curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

random_port() {
  shuf -i 20000-60000 -n 1
}

PARAMS="/root/eu-params.env"
if [[ -f "$PARAMS" ]]; then
  source "$PARAMS"
else
  read -rp "EU_IP: " EU_IP
  read -rp "EU_PORT: " EU_PORT
  read -rp "EU_UUID: " EU_UUID
  read -rp "EU_PUBLIC_KEY: " EU_PUBLIC_KEY
  read -rp "EU_SHORT_ID: " EU_SHORT_ID
  read -rp "EU_SNI: " EU_SERVER_NAME
  read -rp "EU_NETWORK: " EU_NETWORK
  read -rp "EU_FLOW: " EU_FLOW
fi

read -rp "SNI domain (default: www.google.com): " RU_DOMAIN
RU_DOMAIN="${RU_DOMAIN,,:-www.google.com}"

RU_PORT=$(random_port)

apt update -y >/dev/null 2>&1
apt install -y curl wget jq openssl >/dev/null 2>&1

bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install >/dev/null 2>&1

RU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)
RU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
RU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
RU_SHORT_ID=$(openssl rand -hex 8)
FP="firefox"

if [[ -f /usr/local/etc/xray/config.json ]]; then
  cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.backup.$(date +%F)"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "tag": "vless-ru-in", "listen": "0.0.0.0", "port": $RU_PORT, "protocol": "vless",
    "settings": { "clients": [ { "id": "$RU_UUID", "email": "multihop@ru", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
    "streamSettings": { "network": "xhttp", "security": "reality", "realitySettings": { "show": false, "dest": "$RU_DOMAIN:443", "xver": 0, "serverNames": ["$RU_DOMAIN"], "privateKey": "$RU_PRIVATE_KEY", "shortIds": ["$RU_SHORT_ID"] }, "sockopt": { "tcpFastOpen": true }
  }],
  "outbounds": [{
    "tag": "vless-to-eu", "protocol": "vless",
    "settings": { "vnext": [ { "address": "$EU_IP", "port": $EU_PORT, "users": [ { "id": "$EU_UUID", "encryption": "none", "flow": "$EU_FLOW" } ] } ] },
    "streamSettings": { "network": "$EU_NETWORK", "security": "reality", "realitySettings": { "serverName": "$EU_SERVER_NAME", "fingerprint": "$FP", "publicKey": "$EU_PUBLIC_KEY", "shortId": "$EU_SHORT_ID", "spiderX": "/" }, "sockopt": { "tcpFastOpen": true } }
  },
  { "tag": "direct", "protocol": "freedom" },
  { "tag": "block", "protocol": "blackhole" } ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["domain:ru", "domain:рф", "domain:su"], "outboundTag": "direct" },
      { "type": "field", "inboundTag": ["vless-ru-in"], "outboundTag": "vless-to-eu" }
    ]
  }
}
EOF

systemctl enable --now xray >/dev/null 2>&1
systemctl restart xray

PUBLIC_IP=$(get_public_ip)

CLIENT_LINK="vless://$RU_UUID@$PUBLIC_IP:$RU_PORT?type=xhttp&security=reality&pbk=$RU_PUBLIC_KEY&sid=$RU_SHORT_ID&sni=$RU_DOMAIN&flow=xtls-rprx-vision&fp=$FP#VLESS-Multihop"

# Clean green link output
printf '\033[0;32m%s\033[0m\n' "$CLIENT_LINK"

# Install add-vless
curl -fsSL https://raw.githubusercontent.com/ukkvkkv/Scripts/main/add-vless -o /usr/local/bin/add-vless 2>/dev/null
chmod +x /usr/local/bin/add-vless 2>/dev/null

if [[ -f "$PARAMS" ]]; then
  rm -f "$PARAMS" 2>/dev/null
fi
