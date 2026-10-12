# Talos Patching

Machine configs are assembled by `talosctl gen config` from the secrets bundle in
`secrets.sops.yaml` plus the strategic merge patches in this directory, and written
to `rendered/` by `just talos render`.

spinifex launches nodes with their machine config as user-data, so there is one
config per role rather than one per node: `rendered/controlplane.yaml` and
`rendered/worker.yaml` are what a new node of that role boots from.

<https://www.talos.dev/latest/talos-guides/configuration/patching/>

## Patch Directories

Patches merge in this order, alphabetically within each directory, with later
patches taking precedence:

- `all/`: applied to every node
- `control-plane/`: applied to control-plane nodes
- `worker/`: applied to worker nodes

Three patches carry the domain and the node addresses (`all/10-cluster.yaml`,
`all/81-hosts.yaml`, `control-plane/00-cluster.yaml`), so they're rendered from
`cluster.toml` by `just configure` rather than committed — re-run it after a
fresh clone, before `just bootstrap talos`.
