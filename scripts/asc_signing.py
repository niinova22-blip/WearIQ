#!/usr/bin/env python3
"""Short-lived App Store signing assets via the App Store Connect API.

The account holder's name contains a non-ASCII character, which makes Xcode's cloud
signing produce a designated requirement that App Store validation rejects (ITMS-90035).
So the release workflow signs manually: this script creates a distribution certificate
and an App Store profile for one run, and `cleanup` revokes both afterwards.

Usage:
  asc_signing.py create <csr.pem> <out_dir> <bundle_id[,extension_bundle_id…]> <profile_name>
  asc_signing.py cleanup <out_dir>

One certificate, and an App Store profile per bundle ID: the first is the app
(app.mobileprovision), the others its extensions (<last id component>.mobileprovision,
e.g. share.mobileprovision). Extension bundle IDs that aren't registered yet are.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8 file).
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT (with cryptography for ES256)

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        sys.exit(f"::error::App Store Connect API {method} {path} failed ({e.code}): {detail}")


def try_call(method: str, path: str, body: dict | None = None) -> dict | None:
    """Like call, but returns None on an HTTP error instead of failing the run."""
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"::warning::App Store Connect API {method} {path} failed ({e.code}): {e.read().decode(errors='replace')[:400]}")
        return None


# Capabilities the app's entitlements use, enabled on its bundle ID before its profile is
# made (the profile carries what the ID has). HealthKit: reading the weight; iCloud:
# key-value storage for the optional backup.
APP_CAPABILITIES = {
    "HEALTHKIT": None,
    "ICLOUD": [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6"}]}],
}


def ensure_capabilities(bundle_resource_id: str, out_dir: str) -> None:
    """Enables APP_CAPABILITIES on the bundle ID; writes the ones it has to capabilities.txt
    so the signing step only claims entitlements the profile allows."""
    present = set()
    listed = try_call("GET", f"/bundleIds/{bundle_resource_id}/bundleIdCapabilities?limit=200")
    for c in (listed or {}).get("data", []):
        present.add(c["attributes"].get("capabilityType"))
    for kind, settings in APP_CAPABILITIES.items():
        if kind in present:
            continue
        attributes = {"capabilityType": kind}
        if settings:
            attributes["settings"] = settings
        made = try_call("POST", "/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities", "attributes": attributes,
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}}},
        }})
        if made is not None:
            present.add(kind)
            print(f"Enabled {kind} on the app's bundle ID")
    with open(os.path.join(out_dir, "capabilities.txt"), "w") as f:
        f.write(" ".join(sorted(k for k in present if k in APP_CAPABILITIES)))


def create(csr_path: str, out_dir: str, bundle_id: str, profile_name: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    with open(csr_path) as f:
        csr = f.read()

    cert = call("POST", "/certificates", {"data": {
        "type": "certificates",
        # IOS_DISTRIBUTION has its own quota, separate from the cross-platform DISTRIBUTION type.
        "attributes": {"certificateType": "IOS_DISTRIBUTION", "csrContent": csr},
    }})["data"]
    cert_id = cert["id"]
    with open(os.path.join(out_dir, "cert_id"), "w") as f:
        f.write(cert_id)
    with open(os.path.join(out_dir, "dist.cer"), "wb") as f:
        f.write(base64.b64decode(cert["attributes"]["certificateContent"]))

    ids = bundle_id.split(",")
    profile_ids = []
    for index, identifier in enumerate(ids):
        query = urllib.parse.urlencode({"filter[identifier]": identifier, "filter[platform]": "IOS"})
        bundles = [b for b in call("GET", f"/bundleIds?{query}")["data"] if b["attributes"]["identifier"] == identifier]
        if not bundles and index > 0:
            bundles = [call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
                "identifier": identifier, "name": "WearIQ " + identifier.split(".")[-1], "platform": "IOS"}}})["data"]]
            print(f"Registered bundle ID {identifier}")
        if not bundles:
            sys.exit(f"::error::Bundle ID {identifier} is not registered in the developer account")
        if index == 0:
            ensure_capabilities(bundles[0]["id"], out_dir)

        profile = call("POST", "/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": f"{profile_name} {identifier.split('.')[-1]}" if index else profile_name,
                           "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundles[0]["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            },
        }})["data"]
        profile_ids.append(profile["id"])
        name = "app" if index == 0 else identifier.split(".")[-1]
        with open(os.path.join(out_dir, f"{name}.mobileprovision"), "wb") as f:
            f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    with open(os.path.join(out_dir, "profile_id"), "w") as f:
        f.write("\n".join(profile_ids))
    print(f"Created certificate {cert_id} and profiles {', '.join(profile_ids)}")


def cleanup(out_dir: str) -> None:
    # Profile first: it references the certificate.
    for name, path in (("profile_id", "/profiles/"), ("cert_id", "/certificates/")):
        file = os.path.join(out_dir, name)
        if os.path.exists(file):
            with open(file) as f:
                idents = [line.strip() for line in f if line.strip()]
            for ident in idents:
                call("DELETE", path + ident)
                print(f"Revoked {name[:-3]} {ident}")


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "create":
        create(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "cleanup":
        cleanup(sys.argv[2])
    else:
        sys.exit(__doc__)
