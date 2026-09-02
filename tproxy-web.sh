#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

SITE_DIR="${SITE_DIR:-/var/www/html}"

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

tcp_port_in_use() {
  local p="$1"
  [[ -n "$(ss -H -tln "sport = :${p}" 2>/dev/null)" ]]
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

install_tproxy() {
  local domain="$1" email="$2" site_dir="$3"
  local src=/opt/tproxy-server-src
  local port
  for port in 80 443; do
    if tcp_port_in_use "$port"; then
      echo "Ошибка: ${port}/tcp занят, а его должен слушать Caddy."
      ss -ltnp | grep ":${port}" || true
      exit 1
    fi
  done

  rm -rf "$src"
  git clone --quiet https://github.com/telegramdesktop/tproxy-server "$src"
  if grep -q '^(cd "$repository" && "$go_binary" test \./\.\.\.)$' "$src/deploy/install.sh"; then
    sed -i 's|^(cd "$repository" && "$go_binary" test ./...)|(umask 022; cd "$repository" \&\& "$go_binary" test ./...)|' \
      "$src/deploy/install.sh"
  else
    echo "ВНИМАНИЕ: не нашёл строку с go test в install.sh — апстрим поменялся,"
    echo "проверь результат установки руками."
  fi
  if [[ ! -s /root/tproxy-secret.txt ]]; then
    ( umask 077; openssl rand -hex 16 > /root/tproxy-secret.txt )
  fi
  TPROXY_SECRET=$(cat /root/tproxy-secret.txt)
  echo "Ставлю Telegram WEB proxy..."
  set +e
  ( cd "$src" && ./deploy/install.sh \
      --hostname "$domain" --email "$email" --site-dir "$site_dir" \
      < /root/tproxy-secret.txt )
  local rc=$?
  set -e
  chmod 0755 /opt/MTProxy/objs /opt/MTProxy/objs/bin \
             /opt/MTProxy/objs/bin/mtproto-proxy 2>/dev/null || true
  systemctl reset-failed mtproxy.service 2>/dev/null || true
  systemctl restart mtproxy.service 2>/dev/null || true
  local ready=0
  for _ in {1..30}; do
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8081/readyz; then
      ready=1
      break
    fi
    sleep 2
  done
  if [[ "$ready" != "1" ]]; then
    echo "Ошибка: tproxy-server не вышел в readyz (установщик вернул ${rc})."
    systemctl --no-pager --full status caddy mtproxy tproxy-server | tail -n 40
    exit 1
  fi
}

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "Ошибка: официальный MTProxy собирается только на x86_64."
  exit 1
fi

DOMAIN=""
EMAIL=""
read -rp "Введите домен: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $DOMAIN"
  exit 1
fi
while [[ ! "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
  read -rp "Email для Let's Encrypt: " EMAIL
done

apt update
apt install -y curl ca-certificates openssl iproute2 iptables git

PUBLIC_IP=$(get_public_ip)
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
echo
echo "Текущий публичный IPv4 сервера: ${PUBLIC_IP:-не удалось определить}"
echo "DNS A-запись домена $DOMAIN: ${DNS_IP:-не найдена}"
if [[ -n "${PUBLIC_IP:-}" && -n "${DNS_IP:-}" && "$PUBLIC_IP" != "$DNS_IP" ]]; then
  echo "ВНИМАНИЕ: домен не указывает на текущий IPv4 сервера. Caddy не сможет выпустить сертификат."
  read -rp "Продолжить всё равно? [y/N]: " CONTINUE
  [[ "${CONTINUE,,}" == "y" || "${CONTINUE,,}" == "yes" ]] || exit 1
fi

open_tcp_port 80
open_tcp_port 443

TPROXY_SECRET=""
make_site "$SITE_DIR"
install_tproxy "$DOMAIN" "$EMAIL" "$SITE_DIR"

echo
echo "=== Telegram WEB proxy готов ==="
echo "Hostname: ${DOMAIN}"
echo "Secret:   ${TPROXY_SECRET}"
echo "Ссылка:   https://t.me/webproxy?server=${DOMAIN}&secret=${TPROXY_SECRET}"
echo
