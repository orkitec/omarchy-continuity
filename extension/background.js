// omarchy-continuity extension: send the current tab or a link to the other machine.
// "Open" leaves this tab alone; "Move" closes it here once the other side confirmed.
const HOST = "com.orkitec.omarchy_continuity";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "open-page", title: "Open this page on the other machine", contexts: ["page", "action"] });
  chrome.contextMenus.create({ id: "move-page", title: "Move this tab to the other machine", contexts: ["page", "action"] });
  chrome.contextMenus.create({ id: "open-link", title: "Open link on the other machine", contexts: ["link"] });
});

function notify(title, message) {
  chrome.notifications.create({ type: "basic", iconUrl: "icon.png", title, message });
}

function send(url, tab, move) {
  if (!url || !/^https?:\/\//.test(url)) {
    notify("omarchy-continuity", "Only http(s) pages can be sent.");
    return;
  }
  chrome.runtime.sendNativeMessage(HOST, { action: "open", url }, (reply) => {
    if (chrome.runtime.lastError) {
      notify("omarchy-continuity", "Native host not reachable: " + chrome.runtime.lastError.message);
      return;
    }
    if (!reply || !reply.ok) {
      notify("omarchy-continuity", "Other machine did not accept it: " + (reply && reply.reply ? reply.reply : "no reply"));
      return;
    }
    if (move && tab && tab.id !== undefined) chrome.tabs.remove(tab.id);
  });
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "open-link") send(info.linkUrl, tab, false);
  else if (info.menuItemId === "open-page") send(info.pageUrl || (tab && tab.url), tab, false);
  else if (info.menuItemId === "move-page") send(info.pageUrl || (tab && tab.url), tab, true);
});

// Toolbar button: move the current tab.
chrome.action.onClicked.addListener((tab) => send(tab.url, tab, true));

// Keyboard shortcuts (see manifest "commands"; changeable at chrome://extensions/shortcuts).
chrome.commands.onCommand.addListener(async (command) => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  if (command === "open-on-other") send(tab.url, tab, false);
  if (command === "move-to-other") send(tab.url, tab, true);
});
