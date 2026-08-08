#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo -i, затем повтори команду."
  exit 1
fi

SUB_TOKEN="a1236020fcd2e4a8d46f047ecc63f5c2"
SUB_TOKEN2="4ab0b523673328390d57976dc5e76729"
SUB_DIR="/var/www/sub"
SUB2_BASE64="1"

for _var in SUB_TOKEN SUB_TOKEN2; do
  if ! [[ "${!_var}" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
    echo "Ошибка: не задан токен подписки (${_var})."
    echo
    echo "Впиши его в переменную ${_var} в шапке скрипта."
    echo "Сгенерировать новый:  openssl rand -hex 16"
    echo
    echo "Или разово, не редактируя файл, передай его при запуске:"
    echo "  ${_var}=<токен> bash -c \"\$(curl -fsSL <URL-скрипта>)\""
    exit 1
  fi
done
unset _var

SUB_PATH="/${SUB_TOKEN}"
SUB_PATH2="/${SUB_TOKEN2}"
SUB_FILE="${SUB_DIR}${SUB_PATH}"
SUB_FILE2="${SUB_DIR}${SUB_PATH2}"

if [[ "$SUB_PATH" == "$SUB_PATH2" ]]; then
  echo "Ошибка: пути подписок совпадают: ${SUB_PATH}"
  echo "Поменяй SUB_TOKEN2."
  exit 1
fi

# Порт локального nginx, на который REALITY проксирует чужие хендшейки.
# Наружу не торчит: 443 занимает sing-box, nginx слушает только 127.0.0.1.
NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT:-8443}"
VLESS_PORT="${VLESS_PORT:-443}"

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

# Фильтруем средствами самого ss: у "ss -tln" нет колонки Netid, а у
# "ss -tuln" она есть, поэтому разбор по номеру колонки врёт через раз.
tcp_port_in_use() {
  local p="$1"
  [[ -n "$(ss -H -tln "sport = :${p}" 2>/dev/null)" ]]
}

udp_port_in_use() {
  local p="$1"
  [[ -n "$(ss -H -uln "sport = :${p}" 2>/dev/null)" ]]
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

open_udp_port() {
  local p="$1"
  if need_cmd ufw; then
    ufw allow "${p}/udp" 2>/dev/null || true
  fi
  if need_cmd iptables; then
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true
    iptables -C OUTPUT -p udp --sport "$p" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p udp --sport "$p" -j ACCEPT || true
  fi
}

install_singbox() {
  if ! need_cmd sing-box; then
    echo "Устанавливаю sing-box..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)
  else
    echo "sing-box уже установлен: $(sing-box version | head -n 1)"
  fi
}

prepare_certs() {
  local domain="$1"
  local src_dir="/etc/letsencrypt/live/${domain}"
  local dst_dir="/etc/sing-box/certs/${domain}"

  if [[ ! -f "${src_dir}/fullchain.pem" || ! -f "${src_dir}/privkey.pem" ]]; then
    echo "Ошибка: сертификаты Let's Encrypt не найдены для ${domain}"
    exit 1
  fi

  mkdir -p "$dst_dir"
  cp -f "${src_dir}/fullchain.pem" "${dst_dir}/fullchain.pem"
  cp -f "${src_dir}/privkey.pem" "${dst_dir}/privkey.pem"

  chmod 755 /etc/sing-box /etc/sing-box/certs "$dst_dir"
  chmod 644 "${dst_dir}/fullchain.pem"

  if getent group sing-box >/dev/null 2>&1; then
    chgrp -R sing-box "$dst_dir" || true
    chmod 640 "${dst_dir}/privkey.pem"
  else
    chmod 600 "${dst_dir}/privkey.pem"
  fi


  echo "$dst_dir"
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
sni = qs.get("sni", qs.get("peer", [host]))[0]
insecure_raw = qs.get("insecure", ["0"])[0].lower()
insecure = True if insecure_raw in ("1", "true", "yes") else False
obfs_type = qs.get("obfs", [""])[0]
obfs_pass = unquote(qs.get("obfs-password", [""])[0]) if qs.get("obfs-password") else ""

for k, v in {
    "EU_HOST": host,
    "EU_PORT": str(port),
    "EU_PASS": auth,
    "EU_SNI": sni,
    "EU_INSECURE": "true" if insecure else "false",
    "EU_OBFS": obfs_type,
    "EU_OBFS_PASS": obfs_pass,
}.items():
    print(f"{k}={shlex.quote(v)}")
PY
}

parse_eu_vless_link() {
  EU_VLESS_INPUT="$1" python3 - <<'PY'
import os, sys, shlex
from urllib.parse import urlparse, parse_qs, unquote

url = os.environ.get("EU_VLESS_INPUT", "").strip()
u = urlparse(url)
if u.scheme != "vless":
    print("Ссылка должна начинаться с vless://", file=sys.stderr)
    sys.exit(1)
if not u.hostname or not u.username:
    print("В ссылке нет host или uuid", file=sys.stderr)
    sys.exit(1)

qs = parse_qs(u.query)
if qs.get("security", [""])[0] != "reality":
    print("Ожидалась ссылка с security=reality", file=sys.stderr)
    sys.exit(1)

pbk = qs.get("pbk", [""])[0]
if not pbk:
    print("В ссылке нет pbk (публичный ключ REALITY)", file=sys.stderr)
    sys.exit(1)

for k, v in {
    "EU_V_HOST": u.hostname,
    "EU_V_PORT": str(u.port or 443),
    "EU_V_UUID": unquote(u.username),
    "EU_V_SNI":  qs.get("sni", [u.hostname])[0],
    "EU_V_PBK":  pbk,
    "EU_V_SID":  qs.get("sid", [""])[0],
    "EU_V_FLOW": qs.get("flow", ["xtls-rprx-vision"])[0],
    "EU_V_FP":   qs.get("fp", ["firefox"])[0],
}.items():
    print(f"{k}={shlex.quote(v)}")
PY
}

write_client_config() {
  local out="$1"
  install -d -m 755 "$(dirname "$out")"

  cat > "$out" <<EOF_CLIENT
{
  "log": {
    "level": "error"
  },

  "dns": {
    "servers": [
      { "tag": "dns-remote", "type": "https", "server": "1.1.1.1", "detour": "proxy" },
      { "tag": "dns-local",  "type": "local" }
    ],
    "rules": [
      { "domain_suffix": [".ru"], "action": "route", "server": "dns-local" }
    ],
    "final": "dns-remote"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 1400,
      "auto_route": true
    }
  ],

  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${RU_DOMAIN}",
      "server_port": ${RU_PORT},
      "password": "${RU_PASS}",
      "obfs": {
        "type": "salamander",
        "password": "${RU_OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${RU_DOMAIN}"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],

  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local",
    "final": "proxy",
    "rules": [
      { "action": "sniff" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": [".ru"], "outbound": "direct" }
    ]
  }
}
EOF_CLIENT

  chmod 644 "$out"
  if ! sing-box check -c "$out"; then
    echo "Ошибка: сгенерированный клиентский конфиг не проходит sing-box check"
    exit 1
  fi
}
write_link_config() {
  local out="$1"
  install -d -m 755 "$(dirname "$out")"

  local payload="$RU_LINK"
  if [[ -n "${RU_VLESS_LINK:-}" ]]; then
    payload="${RU_LINK}
${RU_VLESS_LINK}"
  fi

  if [[ "$SUB2_BASE64" == "1" ]]; then
    printf '%s\n' "$payload" | base64 -w0 > "$out"
  else
    printf '%s\n' "$payload" > "$out"
  fi

  chmod 644 "$out"

  if [[ ! -s "$out" ]]; then
    echo "Ошибка: файл второй подписки пустой: $out"
    exit 1
  fi
}
setup_nginx() {
  rm -f /etc/nginx/sites-enabled/default

  # Когда включён VLESS, 443 занимает sing-box, а nginx уезжает на локальный
  # порт и работает двумя способами сразу: как dest для REALITY-хендшейков
  # и как раздатчик подписок (REALITY прозрачно пробрасывает на него
  # всех, кто пришёл без валидного ключа — то есть обычные браузеры).
  local ssl_listen="listen 443 ssl;"
  if [[ "$VLESS_ENABLED" == "1" ]]; then
    ssl_listen="listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;"
  fi

  cat > /etc/nginx/sites-available/subscription.conf <<EOF_NGINX
server {
    listen 80;
    server_name ${RU_DOMAIN};
    location / { return 301 https://\$host\$request_uri; }
}

server {
    ${ssl_listen}
    server_name ${RU_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${RU_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${RU_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;

    server_tokens off;
    access_log off;          # в URL токен, в лог его писать незачем

    root ${SUB_DIR};

    location = ${SUB_PATH} {
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }

    location = ${SUB_PATH2} {
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }

    location / { return 404; }
}
EOF_NGINX

  ln -sf /etc/nginx/sites-available/subscription.conf \
         /etc/nginx/sites-enabled/subscription.conf

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}
setup_renewal_hooks() {
  install -d -m 755 /etc/letsencrypt/renewal-hooks/pre \
                    /etc/letsencrypt/renewal-hooks/deploy \
                    /etc/letsencrypt/renewal-hooks/post

  cat > /etc/letsencrypt/renewal-hooks/pre/00-stop-nginx.sh <<'EOF_PRE'
#!/bin/sh
systemctl stop nginx 2>/dev/null || true
EOF_PRE

  cat > /etc/letsencrypt/renewal-hooks/deploy/10-singbox-certs.sh <<EOF_DEPLOY
#!/bin/bash
set -e
DOMAIN="${RU_DOMAIN}"
DST="/etc/sing-box/certs/\${DOMAIN}"
install -d -m 755 "\$DST"
cp -f "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" "\$DST/fullchain.pem"
cp -f "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem"   "\$DST/privkey.pem"
chmod 644 "\$DST/fullchain.pem"
if getent group sing-box >/dev/null 2>&1; then
  chgrp -R sing-box "\$DST"
  chmod 640 "\$DST/privkey.pem"
else
  chmod 600 "\$DST/privkey.pem"
fi
systemctl restart sing-box
EOF_DEPLOY

  cat > /etc/letsencrypt/renewal-hooks/post/99-start-nginx.sh <<'EOF_POST'
#!/bin/sh
systemctl start nginx 2>/dev/null || true
EOF_POST

  chmod +x /etc/letsencrypt/renewal-hooks/pre/00-stop-nginx.sh \
           /etc/letsencrypt/renewal-hooks/deploy/10-singbox-certs.sh \
           /etc/letsencrypt/renewal-hooks/post/99-start-nginx.sh
}

echo "=== Установка RU-входа (hysteria2 + vless-reality) на sing-box с выходом через EU ==="
read -rp "Введите домен RU-сервера: " RU_DOMAIN
RU_DOMAIN="${RU_DOMAIN,,}"
if ! valid_domain "$RU_DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $RU_DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL
read -rp "Вставь ссылку EU-сервера hysteria2://...: " EU_LINK

eval "$(parse_eu_link "$EU_LINK")"

echo
echo "Теперь VLESS-хоп до того же EU-сервера."
echo "Оставь пустым, если нужен только hysteria2 — тогда VLESS не поднимется вовсе."
read -rp "Вставь ссылку EU-сервера vless://...: " EU_VLESS_LINK

VLESS_ENABLED=0
if [[ -n "${EU_VLESS_LINK// /}" ]]; then
  eval "$(parse_eu_vless_link "$EU_VLESS_LINK")"
  VLESS_ENABLED=1
fi

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban nginx

# Логов быть не должно: sing-box молчит на level=panic, nginx глушим тут.
# access_log писал бы IP всех, кто постучался, включая сканеры на REALITY.
sed -i -e 's#^[[:space:]]*access_log .*#access_log off;#' \
       -e 's#^[[:space:]]*error_log .*#error_log /dev/null crit;#' \
       /etc/nginx/nginx.conf

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
systemctl stop nginx 2>/dev/null || true

if port_in_use 80; then
  echo "Ошибка: TCP-порт 80 занят. Освободи его для certbot --standalone и запусти скрипт снова."
  ss -ltnp | grep ':80' || true
  exit 1
fi

RU_PORT=$(random_port)
RU_PASS=$(random_pass)
RU_OBFS_PASS=$(random_pass)

ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
open_udp_port "$RU_PORT"

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl disable hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true
systemctl disable hysteria-client-eu.service 2>/dev/null || true

install_singbox
systemctl stop sing-box 2>/dev/null || true

# Свои ключи REALITY для входа "клиент -> RU". С EU-нодой они не общие:
# там своя пара, здесь своя.
if [[ "$VLESS_ENABLED" == "1" ]]; then
  RU_REALITY_KEYPAIR=$(sing-box generate reality-keypair)
  RU_REALITY_PRIVATE=$(echo "$RU_REALITY_KEYPAIR" | awk '/PrivateKey/ {print $2}')
  RU_REALITY_PUBLIC=$(echo "$RU_REALITY_KEYPAIR" | awk '/PublicKey/ {print $2}')
  RU_VLESS_UUID=$(sing-box generate uuid)
  RU_VLESS_SID=$(sing-box generate rand 8 --hex)

  if [[ -z "$RU_REALITY_PRIVATE" || -z "$RU_REALITY_PUBLIC" || -z "$RU_VLESS_UUID" || -z "$RU_VLESS_SID" ]]; then
    echo "Ошибка: не удалось сгенерировать параметры REALITY."
    exit 1
  fi
fi

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$RU_DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

CERT_DIR=$(prepare_certs "$RU_DOMAIN")
EU_OBFS_BLOCK=""
if [[ -n "${EU_OBFS_PASS:-}" ]]; then
  EU_OBFS_BLOCK="      \"obfs\": {
        \"type\": \"salamander\",
        \"password\": \"${EU_OBFS_PASS}\"
      },
"
fi

# Блоки VLESS вклеиваются в конфиг с ведущей запятой, чтобы при
# VLESS_ENABLED=0 остался ровно прежний hysteria-only конфиг.
VLESS_IN_BLOCK=""
VLESS_OUT_BLOCK=""
VLESS_RULE_BLOCK=""
if [[ "$VLESS_ENABLED" == "1" ]]; then
  VLESS_IN_BLOCK=",
    {
      \"type\": \"vless\",
      \"tag\": \"vless-in\",
      \"listen\": \"::\",
      \"listen_port\": ${VLESS_PORT},
      \"users\": [
        {
          \"name\": \"user1\",
          \"uuid\": \"${RU_VLESS_UUID}\",
          \"flow\": \"xtls-rprx-vision\"
        }
      ],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${RU_DOMAIN}\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": {
            \"server\": \"127.0.0.1\",
            \"server_port\": ${NGINX_LOCAL_PORT}
          },
          \"private_key\": \"${RU_REALITY_PRIVATE}\",
          \"short_id\": [
            \"${RU_VLESS_SID}\"
          ]
        }
      }
    }"

  VLESS_OUT_BLOCK=",
    {
      \"type\": \"vless\",
      \"tag\": \"eu_exit_vless\",
      \"server\": \"${EU_V_HOST}\",
      \"server_port\": ${EU_V_PORT},
      \"uuid\": \"${EU_V_UUID}\",
      \"flow\": \"${EU_V_FLOW}\",
      \"packet_encoding\": \"xudp\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${EU_V_SNI}\",
        \"utls\": {
          \"enabled\": true,
          \"fingerprint\": \"${EU_V_FP}\"
        },
        \"reality\": {
          \"enabled\": true,
          \"public_key\": \"${EU_V_PBK}\",
          \"short_id\": \"${EU_V_SID}\"
        }
      }
    }"

  # VLESS-клиенты уходят на EU своим VLESS-хопом, hysteria — своим.
  VLESS_RULE_BLOCK=",
      {
        \"inbound\": [
          \"vless-in\"
        ],
        \"outbound\": \"eu_exit_vless\"
      }"
fi

mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF_CONF
{
  "log": {
    "level": "panic",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${RU_PORT},
      "users": [
        {
          "password": "${RU_PASS}"
        }
      ],
      "obfs": {
        "type": "salamander",
        "password": "${RU_OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${RU_DOMAIN}",
        "certificate_path": "${CERT_DIR}/fullchain.pem",
        "key_path": "${CERT_DIR}/privkey.pem"
      },
      "masquerade": {
        "type": "proxy",
        "url": "https://www.bing.com",
        "rewrite_host": true
      }
    }${VLESS_IN_BLOCK}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "ru_direct"
    },
    {
      "type": "hysteria2",
      "tag": "eu_exit",
      "server": "${EU_HOST}",
      "server_port": ${EU_PORT},
      "password": "${EU_PASS}",
${EU_OBFS_BLOCK}      "tls": {
        "enabled": true,
        "server_name": "${EU_SNI}",
        "insecure": ${EU_INSECURE}
      }
    }${VLESS_OUT_BLOCK}
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [
          ".ru"
        ],
        "outbound": "ru_direct"
      }${VLESS_RULE_BLOCK}
    ],
    "final": "eu_exit"
  }
}
EOF_CONF

sing-box check -c /etc/sing-box/config.json
systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box
sleep 2

if ! systemctl is-active --quiet sing-box; then
  echo "Ошибка: sing-box не запустился. Логи:"
  journalctl --no-pager -e -u sing-box
  exit 1
fi

if ! udp_port_in_use "$RU_PORT"; then
  echo "Ошибка: sing-box не слушает ${RU_PORT}/udp (hysteria2)."
  exit 1
fi
if [[ "$VLESS_ENABLED" == "1" ]] && ! tcp_port_in_use "$VLESS_PORT"; then
  echo "Ошибка: sing-box не слушает ${VLESS_PORT}/tcp (vless-reality)."
  exit 1
fi

PASS_ENC=$(urlencode "$RU_PASS")
DOMAIN_ENC=$(urlencode "$RU_DOMAIN")
OBFS_PASS_ENC=$(urlencode "$RU_OBFS_PASS")
RU_LINK="hysteria2://${PASS_ENC}@${RU_DOMAIN}:${RU_PORT}?peer=${DOMAIN_ENC}&obfs=salamander&obfs-password=${OBFS_PASS_ENC}#hys2"

RU_VLESS_LINK=""
if [[ "$VLESS_ENABLED" == "1" ]]; then
  RU_VLESS_LINK="vless://${RU_VLESS_UUID}@${RU_DOMAIN}:${VLESS_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${RU_DOMAIN}&fp=firefox&pbk=${RU_REALITY_PUBLIC}&sid=${RU_VLESS_SID}#vless"
fi

write_client_config "${SUB_FILE}"   # sing-box JSON
write_link_config   "${SUB_FILE2}"  # hysteria2:// + vless://
setup_nginx
setup_renewal_hooks
SUB_URL="https://${RU_DOMAIN}${SUB_PATH}"
SUB_URL2="https://${RU_DOMAIN}${SUB_PATH2}"

# Подписки отдаёт nginx, спрятанный за REALITY. Проверяем, что снаружи
# они реально открываются — иначе клиенту неоткуда взять конфиг.
sleep 1
SUB_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SUB_URL2" || echo "000")
if [[ "$SUB_CODE" != "200" ]]; then
  echo "ВНИМАНИЕ: подписка ${SUB_URL2} отдала код ${SUB_CODE}, а не 200."
  echo "Ссылки ниже рабочие, но подписку по URL клиент не получит — проверь nginx и REALITY handshake."
fi

NEW_SSH_PORT=$(shuf -i 20000-60000 -n 1)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
sed -i '/^#\?Port /d' /etc/ssh/sshd_config
echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
sed -i '/^#\?PasswordAuthentication /d' /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
sed -i '/^#\?PubkeyAuthentication /d' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd

cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow "$NEW_SSH_PORT"/tcp
ufw allow "$RU_PORT"/udp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl -p

systemctl is-active --quiet nginx || systemctl restart nginx

echo
echo "=== Готово ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
if [[ "$VLESS_ENABLED" == "1" ]]; then
  echo "VLESS REALITY: ${VLESS_PORT}/tcp, dest 127.0.0.1:${NGINX_LOCAL_PORT} (локальный nginx с этим же сертом)"
fi
echo
echo "--- Ссылка hysteria2 ---"
echo "$RU_LINK"
if [[ "$VLESS_ENABLED" == "1" ]]; then
  echo
  echo "--- Ссылка vless-reality ---"
  echo "$RU_VLESS_LINK"
fi
echo
echo "--- Подписка sing-box ---"
echo "$SUB_URL"
echo
echo "--- Подписка ---"
echo "$SUB_URL2"
echo
