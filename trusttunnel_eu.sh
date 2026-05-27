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

echo "=== Установка TrustTunnel EU exit-сервера (исправленная версия) ==="
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

[listen_protocols]
[listen_protocols.http1]
upload_buffer_size = 32768
[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536
[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096

[forward_protocol]
direct = {}
EOF

cat > rules.toml <<EOF
# allow all
EOF

# systemd
cp trusttunnel.service.template /etc/systemd/system/trusttunnel.service 2>/dev/null || true
sed -i 's|ExecStart=.*|ExecStart=/opt/trusttunnel/trusttunnel_endpoint vpn.toml hosts.toml|' /etc/systemd/system/trusttunnel.service

systemctl daemon-reload
systemctl enable --now trusttunnel
sleep 4

if ! systemctl is-active --quiet trusttunnel; then
  echo "=== ОШИБКА: trusttunnel не запустился ==="
  journalctl --no-pager -e -u trusttunnel
  echo "Покажи мне этот вывод полностью, если не пойму в чём дело."
  exit 1
fi

echo "Сервер запущен успешно."

# Генерируем ПРАВИЛЬНУЮ tt:// ссылку
echo "Генерируем клиентскую ссылку..."
TT_LINK=$(/opt/trusttunnel/trusttunnel_endpoint vpn.toml hosts.toml -c "${EU_USER}" -a "${DOMAIN}:${EU_PORT}" --format deeplink 2>/dev/null || echo "ОШИБКА генерации ссылки")

echo
echo "=== EU-сервер ГОТОВ ==="
echo "Правильная ссылка для клиентов (Shadowrocket / официальное приложение):"
echo "${TT_LINK}"
echo
echo "Скопируй её целиком и вставь в клиент."
