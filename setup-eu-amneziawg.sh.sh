#!/usr/bin/env bash
set -euo pipefail

AMNEZIA_DIR="/etc/amnezia/amneziawg"
SERVER_CONF="$AMNEZIA_DIR/awg0.conf"
CLIENTS_DIR="$AMNEZIA_DIR/clients"
AWG_SERVICE="awg-quick@awg0"
INSTALLER_URL="https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh"
INSTALLER_FILE="/root/amneziawg-install.sh"

RU_GATEWAY_NAME="ru-gateway"
RU_GATEWAY_CONF="/root/ru-gateway-for-ru.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

echo ""
echo "========== EU/NL СЕРВЕР: УСТАНОВКА AMNEZIAWG =========="
echo ""

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

echo ""
echo "Сейчас запустится официальный установщик AmneziaWG."
echo "Он может задать несколько вопросов: IP, порт, имя клиента."
echo ""

bash "$INSTALLER_FILE"

if [ ! -f "$SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден: $SERVER_CONF"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

echo ""
echo "========== УБИРАЕМ IPV6 ИЗ EU/NL-КОНФИГА =========="
echo ""

cp "$SERVER_CONF" "$SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i '/^PostUp = ip6tables /d' "$SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$SERVER_CONF"

echo ""
echo "========== ВКЛЮЧАЕМ IPV4 FORWARDING =========="
echo ""

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system >/dev/null

systemctl enable "$AWG_SERVICE"
systemctl restart "$AWG_SERVICE"

echo ""
echo "========== СОЗДАЁМ КОМАНДУ add-awg-client =========="
echo ""

cat > /usr/local/bin/add-awg-client <<'ADDCLIENT'
#!/usr/bin/env bash
set -euo pipefail

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
AWG_SERVICE="awg-quick@awg0"
CLIENTS_DIR="/etc/amnezia/amneziawg/clients"

CLIENT_NAME="${1:-client_$(date +%Y%m%d_%H%M%S)}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

if [ ! -f "$SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден: $SERVER_CONF"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

SERVER_PRIVATE=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}')
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | awg pubkey)
SERVER_PORT=$(grep "^ListenPort" "$SERVER_CONF" | awk '{print $3}')

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
echo "Готово. Клиент добавлен."
echo ""
echo "Имя клиента: $CLIENT_NAME"
echo "IP клиента: $CLIENT_IP/32"
echo "Файл клиента: $CLIENT_CONF"
echo ""
echo "========== КЛИЕНТСКИЙ КОНФИГ =========="
echo ""
cat "$CLIENT_CONF"
ADDCLIENT

chmod +x /usr/local/bin/add-awg-client

echo ""
echo "========== СОЗДАЁМ КОНФИГ ru-gateway ДЛЯ RU-СЕРВЕРА =========="
echo ""

add-awg-client "$RU_GATEWAY_NAME" > /tmp/ru-gateway-output.txt

awk '/^\[Interface\]/{flag=1} flag{print}' /tmp/ru-gateway-output.txt > "$RU_GATEWAY_CONF"
chmod 600 "$RU_GATEWAY_CONF"

echo ""
echo "========== ПЕРЕДАЧА КОНФИГА НА RU-СЕРВЕР =========="
echo ""

read -rp "Введите IP RU-сервера для передачи ru-gateway конфига через scp: " RU_SERVER_IP

if [ -z "$RU_SERVER_IP" ]; then
  echo "IP RU-сервера не указан. Пропускаю scp."
else
  echo ""
  echo "Передаю файл на RU-сервер:"
  echo "scp $RU_GATEWAY_CONF root@$RU_SERVER_IP:/root/ru-gateway-for-ru.conf"
  echo ""

  scp "$RU_GATEWAY_CONF" "root@$RU_SERVER_IP:/root/ru-gateway-for-ru.conf"

  echo ""
  echo "Файл передан на RU-сервер:"
  echo "root@$RU_SERVER_IP:/root/ru-gateway-for-ru.conf"
fi

echo ""
echo "========== ГОТОВО НА EU/NL-СЕРВЕРЕ =========="
echo ""
echo "EU/NL AmneziaWG установлен и запущен."
echo "IPv6 убран."
echo "Команда для новых клиентов создана:"
echo ""
echo "sudo add-awg-client имя_клиента"
echo ""
echo "Создан конфиг для RU-сервера:"
echo "$RU_GATEWAY_CONF"
echo ""
echo "Его нужно перенести на RU-сервер в файл:"
echo "/root/ru-gateway-for-ru.conf"
echo ""
echo "========== КОНФИГ ДЛЯ RU-СЕРВЕРА =========="
echo ""
cat "$RU_GATEWAY_CONF"