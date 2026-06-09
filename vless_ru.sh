#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
get_public_ip() {
  for url in "https://api.ipify.org" "https://ifconfig.me"; do
    ip=$(curl -4fsSL --max-time 8 "$url" 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  hostname -I | awk '{print $1}'
}

port_in_use() {
  ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${p}$"
}

random_port() {
  for _ in {1..100}; do
    p=$(shuf -i 20000-60000 -n 1)
    ! port_in_use "$p" && { echo "$p"; return 0; }
  done
  echo "Нет свободного порта" >&2; exit 1
}

echo "=== Установка RU Xray VLESS entry (XHTTP + Reality) с выходом на EU ==="

PARAMS="/root/eu-params.env"
if [[ -f "$PARAMS" ]]; then
  source "$PARAMS"
  echo "Параметры EU загружены автоматически"
else
  read -rp "EU_IP: " EU_IP
  read -rp "EU_PORT: " EU_PORT
  read -rp "EU_UUID: " EU_UUID
  read -rp "EU_PUBLIC_KEY: " EU_PUBLIC_KEY
  read -rp "EU_SHORT_ID: " EU_SHORT_ID
  read -rp "EU_SERVER_NAME (SNI): " EU_SERVER_NAME
  read -rp "EU_NETWORK (raw): " EU_NETWORK
  read -rp "EU_FLOW: " EU_FLOW
fi

read -rp "Домен RU (опционально для SNI, Enter = www.google.com): " RU_DOMAIN
RU_DOMAIN="${RU_DOMAIN,,}"
[[ -z "$RU_DOMAIN" ]] && RU_DOMAIN="www.google.com"

RU_PORT=$(random_port)

apt update -y
apt install -y curl wget jq openssl

bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install

RU_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "Генерация Reality ключей RU..."
KEYS=$(xray x25519)
RU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
RU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
RU_SHORT_ID=$(openssl rand -hex 8)

# Fingerprint choice
 echo "Fingerprint для Reality (RKN ломает Chrome):"
 echo "1) firefox (рекомендую)"
 echo "2) random"
 echo "3) chrome"
 read -rp "Выбор (1-3): " FP_CHOICE
case $FP_CHOICE in
  2) FP="random" ;;
  3) FP="chrome" ;;
  *) FP="firefox" ;;
esac

if [[ -f /usr/local/etc/xray/config.json ]]; then
  cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.backup.$(date +%F_%T)"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-ru-in",
      "listen": "0.0.0.0",
      "port": $RU_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$RU_UUID", "email": "multihop@ru", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$RU_DOMAIN:443",
          "xver": 0,
          "serverNames": ["$RU_DOMAIN"],
          "privateKey": "$RU_PRIVATE_KEY",
          "shortIds": ["$RU_SHORT_ID"]
        },
        "sockopt": { "tcpFastOpen": true }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    {
      "tag": "vless-to-eu",
      "protocol": "vless",
      "settings": {
        "vnext": [ {
          "address": "$EU_IP",
          "port": $EU_PORT,
          "users": [ { "id": "$EU_UUID", "encryption": "none", "flow": "$EU_FLOW" } ]
        } ]
      },
      "streamSettings": {
        "network": "$EU_NETWORK",
        "security": "reality",
        "realitySettings": {
          "serverName": "$EU_SERVER_NAME",
          "fingerprint": "$FP",
          "publicKey": "$EU_PUBLIC_KEY",
          "shortId": "$EU_SHORT_ID",
          "spiderX": "/"
        },
        "sockopt": { "tcpFastOpen": true }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "inboundTag": ["vless-ru-in"], "outboundTag": "vless-to-eu" } ]
  }
}
EOF

systemctl enable --now xray
systemctl restart xray
sleep 2

if ! systemctl is-active --quiet xray; then
  echo "Xray RU не запустился"
  exit 1
fi

PUBLIC_IP=$(get_public_ip)

CLIENT_LINK="vless://$RU_UUID@$PUBLIC_IP:$RU_PORT?type=xhttp&security=reality&pbk=$RU_PUBLIC_KEY&sid=$RU_SHORT_ID&sni=$RU_DOMAIN&flow=xtls-rprx-vision&fp=$FP#VLESS-XHTTP-RU-Multihop"

echo
 echo "=== RU Xray VLESS готов ==="
 echo "Клиентская ссылка (подключайся к RU):"
 echo "$CLIENT_LINK"
 echo
 echo "RU_PORT: $RU_PORT"
 echo "RU_UUID: $RU_UUID"
 echo "RU_PUBLIC_KEY: $RU_PUBLIC_KEY"
 echo "Fingerprint: $FP"
 echo "SNI RU: $RU_DOMAIN"
 echo "Транспорт RU: XHTTP + Reality"
 echo "Выход на EU: raw + Reality + Vision (fingerprint $FP)"

if [[ -f "$PARAMS" ]]; then
  read -rp "Удалить eu-params.env? [y/N]: " DEL
  [[ "${DEL,,}" == "y" ]] && rm -f "$PARAMS"
fi
