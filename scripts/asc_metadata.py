#!/usr/bin/env python3
"""Pushes store listing text and screenshots to the App Store version being prepared.

Usage:
  asc_metadata.py <app_id> <metadata.json> [screenshots_dir]

screenshots_dir holds one folder per language (tr, en) with PNGs in display order, as
produced by the "App Store screenshots" workflow. Existing 6.9" screenshots for those
languages are replaced. Review contact details are left for the account holder to fill in.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8 file).
"""
import hashlib
import json
import os
import sys
import urllib.request

from asc_signing import call

SCREENSHOT_TYPE = "APP_IPHONE_67"  # 6.7"/6.9" iPhone slot (1290x2796, 1320x2868)
SHOT_DIRS = {"tr": "tr", "en-US": "en"}


def first(items, pred):
    return next((i for i in items if pred(i)), None)


def upsert_localizations(list_path, create_type, parent_type, parent_id, wanted, fields):
    existing = {l["attributes"]["locale"]: l["id"] for l in call("GET", list_path)["data"]}
    ids = {}
    for locale, values in wanted.items():
        attrs = {k: values[k] for k in fields if k in values}
        if locale in existing:
            call("PATCH", f"/{create_type}/{existing[locale]}",
                 {"data": {"type": create_type, "id": existing[locale], "attributes": attrs}})
            ids[locale] = existing[locale]
        else:
            ids[locale] = call("POST", f"/{create_type}", {"data": {
                "type": create_type,
                "attributes": {"locale": locale, **attrs},
                "relationships": {parent_type: {"data": {"type": parent_type + "s", "id": parent_id}}},
            }})["data"]["id"]
        print(f"{create_type} {locale}: updated")
    return ids


def upload_screenshots(localization_id, folder):
    sets = call("GET", f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets")["data"]
    shot_set = first(sets, lambda s: s["attributes"]["screenshotDisplayType"] == SCREENSHOT_TYPE)
    if shot_set:
        for old in call("GET", f"/appScreenshotSets/{shot_set['id']}/appScreenshots")["data"]:
            call("DELETE", f"/appScreenshots/{old['id']}")
        set_id = shot_set["id"]
    else:
        set_id = call("POST", "/appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": SCREENSHOT_TYPE},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": localization_id}}},
        }})["data"]["id"]

    for name in sorted(f for f in os.listdir(folder) if f.endswith(".png")):
        with open(os.path.join(folder, name), "rb") as f:
            data = f.read()
        shot = call("POST", "/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": name, "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
        }})["data"]
        for op in shot["attributes"]["uploadOperations"]:
            part = data[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=part, method=op["method"],
                                         headers={h["name"]: h["value"] for h in op["requestHeaders"]})
            urllib.request.urlopen(req).read()
        call("PATCH", f"/appScreenshots/{shot['id']}", {"data": {
            "type": "appScreenshots", "id": shot["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
        }})
        print(f"  uploaded {name}")


def main(app_id, metadata_path, shots_dir=None):
    with open(metadata_path, encoding="utf-8") as f:
        meta = json.load(f)
    locs = meta["localizations"]

    infos = call("GET", f"/apps/{app_id}/appInfos")["data"]
    info = first(infos, lambda i: i["attributes"].get("state") not in ("READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO")) or infos[0]
    call("PATCH", f"/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": meta["primaryCategory"]}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": meta["secondaryCategory"]}},
    }}})
    print("categories: updated")
    upsert_localizations(f"/appInfos/{info['id']}/appInfoLocalizations", "appInfoLocalizations", "appInfo",
                         info["id"], locs, ["name", "subtitle", "privacyPolicyUrl"])

    versions = call("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS"
                           "&filter[appStoreState]=PREPARE_FOR_SUBMISSION")["data"]
    if not versions:
        sys.exit("::error::No iOS App Store version in Prepare for Submission state")
    version = versions[0]
    print(f"version {version['attributes']['versionString']}")
    loc_ids = upsert_localizations(f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                                   "appStoreVersionLocalizations", "appStoreVersion", version["id"], locs,
                                   ["description", "keywords", "promotionalText", "supportUrl"])

    review = call("GET", f"/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    attrs = {"notes": meta["reviewNotes"], "demoAccountRequired": False}
    if review:
        call("PATCH", f"/appStoreReviewDetails/{review['id']}",
             {"data": {"type": "appStoreReviewDetails", "id": review["id"], "attributes": attrs}})
    else:
        call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    print("review notes: updated")

    if shots_dir:
        for locale, folder in SHOT_DIRS.items():
            path = os.path.join(shots_dir, folder)
            if os.path.isdir(path):
                print(f"screenshots {locale}:")
                upload_screenshots(loc_ids[locale], path)


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
