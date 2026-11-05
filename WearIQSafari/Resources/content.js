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
    return !!document.querySelector('meta[property="product:price:amount"], meta[property="og:price:amount"]');
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
    const html = "<html><head><title>" + escapeHTML(document.title) + "</title>" + head.join("\n") +
      "</head><body>" + body.join("\n") + "</body></html>";
    const text = (document.body && document.body.innerText) || "";
    const lines = text.split("\n").filter((l) =>
      /(%\s?\d{1,3}|\d{1,3}\s?%)\s?[A-Za-zÇĞİÖŞÜçğıöşü]/.test(l) || /model/i.test(l) && /(cm|beden|size|boy)/i.test(l));
    const sizes = new Set();
    document.querySelectorAll('button, li, label, option, a[role="button"], span[class*="size" i], div[class*="size" i]')
      .forEach((e) => {
        const s = (e.innerText || e.textContent || "").trim();
        if (s.length <= 8 && SIZE.test(s)) sizes.add(s.toUpperCase().replace(/\s/g, ""));
      });
    return { html: html.slice(0, MAX_HTML), text: lines.slice(0, 12).join("\n"), sizes: [...sizes].slice(0, 24) };
  }

  let lastSent = "";
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

  function check() {
    if (!isProductPage()) return;
    const page = gather();
    const key = page.html.length + "|" + page.sizes.join(",") + "|" + location.href;
    if (key === lastSent) return;
    lastSent = key;
    browser.runtime.sendMessage({ type: "product", url: location.href, title: document.title, ...page })
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
