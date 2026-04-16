#!/bin/bash
# smart-dns-ir: Docker DNS Doctor
# Detects Docker containers whose dns: directives bypass dnsmasq, then
# optionally rewrites their compose files to point at the dnsmasq bridge IP.
#
# Usage:
#   smart-dns-ir-doctor          # audit only — show what's wrong
#   smart-dns-ir-doctor --fix    # fix compose files + recreate containers
#
# Installed to /usr/local/bin/smart-dns-ir-doctor by install.sh.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FIX_MODE=false
[[ "${1:-}" == "--fix" ]] && FIX_MODE=true

if ! command -v docker &>/dev/null; then
    echo "Docker not installed, nothing to check."
    exit 0
fi

if ! docker ps --format '{{.ID}}' 2>/dev/null | grep -q .; then
    echo "No running containers."
    exit 0
fi

# Collect dnsmasq listen addresses (127.0.0.1 + bridge IPs)
VALID_IPS="127.0.0.1"
for ip in $(ip -4 addr show 2>/dev/null \
    | grep -oP 'inet \K[\d.]+(?=/.*(docker|br-))' || true); do
    VALID_IPS+=" $ip"
done

is_valid_dns() {
    local ip=$1
    for v in $VALID_IPS; do
        [[ "$ip" == "$v" ]] && return 0
    done
    return 1
}

# For a container, find the best bridge IP (gateway of its network)
best_bridge_for() {
    local cid=$1
    local nets
    nets=$(docker inspect "$cid" \
        --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
    for net in $nets; do
        local gw
        gw=$(docker network inspect "$net" \
            --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
        if [[ -n "$gw" ]] && echo "$VALID_IPS" | grep -qw "$gw"; then
            echo "$gw"
            return
        fi
    done
    # Fallback: first bridge IP
    echo "$VALID_IPS" | awk '{for(i=1;i<=NF;i++) if($i!="127.0.0.1"){print $i;exit}}'
}

ISSUES=0
FIXED=0
COMPOSE_DIRS_TO_RECREATE=()

while read -r cid cname; do
    dns_raw=$(docker inspect "$cid" \
        --format '{{range .HostConfig.Dns}}{{.}} {{end}}' 2>/dev/null)
    dns_list=($dns_raw)

    [[ ${#dns_list[@]} -eq 0 ]] && continue

    bad=""
    for d in "${dns_list[@]}"; do
        is_valid_dns "$d" || bad+="$d "
    done
    [[ -z "$bad" ]] && continue

    ISSUES=$((ISSUES + 1))

    compose_dir=$(docker inspect "$cid" \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
    compose_svc=$(docker inspect "$cid" \
        --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)

    bridge=$(best_bridge_for "$cid")

    echo -e "${YELLOW}✗${NC}  ${cname}  (service: ${compose_svc:-unknown})"
    echo "   dns: [${bad% }]  →  bypasses dnsmasq"
    echo "   fix: dns: [$bridge]"
    [[ -n "$compose_dir" ]] && echo "   file: ${compose_dir}/docker-compose.{yml,yaml}"

    if $FIX_MODE && [[ -n "$compose_dir" ]] && [[ -n "$compose_svc" ]]; then
        compose_path=""
        for name in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            [[ -f "${compose_dir}/${name}" ]] && compose_path="${compose_dir}/${name}" && break
        done

        if [[ -z "$compose_path" ]]; then
            echo -e "   ${RED}✗ compose file not found${NC}"
            echo ""
            continue
        fi

        if ! command -v python3 &>/dev/null; then
            echo -e "   ${RED}✗ python3 required for --fix${NC}"
            echo ""
            continue
        fi

        cp "$compose_path" "${compose_path}.bak.$(date +%Y%m%d%H%M%S)"

        if python3 - "$compose_path" "$compose_svc" "$bridge" <<'PYEOF'
import sys, re

path, service, bridge = sys.argv[1], sys.argv[2], sys.argv[3]

with open(path) as f:
    lines = f.readlines()

out = []
i = 0
in_service = False
service_indent = None
fixed = False

while i < len(lines):
    line = lines[i]
    stripped = line.rstrip()
    content = stripped.lstrip()
    indent = len(line) - len(line.lstrip()) if content else -1

    # Track which top-level service block we're in.
    # Services are children of the top-level "services:" key, so they
    # appear at indent == 2 (standard) or whatever one level below services.
    if (service_indent is not None and indent >= 0 and indent <= service_indent
            and content and not content.startswith('#') and not content.startswith('-')):
        in_service = False
        service_indent = None

    if not in_service:
        # Match "  service_name:" at any indent (but must be non-zero)
        m = re.match(r'^(\s+)' + re.escape(service) + r'\s*:\s*$', line)
        if m:
            in_service = True
            service_indent = len(m.group(1))
            out.append(line)
            i += 1
            continue

    if in_service and content and not content.startswith('#'):
        # Look for "dns:" line within the service block
        m2 = re.match(r'^(\s+)dns\s*:\s*$', line)
        if m2:
            dns_indent = len(m2.group(1))
            item_indent = dns_indent + 2
            out.append(f"{' ' * dns_indent}dns:\n")
            out.append(f"{' ' * item_indent}- {bridge}\n")
            i += 1
            # Skip old list items
            while i < len(lines):
                li = lines[i].lstrip()
                ci = len(lines[i]) - len(lines[i].lstrip()) if li else -1
                if li.startswith('- ') and ci > dns_indent:
                    i += 1
                elif not li or li.startswith('#'):
                    # Blank lines or comments inside the dns block — skip
                    if i + 1 < len(lines):
                        next_li = lines[i + 1].lstrip()
                        next_ci = len(lines[i + 1]) - len(lines[i + 1].lstrip()) if next_li else -1
                        if next_li.startswith('- ') and next_ci > dns_indent:
                            i += 1
                            continue
                    break
                else:
                    break
            fixed = True
            continue

    out.append(line)
    i += 1

if not fixed:
    sys.exit(1)

with open(path, 'w') as f:
    f.writelines(out)
PYEOF
        then
            echo -e "   ${GREEN}✓ fixed${NC} ${compose_path}"
            FIXED=$((FIXED + 1))
            # Track unique compose dirs to recreate
            if [[ ! " ${COMPOSE_DIRS_TO_RECREATE[*]:-} " =~ " ${compose_dir} " ]]; then
                COMPOSE_DIRS_TO_RECREATE+=("$compose_dir")
            fi
        else
            echo -e "   ${RED}✗ could not patch compose file${NC}"
        fi
    fi
    echo ""
done < <(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null)

# Recreate affected containers
if $FIX_MODE && [[ ${#COMPOSE_DIRS_TO_RECREATE[@]} -gt 0 ]]; then
    for dir in "${COMPOSE_DIRS_TO_RECREATE[@]}"; do
        echo -e "${CYAN}Recreating containers in ${dir}...${NC}"
        (cd "$dir" && docker compose up -d 2>&1 | sed 's/^/   /')
    done
    echo ""
fi

# Summary
if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}All containers use dnsmasq for DNS.${NC}"
    exit 0
fi

if $FIX_MODE; then
    echo -e "Fixed ${GREEN}${FIXED}${NC} / ${ISSUES} containers."
    [[ $FIXED -lt $ISSUES ]] && exit 1
else
    echo -e "${ISSUES} container(s) bypass dnsmasq. Run ${CYAN}smart-dns-ir-doctor --fix${NC} to repair."
    exit 1
fi
