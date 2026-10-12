#!/usr/bin/env bash
# Prints every credential this cluster has, in one place, from the two places
# they actually live: tofu's outputs (what the environment generated) and the
# sops-encrypted cluster-secrets (what render-secrets.sh generated). Nothing is
# written anywhere; it only reads what already exists.
#
# Prints secrets in the clear. Run it in a terminal you trust, not a shared
# screen or a CI log.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="${REPO}/kubernetes/components/sops/cluster-secrets.sops.yaml"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
row() { printf '  %-16s %-38s %s\n' "$1" "$2" "$3"; }
die() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

OUT="$(cd "${REPO}/tofu" && tofu output -json 2>/dev/null)" \
    || die "no tofu outputs — run 'tofu apply' first"
tf() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }

CS=""
if [[ -f "$SECRETS" ]]; then
    CS="$(sops -d "$SECRETS" 2>/dev/null)" \
        || die "can't decrypt ${SECRETS##*/} — is SOPS_AGE_KEY_FILE set? (mise must be active)"
fi
cs() { awk -v k="$1" '$1==k":" {print $2; exit}' <<<"$CS"; }

DOMAIN="$(cs SECRET_DOMAIN)"
DOMAIN="${DOMAIN:-$(awk -F'"' '/^[[:space:]]*domain[[:space:]]*=/ {print $2; exit}' "${REPO}/tofu/terraform.tfvars")}"

say "Logins"
row "Grafana" "https://grafana.${DOMAIN}" "admin / $(cs GRAFANA_ADMIN_PASSWORD)"
row "Media (SMB)" "smb://media.${DOMAIN}/media" "$(tf media_smb_username) / $(tf media_smb_password)"
row "Jellyfin" "https://jellyfin.${DOMAIN}" "admin you created in the first-run wizard"
row "Vikunja" "https://vikunja.${DOMAIN}" "self-registration on the login page"
row "Atuin" "https://atuin.${DOMAIN}" "atuin register -u <user> -e <email>"
row "Kopia" "https://kopia.${DOMAIN}" "no login (repository password below)"

say "Infrastructure"
row "Postgres (RDS)" "$(tf db_endpoint)" "$(tf db_master_username) / $(tf db_master_password)"
row "Atuin DB" "" "$(cs ATUIN_DB_PASSWORD)"
row "Backups (S3)" "$(tf s3_endpoint)/$(tf volsync_bucket)" "$(tf volsync_key_id) / $(tf volsync_key_secret)"
row "Kopia repo" "" "$(cs VOLSYNC_KOPIA_PASSWORD)"

[[ -n "$CS" ]] || printf '\n  (no %s yet — run scripts/render-secrets.sh for the Grafana, Atuin and Kopia passwords)\n' "${SECRETS##*/}"
echo
