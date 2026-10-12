# home-ops on Spinifex

A working GitOps homelab — Talos, Flux, and a set of real applications — running
on [Spinifex](https://mulgadc.com/spinifex) instead of on hardware the cluster
has to manage itself.

The point isn't the applications. It's what sits underneath them. In the lab
this was ported from, the cluster ran its own block storage, its own object
store, its own Postgres operator and its own secret plumbing. Here those are
services the cluster calls, and six operators are gone entirely.

## Credits

This repository stands on two pieces of other people's work.

- **[onedr0p/cluster-template](https://github.com/onedr0p/cluster-template)**
  and the [home-operations](https://github.com/home-operations) community, whose
  template this is derived from. If you want to build a Kubernetes homelab and
  you are not specifically interested in Spinifex, go there first — it is the better starting point and it is
  excellent.
- **[philgood/home-ops](https://github.com/philgood/home-ops)**, the lab this
  was ported from, and its owner, who let us take their real, lived-in home-ops repository apart in public. Their configuration, their
  choices, their four thousand commits of accumulated judgement. Everything
  personal to them — domain, credentials, bookmarks, notification integrations —
  has been removed. None of their secrets were copied; every credential here is
  generated fresh.

## What's different from the upstream template

|                 | Upstream template                                | Here                                       |
| --------------- | ------------------------------------------------ | ------------------------------------------ |
| Block storage   | `rook-ceph` + `ceph-csi`                         | EBS, via the upstream `aws-ebs-csi-driver` |
| Object storage  | `garage`                                         | Predastore, over S3                        |
| Postgres        | `cloudnative-pg`                                 | RDS                                        |
| Secrets         | `external-secrets` against a hosted vault        | `sops` with `age`                          |
| Certificates    | `cert-manager` + Let's Encrypt, needs Cloudflare | ACM, from a tenant private CA              |
| Ingress address | Cilium LoadBalancer IPAM                         | ELB                                        |
| Machines        | hardware you rack                                | OpenTofu, ~30 resources                    |

No Cloudflare account, no public DNS, no port forwarding, no registered domain.

Everything in the right-hand column is reached with the standard AWS-targeting
toolchain — the upstream CSI driver chart, OpenTofu's `aws` provider, Talos's own
AWS platform image. Nothing in this repository is patched to know about
Spinifex.

## Layout

```
tofu/          the environment: instances, security groups, ELB, ACM, RDS, NFS
kubernetes/    the applications, reconciled by Flux
talos/         machine config patches
bootstrap/     first-boot: Talos, then Flux
scripts/       preflight.sh, render-secrets.sh, hosts.sh, ca-drift.py
```

The split is the rule worth taking away: **anything the cluster cannot rebuild
by itself lives in `tofu/`. Everything else lives in `kubernetes/` and is Flux's
problem.**

## The applications

Eight, chosen so each one exercises a different part of the platform rather than
to pad a count.

|                         | Exercises                                                      |
| ----------------------- | -------------------------------------------------------------- |
| `echo`                  | Shared listener, ELB, ACM certificate                          |
| `vikunja`               | An EBS claim, snapshotted and backed up to Predastore          |
| `atuin`                 | RDS — its entire state is in Postgres, so a login is the proof |
| `jellyfin`              | NFS from an EC2 instance, backed by a separate EBS volume      |
| `dragonfly`             | A StatefulSet `volumeClaimTemplate`                            |
| `kopia`                 | Predastore as a browsable backup repository                    |
| `kube-prometheus-stack` | Metrics and dashboards                                         |
| `homepage`              | One screen showing the rest                                    |

## Running it

This fork targets a bare-metal [Spinifex](https://docs.mulgadc.com) cluster on
your own LAN, deployed from a workstation on the same network. No Mulga repo,
no Ansible, no SSH to the cluster's hosts — everything below runs from this
checkout.

### 0. A Spinifex cluster

Install Spinifex itself per the public docs — on one node or several:

- <https://docs.mulgadc.com/docs/install> (single node)
- <https://docs.mulgadc.com/docs/install-multi-node>

That gets you a running gateway. This repo needs a handful of things on top of
a plain install, all one-time, all on the cluster rather than in this repo:

- **Public addresses on your LAN.** The Kubernetes API sits behind an Elastic
  IP and the apps behind a load balancer, so the cluster has to be able to
  hand out addresses your workstation can reach. The simplest way is to let
  your router's DHCP assign them (`--external-source=dhcp`); a static range
  reserved out of the router's DHCP scope works too. See
  [VPC networking](https://docs.mulgadc.com/docs/vpc-networking) for both.
- **A tenant CA for your domain**, so ACM can issue the wildcard certificate
  the edge load balancer holds:

    ```sh
    sudo spx admin cert create-tenant-ca --domain <your domain>
    sudo systemctl restart spinifex-daemon spinifex-awsgw
    ```

    The domain list is frozen at creation — widening it later needs
    `--regenerate` and re-trusting the new CA everywhere.

    The restart is how the daemon picks the CA up, and it's only safe on a
    host with **no instances running**: a daemon restart under running guests
    can mark a live one stopped while it keeps running, after which nothing can
    attach a volume to it. Create the CA before the first `tofu apply`, or tear
    down first (see [Tearing it down](#tearing-it-down)).

    On a multi-node cluster, create it on **one** node only, then copy the
    pair to every other node: Spinifex reads it from local disk and doesn't
    replicate it, so a request that lands on a node without it fails with
    `no tenant CA is configured`. On each other node:

    ```sh
    # with /etc/spinifex/tenant-ca.{pem,key} copied over from the first node
    sudo chown root:root /etc/spinifex/tenant-ca.{pem,key}   # same owner as on the first node
    sudo chmod 0644 /etc/spinifex/tenant-ca.pem
    sudo chmod 0600 /etc/spinifex/tenant-ca.key
    sudo systemctl restart spinifex-daemon spinifex-awsgw
    ```

    Don't run `create-tenant-ca` on each node instead: each would mint a
    different CA.

- **Images imported**, on any node, one at a time:
    ```sh
    sudo spx admin images import --name ubuntu-26.04-x86_64     # the NFS instance
    sudo spx admin images import --name spinifex-rds-postgres   # the database
    ```
    The Talos image for the nodes is built from your `schematic_id`, so
    `scripts/preflight.sh` stages and imports that one for you — see step 2.
- **Credentials and the platform CA, copied to this workstation.**
  `spx admin init` writes an AWS profile (named `spinifex` unless you chose
  otherwise) on the node it ran on. Copy its `~/.aws/credentials` here, and
  the CA the gateway serves with:
    ```sh
    scp <a node>:/etc/spinifex/ca.pem spinifex-ca.pem
    ```
    Only the credentials are used. The profile's endpoint and CA path point at
    the node itself; the scripts and `tofu` take the gateway address and CA
    from `cluster.toml` and `spinifex-ca.pem` instead.
- **Tools**, via [mise](https://mise.jdx.dev): `mise install` installs
  everything in `.mise/config.toml`, including the AWS CLI this repo's
  scripts and `tofu` need. mise also sets the environment the `just` recipes
  rely on (`SOPS_AGE_KEY_FILE`, `KUBECONFIG`, `TALOSCONFIG`, ...), which only
  happens once the config is trusted and mise is activated in your shell:
    ```sh
    mise trust                                     # from the repo root
    echo 'eval "$(mise activate zsh)"' >> ~/.zshrc # or bash; once per machine
    exec zsh
    mise install
    echo "$SOPS_AGE_KEY_FILE"                      # should print <repo>/age.key
    ```
    If it prints nothing, `just init` fails with `SOPS_AGE_KEY_FILE: unbound
variable`; `mise doctor` shows what's missing.

Nothing below asks you to repeat any of this.

### 1. Settings, and the keys to encrypt with

Copy `cluster.sample.toml` to `cluster.toml` and fill it in — your domain, the
gateway and Predastore URLs, the admin CIDR, how many nodes. The settings that
catch people out:

- **`[repository] url`** — the `ssh://git@…` form if the repo is private, with
  `deploy.key.pub` (written by `just init`) added to the repo as a read-only
  deploy key. An `https://` URL to a private repo only fails much later, as a
  FluxInstance that never becomes ready.
- **`[repository] branch`** — a branch of this cluster's own, e.g.
  `cluster/<name>`. `main` carries the shared template; your cluster's
  encrypted secrets live on the branch Flux watches (step 4).
- **`[spinifex] controllers`** — odd, and no more than the Spinifex cluster's
  physical hosts: the controllers are spread one per host. On a small platform,
  controllers equal to the host count with no workers is the usual shape.
- **`[spinifex] instance_type`** — `t3.medium` carries the apps across three
  controllers once they settle; `t3.large` gives headroom if every host has the
  memory for one.
- **`[domain] name`** — a subdomain of a domain you own (e.g.
  `lab.example.com`) lets you publish the cluster's addresses in public DNS in
  step 5, so no machine needs `/etc/hosts` edits. Any name works if you'd
  rather use `/etc/hosts`. The tenant CA from step 0 has to cover it.

Then:

```sh
just init        # generates an age key, a Flux deploy key, a webhook token
just configure    # renders terraform.tfvars and the Talos machine config patches
```

### 2. Pre-flight

```sh
./scripts/preflight.sh
```

Checks the platform CA you copied over is in place and writes it into the
manifests that need it, checks the credentials profile works, checks Flux will
be able to clone `[repository] url` with exactly the access it will have, and
imports the Talos image your `schematic_id` describes — automatically if you set
`spinifex.ssh_host` in `cluster.toml`, otherwise it prints the exact command to
run by hand. Idempotent, and it prints what it cannot do itself rather than
failing quietly.

### 3. Machine configs, then the environment

```sh
just bootstrap talos
cd tofu && tofu init && tofu apply
```

`bootstrap talos` has to run first: the nodes launch with their machine config
as user-data, and `tofu apply` refuses to launch one without it. The apply
itself creates instances, security groups, the load balancer, the certificate,
the database, the NFS server, and the bucket and identity volsync backs up to.

### 4. Secrets, on your cluster's branch

```sh
./scripts/render-secrets.sh       # endpoints and credentials, from tofu's outputs
git switch -c cluster/<name>      # the branch you set in cluster.toml
git add -A kubernetes bootstrap/helmfile talos/secrets.sops.yaml
git commit -m 'chore: my cluster'
```

Check every secret went in encrypted before pushing — each line should end in
`true`:

```sh
git diff --name-only origin/main | grep 'sops.yaml$' \
  | xargs -I{} sh -c 'echo "{}: $(sops filestatus {} | jq .encrypted)"'
git push -u origin cluster/<name>
```

Flux clones that branch, so it has to be pushed before the cluster starts.
Never push it to `main`: the secrets are encrypted to your age key, and any
other cluster built from `main` would fail to decrypt them.
`talos/secrets.sops.yaml` is the cluster's Talos CA and join tokens; the branch
is its backup, so keep it there.

`render-secrets.sh` keeps any password already in the file, so re-running it
after a rebuild never orphans the backup repository.

### 5. The cluster

The bootstrap reaches the controller by name, `kubernetes.<your domain>`: the
nodes' own addresses are private to their VPC, and the Talos API's certificate
names that host, not the address in front of it. So the names have to resolve
first, one of two ways:

- **Public DNS**, if `[domain] name` is under a domain you own. Publish the
  addresses `just hosts --print` shows — `kubernetes.<domain>` to the
  controller's Elastic IP, `*.<domain>` to the load balancer, `media.<domain>`
  to the NFS server. Public DNS answering with private addresses works for
  anything on the same LAN, unless its resolver has DNS-rebinding protection,
  so check one name resolves before relying on it. The addresses change on
  every rebuild; update the records each time.
- **`/etc/hosts`** otherwise: `just hosts` writes them into a marked block it
  replaces on every run (it asks for sudo; `just hosts --print` only shows
  them). Needed on every machine that reaches the cluster.

```sh
just bootstrap cluster "$(cd tofu && tofu output -raw hosts_entry | awk '{print $2}')"
just bootstrap apps
```

The nodes report `NotReady` until `bootstrap apps` installs Cilium; that's
expected. Flux then brings everything up in dependency order, two reconciles at
a time. That is slower than all at once, deliberately: a burst of parallel
image pulls stalls etcd's disk writes on Spinifex block storage. Allow 20–30
minutes on a fresh cluster; `flux get ks -A | grep -v True` shows what's still
waiting, and on what.

### 6. Reach it

Trust the platform's tenant CA — `/etc/spinifex/tenant-ca.pem` from a node —
in your browsing machine's trust store, or every page warns. `just secrets`
prints every login.

## Picking up changes from `main`

Don't rebase your cluster branch onto `main`: nearly everything on it is
generated, and generated files conflict with every template change. Rebuild the
branch instead, keeping the two files that can't be regenerated and
re-rendering the rest:

```sh
git fetch
git switch -f cluster/<name>
git reset --hard origin/main
git checkout origin/cluster/<name> -- talos/secrets.sops.yaml \
  kubernetes/components/sops/cluster-secrets.sops.yaml
just configure
./scripts/preflight.sh            # writes your platform CA back into the manifests
git add -A kubernetes bootstrap/helmfile talos/secrets.sops.yaml
git commit -m 'chore: my cluster'
git push --force-with-lease origin cluster/<name>
```

A change that only touches `tofu/*.tf` or `scripts/` needs none of this: those
aren't generated, so `git cherry-pick <commit>` onto the branch is enough.

## Tearing it down

Kubernetes creates EBS volumes and snapshots of its own, outside tofu. They're
deleted with their claims, but only while the cluster is still running; run
`tofu destroy` first and every one of them is orphaned. So empty the cluster,
then the bucket, then destroy:

```sh
# 0. Anything you want to keep: copy media off the SMB share.
#    The backups bucket is deleted below.

# 1. stop Flux, and the charts it installed, putting things back
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  flux suspend ks --all -n "$ns" 2>/dev/null; flux suspend hr --all -n "$ns" 2>/dev/null
done

# 2. delete what holds volumes, so the CSI driver deletes them on the platform.
#    Operator-owned resources first, or the operators recreate their StatefulSets;
#    volumes before snapshots, because a volume restored from a snapshot keeps
#    that snapshot in use and its deletion waits.
kubectl delete replicationsource,replicationdestination -A --all
kubectl delete dragonfly,prometheus,alertmanager -A --all
for ns in default observability storage; do kubectl -n "$ns" delete deploy,sts --all; done
kubectl delete pvc -A --all
kubectl delete volumesnapshot -A --all --wait=false
kubectl get pv,volumesnapshot,volumesnapshotcontent -A   # wait until all are empty

# 3. empty the backups bucket (destroy refuses a non-empty one)
aws s3 rm "s3://$(tofu -chdir=tofu output -raw volsync_bucket)" --recursive \
  --endpoint-url "https://$(tofu -chdir=tofu output -raw s3_endpoint)" --ca-bundle spinifex-ca.pem

# 4. destroy
cd tofu && tofu destroy
```

Then check nothing's left: `aws ec2 describe-volumes`, `describe-snapshots
--owner-ids self`, `describe-instances` and `describe-addresses` should show
nothing of this cluster's, and on each Spinifex host `ps -eo cmd | grep i-`
should show none of its guests still running. Finally remove the `just hosts`
block from `/etc/hosts`, or the DNS records, wherever you added them.

If `tofu destroy` stops on the IAM user with `DeleteConflict` while every
`aws iam list-*` for that user comes back empty, that's a Spinifex bug: the
user's record keeps IDs of access keys that no longer exist, and no list shows
them. They also count towards the two-keys-per-user limit, so dropping the user
from state and importing it on the next build doesn't help — that apply fails
creating a new key. Delete the stale IDs instead. Every key earlier builds made
is still in tofu's state backups and in the history of `cluster-secrets`:

```sh
U=<cluster_name>-volsync
{ for f in tofu/terraform.tfstate*; do
    jq -r '.resources[]? | select(.type=="aws_iam_access_key") | .instances[].attributes.id' "$f" 2>/dev/null
  done
  for c in $(git rev-list --all --reflog -- kubernetes/components/sops/cluster-secrets.sops.yaml); do
    git show "$c:kubernetes/components/sops/cluster-secrets.sops.yaml" \
      | sops -d --input-type yaml --output-type yaml /dev/stdin 2>/dev/null \
      | awk '$1=="VOLSYNC_KEY_ID:" {print $2}'
  done; } | sort -u | while read -r k; do
  aws iam delete-access-key --user-name "$U" --access-key-id "$k"   # NoSuchEntity is fine
done
aws iam delete-user --user-name "$U"
cd tofu && tofu destroy
```

## When something goes wrong

Most failures on a fresh build came from the platform, not this repo. What they
looked like, and what got past them:

| Symptom                                                                                                              | Cause                                                                                                  | Way past it                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RequestCertificate … no tenant CA is configured`                                                                    | The tenant CA exists only on the node it was created on                                                | Copy the pair to every node (step 0)                                                                                                                                              |
| Bootstrap stuck on "Talos API not answering"                                                                         | Stale `/etc/hosts` or DNS after a rebuild changed the Elastic IP                                       | `just hosts`, or update the DNS record; the retry line shows the real error                                                                                                       |
| FluxInstance never ready: `authentication required`                                                                  | Private repo behind an `https://` URL, or the deploy key missing                                       | `ssh://` URL plus the deploy key (step 1); preflight checks this                                                                                                                  |
| EBS CSI: `lookup ec2.<region>.services.internal … no such host`                                                      | The platform's DNS zone for its service names is unreadable in Predastore, so DNS reconciliation stops | On a host, find the failing object (`journalctl -u spinifex-predastore \| grep '"S3 request failed"'`) and delete it from the `northstar` bucket; it's rebuilt from desired state |
| EBS CSI: `x509: certificate signed by unknown authority`                                                             | The CA manifests carry another cluster's CA                                                            | `./scripts/preflight.sh`, commit, push                                                                                                                                            |
| `AttachVolume … IncorrectInstanceState` on one node                                                                  | A daemon restart marked a running guest stopped                                                        | Drain the node, kill that guest's `qemu` on its host, `aws ec2 start-instances`                                                                                                   |
| `tofu destroy` stops on the volsync IAM user with `DeleteConflict`                                                   | Its record keeps IDs of keys that no longer exist                                                      | Delete the stale key IDs, then the user ([Tearing it down](#tearing-it-down))                                                                                                     |
| `tofu apply` hangs creating a controller; daemon logs `no responders available` for `ec2.RunInstances.<type>.<host>` | That host never subscribed to the instance type after it restarted                                     | Launch and terminate a `t3.micro` so the host re-checks its capacity, then apply again                                                                                            |
| API slow or dropping; etcd logs `slow fdatasync`                                                                     | Block storage stalls writes during bursts of image pulls                                               | Wait for the pulls to finish; Flux's low concurrency keeps it from recurring                                                                                                      |
| `HelmRelease … upgrade failed … deadline` after a slow spell                                                         | A leftover failure from that spell                                                                     | `flux reconcile hr <name> -n <ns> --force`                                                                                                                                        |

Don't restart `spinifex-daemon` on a host with running guests to fix any of
these: that restart is what causes the `IncorrectInstanceState` row.

## Things worth knowing

- **`just secrets` prints every login in one place** — Grafana, the media
  share, the database, the backup repository — read from tofu's outputs and
  the sops-encrypted `cluster-secrets`. It prints them in the clear, so mind
  where you run it.

- **Media goes in over SMB.** Jellyfin reads the library read-only over NFS;
  from a desktop on `admin_cidr`, connect to `smb://media.<your domain>/media`
  as user `media`, with the password `just secrets` prints. Titles go under
  `movies/`, `tv/` and `music/`, one folder per title.

- **Volume expansion is offline.** Getting a claim's size wrong the first time
  means deleting and restoring it, not growing it in place.
- **Anything generated says so in its first line.** The CA manifests and
  `cluster-secrets` are written by the scripts above from your own cluster; edit
  the source, not the output.
- **Hardware transcoding is not configured.** The original lab passed an Intel
  iGPU to `jellyfin`; there's no GPU in the hosts this was built on, so
  transcoding runs on the CPU.
- **A `HelmRelease` reporting `Ready` means the chart installed**, not that the
  application works. Three of these were green in Flux while serving nothing.
  Check status codes.

## Licence

The template this forks is MIT, and so is this. See [LICENSE](./LICENSE).
