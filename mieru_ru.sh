#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
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

    LATEST_TAG=$(curl -s https://api.github.com/repos/enfein/mbox/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [[ -z "$LATEST_TAG" ]]; then
        echo "Не удалось получить информацию о релизе"
        exit 1
    fi

    ARCH=$(dpkg --print-architecture)
    [[ "$ARCH" == "amd64" ]] && ASSET_NAME="linux-amd64" || ASSET_NAME="linux-arm64"

    DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/enfein/mbox/releases/latest" | \
        jq -r ".assets[] | select(.name | contains(\"${ASSET_NAME}\") and endswith(\".tar.gz\")) | .browser_download_url" | head -n1)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "Не удалось найти архив в релизе"
        exit 1
    fi

    curl -L "$DOWNLOAD_URL" -o /tmp/mbox.tar.gz

    mkdir -p /tmp/mbox_extract
    tar -xzf /tmp/mbox.tar.gz -C /tmp/mbox_extract

    BINARY_PATH=$(find /tmp/mbox_extract -type f -name "sing-box" | head -n1)

    if [[ -z "$BINARY_PATH" ]]; then
        echo "Бинарник sing-box не найден в архиве"
        exit 1
    fi

    cp "$BINARY_PATH" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/mbox.tar.gz /tmp/mbox_extract

}

create_systemd_service() {
    mkdir -p /var/lib/sing-box
    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

echo "=== Mieru RU Multihop (mbox) ==="
read -rp "Вставь ссылку EU (mierus://...): " EU_LINK

# Парсинг ссылки
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
create_systemd_service

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
echo "=== Mieru Multihop готов ==="
echo
echo "mierus://${RU_USER}:${RU_PASS}@${PUBLIC_IP}?udp=0&transport=tcp&port=${RU_PORT}&profile=見える"
