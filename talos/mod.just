set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# renovate: datasource=github-releases depName=siderolabs/talos
talos_version := 'v1.14.0'
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetes_version := 'v1.37.0'

cluster_name := 'kubernetes'
cluster_endpoint := 'https://kubernetes.example.com:6443'
installer := 'factory.talos.dev/metal-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:' + talos_version
install_disk := '/dev/vda'

# There is no node inventory to apply to: spinifex launches nodes with
# their machine config as user-data, so a config is rendered per role and
# every node of that role boots from the same one. The day-2 recipes take the
# address the provider assigned, because only it knows.

[doc('Generate the Talos secrets bundle, encrypted (no-op if it exists)')]
[group('talos')]
secrets:
    if [ -f secrets.sops.yaml ]; then
        exit 0
    fi
    umask 077
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    talosctl gen secrets --output-file "$tmp/secrets.yaml"
    # sops matches its creation rules against the input path, which here is
    # a scratch file outside the repo.
    sops encrypt --filename-override secrets.sops.yaml --output secrets.sops.yaml "$tmp/secrets.yaml"

# The secrets bundle has to exist before the first node boots, since its CA
# is baked into the user-data rather than handed over the network later.
[doc('Render the per-role Talos machine configs')]
[group('talos')]
render output='./rendered': secrets
    shopt -s nullglob
    umask 077
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    sops decrypt --output "$tmp/secrets.yaml" secrets.sops.yaml
    patches=()
    for patch in all/*.yaml;           do patches+=(--config-patch "@$patch"); done
    for patch in control-plane/*.yaml; do patches+=(--config-patch-control-plane "@$patch"); done
    for patch in worker/*.yaml;        do patches+=(--config-patch-worker "@$patch"); done
    mkdir -p "{{ output }}"
    talosctl gen config "{{ cluster_name }}" "{{ cluster_endpoint }}" \
        --with-secrets "$tmp/secrets.yaml" \
        --with-docs=false \
        --with-examples=false \
        --kubernetes-version "{{ kubernetes_version }}" \
        --install-image "{{ installer }}" \
        --install-disk "{{ install_disk }}" \
        --output "{{ output }}" \
        --force \
        "${patches[@]}"

[doc('Show what applying the rendered config would change on a node')]
[group('talos')]
diff-node node role='controlplane': render
    talosctl apply-config --nodes "{{ node }}" --file "./rendered/{{ role }}.yaml" --dry-run

[arg('mode', pattern='auto|reboot|no-reboot|staged|try')]
[doc('Apply the rendered config to a node')]
[group('talos')]
apply-node node role='controlplane' mode='auto': render
    talosctl apply-config --nodes "{{ node }}" --file "./rendered/{{ role }}.yaml" --mode "{{ mode }}"

[doc('Upgrade Kubernetes')]
[group('talos')]
upgrade-k8s node:
    talosctl --nodes "{{ node }}" upgrade-k8s --to "{{ trim_start_match(kubernetes_version, 'v') }}"

[confirm("This will reboot the node into the new Talos version — continue? [y/N]")]
[doc('Upgrade Talos on a single node')]
[group('talos')]
upgrade-node node:
    talosctl --nodes "{{ node }}" upgrade --image "{{ installer }}"
