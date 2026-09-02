#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

AWG_PORT="${AWG_PORT:-443}"
AWG_SUBNET_PREFIX=10.9.9
AWG_HOP_IP="${AWG_SUBNET_PREFIX}.2"

cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl -p

need_cmd() { command -v "$1" >/dev/null 2>&1; }

get_public_ip() {
  local ip=""
  for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
    ip=$(curl -4fsSL --max-time 8 "$url" 2>/dev/null || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  hostname -I | awk '{print $1}'
}

udp_port_in_use() {
  local p="$1"
  [[ -n "$(ss -H -uln "sport = :${p}" 2>/dev/null)" ]]
}

open_udp_port() {
  local p="$1"
  if need_cmd ufw; then
    ufw allow "${p}/udp" 2>/dev/null || true
  fi
  if need_cmd iptables; then
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT || true
    iptables -C OUTPUT -p udp --sport "$p" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p udp --sport "$p" -j ACCEPT || true
  fi
}

install_amneziawg() {
  if need_cmd awg && modinfo amneziawg >/dev/null 2>&1; then
    echo "AmneziaWG уже установлен: $(awg --version | head -n 1)"
    return 0
  fi
  echo "Устанавливаю AmneziaWG..."
  # Заголовки именно работающего ядра: linux-headers-generic — метапакет, он тянет
  # самое свежее ядро из репозитория, и на отстающем образе VPS DKMS соберёт модуль
  # не под то ядро, а modprobe ниже упадёт.
  apt install -y software-properties-common "linux-headers-$(uname -r)" linux-headers-generic
  add-apt-repository -y ppa:amnezia/ppa
  apt update
  apt install -y amneziawg-dkms amneziawg-tools
  if ! modprobe amneziawg; then
    echo "Ошибка: модуль amneziawg не загрузился."
    echo "Обычно это значит, что linux-headers не совпадают с текущим ядром."
    echo "Проверь: dkms status; uname -r; ls -d /usr/src/linux-headers-*"
    exit 1
  fi
  echo "AmneziaWG: модуль $(modinfo -F version amneziawg), утилиты $(awg --version | head -n 1)"
}

gen_awg_params() {
  AWG_JC=$(shuf -i 3-6 -n 1)
  AWG_JMIN=$(shuf -i 40-89 -n 1)
  AWG_JMAX=$(( AWG_JMIN + $(shuf -i 50-250 -n 1) ))

  AWG_S1=$(shuf -i 15-150 -n 1)
  AWG_S2=$(shuf -i 15-150 -n 1)
  while [[ $(( AWG_S1 + 56 )) -eq "$AWG_S2" ]]; do AWG_S2=$(shuf -i 15-150 -n 1); done
  AWG_S3=$(shuf -i 15-55 -n 1)
  while [[ $(( AWG_S2 + 28 )) -eq "$AWG_S3" ]]; do AWG_S3=$(shuf -i 15-55 -n 1); done
  AWG_S4=$(shuf -i 15-55 -n 1)

  AWG_H1=$(shuf -i 10-2147483647 -n 1)
  AWG_H2=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H2" == "$AWG_H1" ]]; do AWG_H2=$(shuf -i 10-2147483647 -n 1); done
  AWG_H3=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H3" == "$AWG_H1" || "$AWG_H3" == "$AWG_H2" ]]; do AWG_H3=$(shuf -i 10-2147483647 -n 1); done
  AWG_H4=$(shuf -i 10-2147483647 -n 1)
  while [[ "$AWG_H4" == "$AWG_H1" || "$AWG_H4" == "$AWG_H2" || "$AWG_H4" == "$AWG_H3" ]]; do
    AWG_H4=$(shuf -i 10-2147483647 -n 1)
  done
}

setup_awg_exit() {
  local conf=/etc/amnezia/amneziawg/awg0.conf
  local wan
  wan=$(ip -4 route show default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  [[ -n "$wan" ]] || { echo "Ошибка: не удалось определить внешний интерфейс."; exit 1; }

  if udp_port_in_use "$AWG_PORT"; then
    echo "Ошибка: ${AWG_PORT}/udp уже занят — его должен слушать AmneziaWG."
    ss -lunp | grep ":${AWG_PORT}" || true
    exit 1
  fi

  install_amneziawg
  gen_awg_params
  sysctl -qw net.ipv4.ip_forward=1

  install -d -m 700 /etc/amnezia/amneziawg
  local old_umask; old_umask=$(umask); umask 077
  AWG_SRV_PRIV=$(awg genkey)
  AWG_SRV_PUB=$(echo "$AWG_SRV_PRIV" | awg pubkey)
  AWG_HPK=$(openssl rand -base64 32)
  AWG_HOP_PRIV=$(awg genkey)
  AWG_HOP_PUB=$(echo "$AWG_HOP_PRIV" | awg pubkey)

  cat > "$conf" <<EOF_AWG
[Interface]
PrivateKey = ${AWG_SRV_PRIV}
Address = ${AWG_SUBNET_PREFIX}.1/24
ListenPort = ${AWG_PORT}
MTU = 1280
HeaderProtectionKey = ${AWG_HPK}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${wan} -j MASQUERADE
PostUp = iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostUp = iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o ${wan} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true
PostDown = iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240 2>/dev/null || true

[Peer]
#_Name = entry-hop
PublicKey = ${AWG_HOP_PUB}
AllowedIPs = ${AWG_HOP_IP}/32
EOF_AWG
  chmod 600 "$conf"

  systemctl enable --now awg-quick@awg0
  sleep 2
  if ! systemctl is-active --quiet awg-quick@awg0; then
    echo "Ошибка: awg-quick@awg0 не запустился. Логи:"
    journalctl --no-pager -e -u awg-quick@awg0 | tail -n 30
    exit 1
  fi
  if ! udp_port_in_use "$AWG_PORT"; then
    echo "Ошибка: AmneziaWG не слушает ${AWG_PORT}/udp."
    exit 1
  fi
  umask "$old_umask"
  echo "AmneziaWG поднят"
}

awg_hop_string() {
  {
    printf 'V=1\n'
    printf 'ENDPOINT=%s:%s\n' "$PUBLIC_IP" "$AWG_PORT"
    printf 'SERVER_PUB=%s\n' "$AWG_SRV_PUB"
    printf 'HPK=%s\n' "$AWG_HPK"
    printf 'JC=%s\nJMIN=%s\nJMAX=%s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX"
    printf 'S1=%s\nS2=%s\nS3=%s\nS4=%s\n' "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4"
    printf 'H1=%s\nH2=%s\nH3=%s\nH4=%s\n' "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4"
    printf 'HOP_PRIV=%s\n' "$AWG_HOP_PRIV"
    printf 'HOP_IP=%s\n' "$AWG_HOP_IP"
  } | base64 -w0
}

apt update
apt install -y curl ca-certificates openssl iproute2 iptables fail2ban

PUBLIC_IP=$(get_public_ip)

open_udp_port "$AWG_PORT"
setup_awg_exit

NEW_SSH_PORT=$(shuf -i 20000-60000 -n 1)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
sed -i '/^#\?Port /d' /etc/ssh/sshd_config
echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
sed -i '/^#\?PasswordAuthentication /d' /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
sed -i '/^#\?PubkeyAuthentication /d' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd

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

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow "$NEW_SSH_PORT"/tcp
ufw allow "$AWG_PORT"/udp
ufw --force enable

echo
echo "=== Готово ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "AWGHOP1:$(awg_hop_string)"
echo
