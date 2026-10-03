#!/usr/bin/env bash
# Raspberry Pi OS Bookworm or newer, using NetworkManager.
# sudo bash setup-pi5.sh [--ssid NAME] [--password PASSWORD] [--interface wlan0]
set -Eeuo pipefail
trap 'echo "Setup failed at line $LINENO. Inspect the error above and journalctl -b -u ps5-hotspot.service." >&2' ERR

SSID=PS5-Host
PASSWORD=ps5offline
WIFI_IF=wlan0
PROFILE=ps5-offline-hotspot
HOST_IP=192.168.4.1
SOURCE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEST=/home/ps5
usage() {
    echo "Usage: sudo bash setup-pi5.sh [--ssid NAME] [--password PASSWORD] [--interface wlan0]"
    echo "Installs, enables boot startup and starts the host immediately. Use Ethernet SSH or a local console."
}
while (($#)); do
    case "$1" in
        --ssid|--password|--interface)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            case "$1" in
                --ssid) SSID=$2 ;;
                --password) PASSWORD=$2 ;;
                --interface) WIFI_IF=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ ${#SSID} -ge 1 && $(printf '%s' "$SSID" | wc -c) -le 32 ]] || { echo "SSID must be 1–32 bytes." >&2; exit 1; }
[[ ${#PASSWORD} -ge 8 && ${#PASSWORD} -le 63 && $PASSWORD != *$'\n'* ]] || { echo "Password must be 8–63 characters, without a newline." >&2; exit 1; }
[[ $WIFI_IF =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid interface name." >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "A booted Raspberry Pi OS system is required." >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Raspberry Pi OS (Debian based) is required." >&2; exit 1; }
command -v nmcli >/dev/null || { echo "Use Raspberry Pi OS Bookworm or newer with NetworkManager." >&2; exit 1; }
systemctl is-active --quiet NetworkManager || { echo "NetworkManager must already be active." >&2; exit 1; }
[[ -d /sys/class/net/$WIFI_IF/wireless ]] || { echo "Wi-Fi interface $WIFI_IF not found." >&2; exit 1; }
[[ $(LC_ALL=C nmcli -g WIFI-PROPERTIES.AP device show "$WIFI_IF") == yes ]] || { echo "This adapter does not report access-point support." >&2; exit 1; }
MANAGED_STATE=$(LC_ALL=C nmcli -g GENERAL.STATE device show "$WIFI_IF")
[[ ${MANAGED_STATE%% *} != 10 ]] || { echo "NetworkManager is not managing $WIFI_IF." >&2; exit 1; }
if systemctl is-active --quiet ps5-host.target; then
    echo "Stop the existing Pi host first: sudo systemctl stop ps5-host.target" >&2
    exit 1
fi
for item in index.html serve.py serve_https.py src offsets payloads; do
    [[ -e "$SOURCE/$item" ]] || { echo "Missing project item: $item" >&2; exit 1; }
done
for port in 80 443; do
    unit=ps5-http.service
    [[ $port == 443 ]] && unit=ps5-https.service
    if ss -H -lnt "sport = :$port" | grep -q . && ! systemctl is-active --quiet "$unit"; then
        echo "Port $port is already used by another server. Resolve that conflict first." >&2
        ss -lntp "sport = :$port"
        exit 1
    fi
done
# Refuse an existing wildcard/AP DNS or DHCP listener; don't stop unrelated DNS.
for port in 53 67; do
    if ss -H -lnu "sport = :$port" | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\*|\[::\]|192\.168\.4\.1):$port$"; then
        echo "UDP $port is already bound globally or on $HOST_IP. Stop the conflicting DNS/DHCP server first." >&2
        ss -lnup "sport = :$port"
        exit 1
    fi
done
if ip -4 -o addr show | grep -q '192\.168\.4\.'; then
    if ! ip -4 -o addr show dev "$WIFI_IF" | grep -q '192\.168\.4\.1/24'; then
        echo "192.168.4.0/24 is already used on this Pi; resolve that subnet conflict first." >&2
        exit 1
    fi
fi

# Install everything before changing Wi-Fi; Wi-Fi Internet can be used here.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dnsmasq-base dnsutils python3 openssl rsync curl rfkill
STAMP=$(date +%Y%m%d-%H%M%S)-$$
BACKUP=/var/backups/ps5-pi/$STAMP
install -d -m 700 "$BACKUP"
backup_file() { if [[ -f $1 ]]; then cp --parents -- "$1" "$BACKUP/"; fi; }
install -d -m 755 "$DEST"
if [[ $(readlink -f "$SOURCE") != $(readlink -f "$DEST") ]]; then
    rsync -a --backup --backup-dir="$BACKUP/site" \
        "$SOURCE/index.html" "$SOURCE/serve.py" "$SOURCE/serve_https.py" \
        "$SOURCE/src" "$SOURCE/offsets" "$SOURCE/payloads" "$DEST/"
fi
chmod a+rx /home "$DEST"
chmod a+r "$DEST/index.html" "$DEST/serve.py" "$DEST/serve_https.py"
chmod -R a+rX "$DEST/src" "$DEST/offsets" "$DEST/payloads"
install -d -m 750 -o root -g www-data /etc/ps5-host
if [[ ! -s /etc/ps5-host/cert.pem || ! -s /etc/ps5-host/key.pem ]] || \
    ! openssl x509 -checkend 604800 -noout -in /etc/ps5-host/cert.pem >/dev/null 2>&1; then
    backup_file /etc/ps5-host/cert.pem
    backup_file /etc/ps5-host/key.pem
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/ps5-host/key.pem -out /etc/ps5-host/cert.pem \
        -subj '/CN=manuals.playstation.net' \
        -addext 'subjectAltName=DNS:manuals.playstation.net,IP:192.168.4.1'
fi
chown root:www-data /etc/ps5-host/{cert,key}.pem
chmod 640 /etc/ps5-host/{cert,key}.pem

# A dedicated config/service avoids changing the Pi's existing resolver.
install -d -m 755 -o nobody -g nogroup /var/lib/ps5-dns
backup_file /etc/ps5-host/dnsmasq.conf
cat > /etc/ps5-host/dnsmasq.conf <<EOF
interface=$WIFI_IF
except-interface=lo
bind-dynamic
no-resolv
no-hosts
domain-needed
local=/manuals.playstation.net/
address=/manuals.playstation.net/$HOST_IP
local=/ps5.host/
address=/ps5.host/$HOST_IP
dhcp-range=192.168.4.100,192.168.4.150,255.255.255.0,12h
dhcp-option=option:router,$HOST_IP
dhcp-option=option:dns-server,$HOST_IP
dhcp-authoritative
dhcp-leasefile=/var/lib/ps5-dns/leases
user=nobody
group=nogroup
log-dhcp
log-facility=-
EOF
dnsmasq --test --conf-file=/etc/ps5-host/dnsmasq.conf

# Keep the profile inactive until the target is started (or next boot).
# Store the profile UUID, not an ambiguous display name, in the service.
PROFILE_FILE=/etc/ps5-host/hotspot-uuid
if [[ -s $PROFILE_FILE ]]; then
    UUID=$(cat "$PROFILE_FILE")
    [[ $UUID =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "Invalid saved hotspot UUID." >&2; exit 1; }
    nmcli connection show uuid "$UUID" >/dev/null
else
    if nmcli -g NAME connection show | grep -Fxq "$PROFILE"; then
        echo "An unmanaged profile named $PROFILE already exists. Rename it before setup." >&2
        exit 1
    fi
    nmcli connection add type wifi ifname "$WIFI_IF" con-name "$PROFILE" ssid "$SSID" \
        connection.autoconnect no 802-11-wireless.mode ap ipv4.method manual \
        ipv4.addresses "$HOST_IP/24" ipv4.never-default yes ipv6.method disabled
    UUID=$(nmcli -g connection.uuid connection show "$PROFILE")
    printf '%s\n' "$UUID" > "$PROFILE_FILE"
fi
nmcli connection modify uuid "$UUID" connection.interface-name "$WIFI_IF" \
    connection.autoconnect no 802-11-wireless.ssid "$SSID" 802-11-wireless.mode ap \
    802-11-wireless.band bg 802-11-wireless.channel 6 802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD" wifi-sec.proto rsn \
    ipv4.method manual ipv4.addresses "$HOST_IP/24" ipv4.gateway "" \
    ipv4.dns "" ipv4.never-default yes ipv6.method disabled

for unit in ps5-hotspot.service ps5-dns.service ps5-http.service ps5-https.service ps5-host.target; do
    backup_file "/etc/systemd/system/$unit"
done
backup_file /usr/local/sbin/ps5-start-hotspot
cat > /usr/local/sbin/ps5-start-hotspot <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
interface=$1
uuid=$2
rfkill unblock wifi
nmcli radio wifi on
# NetworkManager can be running before the Wi-Fi device is ready at boot.
# Retry activation, not just device discovery, to cover firmware initialization.
for _attempt in {1..12}; do
    if [[ -d /sys/class/net/$interface/wireless ]]; then
        if nmcli --wait 10 connection up uuid "$uuid"; then
            exit 0
        fi
    fi
    sleep 3
done
echo "Failed to activate hotspot on $interface; inspect NetworkManager logs." >&2
exit 1
EOF
chmod 755 /usr/local/sbin/ps5-start-hotspot
cat > /etc/systemd/system/ps5-hotspot.service <<EOF
[Unit]
Description=PS5 Wi-Fi access point
Requires=NetworkManager.service
After=NetworkManager.service
PartOf=ps5-host.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ps5-start-hotspot $WIFI_IF $UUID
ExecStop=/usr/bin/nmcli --wait 15 connection down uuid $UUID
TimeoutStartSec=180
EOF
cat > /etc/systemd/system/ps5-dns.service <<'EOF'
[Unit]
Description=PS5 hotspot DNS and DHCP
Requires=ps5-hotspot.service
After=ps5-hotspot.service
PartOf=ps5-host.target

[Service]
Type=simple
ExecStartPre=/usr/sbin/dnsmasq --test --conf-file=/etc/ps5-host/dnsmasq.conf
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/ps5-host/dnsmasq.conf --pid-file=
Restart=on-failure
RestartSec=3
EOF
for kind in http https; do
    script=serve.py
    [[ $kind == https ]] && script=serve_https.py
    cat > "/etc/systemd/system/ps5-$kind.service" <<EOF
[Unit]
Description=PS5 local $kind host
After=ps5-hotspot.service
PartOf=ps5-host.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/home/ps5
Environment=PS5_HTTP_PORT=80
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 -u /home/ps5/$script
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
EOF
done
cat > /etc/systemd/system/ps5-host.target <<'EOF'
[Unit]
Description=PS5 offline Wi-Fi, DHCP, DNS and web host
Requires=ps5-hotspot.service ps5-dns.service ps5-http.service ps5-https.service
After=ps5-hotspot.service ps5-dns.service ps5-http.service ps5-https.service

[Install]
WantedBy=multi-user.target
EOF
python3 -m py_compile "$DEST/serve.py" "$DEST/serve_https.py"
systemctl daemon-reload
# The target owns boot activation; remove old standalone web enablement.
systemctl disable ps5-http.service ps5-https.service >/dev/null 2>&1 || true
systemctl enable ps5-host.target

echo "Starting PS5 host now; $WIFI_IF will become the hotspot."
# Queue through systemd so activation survives a Wi-Fi SSH disconnection.
systemctl start --no-block ps5-host.target
for _attempt in {1..100}; do
    all_active=yes
    for unit in ps5-host.target ps5-hotspot.service ps5-dns.service ps5-http.service ps5-https.service; do
        systemctl is-active --quiet "$unit" || all_active=no
    done
    [[ $all_active == yes ]] && break
    sleep 2
done
for unit in ps5-host.target ps5-hotspot.service ps5-dns.service ps5-http.service ps5-https.service; do
    if ! systemctl is-active --quiet "$unit"; then
        echo "$unit did not start. Boot startup is enabled, but setup needs attention." >&2
        journalctl -b -u ps5-hotspot.service -u ps5-dns.service -u ps5-http.service -u ps5-https.service --no-pager -n 60
        exit 1
    fi
done

echo
echo "Installed. Backups: $BACKUP"
echo "All PS5 host services are running and enabled for every boot."
echo "PS5 Wi-Fi: $SSID; use the configured password (default: ps5offline)."
echo "PS5 IP and DNS: Automatic. Host: $HOST_IP. Open User's Guide."
echo "Allow UDP 67, TCP/UDP 53, TCP 80/443 on $WIFI_IF if you use a firewall."
echo "Check: systemctl status ps5-host.target ps5-hotspot ps5-dns ps5-http ps5-https"
