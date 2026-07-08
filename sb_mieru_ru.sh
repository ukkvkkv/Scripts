#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

port_in_use() { ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${1}$"; }

random_port() {
  local p
  for _ in {1..100}; do
    p=$(shuf -i 20000-60000 -n 1)
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "Не удалось подобрать порт" >&2; exit 1
}

random_pass() {
  openssl rand -base64 24 | tr '+/' '-_' | tr -d '=' | cut -c1-28
}

get_public_ip() {
  local ip
  for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    ip=$(curl -4fsSL --max-time 6 "$url" 2>/dev/null || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  hostname -I | awk '{print $1}'
}

install_mbox() {
  echo "Устанавливаю mbox из релиза..."
  LATEST_TAG=$(curl -s https://api.github.com/repos/enfein/mbox/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
  
  ARCH=$(dpkg --print-architecture)
  if [[ "$ARCH" == "amd64" ]]; then
    ASSET_NAME="sing-box.*linux-amd64"
  else
    ASSET_NAME="sing-box.*linux-arm64"
  fi

  DOWNLOAD_URL=$(curl -s https://api.github.com/repos/enfein/mbox/releases/latest | \
    grep browser_download_url | grep -E "$ASSET_NAME" | head -n1 | cut -d '"' -f4)

  if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "Не удалось найти бинарник в релизе"
    exit 1
  fi

  curl -L "$DOWNLOAD_URL" -o /tmp/mbox.tar.gz
  tar -xzf /tmp/mbox.tar.gz -C /usr/local/bin sing-box
  chmod +x /usr/local/bin/sing-box
  rm -f /tmp/mbox.tar.gz
}

echo "=== Mieru RU Multihop (mbox) ==="
read -rp "Вставь ссылку EU (mierus://...): " EU_LINK

EU_HOST=$(echo "$EU_LINK" | sed -E 's|mierus://[^@]+@([^?]+)\?.*|\1|')
EU_USER=$(echo "$EU_LINK" | sed -E 's|mierus://([^:]+):.*@.*|\1|')
EU_PASS=$(echo "$EU_LINK" | sed -E 's|mierus://[^:]+:([^@]+)@.*|\1|')
EU_PORT=$(echo "$EU_LINK" | grep -oE 'port=[0-9]+' | cut -d= -f2)

if [[ -z "$EU_HOST" || -z "$EU_PORT" || -z "$EU_USER" || -z "$EU_PASS" ]]; then
  echo "Не удалось распарсить ссылку EU"
  exit 1
fi

RU_PORT=$(random_port)
RU_USER="u$(openssl rand -hex 5)"
RU_PASS=$(random_pass)

install_mbox
systemctl stop sing-box 2>/dev/null || true

mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "mieru",
      "tag": "mieru-in",
      "listen": "::",
      "listen_port": ${RU_PORT},
      "transport": "TCP",
      "users": [
        {
          "name": "${RU_USER}",
          "password": "${RU_PASS}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "mieru",
      "tag": "eu_exit",
      "server": "${EU_HOST}",
      "server_port": ${EU_PORT},
      "transport": "TCP",
      "username": "${EU_USER}",
      "password": "${EU_PASS}"
    }
  ],
  "route": {
    "final": "eu_exit"
  }
}
EOF

sing-box check -c /etc/sing-box/config.json
systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box
sleep 2

if ! systemctl is-active --quiet sing-box; then
  echo "sing-box не запустился. Логи:"
  journalctl --no-pager -e -u sing-box
  exit 1
fi

PUBLIC_IP=$(get_public_ip)

echo
echo "=== RU Mieru Multihop готов ==="
echo "Порт: ${RU_PORT}"
echo "User: ${RU_USER}"
echo "Pass: ${RU_PASS}"
echo
echo "Ссылка для клиента:"
echo "mierus://${RU_USER}:${RU_PASS}@${PUBLIC_IP}?udp=0&transport=tcp&port=${RU_PORT}&profile=二段見える"
