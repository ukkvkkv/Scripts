#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

# VLESS REALITY и Telegram WEB proxy живут на одном домене, но 443 может
# занимать только кто-то один:
#   без tproxy — 443 у REALITY, dest на 127.0.0.1:8443;
#   с tproxy   — 443 у Caddy (сайт + мост), REALITY на 8443, dest на 127.0.0.1:9443.
# SNI у REALITY в обоих случаях — домен этого сервера. Настоящие TLS-хендшейки
# уходят на локальный nginx с сертом того же домена: наружу он не торчит,
# а REALITY прозрачно пробрасывает на него всех, кто пришёл без валидного
# ключа, — сканер видит обычный сайт с валидным сертом.
# Порты можно задать через окружение; иначе их выберет ответ на вопрос
# про tproxy ниже.
VLESS_PORT_ENV="${VLESS_PORT:-}"
NGINX_LOCAL_PORT_ENV="${NGINX_LOCAL_PORT:-}"

# Каталог сайта-прикрытия. Его отдаёт nginx как dest для REALITY, и он же
# уезжает в /srv/tproxy-site публичным сайтом Telegram WEB proxy: снаружи
# и 443, и хендшейки на REALITY показывают одну и ту же страницу.
SITE_DIR="${SITE_DIR:-/var/www/html}"

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

# Страница-прикрытие. Одна и та же для REALITY-dest и для публичного сайта
# Telegram WEB proxy. Замени её на что-нибудь своё: одинаковый стартер у
# многих операторов сам по себе становится приметой при активном сканировании.
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

# Telegram WEB proxy: официальный MTProxy, спрятанный за обычным HTTPS-сайтом.
# Caddy забирает 80/443, отдаёт всё Go-релею на 127.0.0.1:8080, а тот уже
# разбирает WebView-транспорт и раскладывает потоки в MTProxy на 127.0.0.1:2398.
install_tproxy() {
  local domain="$1" email="$2" site_dir="$3"
  local src=/opt/tproxy-server-src

  # Caddy возьмёт оба порта себе. Обычно к этому моменту nginx уже уехал на
  # локальный dest, но если дефолтный сайт где-то уцелел — установщик молча
  # поставит всё и упадёт только на старте Caddy, а это неочевидно.
  local port
  for port in 80 443; do
    if tcp_port_in_use "$port"; then
      echo "Ошибка: ${port}/tcp занят, а его должен слушать Caddy."
      ss -ltnp | grep ":${port}" || true
      echo "Проверь /etc/nginx/sites-enabled/ — скорее всего там остался сайт на этом порту."
      exit 1
    fi
  done

  rm -rf "$src"
  git clone --quiet https://github.com/telegramdesktop/tproxy-server "$src"

  # Установщик апстрима ставит umask 077 и об него же спотыкается: тест
  # TestLoadAcceptsSystemdCredentialReadPermissions пишет файл с 0444 и ждёт
  # отказа, а при umask 077 выходит 0400 — отказа нет, тест валится, весь
  # install.sh падает по set -e. Тесты гоняем с нормальным umask.
  if grep -q '^(cd "$repository" && "$go_binary" test \./\.\.\.)$' "$src/deploy/install.sh"; then
    sed -i 's|^(cd "$repository" && "$go_binary" test ./...)|(umask 022; cd "$repository" \&\& "$go_binary" test ./...)|' \
      "$src/deploy/install.sh"
  else
    echo "ВНИМАНИЕ: не нашёл строку с go test в install.sh — апстрим поменялся,"
    echo "проверь результат установки руками."
  fi

  # Секрет клиента: 32 hex. Ровно он вводится в Telegram рядом с доменом.
  if [[ ! -s /root/tproxy-secret.txt ]]; then
    ( umask 077; openssl rand -hex 16 > /root/tproxy-secret.txt )
  fi
  TPROXY_SECRET=$(cat /root/tproxy-secret.txt)

  # Секрет уходит на stdin, а не в --secret: так он не светится в списке
  # процессов. Установщик собирает MTProxy и Go-релей — это долго, минуты.
  echo "Ставлю Telegram WEB proxy (сборка MTProxy и релея займёт несколько минут)..."
  set +e
  ( cd "$src" && ./deploy/install.sh \
      --hostname "$domain" --email "$email" --site-dir "$site_dir" \
      < /root/tproxy-secret.txt )
  local rc=$?
  set -e

  # Вторая грабля того же umask 077: /opt/MTProxy/objs, objs/bin и сам бинарь
  # получают 0700 root:root, а mtproxy.service ходит под User=mtproxy — сервис
  # падает с 203/EXEC, релей не выходит в readyz. Права правим всегда: команда
  # идемпотентна, а установщик мог свалиться именно на этом шаге.
  chmod 0755 /opt/MTProxy/objs /opt/MTProxy/objs/bin \
             /opt/MTProxy/objs/bin/mtproto-proxy 2>/dev/null || true
  systemctl reset-failed mtproxy.service 2>/dev/null || true
  systemctl restart mtproxy.service 2>/dev/null || true

  # /readyz зеленеет только когда релей видит живой MTProxy — это и есть
  # признак, что связка целиком рабочая.
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

read -rp "Введите домен EU-сервера: " DOMAIN
DOMAIN="${DOMAIN,,}"
if ! valid_domain "$DOMAIN"; then
  echo "Ошибка: домен выглядит некорректно: $DOMAIN"
  exit 1
fi

read -rp "Email для Let's Encrypt (можно оставить пустым): " EMAIL

echo
echo "Telegram WEB proxy (github.com/telegramdesktop/tproxy-server): официальный"
echo "MTProxy за обычным HTTPS-сайтом. Клиент вводит только домен и секрет."
echo "Он займёт 443, поэтому VLESS REALITY уедет на 8443, а dest — на 9443."
read -rp "Поставить Telegram WEB proxy на ${DOMAIN}? [Y/n]: " TPROXY_ANSWER
TPROXY_ENABLED=1
if [[ "${TPROXY_ANSWER,,}" =~ ^(n|no|нет)$ ]]; then
  TPROXY_ENABLED=0
fi

if [[ "$TPROXY_ENABLED" == "1" ]]; then
  VLESS_PORT="${VLESS_PORT_ENV:-8443}"
  NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT_ENV:-9443}"

  # Официальный MTProxy собирается только под x86_64 — это ограничение
  # апстрима, не скрипта.
  if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Ошибка: официальный MTProxy собирается только на x86_64."
    echo "Перезапусти скрипт и ответь 'n' на вопрос про Telegram WEB proxy."
    exit 1
  fi
  # Установщику tproxy нужен настоящий ACME-контакт: пустой он не примет.
  while [[ ! "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
    read -rp "Для Telegram WEB proxy нужен валидный email: " EMAIL
  done
else
  VLESS_PORT="${VLESS_PORT_ENV:-443}"
  NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT_ENV:-8443}"
fi

apt update
apt install -y curl ca-certificates openssl certbot python3 iproute2 iptables fail2ban nginx git

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

# nginx гасим до проверок: иначе при повторном запуске скрипт увидит на
# порту dest свой же nginx с прошлого раза и решит, что порт занят чужим.
# Обратно его поднимет шаг с настройкой dest.
systemctl stop nginx 2>/dev/null || true

if port_in_use 80; then
  echo "Ошибка: TCP-порт 80 занят. Освободи его для certbot --standalone и запусти скрипт снова."
  ss -ltnp | grep ':80' || true
  exit 1
fi

# Порт REALITY должен быть свободен. Чужой сайт на нём скрипт молча
# разрулить не может — останавливаемся и говорим, что делать.
if tcp_port_in_use "$VLESS_PORT"; then
  echo "Ошибка: ${VLESS_PORT}/tcp уже занят — его должен слушать sing-box (VLESS REALITY)."
  ss -ltnp | grep ":${VLESS_PORT}" || true
  echo
  echo "Если это твой сайт: перевесь его на 127.0.0.1:${NGINX_LOCAL_PORT}"
  echo "(в nginx заменить 'listen ... ssl;' на 'listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;')"
  echo "и запусти скрипт снова. Сайт продолжит открываться по https://${DOMAIN}/ —"
  echo "REALITY прозрачно пробросит на него всех, кто пришёл без ключа."
  exit 1
fi

# Caddy под Telegram WEB proxy встанет на 443 и хочет его целиком.
if [[ "$TPROXY_ENABLED" == "1" ]] && tcp_port_in_use 443; then
  echo "Ошибка: 443/tcp занят, а его должен слушать Caddy под Telegram WEB proxy."
  ss -ltnp | grep ':443' || true
  exit 1
fi

ufw allow 80/tcp 2>/dev/null || true
open_udp_port "$EU_PORT"
open_tcp_port "$VLESS_PORT"
if [[ "$TPROXY_ENABLED" == "1" ]]; then
  open_tcp_port 443
fi

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

# Хуки в каталогах, а не только в аргументах certbot: с --keep-until-expiring
# certbot не трогает уже выпущенный сертификат и не переписывает хуки в его
# renewal-конфиге, так что на повторном запуске старая лишённая caddy версия
# осталась бы жить. Каталожные хуки выполняются для любой линии сертификата.
install -d -m 755 /etc/letsencrypt/renewal-hooks/pre \
                  /etc/letsencrypt/renewal-hooks/post
cat > /etc/letsencrypt/renewal-hooks/pre/00-stop-web.sh <<'EOF_PRE'
#!/bin/sh
# Освобождает порт 80 перед проверкой Let's Encrypt. Держать его может как
# nginx (без tproxy), так и Caddy (с tproxy) — гасим обоих, кто есть.
systemctl stop nginx caddy 2>/dev/null || true
EOF_PRE
cat > /etc/letsencrypt/renewal-hooks/post/99-start-web.sh <<'EOF_POST'
#!/bin/sh
systemctl start nginx caddy 2>/dev/null || true
EOF_POST
chmod +x /etc/letsencrypt/renewal-hooks/pre/00-stop-web.sh \
         /etc/letsencrypt/renewal-hooks/post/99-start-web.sh

# Let's Encrypt
CERTBOT_ARGS=(certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --keep-until-expiring)
CERTBOT_ARGS+=(--pre-hook "systemctl stop nginx caddy 2>/dev/null || true")
CERTBOT_ARGS+=(--post-hook "systemctl start nginx caddy 2>/dev/null || true")
CERTBOT_ARGS+=(--deploy-hook "/usr/local/bin/singbox-cert-deploy.sh")
if [[ -n "$EMAIL" ]]; then
  CERTBOT_ARGS+=(-m "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"

CERT_DIR=$(prepare_certs "$DOMAIN")

# Сайт нужен в любом случае: его отдаёт dest для REALITY, и его же забирает
# установщик tproxy как публичный сайт на 443.
make_site "$SITE_DIR"

# Локальный сайт-заглушка на 127.0.0.1:NGINX_LOCAL_PORT — это dest для REALITY.
# Если на этом порту уже что-то своё (перевешенный сайт) — не трогаем.
if tcp_port_in_use "$NGINX_LOCAL_PORT"; then
  echo "На 127.0.0.1:${NGINX_LOCAL_PORT} уже что-то слушает — беру это как dest, nginx не трогаю."
else
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/reality-dest.conf <<EOF_NGINX
server {
    listen 127.0.0.1:${NGINX_LOCAL_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:5m;

    server_tokens off;
    root ${SITE_DIR};
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

# nginx уже поднят. Если он (или чей-то забытый конфиг сайта) занял порт
# REALITY, sing-box просто не стартует — лучше сказать об этом сразу и по делу.
if tcp_port_in_use "$VLESS_PORT"; then
  echo "Ошибка: ${VLESS_PORT}/tcp занят уже после старта nginx."
  ss -ltnp | grep ":${VLESS_PORT}" || true
  echo "Скорее всего в /etc/nginx/sites-enabled/ остался старый конфиг сайта"
  echo "с 'listen 127.0.0.1:${VLESS_PORT} ssl;' — убери его и запусти скрипт снова."
  exit 1
fi

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

# Ставим tproxy последним: 443 и 80 к этому моменту точно свободны, а сайт
# в SITE_DIR уже лежит и проверен как dest для REALITY.
TPROXY_SECRET=""
if [[ "$TPROXY_ENABLED" == "1" ]]; then
  install_tproxy "$DOMAIN" "$EMAIL" "$SITE_DIR"
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
# VLESS_PORT — vless-reality, 80 нужен certbot для продления серта.
ufw allow "$VLESS_PORT"/tcp
ufw allow 80/tcp
if [[ "$TPROXY_ENABLED" == "1" ]]; then
  # 443 — Caddy: публичный сайт и WebView-транспорт Telegram WEB proxy.
  ufw allow 443/tcp
fi
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
if [[ "$TPROXY_ENABLED" == "1" ]]; then
  echo "Telegram WEB proxy: 443/tcp (Caddy -> релей 127.0.0.1:8080 -> MTProxy 127.0.0.1:2398)"
fi
echo
echo "--- Обе ссылки скормить RU-скрипту ---"
echo "$EU_LINK"
echo
echo "$EU_VLESS_LINK"
echo
if [[ "$TPROXY_ENABLED" == "1" ]]; then
  echo "--- Telegram WEB proxy ---"
  echo "Hostname: ${DOMAIN}"
  echo "Secret:   ${TPROXY_SECRET}"
  echo "Ссылка:   https://t.me/webproxy?server=${DOMAIN}&secret=${TPROXY_SECRET}"
  echo
  echo "Секрет продублирован в /root/tproxy-secret.txt."
  echo "Тип WEB proxy понимают только клиенты с поддержкой WebView-транспорта;"
  echo "публичный t.me этот маршрут пока не регистрирует — ссылку открывать"
  echo "прямо в клиенте."
  echo
fi
