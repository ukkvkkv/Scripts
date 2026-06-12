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

install_xray() {
  echo "Устанавливаю/обновляю Xray-core..."
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
}

prepare_xray_cert() {
  local domain="$1"
  local cert_dir="/usr/local/etc/xray/certs/${domain}"
  mkdir -p "$cert_dir"
  cp -f "/etc/letsencrypt/live/${domain}/fullchain.pem" "$cert_dir/fullchain.pem"
  cp -f "/etc/letsencrypt/live/${domain}/privkey.pem" "$cert_dir/privkey.pem"
  chown -R nobody:nogroup "$cert_dir" 2>/dev/null || chown -R nobody:nobody "$cert_dir" 2>/dev/null || true
  chmod 755 /usr/local/etc/xray /usr/local/etc/xray/certs "$cert_dir"
  chmod 644 "$cert_dir/fullchain.pem"
  chmod 600 "$cert_dir/privkey.pem"

  # Чтобы после продления Let's Encrypt Xray тоже получил свежий сертификат.
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > "/etc/letsencrypt/renewal-hooks/deploy/xray-copy-${domain}.sh" <<HOOK
#!/usr/bin/env bash
set -e
mkdir -p "$cert_dir"
cp -f "/etc/letsencrypt/live/${domain}/fullchain.pem" "$cert_dir/fullchain.pem"
cp -f "/etc/letsencrypt/live/${domain}/privkey.pem" "$cert_dir/privkey.pem"
chown -R nobody:nogroup "$cert_dir" 2>/dev/null || chown -R nobody:nobody "$cert_dir" 2>/dev/null || true
chmod 755 /usr/local/etc/xray /usr/local/etc/xray/certs "$cert_dir"
chmod 644 "$cert_dir/fullchain.pem"
chmod 600 "$cert_dir/privkey.pem"
systemctl restart xray.service 2>/dev/null || true
HOOK
  chmod +x "/etc/letsencrypt/renewal-hooks/deploy/xray-copy-${domain}.sh"
}

echo "=== Установка EU Hysteria2 exit-сервера на ядре Xray ==="
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

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true
systemctl stop xray.service 2>/dev/null || true

install_xray

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"
prepare_xray_cert "$DOMAIN"

mkdir -p /usr/local/etc/xray
DOMAIN="$DOMAIN" EU_PORT="$EU_PORT" EU_PASS="$EU_PASS" python3 - <<'PY'
import json, os

domain = os.environ["DOMAIN"]
port = int(os.environ["EU_PORT"])
password = os.environ["EU_PASS"]

cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "port": port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [
          {"auth": password, "level": 0, "email": "eu@xray.local"}
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": domain,
          "certificates": [
            {
              "certificateFile": f"/usr/local/etc/xray/certs/{domain}/fullchain.pem",
              "keyFile": f"/usr/local/etc/xray/certs/{domain}/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": password,
          "udpIdleTimeout": 60,
          "masquerade": {
            "type": "string",
            "content": "Hello world! This site is running.",
            "headers": {"content-type": "text/plain"},
            "statusCode": 200
          }
        }
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}}
  ]
}

with open("/usr/local/etc/xray/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY


systemctl daemon-reload
systemctl enable --now xray.service
systemctl restart xray.service
sleep 2

if ! systemctl is-active --quiet xray.service; then
  echo "Ошибка: xray.service не запустился. Логи:"
  journalctl --no-pager -e -u xray.service
  exit 1
fi

PASS_ENC=$(urlencode "$EU_PASS")
DOMAIN_ENC=$(urlencode "$DOMAIN")
EU_LINK="hysteria2://${PASS_ENC}@${DOMAIN}:${EU_PORT}/?sni=${DOMAIN_ENC}&insecure=0#xray-hy2-eu"

echo
echo "=== EU-сервер Xray Hysteria2 готов ==="
echo "Ссылка для RU-скрипта:"
echo "$EU_LINK"
