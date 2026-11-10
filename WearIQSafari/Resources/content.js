// WearIQ: on a product page of a store the user allowed, gathers what sizes a garment
// (structured data, size tables, the fabric and model lines, the size buttons), asks the
// app's extension for the user's size and shows it in a small badge. Only product data
// is read: no form fields, no account pages, nothing typed.
(() => {
  if (window.top !== window || window.__wearIQ) return;
  window.__wearIQ = true;

  const MAX_HTML = 350000;
  const SIZE = /^(XXXS|XXS|XS|S|M|L|XL|XXL|XXXL|[2-6]XL|\d{2}(\s?\/\s?\d{2})?|\d{2}[A-H]{1,2})$/i;
  const SIZE_WORDS = /(göğüs|gogus|bel|kalça|kalca|basen|boy|kol|omuz|chest|bust|waist|hip|length|sleeve|shoulder|inseam|beden|size|taille|tour|brust|hüfte)/i;
  const t = (key) => (browser.i18n && browser.i18n.getMessage(key)) || key;

  function isProductPage() {
    for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
      if (/"@type"\s*:\s*\[?\s*"Product"/.test(s.textContent || "")) return true;
    }
    const og = document.querySelector('meta[property="og:type"]');
    if (og && /product/i.test(og.content || "")) return true;
    if (document.querySelector('meta[property="product:price:amount"], meta[property="og:price:amount"], [itemtype*="schema.org/Product" i]')) return true;
    // Amazon publishes no product data in the page head: its product title and buy box.
    return !!(document.getElementById("productTitle") && document.querySelector("#add-to-cart-button, #buy-now-button, #twister, #inline-twister-row-size_name"));
  }

  function escapeHTML(s) {
    return (s || "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  function gather() {
    const head = [];
    document.querySelectorAll('script[type="application/ld+json"]').forEach((s) =>
      head.push('<script type="application/ld+json">' + s.textContent + "</script>"));
    document.querySelectorAll('meta[property^="og:"], meta[property^="product:"], meta[name="description"], meta[itemprop]')
      .forEach((m) => head.push(m.outerHTML));
    const body = [];
    document.querySelectorAll("table").forEach((table) => {
      const text = table.innerText || "";
      if (SIZE_WORDS.test(text) && /\d/.test(text) && text.length < 20000) body.push(table.outerHTML);
    });
    // The store's department in its page data (Zara: "sectionName":"MAN").
    const section = (document.documentElement.innerHTML.match(/"(?:sectionName|section|gender|department)"\s*:\s*"(man|men|woman|women|male|female|erkek|kad[iı]n)"/i) || [])[1];
    if (section) head.push('<script type="application/json">{"sectionName":"' + section.replace(/[^A-Za-zıİ]/g, "") + '"}</script>');
    // Amazon: the title, the brand byline and the size list are in the page, not its head.
    const amazonTitle = document.getElementById("productTitle");
    if (amazonTitle) {
      ["productTitle", "bylineInfo"].forEach((id) => {
        const el = document.getElementById(id);
        if (el) body.push('<span id="' + id + '">' + escapeHTML(el.innerText.trim()) + "</span>");
      });
      const sizeList = (document.documentElement.innerHTML.match(/"size_name"\s*:\s*\[[^\]]*\]/) || [])[0];
      if (sizeList) body.push("<script>{" + sizeList + "}</script>");
    }
    const html = "<html><head><title>" + escapeHTML(document.title) + "</title>" + head.join("\n") +
      "</head><body>" + body.join("\n") + "</body></html>";
    const text = (document.body && document.body.innerText) || "";
    // Fabric lines, and the model block: "Manken Bilgileri" is often a heading with the
    // bodies and the sizes worn on the lines below it.
    const all = text.split("\n").map((l) => l.trim()).filter(Boolean);
    const lines = [];
    all.forEach((l, i) => {
      if (/(%\s?\d{1,3}|\d{1,3}\s?%)\s?[A-Za-zÇĞİÖŞÜçğıöşü]/.test(l)) lines.push(l);
      if (/(model|manken)/i.test(l) && (l.length < 40 || /(cm|beden|size|boy)/i.test(l))) lines.push(...all.slice(i, i + 5));
    });
    const sizes = new Set();
    document.querySelectorAll('button, li, label, option, a[role="button"], span[class*="size" i], div[class*="size" i]')
      .forEach((e) => {
        const s = (e.innerText || e.textContent || "").trim();
        if (s.length <= 8 && SIZE.test(s)) sizes.add(s.toUpperCase().replace(/\s/g, ""));
      });
    let sizeGroups = [];
    try { sizeGroups = visibleSizeGroups(); } catch (e) {}
    return { html: html.slice(0, MAX_HTML), text: [...new Set(lines)].slice(0, 24).join("\n"),
             sizes: [...sizes].slice(0, 24), sizeGroups };
  }

  // The size selectors a shopper can see, outside recommendation widgets and hidden
  // sheets (Mavi hides a T-shirt's "XS S M L" next to its jeans). Same rules as the app's
  // page reader (SizeOptions.script in WearIQKit): keep the two alike.
  function visibleSizeGroups() {
    const SIZE2 = /^(XXXS|XXS|XS|S|M|L|XL|XXL|XXXL|[2-6]XL|W?\d{2}(\s?[\/xX]\s?L?\d{2})?|W\d{2}\s?L\d{2}|\d{1,2}|\d{2}[A-H]{1,2})$/i;
    const SKIP = /(^|[\s_-])(recommend\w*|recommendation\w*|reco|similar|related|carousel|slider|swiper|slick|upsell|cross-?sell|stylitics|insider|ins|benzer|oneri|kombin\w*|footer|filters?|facets?|qty|quantity|adet|miktar|pagination|rating\w*)([\s_-]|$)/i;
    const visible = (e) => {
      if (!e) return false;
      const st = getComputedStyle(e);
      if (st.display === "none" || st.visibility === "hidden" || st.opacity === "0") return false;
      const r = e.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    // The product's own size picker, even when it scrolls sideways (Trendyol's sizes sit
    // in a "slider"): reached before any widget, the sizes are the product's.
    const PICKER = /size[-_]?(picker|selector|select|variant|list|options|chooser|box)|sizepicker|sizeselector|beden[-_]?(sec|secimi|listesi)/i;
    const excluded = (e) => {
      for (let p = e; p && p !== document.body; p = p.parentElement) {
        if (p.getAttribute("aria-hidden") === "true" || p.hidden) return true;
        const c = ((p.className && p.className.toString()) || "") + " " + (p.id || "") + " " + (p.getAttribute("name") || "");
        if (PICKER.test(c + " " + (p.getAttribute("data-testid") || ""))) return false;
        if (SKIP.test(c)) return true;
      }
      return false;
    };
    const boxes = [], byBox = new Map();
    for (const e of document.querySelectorAll('button, li, label, option, a[role="button"], [role="radio"], [role="option"], span[class*="size" i], div[class*="size" i]')) {
      const s = (e.innerText || e.textContent || "").trim().replace(/\s+/g, " ");
      if (!s || s.length > 9 || !SIZE2.test(s)) continue;
      if (!visible(e.tagName === "OPTION" ? e.parentElement : e) || excluded(e)) continue;
      // Up to the element that holds more than this one size: wrappers around a single
      // size (Nike's radio input and its label) belong to the selector above them.
      let box = e.parentElement;
      const own = (n) => (n.innerText || n.textContent || "").trim().replace(/\s+/g, " ");
      while (box && box.parentElement && box !== document.body && (box.children.length === 1 || own(box) === s)) box = box.parentElement;
      if (!byBox.has(box)) { byBox.set(box, []); boxes.push(box); }
      const list = byBox.get(box);
      if (!list.includes(s)) list.push(s);
    }
    const caption = (box) => {
      const own = box.getAttribute("aria-label") || box.getAttribute("data-label") || "";
      if (own) return own;
      if (box.id) { const l = document.querySelector('label[for="' + box.id + '"]'); if (l) return l.innerText; }
      for (let p = box, i = 0; p && i < 3; p = p.parentElement, i++) {
        const prev = p.previousElementSibling;
        if (prev && prev.innerText && prev.innerText.trim().length < 40) return prev.innerText;
      }
      return "";
    };
    return boxes.slice(0, 10).map((b) => ({ caption: caption(b).trim().replace(/\s+/g, " ").slice(0, 40), labels: byBox.get(b).slice(0, 60) }));
  }

  // Zara and the other Inditex stores load the size guide on request, as JSON; the same
  // request their size panel makes (InditexSizeGuide in WearIQKit builds the same address).
  async function inditexGuide() {
    const h = document.documentElement.innerHTML;
    const store = (h.match(/"storeId"\s*:\s*(\d{4,6})\b/) || [])[1];
    const product = (h.match(/"catentryId"\s*:\s*(\d{6,12})\b/) || h.match(/"sku"\s*:\s*"(\d{6,12})-\d+-/) || [])[1];
    if (!store || !product) return null;
    const parts = location.pathname.split("/").filter(Boolean);
    const locale = (h.match(/"locale"\s*:\s*"([a-z]{2}_[A-Z]{2})/) || [])[1] ||
      (parts.length >= 2 && parts[0].length === 2 && parts[1].length === 2 ? parts[1] + "_" + parts[0].toUpperCase() : "en_GB");
    try {
      const r = await fetch("/itxrest/5/catalog/store/" + store + "/product/" + product + "/size-measure-guide?locale=" + locale,
                            { headers: { Accept: "application/json" } });
      return r.ok ? (await r.text()).slice(0, 200000) : null;
    } catch (e) { return null; }
  }

  let lastSent = "";
  let guide = { url: "", text: null };
  let badge = null;

  function show(reply) {
    if (!reply || !reply.status || reply.status === "notGarment" || reply.status === "error") return;
    if (!badge) {
      const host = document.createElement("div");
      host.style.cssText = "position:fixed;right:12px;bottom:max(16px,env(safe-area-inset-bottom));z-index:2147483647;";
      document.documentElement.appendChild(host);
      badge = host.attachShadow({ mode: "closed" });
    }
    let title = "", detail = "", tone = "#6E5BFF";
    if (reply.status === "sized" || reply.status === "between") {
      title = reply.status === "between"
        ? t("between") + " " + reply.size + " " + t("and") + " " + reply.otherSize
        : t("your_size") + ": " + reply.size;
      const risk = reply.risk || "medium";
      tone = risk === "low" ? "#1FA971" : risk === "high" ? "#E5484D" : "#F5A524";
      detail = t("risk_" + risk);
      if (reply.standard) detail += " · " + t("typical");
      if (reply.styleSize) detail += " · " + reply.styleSize + " " + t("for_your_style");
      if (reply.nonReturnable) detail += " · " + t("no_returns");
    } else if (reply.status === "noBody") {
      title = "WearIQ"; detail = t("no_body");
    } else if (reply.status === "noChart") {
      title = "WearIQ"; detail = t("no_chart");
    }
    badge.innerHTML = `
      <style>
        .b{font:600 15px -apple-system,system-ui,sans-serif;color:#fff;background:rgba(20,18,32,.92);
           border-radius:18px;padding:10px 14px 10px 12px;box-shadow:0 8px 24px rgba(0,0,0,.25);
           display:flex;gap:10px;align-items:center;max-width:300px;-webkit-backdrop-filter:blur(12px)}
        .dot{width:10px;height:10px;border-radius:5px;flex:none;background:${tone}}
        .d{font-weight:500;font-size:12px;opacity:.8;margin-top:2px}
        .x{margin-left:6px;opacity:.6;font-size:18px;line-height:18px;border:0;background:none;color:#fff}
      </style>
      <div class="b"><span class="dot"></span><div><div>${escapeHTML(title)}</div><div class="d">${escapeHTML(detail)}</div></div>
      <button class="x" aria-label="${escapeHTML(t("close"))}">×</button></div>`;
    badge.querySelector(".x").addEventListener("click", () => { badge.innerHTML = ""; });
  }

  async function check() {
    if (!isProductPage()) return;
    const page = gather();
    const key = page.html.length + "|" + page.sizes.join(",") + "|" + location.href;
    if (key === lastSent) return;
    lastSent = key;
    if (guide.url !== location.href) guide = { url: location.href, text: await inditexGuide() };
    browser.runtime.sendMessage({ type: "product", url: location.href, title: document.title, ...page,
                                  guide: guide.text || undefined })
      .then(show).catch(() => {});
  }

  // Once loaded, and again when the page changes (a size guide opened, a colour picked,
  // a single-page store moving to another product).
  setTimeout(check, 1200);
  let timer = null;
  new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(check, 1500);
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
