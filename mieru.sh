#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти от root: sudo bash $0"
  exit 1
fi

echo "=== Подготовка системы ==="

# Отключаем IPv6 + BBR
cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p

echo "=== Установка Mieru ==="

port_in_use() {
  ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq ":${1}$" || \
  ss -H -ulnp 2>/dev/null | awk '{print $5}' | grep -Eq ":${1}$"
}

random_port() {
  local p
  for _ in {1..100}; do
    p=$(shuf -i 20000-60000 -n 1)
    if ! port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "Не удалось подобрать порт" >&2; exit 1
}

random_pass() {
  openssl rand -base64 24 | tr '+/' '-_' | tr -d '=' | cut -c1-28
}

get_public_ip() {
  local ip
  for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    ip=$(curl -4fsSL --max-time 6 "$url" 2>/dev/null || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  hostname -I | awk '{print $1}'
}

LATEST_VERSION=$(curl -s https://api.github.com/repos/enfein/mieru/releases/latest | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "3.34.0")
ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == "amd64" ]] && DEB_FILE="mita_${LATEST_VERSION}_amd64.deb" || DEB_FILE="mita_${LATEST_VERSION}_arm64.deb"

curl -LSO "https://github.com/enfein/mieru/releases/download/v${LATEST_VERSION}/${DEB_FILE}"
sudo dpkg -i "${DEB_FILE}" >/dev/null 2>&1 || sudo apt-get install -f -y -qq >/dev/null 2>&1
rm -f "${DEB_FILE}"

USERNAME="u$(openssl rand -hex 5)"
PASSWORD=$(random_pass)
MIERU_PORT=$(random_port)

cat > /tmp/mita_config.json <<EOF
{
  "portBindings": [{"port": ${MIERU_PORT}, "protocol": "UDP"}],
  "users": [{"name": "${USERNAME}", "password": "${PASSWORD}"}],
  "loggingLevel": "DEBUG",
  "traffic_pattern": "GgQIARAK",
  "multiplexing": {"level": "MULTIPLEXING_MIDDLE"},
  "mtu": 1280
}
EOF

sg mita -c "mita apply config /tmp/mita_config.json" 2>/dev/null || true
systemctl daemon-reload
systemctl restart mita
systemctl enable mita

PUBLIC_IP=$(get_public_ip)


# === SSH + Fail2Ban + UFW ===
NEW_SSH_PORT=$(shuf -i 20000-60000 -n 1)

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i '/^#\?Port /d' /etc/ssh/sshd_config
echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config

sed -i '/^#\?PasswordAuthentication /d' /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

sed -i '/^#\?PubkeyAuthentication /d' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd

# === Установка и настройка Fail2Ban ===
apt install -y fail2ban

cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# === UFW ===
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow "$NEW_SSH_PORT"/tcp
ufw allow "$MIERU_PORT"/udp
ufw --force enable

echo
echo "=============================="
echo "ГОТОВО"
echo
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "mierus://${USERNAME}:${PASSWORD}@${PUBLIC_IP}?udp=1&transport=udp&port=${MIERU_PORT}&profile=見える"
echo "=============================="
