#!/bin/bash
# smart-dns-ir: Full Installer
# Sets up dnsmasq as a local caching DNS resolver, optimized for Iranian networks.
# Handles systemd-resolved conflicts, IPv6, Docker integration, health checks.
# Usage: sudo bash install.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}[$1/7]${NC} $2"; }
ok()   { echo -e "  ${GREEN}OK${NC} $1"; }
warn() { echo -e "  ${YELLOW}!!${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; exit 1; }

if [[ "${EUID:-}" -ne 0 ]]; then
    fail "Run as root: sudo bash install.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_dnsmasq_service() {
    if systemctl cat dnsmasq.service &>/dev/null; then
        return 0
    fi
    cat <<'UNIT' > /etc/systemd/system/dnsmasq.service
[Unit]
Description=dnsmasq - A lightweight DHCP and caching DNS server
After=network.target

[Service]
Type=forking
ExecStartPre=/usr/sbin/dnsmasq --test
ExecStart=/usr/sbin/dnsmasq -x /run/dnsmasq.pid
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/run/dnsmasq.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    ok "created missing dnsmasq.service unit"
}

# ─────────────────────────────────────────────────────────────
step 1 "Installing packages (dnsmasq, dnsutils)"
# ─────────────────────────────────────────────────────────────
if command -v dnsmasq &>/dev/null && command -v dig &>/dev/null; then
    ok "dnsmasq and dnsutils already installed"
else
    apt-get update -qq
    apt-get install -y -qq dnsmasq dnsutils
    ok "installed"
fi

# ─────────────────────────────────────────────────────────────
step 2 "Disabling IPv6 (reduces DNS noise on Iranian networks)"
# ─────────────────────────────────────────────────────────────
cat <<'EOF' > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf &>/dev/null
ok "IPv6 disabled"

# ─────────────────────────────────────────────────────────────
step 3 "Clearing port 53 conflicts"
# ─────────────────────────────────────────────────────────────

# Stop unbound if running (common conflict)
if systemctl is-active --quiet unbound 2>/dev/null; then
    systemctl stop unbound
    systemctl disable unbound
    ok "stopped unbound (was occupying port 53)"
fi

# Fix Ubuntu's ubuntu-fan drop-in which sets bind-interfaces,
# conflicting with the bind-dynamic we need for Docker bridge support.
FAN_CONF=/etc/dnsmasq.d/ubuntu-fan
if [[ -f "$FAN_CONF" ]] && grep -q 'bind-interfaces' "$FAN_CONF"; then
    sed -i '/^bind-interfaces/d' "$FAN_CONF"
    ok "removed bind-interfaces from ubuntu-fan drop-in (conflicts with bind-dynamic)"
fi

# Configure systemd-resolved to not use its stub listener
mkdir -p /etc/systemd/resolved.conf.d
cat <<'EOF' > /etc/systemd/resolved.conf.d/no-stub.conf
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF

# Prevent dnsmasq from reading a looping resolv.conf
sed -i 's/^#IGNORE_RESOLVCONF=yes/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq 2>/dev/null \
    || echo 'IGNORE_RESOLVCONF=yes' >> /etc/default/dnsmasq
grep -q '^DNSMASQ_EXCEPT="lo"' /etc/default/dnsmasq 2>/dev/null \
    || echo 'DNSMASQ_EXCEPT="lo"' >> /etc/default/dnsmasq

systemctl restart systemd-resolved 2>/dev/null || true

# Point system DNS at our local dnsmasq
rm -f /etc/resolv.conf
cat <<'EOF' > /etc/resolv.conf
nameserver 127.0.0.1
options edns0 trust-ad
EOF
ok "systemd-resolved reconfigured, resolv.conf updated"

# ─────────────────────────────────────────────────────────────
step 4 "Installing scripts"
# ─────────────────────────────────────────────────────────────

# Clean up legacy scripts from setup_ubuntu_dns.sh if present
LEGACY_CLEANED=false
for old_script in /usr/local/bin/dns_auto_update.sh /usr/local/bin/dns_test2; do
    if [[ -f "$old_script" ]]; then
        rm -f "$old_script"
        LEGACY_CLEANED=true
    fi
done
# Clean up legacy cron entries
if crontab -l 2>/dev/null | grep -q "dns_auto_update"; then
    crontab -l 2>/dev/null | grep -v "dns_auto_update" | crontab -
    LEGACY_CLEANED=true
fi
$LEGACY_CLEANED && ok "cleaned up legacy scripts from setup_ubuntu_dns.sh"

install -m 0755 "$SCRIPT_DIR/dns-updater.sh"      /usr/local/bin/smart-dns-ir-update
install -m 0755 "$SCRIPT_DIR/dns-health-check.sh"  /usr/local/bin/smart-dns-ir-health-check
install -m 0755 "$SCRIPT_DIR/benchmark.sh"         /usr/local/bin/smart-dns-ir-benchmark
install -m 0755 "$SCRIPT_DIR/dns-doctor.sh"        /usr/local/bin/smart-dns-ir-doctor
ok "scripts installed to /usr/local/bin/"

# ─────────────────────────────────────────────────────────────
step 5 "Running initial benchmark + configuring dnsmasq"
# ─────────────────────────────────────────────────────────────
echo "  Benchmarking 60+ DNS servers in parallel (10-15 seconds)..."
/usr/local/bin/smart-dns-ir-update

ensure_dnsmasq_service
systemctl enable dnsmasq
ok "dnsmasq enabled and configured"

# ─────────────────────────────────────────────────────────────
step 6 "Docker integration (if Docker is installed)"
# ─────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    # Detect all Docker bridge IPs
    BRIDGE_IPS=$(ip -4 addr show 2>/dev/null \
        | grep -oP 'inet \K[\d.]+(?=/.*(docker|br-))' || true)

    if [[ -n "$BRIDGE_IPS" ]]; then
        DNS_JSON=$(echo "$BRIDGE_IPS" | head -2 | awk '{printf "\"%s\", ", $1}' | sed 's/, $//')
        DAEMON_JSON=/etc/docker/daemon.json
        if [[ -f "$DAEMON_JSON" ]]; then
            cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
            # Merge DNS into existing config, preserving all other settings
            if command -v python3 &>/dev/null; then
                python3 -c "
import json, sys
with open('$DAEMON_JSON') as f:
    conf = json.load(f)
conf['dns'] = [$(echo "$BRIDGE_IPS" | head -2 | awk '{printf "\"%s\", ", $1}' | sed 's/, $//')]
with open('$DAEMON_JSON', 'w') as f:
    json.dump(conf, f, indent=2)
    f.write('\n')
"
            else
                echo "{\"dns\": [$DNS_JSON]}" > "$DAEMON_JSON"
            fi
        else
            echo "{\"dns\": [$DNS_JSON]}" > "$DAEMON_JSON"
        fi
        ok "Docker daemon.json updated with DNS: [$DNS_JSON]"

        # Open UFW for Docker subnets if UFW is active
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            for bridge_ip in $BRIDGE_IPS; do
                subnet="${bridge_ip%.*}.0/16"
                for proto in udp tcp; do
                    if ! ufw status | grep -q "53.*$proto.*${bridge_ip%.*}"; then
                        ufw allow from "$subnet" to any port 53 proto $proto >/dev/null 2>&1
                    fi
                done
            done
            ok "UFW rules added for Docker DNS traffic"
        fi

        warn "Restart Docker to apply: systemctl restart docker"
    else
        ok "Docker found but no bridge networks detected yet (will be configured on next smart-dns-ir-update run)"
    fi

    # Check for containers with dns: directives that bypass dnsmasq
    if docker ps --format '{{.ID}}' 2>/dev/null | grep -q .; then
        echo ""
        echo "  Checking containers for DNS bypass..."
        if ! /usr/local/bin/smart-dns-ir-doctor 2>/dev/null; then
            warn "Some containers bypass dnsmasq. Run: smart-dns-ir-doctor --fix"
        fi
    fi
else
    ok "Docker not installed, skipping"
fi

# ─────────────────────────────────────────────────────────────
step 7 "Setting up automated maintenance"
# ─────────────────────────────────────────────────────────────

# dnsmasq auto-restart on crash
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat <<'EOF' > /etc/systemd/system/dnsmasq.service.d/restart.conf
[Service]
Restart=on-failure
RestartSec=5
EOF

# Health check systemd timer (every 5 min)
cat <<'EOF' > /etc/systemd/system/smart-dns-ir-health-check.service
[Unit]
Description=smart-dns-ir health check
After=network.target dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smart-dns-ir-health-check
EOF

cat <<'EOF' > /etc/systemd/system/smart-dns-ir-health-check.timer
[Unit]
Description=Run smart-dns-ir health check every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=30

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now smart-dns-ir-health-check.timer

# Daily cron for DNS re-benchmark
(crontab -l 2>/dev/null | grep -v "smart-dns-ir-update"; \
 echo "0 3 * * * /usr/local/bin/smart-dns-ir-update > /var/log/smart-dns-ir-update.log 2>&1") | crontab -

ok "health check timer (5 min), daily re-benchmark (03:00), dnsmasq auto-restart"

# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "  What's running now:"
echo "    dnsmasq          — local caching DNS on 127.0.0.1 (+ Docker bridges)"
echo "    smart-dns-ir-update  — daily re-benchmark of upstream servers (03:00)"
echo "    smart-dns-ir-health-check — health monitor every 5 min"
echo ""
echo "  Useful commands:"
echo "    smart-dns-ir-benchmark         — run a standalone DNS benchmark"
echo "    smart-dns-ir-update            — re-benchmark and update dnsmasq now"
echo "    smart-dns-ir-health-check      — run health check manually"
echo "    smart-dns-ir-doctor            — check containers for DNS bypass"
echo "    smart-dns-ir-doctor --fix      — fix containers + recreate them"
echo "    journalctl -u dnsmasq      — dnsmasq logs"
echo "    cat /var/log/smart-dns-ir-health.log  — health check log"
echo ""
echo "  To add anti-censorship overrides for specific domains, edit:"
echo "    /etc/dnsmasq.conf  (inside the MANUAL-BEGIN block)"
echo ""
echo "  Example override (route a censored domain through an uncensored resolver):"
echo "    server=/example.com/194.225.152.10"
echo ""
