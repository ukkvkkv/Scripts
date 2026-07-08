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
  
  if [[ -z "$LATEST_TAG" ]]; then
    echo "Не удалось получить информацию о релизе"
    exit 1
  fi

  ARCH=$(dpkg --print-architecture)
  if [[ "$ARCH" == "amd64" ]]; then
    ASSET_PATTERN="linux-amd64"
  else
    ASSET_PATTERN="linux-arm64"
  fi

  # Находим нужный архив
  DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/enfein/mbox/releases/latest" | \
    jq -r ".assets[] | select(.name | contains(\"${ASSET_PATTERN}\") and contains(\".tar.gz\")) | .browser_download_url" | head -n1)

  if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "Не удалось найти подходящий архив в релизе"
    exit 1
  fi

  echo "Скачиваю: $DOWNLOAD_URL"
  curl -L "$DOWNLOAD_URL" -o /tmp/mbox.tar.gz

  # Распаковываем во временную папку
  mkdir -p /tmp/mbox_extracted
  tar -xzf /tmp/mbox.tar.gz -C /tmp/mbox_extracted

  # Ищем бинарник sing-box внутри распакованного архива
  BINARY_PATH=$(find /tmp/mbox_extracted -type f -name "sing-box" | head -n1)

  if [[ -z "$BINARY_PATH" ]]; then
    echo "Не удалось найти бинарник sing-box внутри архива"
    exit 1
  fi

  cp "$BINARY_PATH" /usr/local/bin/sing-box
  chmod +x /usr/local/bin/sing-box
  rm -rf /tmp/mbox.tar.gz /tmp/mbox_extracted

  echo "mbox успешно установлен: $(sing-box version)"
}

echo "=== Mieru EU Exit (mbox) ==="

EU_PORT=$(random_port)
EU_USER="u$(openssl rand -hex 5)"
EU_PASS=$(random_pass)

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

PUBLIC_IP=$(get_public_ip)

echo
echo "=== EU Mieru готов ==="
echo "Порт: ${EU_PORT}"
echo "User: ${EU_USER}"
echo "Pass: ${EU_PASS}"
echo
echo "Ссылка:"
echo "mierus://${EU_USER}:${EU_PASS}@${PUBLIC_IP}?udp=0&transport=tcp&port=${EU_PORT}&profile=見た"
