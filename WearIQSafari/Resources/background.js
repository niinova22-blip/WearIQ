// Relays a product page from the content script to WearIQ's native handler on the
// phone, and its advice back. Nothing leaves the device.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "product") return false;
  browser.runtime.sendNativeMessage("com.niinova.weariq", message)
    .then((reply) => sendResponse(reply))
    .catch(() => sendResponse({ status: "error" }));
  return true;
});
