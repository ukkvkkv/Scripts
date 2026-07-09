
cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p

set -euo pipefail

apt update
apt install -y cron

systemctl enable cron
systemctl start cron


cat <<EOF | crontab -
0 2 * * * reboot
EOF

crontab -l

NEW_PORT=$(shuf -i 20000-60000 -n 1)

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sed -i '/^#\?Port /d' /etc/ssh/sshd_config

echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

if command -v ufw >/dev/null 2>&1; then
  ufw allow "$NEW_PORT" || true
fi

echo "=============================="
echo "НОВЫЙ SSH ПОРТ: $NEW_PORT"
echo "=============================="

# Disable password authentication (reverted as requested)
sed -i '/^#\?PasswordAuthentication /d' /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config

sed -i '/^#\?PubkeyAuthentication /d' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd
