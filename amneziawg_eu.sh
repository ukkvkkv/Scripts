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

echo "========== EU/NL СЕРВЕР: УСТАНОВКА AMNEZIAWG ==========\n"

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

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

echo "Настройка конфига..."

cp "$SERVER_CONF" "$SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Убираем IPv6
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i '/^PostUp = ip6tables /d' "$SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$SERVER_CONF"

# Forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system >/dev/null

systemctl enable "$AWG_SERVICE"
systemctl restart "$AWG_SERVICE"

# add-awg-client с поддержкой AmneziaWG 2.0
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

I1=$(grep "^I1" "$SERVER_CONF" | awk '{print $3}' || true)
I2=$(grep "^I2" "$SERVER_CONF" | awk '{print $3}' || true)
I3=$(grep "^I3" "$SERVER_CONF" | awk '{print $3}' || true)
I4=$(grep "^I4" "$SERVER_CONF" | awk '{print $3}' || true)
I5=$(grep "^I5" "$SERVER_CONF" | awk '{print $3}' || true)

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
EOF

if [ -n "$I1" ]; then echo "I1 = $I1" >> "$CLIENT_CONF"; fi
if [ -n "$I2" ]; then echo "I2 = $I2" >> "$CLIENT_CONF"; fi
if [ -n "$I3" ]; then echo "I3 = $I3" >> "$CLIENT_CONF"; fi
if [ -n "$I4" ]; then echo "I4 = $I4" >> "$CLIENT_CONF"; fi
if [ -n "$I5" ]; then echo "I5 = $I5" >> "$CLIENT_CONF"; fi

cat >> "$CLIENT_CONF" <<EOF

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

echo "Клиент добавлен: $CLIENT_NAME ($CLIENT_IP/32)"
echo "Файл: $CLIENT_CONF"
ADDCLIENT

chmod +x /usr/local/bin/add-awg-client

# Создаём ru-gateway конфиг
add-awg-client "$RU_GATEWAY_NAME" > /tmp/ru-gateway-output.txt
awk '/^\[Interface\]/{flag=1} flag{print}' /tmp/ru-gateway-output.txt > "$RU_GATEWAY_CONF"
chmod 600 "$RU_GATEWAY_CONF"

echo ""
echo "Готово. EU/NL AmneziaWG настроен."
echo "Команда для клиентов: sudo add-awg-client [имя]"
echo ""
echo "Конфиг для RU-сервера: $RU_GATEWAY_CONF"

read -rp "Хочешь сразу передать его на RU-сервер через scp? Введи IP RU-сервера (или Enter чтобы пропустить): " RU_SERVER_IP

if [ -n "$RU_SERVER_IP" ]; then
  echo "Передаю файл..."
  scp "$RU_GATEWAY_CONF" "root@$RU_SERVER_IP:/root/ru-gateway-for-ru.conf"
  echo "Готово. Файл на RU-сервере: /root/ru-gateway-for-ru.conf"
else
  echo "Пропущено. Перенеси файл вручную на RU-сервер как /root/ru-gateway-for-ru.conf"
fi
