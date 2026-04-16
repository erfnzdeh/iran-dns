#!/bin/bash
# smart-dns-ir: Uninstaller
# Removes smart-dns-ir scripts, systemd units, and cron jobs.
# Does NOT remove dnsmasq itself (you may be using it for other things).
# Usage: sudo bash uninstall.sh

set -euo pipefail

if [[ "${EUID:-}" -ne 0 ]]; then
    echo "Run as root: sudo bash uninstall.sh"
    exit 1
fi

echo "Removing smart-dns-ir..."

# Stop and disable timer
systemctl stop smart-dns-ir-health-check.timer 2>/dev/null || true
systemctl disable smart-dns-ir-health-check.timer 2>/dev/null || true

# Remove systemd units
rm -f /etc/systemd/system/smart-dns-ir-health-check.service
rm -f /etc/systemd/system/smart-dns-ir-health-check.timer
rm -f /etc/systemd/system/dnsmasq.service.d/restart.conf
rmdir /etc/systemd/system/dnsmasq.service.d 2>/dev/null || true
systemctl daemon-reload

# Remove scripts
rm -f /usr/local/bin/smart-dns-ir-update
rm -f /usr/local/bin/smart-dns-ir-health-check
rm -f /usr/local/bin/smart-dns-ir-benchmark
rm -f /usr/local/bin/smart-dns-ir-doctor

# Remove cron job
(crontab -l 2>/dev/null | grep -v "smart-dns-ir-update") | crontab - 2>/dev/null || true

# Remove state directory
rm -rf /var/lib/smart-dns-ir

echo ""
echo "Removed:"
echo "  - systemd timer and service"
echo "  - /usr/local/bin/smart-dns-ir-*"
echo "  - cron job"
echo "  - /var/lib/smart-dns-ir/"
echo ""
echo "NOT removed (manual cleanup if desired):"
echo "  - dnsmasq package and /etc/dnsmasq.conf"
echo "  - /etc/sysctl.d/99-disable-ipv6.conf"
echo "  - /etc/systemd/resolved.conf.d/no-stub.conf"
echo "  - /etc/docker/daemon.json"
echo "  - /var/log/smart-dns-ir-*.log"
