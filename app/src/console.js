// The shell: four tabs, the Desk first.
//
// One story per tab, each with its own header and its own action: the Desk is the live zero and
// the take; the Record is every fill against the band and the archive that answers for any
// instant; the Cascade is the same zero over 123 minutes of 10 Oct 2025; the Keys is who is
// trusted with what. The Cascade's replay is imported only when it is first opened — it fetches
// a 200-row CSV and the other three should not wait for it. The Cascade's carousel wires itself
// with the shell: the slides are markup, the chart joins them when the tab first opens.

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

// The Desk's strip makes a claim about this block; the Cascade makes the same claim about 123 of
// them. The link between them is in the prose, so it should also be in the page.
document.getElementById("go-cascade")?.addEventListener("click", () => {
  show("tab-cascade", "panel-cascade");
});

// Cross-tab prose links are buttons with data-show-tab (a link would lie about going somewhere).
// Delegated once: the hero's record grounding lives beside the zero, and its module re-renders
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
// The carousel hides before there are charts and shows with them — the slides are six sections
// (the film's three stills, then the three at-la charts) and the counter says so the moment
// there is something to count. The day itself and the lean live in the fold below it.
mountCarousel(document, "carousel");
