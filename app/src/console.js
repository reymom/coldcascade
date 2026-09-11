// The shell: four tabs, the Desk first.
//
// One story per tab, each with its own header and its own action: the Desk is the live zero and
// the take; the Record is every fill against the band and the archive that answers for any
// instant; the Cascade is the same zero over 123 minutes of 10 Oct 2025; the Keys is who is
// trusted with what. The Cascade's replay is imported only when it is first opened — it fetches
// a 200-row CSV and the other three should not wait for it.

import { mountFloor } from "./floor.js";
import { mountRecord } from "./record.js";
import { mountArchive } from "./archive.js";
import { mountCarousel } from "./carousel.js";

const tabs = [
  { button: "tab-desk", panel: "panel-desk" },
  { button: "tab-record", panel: "panel-record" },
  { button: "tab-cascade", panel: "panel-cascade" },
  { button: "tab-keys", panel: "panel-keys" },
];

let cascadeLoaded = false;

async function show(button, panel) {
  for (const t of tabs) {
    const selected = t.button === button;
    document.getElementById(t.button).setAttribute("aria-selected", String(selected));
    document.getElementById(t.panel).hidden = !selected;
  }
  if (panel === "panel-cascade" && !cascadeLoaded) {
    cascadeLoaded = true;
    await import("./app.js");
  }
  // The panels differ in height, so a switch that kept the old scroll offset would land mid-air.
  window.scrollTo({ top: 0 });
}

for (const { button, panel } of tabs) {
  document.getElementById(button).addEventListener("click", () => show(button, panel));
}

// Cross-tab prose links are buttons with data-show-tab (a link would lie about going somewhere).
// Delegated once: the doors are rebuilt whenever the record lands, and their module re-renders
// the line it sits in.
document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-show-tab]");
  if (!b) return;
  const tab = tabs.find((t) => t.button === b.dataset.showTab);
  if (tab) show(tab.button, tab.panel);
});

mountFloor(document);
// The record reads its own file on its own cadence; it neither waits for the chain nor blocks it.
// The Desk's hero subscribes to this same read (onRecord in floor.js) rather than polling twice.
mountRecord(document);
// The archive is the record's other half: the record shows the fills, the archive answers for any
// instant. Same keeper pass, same cadence, and no chain needed — the file alone carries it.
mountArchive(document);
// The Cascade runs two galleries: the film's stills with their YouTube thumb above, and the
// four figures below — the three argument charts plus the day that grounds them. Same pattern,
// one instance each.
mountCarousel(document, "mech-carousel");
mountCarousel(document, "charts");
