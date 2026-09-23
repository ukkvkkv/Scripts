#!/usr/bin/env bash
# Выход цепочки: клиент → XHTTP/REALITY → entry → raw/REALITY+Vision → exit → интернет.
# Запуск на чистом Ubuntu/Debian от root. В конце печатает ссылку для entry.sh.
set -Eeuo pipefail

XRAY_VERSION=v26.3.27
ACME_DIR=/var/www/letsencrypt
SITE=/etc/nginx/sites-available/site.conf

[[ -s /root/.ssh/authorized_keys ]] || { echo "Нет /root/.ssh/authorized_keys — вход по паролю будет отключён."; exit 1; }
read -rp "Домен: " DOMAIN
read -rp "Email для Let's Encrypt (можно пусто): " EMAIL

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl certbot nginx fail2ban python3-systemd ufw
sed -i -e 's#^\s*access_log .*#access_log off;#' -e 's#^\s*error_log .*#error_log /dev/null crit;#' /etc/nginx/nginx.conf

# --- IPv6 ---
# Включаем до проверки: disable_ipv6=1 от прошлой установки прячет адрес.
printf '%s\n' net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
  net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr > /etc/sysctl.d/99-tunnel.conf
sysctl --system >/dev/null
# Рабочий v6 = глобальный адрес + дефолтный маршрут + реальный выход наружу. Одного
# маршрута мало: без связности freedom ушёл бы в v6 и умер. Пара попыток — SLAAC
# после включения v6 приходит не сразу.
V6_ADDR=""
for _ in 1 2 3 4 5; do
  if ip -6 addr show scope global | grep -q inet6 && ip -6 route show default | grep -q .; then
    V6_ADDR=$(curl -6fsS -m 5 https://api6.ipify.org 2>/dev/null) && break
  fi
  sleep 2
done
HAS_V6=0; [[ -n "$V6_ADDR" ]] && HAS_V6=1
if [[ $HAS_V6 == 1 ]]; then V6_STATUS="есть, $V6_ADDR"
elif ip -6 addr show scope global | grep -q inet6; then V6_STATUS="адрес есть, но наружу не ходит — считаю, что нет"
else V6_STATUS="нет"; fi
echo "IPv6: $V6_STATUS"
# Let's Encrypt предпочитает AAAA: при AAAA-записи на ноде без v6 certbot не пройдёт
if [[ $HAS_V6 == 0 ]] && python3 -c 'import socket,sys; socket.getaddrinfo(sys.argv[1], 80, socket.AF_INET6)' "$DOMAIN" 2>/dev/null; then
  echo "У $DOMAIN есть AAAA-запись, а у ноды нет IPv6 — удали AAAA или почини v6."; exit 1
fi
V6_LISTEN=""; [[ $HAS_V6 == 1 ]] && V6_LISTEN=$'\n    listen [::]:80;'

# --- сертификат (webroot: nginx при продлении не гасится) ---
rm -f /etc/nginx/sites-enabled/default
mkdir -p "$ACME_DIR"
cat > "$SITE" <<EOF
server {
    listen 80;${V6_LISTEN}
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root ${ACME_DIR}; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf "$SITE" /etc/nginx/sites-enabled/site.conf
systemctl restart nginx
EMAIL_ARG=(--register-unsafely-without-email); [[ -n "$EMAIL" ]] && EMAIL_ARG=(-m "$EMAIL")
certbot certonly --webroot -w "$ACME_DIR" -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring "${EMAIL_ARG[@]}"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# target REALITY: свой домен с настоящим сертификатом и заглушкой, только на loopback
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>Сайт в разработке</title>
<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;font:16px/1.6 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#333;background:#fafafa}h1{font-size:22px;font-weight:600;margin:0 0 8px}p{margin:0;color:#666}</style>
</head><body><main style="text-align:center"><h1>Сайт в разработке</h1><p>Страница появится позже.</p></main></body></html>
EOF
cat >> "$SITE" <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    server_tokens off;
    root /var/www/html;
}
EOF
nginx -t && systemctl reload nginx

# --- Xray ---
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"
UUID=$(xray uuid)
SID=$(openssl rand -hex 8)
KEYS=$(xray x25519)
PRIV=$(awk -F': ' '/^PrivateKey/{print $2}' <<<"$KEYS")
PUB=$(awk -F': ' '/^Password/{print $2}' <<<"$KEYS")

# Есть v6 — UseIPv4v6: сначала v4 (адрес выхода у сайтов остаётся привычным), при
# отсутствии A-записи — v6; голые v6-адреса freedom отдаёт как есть. Нет v6 — только
# v4, а голый v6 сразу в blackhole: клиент получает быстрый отказ и откатывается на
# v4, вместо того чтобы ждать таймаута.
if [[ $HAS_V6 == 1 ]]; then
  DIRECT_STRATEGY=UseIPv4v6; V6_RULE=""
else
  DIRECT_STRATEGY=UseIPv4; V6_RULE='{ "ip": ["::/0"], "outboundTag": "block" },
      '
fi
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "access": "none", "error": "none", "loglevel": "none" },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "email": "entry-relay", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "target": "127.0.0.1:8443",
        "serverNames": ["${DOMAIN}"],
        "privateKey": "${PRIV}",
        "shortIds": ["${SID}"]
      }
    }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "${DIRECT_STRATEGY}" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      ${V6_RULE}{ "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

# systemd сам пишет Started/Stopped и предупреждение про nobody — глушим
mkdir -p /etc/systemd/system/xray.service.d
printf '[Service]\nStandardOutput=null\nStandardError=null\nLogLevelMax=err\n' > /etc/systemd/system/xray.service.d/nolog.conf
rm -rf /var/log/xray
xray run -test -c /usr/local/etc/xray/config.json >/dev/null
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# --- система ---
# SSH: drop-in с 00-, т.к. в sshd побеждает первое значение, а 50-cloud-init.conf
# включает пароль. Port накапливается — из основного конфига его убираем.
SSH_PORT=$(shuf -i 20000-60000 -n 1)
sed -i '/^\s*#\?\s*Port\s/d' /etc/ssh/sshd_config
printf 'Port %s\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' \
  "$SSH_PORT" > /etc/ssh/sshd_config.d/00-hardening.conf
mkdir -p /run/sshd && sshd -t
# Ubuntu 24.04: ssh.socket держит порт 22 и игнорирует Port
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
systemctl restart ssh

printf '[sshd]\nenabled = true\nport = %s\nbackend = systemd\n' "$SSH_PORT" > /etc/fail2ban/jail.d/sshd.conf
systemctl restart fail2ban

sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw   # иначе ufw не открывает порты по v6
ufw --force reset >/dev/null
ufw default deny incoming
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo
echo "SSH порт: $SSH_PORT"
echo "IPv6:     $V6_STATUS"
echo "Ссылка для entry.sh:"
echo "vless://${UUID}@${DOMAIN}:443?type=tcp&security=reality&sni=${DOMAIN}&fp=firefox&pbk=${PUB}&sid=${SID}&flow=xtls-rprx-vision#exit-relay"
