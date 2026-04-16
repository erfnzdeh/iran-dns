# smart-dns-ir

A self-healing DNS optimizer for servers in Iran.

Benchmarks 60+ DNS servers, installs a local caching resolver (`dnsmasq`), and keeps it running with automated health checks — so your server always has fast, uncensored DNS even when upstream providers get throttled, filtered, or go down.

## The Problem

Running servers in Iran means dealing with:

- **DNS censorship** — some resolvers return fake IPs (`10.10.34.x`) for blocked domains
- **Inconsistent providers** — a DNS server that works today may start censoring tomorrow
- **International throttling** — Google (`8.8.8.8`) and Cloudflare (`1.1.1.1`) are often slow or unreachable
- **Docker blindspot** — containers can't use `127.0.0.1` to reach the host's DNS, so they inherit whatever broken upstream DNS Docker is configured with

If you're running Matrix Synapse, Gitea, Nextcloud, or any self-hosted service that talks to other servers — broken DNS means broken federation, broken webhooks, and broken everything.

## Quick Start

```bash
git clone https://github.com/erfnzdeh/smart-dns-ir.git
cd smart-dns-ir
sudo bash install.sh
```

That's it. The installer:

1. Installs `dnsmasq` and disables conflicting services (`systemd-resolved`, `unbound`)
2. Benchmarks 60+ DNS servers in parallel and picks the 10 fastest uncensored ones
3. Configures a local caching resolver with aggressive caching (10K entries, 1-week TTL)
4. Auto-detects Docker bridge IPs and configures container DNS
5. Opens firewall (UFW) for Docker-to-host DNS traffic
6. Sets up a health check that runs every 5 minutes (systemd timer)
7. Schedules a daily re-benchmark at 03:00 to adapt to changing network conditions

## What Gets Installed

| Component | Location | Purpose |
|---|---|---|
| `smart-dns-ir-benchmark` | `/usr/local/bin/` | Standalone benchmark — test DNS servers anytime |
| `smart-dns-ir-update` | `/usr/local/bin/` | Re-benchmark + update dnsmasq config |
| `smart-dns-ir-health-check` | `/usr/local/bin/` | Test host + container DNS, auto-restart if broken |
| `smart-dns-ir-doctor` | `/usr/local/bin/` | Detect + fix containers that bypass dnsmasq |
| Health check timer | systemd | Runs `smart-dns-ir-health-check` every 5 min |
| Daily cron | crontab | Runs `smart-dns-ir-update` at 03:00 |
| dnsmasq restart policy | systemd drop-in | Auto-restarts dnsmasq on crash |

## Just Want to Benchmark?

You don't have to install anything. Run the benchmark standalone on any Linux or macOS machine:

```bash
# Requires: dig (apt install dnsutils / brew install bind)
chmod +x benchmark.sh
./benchmark.sh
```

Output:

```
================================================================================
DNS Server         | Provider         | Support    | Latency   | Failed Domains
================================================================================
194.225.152.10     | IPM              | 34 / 34   | 12 ms     | None
193.186.32.32      | Bertina          | 34 / 34   | 8 ms      | None
78.157.42.100      | Electro          | 33 / 34   | 15 ms     | matrix.org
8.8.8.8            | Google           |  0 / 34   | N/A       | ALL_FAILED
...
================================================================================
```

## Restricted Networks

Some VPSes can't reach `apt` mirrors or public DNS at all. If `apt-get update` fails:

```bash
sudo bash bootstrap-apt.sh    # Points apt at Arvan's domestic mirror
sudo bash install.sh           # Then install as normal
```

If even `apt` doesn't work (no outbound DNS at all), see [Offline Installation](#offline-installation).

## Docker Integration

The installer auto-detects Docker bridge networks and configures everything. If you set up Docker *after* running `install.sh`, just run the updater:

```bash
sudo smart-dns-ir-update
```

It auto-detects new bridge IPs and adds them to dnsmasq's listen addresses.

### Manual Docker Setup

If you prefer to do it yourself:

**1. Find your Docker bridge IPs:**

```bash
ip -4 addr show | grep -E "inet .*(br-|docker)"
# 172.17.0.1  (docker0 — default bridge)
# 172.18.0.1  (br-xxx — compose network)
```

**2. Edit `/etc/dnsmasq.conf`:**

```
listen-address=127.0.0.1,172.17.0.1,172.18.0.1
bind-dynamic
```

**3. Point Docker at dnsmasq — `/etc/docker/daemon.json`:**

```json
{ "dns": ["172.18.0.1", "172.17.0.1"] }
```

And/or per service in `docker-compose.yml`:

```yaml
services:
  myapp:
    dns:
      - 172.18.0.1
```

> **Warning: never use external DNS servers (e.g. `78.157.42.100`, `217.218.127.127`) in `docker-compose.yml` `dns:` directives.** This bypasses dnsmasq entirely — containers will talk directly to those upstream servers, skipping the local cache, anti-censorship overrides (`bogus-nxdomain`, `server=/domain/...`), and health-check auto-recovery. If any of those upstreams censor a domain, your containers will silently fail to resolve it even though `dig @127.0.0.1` on the host works fine. Always point container DNS at the dnsmasq bridge IP (e.g. `172.18.0.1`).

**4. Open the firewall (this is the most commonly missed step):**

```bash
sudo ufw allow from 172.17.0.0/16 to any port 53 proto udp
sudo ufw allow from 172.17.0.0/16 to any port 53 proto tcp
sudo ufw allow from 172.18.0.0/16 to any port 53 proto udp
sudo ufw allow from 172.18.0.0/16 to any port 53 proto tcp
```

**5. Restart:**

```bash
sudo systemctl restart dnsmasq docker
docker-compose down && docker-compose up -d
```

### Docker DNS Doctor

If you inherited a `docker-compose.yml` with hardcoded `dns:` entries pointing at external servers (e.g. `78.157.42.100`, `217.218.127.127`), the doctor can detect and fix them automatically:

```bash
# Audit — show which containers bypass dnsmasq
sudo smart-dns-ir-doctor

# Fix — rewrite compose files and recreate affected containers
sudo smart-dns-ir-doctor --fix
```

The installer runs the audit automatically. The health check also logs warnings when it detects containers with DNS bypass.

## Anti-Censorship Overrides

The installer creates a `MANUAL-BEGIN` / `MANUAL-END` block in `/etc/dnsmasq.conf` that survives auto-updates. Use it to fight censorship:

```
# MANUAL-BEGIN — preserved across auto-updates. Edit freely.

# Reject hijacked IPs (Iranian censors return these for blocked domains)
bogus-nxdomain=10.10.34.35
bogus-nxdomain=10.10.34.36
bogus-nxdomain=10.10.34.34

# Force a censored domain through an uncensored resolver (IPM in this case)
server=/example.com/194.225.152.10
server=/blocked-service.app/194.225.152.10

# MANUAL-END
```

**How it works:**

- `bogus-nxdomain` — if *any* upstream returns this IP, dnsmasq treats it as NXDOMAIN and tries the next server
- `server=/domain/ip` — routes queries for that domain exclusively through the specified resolver, bypassing all others

**Finding hijacked IPs:**

```bash
dig @SUSPECT_DNS blocked-domain.com A +short
# Returns 10.10.34.36  ← that's a hijack IP, add it to bogus-nxdomain
```

## Troubleshooting

### Host DNS is broken

```bash
# Is dnsmasq running?
systemctl status dnsmasq

# Can it resolve?
dig @127.0.0.1 google.com A +short

# Check if something else grabbed port 53
ss -lnp sport = 53

# Re-run the benchmark to get fresh upstreams
sudo smart-dns-ir-update
```

### Container DNS is broken but host works

```bash
# Is dnsmasq listening on the Docker bridge?
ss -lnp sport = 53 | grep 172

# Is UFW blocking it?
sudo ufw status | grep 53

# Test from inside a container
docker exec CONTAINER python3 -c "import socket; print(socket.gethostbyname('google.com'))"

# Nuclear option: restart everything
sudo systemctl restart dnsmasq docker
docker-compose down && docker-compose up -d
```

### A specific domain is censored

```bash
# Test which upstream resolves it correctly
dig @194.225.152.10 blocked-domain.com A +short   # IPM — usually uncensored
dig @193.186.32.32 blocked-domain.com A +short     # Bertina

# If one works, add a domain override to /etc/dnsmasq.conf:
#   server=/blocked-domain.com/194.225.152.10
# Then restart dnsmasq:
sudo systemctl restart dnsmasq
```

### Bridge IP changed after docker-compose down/up

```bash
# Check current bridge IPs
docker network inspect $(docker network ls -q) 2>/dev/null | grep Gateway

# Re-run updater to auto-detect new IPs
sudo smart-dns-ir-update
```

## Offline Installation

When the VPS has no outbound DNS and `apt` can't install packages:

On a machine with internet (or via Docker):

```bash
mkdir -p /tmp/debs && cd /tmp/debs
docker run --rm -v "$PWD:/out" ubuntu:24.04 bash -lc \
  'apt-get update && apt-get download dnsmasq dnsutils && \
   for p in *.deb; do dpkg -I "$p" | sed -n "s/^ Depends: //p"; done | \
   tr ", " "\n" | sort -u | grep -v "^$" | \
   while read -r d; do apt-get download "$d" || true; done; \
   cp *.deb /out/ 2>/dev/null'
```

Copy to the VPS:

```bash
scp /tmp/debs/*.deb root@YOUR_VPS:/root/
scp -r smart-dns-ir/ root@YOUR_VPS:/root/smart-dns-ir/
ssh root@YOUR_VPS 'cd /root && dpkg -i *.deb; apt-get install -f -y; cd smart-dns-ir && bash install.sh'
```

## Uninstall

```bash
sudo bash uninstall.sh
```

Removes scripts, systemd units, cron jobs, and state files. Does **not** remove `dnsmasq` itself or system configs (IPv6, resolv.conf) — see the script output for what to clean up manually.

## DNS Servers Tested

60+ servers from Iranian and global providers:

| Provider | IPs |
|---|---|
| Google | 8.8.8.8, 8.8.4.4 |
| Cloudflare | 1.1.1.1, 1.0.0.1 |
| Shecan | 178.22.122.100/101, 185.51.200.1/2 |
| 403.online / Respina | 10.202.10.202/102 |
| Electro | 78.157.42.100/101 |
| Radar Game | 10.202.10.10/11 |
| Begzar | 185.55.226.26/25 |
| 3dns | 77.77.77.77/78 |
| Shatel | 85.15.1.14/15, 94.182.39.x |
| TIC | 2.188.21.x, 217.218.x.x |
| TCI / Mokhaberat | 5.200.200.200, 217.219.72.194 |
| Asiatech | 185.98.113.113/114 |
| IPM | 194.225.152.10/12/13 |
| Derak Cloud | 193.151.128.100/200 |
| Bertina | 193.186.32.32 |
| IRNIC | 193.189.123.2, 193.189.122.83 |
| Pishgaman | 5.202.100.100/101 |
| OpenDNS (Hamrah Aval) | 208.67.222.222/220.200 |
| + more | Fanava, Faradadeh, Amirkabir, Toloe Rayaneh, Rightel, Irancell/HE |

## Test Domains

32 domains covering international/sanctioned services (Google, YouTube, GitHub, Docker, X) and Iranian services (Digikala, Aparat, Shaparak, Bale, Eitaa, Quera) to measure both reach and censorship.

## License

MIT
