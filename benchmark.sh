#!/bin/bash
# smart-dns-ir: DNS Benchmark
# Tests 60+ Iranian and global DNS servers in parallel.
# Measures domain support and latency, filters out censored 10.10.x.x responses.
# Works on any Linux/macOS with `dig` installed.
# Usage: ./benchmark.sh

if ! command -v dig &>/dev/null; then
    echo "Error: 'dig' is required. Install: apt install dnsutils (or brew install bind on macOS)"
    exit 1
fi

DNS_SERVERS=(
    # Global
    "8.8.8.8" "8.8.4.4"                          # Google
    "1.1.1.1" "1.0.0.1"                          # Cloudflare
    # Shecan
    "178.22.122.100" "185.51.200.2"               # Normal
    "178.22.122.101" "185.51.200.1"               # Pro
    # 403.online / Respina
    "10.202.10.202" "10.202.10.102"
    # Electro
    "78.157.42.100" "78.157.42.101"
    # Radar Game
    "10.202.10.10" "10.202.10.11"
    # Begzar
    "185.55.226.26" "185.55.225.25"
    # 3dns
    "77.77.77.77" "77.77.77.78"
    # Shatel
    "85.15.1.14" "85.15.1.15" "94.182.39.201" "94.182.39.228" "94.182.39.238"
    # TIC (Telecommunication Infrastructure Company)
    "2.188.21.90" "2.188.21.100" "2.188.21.120" "2.188.21.190"
    "2.188.21.230" "2.188.21.240" "2.189.44.44"
    "2.188.21.130" "2.188.21.131" "2.188.21.132"
    "217.218.155.155" "217.218.127.127"
    # TCI / Mokhaberat
    "5.200.200.200"
    # Mokhaberat Azerbaijan
    "217.219.72.194" "2.185.239.133" "2.185.239.134" "2.185.239.135"
    "2.185.239.136" "2.185.239.137" "2.185.239.138" "2.185.239.139"
    # Asiatech
    "185.98.113.113" "185.98.114.114"
    # Fanava
    "95.38.15.205"
    # IPM (Institute for Research in Fundamental Sciences)
    "194.225.152.12" "194.225.152.10" "194.225.152.13"
    # Derak Cloud
    "193.151.128.100" "193.151.128.200"
    # Faradadeh
    "81.91.144.116"
    # Amirkabir University
    "185.51.200.4"
    # IRNIC
    "193.189.123.2" "193.189.122.83" "194.225.70.83"
    # Pishgaman
    "5.202.100.100" "5.202.100.101"
    # Toloe Rayaneh Loghman
    "185.243.50.1" "185.243.50.30"
    # Bertina
    "193.186.32.32"
    # Hamrah Aval / OpenDNS
    "208.67.220.200" "208.67.222.222"
    # Irancell / Hurricane Electric
    "74.82.42.42"
    # Rightel
    "91.239.100.100" "89.223.43.71"
)

DOMAINS=(
    # International / sanctioned
    "google.com" "youtube.com" "github.com" "gitlab.com" "docker.com"
    "developer.apple.com" "android.com" "epicgames.com" "oracle.com" "x.com"
    # Iranian
    "tgju.org" "aparat.com" "digikala.com" "varzesh3.com" "torob.com"
    "shaparak.ir" "sep.shaparak.ir"
    "digiato.com" "isna.ir" "irna.ir" "zoomit.ir" "zarebin.ir"
    "gateway.zibal.ir" "zibal.ir" "web.bale.ai"
    "eitaa.com" "web.eitaa.com" "quera.ir" "quera.org" "ramzinex.com" "cdn.ir"
    "matrix.org"
)

echo "================================================================================"
echo "  smart-dns-ir benchmark"
echo "  Testing ${#DOMAINS[@]} domains against ${#DNS_SERVERS[@]} DNS servers..."
echo "  Hijack detection: responses containing 10.10.x.x are marked as censored."
echo "  Please wait ~10 seconds..."
echo "================================================================================"

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

echo ""
echo "================================================================================"
printf "%-18s | %-16s | %-10s | %-9s | %s\n" "DNS Server" "Provider" "Support" "Latency" "Failed Domains"
echo "================================================================================"

rank=1
for dns in "${!results[@]}"; do
    echo "$dns ${results[$dns]}"
done | sort -k2,2rn -k3,3n | while read -r dns score latency failed_list; do

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
    if [[ $rank -le 15 ]]; then
        if [[ $score -eq ${#DOMAINS[@]} ]]; then
            fail_col="None"
        else
            fail_col=$(echo "$failed_list" | sed 's/,/, /g')
        fi
    fi

    printf "%-18s | %-16s | %2d / %2d   | %-9s | %s\n" \
        "$dns" "$name" "$score" "${#DOMAINS[@]}" "$lat_display" "$fail_col"

    ((rank++))
done
echo "================================================================================"
