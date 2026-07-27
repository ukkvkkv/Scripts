#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo -i, затем повтори команду."
  exit 1
fi

SUB_TOKEN="a1236020fcd2e4a8d46f047ecc63f5c2"
SUB_DIR="/var/www/sub"
if ! [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
  echo "Ошибка: не задан токен подписки."
  echo
  echo "Впиши его в переменную SUB_TOKEN в шапке скрипта."
  echo "Сгенерировать новый:  openssl rand -hex 16"
  echo
  echo "Или разово, не редактируя файл, передай его при запуске:"
  echo "  SUB_TOKEN=<токен> bash -c \"\$(curl -fsSL <URL-скрипта>)\""
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


# ============================================================================
#  ПОДПИСКА ДЛЯ SING-BOX
# ============================================================================

# Клиентский конфиг. Роутинг на стороне клиента: .ru и локалка мимо туннеля,
# всё остальное -> RU-сервер -> EU-сервер.
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

  # проверяем схему тем же бинарником, что стоит на сервере
  if ! sing-box check -c "$out"; then
    echo "Ошибка: сгенерированный клиентский конфиг не проходит sing-box check"
    exit 1
  fi
}

# nginx отдаёт конфиг по одному точному пути, всё остальное -> 404.
# IPv4-only: sysctl в конце скрипта отключает IPv6.
setup_nginx() {
  rm -f /etc/nginx/sites-enabled/default

  cat > /etc/nginx/sites-available/subscription.conf <<EOF_NGINX
server {
    listen 80;
    server_name ${RU_DOMAIN};
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name ${RU_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${RU_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${RU_DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;

    server_tokens off;
    access_log off;          # в URL токен, в лог его писать незачем

    root ${SUB_DIR};

    location = /${SUB_TOKEN} {
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

# Продление сертификата: certbot --standalone требует свободный 80-й,
# поэтому на время продления гасим nginx. Deploy-хук докладывает свежие
# сертификаты в /etc/sing-box/certs и перезапускает sing-box —
# без него сервер продолжал бы работать со старой копией.
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

echo "=== Установка RU Hysteria2 entry-сервера на sing-box с выходом через EU ==="
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
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban nginx

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

# nginx после установки стартует сам и занимает 80 — гасим,
# порт нужен certbot --standalone
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
open_udp_port "$RU_PORT"

systemctl stop hysteria-server.service 2>/dev/null || true
systemctl disable hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true
systemctl disable hysteria-client-eu.service 2>/dev/null || true

install_singbox
systemctl stop sing-box 2>/dev/null || true

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$RU_DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

CERT_DIR=$(prepare_certs "$RU_DOMAIN")

# Блок обфускации для исходящего соединения RU -> EU.
# Заполняется только если во вставленной EU-ссылке были обнаружены obfs/obfs-password.
EU_OBFS_BLOCK=""
if [[ -n "${EU_OBFS_PASS:-}" ]]; then
  EU_OBFS_BLOCK="      \"obfs\": {
        \"type\": \"salamander\",
        \"password\": \"${EU_OBFS_PASS}\"
      },
"
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
    }
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
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [
          ".ru"
        ],
        "outbound": "ru_direct"
      }
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

# ---- подписка для sing-box ----
write_client_config "${SUB_DIR}/${SUB_TOKEN}"
setup_nginx
setup_renewal_hooks
SUB_URL="https://${RU_DOMAIN}/${SUB_TOKEN}"

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
ufw allow 80/tcp     # certbot --standalone при продлении + редирект на https
ufw allow 443/tcp    # страница подписки
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

PASS_ENC=$(urlencode "$RU_PASS")
DOMAIN_ENC=$(urlencode "$RU_DOMAIN")
OBFS_PASS_ENC=$(urlencode "$RU_OBFS_PASS")
RU_LINK="hysteria2://${PASS_ENC}@${RU_DOMAIN}:${RU_PORT}?peer=${DOMAIN_ENC}&obfs=salamander&obfs-password=${OBFS_PASS_ENC}#hys2"

# nginx мог не пережить ufw --force reset — убеждаемся, что жив
systemctl is-active --quiet nginx || systemctl restart nginx

echo
echo "=== Готово ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "--- Ссылка ---"
echo "$RU_LINK"
echo
echo "--- Подписка ---"
echo "$SUB_URL"
echo
