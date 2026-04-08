#!/bin/bash
# iran-dns: DNS Auto-Updater
# Benchmarks 60+ DNS servers, picks the top 10, writes /etc/dnsmasq.conf.
# Preserves manual overrides in the MANUAL-BEGIN/MANUAL-END block.
# Installed to /usr/local/bin/iran-dns-update by install.sh.
# Runs daily via cron.

DNS_SERVERS=(
    "8.8.8.8" "8.8.4.4" "1.1.1.1" "1.0.0.1"
    "178.22.122.100" "185.51.200.2" "178.22.122.101" "185.51.200.1"
    "10.202.10.202" "10.202.10.102" "78.157.42.100" "78.157.42.101"
    "10.202.10.10" "10.202.10.11" "185.55.226.26" "185.55.225.25"
    "77.77.77.77" "77.77.77.78"
    "85.15.1.14" "85.15.1.15" "94.182.39.201" "94.182.39.228" "94.182.39.238"
    "2.188.21.90" "2.188.21.100" "2.188.21.120" "2.188.21.190"
    "2.188.21.230" "2.188.21.240" "2.189.44.44" "2.188.21.130" "2.188.21.131" "2.188.21.132"
    "217.218.155.155" "217.218.127.127" "5.200.200.200"
    "217.219.72.194" "2.185.239.133" "2.185.239.134" "2.185.239.135"
    "2.185.239.136" "2.185.239.137" "2.185.239.138" "2.185.239.139"
    "185.98.113.113" "185.98.114.114" "95.38.15.205"
    "194.225.152.12" "194.225.152.10" "194.225.152.13"
    "193.151.128.100" "193.151.128.200" "81.91.144.116" "185.51.200.4"
    "193.189.123.2" "193.189.122.83" "194.225.70.83"
    "5.202.100.100" "5.202.100.101" "185.243.50.1" "185.243.50.30"
    "193.186.32.32" "208.67.220.200" "208.67.222.222"
    "74.82.42.42" "91.239.100.100" "89.223.43.71"
)

DOMAINS=(
    "google.com" "youtube.com" "github.com" "gitlab.com" "docker.com"
    "developer.apple.com" "android.com" "epicgames.com" "oracle.com" "x.com"
    "tgju.org" "aparat.com" "digikala.com" "varzesh3.com" "torob.com"
    "shaparak.ir" "sep.shaparak.ir"
    "digiato.com" "isna.ir" "irna.ir" "zoomit.ir" "zarebin.ir"
    "gateway.zibal.ir" "zibal.ir" "web.bale.ai"
    "eitaa.com" "web.eitaa.com" "quera.ir" "quera.org" "ramzinex.com" "cdn.ir"
    "matrix.org"
)

CONF=/etc/dnsmasq.conf
TMP_DIR=$(mktemp -d)

test_dns() {
    local dns=$1
    local success_count=0
    local total_time=0
    local failed_domains=""

    for domain in "${DOMAINS[@]}"; do
        result=$(dig @"$dns" "$domain" A +noall +answer +stats +time=2 +tries=1 2>/dev/null)
        ips=$(echo "$result" | grep -v '^;' | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')

        if [[ -n "$ips" ]] && ! echo "$ips" | grep -qE '^10\.10\.'; then
            ((success_count++))
            q_time=$(echo "$result" | grep "Query time:" | awk '{print $4}')
            if [[ -n "$q_time" && "$q_time" =~ ^[0-9]+$ ]]; then
                total_time=$((total_time + q_time))
            fi
        else
            failed_domains+="$domain,"
        fi
    done

    failed_domains=${failed_domains%,}
    local avg_time=9999
    if [[ $success_count -gt 0 ]]; then
        avg_time=$((total_time / success_count))
    fi
    echo "$success_count $avg_time $failed_domains" > "$TMP_DIR/$dns"
}

for dns in "${DNS_SERVERS[@]}"; do test_dns "$dns" & done
wait

declare -A results
for dns in "${DNS_SERVERS[@]}"; do
    if [[ -f "$TMP_DIR/$dns" ]]; then
        results["$dns"]=$(cat "$TMP_DIR/$dns")
    else
        results["$dns"]="0 9999 ALL_FAILED"
    fi
done
rm -rf "$TMP_DIR"

echo "================================================================================"
echo " Top 15 DNS Servers (by domain support, then latency):"
echo "================================================================================"

rank=1
TOP_TEN=""

while read -r dns score latency failed_list; do
    if [[ $rank -le 10 ]]; then
        TOP_TEN+="$dns "
    fi

    if [[ $rank -le 15 ]]; then
        case $dns in
            "8.8.8.8"|"8.8.4.4") name="Google" ;;
            "1.1.1.1"|"1.0.0.1") name="Cloudflare" ;;
            "178.22.122.101"|"185.51.200.1") name="Shecan Pro" ;;
            "178.22.122.100"|"185.51.200.2") name="Shecan Normal" ;;
            "10.202.10.202"|"10.202.10.102") name="403.online" ;;
            "78.157.42.100"|"78.157.42.101") name="Electro" ;;
            "10.202.10.10"|"10.202.10.11") name="Radar Game" ;;
            "185.55.226.26"|"185.55.225.25") name="Begzar" ;;
            "77.77.77.77"|"77.77.77.78") name="3dns" ;;
            "85.15.1.14"|"85.15.1.15"|"94.182.39."*) name="Shatel" ;;
            "217.218.155.155"|"217.218.127.127"|"2.189.44.44"|"2.188.21."*) name="TIC" ;;
            "5.200.200.200") name="Mokhaberat" ;;
            "217.219.72.194"|"2.185.239."*) name="Mokhaberat AZ" ;;
            "185.98.113.113"|"185.98.114.114") name="Asiatech" ;;
            "95.38.15.205") name="Fanava" ;;
            "194.225.152.12"|"194.225.152."*) name="IPM" ;;
            "193.151.128.100"|"193.151.128.200") name="Derak Cloud" ;;
            "81.91.144.116") name="Faradadeh" ;;
            "185.51.200.4") name="Amirkabir" ;;
            "193.189.123.2"|"193.189.122.83"|"194.225.70.83") name="IRNIC" ;;
            "5.202.100.100"|"5.202.100.101") name="Pishgaman" ;;
            "185.243.50.1"|"185.243.50.30") name="Toloe Rayaneh" ;;
            "193.186.32.32") name="Bertina" ;;
            "208.67.220.200"|"208.67.222.222") name="OpenDNS" ;;
            "74.82.42.42") name="HE" ;;
            "91.239.100.100"|"89.223.43.71") name="Rightel" ;;
            *) name="Unknown" ;;
        esac

        [[ "$latency" == "9999" ]] && lat_display="N/A" || lat_display="${latency} ms"

        fail_col=""
        if [[ $score -eq ${#DOMAINS[@]} ]]; then
            fail_col="Failed: None"
        else
            fail_col="Failed: $(echo "$failed_list" | sed 's/,/, /g')"
        fi

        printf "%-18s | %-16s | %2d / %2d | %-7s | %s\n" \
            "$dns" "$name" "$score" "${#DOMAINS[@]}" "$lat_display" "$fail_col"
    fi
    ((rank++))
done < <(for dns in "${!results[@]}"; do echo "$dns ${results[$dns]}"; done | sort -k2,2rn -k3,3n)

echo "================================================================================"

# Auto-detect Docker bridge IPs
LISTEN="127.0.0.1"
if command -v docker &>/dev/null; then
    for bridge_ip in $(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+(?=/.*(docker|br-))'); do
        LISTEN+=",${bridge_ip}"
    done
fi

# Preserve existing MANUAL block
MANUAL_BLOCK=""
if [[ -f "$CONF" ]]; then
    MANUAL_BLOCK=$(sed -n '/^# MANUAL-BEGIN/,/^# MANUAL-END/p' "$CONF")
fi

if [[ -z "$MANUAL_BLOCK" ]]; then
    MANUAL_BLOCK='# MANUAL-BEGIN — preserved across auto-updates. Edit freely.
# Anti-censorship: reject responses containing hijacked IPs.
# Iranian censors return 10.10.x.x for blocked domains.
bogus-nxdomain=10.10.34.35
bogus-nxdomain=10.10.34.36
bogus-nxdomain=10.10.34.34
# To force a specific domain through an uncensored resolver:
# server=/example.com/194.225.152.10
# MANUAL-END'
fi

cat <<CONFIG_EOF > "$CONF"
# Auto-generated by iran-dns-update on $(date '+%Y-%m-%d %H:%M')
# Manual overrides between MANUAL-BEGIN and MANUAL-END are preserved.
port=53
listen-address=${LISTEN}
bind-dynamic
no-resolv
no-poll
filter-AAAA

cache-size=10000
min-cache-ttl=604800
max-cache-ttl=604800
local-ttl=604800
neg-ttl=60

$MANUAL_BLOCK

# Top 10 upstream servers
CONFIG_EOF

for ip in $TOP_TEN; do
    echo "server=$ip" >> "$CONF"
done

systemctl restart dnsmasq
echo "dnsmasq restarted with ${LISTEN} and $(echo $TOP_TEN | wc -w | tr -d ' ') upstreams."
