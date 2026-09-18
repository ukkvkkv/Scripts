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
    listen 80;
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
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
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
        "realitySettings": { "serverName": "${EXIT_SNI}", "fingerprint": "chrome",
          "publicKey": "${EXIT_PBK}", "shortId": "${EXIT_SID}" }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "block" },
      { "domain": ["geosite:category-ru"], "outboundTag": "direct" },
      { "ip": ["geoip:ru"], "outboundTag": "direct" }
    ]
  }
}
EOF

# systemd сам пишет Started/Stopped и предупреждение про nobody — глушим
mkdir -p /etc/systemd/system/xray.service.d
printf '[Service]\nStandardOutput=null\nStandardError=null\nLogLevelMax=err\n' > /etc/systemd/system/xray.service.d/nolog.conf
rm -rf /var/log/xray
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=reality&sni=${DOMAIN}&fp=firefox&pbk=${PUB}&sid=${SID}&type=xhttp&host=${DOMAIN}&path=%2F${XPATH#/}&mode=auto#vless-xhttp-multihop"
mkdir -p "$SUB_DIR"
printf '%s\n' "$LINK" | base64 -w0 > "$SUB_DIR/$SUB_TOKEN"

# --- система ---
printf '%s\n' net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 \
  net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr > /etc/sysctl.d/99-tunnel.conf
sysctl --system >/dev/null

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

ufw --force reset >/dev/null
ufw default deny incoming
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo
echo "SSH порт: $SSH_PORT"
echo "Ссылка:   $LINK"
echo "Подписка: https://${DOMAIN}/${SUB_TOKEN}"
