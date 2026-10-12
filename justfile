set quiet
set minimum-version := '1.55.1'
set default-list
set default-script
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[group('bootstrap')]
mod? bootstrap 'bootstrap'

[group('kubernetes')]
mod? kube 'kubernetes'

[group('talos')]
mod? talos 'talos'

# Positional, so a value with spaces (an error message) stays one argument
# rather than being split into key=value pairs.
[positional-arguments]
[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "$1" "$2" "${@:3}"

[doc('Print every login and credential this cluster has (tofu outputs + cluster-secrets)')]
[group('bootstrap')]
secrets:
    bash scripts/secrets.sh

[doc('Write /etc/hosts lines for the API and the apps (after tofu apply); --print to only show them')]
[group('bootstrap')]
hosts *args:
    bash scripts/hosts.sh {{ args }}

# === template ===

[group('template')]
mod template 'template'

[doc('Render and validate configuration files')]
[group('template')]
configure:
    just template configure

[doc('Initialize configuration files (cluster.toml, age key, deploy key, webhook token)')]
[group('template')]
init:
    just template init
