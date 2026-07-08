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

install_singbox() {
  if ! need_cmd sing-box; then
    echo "Устанавливаю sing-box..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  fi
}

echo "=== Mieru EU Exit (sing-box) ==="

EU_PORT=$(random_port)
EU_USER="u$(openssl rand -hex 5)"
EU_PASS=$(random_pass)

install_singbox
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
      "listen_port": ${EU_PORT},
      "transport": "TCP",
      "users": [
        {
          "name": "${EU_USER}",
          "password": "${EU_PASS}"
        }
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
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

echo
echo "=== EU Mieru готов ==="
echo "Порт: ${EU_PORT}"
echo "User: ${EU_USER}"
echo "Pass: ${EU_PASS}"
echo
echo "Ссылка для RU-скрипта:"
echo "mierus://${EU_USER}:${EU_PASS}@IP_ИЛИ_ДОМЕН_ЕВРОПЫ:${EU_PORT}?transport=tcp"