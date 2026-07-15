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
  for url in "https://api.ipify.org" "https://ifconfig.me"; do
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

# Парсит вставленный текстовый конфиг EU-хопа (формат wg-conf) и печатает
# shell-присвоения для eval, аналогично parse_eu_link() в hysteria2-варианте.
parse_eu_hop_conf() {
  EU_HOP_INPUT="$1" python3 - <<'PY'
import os, re, shlex, sys

text = os.environ.get("EU_HOP_INPUT", "")
if not text.strip():
    print("Пустой конфиг", file=sys.stderr)
    sys.exit(1)

parts = re.split(r'(?im)^\[Peer\]\s*$', text, maxsplit=1)
if len(parts) != 2:
    print("Не найдена секция [Peer] в конфиге", file=sys.stderr)
    sys.exit(1)
iface_block, peer_block = parts

def grab(block, key):
    m = re.search(rf'(?im)^{re.escape(key)}\s*=\s*(.+?)\s*$', block)
    return m.group(1).strip() if m else ""

fields = {
    "RU_PRIV": grab(iface_block, "PrivateKey"),
    "RU_TUN_ADDR": grab(iface_block, "Address"),
    "AWG_JC": grab(iface_block, "Jc"),
    "AWG_JMIN": grab(iface_block, "Jmin"),
    "AWG_JMAX": grab(iface_block, "Jmax"),
    "AWG_S1": grab(iface_block, "S1"),
    "AWG_S2": grab(iface_block, "S2"),
    "AWG_H1": grab(iface_block, "H1"),
    "AWG_H2": grab(iface_block, "H2"),
    "AWG_H3": grab(iface_block, "H3"),
    "AWG_H4": grab(iface_block, "H4"),
    "EU_PUB": grab(peer_block, "PublicKey"),
    "EU_ENDPOINT": grab(peer_block, "Endpoint"),
}

missing = [k for k in ("RU_PRIV", "RU_TUN_ADDR", "EU_PUB", "EU_ENDPOINT") if not fields[k]]
if missing:
    print(f"Не найдены обязательные поля: {missing}", file=sys.stderr)
    sys.exit(1)

for k, v in fields.items():
    print(f"{k}={shlex.quote(v)}")
PY
}

EU_HOP_CONF=""
while IFS= read -r line; do
  [[ "$line" == "END" ]] && break
  EU_HOP_CONF+="${line}"$'\n'
done

eval "$(parse_eu_hop_conf "$EU_HOP_CONF")"

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
echo "Текущий публичный IPv4 RU-сервера: ${PUBLIC_IP}"
echo "WAN-интерфейс: $WAN_IF"

install_amneziawg

systemctl stop awg-quick@awg1 2>/dev/null || true
systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl disable awg-quick@awg1 2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

# --- awg1: клиентское подключение RU -> EU (туннель-хоп) ---
# Table = off, чтобы awg-quick не трогал таблицу маршрутизации по умолчанию —
# маршрутизацией займётся наш собственный split-routing скрипт ниже.
cat > /etc/amnezia/amneziawg/awg1.conf <<EOF_CONF
[Interface]
PrivateKey = ${RU_PRIV}
Address = ${RU_TUN_ADDR}
Table = off
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
Endpoint = ${EU_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_CONF
chmod 600 /etc/amnezia/amneziawg/awg1.conf

systemctl daemon-reload
systemctl enable --now awg-quick@awg1
systemctl restart awg-quick@awg1
sleep 2

if ! systemctl is-active --quiet awg-quick@awg1; then
  echo "Ошибка: awg-quick@awg1 (хоп на EU) не запустился. Логи:"
  journalctl --no-pager -e -u awg-quick@awg1
  exit 1
fi

echo "Проверяю handshake с EU-сервером..."
HANDSHAKE_OK=0
for _ in {1..10}; do
  if awg show awg1 latest-handshakes 2>/dev/null | awk '{print $2}' | grep -qE '^[1-9][0-9]*$'; then
    HANDSHAKE_OK=1
    break
  fi
  sleep 1
done
if [[ "$HANDSHAKE_OK" -ne 1 ]]; then
  echo "ВНИМАНИЕ: за 10 секунд не увидел handshake на awg1. Проверь, что порт EU открыт и Endpoint указан верно."
  echo "Скрипт продолжит настройку, но туннель может не работать."
fi

# --- awg0: собственный сервер RU для конечных клиентов ---
RU_PORT=$(random_port)
THIRD2=$(shuf -i 10-250 -n 1)
CLIENT_SUBNET="10.66.${THIRD2}"

RU0_PRIV=$(awg genkey)
RU0_PUB=$(echo "$RU0_PRIV" | awg pubkey)

CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)

eval "$(gen_awg_params)"

open_udp_port "$RU_PORT"

cat > /etc/amnezia/amneziawg/awg0.conf <<EOF_CONF
[Interface]
PrivateKey = ${RU0_PRIV}
Address = ${CLIENT_SUBNET}.1/24
ListenPort = ${RU_PORT}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; bash /root/awg/awg-routing.sh
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_SUBNET}.2/32
EOF_CONF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# --- split-routing: RU-адреса напрямую через WAN, всё остальное через awg1 ---
mkdir -p /root/awg

cat > /root/awg/awg-routing.sh <<EOF_ROUTING
#!/usr/bin/env bash
# Идемпотентный split-routing для клиентов awg0 (сервер-вход).
# RU-подсети идут напрямую через WAN, остальной трафик — через awg1 (хоп на EU).
set -Eeuo pipefail

CLIENT_SUBNET="${CLIENT_SUBNET}.0/24"
WAN_IF="${WAN_IF}"
AWG1_IF="awg1"
TABLE_ID="100"
FWMARK="0x100"
RU_LIST_URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"

need_cmd() { command -v "\$1" >/dev/null 2>&1; }

if ! need_cmd ipset; then
  apt-get install -y ipset >/dev/null 2>&1 || true
fi

if ! ipset list ru >/dev/null 2>&1; then
  ipset create ru hash:net
fi

TMP_LIST=\$(mktemp)
if curl -4fsSL --max-time 20 "\$RU_LIST_URL" -o "\$TMP_LIST" 2>/dev/null && [[ -s "\$TMP_LIST" ]]; then
  ipset flush ru
  while read -r cidr; do
    [[ -n "\$cidr" ]] && ipset add ru "\$cidr" 2>/dev/null || true
  done < "\$TMP_LIST"
  echo "OK: список RU-сетей обновлён (\$(wc -l < "\$TMP_LIST") записей)"
else
  echo "ВНИМАНИЕ: не удалось скачать список RU-сетей (\$RU_LIST_URL), использую то, что уже есть в ipset"
fi
rm -f "\$TMP_LIST"

ip rule show | grep -q "fwmark \$FWMARK lookup \$TABLE_ID" \\
  || ip rule add fwmark "\$FWMARK" table "\$TABLE_ID"

ip route replace default dev "\$AWG1_IF" table "\$TABLE_ID"

iptables -t mangle -C PREROUTING -i awg0 -s "\$CLIENT_SUBNET" -m set --match-set ru dst -j RETURN 2>/dev/null \\
  || iptables -t mangle -I PREROUTING 1 -i awg0 -s "\$CLIENT_SUBNET" -m set --match-set ru dst -j RETURN
iptables -t mangle -C PREROUTING -i awg0 -s "\$CLIENT_SUBNET" -j MARK --set-mark "\$FWMARK" 2>/dev/null \\
  || iptables -t mangle -A PREROUTING -i awg0 -s "\$CLIENT_SUBNET" -j MARK --set-mark "\$FWMARK"

iptables -t nat -C POSTROUTING -s "\$CLIENT_SUBNET" -o "\$WAN_IF" -j MASQUERADE 2>/dev/null \\
  || iptables -t nat -A POSTROUTING -s "\$CLIENT_SUBNET" -o "\$WAN_IF" -j MASQUERADE
iptables -t nat -C POSTROUTING -s "\$CLIENT_SUBNET" -o "\$AWG1_IF" -j MASQUERADE 2>/dev/null \\
  || iptables -t nat -A POSTROUTING -s "\$CLIENT_SUBNET" -o "\$AWG1_IF" -j MASQUERADE

echo "OK: каскадный split-routing применён (WAN=\$WAN_IF, выход=\$AWG1_IF, table=\$TABLE_ID)"
EOF_ROUTING
chmod +x /root/awg/awg-routing.sh

systemctl enable --now awg-quick@awg0
systemctl restart awg-quick@awg0
sleep 2

if ! systemctl is-active --quiet awg-quick@awg0; then
  echo "Ошибка: awg-quick@awg0 (собственный сервер RU) не запустился. Логи:"
  journalctl --no-pager -e -u awg-quick@awg0
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
ufw allow "$RU_PORT"/udp
ufw --force enable

RU_ENDPOINT_HOST="$PUBLIC_IP"

CLIENT_CONF=$(cat <<EOF_CLIENT
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_SUBNET}.2/32
DNS = 1.1.1.1
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
PublicKey = ${RU0_PUB}
Endpoint = ${RU_ENDPOINT_HOST}:${RU_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_CLIENT
)

echo
echo "=== Готово: каскад RU -> EU настроен ==="
echo "Новый SSH порт: $NEW_SSH_PORT"
echo
echo "$CLIENT_CONF"
