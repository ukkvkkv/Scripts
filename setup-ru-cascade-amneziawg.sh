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
RU_GATEWAY_CONF_SOURCE="${1:-/root/ru-gateway-for-ru.conf}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: запусти скрипт от root или через sudo"
  exit 1
fi

if [ ! -f "$RU_GATEWAY_CONF_SOURCE" ]; then
  echo "Ошибка: не найден конфиг RU → EU/NL:"
  echo "$RU_GATEWAY_CONF_SOURCE"
  echo ""
  echo "Сначала перенеси файл с EU/NL-сервера:"
  echo "/root/ru-gateway-for-ru.conf"
  exit 1
fi

echo ""
echo "========== RU-СЕРВЕР: УСТАНОВКА AMNEZIAWG =========="
echo ""

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y curl wget qrencode iptables iptables-persistent ca-certificates

curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE"
chmod +x "$INSTALLER_FILE"

echo ""
echo "Сейчас запустится официальный установщик AmneziaWG."
echo "Он может задать несколько вопросов."
echo "Этот awg0 будет использоваться как сервер для клиентов на RU."
echo ""

bash "$INSTALLER_FILE"

if [ ! -f "$RU_SERVER_CONF" ]; then
  echo "Ошибка: серверный конфиг RU не найден: $RU_SERVER_CONF"
  exit 1
fi

if ! command -v awg >/dev/null 2>&1; then
  echo "Ошибка: команда awg не найдена"
  exit 1
fi

mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"

echo ""
echo "========== НАСТРАИВАЕМ awg0 НА RU-ПОДСЕТЬ 10.77.77.0/24 =========="
echo ""

cp "$RU_SERVER_CONF" "$RU_SERVER_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Убираем всех клиентов, созданных установщиком, чтобы начать чисто.
awk 'BEGIN{keep=1} /^\[Peer\]/{keep=0} keep{print}' "$RU_SERVER_CONF" > /tmp/awg0.interface.only
mv /tmp/awg0.interface.only "$RU_SERVER_CONF"

# Меняем адрес сервера на RU-подсеть.
sed -i -E "s#^Address = .*#Address = $RU_SERVER_ADDRESS#g" "$RU_SERVER_CONF"

# Убираем IPv6.
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$RU_SERVER_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$RU_SERVER_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$RU_SERVER_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$RU_SERVER_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$RU_SERVER_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$RU_SERVER_CONF"
sed -i '/^PostUp = ip6tables /d' "$RU_SERVER_CONF"
sed -i '/^PostDown = ip6tables /d' "$RU_SERVER_CONF"

# Убираем старые PostUp/PostDown, которые могли делать NAT напрямую в интернет.
sed -i '/^PostUp = iptables /d' "$RU_SERVER_CONF"
sed -i '/^PostDown = iptables /d' "$RU_SERVER_CONF"
sed -i '/^PostUp = ip rule /d' "$RU_SERVER_CONF"
sed -i '/^PostDown = ip rule /d' "$RU_SERVER_CONF"
sed -i '/^PostUp = ip route /d' "$RU_SERVER_CONF"
sed -i '/^PostDown = ip route /d' "$RU_SERVER_CONF"

cat >> "$RU_SERVER_CONF" <<EOF
PostUp = ip rule add from $RU_CLIENT_SUBNET table 200 2>/dev/null || true
PostUp = ip route replace default dev awg-nl table 200
PostUp = iptables -t nat -A POSTROUTING -s $RU_CLIENT_SUBNET -o awg-nl -j MASQUERADE
PostUp = iptables -A FORWARD -i awg0 -o awg-nl -j ACCEPT
PostUp = iptables -A FORWARD -i awg-nl -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

PostDown = ip rule del from $RU_CLIENT_SUBNET table 200 2>/dev/null || true
PostDown = ip route del default dev awg-nl table 200 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s $RU_CLIENT_SUBNET -o awg-nl -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i awg0 -o awg-nl -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i awg-nl -o awg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
EOF

echo ""
echo "========== СОЗДАЁМ ТУННЕЛЬ RU → EU/NL: awg-nl =========="
echo ""

cp "$RU_GATEWAY_CONF_SOURCE" "$NL_TUNNEL_CONF"
chmod 600 "$NL_TUNNEL_CONF"

# Для серверного туннеля DNS не нужен, иначе может быть ошибка resolvconf.
sed -i '/^DNS = /d' "$NL_TUNNEL_CONF"

# Убираем IPv6 из туннеля.
sed -i -E 's/,[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$NL_TUNNEL_CONF"
sed -i -E 's/fd42:[0-9a-fA-F:]+\/[0-9]+,[[:space:]]*//g' "$NL_TUNNEL_CONF"
sed -i -E 's/[[:space:]]*fd42:[0-9a-fA-F:]+\/[0-9]+//g' "$NL_TUNNEL_CONF"
sed -i -E 's/,[[:space:]]*::\/0//g' "$NL_TUNNEL_CONF"
sed -i -E 's/::\/0,[[:space:]]*//g' "$NL_TUNNEL_CONF"
sed -i -E 's/[[:space:]]*::\/0//g' "$NL_TUNNEL_CONF"

# Для awg-nl нужен полный AllowedIPs, но без изменения основной таблицы маршрутов.
if ! grep -q "^Table = off" "$NL_TUNNEL_CONF"; then
  sed -i '/^\[Interface\]/a Table = off' "$NL_TUNNEL_CONF"
fi

sed -i -E 's#^AllowedIPs = .*#AllowedIPs = 0.0.0.0/0#g' "$NL_TUNNEL_CONF"

echo ""
echo "========== ВКЛЮЧАЕМ IPV4 FORWARDING =========="
echo ""

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-awg-forward.conf
sysctl --system >/dev/null

echo ""
echo "========== СОЗДАЁМ КОМАНДУ add-awg-client ДЛЯ RU-СЕРВЕРА =========="
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
echo "========== НАСТРАИВАЕМ ПОРЯДОК ЗАПУСКА СЕРВИСОВ =========="
echo ""

mkdir -p /etc/systemd/system/awg-quick@awg0.service.d

cat > /etc/systemd/system/awg-quick@awg0.service.d/cascade.conf <<EOF
[Unit]
Requires=awg-quick@awg-nl.service
After=awg-quick@awg-nl.service
EOF

systemctl daemon-reload

echo ""
echo "========== ЗАПУСКАЕМ ТУННЕЛЬ И RU-СЕРВЕР =========="
echo ""

# На случай если интерфейсы уже были подняты вручную.
awg-quick down awg-nl 2>/dev/null || true
awg-quick down awg0 2>/dev/null || true

systemctl enable "$AWG_NL_SERVICE"
systemctl enable "$AWG_RU_SERVICE"

systemctl restart "$AWG_NL_SERVICE"
systemctl restart "$AWG_RU_SERVICE"

echo ""
echo "========== СОЗДАЁМ ПЕРВОГО ТЕСТОВОГО КЛИЕНТА НА RU =========="
echo ""

add-awg-client client_test > /tmp/ru-client-test-output.txt

echo ""
echo "========== ГОТОВО НА RU-СЕРВЕРЕ =========="
echo ""
echo "RU-сервер настроен как каскадный входной узел."
echo ""
echo "Схема:"
echo "Клиент → RU сервер → EU/NL сервер → интернет"
echo ""
echo "Интерфейсы:"
echo "awg0   — сервер для клиентов на RU, подсеть 10.77.77.0/24"
echo "awg-nl — туннель RU → EU/NL"
echo ""
echo "Для создания новых клиентов используй:"
echo ""
echo "sudo add-awg-client имя_клиента"
echo ""
echo "Например:"
echo "sudo add-awg-client iphone_ivan"
echo ""
echo "Можно без имени:"
echo "sudo add-awg-client"
echo ""
echo "========== ТЕСТОВЫЙ КЛИЕНТСКИЙ КОНФИГ =========="
echo ""
awk '/^\[Interface\]/{flag=1} flag{print}' /tmp/ru-client-test-output.txt