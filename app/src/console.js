// The shell: two tabs, the Floor first.
//
// The Evidence tab is the Oct-10 page unchanged, and it is imported only when it is first opened —
// it fetches a 200-row CSV and the Floor should not wait for it. It is also labelled a
// reproduction, on the tab and in its own header, so nothing on a live screen is a picture of
// something else.

import { mountFloor } from "./floor.js";

const tabs = [
  { button: "tab-floor", panel: "panel-floor" },
  { button: "tab-evidence", panel: "panel-evidence" },
];

let evidenceLoaded = false;

for (const { button, panel } of tabs) {
  document.getElementById(button).addEventListener("click", async () => {
    for (const t of tabs) {
      const selected = t.button === button;
      document.getElementById(t.button).setAttribute("aria-selected", String(selected));
      document.getElementById(t.panel).hidden = !selected;
    }
    if (panel === "panel-evidence" && !evidenceLoaded) {
      evidenceLoaded = true;
      await import("./app.js");
    }
  });
}

mountFloor(document);
