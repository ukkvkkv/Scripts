#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

# VLESS REALITY стоит на 443, SNI — всегда домен этого сервера.
# Настоящие TLS-хендшейки уходят на локальный nginx с сертом того же домена:
# наружу он не торчит, а REALITY прозрачно пробрасывает на него всех, кто
# пришёл без валидного ключа, — сканер видит обычный сайт с валидным сертом.
VLESS_PORT=443
NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT:-8443}"

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

need_cmd() { command -v "$1" >/dev/null 2>&1; }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

get_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
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

open_tcp_port() {
  local p="$1"
  if need_cmd ufw; then
    ufw allow "${p}/tcp" 2>/dev/null || true
  fi
  if need_cmd iptables; then
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
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

read -rp "Введите домен EU-сервера: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban nginx

# Логов быть не должно: sing-box молчит на level=panic, nginx глушим тут.
# access_log писал бы IP всех, кто постучался, включая сканеры на REALITY.
sed -i -e 's#^[[:space:]]*access_log .*#access_log off;#' \
       -e 's#^[[:space:]]*error_log .*#error_log /dev/null crit;#' \
       /etc/nginx/nginx.conf

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
  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "Порт 80 занят nginx — certbot остановит его на время выпуска и вернёт обратно."
  else
    echo "Ошибка: TCP-порт 80 занят. Освободи его для certbot --standalone и запусти скрипт снова."
    ss -ltnp | grep ':80' || true
    exit 1
  fi
fi

EU_PORT=$(random_port)
EU_PASS=$(random_pass)
EU_OBFS_PASS=$(random_pass)

# Останавливаем старые сервисы. Обязательно ДО проверки занятости 443:
# иначе при повторном запуске скрипт увидит на 443 свой же sing-box
# с прошлого раза и решит, что порт занят чужим сайтом.
systemctl stop hysteria-server.service 2>/dev/null || true
systemctl disable hysteria-server.service 2>/dev/null || true
systemctl stop hysteria-client-eu.service 2>/dev/null || true
systemctl disable hysteria-client-eu.service 2>/dev/null || true
systemctl stop sing-box 2>/dev/null || true

# 443 занимает REALITY, поэтому чужой сайт на нём — это конфликт, который
# скрипт молча разрулить не может. Останавливаемся и говорим, что делать.
if tcp_port_in_use 443; then
  echo "Ошибка: 443/tcp уже занят — его должен слушать sing-box."
  ss -ltnp | grep ':443' || true
  echo
  echo "Если это твой сайт: перевесь его на 127.0.0.1:${NGINX_LOCAL_PORT}"
  echo "(в nginx заменить 'listen 443 ssl;' на 'listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;')"
  echo "и запусти скрипт снова. Сайт продолжит открываться по https://${DOMAIN}/ —"
  echo "REALITY прозрачно пробросит на него всех, кто пришёл без ключа."
  exit 1
fi

ufw allow 80/tcp 2>/dev/null || true
open_udp_port "$EU_PORT"
open_tcp_port "$VLESS_PORT"

install_singbox

# Ключи REALITY и учётка VLESS. Приватный ключ остаётся здесь,
# публичный уезжает в ссылку для RU-ноды.
REALITY_KEYPAIR=$(sing-box generate reality-keypair)
REALITY_PRIVATE=$(echo "$REALITY_KEYPAIR" | awk '/PrivateKey/ {print $2}')
REALITY_PUBLIC=$(echo "$REALITY_KEYPAIR" | awk '/PublicKey/ {print $2}')
VLESS_UUID=$(sing-box generate uuid)
VLESS_SID=$(sing-box generate rand 8 --hex)

if [[ -z "$REALITY_PRIVATE" || -z "$REALITY_PUBLIC" || -z "$VLESS_UUID" || -z "$VLESS_SID" ]]; then
  echo "Ошибка: не удалось сгенерировать параметры REALITY."
  exit 1
fi

# Хук обновления: после продления сертификата раскладываем его в sing-box
# и перезапускаем VPN. Без этого sing-box продолжит жить со старой копией.
cat > /usr/local/bin/singbox-cert-deploy.sh <<EOF_HOOK
#!/bin/sh
set -e
SRC="/etc/letsencrypt/live/${DOMAIN}"
DST="/etc/sing-box/certs/${DOMAIN}"
mkdir -p "\$DST"
cp -f "\$SRC/fullchain.pem" "\$DST/fullchain.pem"
cp -f "\$SRC/privkey.pem" "\$DST/privkey.pem"
chmod 644 "\$DST/fullchain.pem"
if getent group sing-box >/dev/null 2>&1; then
    chgrp -R sing-box "\$DST" || true
    chmod 640 "\$DST/privkey.pem"
else
    chmod 600 "\$DST/privkey.pem"
fi
systemctl restart sing-box
EOF_HOOK
chmod +x /usr/local/bin/singbox-cert-deploy.sh

# Let's Encrypt
# pre/post-хуки освобождают порт 80 на время проверки, если на нём стоит nginx.
CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
CERTBOT_ARGS+=(--pre-hook "systemctl stop nginx 2>/dev/null || true")
CERTBOT_ARGS+=(--post-hook "systemctl start nginx 2>/dev/null || true")
CERTBOT_ARGS+=(--deploy-hook "/usr/local/bin/singbox-cert-deploy.sh")
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

CERT_DIR=$(prepare_certs "$DOMAIN")

# Локальный сайт-заглушка на 127.0.0.1:NGINX_LOCAL_PORT — это dest для REALITY.
# Если на этом порту уже что-то своё (перевешенный сайт) — не трогаем.
if tcp_port_in_use "$NGINX_LOCAL_PORT"; then
  echo "На 127.0.0.1:${NGINX_LOCAL_PORT} уже что-то слушает — беру это как dest, nginx не трогаю."
else
  rm -f /etc/nginx/sites-enabled/default
  install -d -m 755 /var/www/html
  cat > /etc/nginx/sites-available/reality-dest.conf <<EOF_NGINX
server {
    listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;

    server_tokens off;
    root /var/www/html;
    index index.html;
}
EOF_NGINX
  ln -sf /etc/nginx/sites-available/reality-dest.conf \
         /etc/nginx/sites-enabled/reality-dest.conf
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
fi

# REALITY без живого dest не установит ни одного соединения, поэтому
# убеждаемся, что оттуда реально приходит TLS с сертом нашего домена.
sleep 1
DEST_SUBJECT=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:${NGINX_LOCAL_PORT}" \
  -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
if [[ -z "$DEST_SUBJECT" ]]; then
  echo "Ошибка: dest 127.0.0.1:${NGINX_LOCAL_PORT} не отвечает валидным TLS с SNI ${DOMAIN}."
  echo "REALITY без рабочего dest не поднимет ни одного соединения."
  exit 1
fi
echo "dest живой, сертификат: ${DEST_SUBJECT}"

# Конфиг sing-box: hysteria2 + vless-reality, оба выходят через direct
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
      "listen_port": ${EU_PORT},
      "users": [
        {
          "password": "${EU_PASS}"
        }
      ],
      "obfs": {
        "type": "salamander",
        "password": "${EU_OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "certificate_path": "${CERT_DIR}/fullchain.pem",
        "key_path": "${CERT_DIR}/privkey.pem"
      },
      "masquerade": {
        "type": "proxy",
        "url": "https://www.bing.com",
        "rewrite_host": true
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "name": "ru-hop",
          "uuid": "${VLESS_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "127.0.0.1",
            "server_port": ${NGINX_LOCAL_PORT}
          },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": [
            "${VLESS_SID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
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

if ! udp_port_in_use "$EU_PORT"; then
  echo "Ошибка: sing-box не слушает ${EU_PORT}/udp (hysteria2)."
  exit 1
fi
if ! tcp_port_in_use "$VLESS_PORT"; then
  echo "Ошибка: sing-box не слушает ${VLESS_PORT}/tcp (vless-reality)."
  exit 1
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
ufw allow "$EU_PORT"/udp
# 443 — это vless-reality (VLESS_PORT), 80 нужен certbot для продления серта.
ufw allow "$VLESS_PORT"/tcp
ufw allow 80/tcp
ufw --force enable

PASS_ENC=$(urlencode "$EU_PASS")
DOMAIN_ENC=$(urlencode "$DOMAIN")
OBFS_PASS_ENC=$(urlencode "$EU_OBFS_PASS")
EU_LINK="hysteria2://${PASS_ENC}@${DOMAIN}:${EU_PORT}?peer=${DOMAIN_ENC}&obfs=salamander&obfs-password=${OBFS_PASS_ENC}#hy2sb"
EU_VLESS_LINK="vless://${VLESS_UUID}@${DOMAIN}:${VLESS_PORT}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=firefox&pbk=${REALITY_PUBLIC}&sid=${VLESS_SID}#hop-eu"

echo
echo "=== EU-сервер готов: hysteria2 + vless-reality ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo "VLESS REALITY: ${VLESS_PORT}/tcp, SNI ${DOMAIN}, dest 127.0.0.1:${NGINX_LOCAL_PORT}"
echo
echo "--- Обе ссылки скормить RU-скрипту ---"
echo "$EU_LINK"
echo
echo "$EU_VLESS_LINK"
echo
