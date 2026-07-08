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

echo "=== Mieru EU Exit (чистый mita) ==="

LATEST_VERSION=$(curl -s https://api.github.com/repos/enfein/mieru/releases/latest | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "3.34.0")

ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == "amd64" ]] && DEB_FILE="mita_${LATEST_VERSION}_amd64.deb" || DEB_FILE="mita_${LATEST_VERSION}_arm64.deb"

curl -LSO "https://github.com/enfein/mieru/releases/download/v${LATEST_VERSION}/${DEB_FILE}"
sudo dpkg -i "${DEB_FILE}" >/dev/null 2>&1 || sudo apt-get install -f -y -qq >/dev/null 2>&1
rm -f "${DEB_FILE}"

EU_PORT=$(random_port)
EU_USER="u$(openssl rand -hex 5)"
EU_PASS=$(random_pass)

cat > /tmp/mita_config.json <<EOF
{
  "portBindings": [{"port": ${EU_PORT}, "protocol": "TCP"}],
  "users": [{"name": "${EU_USER}", "password": "${EU_PASS}"}],
  "loggingLevel": "ERROR",
  "mtu": 1400
}
EOF

mita apply config /tmp/mita_config.json
mita start
systemctl enable mita

PUBLIC_IP=$(get_public_ip)

echo
echo "=== EU Mieru готов ==="
echo "Порт: ${EU_PORT}"
echo "User: ${EU_USER}"
echo "Pass: ${EU_PASS}"
echo
echo "Ссылка:"
echo "mierus://${EU_USER}:${EU_PASS}@${PUBLIC_IP}?udp=0&transport=tcp&port=${EU_PORT}&profile=見た"
