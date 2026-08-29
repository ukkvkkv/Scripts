#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo -i, затем повтори команду."
  exit 1
fi

SUB_TOKEN="4ab0b523673328390d57976dc5e76729"
SUB_DIR="/var/www/sub"
SUB_BASE64="1"

if ! [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
  echo "Ошибка: не задан токен подписки (SUB_TOKEN)."
  echo
  echo "Впиши его в переменную SUB_TOKEN в шапке скрипта."
  echo "Сгенерировать новый:  openssl rand -hex 16"
  exit 1
fi

SUB_PATH="/${SUB_TOKEN}"
SUB_FILE="${SUB_DIR}${SUB_PATH}"
SITE_DIR="${SITE_DIR:-/var/www/html}"
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

write_link_config() {
  local out="$1"
  install -d -m 755 "$(dirname "$out")"

  local payload="$RU_LINK"
  if [[ -n "${RU_VLESS_LINK:-}" ]]; then
    payload="${RU_LINK}
${RU_VLESS_LINK}"
  fi

  if [[ "$SUB_BASE64" == "1" ]]; then
    printf '%s\n' "$payload" | base64 -w0 > "$out"
  else
    printf '%s\n' "$payload" > "$out"
  fi

  chmod 644 "$out"

  if [[ ! -s "$out" ]]; then
    echo "Ошибка: файл подписки пустой: $out"
    exit 1
  fi
}
make_site() {
  local dir="$1"
  install -d -m 755 "$dir"
  if [[ -f "$dir/index.html" ]]; then
    return 0
  fi
  cat > "$dir/index.html" <<'EOF_SITE'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Сайт в разработке</title>
<style>
    html, body { height: 100%; margin: 0; }
    body {
        display: flex; align-items: center; justify-content: center;
        font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
        color: #333; background: #fafafa;
    }
    main { text-align: center; padding: 24px; }
    h1 { font-size: 22px; font-weight: 600; margin: 0 0 8px; }
    p { margin: 0; color: #666; }
</style>
</head>
<body>
<main>
<h1>Сайт в разработке</h1>
<p>Страница появится позже.</p>
</main>
</body>
</html>
EOF_SITE
  chmod 644 "$dir/index.html"
}

setup_nginx() {
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/subscription.conf /etc/nginx/sites-available/subscription.conf
  local ssl_listen="listen 443 ssl;"
  if [[ "$VLESS_ENABLED" == "1" ]]; then
    ssl_listen="listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;"
  fi

  make_site "$SITE_DIR"
  cat > /etc/nginx/sites-available/reality-dest.conf <<EOF_NGINX
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
    access_log off;          

    root ${SITE_DIR};
    index index.html;

    location = ${SUB_PATH} {
        root ${SUB_DIR};
        default_type "text/plain; charset=utf-8";
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
}
EOF_NGINX

  ln -sf /etc/nginx/sites-available/reality-dest.conf \
         /etc/nginx/sites-enabled/reality-dest.conf

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

AWG_PORT="${AWG_PORT:-443}"
AWG_SUBNET_PREFIX=10.8.0
AWG_TABLE_HOP=100
AWG_TABLE_RU=101

install_amneziawg() {
  if need_cmd awg && modinfo amneziawg >/dev/null 2>&1; then
    echo "AmneziaWG уже установлен: $(awg --version | head -n 1)"
    return 0
  fi
  echo "Устанавливаю AmneziaWG (модуль собирается через DKMS)..."
  apt install -y software-properties-common linux-headers-generic
  add-apt-repository -y ppa:amnezia/ppa
  apt update
  apt install -y amneziawg-dkms amneziawg-tools
  if ! modprobe amneziawg; then
    echo "Ошибка: модуль amneziawg не загрузился."
    echo "Обычно это значит, что linux-headers не совпадают с текущим ядром."
    echo "Проверь: dkms status; uname -r; ls -d /usr/src/linux-headers-*"
    exit 1
  fi
  echo "AmneziaWG: модуль $(modinfo -F version amneziawg), утилиты $(awg --version | head -n 1)"
}
gen_awg_params() {
  AWG_JC=$(shuf -i 3-6 -n 1)
  AWG_JMIN=$(shuf -i 40-89 -n 1)
  AWG_JMAX=$(( AWG_JMIN + $(shuf -i 50-250 -n 1) ))

  AWG_S1=$(shuf -i 15-150 -n 1)
  AWG_S2=$(shuf -i 15-150 -n 1)
  while [[ $(( AWG_S1 + 56 )) -eq "$AWG_S2" ]]; do AWG_S2=$(shuf -i 15-150 -n 1); done
  AWG_S3=$(shuf -i 15-55 -n 1)
  while [[ $(( AWG_S2 + 28 )) -eq "$AWG_S3" ]]; do AWG_S3=$(shuf -i 15-55 -n 1); done
  AWG_S4=$(shuf -i 15-55 -n 1)

  AWG_H1=$(shuf -i 10-2147483647 -n 1)
  AWG_H2=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H2" == "$AWG_H1" ]]; do AWG_H2=$(shuf -i 10-2147483647 -n 1); done
  AWG_H3=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H3" == "$AWG_H1" || "$AWG_H3" == "$AWG_H2" ]]; do AWG_H3=$(shuf -i 10-2147483647 -n 1); done
  AWG_H4=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H4" == "$AWG_H1" || "$AWG_H4" == "$AWG_H2" || "$AWG_H4" == "$AWG_H3" ]]; do
    AWG_H4=$(shuf -i 10-2147483647 -n 1)
  done
}
parse_awg_hop() {
  local raw="${1#AWGHOP1:}" decoded line k v
  decoded=$(printf '%s' "$raw" | tr -d ' \t\n\r' | base64 -d 2>/dev/null || true)
  if [[ -z "$decoded" ]]; then
    echo "Ошибка: hop-строку не удалось разобрать. Нужна строка вида AWGHOP1:<base64>" >&2
    exit 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      ENDPOINT)   HOP_ENDPOINT="$v" ;;
      SERVER_PUB) HOP_SERVER_PUB="$v" ;;
      HPK)        HOP_HPK="$v" ;;
      JC)         HOP_JC="$v" ;;
      JMIN)       HOP_JMIN="$v" ;;
      JMAX)       HOP_JMAX="$v" ;;
      S1)         HOP_S1="$v" ;;
      S2)         HOP_S2="$v" ;;
      S3)         HOP_S3="$v" ;;
      S4)         HOP_S4="$v" ;;
      H1)         HOP_H1="$v" ;;
      H2)         HOP_H2="$v" ;;
      H3)         HOP_H3="$v" ;;
      H4)         HOP_H4="$v" ;;
      HOP_PRIV)   HOP_PRIV="$v" ;;
      HOP_IP)     HOP_IP="$v" ;;
    esac
  done <<< "$decoded"

  local var
  for var in HOP_ENDPOINT HOP_SERVER_PUB HOP_HPK HOP_PRIV HOP_IP \
             HOP_JC HOP_JMIN HOP_JMAX HOP_S1 HOP_S2 HOP_S3 HOP_S4 \
             HOP_H1 HOP_H2 HOP_H3 HOP_H4; do
    if [[ -z "${!var:-}" ]]; then
      echo "Ошибка: в hop-строке нет поля ${var#HOP_}." >&2
      exit 1
    fi
  done
}

setup_awg_entry() {
  local wan
  wan=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  [[ -n "$wan" ]] || { echo "Ошибка: не удалось определить внешний интерфейс."; exit 1; }

  if udp_port_in_use "$AWG_PORT"; then
    echo "Ошибка: ${AWG_PORT}/udp уже занят — его должен слушать AmneziaWG."
    ss -lunp | grep ":${AWG_PORT}" || true
    exit 1
  fi

  install_amneziawg
  gen_awg_params
  sysctl -qw net.ipv4.ip_forward=1
  install -d -m 700 /etc/amnezia/amneziawg
  local old_umask; old_umask=$(umask); umask 077
  cat > /etc/amnezia/amneziawg/awg1.conf <<EOF_AWG1
[Interface]
PrivateKey = ${HOP_PRIV}
Address = ${HOP_IP}/32
MTU = 1420
Table = off
HeaderProtectionKey = ${HOP_HPK}
Jc = ${HOP_JC}
Jmin = ${HOP_JMIN}
Jmax = ${HOP_JMAX}
S1 = ${HOP_S1}
S2 = ${HOP_S2}
S3 = ${HOP_S3}
S4 = ${HOP_S4}
H1 = ${HOP_H1}
H2 = ${HOP_H2}
H3 = ${HOP_H3}
H4 = ${HOP_H4}
PostUp = ip rule add from ${AWG_SUBNET_PREFIX}.0/24 lookup ${AWG_TABLE_HOP}
PostUp = ip route add default dev %i table ${AWG_TABLE_HOP}
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostDown = ip rule del from ${AWG_SUBNET_PREFIX}.0/24 lookup ${AWG_TABLE_HOP} 2>/dev/null || true
PostDown = ip route del default dev %i table ${AWG_TABLE_HOP} 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${HOP_SERVER_PUB}
Endpoint = ${HOP_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_AWG1
  chmod 600 /etc/amnezia/amneziawg/awg1.conf
  AWG_SRV_PRIV=$(awg genkey)
  AWG_SRV_PUB=$(echo "$AWG_SRV_PRIV" | awg pubkey)
  AWG_HPK=$(openssl rand -base64 32)

  cat > /etc/amnezia/amneziawg/awg0.conf <<EOF_AWG0
[Interface]
PrivateKey = ${AWG_SRV_PRIV}
Address = ${AWG_SUBNET_PREFIX}.1/24
ListenPort = ${AWG_PORT}
MTU = 1280
HeaderProtectionKey = ${AWG_HPK}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT
PostUp = iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostUp = iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostUp = iptables -I FORWARD -i %i -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
EOF_AWG0
  chmod 600 /etc/amnezia/amneziawg/awg0.conf
  cat > /root/awg0-params.env <<EOF_PARAMS
JC=${AWG_JC}
JMIN=${AWG_JMIN}
JMAX=${AWG_JMAX}
S1=${AWG_S1}
S2=${AWG_S2}
S3=${AWG_S3}
S4=${AWG_S4}
H1=${AWG_H1}
H2=${AWG_H2}
H3=${AWG_H3}
H4=${AWG_H4}
ENDPOINT=${PUBLIC_IP}:${AWG_PORT}
EOF_PARAMS
  chmod 600 /root/awg0-params.env
  printf '%s\n' "$AWG_HPK" > /root/awg0-hpk.txt
  printf '%s\n' "$AWG_SRV_PUB" > /root/awg0-server.pub
  chmod 600 /root/awg0-hpk.txt

  umask "$old_umask"

  systemctl enable --now awg-quick@awg1
  systemctl enable --now awg-quick@awg0
  sleep 3

  local unit
  for unit in awg-quick@awg1 awg-quick@awg0; do
    if ! systemctl is-active --quiet "$unit"; then
      echo "Ошибка: $unit не запустился. Логи:"
      journalctl --no-pager -e -u "$unit" | tail -n 30
      exit 1
    fi
  done
  if ! udp_port_in_use "$AWG_PORT"; then
    echo "Ошибка: AmneziaWG не слушает ${AWG_PORT}/udp."
    exit 1
  fi
  local hs=""
  for _ in {1..10}; do
    hs=$(awg show awg1 latest-handshakes | awk '{print $2}' | head -n 1)
    [[ "${hs:-0}" != "0" ]] && break
    sleep 2
  done
  if [[ "${hs:-0}" == "0" ]]; then
    echo "ВНИМАНИЕ: рукопожатия с (${HOP_ENDPOINT}) пока нет."
    echo "Проверь, что на выходной ноде открыт ${AWG_PORT}/udp и hop-строка свежая."
  else
    echo "Рукопожатие с ${HOP_ENDPOINT} есть."
  fi
}
setup_ru_routes() {
  cat > /usr/local/sbin/awg-ru-routes <<'EOF_RU'
#!/usr/bin/env bash
set -euo pipefail

CLIENT_SUBNET=10.8.0.0/24
TABLE=101
RULE_PRIO=32764
CACHE_DIR=/var/lib/awg-ru-routes
CACHE="$CACHE_DIR/ru.zone"
MIN_PREFIXES=1000
URL_PRIMARY=https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone

log() { echo "[awg-ru-routes] $*"; }

install -d -m 755 "$CACHE_DIR"

# Шлюз и интерфейс берём из системы, а не хардкодим: смена шлюза провайдером
# не должна тихо оставить таблицу с мёртвыми маршрутами.
read -r GW DEV < <(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) {if ($i == "via") g = $(i + 1); if ($i == "dev") d = $(i + 1)} print g, d; exit}')
if [[ -z "${GW:-}" || -z "${DEV:-}" ]]; then
    log "не удалось определить шлюз по умолчанию"; exit 1
fi

if ! iptables -t nat -C POSTROUTING -s "$CLIENT_SUBNET" -o "$DEV" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -o "$DEV" -j MASQUERADE
    log "NAT для прямого выхода добавлен"
fi

TMP="$(mktemp /tmp/ru-zone.XXXXXX)"
trap 'rm -f "$TMP" "$TMP.batch"' EXIT

if curl -fsS --max-time 60 -o "$TMP" "$URL_PRIMARY"; then
    COUNT=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$TMP" || true)
    if [[ "$COUNT" -ge "$MIN_PREFIXES" ]]; then
        install -m 644 "$TMP" "$CACHE"
        log "загружено префиксов: $COUNT"
    else
        # Обрезанный или подменённый ответ не должен обнулить маршрутизацию.
        log "ответ подозрительно короткий ($COUNT префиксов), беру кэш"
    fi
else
    log "загрузка не удалась, беру кэш"
fi

if [[ ! -s "$CACHE" ]]; then
    log "кэша нет и загрузка не удалась — маршруты не тронуты"; exit 1
fi

if ! ip rule list | grep -q "from ${CLIENT_SUBNET} lookup ${TABLE}"; then
    ip rule add from "$CLIENT_SUBNET" lookup "$TABLE" priority "$RULE_PRIO"
    log "правило маршрутизации добавлено"
fi

grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$CACHE" \
    | awk -v gw="$GW" -v dev="$DEV" -v t="$TABLE" '{print "route add " $1 " via " gw " dev " dev " table " t}' \
    > "$TMP.batch"

ip route flush table "$TABLE" 2>/dev/null || true
ip -force -batch "$TMP.batch"
log "в таблице $TABLE маршрутов: $(ip route show table "$TABLE" | wc -l) (шлюз $GW, $DEV)"
EOF_RU
  chmod 755 /usr/local/sbin/awg-ru-routes

  cat > /etc/systemd/system/awg-ru-routes.service <<'EOF_RU_SVC'
[Unit]
Description=Российские префиксы в таблицу 101 для сплит-роутинга AmneziaWG
After=network-online.target awg-quick@awg1.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/awg-ru-routes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_RU_SVC

  cat > /etc/systemd/system/awg-ru-routes.timer <<'EOF_RU_TIMER'
[Unit]
Description=Еженедельное обновление списка российских префиксов

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF_RU_TIMER

  systemctl daemon-reload
  systemctl enable --now awg-ru-routes.service
  systemctl enable --now awg-ru-routes.timer
  echo "Сплит-роутинг: $(ip route show table 101 | wc -l) российских префиксов идут напрямую"
}

install_vpn_cli() {
  cat > /usr/local/sbin/vpn <<'EOF_AWGCLI'
#!/usr/bin/env bash
set -euo pipefail

IFACE=awg0
CONF=/etc/amnezia/amneziawg/${IFACE}.conf
CLIENTS_DIR=/root/awg/clients
PARAMS=/root/awg0-params.env
HPK_FILE=/root/awg0-hpk.txt
SERVER_PUB=/root/awg0-server.pub
SUBNET_PREFIX=10.8.0
DNS_LINE="8.8.8.8, 8.8.4.4"
MTU=1280

die() { echo "Ошибка: $*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
Использование: vpn <команда>

  add <имя>...       добавить клиента(ов), адрес подбирается автоматически
  remove <имя>...    удалить клиента(ов)
  list               таблица: имя, адрес, последнее рукопожатие
  names              только имена, по одному в строке (для скриптов)
  show <имя>         вывести один конфиг в stdout
  dump [имя...]      tar.gz со всеми (или указанными) конфигами в stdout

USAGE
}

case "${1:-}" in
    help|--help|-h|"") usage; exit 1 ;;
esac

[[ $EUID -eq 0 ]] || die "нужен root"
[[ -r "$CONF" ]] || die "нет конфига сервера: $CONF"
[[ -r "$PARAMS" ]] || die "нет параметров обфускации: $PARAMS"
[[ -s "$HPK_FILE" ]] || die "нет ключа защиты заголовков: $HPK_FILE"

next_free_ip() {
    local used n
    used=$(grep -oE "^AllowedIPs *= *${SUBNET_PREFIX}\.[0-9]+" "$CONF" | grep -oE '[0-9]+$' || true)
    for n in $(seq 2 254); do
        if ! grep -qx "$n" <<< "$used"; then
            echo "${SUBNET_PREFIX}.${n}"
            return 0
        fi
    done
    die "свободных адресов в ${SUBNET_PREFIX}.0/24 не осталось"
}

peer_pubkey_by_name() {
    awk -v want="$1" '
        /^#_Name *=/    { n = $0; sub(/^#_Name *= */, "", n) }
        /^PublicKey *=/ { if (n == want) { k = $0; sub(/^PublicKey *= */, "", k); print k; exit } }
    ' "$CONF"
}

cmd_add() {
    [[ $# -ge 1 ]] || die "укажи имя: vpn add <имя> [имя2 ...]"
    # shellcheck disable=SC1090
    . "$PARAMS"
    [[ -n "${ENDPOINT:-}" ]] || die "в $PARAMS нет ENDPOINT"
    local hpk spub name ip priv pub
    hpk=$(cat "$HPK_FILE")
    spub=$(cat "$SERVER_PUB")
    install -d -m 700 "$CLIENTS_DIR"
    for name in "$@"; do
        [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "недопустимое имя: $name"
        [[ -z "$(peer_pubkey_by_name "$name")" ]] || die "клиент уже существует: $name"
        ip=$(next_free_ip)
        priv=$(awg genkey)
        pub=$(echo "$priv" | awg pubkey)
        printf '\n[Peer]\n#_Name = %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$ip" >> "$CONF"
        awg set "$IFACE" peer "$pub" allowed-ips "$ip/32"
        ( umask 077
          cat > "$CLIENTS_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $DNS_LINE
MTU = $MTU
HeaderProtectionKey = $hpk
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $spub
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 33
EOF
        )
        echo "добавлен $name -> $ip ($CLIENTS_DIR/$name.conf)"
    done
}

cmd_remove() {
    [[ $# -ge 1 ]] || die "укажи имя: vpn remove <имя>"
    local name pub
    for name in "$@"; do
        pub=$(peer_pubkey_by_name "$name")
        [[ -n "$pub" ]] || die "нет такого клиента: $name"
        awg set "$IFACE" peer "$pub" remove || true
        # Абзацный режим awk (RS="") надёжнее построчного удаления: блок [Peer]
        # всегда отделён пустой строкой.
        awk -v want="#_Name = $name" '
            BEGIN { RS = ""; ORS = "\n\n" }
            {
                if ($0 ~ /^\[Peer\]/ && index($0, want) > 0) next
                print
            }
        ' "$CONF" > "$CONF.tmp"
        mv "$CONF.tmp" "$CONF"
        chmod 600 "$CONF"
        rm -f "$CLIENTS_DIR/$name.conf"
        echo "удалён $name"
    done
}

cmd_list() {
    local now name ip pub hs age
    now=$(date +%s)
    printf '%-16s %-14s %s\n' "ИМЯ" "АДРЕС" "ПОСЛЕДНЕЕ РУКОПОЖАТИЕ"
    while read -r name ip pub; do
        hs=$(awg show "$IFACE" latest-handshakes | awk -v k="$pub" '$1 == k { print $2 }')
        if [[ -z "$hs" || "$hs" == "0" ]]; then
            age="никогда"
        else
            age="$(( (now - hs) / 60 )) мин назад"
        fi
        printf '%-16s %-14s %s\n' "$name" "$ip" "$age"
    done < <(awk '
        /^#_Name *=/     { n = $0; sub(/^#_Name *= */, "", n) }
        /^PublicKey *=/  { k = $0; sub(/^PublicKey *= */, "", k) }
        /^AllowedIPs *=/ { a = $0; sub(/^AllowedIPs *= */, "", a); if (n != "") { print n, a, k; n = "" } }
    ' "$CONF")
}


cmd_show() {
    [[ $# -eq 1 ]] || die "укажи ровно одно имя: vpn show <имя>"
    local f="$CLIENTS_DIR/$1.conf"
    [[ -r "$f" ]] || die "нет конфига: $1"
    cat "$f"
}

cmd_dump() {
    [[ -d "$CLIENTS_DIR" ]] || die "нет каталога клиентов: $CLIENTS_DIR"
    local n names=()
    if [[ $# -eq 0 ]]; then
        shopt -s nullglob
        for n in "$CLIENTS_DIR"/*.conf; do names+=("$(basename "$n")"); done
        shopt -u nullglob
        [[ ${#names[@]} -gt 0 ]] || die "конфигов нет"
    else
        for n in "$@"; do
            [[ -r "$CLIENTS_DIR/$n.conf" ]] || die "нет конфига: $n"
            names+=("$n.conf")
        done
    fi
    tar -C "$CLIENTS_DIR" -czf - "${names[@]}"
}

cmd_names() {
    awk '/^#_Name *=/ { n = $0; sub(/^#_Name *= */, "", n); print n }' "$CONF"
}

case "$1" in
    add)    shift; cmd_add "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    list)   cmd_list ;;
    names)  cmd_names ;;
    show)   shift; cmd_show "$@" ;;
    dump)   shift; cmd_dump "$@" ;;
    *)      usage; exit 1 ;;
esac
EOF_AWGCLI
  chmod 755 /usr/local/sbin/vpn
}

create_awg_clients() {
  local n="${1:-0}" i names=()
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 )) || { echo "Клиенты не создавались."; return 0; }
  for i in $(seq -w 1 "$n"); do
    names+=("user$i")
  done
  /usr/local/sbin/vpn add "${names[@]}" > /dev/null
  echo "Клиентов создано: $(/usr/local/sbin/vpn names | wc -l)"
}

echo "=== Установка ==="
read -rp "Введите домен : " RU_DOMAIN
RU_DOMAIN="${RU_DOMAIN,,}"
if ! valid_domain "$RU_DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $RU_DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL
read -rp "Вставь ссылку hysteria2://...: " EU_LINK

eval "$(parse_eu_link "$EU_LINK")"

echo

read -rp "Вставь ссылку vless://...: " EU_VLESS_LINK

VLESS_ENABLED=0
if [[ -n "${EU_VLESS_LINK// /}" ]]; then
  eval "$(parse_eu_vless_link "$EU_VLESS_LINK")"
  VLESS_ENABLED=1
fi

echo
read -rp "Вставь строку AWGHOP1: " AWG_HOP_STRING
parse_awg_hop "$AWG_HOP_STRING"

read -rp "Сколько клиентских конфигов создать? [30]: " AWG_CLIENTS
AWG_CLIENTS="${AWG_CLIENTS:-30}"
if ! [[ "$AWG_CLIENTS" =~ ^[0-9]+$ ]] || (( AWG_CLIENTS > 250 )); then
  echo "Ошибка: нужно число от 0 до 250 (в подсети ${AWG_SUBNET_PREFIX}.0/24 больше не поместится)."
  exit 1
fi

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban nginx
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

write_link_config "${SUB_FILE}"
setup_nginx
setup_renewal_hooks
SUB_URL="https://${RU_DOMAIN}${SUB_PATH}"

sleep 1
SUB_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SUB_URL" || echo "000")
if [[ "$SUB_CODE" != "200" ]]; then
  echo "ВНИМАНИЕ: подписка ${SUB_URL} отдала код ${SUB_CODE}, а не 200."
  echo "Ссылки ниже рабочие, но по URL клиент их не получит — проверь nginx и REALITY handshake."
fi

if [[ "$VLESS_ENABLED" == "1" ]]; then
  sleep 1
  DEST_SUBJECT=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:${NGINX_LOCAL_PORT}" \
    -servername "$RU_DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
  if [[ -z "$DEST_SUBJECT" ]]; then
    echo "ВНИМАНИЕ: dest 127.0.0.1:${NGINX_LOCAL_PORT} не отвечает валидным TLS с SNI ${RU_DOMAIN}."
    echo "REALITY без рабочего dest соединений не поднимет — проверь nginx."
  else
    echo "dest живой, сертификат: ${DEST_SUBJECT}"
  fi
fi

setup_awg_entry
setup_ru_routes
install_vpn_cli
create_awg_clients "$AWG_CLIENTS"

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
ufw allow "$AWG_PORT"/udp
ufw --force enable

cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.ip_forward = 1
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
echo
echo "--- Ссылка hysteria2 ---"
echo "$RU_LINK"
if [[ "$VLESS_ENABLED" == "1" ]]; then
  echo
  echo "--- Ссылка vless-reality ---"
  echo "$RU_VLESS_LINK"
fi
echo
echo "--- Подписка ---"
echo "$SUB_URL"
echo
echo "=== AmneziaWG ==="
echo
echo "Управление:"
echo "  vpn list            список"
echo "  vpn add <имя>       добавить"
echo "  vpn remove <имя>    удалить"
echo "  vpn dump            все конфиги одним потоком"

echo "--- Скачать все конфиги к себе ---"
echo "scp -P ${NEW_SSH_PORT} 'root@${PUBLIC_IP}:/root/awg/clients/*.conf' ~/Desktop/"
echo
