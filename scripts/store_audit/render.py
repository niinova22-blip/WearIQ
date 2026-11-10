"""Reads product pages the way the app's WebPageLoader does (iPhone Safari UA, 390x2000,
presses size-guide buttons every second, then innerText + SizeOptions.script + Zara's
size-measure-guide), with Playwright driving the installed Chrome. Writes one JSON per
page: {url, html, text, sizeGroups, guide} for the Swift-side audit."""
import asyncio, json, os, re, sys

from playwright.async_api import async_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

OUT = os.environ.get("STORE_AUDIT_OUT", os.path.join(os.getcwd(), "rendered"))
os.makedirs(OUT, exist_ok=True)


def swift_raw(path, name):
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    m = re.search(name + r'\s*=\s*#"""\n(.*?)\n\s*"""#', src, re.S)
    return m.group(1)


OPEN = swift_raw(os.path.join("WearIQ", "Services", "WebPageLoader.swift"), "openSizeGuides")
SIZES = swift_raw(os.path.join("WearIQKit", "Sources", "ProductMeasurementParser", "SizeOptions.swift"), "script")
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"


def inditex_url(html, url):
    from urllib.parse import urlparse
    store = re.search(r'"storeId"\s*:\s*(\d{4,6})\b', html)
    prod = re.search(r'"catentryId"\s*:\s*(\d{6,12})\b', html) or re.search(r'"sku"\s*:\s*"(\d{6,12})-\d+-[^"]*"', html)
    if not store or not prod:
        return None
    loc = re.search(r'"locale"\s*:\s*"([a-z]{2}_[A-Z]{2})', html)
    p = urlparse(url)
    parts = [x for x in p.path.split("/") if x]
    locale = loc.group(1) if loc else (parts[1] + "_" + parts[0].upper() if len(parts) >= 2 and len(parts[0]) == 2 and len(parts[1]) == 2 else "en_GB")
    return f"{p.scheme}://{p.netloc}/itxrest/5/catalog/store/{store.group(1)}/product/{prod.group(1)}/size-measure-guide?locale={locale}"


def complete(html):
    # The app stops once a size table or a size chart image shows up; approximate.
    return bool(re.search(r"<table[\s\S]{0,4000}?(göğüs|gogus|chest|bust|bel|waist)", html, re.I))


async def render(ctx, name, url, sem):
    path = os.path.join(OUT, name + ".json")
    if os.path.exists(path):
        return
    async with sem:
        page = await ctx.new_page()
        result = {"url": url, "html": "", "text": "", "sizeGroups": [], "guide": None, "controls": 0}
        try:
            try:
                await page.goto(url, timeout=25000, wait_until="domcontentloaded")
            except Exception as e:
                result["error"] = str(e)[:200]
            for second in range(15):
                await page.wait_for_timeout(1000)
                try:
                    result["controls"] = await page.evaluate(OPEN)
                    html = await page.evaluate("document.documentElement.outerHTML")
                except Exception:
                    continue
                result["html"] = html
                if complete(html) or (second > 8 and result["controls"] == 0 and len(html) > 20000):
                    break
            try:
                result["text"] = await page.evaluate("document.body.innerText")
                result["sizeGroups"] = await page.evaluate(SIZES)
                result["url"] = page.url
            except Exception as e:
                result["error"] = str(e)[:200]
            gurl = inditex_url(result["html"], page.url)
            if gurl:
                try:
                    result["guide"] = await page.evaluate(
                        "async u => { const r = await fetch(u, {headers: {Accept: 'application/json'}}); return r.ok ? await r.text() : null; }", gurl)
                except Exception:
                    pass
            await page.screenshot(path=os.path.join(OUT, name + ".png"))
        finally:
            await page.close()
        with open(path, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False)
        print(name, len(result["html"]), result["controls"], len(result["sizeGroups"] or []), bool(result["guide"]), flush=True)


async def main(urls):
    async with async_playwright() as p:
        browser = await p.chromium.launch(channel="chrome", headless=True)
        ctx = await browser.new_context(user_agent=UA, viewport={"width": 390, "height": 2000}, locale="tr-TR",
                                        is_mobile=True, has_touch=True, device_scale_factor=2)
        sem = asyncio.Semaphore(5)
        await asyncio.gather(*(render(ctx, n, u, sem) for n, u in urls.items()))
        await browser.close()


if __name__ == "__main__":
    manifest = json.load(open(sys.argv[1], encoding="utf-8"))
    only = set(sys.argv[2:])
    urls = {k.removesuffix(".html"): v["url"] for k, v in manifest.items() if not only or v["store"] in only}
    asyncio.run(main(urls))

# Usage, from a machine the stores serve (CI runners are in the US, where Turkish
# stores block or redirect):
#   pip install playwright          (drives the installed Chrome)
#   STORE_AUDIT_OUT=out python scripts/store_audit/render.py scripts/store_audit/links.json
#   cd WearIQKit && LIVE_PAGES=../out swift test --filter LivePageAudit
