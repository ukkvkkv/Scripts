#!/usr/bin/env bash
set -e

echo "=== RU VLESS + MTProto Multihop (простая версия) ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужно запускать от root"
  exit 1
fi

# Спрашиваем параметры EU
read -rp "EU IP: " EU_IP
read -rp "EU VLESS Port: " EU_VLESS_PORT
read -rp "EU VLESS UUID: " EU_VLESS_UUID
read -rp "EU PublicKey: " EU_PUBLIC_KEY
read -rp "EU ShortID: " EU_SHORT_ID
read -rp "EU SNI: " EU_SNI
read -rp "EU Flow (обычно xtls-rprx-vision): " EU_FLOW
EU_FLOW="${EU_FLOW:-xtls-rprx-vision}"

read -rp "MTProto Port (с EU): " MT_PORT
read -rp "MTProto Secret (с EU): " MT_SECRET

read -rp "RU SNI (нажми Enter для www.google.com): " RU_SNI
RU_SNI="${RU_SNI:-www.google.com}"

apt update
apt install -y curl wget jq openssl

# Установка Xray
if ! command -v xray >/dev/null 2>&1; then
  echo "Ставим Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

export PATH=$PATH:/usr/local/bin

RU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)

if echo "$KEYS" | grep -q "PrivateKey:"; then
  RU_PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | head -n1 | awk '{print $2}')
  RU_PUBLIC_KEY=$(echo "$KEYS" | grep "Password (PublicKey):" | head -n1 | awk '{print $3}')
else
  RU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
  RU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
fi

RU_SHORT_ID=$(openssl rand -hex 8)

# Создаём конфиг Xray с докодемо-дор для MTProto
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "vless-ru-in",
      "port": $EU_VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$RU_UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "dest": "$RU_SNI:443",
          "serverNames": ["$RU_SNI"],
          "privateKey": "$RU_PRIVATE_KEY",
          "shortIds": ["$RU_SHORT_ID"]
        }
      }
    },
    {
      "tag": "mtproto-in",
      "port": $MT_PORT,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": $MT_PORT, "network": "tcp,udp" }
    }
  ],
  "outbounds": [
    {
      "tag": "vless-to-eu",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$EU_IP",
          "port": $EU_VLESS_PORT,
          "users": [{ "id": "$EU_VLESS_UUID", "encryption": "none", "flow": "$EU_FLOW" }]
        }]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "serverName": "$EU_SNI",
          "fingerprint": "firefox",
          "publicKey": "$EU_PUBLIC_KEY",
          "shortId": "$EU_SHORT_ID"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["domain:ru", "domain:рф", "domain:su"], "outboundTag": "direct" },
      { "type": "field", "inboundTag": ["vless-ru-in"], "outboundTag": "vless-to-eu" },
      { "type": "field", "inboundTag": ["mtproto-in"], "outboundTag": "vless-to-eu" }
    ]
  }
}
EOF

systemctl restart xray

echo "Xray настроен (VLESS + MTProto multihop)"

PUBLIC_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

VLESS_LINK="vless://$RU_UUID@$PUBLIC_IP:$EU_VLESS_PORT?type=xhttp&security=reality&pbk=$RU_PUBLIC_KEY&sid=$RU_SHORT_ID&sni=$RU_SNI&flow=xtls-rprx-vision&fp=firefox#RU-Multihop"
MT_LINK="tg://proxy?server=$PUBLIC_IP&port=$MT_PORT&secret=$MT_SECRET"

echo ""
echo "=== RU ГОТОВ ==="
echo "VLESS ссылка:"
echo "$VLESS_LINK"
echo ""
echo "MTProto ссылка:"
echo "$MT_LINK"
