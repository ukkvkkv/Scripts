#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

port_in_use() { ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${1}$"; }
random_port() {
  local p; for _ in {1..100}; do p=$(shuf -i 20000-60000 -n 1); if ! port_in_use "$p"; then echo "$p"; return 0; fi; done
  echo "Не удалось подобрать порт" >&2; exit 1
}
random_pass() { openssl rand -base64 24 | tr '+/' '-_' | tr -d '=' | cut -c1-28; }
get_public_ip() {
  local ip; for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    ip=$(curl -4fsSL --max-time 6 "$url" 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  hostname -I | awk '{print $1}'
}

install_mbox() {
    echo "Устанавливаю mbox..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/enfein/mbox/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    ARCH=$(dpkg --print-architecture); [[ "$ARCH" == "amd64" ]] && ASSET="linux-amd64" || ASSET="linux-arm64"
    URL=$(curl -s "https://api.github.com/repos/enfein/mbox/releases/latest" | \
        jq -r ".assets[] | select(.name | contains(\"$ASSET\") and endswith(\".tar.gz\")) | .browser_download_url" | head -n1)
    curl -L "$URL" -o /tmp/mbox.tar.gz
    mkdir -p /tmp/mbox_extract
    tar -xzf /tmp/mbox.tar.gz -C /tmp/mbox_extract
    BIN=$(find /tmp/mbox_extract -type f -name "sing-box" | head -n1)
    [[ -z "$BIN" ]] && { echo "Бинарник не найден"; exit 1; }
    cp "$BIN" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf /tmp/mbox.tar.gz /tmp/mbox_extract
    echo "mbox установлен: $(sing-box version)"
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

echo "=== Mieru EU Exit (mbox) ==="

EU_PORT=$(random_port)
EU_USER="u$(openssl rand -hex 5)"
EU_PASS=$(random_pass)

install_mbox
create_systemd_service

mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "mieru",
    "tag": "mieru-in",
    "listen": "::",
    "listen_port": ${EU_PORT},
    "transport": "TCP",
    "users": [{ "name": "${EU_USER}", "password": "${EU_PASS}" }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
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
echo "=== EU Mieru готов ==="
echo "Порт: ${EU_PORT}"
echo "User: ${EU_USER}"
echo "Pass: ${EU_PASS}"
echo
echo "Ссылка:"
echo "mierus://${EU_USER}:${EU_PASS}@${PUBLIC_IP}?udp=0&transport=tcp&port=${EU_PORT}&profile=見た"
