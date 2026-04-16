#!/bin/bash
# smart-dns-ir: DNS Health Check
# Runs every 5 minutes via systemd timer. Tests resolution from host and
# from inside Docker containers. Auto-restarts dnsmasq or containers as needed.
# Installed to /usr/local/bin/smart-dns-ir-health-check by install.sh.

set -o pipefail

LOG=/var/log/smart-dns-ir-health.log
STATE_DIR=/var/lib/smart-dns-ir
mkdir -p "$STATE_DIR"

DOMAINS=("google.com" "matrix.org" "github.com")
FAILURES=0
HOST_OK=true
CONTAINER_OK=true

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

restart_dnsmasq() {
    if systemctl cat dnsmasq.service &>/dev/null; then
        systemctl restart dnsmasq
    else
        if [[ -f /run/dnsmasq.pid ]] && kill -0 "$(cat /run/dnsmasq.pid)" 2>/dev/null; then
            kill "$(cat /run/dnsmasq.pid)"
            sleep 1
        fi
        pkill -x dnsmasq 2>/dev/null || true
        /usr/sbin/dnsmasq -x /run/dnsmasq.pid
    fi
}

# ---------- Test 1: Host DNS via dnsmasq ----------
for domain in "${DOMAINS[@]}"; do
    result=$(dig @127.0.0.1 "$domain" A +short +time=3 +tries=1 2>/dev/null | head -1)
    if [[ -z "$result" ]] || echo "$result" | grep -qE '^10\.10\.'; then
        ((FAILURES++))
        log "FAIL host: $domain -> ${result:-EMPTY}"
    fi
done

if [[ $FAILURES -ge 2 ]]; then
    HOST_OK=false
    log "ACTION: restarting dnsmasq ($FAILURES/${#DOMAINS[@]} host lookups failed)"
    restart_dnsmasq
    sleep 2
    retest=$(dig @127.0.0.1 google.com A +short +time=3 +tries=1 2>/dev/null | head -1)
    if [[ -n "$retest" ]] && ! echo "$retest" | grep -qE '^10\.10\.'; then
        log "RECOVERED: dnsmasq restart fixed host DNS"
        HOST_OK=true
    else
        log "STILL_BROKEN: dnsmasq restart did not fix host DNS"
    fi
fi

# ---------- Test 2: Container DNS (if Docker is present) ----------
if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | head -1 | grep -q .; then
    FIRST_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | head -1)

    container_result=$(docker exec "$FIRST_CONTAINER" sh -c \
        'if command -v python3 >/dev/null 2>&1; then
             python3 -c "import socket; print(socket.gethostbyname(\"google.com\"))" 2>/dev/null
         elif command -v getent >/dev/null 2>&1; then
             getent hosts google.com | awk "{print \$1}" 2>/dev/null
         elif command -v nslookup >/dev/null 2>&1; then
             nslookup google.com 2>/dev/null | grep -A1 "Name:" | grep Address | awk "{print \$2}"
         else
             echo "NO_DNS_TOOL"
         fi' 2>/dev/null)

    if [[ "$container_result" == "FAIL" ]] || [[ -z "$container_result" ]] || [[ "$container_result" == "NO_DNS_TOOL" ]]; then
        CONTAINER_OK=false
        log "FAIL container ($FIRST_CONTAINER): cannot resolve google.com"

        if $HOST_OK; then
            # Check if dnsmasq is listening on Docker bridge IPs
            for bridge_ip in $(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+(?=/.*(docker|br-))'); do
                if ! ss -lnp sport = 53 | grep -q "$bridge_ip"; then
                    log "ACTION: dnsmasq not listening on $bridge_ip, restarting"
                    restart_dnsmasq
                    sleep 2
                    break
                fi
            done

            if command -v ufw &>/dev/null; then
                for subnet in 172.17.0.0/16 172.18.0.0/16; do
                    if ! ufw status 2>/dev/null | grep -q "53.*${subnet%%.*}"; then
                        log "WARNING: UFW may block Docker DNS — run: ufw allow from $subnet to any port 53"
                    fi
                done
            fi

            log "ACTION: restarting container $FIRST_CONTAINER to clear DNS cache"
            docker restart "$FIRST_CONTAINER" >/dev/null 2>&1
        fi
    elif echo "$container_result" | grep -qE '^10\.10\.'; then
        CONTAINER_OK=false
        log "FAIL container ($FIRST_CONTAINER): got censored IP $container_result for google.com"
    fi

    # Check for containers whose dns: directives bypass dnsmasq entirely.
    # These containers talk directly to external DNS, missing anti-censorship
    # overrides even when dnsmasq itself is healthy.
    BRIDGE_IPS_RE=$(ip -4 addr show 2>/dev/null \
        | grep -oP 'inet \K[\d.]+(?=/.*(docker|br-))' \
        | paste -sd'|' || true)
    if [[ -n "$BRIDGE_IPS_RE" ]]; then
        while read -r cid cname; do
            dns_raw=$(docker inspect "$cid" \
                --format '{{range .HostConfig.Dns}}{{.}} {{end}}' 2>/dev/null)
            [[ -z "$dns_raw" ]] && continue
            for d in $dns_raw; do
                if [[ "$d" != "127.0.0.1" ]] && ! echo "$d" | grep -qE "^($BRIDGE_IPS_RE)$"; then
                    log "BYPASS container $cname has dns=$dns_raw (not using dnsmasq). Run: smart-dns-ir-doctor --fix"
                    break 2
                fi
            done
        done < <(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null)
    fi
fi

# ---------- State file ----------
if $HOST_OK && $CONTAINER_OK; then
    echo "ok $(date +%s)" > "$STATE_DIR/health.state"
else
    echo "degraded $(date +%s) host=$HOST_OK container=$CONTAINER_OK" > "$STATE_DIR/health.state"
fi
