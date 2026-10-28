#!/usr/bin/env python3
"""Short-lived App Store signing assets via the App Store Connect API.

The account holder's name contains a non-ASCII character, which makes Xcode's cloud
signing produce a designated requirement that App Store validation rejects (ITMS-90035).
So the release workflow signs manually: this script creates a distribution certificate
and an App Store profile for one run, and `cleanup` revokes both afterwards.

Usage:
  asc_signing.py create <csr.pem> <out_dir> <bundle_id> <profile_name>
  asc_signing.py cleanup <out_dir>

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

    query = urllib.parse.urlencode({"filter[identifier]": bundle_id, "filter[platform]": "IOS"})
    bundles = [b for b in call("GET", f"/bundleIds?{query}")["data"] if b["attributes"]["identifier"] == bundle_id]
    if not bundles:
        sys.exit(f"::error::Bundle ID {bundle_id} is not registered in the developer account")

    profile = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundles[0]["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        },
    }})["data"]
    with open(os.path.join(out_dir, "profile_id"), "w") as f:
        f.write(profile["id"])
    with open(os.path.join(out_dir, "app.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print(f"Created certificate {cert_id} and profile {profile['id']}")


def cleanup(out_dir: str) -> None:
    # Profile first: it references the certificate.
    for name, path in (("profile_id", "/profiles/"), ("cert_id", "/certificates/")):
        file = os.path.join(out_dir, name)
        if os.path.exists(file):
            with open(file) as f:
                ident = f.read().strip()
            call("DELETE", path + ident)
            print(f"Revoked {name[:-3]} {ident}")


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "create":
        create(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "cleanup":
        cleanup(sys.argv[2])
    else:
        sys.exit(__doc__)
