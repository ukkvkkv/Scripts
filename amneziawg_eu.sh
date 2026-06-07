#!/usr/bin/env bash
set -euo pipefail

AMNEZIA_DIR="/etc/amnezia/amneziawg"
SERVER_CONF="$AMNEZIA_DIR/awg0.conf"
CLIENTS_DIR="$AMNEZIA_DIR/clients"
AWG_SERVICE="awg-quick@awg0"

INSTALLER_URL="https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh"
INSTALLER_FILE="/root/amneziawg-install.sh"

# ==================== МОБИЛЬНЫЙ ПРЕСЕТ (с I-параметрами) ====================
AWG_MTU="1280"
AWG_JC="3"
AWG_JMIN="40"
AWG_JMAX="100"
AWG_S1="24"
AWG_S2="64"
AWG_S3="0"
AWG_S4="0"

# I1-I5 (рекомендуемый мобильный вариант)
AWG_I1="<r 128>"
AWG_I2="<r 64><t>"
AWG_I3="<r 32>"
AWG_I4=""
AWG_I5=""

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

echo "========== EU-СЕРВЕР: ЧИСТАЯ УСТАНОВКА AMNEZIAWG (мобильный пресет) =========="

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"
bash "$INSTALLER_FILE"

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

echo "Настройка конфига под мобильный пресет..."

cp "$SERVER_CONF" "$SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Очищаем клиентов, оставляем только Interface
awk 'BEGIN{keep=1} /^\[Peer\]/{keep=0} keep{print}' "$SERVER_CONF" > /tmp/awg0.clean
mv /tmp/awg0.clean "$SERVER_CONF"

# Применяем мобильные параметры + I1-I5
sed -i '/^MTU = /d; /^Jc = /d; /^Jmin = /d; /^Jmax = /d; /^S1 = /d; /^S2 = /d; /^S3 = /d; /^S4 = /d; /^H1 = /d; /^H2 = /d; /^H3 = /d; /^H4 = /d; /^I1 = /d; /^I2 = /d; /^I3 = /d; /^I4 = /d; /^I5 = /d' "$SERVER_CONF"

cat >> "$SERVER_CONF" <<EOF
MTU = $AWG_MTU
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = 1
H2 = 2
H3 = 3
H4 = 4
EOF

# Добавляем I-параметры
[ -n "$AWG_I1" ] && echo "I1 = $AWG_I1" >> "$SERVER_CONF"
[ -n "$AWG_I2" ] && echo "I2 = $AWG_I2" >> "$SERVER_CONF"
[ -n "$AWG_I3" ] && echo "I3 = $AWG_I3" >> "$SERVER_CONF"
[ -n "$AWG_I4" ] && echo "I4 = $AWG_I4" >> "$SERVER_CONF"
[ -n "$AWG_I5" ] && echo "I5 = $AWG_I5" >> "$SERVER_CONF"

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

# Создаём add-awg-client с полным набором параметров (включая I)
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
I1 = $(get_param I1)
I2 = $(get_param I2)
I3 = $(get_param I3)
I4 = $(get_param I4)
I5 = $(get_param I5)

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

systemctl restart "$AWG_SERVICE"

echo "Клиент добавлен: $CLIENT_NAME ($CLIENT_IP)"
echo "Файл: $CLIENTS_DIR/${CLIENT_NAME}.conf"
ADDCLIENT

chmod +x /usr/local/bin/add-awg-client

systemctl enable "$AWG_SERVICE"
systemctl restart "$AWG_SERVICE"

echo ""
echo "========== ГОТОВО =========="
echo "EU AmneziaWG сервер настроен под мобильный пресет (с I-параметрами)"
echo "Команда для добавления клиентов: sudo add-awg-client [имя]"
echo "========================================"