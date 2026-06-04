#!/usr/bin/env bash
set -euo pipefail

AMNEZIA_DIR="/etc/amnezia/amneziawg"
SERVER_CONF="$AMNEZIA_DIR/awg0.conf"
CLIENTS_DIR="$AMNEZIA_DIR/clients"
AWG_SERVICE="awg-quick@awg0"
INSTALLER_URL="https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh"
INSTALLER_FILE="/root/amneziawg-install.sh"

CLIENT_NAME="${1:-client_$(date +%Y%m%d_%H%M%S)}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

echo ""
echo "========== УСТАНОВКА ЗАВИСИМОСТЕЙ =========="
echo ""

apt update
apt install -y curl wget qrencode iptables iptables-persistent

echo ""
echo "========== СКАЧИВАНИЕ УСТАНОВЩИКА AMNEZIAWG =========="
echo ""

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

echo ""
echo "========== ЗАПУСК УСТАНОВЩИКА AMNEZIAWG =========="
echo ""
echo "Дальше установщик может задать вопросы."
echo "После завершения этот скрипт автоматически уберёт IPv6 и создаст нового клиента."
echo ""

bash "$INSTALLER_FILE"

if [ ! -f "$SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден: $SERVER_CONF"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена после установки"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

echo ""
echo "========== УДАЛЕНИЕ IPV6 ИЗ СЕРВЕРНОГО КОНФИГА =========="
echo ""

cp "$SERVER_CONF" "$SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Удаляем IPv6-адреса fd42... из Address и AllowedIPs.
# Также убираем пустые хвосты после запятых.
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"

# Удаляем IPv6 PostUp/PostDown, чтобы не трогать ip6tables на сервере с отключённым IPv6.
sed -i '/^PostUp = ip6tables /d' "$SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$SERVER_CONF"

echo ""
echo "Проверка IPv6-строк в серверном конфиге:"
if grep -nE 'fd42|::/0|ip6tables' "$SERVER_CONF"; then
  echo "Внимание: в серверном конфиге ещё остались IPv6-строки. Проверь вручную: $SERVER_CONF"
else
  echo "IPv6 из серверного конфига убран."
fi

echo ""
echo "========== УДАЛЕНИЕ IPV6 ИЗ СУЩЕСТВУЮЩИХ КЛИЕНТСКИХ КОНФИГОВ =========="
echo ""

if [ -d "$CLIENTS_DIR" ]; then
  find "$CLIENTS_DIR" -type f -name "*.conf" -print0 | while IFS= read -r -d '' file; do
    cp "$file" "$file.backup.$(date +%Y%m%d_%H%M%S)"
    sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$file"
    sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$file"
    sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$file"
    sed -i -E 's/,[[:space:]]*::\/0//g' "$file"
    sed -i -E 's/::\/0,[[:space:]]*//g' "$file"
    sed -i -E 's/[[:space:]]*::\/0//g' "$file"
  done
fi

echo ""
echo "========== ВКЛЮЧЕНИЕ IPV4 FORWARDING =========="
echo ""

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system >/dev/null

echo ""
echo "========== ПЕРЕЗАПУСК AMNEZIAWG =========="
echo ""

systemctl restart "$AWG_SERVICE"

echo ""
echo "========== СОЗДАНИЕ НОВОГО КЛИЕНТА =========="
echo ""

SERVER_PRIVATE=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}')
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | awg pubkey)
SERVER_PORT=$(grep "^ListenPort" "$SERVER_CONF" | awk '{print $3}')

if [ -z "$SERVER_PRIVATE" ] || [ -z "$SERVER_PUBLIC" ] || [ -z "$SERVER_PORT" ]; then
  echo "Ошибка: не удалось получить PrivateKey/PublicKey/ListenPort сервера"
  exit 1
fi

SERVER_IP=$(curl -4 -s ifconfig.me || true)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -4 -s icanhazip.com | tr -d '\n' || true)
fi

if [ -z "$SERVER_IP" ]; then
  echo "Ошибка: не удалось определить внешний IPv4 сервера"
  exit 1
fi

CLIENT_IP=""

for i in $(seq 2 254); do
  candidate="10.66.66.$i"
  if ! grep -q "$candidate/32" "$SERVER_CONF"; then
    CLIENT_IP="$candidate"
    break
  fi
done

if [ -z "$CLIENT_IP" ]; then
  echo "Ошибка: свободных IP в подсети 10.66.66.0/24 не найдено"
  exit 1
fi

CLIENT_PRIVATE=$(awg genkey)
CLIENT_PUBLIC=$(echo "$CLIENT_PRIVATE" | awg pubkey)
CLIENT_PSK=$(awg genpsk)

JC=$(grep "^Jc" "$SERVER_CONF" | awk '{print $3}')
JMIN=$(grep "^Jmin" "$SERVER_CONF" | awk '{print $3}')
JMAX=$(grep "^Jmax" "$SERVER_CONF" | awk '{print $3}')
S1=$(grep "^S1" "$SERVER_CONF" | awk '{print $3}')
S2=$(grep "^S2" "$SERVER_CONF" | awk '{print $3}')
S3=$(grep "^S3" "$SERVER_CONF" | awk '{print $3}')
S4=$(grep "^S4" "$SERVER_CONF" | awk '{print $3}')
H1=$(grep "^H1" "$SERVER_CONF" | awk '{print $3}')
H2=$(grep "^H2" "$SERVER_CONF" | awk '{print $3}')
H3=$(grep "^H3" "$SERVER_CONF" | awk '{print $3}')
H4=$(grep "^H4" "$SERVER_CONF" | awk '{print $3}')

CLIENT_CONF="$CLIENTS_DIR/${CLIENT_NAME}.conf"

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 1.0.0.1
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
PublicKey = $SERVER_PUBLIC
PresharedKey = $CLIENT_PSK
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF"

cat >> "$SERVER_CONF" <<EOF

### Client $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC
PresharedKey = $CLIENT_PSK
AllowedIPs = $CLIENT_IP/32
EOF

systemctl restart "$AWG_SERVICE"

echo ""
echo "========== ГОТОВО =========="
echo ""
echo "AmneziaWG установлен и запущен."
echo "IPv6 убран из серверного и клиентского конфига."
echo "Клиент создан."
echo ""
echo "Имя клиента: $CLIENT_NAME"
echo "IP клиента: $CLIENT_IP/32"
echo "Файл клиента: $CLIENT_CONF"
echo "Endpoint: $SERVER_IP:$SERVER_PORT"
echo ""
echo "========== КЛИЕНТСКИЙ КОНФИГ =========="
echo ""
cat "$CLIENT_CONF"