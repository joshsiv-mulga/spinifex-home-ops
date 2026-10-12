set quiet
set default-list
set default-script
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set working-directory := '..'

bootstrap_dir := justfile_dir() + '/bootstrap'
kubernetes_dir := justfile_dir() + '/kubernetes'
talos_dir := justfile_dir() + '/talos'
private_dir := justfile_dir() + '/.private'

template_dir := justfile_dir() + '/template'
template_resources := template_dir + '/resources'
makejinja_config := justfile_dir() + '/makejinja.toml'
mise_fragment := justfile_dir() + '/.mise/conf.d/template.toml'

config_file := justfile_dir() + '/cluster.toml'
schema_file := justfile_dir() + '/cluster.schema.json'
sample_config_file := justfile_dir() + '/cluster.sample.toml'
validate_script := template_dir + '/scripts/validate.py'
deploy_key := justfile_dir() + '/deploy.key'
webhook_token_file := justfile_dir() + '/flux-webhook-token.txt'
cloudflare_tunnel := justfile_dir() + '/cloudflare-tunnel.json'
spinifex_ca := justfile_dir() + '/spinifex-ca.pem'
vikunja_jwt_secret_file := justfile_dir() + '/vikunja-jwt-secret.txt'
cluster_secrets_file := kubernetes_dir + '/components/sops/cluster-secrets.sops.yaml'

[doc('Render and validate configuration files')]
[group('template')]
configure: render stub-cluster-secrets encrypt-secrets validate-kubernetes validate-talos

[doc('Check that all prerequisite files exist and cluster.toml validates against the schema')]
[group('template')]
[no-exit-message]
doctor:
    rc=0
    just log info "just version" version "{{ just_version() }}"
    just template doctor-check "cluster.toml"           "{{ config_file }}"           || rc=1
    just template doctor-check "cluster.sample.toml"    "{{ sample_config_file }}"    || rc=1
    config_json="$(just template config-json 2>/dev/null || true)"
    if [ "$(jq -r '.ingress.mode' <<< "$config_json" 2>/dev/null)" = "cloudflare-tunnel" ]; then
        just template doctor-check "cloudflare-tunnel.json" "{{ cloudflare_tunnel }}" || rc=1
    fi
    if [ "$(jq -r '.provider' <<< "$config_json" 2>/dev/null)" = "spinifex" ]; then
        just template doctor-check "spinifex-ca.pem"    "{{ spinifex_ca }}"           || rc=1
        just template ca-drift                                                        || rc=1
    fi
    just template doctor-check "age.key"                "$SOPS_AGE_KEY_FILE"          || rc=1
    just template doctor-check "deploy.key"             "{{ deploy_key }}"            || rc=1
    just template doctor-check "flux-webhook-token.txt" "{{ webhook_token_file }}"    || rc=1
    just template doctor-check "vikunja-jwt-secret.txt" "{{ vikunja_jwt_secret_file }}" || rc=1
    just template doctor-check "template/"              "{{ template_dir }}"          || rc=1
    just template doctor-check "makejinja.toml"         "{{ makejinja_config }}"      || rc=1
    just template doctor-check "validate.py"            "{{ validate_script }}"       || rc=1
    if [ -f "{{ config_file }}" ] && [ -f "{{ validate_script }}" ]; then
        if [ -n "$config_json" ]; then
            just log info "ok" check schema
        else
            just log error "fail" check schema
            just log info "diagnose with: uv run --locked --no-dev {{ validate_script }} {{ config_file }}"
            rc=1
        fi
    fi
    [ "$rc" = 0 ] && just log info "all good"
    exit "$rc"

[doc('Check every embedded copy of the cluster CA still matches spinifex-ca.pem')]
[group('template')]
[no-exit-message]
ca-drift:
    uv run --quiet --locked {{ justfile_dir() }}/scripts/ca-drift.py

[doc('Initialize configuration files (cluster.toml, age key, deploy key, webhook token)')]
[group('template')]
init:
    [ -f "{{ config_file }}" ]           || cp "{{ sample_config_file }}" "{{ config_file }}"
    [ -f "$SOPS_AGE_KEY_FILE" ]          || age-keygen -pq --output "$SOPS_AGE_KEY_FILE"
    [ -f "{{ deploy_key }}" ]            || ssh-keygen -t ed25519 -C "deploy-key" -f "{{ deploy_key }}" -q -P ""
    [ -f "{{ webhook_token_file }}" ]    || openssl rand -hex 16 > "{{ webhook_token_file }}"
    [ -f "{{ vikunja_jwt_secret_file }}" ] || openssl rand -hex 32 > "{{ vikunja_jwt_secret_file }}"

# Editors resolve the #:schema directive in cluster.toml against this file;
# the validator tests fail when it drifts from the pydantic model.
[doc('Regenerate the cluster.toml JSON Schema from the validator')]
[group('template')]
schema:
    uv run --quiet --locked --no-dev "{{ validate_script }}" --schema > "{{ schema_file }}"
    oxfmt "{{ schema_file }}" > /dev/null

# tofu/ is deliberately left alone. Its state file is the only record of what
# was built, and removing it strands every resource it names.
[confirm("Remove all templated files and directories — continue? [y/N]")]
[doc('Remove rendered files (bootstrap/, kubernetes/, talos/, .sops.yaml)')]
[group('template')]
reset:
    rm -rf "{{ bootstrap_dir }}" "{{ kubernetes_dir }}" "{{ talos_dir }}" "{{ justfile_dir() }}/.sops.yaml"

# tidy-archive moves template/ (this module's source) away, so it runs as a
# subsequent dependency: the tidy script itself must spawn while the module
# directory still exists.
[confirm("All template related config will be archived — continue? [y/N]")]
[doc('Archive all template tooling under .private/<ts>/ (one-way, run after configure works)')]
[group('template')]
tidy: tidy-preconditions tidy-strip && tidy-archive

# Validated, defaulted cluster config as JSON on stdout; fails when the
# config is invalid.
[private]
config-json:
    uv run --quiet --locked --no-dev "{{ validate_script }}" "{{ config_file }}"

[no-exit-message]
[private]
doctor-check label path:
    if [ -e "{{ path }}" ]; then
        just log info "ok" file "{{ label }}"
    else
        just log error "missing" file "{{ label }}"
        exit 1
    fi

[private]
encrypt-secrets:
    find "{{ bootstrap_dir }}" "{{ kubernetes_dir }}" "{{ talos_dir }}" -type f -name '*.sops.*' -print0 \
        | while IFS= read -r -d '' f; do
            if ! status="$(sops filestatus "$f" | jq -r '.encrypted')"; then
                just log fatal "could not read encryption status" file "$f"
            fi
            case "$status" in
                false) sops encrypt --in-place "$f" ;;
                true)  : ;;
                *)     just log fatal "could not determine encryption status" file "$f" ;;
            esac
        done

[private]
render:
    PYTHONDONTWRITEBYTECODE=1 uv run --locked --no-dev makejinja

# cluster-secrets carries values no template can know until the environment
# exists (tofu outputs, generated passwords) — scripts/render-secrets.sh is
# its only owner once that's true. This only fills the gap on a fresh fork,
# so configure never re-renders over (and loses) what that script wrote.
[private]
stub-cluster-secrets:
    [ -f "{{ cluster_secrets_file }}" ] && exit 0 || true
    config_json="$(just template config-json)"
    domain="$(jq -r '.domain.name' <<< "$config_json")"
    region="$(jq -r 'if .provider == "spinifex" then .spinifex.region else "" end' <<< "$config_json")"
    mkdir -p "$(dirname "{{ cluster_secrets_file }}")"
    {
        echo "---"
        echo "# Placeholder. ./scripts/render-secrets.sh overwrites this with the real"
        echo "# values once the environment exists (tofu outputs, generated passwords) —"
        echo "# it is the only thing that should ever edit this file after that."
        echo "apiVersion: v1"
        echo "kind: Secret"
        echo "metadata:"
        echo "  name: cluster-secrets"
        echo "  namespace: flux-system"
        echo "stringData:"
        echo "  SECRET_DOMAIN: ${domain}"
        echo "  SPINIFEX_REGION: ${region}"
    } > "{{ cluster_secrets_file }}"

[private]
tidy-archive:
    TIDY_FOLDER="{{ private_dir }}/$(date +%s)"
    mkdir -p "$TIDY_FOLDER"
    rm -rf "{{ justfile_dir() }}/.github/template-tests" "{{ justfile_dir() }}/.github/workflows"/template-*.yaml
    mv \
        "{{ template_dir }}" \
        "{{ makejinja_config }}" \
        "{{ mise_fragment }}" \
        "{{ schema_file }}" \
        "{{ config_file }}" \
        "{{ sample_config_file }}" \
        "{{ justfile_dir() }}/pyproject.toml" \
        "{{ justfile_dir() }}/uv.lock" \
        "$TIDY_FOLDER/"
    rmdir "$(dirname "{{ mise_fragment }}")" 2>/dev/null || true
    rm -rf "{{ justfile_dir() }}/.venv"

[private]
tidy-preconditions:
    test -d "{{ template_dir }}"
    test -d "{{ justfile_dir() }}/.github/template-tests"
    test -f "{{ makejinja_config }}"
    test -f "{{ config_file }}"
    test -f "{{ sample_config_file }}"
    test -f "{{ justfile_dir() }}/pyproject.toml"
    test -f "{{ justfile_dir() }}/uv.lock"
    test -f "{{ justfile_dir() }}/justfile"
    test -f "{{ mise_fragment }}"
    test -f "{{ schema_file }}"
    test -f "{{ justfile_dir() }}/.renovaterc.json5"
    compgen -G "{{ justfile_dir() }}/.github/workflows/template-*.yaml" > /dev/null

[private]
tidy-strip:
    sd '\..\.j2'                          '' "{{ justfile_dir() }}/.renovaterc.json5"
    sd -A '(?ms)^# === template ===$.*'   '' "{{ justfile_dir() }}/justfile"

# Renders every bootstrap chart with the rendered values, catching chart or
# values drift that dry runs cannot; needs network access to pull charts.
[doc('Render the bootstrap helmfile charts against the rendered values')]
[group('template')]
test-helmfile:
    helmfile --file "{{ bootstrap_dir }}/helmfile/apps.yaml" template --quiet > /dev/null
    just log info "bootstrap charts rendered cleanly"

[private]
validate-kubernetes:
    bash "{{ template_resources }}/kubeconform.sh" "{{ kubernetes_dir }}"

# Rendering needs the secrets bundle; both renderers generate and
# sops-encrypt one on first run (--confirm=false so topf never prompts
# mid-pipeline). topf.yaml is absent on a provider that launches its own
# nodes, which has nothing for topf to discover or apply to.
[private]
[working-directory('talos')]
validate-talos:
    if [ -f topf.yaml ]; then
        topf render --confirm=false --output "$(mktemp -d)" >/dev/null
    else
        out="$(just talos render "$(mktemp -d)" 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
    fi
    if ! sops filestatus secrets.sops.yaml | jq --exit-status '.encrypted == true' >/dev/null; then
        just log fatal "Talos secrets bundle is not encrypted"
    fi
