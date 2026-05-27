#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

get_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me"; do
    ip=$(curl -4fsSL --max-time 8 "$url" 2>/dev/null || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
  done
  hostname -I | awk '{print $1}'
}

port_in_use() { ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${1}$"; }
random_port() { shuf -i 20000-60000 -n 1; }
random_pass() { openssl rand -base64 24 | tr '+/' '-_' | tr -d '=' | cut -c1-28; }

echo "=== Установка TrustTunnel EU exit-сервера ==="
read -rp "Введите домен EU-сервера: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then echo "Ошибка: домен некорректен: $DOMAIN"; exit 1; fi

read -rp "Email для Let's Encrypt (можно пустым): " EMAIL

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2

PUBLIC_IP=$(get_public_ip)
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)

echo
echo "Публичный IPv4: ${PUBLIC_IP:-не определён}"
echo "DNS A-запись $DOMAIN: ${DNS_IP:-не найдена}"
if [[ -n "$PUBLIC_IP" && -n "$DNS_IP" && "$PUBLIC_IP" != "$DNS_IP" ]]; then
  echo "ВНИМАНИЕ: домен не указывает на этот сервер!"
  read -rp "Продолжить? [y/N]: " CONTINUE; [[ "${CONTINUE,,}" == "y" ]] || exit 1
fi

if port_in_use 80; then
  echo "Ошибка: порт 80 занят. Освободи для certbot."
  exit 1
fi

EU_PORT=$(random_port)
EU_USER="user$(shuf -i 1000-9999 -n 1)"
EU_PASS=$(random_pass)

if need_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow "${EU_PORT}/tcp" || true
fi

echo "Устанавливаю TrustTunnel Endpoint..."
curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -

systemctl stop trusttunnel 2>/dev/null || true

# Сертификаты
CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
[[ -n "$EMAIL" ]] && CERTBOT_ARGS+=(-m "$EMAIL") || CERTBOT_ARGS+=(--register-unsafely-without-email)
certbot "${CERTBOT_ARGS[@]}"

# Конфиги TrustTunnel
cd /opt/trusttunnel

cat > credentials.toml <<EOF
[[client]]
username = "${EU_USER}"
password = "${EU_PASS}"
EOF

cat > hosts.toml <<EOF
[[main_hosts]]
hostname = "${DOMAIN}"
cert_chain_path = "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
EOF

cat > vpn.toml <<EOF
listen_address = "0.0.0.0:${EU_PORT}"

ipv6_available = true
allow_private_network_connections = false

credentials_file = "credentials.toml"
rules_file = "rules.toml"

[forward_protocol]
direct = {}
EOF

cat > rules.toml <<EOF
# allow all
EOF

# systemd
cp trusttunnel.service.template /etc/systemd/system/trusttunnel.service 2>/dev/null || true
sed -i "s|ExecStart=.*|ExecStart=/opt/trusttunnel/trusttunnel_endpoint vpn.toml hosts.toml|" /etc/systemd/system/trusttunnel.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now trusttunnel
sleep 3

if ! systemctl is-active --quiet trusttunnel; then
  echo "Ошибка: trusttunnel не запустился"
  journalctl --no-pager -e -u trusttunnel
  exit 1
fi

echo
echo "=== EU-сервер готов ==="
echo " "
TT_LINK="tt://${EU_USER}:${EU_PASS}@${DOMAIN}:${EU_PORT}/?sni=${DOMAIN}&insecure=0#trusttunnel-eu"
echo "$TT_LINK"