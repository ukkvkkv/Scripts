#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

get_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me"; do
    ip=$(curl -4fsSL --max-time 8 "$url" 2>/dev/null || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  hostname -I | awk '{print $1}'
}

port_in_use() {
  local p="$1"
  ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${p}$"
}

random_port() {
  local p
  for _ in {1..100}; do
    p=$(shuf -i 20000-60000 -n 1)
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "Не удалось подобрать свободный порт" >&2
  exit 1
}

echo "=== Установка EU Xray VLESS exit-сервера (raw + Reality + Vision) ==="

read -rp "Домен EU (опционально для SNI, Enter = www.microsoft.com): " EU_DOMAIN
EU_DOMAIN="${EU_DOMAIN,,}"
if [[ -z "$EU_DOMAIN" ]]; then
  EU_DOMAIN="www.microsoft.com"
fi

EU_PORT=$(random_port)

apt update -y
apt install -y curl wget jq openssl sshpass

bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install

EU_UUID=$(cat /proc/sys/kernel/random/uuid)
echo "Генерация Reality ключей EU..."
KEYS=$(xray x25519)
EU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
EU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
EU_SHORT_ID=$(openssl rand -hex 8)

if [[ -f /usr/local/etc/xray/config.json ]]; then
  cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.backup.$(date +%F_%T)"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-eu-in",
      "listen": "0.0.0.0",
      "port": $EU_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$EU_UUID", "email": "multihop@eu", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$EU_DOMAIN:443",
          "xver": 0,
          "serverNames": ["$EU_DOMAIN"],
          "privateKey": "$EU_PRIVATE_KEY",
          "shortIds": ["$EU_SHORT_ID"]
        },
        "sockopt": { "tcpFastOpen": true }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "inboundTag": ["vless-eu-in"], "outboundTag": "direct" } ]
  }
}
EOF

systemctl enable --now xray
systemctl restart xray
sleep 2

if ! systemctl is-active --quiet xray; then
  echo "Xray EU не запустился"
  exit 1
fi

PUBLIC_IP=$(get_public_ip)

echo
 echo "=== EU готов ==="
 echo "EU_IP: $PUBLIC_IP"
 echo "EU_PORT: $EU_PORT"
 echo "EU_UUID: $EU_UUID"
 echo "EU_PUBLIC_KEY: $EU_PUBLIC_KEY"
 echo "EU_SHORT_ID: $EU_SHORT_ID"
 echo "EU_SNI: $EU_DOMAIN"
 echo "Транспорт: raw + Reality + Vision"
 echo

read -rp "Передать параметры на RU по IP и паролю? [y/N]: " DO_TR
if [[ "${DO_TR,,}" == "y" ]]; then
  read -rp "IP RU: " RU_IP
  read -s -rp "Пароль root RU: " RU_PASS
  echo
  cat > /tmp/eu-params.env <<EOP
EU_IP="$PUBLIC_IP"
EU_PORT="$EU_PORT"
EU_UUID="$EU_UUID"
EU_PUBLIC_KEY="$EU_PUBLIC_KEY"
EU_SHORT_ID="$EU_SHORT_ID"
EU_SERVER_NAME="$EU_DOMAIN"
EU_NETWORK="raw"
EU_FLOW="xtls-rprx-vision"
EOP
  sshpass -p "$RU_PASS" scp -o StrictHostKeyChecking=no /tmp/eu-params.env root@"$RU_IP":/root/eu-params.env && echo "Параметры переданы" || echo "Ошибка передачи"
  rm -f /tmp/eu-params.env
fi
