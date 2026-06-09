#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

get_public_ip() { curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'; }
random_port() { shuf -i 20000-60000 -n 1; }

EU_PORT=$(random_port)
MT_PORT=$(random_port)
MT_SECRET=$(openssl rand -hex 16)

apt update -y >/dev/null 2>&1
apt install -y curl wget jq openssl sshpass python3 git >/dev/null 2>&1

# === VLESS ===
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) @ install >/dev/null 2>&1

EU_UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519)
EU_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | head -n1 | awk '{print $3}')
EU_PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | head -n1 | awk '{print $3}')
EU_SHORT_ID=$(openssl rand -hex 8)

read -rp "SNI for VLESS (default www.microsoft.com): " EU_DOMAIN
EU_DOMAIN="${EU_DOMAIN,,:-www.microsoft.com}"

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [{
    "tag": "vless-eu-in", "port": $EU_PORT, "protocol": "vless",
    "settings": { "clients": [{"id":"$EU_UUID","flow":"xtls-rprx-vision"}], "decryption":"none" },
    "streamSettings": { "network":"raw", "security":"reality", "realitySettings": {"dest":"$EU_DOMAIN:443","serverNames":["$EU_DOMAIN"],"privateKey":"$EU_PRIVATE_KEY","shortIds":["$EU_SHORT_ID"]} }
  }],
  "outbounds": [{"tag":"direct","protocol":"freedom"}],
  "routing": { "rules": [{"type":"field","inboundTag":["vless-eu-in"],"outboundTag":"direct"}] }
}
EOF

systemctl enable --now xray
systemctl restart xray

# === MTProto on EU ===
rm -rf /opt/mtprotoproxy
mkdir -p /opt/mtprotoproxy
cd /opt/mtprotoproxy
git clone https://github.com/alexbers/mtprotoproxy.git . >/dev/null 2>&1

cat > config.py <<EOF
PORT = $MT_PORT
USERS = {"main": "$MT_SECRET"}
TLS_DOMAIN = "vk.ru"
MODES = {"classic": True, "secure": True, "tls": True}
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

PUBLIC_IP=$(get_public_ip)

echo "EU ready"
echo "VLESS Port: $EU_PORT | UUID: $EU_UUID | PublicKey: $EU_PUBLIC_KEY | ShortID: $EU_SHORT_ID | SNI: $EU_DOMAIN"
echo "MTProto Port: $MT_PORT | Secret: $MT_SECRET"

read -rp "Transfer to RU? [y/N]: " DO
if [[ "${DO,,}" == "y" ]]; then
  read -rp "RU IP: " RU_IP; read -s -rp "Password: " PW; echo
  cat > /tmp/params.env <<EOP
EU_IP="$PUBLIC_IP"
EU_VLESS_PORT="$EU_PORT"
EU_VLESS_UUID="$EU_UUID"
EU_PUBLIC_KEY="$EU_PUBLIC_KEY"
EU_SHORT_ID="$EU_SHORT_ID"
EU_SNI="$EU_DOMAIN"
EU_NETWORK="raw"
EU_FLOW="xtls-rprx-vision"
MT_PORT="$MT_PORT"
MT_SECRET="$MT_SECRET"
EOP
  sshpass -p "$PW" scp /tmp/params.env root@"$RU_IP":/root/params.env 2>/dev/null && echo "Params sent" || echo "Failed"
fi
