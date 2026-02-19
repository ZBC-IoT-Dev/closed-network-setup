#!/bin/bash

# Closed Network Gateway Setup for Raspberry Pi (Dual Mode)
# Keeps Wi-Fi client uplink (STA) while exposing AP on a virtual interface.
# Run as: sudo bash setup_ap.sh

# CREDIT: BUSTER OG PATRICK

set -euo pipefail

echo "=== Closed Network Gateway Setup (Dual AP+STA) ==="

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo bash setup_ap.sh"
    exit 1
fi

AP_SSID="IoTGateway"
AP_PASSWORD="12345678"
AP_IP="10.42.0.1"
DHCP_RANGE="10.42.0.10,10.42.0.100,255.255.255.0,12h"
AP_IFACE="ap0"

detect_wifi_iface() {
    if ip link show wlan0 >/dev/null 2>&1; then
        echo "wlan0"
        return
    fi
    iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}'
}

remove_dhcpcd_deny_iface() {
    local iface="$1"
    local conf="/etc/dhcpcd.conf"
    [ -f "$conf" ] || return 0
    sed -i "/^[[:space:]]*denyinterfaces[[:space:]]\+${iface}\([[:space:]].*\)\?$/d" "$conf"
}

ensure_dhcpcd_ignores_iface() {
    local iface="$1"
    local conf="/etc/dhcpcd.conf"
    touch "$conf"
    if ! grep -Eq "^[[:space:]]*denyinterfaces[[:space:]]+${iface}([[:space:]]|\$)" "$conf"; then
        {
            echo ""
            echo "# Managed by closedmqtt AP setup"
            echo "denyinterfaces ${iface}"
        } >> "$conf"
    fi
}

restart_dhcp_manager_if_present() {
    if systemctl list-unit-files | grep -q '^dhcpcd\.service'; then
        systemctl restart dhcpcd || true
    elif systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        systemctl restart NetworkManager || true
    fi
}

freq_to_channel() {
    local freq="$1"
    if ! [[ "$freq" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi
    if [ "$freq" = "2484" ]; then
        echo "14"
    elif [ "$freq" -ge 2412 ] && [ "$freq" -le 2472 ]; then
        echo $(( (freq - 2407) / 5 ))
    elif [ "$freq" -ge 5180 ] && [ "$freq" -le 5885 ]; then
        echo $(( (freq - 5000) / 5 ))
    else
        echo ""
    fi
}

get_sta_channel() {
    local iface="$1"
    local freq
    freq="$(iw dev "$iface" link 2>/dev/null | awk '/freq:/ {print $2; exit}')"
    if [ -z "${freq:-}" ]; then
        echo ""
        return
    fi
    freq_to_channel "$freq"
}

echo "[1/7] Updating package list..."
apt update

echo "[2/7] Installing required packages..."
apt install -y hostapd dnsmasq mosquitto mosquitto-clients iw rfkill iptables

STA_IFACE="$(detect_wifi_iface || true)"
if [ -z "${STA_IFACE}" ]; then
    echo "No Wi-Fi interface found. Check adapter support."
    exit 1
fi
echo "Using STA interface: ${STA_IFACE}"

rfkill unblock wifi || true

if ! iw list 2>/dev/null | grep -A20 "valid interface combinations" | grep -Eq "(AP.*managed|managed.*AP)"; then
    echo "WARNING: Driver may not support simultaneous AP+STA."
    echo "If AP stays down, use a second Wi-Fi adapter (recommended)."
fi

AP_CHANNEL="$(get_sta_channel "${STA_IFACE}")"
if [ -z "${AP_CHANNEL}" ]; then
    AP_CHANNEL="1"
    echo "STA not connected yet. Defaulting AP channel to ${AP_CHANNEL}."
    echo "For best stability, connect ${STA_IFACE} to DEV first, then rerun."
else
    echo "Using AP channel ${AP_CHANNEL} (matched to STA uplink)."
fi

echo "[3/7] Configuring hostapd on ${AP_IFACE}..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=${AP_IFACE}
driver=nl80211
ssid=${AP_SSID}
country_code=US
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=0
ap_isolate=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

echo "[4/7] Configuring dnsmasq on ${AP_IFACE}..."
cat > /etc/dnsmasq.conf << EOF
interface=${AP_IFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE}
domain=local
address=/gateway.local/${AP_IP}
EOF

echo "[5/7] Configuring AP interface services..."
for old_svc in regenerate_ap_network.service ap_network.service; do
    systemctl disable --now "$old_svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${old_svc}"
done

mkdir -p /usr/local/sbin
cat > /usr/local/sbin/closedmqtt-ap-ensure.sh << EOF
#!/bin/sh
set -eu
STA_IFACE="${STA_IFACE}"
AP_IFACE="${AP_IFACE}"
AP_IP="${AP_IP}"

tries=0
while [ "\$tries" -lt 20 ]; do
    if iw dev "\$AP_IFACE" info >/dev/null 2>&1; then
        break
    fi
    iw dev "\$STA_IFACE" interface add "\$AP_IFACE" type __ap 2>/dev/null || true
    tries=\$((tries + 1))
    sleep 0.5
done

if ! iw dev "\$AP_IFACE" info >/dev/null 2>&1; then
    echo "Failed to create \$AP_IFACE from \$STA_IFACE" >&2
    exit 1
fi

ip link set "\$AP_IFACE" up
ip addr flush dev "\$AP_IFACE"
ip addr add "\$AP_IP"/24 dev "\$AP_IFACE"
EOF
chmod +x /usr/local/sbin/closedmqtt-ap-ensure.sh

cat > /etc/systemd/system/closedmqtt-ap-iface.service << EOF
[Unit]
Description=Create virtual AP interface ${AP_IFACE}
After=network-pre.target wpa_supplicant.service NetworkManager.service
Before=hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/closedmqtt-ap-ensure.sh
ExecStop=/bin/sh -c '/sbin/ip link set ${AP_IFACE} down 2>/dev/null || true'
ExecStop=/bin/sh -c '/sbin/iw dev ${AP_IFACE} del 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/closedmqtt-ap-ip.service << EOF
[Unit]
Description=Assign static IP to ${AP_IFACE}
After=closedmqtt-ap-iface.service
Requires=closedmqtt-ap-iface.service
Before=dnsmasq.service hostapd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip addr flush dev ${AP_IFACE}
ExecStart=/sbin/ip addr add ${AP_IP}/24 dev ${AP_IFACE}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/closedmqtt-ap-firewall.service << EOF
[Unit]
Description=Isolate AP clients from uplink network and internet
After=closedmqtt-ap-ip.service
Requires=closedmqtt-ap-ip.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w net.ipv4.ip_forward=1
ExecStart=/bin/sh -c '/usr/sbin/iptables -t nat -D POSTROUTING -o ${STA_IFACE} -j MASQUERADE 2>/dev/null || true'
ExecStart=/bin/sh -c '/usr/sbin/iptables -D FORWARD -i ${STA_IFACE} -o ${AP_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true'
ExecStart=/bin/sh -c '/usr/sbin/iptables -D FORWARD -i ${AP_IFACE} -o ${STA_IFACE} -j ACCEPT 2>/dev/null || true'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i ${AP_IFACE} -o ${STA_IFACE} -j DROP || /usr/sbin/iptables -I FORWARD 1 -i ${AP_IFACE} -o ${STA_IFACE} -j DROP'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i ${STA_IFACE} -o ${AP_IFACE} -j DROP || /usr/sbin/iptables -I FORWARD 1 -i ${STA_IFACE} -o ${AP_IFACE} -j DROP'

[Install]
WantedBy=multi-user.target
EOF

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-closedmqtt-ap-forward.conf
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-closedmqtt-unmanaged-ap0.conf << EOF
[keyfile]
unmanaged-devices=interface-name:${AP_IFACE}
EOF

mkdir -p /etc/systemd/system/hostapd.service.d
cat > /etc/systemd/system/hostapd.service.d/closedmqtt-deps.conf << EOF
[Unit]
Requires=closedmqtt-ap-ip.service
After=closedmqtt-ap-ip.service
EOF

mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/closedmqtt-deps.conf << EOF
[Unit]
Requires=closedmqtt-ap-ip.service
After=closedmqtt-ap-ip.service
EOF

echo "[6/7] Resolving network-manager conflicts..."
remove_dhcpcd_deny_iface "${STA_IFACE}"
ensure_dhcpcd_ignores_iface "${AP_IFACE}"
restart_dhcp_manager_if_present

# Keep STA client stack enabled for uplink.
systemctl enable wpa_supplicant >/dev/null 2>&1 || true
systemctl restart wpa_supplicant >/dev/null 2>&1 || true

echo "[7/7] Enabling and starting services..."
systemctl daemon-reload
systemctl unmask hostapd
systemctl enable closedmqtt-ap-iface.service
systemctl enable closedmqtt-ap-ip.service
systemctl disable --now closedmqtt-ap-nat.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/closedmqtt-ap-nat.service
systemctl enable closedmqtt-ap-firewall.service
systemctl enable dnsmasq
systemctl enable hostapd
systemctl enable mosquitto

systemctl restart closedmqtt-ap-iface.service
systemctl restart closedmqtt-ap-ip.service
systemctl restart dnsmasq
systemctl restart hostapd
systemctl restart closedmqtt-ap-firewall.service
systemctl restart mosquitto

echo ""
echo "=== Setup Complete ==="
echo "STA (uplink): ${STA_IFACE}"
echo "AP interface: ${AP_IFACE}"
echo "AP SSID: ${AP_SSID}"
echo "AP Password: ${AP_PASSWORD}"
echo "AP Gateway IP: ${AP_IP}"
echo "MQTT Broker: ${AP_IP}:1883"
echo ""
echo "Validation:"
echo "  iw dev"
echo "  ip a show ${STA_IFACE}"
echo "  ip a show ${AP_IFACE}"
echo "  systemctl status closedmqtt-ap-iface.service --no-pager"
echo "  systemctl status closedmqtt-ap-ip.service --no-pager"
echo "  systemctl status closedmqtt-ap-firewall.service --no-pager"
echo "  systemctl status hostapd --no-pager"
