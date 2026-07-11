#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
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

random_path() {
  echo "/$(openssl rand -hex 6)"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

open_tcp_port() {
  local p="$1"
  if need_cmd ufw; then
    ufw allow "${p}/tcp" 2>/dev/null || true
  fi
  if need_cmd iptables; then
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
    iptables -C OUTPUT -p tcp --sport "$p" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p tcp --sport "$p" -j ACCEPT || true
  fi
}

install_xray() {
  if ! need_cmd xray; then
    echo "Устанавливаю Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  else
    echo "Xray уже установлен: $(xray version | head -n 1)"
  fi
}

prepare_certs() {
  local domain="$1"
  local src_dir="/etc/letsencrypt/live/${domain}"
  local dst_dir="/usr/local/etc/xray/certs/${domain}"

  if [[ ! -f "${src_dir}/fullchain.pem" || ! -f "${src_dir}/privkey.pem" ]]; then
    echo "Ошибка: сертификаты Let's Encrypt не найдены для ${domain}"
    exit 1
  fi

  mkdir -p "$dst_dir"
  cp -f "${src_dir}/fullchain.pem" "${dst_dir}/fullchain.pem"
  cp -f "${src_dir}/privkey.pem" "${dst_dir}/privkey.pem"

  local xray_group
  xray_group=$(id -gn nobody 2>/dev/null || echo nogroup)

  chmod 755 /usr/local/etc/xray/certs
  chmod 750 "$dst_dir"
  chgrp -R "$xray_group" "$dst_dir"
  chmod 644 "${dst_dir}/fullchain.pem"
  chmod 640 "${dst_dir}/privkey.pem"

  echo "$dst_dir"
}
parse_vless_link() {
  local link="$1"
  python3 - "$link" <<'PY'
import sys, urllib.parse as up, shlex

link = sys.argv[1]
if not link.startswith("vless://"):
    sys.exit("not a vless link")

rest = link[len("vless://"):]
rest, _, _frag = rest.partition('#')
userinfo, _, hostpart = rest.partition('@')
if not userinfo or not hostpart:
    sys.exit("malformed vless link")

hostport, _, query = hostpart.partition('?')
if ':' in hostport:
    host, port = hostport.rsplit(':', 1)
else:
    host, port = hostport, '443'

params = dict(up.parse_qsl(query))

out = {
    "EXIT_UUID": userinfo,
    "EXIT_HOST": host,
    "EXIT_PORT": port,
    "EXIT_SNI": params.get("sni") or params.get("peer") or host,
    "EXIT_PATH": params.get("path", "/"),
    "EXIT_SECURITY": params.get("security", "tls"),
    "EXIT_NETWORK": params.get("type", "xhttp"),
}
for k, v in out.items():
    print(f"{k}={shlex.quote(v)}")
PY
}

read -rp "Введите домен сервера: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $DOMAIN"
  exit 1
fi

echo
echo "Вставь vless-ссылку"
read -rp "> " EXIT_LINK
if [[ "$EXIT_LINK" != vless://* ]]; then
  echo "Ошибка: это не похоже на vless-ссылку"
  exit 1
fi

eval "$(parse_vless_link "$EXIT_LINK")"

echo
echo "  host:    $EXIT_HOST"
echo "  port:    $EXIT_PORT"
echo "  sni:     $EXIT_SNI"
echo "  path:    $EXIT_PATH"
echo "  network: $EXIT_NETWORK"
echo "  security: $EXIT_SECURITY"
echo

EMAIL=""

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban

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

VLESS_PORT=8443
if port_in_use "$VLESS_PORT"; then
  echo "Ошибка: TCP-порт $VLESS_PORT уже занят."
  ss -ltnp | grep ":${VLESS_PORT}" || true
  exit 1
fi
XHTTP_PATH=$(random_path)

ufw allow 80/tcp 2>/dev/null || true
open_tcp_port "$VLESS_PORT"

systemctl stop xray 2>/dev/null || true

install_xray

UUID=$(xray uuid)

CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

CERT_DIR=$(prepare_certs "$DOMAIN")
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF_CONF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp-in",
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "minVersion": "1.2",
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/privkey.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "chain-to-exit",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${EXIT_HOST}",
            "port": ${EXIT_PORT},
            "users": [
              {
                "id": "${EXIT_UUID}",
                "flow": "",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "${EXIT_NETWORK}",
        "xhttpSettings": {
          "path": "${EXIT_PATH}",
          "mode": "auto"
        },
        "security": "${EXIT_SECURITY}",
        "tlsSettings": {
          "serverName": "${EXIT_SNI}"
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-xhttp-in"],
        "outboundTag": "chain-to-exit"
      }
    ]
  }
}
EOF_CONF

xray run -test -c /usr/local/etc/xray/config.json
systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray
sleep 2

if ! systemctl is-active --quiet xray; then
  echo "Ошибка: xray не запустился. Логи:"
  journalctl --no-pager -e -u xray
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
ufw allow "$VLESS_PORT"/tcp
ufw --force enable

DOMAIN_ENC=$(urlencode "$DOMAIN")
PATH_ENC=$(urlencode "$XHTTP_PATH")
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?type=xhttp&security=tls&sni=${DOMAIN_ENC}&path=${PATH_ENC}&mode=auto&fp=firefox&obfs=xhttp&tls=1&peer=${DOMAIN_ENC}&udp=3&fingerprint=firefox#xhttp"

echo
echo "=== Готово ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "$VLESS_LINK"
