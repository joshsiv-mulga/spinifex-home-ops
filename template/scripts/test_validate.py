"""Unit tests for the cluster.toml validator.

Run from the repo root:
    uv run --locked pytest template/scripts/test_validate.py -q
"""

from pathlib import Path

import json
import sys
import tomllib

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from pydantic import ValidationError  # noqa: E402
from validate import Config, ConfigError, format_errors, load, schema  # noqa: E402

REPO_ROOT = Path(__file__).parents[2]
VALID = sorted((REPO_ROOT / ".github/template-tests/valid").glob("*.toml"))
INVALID = sorted((REPO_ROOT / ".github/template-tests/invalid").glob("*.toml"))


def config_from(fixture: str, **overrides) -> dict:
    raw = tomllib.loads((REPO_ROOT / ".github/template-tests/valid" / fixture).read_text())
    for dotted, value in overrides.items():
        target = raw
        *parents, leaf = dotted.split(".")
        for key in parents:
            target = target.setdefault(key, {})
        if value is None:
            target.pop(leaf, None)
        else:
            target[leaf] = value
    return raw


@pytest.mark.parametrize("fixture", VALID, ids=lambda p: p.stem)
def test_valid_fixture_accepted(fixture: Path):
    load(str(fixture))


@pytest.mark.parametrize("fixture", INVALID, ids=lambda p: p.stem)
def test_invalid_fixture_rejected(fixture: Path):
    with pytest.raises(ConfigError):
        load(str(fixture))


def _load_raw(raw: dict) -> Config:
    try:
        return Config.model_validate(raw)
    except ValidationError as e:
        raise ConfigError(format_errors(e)) from None


def test_host_bits_error_suggests_network_address():
    raw = config_from("public.toml", **{"network.node_cidr": "10.10.10.5/24"})
    with pytest.raises(ConfigError, match=r"did you mean 10\.10\.10\.0/24"):
        _load_raw(raw)


def test_duplicate_address_names_both_owners():
    raw = config_from("public.toml")
    raw["nodes"][0]["address"] = raw["gateways"]["internal"]
    with pytest.raises(ConfigError, match=r"gateways\.internal and nodes\[0\]\.address"):
        _load_raw(raw)


def test_default_gateway_derived_from_node_cidr():
    raw = config_from("private.toml")
    assert "default_gateway" not in raw["network"]
    data = _load_raw(raw).model_dump(mode="json")
    assert data["network"]["default_gateway"] == "10.10.10.1"


def test_coredns_addr_default_and_override():
    raw = config_from("private.toml")
    assert _load_raw(raw).model_dump(mode="json")["kubernetes"]["coredns_addr"] == "10.43.0.10"
    raw = config_from("private.toml", **{"kubernetes.coredns_addr": "10.43.0.53"})
    assert _load_raw(raw).model_dump(mode="json")["kubernetes"]["coredns_addr"] == "10.43.0.53"
    raw = config_from("private.toml", **{"kubernetes.coredns_addr": "192.168.9.9"})
    with pytest.raises(ConfigError, match="not inside svc_cidr"):
        _load_raw(raw)


def test_spegel_enabled_follows_node_count():
    two_nodes = config_from("private.toml")
    assert _load_raw(two_nodes).spegel.enabled is True
    one_node = config_from("private.toml")
    one_node["nodes"] = one_node["nodes"][:1]
    assert _load_raw(one_node).spegel.enabled is False
    empty_section = config_from("private.toml", spegel={})
    assert _load_raw(empty_section).spegel.enabled is True
    explicit = config_from("private.toml", **{"spegel.enabled": False})
    assert _load_raw(explicit).spegel.enabled is False


def test_controller_count_ignores_workers():
    raw = config_from("private.toml")
    assert [n["controller"] for n in raw["nodes"]] == [True, False]
    assert _load_raw(raw).controller_count == 1
    raw["nodes"][1]["controller"] = True
    assert _load_raw(raw).controller_count == 2


def test_derived_fields_are_not_settable():
    raw = config_from("public.toml", cilium_bgp_enabled=True)
    with pytest.raises(ConfigError, match="cilium_bgp_enabled"):
        _load_raw(raw)
    raw = config_from("public.toml", controller_count=3)
    with pytest.raises(ConfigError, match="controller_count"):
        _load_raw(raw)


def test_cert_sans_single_source():
    raw = config_from("public.toml")
    assert _load_raw(raw).cert_sans == ["127.0.0.1", "10.10.10.254", "example.com"]
    raw = config_from("private.toml")
    assert _load_raw(raw).cert_sans == ["127.0.0.1", "10.10.10.254"]


def test_ingress_mode_follows_dns_provider():
    cloudflare = config_from("public.toml", ingress=None)
    assert _load_raw(cloudflare).ingress.mode == "cloudflare-tunnel"
    internal = config_from("internal.toml")
    assert (REPO_ROOT / ".github/template-tests/valid/internal.toml").exists()
    assert "ingress" not in internal
    assert _load_raw(internal).ingress.mode == "none"


def test_ingress_requires_someone_to_publish_the_record():
    raw = config_from("internal.toml", **{"ingress.mode": "direct"})
    with pytest.raises(ConfigError, match="requires a dns.provider"):
        _load_raw(raw)


def test_tunnel_mode_requires_cloudflare_dns():
    raw = config_from("spinifex.toml", **{"ingress.mode": "cloudflare-tunnel"})
    with pytest.raises(ConfigError, match="requires dns.provider 'cloudflare'"):
        _load_raw(raw)


def test_spinifex_dns_defaults_to_direct_ingress():
    raw = config_from("spinifex.toml", **{"dns.provider": "spinifex"})
    assert _load_raw(raw).ingress.mode == "direct"


def test_spinifex_dns_requires_the_spinifex_provider():
    raw = config_from("private.toml", **{"dns.provider": "spinifex", "dns.token": None})
    with pytest.raises(ConfigError, match="requires provider 'spinifex'"):
        _load_raw(raw)


def test_spinifex_dns_takes_no_token():
    raw = config_from("spinifex.toml", **{"dns.provider": "spinifex", "dns.token": "fake"})
    with pytest.raises(ConfigError, match="token must be empty"):
        _load_raw(raw)


# ACM's certificate lives on the load balancer listener, so the cluster has
# nothing to issue and cert-manager is not rendered at all.
def test_cert_manager_follows_dns_provider():
    assert _load_raw(config_from("public.toml")).cert_manager_enabled is True
    assert _load_raw(config_from("internal.toml")).cert_manager_enabled is True
    spinifex = config_from("spinifex.toml", **{"dns.provider": "spinifex"})
    assert _load_raw(spinifex).cert_manager_enabled is False


def test_schematic_id_inherits_from_talos_section():
    raw = config_from("public.toml")
    cfg = _load_raw(raw)
    assert cfg.nodes[0].schematic_id == cfg.talos.schematic_id
    assert cfg.nodes[1].schematic_id is not None


def test_partial_bgp_rejected():
    raw = config_from("private.toml", **{"cilium.bgp.router_addr": "10.10.1.1", "cilium.bgp.router_asn": "64513"})
    with pytest.raises(ConfigError, match="partially configured"):
        _load_raw(raw)


def test_node_defaults_exported():
    data = _load_raw(config_from("private.toml")).model_dump(mode="json")
    node = data["nodes"][0]
    assert node["mtu"] == 1500
    assert node["secureboot"] is False
    assert node["kernel_modules"] == []


def test_gateways_may_leave_node_cidr_only_with_bgp():
    with_bgp = config_from("public.toml", **{"gateways.external": "192.168.50.1"})
    _load_raw(with_bgp)  # public.toml enables BGP
    without_bgp = config_from("private.toml", **{"gateways.external": "192.168.50.1"})
    with pytest.raises(ConfigError, match="required unless BGP is enabled"):
        _load_raw(without_bgp)


def test_provider_defaults_to_bare_metal():
    raw = config_from("single-node.toml")
    assert "provider" not in raw
    assert _load_raw(raw).provider == "bare-metal"


def test_provider_rejects_unknown_target():
    raw = config_from("single-node.toml", provider="proxmox")
    with pytest.raises(ConfigError, match="provider"):
        _load_raw(raw)


def test_spinifex_derives_nodes_controllers_first():
    cfg = _load_raw(config_from("spinifex-multi-controller.toml"))
    assert [n.name for n in cfg.nodes] == ["k8s-0", "k8s-1", "k8s-2", "k8s-3", "k8s-4"]
    assert [n.controller for n in cfg.nodes] == [True, True, True, False, False]
    assert cfg.controller_count == 3


def test_spinifex_nodes_carry_no_machine_identity():
    cfg = _load_raw(config_from("spinifex.toml"))
    assert len(cfg.nodes) == 1
    assert (cfg.nodes[0].address, cfg.nodes[0].mac_addr, cfg.nodes[0].disk) == (None, None, None)


def test_spinifex_rejects_declared_nodes():
    raw = config_from("spinifex.toml")
    raw["nodes"] = [
        {"name": "k8s-0", "address": "172.31.0.4", "controller": True,
         "disk": "/dev/vda", "mac_addr": "02:88:a5:66:74:b6"}
    ]
    with pytest.raises(ConfigError, match="must not be declared"):
        _load_raw(raw)


def test_spinifex_install_disk_default_and_override():
    assert _load_raw(config_from("spinifex.toml")).spinifex.install_disk == "/dev/vda"
    raw = config_from("spinifex.toml", **{"spinifex.install_disk": "/dev/nvme0n1"})
    assert _load_raw(raw).spinifex.install_disk == "/dev/nvme0n1"


def test_spinifex_requires_odd_controllers():
    raw = config_from("spinifex.toml", **{"spinifex.controllers": 2})
    with pytest.raises(ConfigError, match="must be odd for etcd quorum"):
        _load_raw(raw)


def test_api_endpoint_is_the_vip_on_bare_metal():
    cfg = _load_raw(config_from("single-node.toml"))
    assert cfg.api_endpoint == "https://10.10.10.254:6443"
    assert cfg.cert_sans[1] == "10.10.10.254"


def test_spinifex_api_host_defaults_to_the_domain():
    cfg = _load_raw(config_from("spinifex.toml"))
    assert cfg.kubernetes.api.addr is None
    assert cfg.kubernetes.api.host == "kubernetes.example.com"
    assert cfg.api_endpoint == "https://kubernetes.example.com:6443"
    assert cfg.cert_sans == ["127.0.0.1", "kubernetes.example.com"]


def test_spinifex_api_host_override():
    cfg = _load_raw(config_from("spinifex-multi-controller.toml"))
    assert cfg.api_endpoint == "https://k8s.example.com:6443"


def test_spinifex_rejects_a_pinned_api_addr():
    raw = config_from("spinifex.toml", **{"kubernetes.api.addr": "172.31.0.254"})
    with pytest.raises(ConfigError, match="api.addr must not be set"):
        _load_raw(raw)


def test_spinifex_rejects_declared_gateways():
    for name in ("internal", "dns", "external"):
        raw = config_from("spinifex.toml", **{f"gateways.{name}": "172.31.0.252"})
        with pytest.raises(ConfigError, match=f"gateways.{name} must not be set"):
            _load_raw(raw)


def test_spinifex_rejects_bgp():
    raw = config_from("spinifex.toml", **{
        "cilium.bgp.router_addr": "172.31.0.1",
        "cilium.bgp.router_asn": "64512",
        "cilium.bgp.node_asn": "64513",
    })
    with pytest.raises(ConfigError, match="cilium.bgp must not be set"):
        _load_raw(raw)


def test_spinifex_node_ports_default_and_must_differ():
    cfg = _load_raw(config_from("spinifex.toml"))
    ports = (
        cfg.spinifex.external_node_port,
        cfg.spinifex.internal_node_port,
        cfg.spinifex.dns_node_port,
    )
    assert ports == (30080, 30081, 30053)
    raw = config_from("spinifex.toml", **{"spinifex.internal_node_port": 30080})
    with pytest.raises(ConfigError, match="node port 30080 is used by both"):
        _load_raw(raw)
    raw = config_from("spinifex.toml", **{"spinifex.external_node_port": 8080})
    with pytest.raises(ConfigError, match="external_node_port"):
        _load_raw(raw)


def test_spinifex_ec2_endpoint_defaults_to_the_services_domain():
    cfg = _load_raw(config_from("spinifex.toml"))
    assert cfg.spinifex.ec2_endpoint == "https://ec2.ap-southeast-2.services.internal:9999"
    raw = config_from("spinifex.toml", **{"spinifex.region": "us-east-1"})
    assert _load_raw(raw).spinifex.ec2_endpoint == "https://ec2.us-east-1.services.internal:9999"


def test_spinifex_endpoint_override_needs_a_scheme_and_a_port():
    raw = config_from("spinifex.toml", **{"spinifex.endpoint": "https://10.0.0.1:9999"})
    assert _load_raw(raw).spinifex.ec2_endpoint == "https://10.0.0.1:9999"
    for bad in ("https://ec2.example.internal", "ec2.example.internal:9999", "http://ec2:9999"):
        raw = config_from("spinifex.toml", **{"spinifex.endpoint": bad})
        with pytest.raises(ConfigError, match="explicit port"):
            _load_raw(raw)


def test_spinifex_requires_a_gateway_url_and_an_admin_cidr():
    for name in ("gateway_url", "admin_cidr"):
        raw = config_from("spinifex.toml", **{f"spinifex.{name}": None})
        with pytest.raises(ConfigError, match=f"spinifex.{name} is required"):
            _load_raw(raw)
    raw = config_from("spinifex.toml", **{"spinifex.gateway_url": "https://gw.example.internal"})
    with pytest.raises(ConfigError, match="explicit port"):
        _load_raw(raw)


def test_cilium_loadbalancer_mode_follows_the_routing_mode():
    assert _load_raw(config_from("spinifex.toml")).cilium.loadbalancer_mode == "snat"
    assert _load_raw(config_from("single-node.toml")).cilium.loadbalancer_mode == "dsr"
    raw = config_from("spinifex.toml", **{"cilium.loadbalancer_mode": "dsr"})
    with pytest.raises(ConfigError, match="dsr on top of vxlan"):
        _load_raw(raw)
    raw = config_from("single-node.toml", **{"cilium.loadbalancer_mode": "snat"})
    assert _load_raw(raw).cilium.loadbalancer_mode == "snat"


def test_spinifex_admin_cidr_must_not_be_the_whole_internet():
    raw = config_from("spinifex.toml", **{"spinifex.admin_cidr": "0.0.0.0/0"})
    with pytest.raises(ConfigError, match="only network boundary"):
        _load_raw(raw)


def test_spinifex_controller_addrs_are_pinned_inside_the_node_cidr():
    cfg = _load_raw(config_from("spinifex-multi-controller.toml"))
    assert cfg.controller_addrs == ["172.31.0.10", "172.31.0.11", "172.31.0.12"]
    assert len(cfg.controller_addrs) == cfg.spinifex.controllers
    raw = config_from("spinifex.toml", **{"network.node_cidr": "10.20.0.0/16"})
    assert _load_raw(raw).controller_addrs == ["10.20.0.10"]


def test_bare_metal_declares_no_controller_addrs():
    assert _load_raw(config_from("multi-controller.toml")).controller_addrs == []


def test_spinifex_nodes_resolve_through_the_vpc_resolver():
    cfg = _load_raw(config_from("spinifex.toml"))
    assert [str(a) for a in cfg.network.dns_servers] == ["169.254.169.253"]
    raw = config_from("spinifex.toml", **{"network.dns_servers": ["10.0.0.53"]})
    assert [str(a) for a in _load_raw(raw).network.dns_servers] == ["10.0.0.53"]


def test_bare_metal_requires_api_addr_and_gateways():
    raw = config_from("single-node.toml", **{"kubernetes.api.addr": None})
    with pytest.raises(ConfigError, match="api.addr is required"):
        _load_raw(raw)
    for name in ("internal", "dns"):
        raw = config_from("single-node.toml", **{f"gateways.{name}": None})
        with pytest.raises(ConfigError, match=f"gateways.{name} is required"):
            _load_raw(raw)


def test_bare_metal_still_requires_machine_identity():
    raw = config_from("single-node.toml")
    del raw["nodes"][0]["mac_addr"]
    with pytest.raises(ConfigError, match=r"nodes\[0\].mac_addr is required"):
        _load_raw(raw)


def test_bare_metal_requires_at_least_one_node():
    raw = config_from("single-node.toml", nodes=[])
    with pytest.raises(ConfigError, match="at least one node is required"):
        _load_raw(raw)


def test_schema_file_matches_model():
    committed = json.loads((REPO_ROOT / "cluster.schema.json").read_text())
    assert committed == schema(), "cluster.schema.json is stale: run `just template schema`"


def test_schema_omits_computed_fields():
    assert "cluster_issuer" not in schema()["properties"]
