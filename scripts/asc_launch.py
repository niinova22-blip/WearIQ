#!/usr/bin/env python3
"""App Store launch setup through the App Store Connect API.

Usage:
  asc_launch.py <app_id> status
  asc_launch.py <app_id> subscriptions <review_screenshot.png>
  asc_launch.py <app_id> submit <version> <build_number>

status: prints what the App Store submission still needs (subscriptions, prices, the
app's price and availability, age rating, review contact, the version and its build).

subscriptions: makes the Premium group and its monthly and yearly subscriptions if they
don't exist, with English and Turkish names, prices in every territory (the US price's
equalized price; Türkiye's own), a one-week free trial on the yearly plan, availability
everywhere, and the paywall screenshot App Review asks for. Safe to run again: what
exists is left as it is.
"""
import hashlib
import json
import sys
import urllib.request

import asc_signing
from asc_signing import call, try_call


def call_v2(method, path, body=None):
    """The same call on the API's v2 paths (app availability)."""
    saved = asc_signing.API
    asc_signing.API = saved.replace("/v1", "/v2")
    try:
        return call(method, path, body)
    finally:
        asc_signing.API = saved

GROUP = "WearIQ Premium"
PRODUCTS = [
    {"productId": "com.niinova.weariq.premium.monthly", "name": "Premium Monthly", "period": "ONE_MONTH", "level": 2,
     "usd": "6.99", "try": "149.99",
     "en": ("Premium Monthly", "Unlimited checks, no ads and the Style tab."),
     "tr": ("Premium Aylık", "Sınırsız kontrol, reklamsız ve Tarz sekmesi."),
     "trial": False},
    {"productId": "com.niinova.weariq.premium.yearly", "name": "Premium Yearly", "period": "ONE_YEAR", "level": 1,
     "usd": "39.99", "try": "999.99",
     "en": ("Premium Yearly", "Unlimited checks, no ads and the Style tab."),
     "tr": ("Premium Yıllık", "Sınırsız kontrol, reklamsız ve Tarz sekmesi."),
     "trial": True},
]
REVIEW_NOTE = ("Premium unlocks unlimited garment checks (free: 5 a day), removes ads and opens the Style tab. "
               "The paywall opens from the Style tab, or when the day's free checks are used.")


def pages(path):
    """Every item of a paginated list."""
    out = []
    while path:
        page = call("GET", path)
        out += page.get("data", [])
        nxt = page.get("links", {}).get("next")
        path = nxt.split("/v1", 1)[1] if nxt else None
    return out


def rel(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def status(app_id):
    app = call("GET", f"/apps/{app_id}")["data"]["attributes"]
    print(f"app: {app.get('name')} primaryLocale={app.get('primaryLocale')} bundle={app.get('bundleId')}")
    groups = call("GET", f"/apps/{app_id}/subscriptionGroups")["data"]
    print(f"subscription groups: {[g['attributes']['referenceName'] for g in groups]}")
    for g in groups:
        for s in call("GET", f"/subscriptionGroups/{g['id']}/subscriptions")["data"]:
            a = s["attributes"]
            prices = try_call("GET", f"/subscriptions/{s['id']}/prices?limit=1") or {}
            n = prices.get("meta", {}).get("paging", {}).get("total")
            print(f"  {a['productId']}: state={a.get('state')} period={a.get('subscriptionPeriod')} prices={n} "
                  f"USA={current_price(s['id'], 'USA')} TUR={current_price(s['id'], 'TUR')}")
    sched = try_call("GET", f"/apps/{app_id}/appPriceSchedule")
    print(f"app price schedule: {'set' if sched and sched.get('data') else 'missing'}")
    avail = try_call("GET", f"/apps/{app_id}/appAvailabilityV2")
    print(f"app availability: {'set' if avail and avail.get('data') else 'missing'}")
    versions = call("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=5")["data"]
    for v in versions:
        a = v["attributes"]
        build = try_call("GET", f"/appStoreVersions/{v['id']}/build") or {}
        b = (build.get("data") or {}).get("attributes", {})
        print(f"version {a['versionString']}: {a['appStoreState']} build={b.get('version')}")
        review = try_call("GET", f"/appStoreVersions/{v['id']}/appStoreReviewDetail") or {}
        r = (review.get("data") or {}).get("attributes", {})
        print(f"  review contact: {r.get('contactFirstName')} {r.get('contactLastName')} "
              f"email={'yes' if r.get('contactEmail') else 'no'} phone={'yes' if r.get('contactPhone') else 'no'}")
    infos = call("GET", f"/apps/{app_id}/appInfos")["data"]
    for info in infos:
        age = try_call("GET", f"/appInfos/{info['id']}/ageRatingDeclaration") or {}
        print(f"app info {info['attributes'].get('state')}: age rating {'set' if age.get('data') else 'missing'}")


def current_price(sub_id, territory):
    """The customer price a territory pays now, or None."""
    data = try_call("GET", f"/subscriptions/{sub_id}/prices?filter[territory]={territory}&include=subscriptionPricePoint&limit=10") or {}
    points = [i for i in data.get("included", []) if i["type"] == "subscriptionPricePoints"]
    return points[-1]["attributes"]["customerPrice"] if points else None


def price_point(sub_id, territory, price):
    points = pages(f"/subscriptions/{sub_id}/pricePoints?filter[territory]={territory}&limit=200")
    best = min(points, key=lambda p: abs(float(p["attributes"]["customerPrice"]) - float(price)))
    return best


def set_prices(sub_id, usd, try_price):
    usa, tur = current_price(sub_id, "USA"), current_price(sub_id, "TUR")
    if usa and tur and abs(float(usa) - float(usd)) < 0.01 and abs(float(tur) - float(try_price)) < 0.01:
        print(f"  prices already {usa} USD, {tur} TRY")
        return
    print(f"  prices were {usa} USD, {tur} TRY")
    # Not yet on sale: the old prices can go, and the new ones take their place.
    for price in pages(f"/subscriptions/{sub_id}/prices?limit=200"):
        try_call("DELETE", f"/subscriptionPrices/{price['id']}")
    us = price_point(sub_id, "USA", usd)
    print(f"  USA {us['attributes']['customerPrice']}")
    points = {"USA": us["id"]}
    for p in pages(f"/subscriptionPricePoints/{us['id']}/equalizations?include=territory&limit=200"):
        terr = p["relationships"]["territory"]["data"]["id"]
        points[terr] = p["id"]
    tr = price_point(sub_id, "TUR", try_price)
    points["TUR"] = tr["id"]
    print(f"  TUR {tr['attributes']['customerPrice']}; {len(points)} territories")
    for terr, point in points.items():
        try_call("POST", "/subscriptionPrices", {"data": {
            "type": "subscriptionPrices",
            "attributes": {"preserveCurrentPrice": False},
            "relationships": {"subscription": rel("subscriptions", sub_id),
                              "subscriptionPricePoint": rel("subscriptionPricePoints", point),
                              "territory": rel("territories", terr)}}})


def availability(app_id):
    """The app on sale in every territory, and in new ones as they open."""
    if (try_call("GET", f"/apps/{app_id}/appAvailabilityV2") or {}).get("data"):
        print("app availability: already set")
        return
    territories = [t["id"] for t in pages("/territories?limit=200")]
    call_v2("POST", "/appAvailabilities", {
        "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
                 "relationships": {"app": rel("apps", app_id),
                                   "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"}
                                                                        for t in territories]}}},
        "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                      "relationships": {"territory": rel("territories", t)}} for t in territories]})
    print(f"app availability: {len(territories)} territories")


def subscriptions(app_id, screenshot):
    availability(app_id)
    groups = call("GET", f"/apps/{app_id}/subscriptionGroups")["data"]
    group = next((g for g in groups if g["attributes"]["referenceName"] == GROUP), groups[0] if groups else None)
    if not group:
        group = call("POST", "/subscriptionGroups", {"data": {
            "type": "subscriptionGroups", "attributes": {"referenceName": GROUP},
            "relationships": {"app": rel("apps", app_id)}}})["data"]
        print(f"group created: {GROUP}")
    gid = group["id"]
    have = {l["attributes"]["locale"] for l in call("GET", f"/subscriptionGroups/{gid}/subscriptionGroupLocalizations")["data"]}
    for locale, name in (("en-US", "WearIQ Premium"), ("tr", "WearIQ Premium")):
        if locale not in have:
            call("POST", "/subscriptionGroupLocalizations", {"data": {
                "type": "subscriptionGroupLocalizations", "attributes": {"locale": locale, "name": name},
                "relationships": {"subscriptionGroup": rel("subscriptionGroups", gid)}}})
            print(f"group localization {locale}")

    territories = [t["id"] for t in pages("/territories?limit=200")]
    shot = open(screenshot, "rb").read() if screenshot else None
    existing = {s["attributes"]["productId"]: s for s in call("GET", f"/subscriptionGroups/{gid}/subscriptions")["data"]}
    for p in PRODUCTS:
        sub = existing.get(p["productId"])
        if not sub:
            sub = call("POST", "/subscriptions", {"data": {
                "type": "subscriptions",
                "attributes": {"name": p["name"], "productId": p["productId"], "familySharable": False,
                               "subscriptionPeriod": p["period"], "groupLevel": p["level"], "reviewNote": REVIEW_NOTE},
                "relationships": {"group": rel("subscriptionGroups", gid)}}})["data"]
            print(f"{p['productId']}: created")
        sid = sub["id"]
        print(f"{p['productId']}: {sub['attributes'].get('state')}")
        have = {l["attributes"]["locale"] for l in call("GET", f"/subscriptions/{sid}/subscriptionLocalizations")["data"]}
        for locale, key in (("en-US", "en"), ("tr", "tr")):
            if locale not in have:
                name, description = p[key]
                call("POST", "/subscriptionLocalizations", {"data": {
                    "type": "subscriptionLocalizations",
                    "attributes": {"locale": locale, "name": name, "description": description},
                    "relationships": {"subscription": rel("subscriptions", sid)}}})
                print(f"  localization {locale}")
        if not (try_call("GET", f"/subscriptions/{sid}/subscriptionAvailability") or {}).get("data"):
            call("POST", "/subscriptionAvailabilities", {"data": {
                "type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
                "relationships": {"subscription": rel("subscriptions", sid),
                                  "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
            print(f"  available in {len(territories)} territories")
        set_prices(sid, p["usd"], p["try"])
        if p["trial"]:
            offers = call("GET", f"/subscriptions/{sid}/introductoryOffers?limit=1").get("meta", {}).get("paging", {}).get("total", 0)
            if not offers:
                made = 0
                for t in territories:
                    if try_call("POST", "/subscriptionIntroductoryOffers", {"data": {
                        "type": "subscriptionIntroductoryOffers",
                        "attributes": {"duration": "ONE_WEEK", "offerMode": "FREE_TRIAL", "numberOfPeriods": 1},
                        "relationships": {"subscription": rel("subscriptions", sid), "territory": rel("territories", t)}}}):
                        made += 1
                print(f"  free week in {made} territories")
        if shot and not (try_call("GET", f"/subscriptions/{sid}/appStoreReviewScreenshot") or {}).get("data"):
            up = call("POST", "/subscriptionAppStoreReviewScreenshots", {"data": {
                "type": "subscriptionAppStoreReviewScreenshots",
                "attributes": {"fileName": "paywall.png", "fileSize": len(shot)},
                "relationships": {"subscription": rel("subscriptions", sid)}}})["data"]
            for op in up["attributes"]["uploadOperations"]:
                req = urllib.request.Request(op["url"], data=shot[op["offset"]:op["offset"] + op["length"]], method=op["method"],
                                             headers={h["name"]: h["value"] for h in op["requestHeaders"]})
                urllib.request.urlopen(req).read()
            call("PATCH", f"/subscriptionAppStoreReviewScreenshots/{up['id']}", {"data": {
                "type": "subscriptionAppStoreReviewScreenshots", "id": up["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(shot).hexdigest()}}})
            print("  review screenshot uploaded")


def submit(app_id, version_string, build_number):
    """Attaches the build to the version, puts the subscriptions in with it, and sends
    the lot to App Review."""
    call("PATCH", f"/apps/{app_id}", {"data": {"type": "apps", "id": app_id,
                                               "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    version = next(v for v in call("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
                   if v["attributes"]["versionString"] == version_string)
    builds = call("GET", f"/builds?filter[app]={app_id}&filter[version]={build_number}"
                         f"&filter[preReleaseVersion.version]={version_string}&limit=5")["data"]
    if not builds:
        sys.exit(f"::error::No build {build_number} of {version_string}")
    build = builds[0]
    state = build["attributes"].get("processingState")
    if state != "VALID":
        sys.exit(f"::error::Build {build_number} is {state}")
    call("PATCH", f"/appStoreVersions/{version['id']}/relationships/build",
         {"data": {"type": "builds", "id": build["id"]}})
    print(f"version {version_string}: build {build_number}")
    for g in call("GET", f"/apps/{app_id}/subscriptionGroups")["data"]:
        for sub in call("GET", f"/subscriptionGroups/{g['id']}/subscriptions")["data"]:
            st = sub["attributes"].get("state")
            print(f"{sub['attributes']['productId']}: {st}")
            if st == "READY_TO_SUBMIT":
                call("POST", "/subscriptionSubmissions", {"data": {
                    "type": "subscriptionSubmissions", "relationships": {"subscription": rel("subscriptions", sub["id"])}}})
                print("  submitted with the version")
    open_subs = call("GET", f"/reviewSubmissions?filter[app]={app_id}&filter[platform]=IOS"
                            "&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES")["data"]
    if open_subs and open_subs[0]["attributes"]["state"] != "READY_FOR_REVIEW":
        print(f"already with App Review: {open_subs[0]['attributes']['state']}")
        return
    rs = open_subs[0] if open_subs else call("POST", "/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": rel("apps", app_id)}}})["data"]
    try_call("POST", "/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": rel("reviewSubmissions", rs["id"]),
                          "appStoreVersion": rel("appStoreVersions", version["id"])}}})
    call("PATCH", f"/reviewSubmissions/{rs['id']}", {"data": {
        "type": "reviewSubmissions", "id": rs["id"], "attributes": {"submitted": True}}})
    print("submitted for review")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[2] == "status":
        status(sys.argv[1])
    elif sys.argv[2] == "submit":
        submit(sys.argv[1], sys.argv[3], sys.argv[4])
    elif sys.argv[2] == "subscriptions":
        subscriptions(sys.argv[1], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        sys.exit(__doc__)
