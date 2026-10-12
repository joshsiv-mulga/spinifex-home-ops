# Infrastructure

Everything spinifex has to create before there is a cluster: a VPC of its
own, the nodes, the security groups in front of them, the wildcard certificate
and the load balancer that holds it. Rendered from `cluster.toml` by
`just configure`, so the knobs are in `terraform.tfvars` and the config is in
`cluster.toml`.

The VPC's CIDR is `network.node_cidr` from `cluster.toml` — the same range the
machine configs use for the nodes' default gateway and the controller and NFS
addresses. A tenant can hold more than one VPC, so this workspace creates and
owns its own rather than guessing which existing one is the right one.

`.terraform/` and the state file are ignored by git. **The state holds every
node's user-data, which is the whole machine config — its CA keys and its join
token.** Treat it the way you treat `talos/secrets.sops.yaml`.

## Before the first apply

The wildcard certificate is signed by the platform's tenant CA, and nothing
creates that for you. Once per deployment, on a node:

```sh
sudo spx admin cert create-tenant-ca --domain example.com
sudo systemctl restart spinifex-daemon spinifex-awsgw
```

Without it the certificate never leaves `PENDING_VALIDATION` and the apply
stops with that message. The CA is self-signed, so add `/etc/spinifex/tenant-ca.pem`
to the trust store of anything that should reach the cluster without a warning.

## Order

The nodes boot from their machine config, so it has to exist before they launch:

```sh
just configure          # renders this directory and the Talos patches
just bootstrap talos    # writes ../talos/rendered/{controlplane,worker}.yaml
tofu -chdir=tofu init
tofu -chdir=tofu apply
```

`tofu validate` works before the machine configs exist; `apply` does not, and
says so rather than launching a node that would sit in maintenance mode.

## Reaching the cluster

The nodes resolve the API's name themselves, from the fixed addresses in
`controller_addresses` — which is why those addresses are assigned rather than
allocated. Those addresses are private to the cluster's VPC, though; your
machine reaches the API at `controller_endpoint`, by name, so add the entry
before bootstrapping:

```sh
just hosts
just bootstrap cluster "$(tofu -chdir=tofu output -raw hosts_entry | awk '{print $2}')"
```

Applications answer on the load balancer instead, at `edge_lb_dns_name`, which
resolves through the platform's own DNS rather than yours.

## Changing the cluster

Node counts, instance type, region, domain and the admin CIDR all come from
`cluster.toml`. Edit it and re-run `just configure` rather than editing
`terraform.tfvars`, which is overwritten on every render. Changing the controller
count changes the machine config too, so re-run `just bootstrap talos` after it.
