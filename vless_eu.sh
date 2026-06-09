#!/usr/bin/env bash
set -e

echo "=== EU VLESS + MTProto Setup (простая версия) ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужно запускать от root"
  exit 1
fi

# Генерируем значения
EU_PORT=$(shuf -i 20000-60000 -n 1)
MT_PORT=$(shuf -i 20000-60000 -n 1)
MT_SECRET=$(openssl rand -hex 16)

echo "Обновляем систему и ставим зависимости..."
apt update
apt install -y curl wget jq openssl sshpass python3 git

# Установка Xray (именно та команда, которую ты просил)
if ! command -v xray >/dev/null 2>&1; then
  echo "Ставим Xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

export PATH=$PATH:/usr/local/bin

if ! command -v xray >/dev/null 2>&1; then
  echo "Xray не установился. Установи вручную и запусти скрипт заново."
  exit 1
fi

# Генерируем ключи и параметры
EU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)

if echo "$KEYS" | grep -q "PrivateKey:"; then
  EU_PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | head -n1 | awk '{print $2}')
  EU_PUBLIC_KEY=$(echo "$KEYS" | grep "Password (PublicKey):" | head -n1 | awk '{print $3}')
else
  EU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
  EU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
fi

EU_SHORT_ID=$(openssl rand -hex 8)

read -rp "SNI (нажми Enter для www.microsoft.com): " EU_SNI
EU_SNI="${EU_SNI:-www.microsoft.com}"

# Создаём конфиг Xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "tag": "vless-eu-in",
    "port": $EU_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$EU_UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "dest": "$EU_SNI:443",
        "serverNames": ["$EU_SNI"],
        "privateKey": "$EU_PRIVATE_KEY",
        "shortIds": ["$EU_SHORT_ID"]
      }
    }
  }],
  "outbounds": [{ "tag": "direct", "protocol": "freedom" }],
  "routing": { "rules": [{ "type": "field", "inboundTag": ["vless-eu-in"], "outboundTag": "direct" }] }
}
EOF

systemctl restart xray
echo "Xray перезапущен"

# MTProto
echo "Ставим MTProto proxy..."
rm -rf /opt/mtprotoproxy
mkdir -p /opt/mtprotoproxy
cd /opt/mtprotoproxy
git clone https://github.com/alexbers/mtprotoproxy.git .

cat > config.py <<EOF
PORT = $MT_PORT
USERS = {"main": "$MT_SECRET"}
TLS_DOMAIN = "vk.ru"
MODES = {"classic": true, "secure": true, "tls": true}
EOF

cat > /etc/systemd/system/mtprotoproxy.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/mtprotoproxy
ExecStart=/usr/bin/python3 /opt/mtprotoproxy/mtprotoproxy.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtprotoproxy

PUBLIC_IP=$(curl -s ifconfig.me || echo "IP_СЕРВЕРА")

echo ""
echo "=== ГОТОВО ==="
echo "VLESS Port: $EU_PORT"
echo "VLESS UUID: $EU_UUID"
echo "VLESS PublicKey: $EU_PUBLIC_KEY"
echo "VLESS ShortID: $EU_SHORT_ID"
echo "VLESS SNI: $EU_SNI"
echo ""
echo "MTProto Port: $MT_PORT"
echo "MTProto Secret: $MT_SECRET"
echo ""
echo "MTProto ссылка (замени IP):"
echo "tg://proxy?server=$PUBLIC_IP&port=$MT_PORT&secret=$MT_SECRET"
