#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
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

random_pass() {
  openssl rand -base64 24 | tr '+/' '-_' | tr -d '=' | cut -c1-28
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

echo "=== Установка EU Hysteria2 exit-сервера ==="
read -rp "Введите домен EU-сервера: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2

PUBLIC_IP=$(get_public_ip)
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)

echo
 echo "Текущий публичный IPv4 сервера: ${PUBLIC_IP:-не удалось определить}"
 echo "DNS A-запись домена $DOMAIN: ${DNS_IP:-не найдена}"
if [[ -n "${PUBLIC_IP:-}" && -n "${DNS_IP:-}" && "$PUBLIC_IP" != "$DNS_IP" ]]; then
  echo "ВНИМАНИЕ: домен не указывает на текущий IPv4 сервера. Certbot может не выпустить сертификат."
  read -rp "Продолжить всё равно? [y/N]: " CONTINUE
  [[ "${CONTINUE,,}" == "y" || "${CONTINUE,,}" == "yes" ]] || exit 1
fi

if port_in_use 80; then
  echo "Ошибка: TCP-порт 80 занят. Освободи его для certbot --standalone и запусти скрипт снова."
  ss -ltnp | grep ':80' || true
  exit 1
fi

EU_PORT=$(random_port)
EU_PASS=$(random_pass)

if need_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow "${EU_PORT}/udp" || true
fi

echo
 echo "Устанавливаю/обновляю Hysteria2..."
HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

systemctl stop hysteria-server.service 2>/dev/null || true

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

certbot "${CERTBOT_ARGS[@]}"

mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF_CONF
listen: :${EU_PORT}

tls:
  cert: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem
  sniGuard: strict

auth:
  type: password
  password: ${EU_PASS}

bandwidth:
  up: 0 gbps
  down: 0 gbps

ignoreClientBandwidth: true

disableUDP: false
udpIdleTimeout: 60s

masquerade:
  type: string
  string:
    content: "Hello world! This site is running."
    headers:
      content-type: text/plain
    statusCode: 200
EOF_CONF

systemctl daemon-reload
systemctl enable --now hysteria-server.service
systemctl restart hysteria-server.service
sleep 2

if ! systemctl is-active --quiet hysteria-server.service; then
  echo "Ошибка: hysteria-server.service не запустился. Логи:"
  journalctl --no-pager -e -u hysteria-server.service
  exit 1
fi

PASS_ENC=$(urlencode "$EU_PASS")
DOMAIN_ENC=$(urlencode "$DOMAIN")
EU_LINK="hysteria2://${PASS_ENC}@${DOMAIN}:${EU_PORT}/?sni=${DOMAIN_ENC}&insecure=0#hys2"

echo
echo "=== EU-сервер готов ==="
echo "Ссылка для дальнейшего использования в RU-скрипте:"
echo "$EU_LINK"
