#!/usr/bin/env bash
# Вход цепочки: клиент → XHTTP/REALITY → entry → raw/REALITY+Vision → exit → интернет.
# Запуск на чистом Ubuntu/Debian от root после exit.sh; спросит его ссылку.
set -Eeuo pipefail

XRAY_VERSION=v26.3.27
SUB_TOKEN=4ab0b523673328390d57976dc5e76729
SUB_DIR=/var/www/sub
ACME_DIR=/var/www/letsencrypt
SITE=/etc/nginx/sites-available/site.conf

[[ -s /root/.ssh/authorized_keys ]] || { echo "Нет /root/.ssh/authorized_keys — вход по паролю будет отключён."; exit 1; }
read -rp "Домен: " DOMAIN
read -rp "Email для Let's Encrypt (можно пусто): " EMAIL
read -rp "Ссылка из exit.sh: " EXIT_LINK

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl certbot nginx fail2ban python3-systemd ufw
sed -i -e 's#^\s*access_log .*#access_log off;#' -e 's#^\s*error_log .*#error_log /dev/null crit;#' /etc/nginx/nginx.conf

# --- IPv6 ---
# Включаем до проверки: disable_ipv6=1 от прошлой установки прячет адрес.
printf '%s\n' net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
  net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr > /etc/sysctl.d/99-tunnel.conf
sysctl --system >/dev/null
# Рабочий v6 = глобальный адрес + дефолтный маршрут + реальный выход наружу. Одного
# маршрута мало: без связности direct ушёл бы в v6 и умер. Пара попыток — SLAAC
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

eval "$(python3 -c '
import sys
from urllib.parse import urlparse, parse_qs
u = urlparse(sys.argv[1]); q = {k: v[0] for k, v in parse_qs(u.query).items()}
print("EXIT_UUID=%s EXIT_HOST=%s EXIT_PORT=%s EXIT_SNI=%s EXIT_PBK=%s EXIT_SID=%s" % (
    u.username, u.hostname, u.port or 443, q["sni"], q["pbk"], q.get("sid", "")))
' "$EXIT_LINK")"

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

# target REALITY (свой домен, только loopback) + подписка
cat >> "$SITE" <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    server_tokens off;
    location = /${SUB_TOKEN} {
        root ${SUB_DIR};
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
}
EOF
nginx -t && systemctl reload nginx

# --- Xray ---
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"
UUID=$(xray uuid)
SID=$(openssl rand -hex 8)
XPATH=/$(openssl rand -hex 5)
KEYS=$(xray x25519)
PRIV=$(awk -F': ' '/^PrivateKey/{print $2}' <<<"$KEYS")
PUB=$(awk -F': ' '/^Password/{print $2}' <<<"$KEYS")

# Российское — напрямую отсюда, остальное — на exit. sniffing даёт geosite домен,
# IPIfNonMatch даёт geoip IP домена (vk.com не .ru, но IP российский).
#
# IPv6. Если v6 у ноды нет, российские v6-адреса нельзя пускать в direct — уйдут
# в никуда, поэтому весь v6 заворачивается на exit правилом ::/0. Чтобы это
# правило не утащило туда же российские домены (у ya.ru и vk.com есть AAAA),
# queryStrategy держит резолвинг для маршрутизации на v4 — тогда ::/0 совпадает
# только с голыми v6-адресами от клиента. Есть v6 — правило не нужно, geoip:ru
# покрывает и v6-диапазоны, direct ходит обеими семьями (так на Beget с 23.09.2026),
# а зарубежный v6 уходит на exit, который без своего v6 его сразу отбивает.
if [[ $HAS_V6 == 1 ]]; then
  DIRECT_STRATEGY=UseIPv4v6; QUERY_STRATEGY=UseIP; V6_RULE=""
else
  DIRECT_STRATEGY=UseIPv4; QUERY_STRATEGY=UseIPv4
  V6_RULE='{ "ip": ["::/0"], "outboundTag": "to-exit" },
      '
fi
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "access": "none", "error": "none", "loglevel": "none" },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "realitySettings": {
        "target": "127.0.0.1:8443",
        "serverNames": ["${DOMAIN}"],
        "privateKey": "${PRIV}",
        "shortIds": ["${SID}"]
      },
      "xhttpSettings": { "host": "${DOMAIN}", "path": "${XPATH}", "mode": "auto" }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    {
      "tag": "to-exit",
      "protocol": "vless",
      "settings": { "vnext": [{ "address": "${EXIT_HOST}", "port": ${EXIT_PORT},
        "users": [{ "id": "${EXIT_UUID}", "encryption": "none", "flow": "xtls-rprx-vision" }] }] },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": { "serverName": "${EXIT_SNI}", "fingerprint": "firefox",
          "publicKey": "${EXIT_PBK}", "shortId": "${EXIT_SID}" }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "${DIRECT_STRATEGY}" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "dns": { "servers": ["localhost"], "queryStrategy": "${QUERY_STRATEGY}" },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "block" },
      ${V6_RULE}{ "domain": ["geosite:category-ru"], "outboundTag": "direct" },
      { "ip": ["geoip:ru"], "outboundTag": "direct" }
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

# В ссылке IP, а не домен: клиенту не нужен DNS (и не мешает закешированный старый адрес)
IP=$(curl -4fsS https://api.ipify.org)
LINK="vless://${UUID}@${IP}:443?encryption=none&security=reality&sni=${DOMAIN}&fp=firefox&pbk=${PUB}&sid=${SID}&type=xhttp&host=${DOMAIN}&path=%2F${XPATH#/}&mode=auto#vless"
mkdir -p "$SUB_DIR"
printf '%s\n' "$LINK" | base64 -w0 > "$SUB_DIR/$SUB_TOKEN"

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
echo "Ссылка:   $LINK"
echo "Подписка: https://${DOMAIN}/${SUB_TOKEN}"
