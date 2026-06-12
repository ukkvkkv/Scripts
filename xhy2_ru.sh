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

install_xray() {
  echo "Устанавливаю/обновляю Xray-core..."
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
}

echo "=== Установка RU Hysteria2 entry-сервера на ядре Xray с выходом через EU ==="
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

if need_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp || true
  ufw allow "${RU_PORT}/udp" || true
fi

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true
systemctl stop xray.service 2>/dev/null || true

install_xray

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$RU_DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

mkdir -p /usr/local/etc/xray
RU_DOMAIN="$RU_DOMAIN" RU_PORT="$RU_PORT" RU_PASS="$RU_PASS" EU_HOST="$EU_HOST" EU_PORT="$EU_PORT" EU_PASS="$EU_PASS" EU_SNI="$EU_SNI" EU_INSECURE="$EU_INSECURE" python3 - <<'PY'
import json, os

ru_domain = os.environ["RU_DOMAIN"]
ru_port = int(os.environ["RU_PORT"])
ru_pass = os.environ["RU_PASS"]
eu_host = os.environ["EU_HOST"]
eu_port = int(os.environ["EU_PORT"])
eu_pass = os.environ["EU_PASS"]
eu_sni = os.environ["EU_SNI"]
eu_insecure = os.environ["EU_INSECURE"].lower() == "true"

cfg = {
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "port": ru_port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [
          {"auth": ru_pass, "level": 0, "email": "ru@xray.local"}
        ]
      },
      "sniffing": {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": ru_domain,
          "certificates": [
            {
              "certificateFile": f"/etc/letsencrypt/live/{ru_domain}/fullchain.pem",
              "keyFile": f"/etc/letsencrypt/live/{ru_domain}/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": ru_pass,
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
    {
      "tag": "eu_exit",
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "address": eu_host,
        "port": eu_port
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": eu_sni,
          "allowInsecure": eu_insecure
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": eu_pass,
          "udpIdleTimeout": 60
        }
      }
    },
    {
      "tag": "ru_direct",
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIP"}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "domain": ["domain:ru"],
        "outboundTag": "ru_direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "eu_exit"
      }
    ]
  }
}

with open("/usr/local/etc/xray/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY

if ! /usr/local/bin/xray test -config /usr/local/etc/xray/config.json; then
  echo "Ошибка: Xray не принял config.json"
  exit 1
fi

systemctl daemon-reload
systemctl enable --now xray.service
systemctl restart xray.service
sleep 2

if ! systemctl is-active --quiet xray.service; then
  echo "Ошибка: xray.service не запустился. Логи:"
  journalctl --no-pager -e -u xray.service
  exit 1
fi

PASS_ENC=$(urlencode "$RU_PASS")
DOMAIN_ENC=$(urlencode "$RU_DOMAIN")
LINK_DOMAIN="hysteria2://${PASS_ENC}@${RU_DOMAIN}:${RU_PORT}/?sni=${DOMAIN_ENC}&insecure=0#xray-hy2-ru-multihop"

echo
echo "=== RU-сервер Xray Hysteria2 готов ==="
echo "$LINK_DOMAIN"
echo
echo "Проверка логов: journalctl -u xray -e --no-pager"
echo "Проверка конфига: /usr/local/bin/xray test -config /usr/local/etc/xray/config.json"
