// The shell: two tabs, the Floor first.
//
// The Evidence tab is the Oct-10 page unchanged, and it is imported only when it is first opened —
// it fetches a 200-row CSV and the Floor should not wait for it. It is also labelled a
// reproduction, on the tab and in its own header, so nothing on a live screen is a picture of
// something else.

import { mountFloor } from "./floor.js";
import { mountRecord } from "./record.js";

const tabs = [
  { button: "tab-floor", panel: "panel-floor" },
  { button: "tab-evidence", panel: "panel-evidence" },
];

let evidenceLoaded = false;

async function show(button, panel) {
  for (const t of tabs) {
    const selected = t.button === button;
    document.getElementById(t.button).setAttribute("aria-selected", String(selected));
    document.getElementById(t.panel).hidden = !selected;
  }
  if (panel === "panel-evidence" && !evidenceLoaded) {
    evidenceLoaded = true;
    await import("./app.js");
  }
}

for (const { button, panel } of tabs) {
  document.getElementById(button).addEventListener("click", () => show(button, panel));
}

// The Floor's arbitrage panel makes a claim about this block; the Evidence tab makes the same claim
// about 123 of them. The link between them is in the prose, so it should also be in the page.
document.getElementById("go-evidence")?.addEventListener("click", () => {
  show("tab-evidence", "panel-evidence");
  document.getElementById("panel-evidence").scrollIntoView({ behavior: "smooth", block: "start" });
});

mountFloor(document);
// The record reads its own file on its own cadence; it neither waits for the chain nor blocks it.
mountRecord(document);
