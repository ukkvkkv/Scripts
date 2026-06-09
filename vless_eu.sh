#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

get_public_ip() {
  curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

random_port() {
  shuf -i 20000-60000 -n 1
}

EU_PORT=$(random_port)

apt update -y >/dev/null 2>&1
apt install -y curl wget jq openssl sshpass >/dev/null 2>&1

bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install >/dev/null 2>&1

EU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)
EU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
EU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
EU_SHORT_ID=$(openssl rand -hex 8)

read -rp "SNI domain (default: www.microsoft.com): " EU_DOMAIN
EU_DOMAIN="${EU_DOMAIN,,:-www.microsoft.com}"

if [[ -f /usr/local/etc/xray/config.json ]]; then
  cp /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.backup.$(date +%F)"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "tag": "vless-eu-in", "listen": "0.0.0.0", "port": $EU_PORT, "protocol": "vless",
    "settings": { "clients": [ { "id": "$EU_UUID", "email": "multihop@eu", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
    "streamSettings": { "network": "raw", "security": "reality", "realitySettings": { "show": false, "dest": "$EU_DOMAIN:443", "xver": 0, "serverNames": ["$EU_DOMAIN"], "privateKey": "$EU_PRIVATE_KEY", "shortIds": ["$EU_SHORT_ID"] }, "sockopt": { "tcpFastOpen": true }
  }],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" }, { "tag": "block", "protocol": "blackhole" } ],
  "routing": { "domainStrategy": "AsIs", "rules": [ { "type": "field", "inboundTag": ["vless-eu-in"], "outboundTag": "direct" } ]
  }
}
EOF

systemctl enable --now xray >/dev/null 2>&1
systemctl restart xray

PUBLIC_IP=$(get_public_ip)

echo "EU ready"
echo "IP: $PUBLIC_IP"
echo "Port: $EU_PORT"
echo "UUID: $EU_UUID"
echo "PublicKey: $EU_PUBLIC_KEY"
echo "ShortID: $EU_SHORT_ID"
echo "SNI: $EU_DOMAIN"

read -rp "Transfer params to RU server? [y/N]: " DO_TR
if [[ "${DO_TR,,}" == "y" ]]; then
  read -rp "RU IP: " RU_IP
  read -s -rp "Root password: " RU_PASS
  echo
  cat > /tmp/eu-params.env <<EOP
EU_IP="$PUBLIC_IP"
EU_PORT="$EU_PORT"
EU_UUID="$EU_UUID"
EU_PUBLIC_KEY="$EU_PUBLIC_KEY"
EU_SHORT_ID="$EU_SHORT_ID"
EU_SERVER_NAME="$EU_DOMAIN"
EU_NETWORK="raw"
EU_FLOW="xtls-rprx-vision"
EOP
  sshpass -p "$RU_PASS" scp -o StrictHostKeyChecking=no /tmp/eu-params.env root@"$RU_IP":/root/eu-params.env 2>/dev/null && echo "Params transferred" || echo "Transfer failed"
  rm -f /tmp/eu-params.env
fi
