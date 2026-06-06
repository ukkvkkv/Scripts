#!/usr/bin/env bash
set -euo pipefail

AMNEZIA_DIR="/etc/amnezia/amneziawg"
RU_SERVER_CONF="$AMNEZIA_DIR/awg0.conf"
NL_TUNNEL_CONF="$AMNEZIA_DIR/awg-nl.conf"
CLIENTS_DIR="$AMNEZIA_DIR/clients"
AWG_RU_SERVICE="awg-quick@awg0"
AWG_NL_SERVICE="awg-quick@awg-nl"
INSTALLER_URL="https://raw.githubusercontent.com/wiresock/amneziawg-install/master/amneziawg-install.sh"
INSTALLER_FILE="/root/amneziawg-install.sh"

RU_CLIENT_SUBNET="10.77.77.0/24"
RU_SERVER_ADDRESS="10.77.77.1/24"

# AmneziaWG mobile-optimized parameters (2.0)
AWG_MTU="1280"
AWG_JC="3"
AWG_JMIN="40"
AWG_JMAX="100"
AWG_S1="24"
AWG_S2="64"
AWG_S3="0"
AWG_S4="0"

# I1-I5 — Вариант 1 (рекомендуемый)
AWG_I1="<r 128>"
AWG_I2="<r 64><t>"
AWG_I3="<r 32>"
AWG_I4=""
AWG_I5=""

RU_GATEWAY_CONF_SOURCE="${1:-/root/ru-gateway-for-ru.conf}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

if [ ! -f "$RU_GATEWAY_CONF_SOURCE" ]; then
  echo "Ошибка: не найден конфиг RU → EU/NL: $RU_GATEWAY_CONF_SOURCE"
  echo "Сначала перенеси файл с EU/NL-сервера: /root/ru-gateway-for-ru.conf"
  exit 1
fi

echo "========== RU-СЕРВЕР: УСТАНОВКА AMNEZIAWG ==========\n"

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

bash "$INSTALLER_FILE"

if [ ! -f "$RU_SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг не найден: $RU_SERVER_CONF"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

echo "Настройка awg0..."

cp "$RU_SERVER_CONF" "$RU_SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Очищаем клиентов, установленных инсталлером
awk 'BEGIN{keep=1} /^\[Peer\]/{keep=0} keep{print}' "$RU_SERVER_CONF" > /tmp/awg0.interface.only
mv /tmp/awg0.interface.only "$RU_SERVER_CONF"

sed -i -E "s#^Address = .*#Address = $RU_SERVER_ADDRESS#g" "$RU_SERVER_CONF"

# Применяем параметры AmneziaWG 2.0
sed -i '/^MTU = /d; /^Jc = /d; /^Jmin = /d; /^Jmax = /d; /^S1 = /d; /^S2 = /d; /^S3 = /d; /^S4 = /d; /^H1 = /d; /^H2 = /d; /^H3 = /d; /^H4 = /d; /^I1 = /d; /^I2 = /d; /^I3 = /d; /^I4 = /d; /^I5 = /d' "$RU_SERVER_CONF"

sed -i "/^Address = /a MTU = $AWG_MTU\nJc = $AWG_JC\nJmin = $AWG_JMIN\nJmax = $AWG_JMAX\nS1 = $AWG_S1\nS2 = $AWG_S2\nS3 = $AWG_S3\nS4 = $AWG_S4" "$RU_SERVER_CONF"

if [ -n "$AWG_I1" ]; then sed -i "/^S4 = /a I1 = $AWG_I1" "$RU_SERVER_CONF"; fi
if [ -n "$AWG_I2" ]; then sed -i "/^I1 = /a I2 = $AWG_I2" "$RU_SERVER_CONF"; fi
if [ -n "$AWG_I3" ]; then sed -i "/^I2 = /a I3 = $AWG_I3" "$RU_SERVER_CONF"; fi
if [ -n "$AWG_I4" ]; then sed -i "/^I3 = /a I4 = $AWG_I4" "$RU_SERVER_CONF"; fi
if [ -n "$AWG_I5" ]; then sed -i "/^I4 = /a I5 = $AWG_I5" "$RU_SERVER_CONF"; fi

# Убираем IPv6
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$RU_SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$RU_SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$RU_SERVER_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$RU_SERVER_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$RU_SERVER_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$RU_SERVER_CONF"
sed -i '/^PostUp = ip6tables /d' "$RU_SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$RU_SERVER_CONF"

# Создаём туннель awg-nl
cp "$RU_GATEWAY_CONF_SOURCE" "$NL_TUNNEL_CONF"
chmod 600 "$NL_TUNNEL_CONF"
sed -i '/^DNS = /d' "$NL_TUNNEL_CONF"

sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$NL_TUNNEL_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$NL_TUNNEL_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$NL_TUNNEL_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$NL_TUNNEL_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$NL_TUNNEL_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$NL_TUNNEL_CONF"

if ! grep -q "^Table = off" "$NL_TUNNEL_CONF"; then
  sed -i '/^\[Interface\]/a Table = off' "$NL_TUNNEL_CONF"
fi
sed -i -E 's#^AllowedIPs = .*#AllowedIPs = 0.0.0.0/0#g' "$NL_TUNNEL_CONF"

# Включаем forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system >/dev/null

# Минимальные PostUp/PostDown для туннеля
cat >> "$RU_SERVER_CONF" <<EOF

PostUp = iptables -t nat -D POSTROUTING -s $RU_CLIENT_SUBNET -o awg-nl -j MASQUERADE 2>/dev/null || true
PostUp = iptables -t nat -A POSTROUTING -s $RU_CLIENT_SUBNET -o awg-nl -j MASQUERADE

PostUp = iptables -D FORWARD -i awg0 -o awg-nl -j ACCEPT 2>/dev/null || true
PostUp = iptables -D FORWARD -i awg-nl -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
PostUp = iptables -A FORWARD -i awg0 -o awg-nl -j ACCEPT
PostUp = iptables -A FORWARD -i awg-nl -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s $RU_CLIENT_SUBNET -o awg-nl -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i awg0 -o awg-nl -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i awg-nl -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
EOF

# Создаём add-awg-client
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
  candidate="10.77.77.$i"
  if ! grep -q "$candidate/32" "$SERVER_CONF"; then
    CLIENT_IP="$candidate"
    break
  fi
done

if [ -z "$CLIENT_IP" ]; then
  echo "Ошибка: свободных IP в подсети 10.77.77.0/24 не найдено"
  exit 1
fi

CLIENT_PRIVATE=$(awg genkey)
CLIENT_PUBLIC=$(echo "$CLIENT_PRIVATE" | awg pubkey)
CLIENT_PSK=$(awg genpsk)

MTU=$(grep "^MTU" "$SERVER_CONF" | awk '{print $3}')
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
DNS = 10.77.77.1
MTU = $MTU
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

# Systemd dependency
mkdir -p /etc/systemd/system/awg-quick@awg0.service.d
cat > /etc/systemd/system/awg-quick@awg0.service.d/cascade.conf <<EOF
[Unit]
Requires=awg-quick@awg-nl.service
After=awg-quick@awg-nl.service
EOF

systemctl daemon-reload

# Запуск
awg-quick down awg-nl 2>/dev/null || true
awg-quick down awg0 2>/dev/null || true

systemctl enable "$AWG_NL_SERVICE"
systemctl enable "$AWG_RU_SERVICE"
systemctl restart "$AWG_NL_SERVICE"
systemctl restart "$AWG_RU_SERVICE"

echo ""
echo "Готово. RU-сервер настроен (весь трафик идёт через EU/NL)."
echo "Используй: sudo add-awg-client [имя_клиента]"
