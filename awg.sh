#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Запусти скрипт от root: sudo bash $0"
  exit 1
fi

cat > /etc/sysctl.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
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

get_wan_if() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

port_in_use() {
  local p="$1"
  ss -H -uln 2>/dev/null | awk '{print $5}' | grep -Eq ":${p}$"
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
  echo "Не удалось подобрать свободный порт" >&2
  exit 1
}

open_udp_port() {
  local p="$1"
  if need_cmd ufw; then
    ufw allow "${p}/udp" 2>/dev/null || true
  fi
}

# Генерирует непересекающиеся обфускационные параметры AmneziaWG 1.5
# и печатает их как shell-присвоения (использовать через eval).
gen_awg_params() {
  python3 - <<'PY'
import random

jc = random.randint(4, 10)
jmin = random.randint(40, 120)
jmax = random.randint(jmin + 50, min(jmin + 700, 1280))

s1 = random.randint(15, 150)
s2 = random.randint(15, 150)
while s1 + 56 == s2:
    s2 = random.randint(15, 150)

# H1-H4 обязаны быть попарно различны
h = random.sample(range(5, 2_000_000_000), 4)

print(f"AWG_JC={jc}")
print(f"AWG_JMIN={jmin}")
print(f"AWG_JMAX={jmax}")
print(f"AWG_S1={s1}")
print(f"AWG_S2={s2}")
print(f"AWG_H1={h[0]}")
print(f"AWG_H2={h[1]}")
print(f"AWG_H3={h[2]}")
print(f"AWG_H4={h[3]}")
PY
}

install_amneziawg() {
  if need_cmd awg && need_cmd awg-quick; then
    echo "AmneziaWG уже установлен: $(awg --version 2>/dev/null || echo ok)"
    return 0
  fi
  echo "Устанавливаю AmneziaWG (kernel module + tools) из PPA amnezia/ppa..."
  apt update
  apt install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)" || true
  add-apt-repository -y ppa:amnezia/ppa
  apt update
  apt install -y amneziawg

  if ! need_cmd awg-quick; then
    echo "Ошибка: awg-quick не появился после установки. Проверь вывод apt выше."
    exit 1
  fi
}

apt update
apt install -y curl ca-certificates python3 iproute2 iptables fail2ban ufw ipset dnsutils

PUBLIC_IP=$(get_public_ip)
WAN_IF=$(get_wan_if)
if [[ -z "$WAN_IF" ]]; then
  echo "Не удалось определить исходящий сетевой интерфейс (WAN). Проверь маршрут по умолчанию."
  exit 1
fi
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Не удалось автоопределить публичный IP сервера."
  exit 1
fi

EU_ENDPOINT_HOST="$PUBLIC_IP"
echo "Текущий публичный IPv4 сервера: ${PUBLIC_IP:-не удалось определить}"
echo "WAN-интерфейс: $WAN_IF"
echo "Endpoint для клиентов будет: $EU_ENDPOINT_HOST"

install_amneziawg

# Останавливаем возможные старые интерфейсы
systemctl stop awg-quick@awg1 2>/dev/null || true
systemctl disable awg-quick@awg1 2>/dev/null || true

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

EU_PORT=$(random_port)
THIRD=$(shuf -i 10-250 -n 1)
TUN_SUBNET="10.29.${THIRD}"

# Ключи сервера (EU, "выход")
EU_PRIV=$(awg genkey)
EU_PUB=$(echo "$EU_PRIV" | awg pubkey)

# Ключи клиента-хопа (RU, "вход") — генерируются здесь же,
# чтобы сразу прописать RU как разрешённого peer'а на EU.
RU_PRIV=$(awg genkey)
RU_PUB=$(echo "$RU_PRIV" | awg pubkey)

eval "$(gen_awg_params)"

open_udp_port "$EU_PORT"

cat > /etc/amnezia/amneziawg/awg1.conf <<EOF_CONF
[Interface]
PrivateKey = ${EU_PRIV}
Address = ${TUN_SUBNET}.1/24
ListenPort = ${EU_PORT}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
PostUp = iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE; iptables -A FORWARD -i awg1 -j ACCEPT; iptables -A FORWARD -o awg1 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE; iptables -D FORWARD -i awg1 -j ACCEPT; iptables -D FORWARD -o awg1 -j ACCEPT

[Peer]
# ru-hop (сервер-вход)
PublicKey = ${RU_PUB}
AllowedIPs = ${TUN_SUBNET}.2/32
EOF_CONF

chmod 600 /etc/amnezia/amneziawg/awg1.conf

systemctl daemon-reload
systemctl enable --now awg-quick@awg1
systemctl restart awg-quick@awg1
sleep 2

if ! systemctl is-active --quiet awg-quick@awg1; then
  echo "Ошибка: awg-quick@awg1 не запустился. Логи:"
  journalctl --no-pager -e -u awg-quick@awg1
  exit 1
fi

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
ufw allow "$EU_PORT"/udp
ufw --force enable

RU_HOP_CONF=$(cat <<EOF_HOP
[Interface]
PrivateKey = ${RU_PRIV}
Address = ${TUN_SUBNET}.2/32
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${EU_PUB}
Endpoint = ${EU_ENDPOINT_HOST}:${EU_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
END
EOF_HOP
)

echo
echo "=== AmneziaWG EU (выход) сервер готов ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "$RU_HOP_CONF"
