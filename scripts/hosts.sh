#!/usr/bin/env bash
# Writes /etc/hosts lines for the Talos/Kubernetes API and the application
# hostnames, from tofu's outputs, into a marked block it replaces on every run
# (so a rebuild's new addresses take over, and nothing outside the block is
# touched). `--print` only prints the block. Only runs after `tofu apply` —
# none of these addresses exist before then.
set -euo pipefail

PRINT_ONLY=0
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$1"; }

TFVARS="${REPO}/tofu/terraform.tfvars"
tfvar() { awk -F'"' -v k="$1" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' "$TFVARS"; }

cd "${REPO}/tofu"
HOSTS_ENTRY="$(tofu output -raw hosts_entry)"
LB_DNS="$(tofu output -raw edge_lb_dns_name)"
MEDIA_IP="$(tofu output -raw media_smb_address 2>/dev/null || true)"
DOMAIN="$(tfvar domain)"

# The apps answer on the shared Envoy listener behind the edge load balancer.
# Its DNS name has no resolver off the platform yet, and the aws provider
# doesn't expose its address, so ask the gateway for the address it was given
# from the external pool — the same query the Spinifex docs use.
LB_IP="$(AWS_PROFILE="$(tfvar aws_profile)" AWS_CA_BUNDLE="${REPO}/spinifex-ca.pem" \
    aws --endpoint-url "$(tfvar gateway_endpoint)" --region "$(tfvar region)" \
    elbv2 describe-load-balancers \
    --query "LoadBalancers[?DNSName=='${LB_DNS}'].AvailabilityZones[].LoadBalancerAddresses[].IpAddress | [0]" \
    --output text 2>/dev/null || true)"
[[ "$LB_IP" == "None" ]] && LB_IP=""

APPS=(home echo vikunja atuin jellyfin kopia grafana alertmanager prometheus)

APP_NAMES="$(printf '%s.'"${DOMAIN}"' ' "${APPS[@]}" | sed 's/ $//')"
BEGIN="# BEGIN home-ops ${DOMAIN}"
END="# END home-ops ${DOMAIN}"

if [[ -z "$LB_IP" ]]; then
    warn "the gateway returned no address for ${LB_DNS}; writing the API line only"
    echo "    Check it in the Spinifex UI, or from a node with:"
    echo "      aws elbv2 describe-load-balancers --query 'LoadBalancers[].AvailabilityZones[].LoadBalancerAddresses[]'"
    echo "    then re-run this."
fi

BLOCK="${BEGIN}
${HOSTS_ENTRY}${LB_IP:+
${LB_IP} ${APP_NAMES}}${MEDIA_IP:+
${MEDIA_IP} media.${DOMAIN}}
${END}"

# Every line between the markers has to be a plain "IPv4 name..." entry. A
# lookup that returned an error or a warning instead of an address must never
# reach /etc/hosts: a garbage line there can stop macOS resolving any name.
valid='^([0-9]{1,3}\.){3}[0-9]{1,3}( [A-Za-z0-9.-]+)+$'
while IFS= read -r line; do
    [[ "$line" == "$BEGIN" || "$line" == "$END" ]] && continue
    if ! [[ "$line" =~ $valid ]]; then
        printf '    \033[31m✗\033[0m refusing to write an invalid hosts line: %q\n' "$line" >&2
        exit 1
    fi
done <<<"$BLOCK"

if (( PRINT_ONLY )); then
    printf '%s\n' "$BLOCK"
    exit 0
fi

# Rebuilt in a temp file and copied over, rather than sed -i, which takes
# different arguments on macOS and Linux.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' /etc/hosts > "$TMP"
printf '%s\n' "$BLOCK" >> "$TMP"

say "Updating /etc/hosts (sudo)"
printf '%s\n' "$BLOCK" | sed 's/^/    /'
sudo cp "$TMP" /etc/hosts
# macOS caches lookups; without this the old addresses can linger.
if [[ "$(uname)" == "Darwin" ]]; then
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder 2>/dev/null || true
fi
