#!/usr/bin/env python3
"""Check every embedded copy of the cluster CA against spinifex-ca.pem.

A rebuilt cluster mints a new CA, and a copy left behind fails as something
that does not name a certificate: a provider that retries until it looks hung,
or a CSI controller in CrashLoopBackOff with every claim Pending.
"""

import base64
import json
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CA = ROOT / "spinifex-ca.pem"


def normalise(pem):
    return pem.strip().replace("\r\n", "\n")


def from_configmap(path, key):
    doc = next(d for d in yaml.safe_load_all(path.read_text()) if d)
    return doc["data"][key]


def from_kopia_rootca(path):
    doc = next(d for d in yaml.safe_load_all(path.read_text()) if d)
    cfg = doc["spec"]["values"]["configMaps"]["config"]["data"]["repository.config"]
    return base64.b64decode(json.loads(cfg)["storage"]["config"]["rootCA"]).decode()


COPIES = [
    (
        "ebs-csi spinifex-ca configmap",
        lambda: from_configmap(
            ROOT / "kubernetes/apps/kube-system/aws-ebs-csi-driver/app/ca-configmap.yaml",
            "ca.pem",
        ),
    ),
    (
        "volsync component configmap",
        lambda: from_configmap(ROOT / "kubernetes/components/volsync/configmap.yaml", "ca.pem"),
    ),
    (
        "volsync maintenance configmap",
        lambda: from_configmap(
            ROOT / "kubernetes/apps/storage/volsync/maintenance/configmap.yaml", "ca.pem"
        ),
    ),
    (
        "kopia repository rootCA",
        lambda: from_kopia_rootca(ROOT / "kubernetes/apps/storage/kopia/app/helmrelease.yaml"),
    ),
]


def main():
    if not CA.is_file():
        print(f"ca-drift: no {CA.name}; nothing to compare against", file=sys.stderr)
        return 1

    want = normalise(CA.read_text())
    rc = 0
    for name, read in COPIES:
        try:
            got = normalise(read())
        except FileNotFoundError:
            print(f"  skip  {name} (absent)")
            continue
        except Exception as err:  # noqa: BLE001 - the reason is what matters here
            print(f"  ERROR {name}: {err}", file=sys.stderr)
            rc = 1
            continue
        if got == want:
            print(f"  ok    {name}")
        else:
            print(f"  STALE {name} does not match spinifex-ca.pem", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
