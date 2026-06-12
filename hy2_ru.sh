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

wait_tcp_port() {
  local port="$1"
  for _ in {1..20}; do
    if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

parse_eu_link() {
  EU_LINK_INPUT="$1" python3 - <<'PY'
import os, sys, shlex
from urllib.parse import urlparse, parse_qs, unquote

url = os.environ.get("EU_LINK_INPUT", "").strip()
if not url:
    print("Пустая ссылка", file=sys.stderr)
    sys.exit(1)

u = urlparse(url)
if u.scheme not in ("hysteria2", "hy2"):
    print("Ссылка должна начинаться с hysteria2:// или hy2://", file=sys.stderr)
    sys.exit(1)
if not u.hostname:
    print("Не найден host в ссылке", file=sys.stderr)
    sys.exit(1)
if not u.username:
    print("Не найден пароль/auth в ссылке", file=sys.stderr)
    sys.exit(1)

qs = parse_qs(u.query)
host = u.hostname
port = u.port or 443
auth = unquote(u.username)
sni = qs.get("sni", [host])[0]
insecure_raw = qs.get("insecure", ["0"])[0].lower()
insecure = "true" if insecure_raw in ("1", "true", "yes") else "false"

for k, v in {
    "EU_HOST": host,
    "EU_PORT": str(port),
    "EU_PASS": auth,
    "EU_SNI": sni,
    "EU_INSECURE": insecure,
}.items():
    print(f"{k}={shlex.quote(v)}")
PY
}

echo "=== Установка RU Hysteria2 entry-сервера с выходом через EU ==="
read -rp "Введите домен RU-сервера: " RU_DOMAIN
RU_DOMAIN="${RU_DOMAIN,,}"
if ! valid_domain "$RU_DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $RU_DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL
read -rp "Вставь ссылку EU-сервера hysteria2://...: " EU_LINK

eval "$(parse_eu_link "$EU_LINK")"

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2

PUBLIC_IP=$(get_public_ip)
DNS_IP=$(getent ahostsv4 "$RU_DOMAIN" | awk '{print $1; exit}' || true)

echo
 echo "Текущий публичный IPv4 RU-сервера: ${PUBLIC_IP:-не удалось определить}"
 echo "DNS A-запись домена $RU_DOMAIN: ${DNS_IP:-не найдена}"
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

RU_PORT=$(random_port)
RU_PASS=$(random_pass)
LOCAL_SOCKS_PORT=$(random_port)

if need_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow "${RU_PORT}/udp" || true
fi

echo
 echo "Устанавливаю/обновляю Hysteria2..."
HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$RU_DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

certbot "${CERTBOT_ARGS[@]}"

mkdir -p /etc/hysteria /etc/hysteria-client-eu
cat > /etc/hysteria-client-eu/config.yaml <<EOF_CLIENT
server: ${EU_HOST}:${EU_PORT}

auth: ${EU_PASS}

tls:
  sni: ${EU_SNI}
  insecure: ${EU_INSECURE}

bandwidth:
  up: 0 gbps
  down: 0 gbps

socks5:
  listen: 127.0.0.1:${LOCAL_SOCKS_PORT}
  disableUDP: false
EOF_CLIENT

HYSTERIA_BIN=$(command -v hysteria || echo /usr/local/bin/hysteria)
cat > /etc/systemd/system/hysteria-client-eu.service <<EOF_SERVICE
[Unit]
Description=Hysteria2 client to EU exit
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} client -c /etc/hysteria-client-eu/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SERVICE

cat > /etc/hysteria/config.yaml <<EOF_SERVER
listen: :${RU_PORT}

tls:
  cert: /etc/letsencrypt/live/${RU_DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${RU_DOMAIN}/privkey.pem
  sniGuard: strict

auth:
  type: password
  password: ${RU_PASS}

bandwidth:
  up: 0 gbps
  down: 0 gbps

ignoreClientBandwidth: true

disableUDP: false
udpIdleTimeout: 60s

outbounds:
  - name: eu_exit
    type: socks5
    socks5:
      addr: 127.0.0.1:${LOCAL_SOCKS_PORT}
  - name: ru_direct
    type: direct
    direct:
      mode: auto
acl:
  inline:
    - ru_direct(suffix:ru)
    - eu_exit(all)

masquerade:
  type: string
  string:
    content: "Hello world! This site is running."
    headers:
      content-type: text/plain
    statusCode: 200
EOF_SERVER

systemctl daemon-reload
systemctl enable --now hysteria-client-eu.service
systemctl restart hysteria-client-eu.service
sleep 2

if ! systemctl is-active --quiet hysteria-client-eu.service; then
  echo "Ошибка: hysteria-client-eu.service не запустился. Логи:"
  journalctl --no-pager -e -u hysteria-client-eu.service
  exit 1
fi

systemctl enable --now hysteria-server.service
systemctl restart hysteria-server.service
sleep 2

if ! systemctl is-active --quiet hysteria-server.service; then
  echo "Ошибка: hysteria-server.service не запустился. Логи:"
  journalctl --no-pager -e -u hysteria-server.service
  exit 1
fi

echo
 echo "Проверяю локальный SOCKS5 до EU: 127.0.0.1:${LOCAL_SOCKS_PORT}"
if ! wait_tcp_port "$LOCAL_SOCKS_PORT"; then
  echo "Ошибка: локальный SOCKS5 порт не открылся. Логи EU-клиента:"
  journalctl --no-pager -e -u hysteria-client-eu.service
  exit 1
fi

EU_EXIT_IP=$(curl --socks5-hostname "127.0.0.1:${LOCAL_SOCKS_PORT}" -4fsSL --max-time 20 https://api.ipify.org || true)
if [[ -z "$EU_EXIT_IP" ]]; then
  echo "Ошибка: через локальный SOCKS5 до EU не удалось выйти в интернет."
  journalctl --no-pager -e -u hysteria-client-eu.service
  exit 1
fi
 echo "OK: локальный SOCKS5 до EU работает."

PASS_ENC=$(urlencode "$RU_PASS")
DOMAIN_ENC=$(urlencode "$RU_DOMAIN")
LINK_DOMAIN="hysteria2://${PASS_ENC}@${RU_DOMAIN}:${RU_PORT}/?sni=${DOMAIN_ENC}&insecure=0#hys2-multihop"

echo
 echo "=== RU-сервер готов ==="
 echo "$LINK_DOMAIN"
