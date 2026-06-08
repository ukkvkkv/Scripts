#!/usr/bin/env bash
set -euo pipefail

AMNEZIA_DIR="/etc/amnezia/amneziawg"
SERVER_CONF="$AMNEZIA_DIR/awg0.conf"
CLIENTS_DIR="$AMNEZIA_DIR/clients"
AWG_SERVICE="awg-quick@awg0"

INSTALLER_URL="https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh"
INSTALLER_FILE="/root/amneziawg-install.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

echo "========== EU-СЕРВЕР: ЧИСТАЯ УСТАНОВКА AMNEZIAWG =========="

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

# Запускаем установщик полностью автоматически (принимаем все дефолтные ответы)
printf '\n\n\n\n\n\n' | bash "$INSTALLER_FILE" || true

if [ ! -f "$SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден после установки"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

echo "Очистка конфига и настройка..."

cp "$SERVER_CONF" "$SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Очищаем клиентов, оставляем только Interface
awk 'BEGIN{keep=1} /^\[Peer\]/{keep=0} keep{print}' "$SERVER_CONF" > /tmp/awg0.clean
mv /tmp/awg0.clean "$SERVER_CONF"

# Убираем IPv6
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$SERVER_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$SERVER_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$SERVER_CONF"
sed -i '/^PostUp = ip6tables /d' "$SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$SERVER_CONF"

# Включаем forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system

# Создаём add-awg-client
cat > /usr/local/bin/add-awg-client <<'ADDCLIENT'
#!/usr/bin/env bash
set -euo pipefail

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
CLIENTS_DIR="/etc/amnezia/amneziawg/clients"

CLIENT_NAME="${1:-client_$(date +%Y%m%d_%H%M%S)}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

if [ ! -f "$SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден"
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
SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)

CLIENT_IP=""
for i in $(seq 2 254); do
  candidate="10.66.66.$i"
  if ! grep -q "$candidate/32" "$SERVER_CONF"; then
    CLIENT_IP="$candidate"
    break
  fi
done

if [ -z "$CLIENT_IP" ]; then
  echo "Ошибка: нет свободных IP"
  exit 1
fi

CLIENT_PRIVATE=$(awg genkey)
CLIENT_PUBLIC=$(echo "$CLIENT_PRIVATE" | awg pubkey)
CLIENT_PSK=$(awg genpsk)

get_param() {
  grep "^$1" "$SERVER_CONF" | awk '{print $3}' | head -1
}

cat > "$CLIENTS_DIR/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 1.0.0.1
MTU = $(get_param MTU)
Jc = $(get_param Jc)
Jmin = $(get_param Jmin)
Jmax = $(get_param Jmax)
S1 = $(get_param S1)
S2 = $(get_param S2)
S3 = $(get_param S3)
S4 = $(get_param S4)
H1 = $(get_param H1)
H2 = $(get_param H2)
H3 = $(get_param H3)
H4 = $(get_param H4)

[Peer]
PublicKey = $SERVER_PUBLIC
PresharedKey = $CLIENT_PSK
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENTS_DIR/${CLIENT_NAME}.conf"

cat >> "$SERVER_CONF" <<EOF

### Client $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBLIC
PresharedKey = $CLIENT_PSK
AllowedIPs = $CLIENT_IP/32
EOF

systemctl restart "awg-quick@awg0"

echo "Клиент добавлен: $CLIENT_NAME ($CLIENT_IP)"
echo "Файл: $CLIENTS_DIR/${CLIENT_NAME}.conf"
ADDCLIENT

chmod +x /usr/local/bin/add-awg-client

systemctl enable "$AWG_SERVICE"
systemctl restart "$AWG_SERVICE"

echo ""
echo "========== ГОТОВО =========="
echo "EU AmneziaWG сервер настроен (дефолтные параметры от установщика)"
echo "Команда для добавления клиентов: sudo add-awg-client [имя]"
echo "========================================"