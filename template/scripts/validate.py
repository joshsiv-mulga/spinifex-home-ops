"""Validate cluster.toml, apply defaults, and emit the config as JSON.

Standalone usage (doctor, CI): uv run --locked --no-dev template/scripts/validate.py [cluster.toml]
Schema export (just template schema): uv run --locked --no-dev template/scripts/validate.py --schema
In-process usage (makejinja plugin): from validate import load

Exits non-zero with one human-readable error per line on stderr when the
config is invalid.
"""

from ipaddress import IPv4Address, IPv4Network
from pathlib import Path
from typing import Annotated, Any, Literal, Self

import json
import re
import sys
import tomllib

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    ValidationError,
    computed_field,
    model_validator,
)

# Git hosts whose SSH host keys are bundled with the template; ssh:// URLs
# pointing anywhere else must provide repository.known_hosts.
KNOWN_SSH_HOSTS = ["github.com", "gitlab.com", "codeberg.org"]

REPO_URL_PATTERN = r"^(https?://|ssh://git@)[^/]+/.+$"
GATEWAY_URL_PATTERN = r"https://[a-z0-9][a-z0-9.-]*:[0-9]{1,5}"
FQDN_PATTERN = r"^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$"

# How traffic reaches the cluster from outside, given who owns the records.
INGRESS_DEFAULTS = {
    "cloudflare": "cloudflare-tunnel",
    "spinifex": "direct",
    "none": "none",
}


def _network(value: Any) -> Any:
    """Parse a CIDR, requiring network-address form (no host bits set)."""
    if not isinstance(value, str):
        return value
    try:
        return IPv4Network(value)
    except ValueError:
        try:
            fixed = IPv4Network(value, strict=False)
        except ValueError:
            raise ValueError(f"{value!r} is not a valid IPv4 CIDR") from None
        raise ValueError(
            f"{value!r} has host bits set; did you mean {fixed}?"
        ) from None


def _asn(value: str) -> str:
    if value == "":
        return value
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError(f"{value!r} must be a decimal ASN")
    if not 1 <= int(value) <= 4294967295:
        raise ValueError(f"{value!r} must be in the range 1-4294967295")
    return value


type Cidr = Annotated[IPv4Network, BeforeValidator(_network)]
type Asn = Annotated[str, AfterValidator(_asn)]
type Fqdn = Annotated[str, Field(pattern=FQDN_PATTERN)]
type NodePort = Annotated[int, Field(ge=30000, le=32767)]


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Network(Model):
    node_cidr: Cidr
    dns_servers: list[IPv4Address] = [IPv4Address("1.1.1.1"), IPv4Address("1.0.0.1")]
    ntp_servers: list[IPv4Address] = [IPv4Address("162.159.200.1"), IPv4Address("162.159.200.123")]
    # The first IP in node_cidr unless set explicitly.
    default_gateway: IPv4Address = Field(
        default_factory=lambda data: data["node_cidr"].network_address + 1
    )
    vlan_tag: str | None = Field(default=None, pattern=r"^[0-9]+$")

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.default_gateway not in self.node_cidr:
            raise ValueError(
                f"default_gateway {self.default_gateway} is not inside node_cidr {self.node_cidr}"
            )
        if self.vlan_tag is not None and not 1 <= int(self.vlan_tag) <= 4094:
            raise ValueError(f"vlan_tag {self.vlan_tag} must be in the range 1-4094")
        return self


class Api(Model):
    # A floating VIP inside node_cidr. Declared for bare-metal; on a provider
    # the API server sits behind a load balancer and is reached by name.
    addr: IPv4Address | None = None
    # The name the load balancer answers on. Defaults to kubernetes.<domain>.
    host: Fqdn | None = None
    tls_sans: list[Fqdn] | None = None


class Kubernetes(Model):
    pod_cidr: Cidr = IPv4Network("10.42.0.0/16")
    svc_cidr: Cidr = IPv4Network("10.43.0.0/16")
    # The 10th IP in svc_cidr unless set explicitly.
    coredns_addr: IPv4Address = Field(
        default_factory=lambda data: data["svc_cidr"].network_address + 10
    )
    api: Api = Api()

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.coredns_addr not in self.svc_cidr:
            raise ValueError(
                f"coredns_addr {self.coredns_addr} is not inside svc_cidr {self.svc_cidr}"
            )
        return self


# LAN addresses Cilium announces over L2 or BGP. Required for bare-metal and
# absent on a provider, where the same traffic arrives through a load
# balancer pointed at a node port.
class Gateways(Model):
    internal: IPv4Address | None = None
    dns: IPv4Address | None = None
    # Required when ingress.mode is not "none".
    external: IPv4Address | None = None


class Repository(Model):
    url: str = Field(pattern=REPO_URL_PATTERN)
    branch: str = Field(default="main", min_length=1)
    webhook_provider: Literal["github", "gitlab", "generic-hmac", "none"] = "github"
    known_hosts: str = ""

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.url.startswith("ssh://"):
            host = self.url.removeprefix("ssh://git@").split("/", 1)[0].split(":", 1)[0]
            if host not in KNOWN_SSH_HOSTS and not self.known_hosts:
                raise ValueError(
                    f"known_hosts is required for ssh:// URLs to {host!r} "
                    f"(host keys are only bundled for {', '.join(KNOWN_SSH_HOSTS)})"
                )
        return self


class Domain(Model):
    name: Fqdn


class Dns(Model):
    # "spinifex" points the records at northstar and the certificates at ACM,
    # neither of which takes a token: the API is reached with the same SigV4
    # credentials as every other call.
    provider: Literal["cloudflare", "spinifex", "none"] = "cloudflare"
    token: str = ""

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.provider == "cloudflare" and not self.token:
            raise ValueError("token is required when dns.provider is 'cloudflare'")
        if self.provider != "cloudflare" and self.token:
            raise ValueError(f"token must be empty when dns.provider is {self.provider!r}")
        return self


class Ingress(Model):
    mode: Literal["cloudflare-tunnel", "direct", "none"] = "cloudflare-tunnel"


class Bgp(Model):
    router_addr: IPv4Address | Literal[""] = ""
    router_asn: Asn = ""
    node_asn: Asn = ""

    @model_validator(mode="after")
    def check(self) -> Self:
        unset = [name for name in ("router_addr", "router_asn", "node_asn") if getattr(self, name) == ""]
        if unset and len(unset) < 3:
            raise ValueError(
                "bgp is partially configured: set router_addr, router_asn and "
                f"node_asn together (missing: {', '.join(unset)})"
            )
        return self


class Talos(Model):
    # Default Image Factory schematic for nodes that don't set their own.
    schematic_id: str | None = Field(default=None, pattern=r"^[a-z0-9]{64}$")


class Spegel(Model):
    # True when the cluster has more than one node, unless set explicitly.
    enabled: bool | None = None


class Cilium(Model):
    # Defaulted per provider rather than here: dsr returns a reply straight to
    # the client from whichever node holds the backend, which a tunnel cannot
    # carry. Routing mode follows the provider, so this has to as well.
    loadbalancer_mode: Literal["dsr", "snat"] | None = None
    bgp: Bgp = Bgp()


class Spinifex(Model):
    region: str = Field(default="ap-southeast-2", pattern=r"^[a-z]{2}-[a-z]+-[0-9]$")
    # Where this host reaches the API, which is not always where a guest does:
    # tofu calls the gateway from outside the tenant network.
    gateway_url: str = ""
    # Predastore's own endpoint. Object storage answers separately from the
    # gateway, on its own port.
    s3_url: str = ""
    # The only network boundary the cluster has. The platform has no public
    # exposure of its own, so nothing else stands between it and a caller.
    admin_cidr: str = ""
    # Shared-credentials profile carrying the access keys for the
    # environment. Cluster bootstrap writes this profile on the node; copy it
    # to the workstation rather than using the bare "spinifex" dev profile.
    aws_profile: str = "spinifex"
    # Prefix for the resources tofu creates, so one environment can carry more
    # than one cluster. Node names are generated from it too.
    cluster_name: str = Field(default="k8s", pattern=r"^[a-z][a-z0-9-]{0,20}$")
    instance_type: str = Field(default="t3.medium", pattern=r"^[a-z][a-z0-9]*\.[a-z0-9]+$")
    # Root disk for every node, in GiB. An image is unpacked onto it, and the
    # AMI's own size leaves nowhere near enough room for container images.
    node_disk_size: int = Field(default=40, ge=20)
    # Node names are generated as k8s-0, k8s-1, ... with controllers first.
    controllers: int = Field(default=1, ge=1, le=9)
    workers: int = Field(default=0, ge=0, le=99)
    # Where a Talos upgrade reinstalls to. Not an install target for the
    # first boot: the image arrives already installed on the root volume.
    install_disk: str = Field(default="/dev/vda", pattern=r"^/dev/[a-z0-9/]+$")
    # Optional: lets `scripts/preflight.sh` stage and import the Talos image
    # over SSH on a node that already has it reachable. Left unset, the
    # script prints the manual `spx admin images import` command instead.
    ssh_host: str = ""
    ssh_user: str = ""
    ssh_key: str = ""
    # Node ports the ELBv2 target groups forward to, one per gateway. Pinned
    # rather than allocated, because the load balancer is created before the
    # cluster that would allocate them exists, and one per gateway because a
    # node port belongs to a single Service.
    external_node_port: NodePort = 30080
    internal_node_port: NodePort = 30081
    # Where k8s-gateway answers. Pinned for the same reason: whatever resolver
    # forwards the zone here has the port written into its config, so it has
    # to survive a redeploy.
    dns_node_port: NodePort = 30053
    # Where the EC2 API answers, for a gateway that is not on the name its own
    # services domain advertises. Defaults to that name, which resolves from
    # inside the cluster through IMDS.
    endpoint: str = ""

    # The endpoint the EBS CSI controller dials. Spelled out in full because
    # the SDK builds endpoints from its compiled-in partition table rather
    # than from the services domain IMDS hands out, and never guesses a port.
    @computed_field
    @property
    def ec2_endpoint(self) -> str:
        return self.endpoint or f"https://ec2.{self.region}.services.internal:9999"

    @model_validator(mode="after")
    def check(self) -> Self:
        for name in ("endpoint", "gateway_url", "s3_url"):
            value = getattr(self, name)
            if value and not re.fullmatch(GATEWAY_URL_PATTERN, value):
                raise ValueError(
                    f"{name} {value!r} must be an https URL with an explicit "
                    "port, e.g. 'https://ec2.example.internal:9999'"
                )
        if self.admin_cidr:
            _network(self.admin_cidr)
            if self.admin_cidr == "0.0.0.0/0":
                raise ValueError(
                    "admin_cidr must not be 0.0.0.0/0: it is the only network "
                    "boundary the cluster has"
                )
        if self.controllers % 2 == 0:
            raise ValueError(
                f"controllers must be odd for etcd quorum, got {self.controllers}"
            )
        if self.ssh_host and not self.ssh_user:
            raise ValueError(
                "ssh_user is required when ssh_host is set: the image-import "
                "helper has to know who to log in as"
            )
        ports = {
            "external_node_port": self.external_node_port,
            "internal_node_port": self.internal_node_port,
            "dns_node_port": self.dns_node_port,
        }
        seen: dict[int, str] = {}
        for name, port in ports.items():
            if port in seen:
                raise ValueError(f"node port {port} is used by both {seen[port]} and {name}")
            seen[port] = name
        return self


class Node(Model):
    name: str = Field(pattern=r"^[a-z0-9][a-z0-9\-]{0,61}[a-z0-9]$|^[a-z0-9]$")
    # address, disk and mac_addr identify a machine that already exists, so
    # they are required for bare-metal and absent on a provider that launches
    # its nodes: the address is assigned at launch, and there is no MAC to
    # discover because the config arrives as user-data rather than by apply.
    address: IPv4Address | None = None
    controller: bool
    disk: str | None = None
    mac_addr: str | None = Field(default=None, pattern=r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")
    # Falls back to talos.schematic_id when unset.
    schematic_id: str | None = Field(default=None, pattern=r"^[a-z0-9]{64}$")
    mtu: int = Field(default=1500, ge=1450, le=9000)
    secureboot: bool = False
    encrypt_disk: bool = False
    kernel_modules: list[str] = []

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.name in ("global", "controller", "worker"):
            raise ValueError(f"node name {self.name!r} is reserved")
        return self


class Config(Model):
    model_config = ConfigDict(extra="forbid", title="cluster.toml")

    # Where the cluster runs. "bare-metal" is the upstream behaviour: nodes are
    # physical machines declared one by one in [[nodes]]. "spinifex" targets an
    # AWS-compatible API, where nodes are launched rather than described.
    provider: Literal["bare-metal", "spinifex"] = "bare-metal"
    network: Network
    kubernetes: Kubernetes = Kubernetes()
    gateways: Gateways = Gateways()
    repository: Repository
    domain: Domain
    dns: Dns
    # Defaults to "cloudflare-tunnel" when dns.provider is "cloudflare" and
    # "direct" when it is "spinifex", where the load balancer is the tunnel's
    # job: it holds the certificate and is the only way in.
    ingress: Ingress = Field(
        default_factory=lambda data: Ingress(
            mode=INGRESS_DEFAULTS[data["dns"].provider]
        )
    )
    cilium: Cilium = Cilium()
    talos: Talos = Talos()
    spegel: Spegel = Spegel()
    spinifex: Spinifex = Spinifex()
    # Declared for bare-metal, derived from [spinifex] otherwise.
    nodes: list[Node] = []

    @computed_field
    @property
    def cilium_bgp_enabled(self) -> bool:
        bgp = self.cilium.bgp
        return bgp.router_addr != "" and bgp.router_asn != "" and bgp.node_asn != ""

    # Replica counts for control-plane-only workloads key off this rather
    # than len(nodes); a cluster can have many workers but one controller.
    @computed_field
    @property
    def controller_count(self) -> int:
        return sum(1 for node in self.nodes if node.controller)

    @computed_field
    @property
    def cluster_issuer(self) -> str:
        if self.dns.provider == "cloudflare":
            return "letsencrypt-production"
        return "internal-ca"

    # Whether the cluster issues its own certificates. With ACM the
    # certificate belongs to the load balancer listener, which terminates TLS
    # before the cluster sees the request, so there is nothing left for
    # cert-manager to hold.
    @computed_field
    @property
    def cert_manager_enabled(self) -> bool:
        return self.dns.provider != "spinifex"

    # The control-plane addresses, pinned rather than assigned. The API is
    # reached by a name, and nothing can publish that name before the nodes
    # exist, so the name is resolved from the machine config itself — which
    # means the address has to be known before the node is launched. Offset
    # from the base to leave the low addresses to whatever the platform hands
    # out. Empty on bare-metal, where the nodes declare their own addresses.
    @computed_field
    @property
    def controller_addrs(self) -> list[str]:
        if self.provider == "bare-metal":
            return []
        base = self.network.node_cidr.network_address + 10
        return [str(base + i) for i in range(self.spinifex.controllers)]

    # The NFS server's address, pinned for the same reason the controllers
    # are: applications name it in their mounts, and a rebuild that moved it
    # would break every one. Offset well clear of the controller range (which
    # tops out at +18 for the maximum 9 controllers) rather than a fixed
    # address, so it still lands inside a non-default node_cidr.
    @computed_field
    @property
    def nfs_addr(self) -> str:
        if self.provider == "bare-metal":
            return ""
        return str(self.network.node_cidr.network_address + 30)

    # Where the API server answers: a VIP on bare-metal, the load balancer's
    # name on a provider. Exactly one of the two is set by the time this runs.
    @property
    def _api_target(self) -> str:
        api = self.kubernetes.api
        return str(api.addr) if api.addr is not None else str(api.host)

    # Single source for the machine and apiServer certificate SAN lists,
    # which live in separate patch files.
    @computed_field
    @property
    def cert_sans(self) -> list[str]:
        return ["127.0.0.1", self._api_target, *(self.kubernetes.api.tls_sans or [])]

    # What every client and every node dials for the Kubernetes API.
    @computed_field
    @property
    def api_endpoint(self) -> str:
        return f"https://{self._api_target}:6443"

    # Generate the node list from instance counts. Controllers come first so
    # the names are stable as workers are added or removed.
    def _derive_nodes(self) -> None:
        total = self.spinifex.controllers + self.spinifex.workers
        self.nodes = [
            Node(
                name=f"{self.spinifex.cluster_name}-{i}",
                controller=i < self.spinifex.controllers,
            )
            for i in range(total)
        ]

    @model_validator(mode="after")
    def check(self) -> Self:
        if self.provider == "spinifex":
            if self.nodes:
                raise ValueError(
                    "nodes must not be declared when provider is 'spinifex': "
                    "set spinifex.controllers and spinifex.workers instead"
                )
            self._derive_nodes()
            # A VIP is announced over L2 or BGP from inside the node network.
            # Neither reaches a provider's load balancer, and pinning the API
            # to an address reintroduces the ordering problem the name solves.
            if self.kubernetes.api.addr is not None:
                raise ValueError(
                    "kubernetes.api.addr must not be set when provider is 'spinifex': "
                    "the API server is reached by name through a load balancer, "
                    "set kubernetes.api.host or leave it to default"
                )
            for name in ("internal", "dns", "external"):
                if getattr(self.gateways, name) is not None:
                    raise ValueError(
                        f"gateways.{name} must not be set when provider is 'spinifex': "
                        "a load balancer forwards to a node port instead"
                    )
            if self.cilium_bgp_enabled:
                raise ValueError(
                    "cilium.bgp must not be set when provider is 'spinifex': "
                    "there is no router to peer with"
                )
            if self.kubernetes.api.host is None:
                self.kubernetes.api.host = f"kubernetes.{self.domain.name}"
            # The link-local VPC resolver, which answers for the platform's own
            # names — the EC2 endpoint the storage driver dials is one of them.
            # A public resolver knows none of them, so it is the wrong default
            # here even though it is the right one on a LAN.
            if "dns_servers" not in self.network.model_fields_set:
                self.network.dns_servers = [IPv4Address("169.254.169.253")]
            # Pod traffic rides a vxlan tunnel here, because native routing
            # needs the VPC route tables to carry the pod CIDRs and nothing
            # sets that up. Cilium refuses to start when dsr is asked for on
            # top of a tunnel: "Node Port \"dsr\" mode cannot be used with
            # vxlan tunneling."
            if self.cilium.loadbalancer_mode is None:
                self.cilium.loadbalancer_mode = "snat"
            elif self.cilium.loadbalancer_mode == "dsr":
                raise ValueError(
                    "cilium.loadbalancer_mode 'dsr' cannot be used when provider "
                    "is 'spinifex': pod traffic is tunnelled, and Cilium refuses "
                    "dsr on top of vxlan"
                )
            # Nothing can be launched without knowing where the API answers,
            # where objects land, and who is allowed to reach what it launches.
            for name in ("gateway_url", "s3_url", "admin_cidr"):
                if not getattr(self.spinifex, name):
                    raise ValueError(
                        f"spinifex.{name} is required when provider is 'spinifex'"
                    )
        else:
            # Native routing, so a reply can leave the node that holds the
            # backend directly.
            if self.cilium.loadbalancer_mode is None:
                self.cilium.loadbalancer_mode = "dsr"
            if self.dns.provider == "spinifex":
                raise ValueError(
                    "dns.provider 'spinifex' requires provider 'spinifex': "
                    "northstar and ACM are reached with the same credentials "
                    "as the rest of the API"
                )
            if not self.nodes:
                raise ValueError("at least one node is required")
            for i, node in enumerate(self.nodes):
                for field in ("address", "disk", "mac_addr"):
                    if getattr(node, field) is None:
                        raise ValueError(
                            f"nodes[{i}].{field} is required when provider is 'bare-metal'"
                        )
            if self.kubernetes.api.addr is None:
                raise ValueError(
                    "kubernetes.api.addr is required when provider is 'bare-metal'"
                )
            for name in ("internal", "dns"):
                if getattr(self.gateways, name) is None:
                    raise ValueError(
                        f"gateways.{name} is required when provider is 'bare-metal'"
                    )

        if self.spegel.enabled is None:
            self.spegel.enabled = len(self.nodes) > 1
        for i, node in enumerate(self.nodes):
            if node.schematic_id is None:
                node.schematic_id = self.talos.schematic_id
            if node.schematic_id is None:
                raise ValueError(
                    f"nodes[{i}].schematic_id is required: set it on the node "
                    "or set a cluster-wide default in [talos]"
                )
        if self.ingress.mode == "cloudflare-tunnel" and self.dns.provider != "cloudflare":
            raise ValueError(
                "ingress.mode 'cloudflare-tunnel' requires dns.provider 'cloudflare'"
            )
        if self.ingress.mode != "none" and self.dns.provider == "none":
            raise ValueError(
                f"ingress.mode {self.ingress.mode!r} requires a dns.provider: "
                "nothing would publish the record that reaches the gateway"
            )
        # The provider's own load balancer is the external address, so there
        # is no VIP to announce and nothing to declare here.
        if (
            self.ingress.mode != "none"
            and self.provider == "bare-metal"
            and self.gateways.external is None
        ):
            raise ValueError(
                f"gateways.external is required when ingress.mode is {self.ingress.mode!r}"
            )

        cidrs = {
            "network.node_cidr": self.network.node_cidr,
            "kubernetes.pod_cidr": self.kubernetes.pod_cidr,
            "kubernetes.svc_cidr": self.kubernetes.svc_cidr,
        }
        names = list(cidrs)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                if cidrs[a].overlaps(cidrs[b]):
                    raise ValueError(f"{a} {cidrs[a]} overlaps {b} {cidrs[b]}")

        addresses = {
            "kubernetes.api.addr": self.kubernetes.api.addr,
            "gateways.internal": self.gateways.internal,
            "gateways.dns": self.gateways.dns,
            "gateways.external": self.gateways.external,
            "network.default_gateway": self.network.default_gateway,
        } | {
            f"nodes[{i}].address": n.address for i, n in enumerate(self.nodes)
        }
        seen: dict[IPv4Address, str] = {}
        for owner, addr in addresses.items():
            if addr is None:
                continue
            if addr in seen:
                raise ValueError(f"address {addr} is used by both {seen[addr]} and {owner}")
            seen[addr] = owner

        node_cidr = self.network.node_cidr
        for i, node in enumerate(self.nodes):
            if node.address is not None and node.address not in node_cidr:
                raise ValueError(
                    f"nodes[{i}].address {node.address} is not inside node_cidr {node_cidr}"
                )
        if self.kubernetes.api.addr is not None and self.kubernetes.api.addr not in node_cidr:
            raise ValueError(
                f"kubernetes.api.addr {self.kubernetes.api.addr} is not inside node_cidr {node_cidr}"
            )
        # Without BGP the gateway VIPs are announced over L2 and must live in
        # the node network.
        if not self.cilium_bgp_enabled:
            for name in ("internal", "dns", "external"):
                addr = getattr(self.gateways, name)
                if addr is not None and addr not in node_cidr:
                    raise ValueError(
                        f"gateways.{name} {addr} is not inside node_cidr {node_cidr} "
                        "(required unless BGP is enabled)"
                    )

        for field, label in (("name", "name"), ("mac_addr", "MAC address")):
            values: dict[str, int] = {}
            for i, node in enumerate(self.nodes):
                value = getattr(node, field)
                if value is None:
                    continue
                if value in values:
                    raise ValueError(
                        f"duplicate node {label} {value!r} on nodes[{values[value]}] and nodes[{i}]"
                    )
                values[value] = i
        return self


def format_errors(error: ValidationError) -> str:
    lines = []
    for err in error.errors():
        loc = ".".join(str(part) for part in err["loc"])
        msg = err["msg"].removeprefix("Value error, ")
        lines.append(f"{loc}: {msg}" if loc else msg)
    return "\n".join(lines)


class ConfigError(Exception):
    pass


# Validate config_file and return the defaulted config as a plain dict.
# Raises ConfigError with a human-readable message.
def load(config_file: str = "cluster.toml") -> dict[str, Any]:
    path = Path(config_file)
    try:
        raw = tomllib.loads(path.read_text())
    except FileNotFoundError:
        raise ConfigError(f"{path}: file not found") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: invalid TOML: {e}") from None

    try:
        config = Config.model_validate(raw)
    except ValidationError as e:
        raise ConfigError(format_errors(e)) from None

    # Unset optionals stay in the dump as None rather than being dropped:
    # makejinja renders with StrictUndefined, so a template testing
    # network.vlan_tag needs the key to exist.
    return config.model_dump(mode="json")


# JSON Schema for editor completion and validation of cluster.toml (taplo's
# #:schema directive). Cross-field rules and data-aware defaults only exist in
# the model validators, so the schema is an editing aid, not the gate.
def schema() -> dict[str, Any]:
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        **Config.model_json_schema(),
    }


def main() -> int:
    if sys.argv[1:] == ["--schema"]:
        json.dump(schema(), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    try:
        data = load(sys.argv[1] if len(sys.argv) > 1 else "cluster.toml")
    except ConfigError as e:
        print(e, file=sys.stderr)
        return 1
    json.dump(data, sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
