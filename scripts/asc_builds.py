#!/usr/bin/env python3
"""Prints the app's latest builds and their processing state on App Store Connect.

Usage: asc_builds.py <app_id>
Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8 file).
"""
import sys

from asc_signing import call

app_id = sys.argv[1]
builds = call("GET", f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"
                     "&fields[builds]=version,uploadedDate,processingState,expired,usesNonExemptEncryption")
for b in builds.get("data", []):
    a = b["attributes"]
    print(f"build {a['version']}: {a['processingState']}, uploaded {a['uploadedDate']}, "
          f"expired={a['expired']}, nonExemptEncryption={a.get('usesNonExemptEncryption')}")
