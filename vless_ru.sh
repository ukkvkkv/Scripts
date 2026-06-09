#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

get_public_ip() { curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }

PARAMS="/root/params.env"
if [[ -f "$PARAMS" ]]; then source "$PARAMS"; else
  read -rp "EU_IP: " EU_IP
  read -rp "EU_VLESS_PORT: " EU_VLESS_PORT
  read -rp "EU_VLESS_UUID: " EU_VLESS_UUID
  read -rp "EU_PUBLIC_KEY: " EU_PUBLIC_KEY
  read -rp "EU_SHORT_ID: " EU_SHORT_ID
  read -rp "EU_SNI: " EU_SNI
  read -rp "EU_NETWORK: " EU_NETWORK
  read -rp "EU_FLOW: " EU_FLOW
  read -rp "MT_PORT: " MT_PORT
  read -rp "MT_SECRET: " MT_SECRET
fi

read -rp "RU SNI (default www.google.com): " RU_SNI
RU_SNI="${RU_SNI,,:-www.google.com}"

apt update -y >/dev/null 2>&1
apt install -y curl wget jq openssl >/dev/null 2>&1

bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install >/dev/null 2>&1

RU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)
RU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
RU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
RU_SHORT_ID=$(openssl rand -hex 8)

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "vless-ru-in", "port": $EU_VLESS_PORT, "protocol": "vless",
      "settings": { "clients": [{"id":"$RU_UUID","flow":"xtls-rprx-vision"}], "decryption":"none" },
      "streamSettings": { "network":"xhttp", "security":"reality", "realitySettings": {"serverNames":["$RU_SNI"],"privateKey":"$RU_PRIVATE_KEY","shortIds":["$RU_SHORT_ID"]} }
    },
    {
      "tag": "mtproto-in", "port": $MT_PORT, "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": $MT_PORT, "network": "tcp,udp" }
    }
  ],
  "outbounds": [
    { "tag": "vless-to-eu", "protocol": "vless", "settings": { "vnext": [{"address":"$EU_IP","port":$EU_VLESS_PORT,"users":[{"id":"$EU_VLESS_UUID","flow":"$EU_FLOW"}]}] }, "streamSettings": { "network":"$EU_NETWORK","security":"reality","realitySettings":{"serverName":"$EU_SNI","fingerprint":"firefox","publicKey":"$EU_PUBLIC_KEY","shortId":"$EU_SHORT_ID"} } },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["domain:ru","domain:рф","domain:su"], "outboundTag": "direct" },
      { "type": "field", "inboundTag": ["vless-ru-in"], "outboundTag": "vless-to-eu" },
      { "type": "field", "inboundTag": ["mtproto-in"], "outboundTag": "vless-to-eu" }
    ]
  }
}
EOF

systemctl enable --now xray
systemctl restart xray

PUBLIC_IP=$(get_public_ip)

VLESS_LINK="vless://$RU_UUID@$PUBLIC_IP:$EU_VLESS_PORT?type=xhttp&security=reality&pbk=$RU_PUBLIC_KEY&sid=$RU_SHORT_ID&sni=$RU_SNI&flow=xtls-rprx-vision&fp=firefox#VLESS-Multihop"
MT_LINK="tg://proxy?server=$PUBLIC_IP&port=$MT_PORT&secret=$MT_SECRET"

printf '\033[0;32m%s\033[0m\n' "$VLESS_LINK"
printf '\033[0;32m%s\033[0m\n' "$MT_LINK"

curl -fsSL https://raw.githubusercontent.com/ukkvkkv/Scripts/main/add-vless -o /usr/local/bin/add-vless 2>/dev/null
chmod +x /usr/local/bin/add-vless 2>/dev/null

rm -f "$PARAMS" 2>/dev/null
