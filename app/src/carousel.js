// Any block of slides, as a product gallery: one at a time, arrows on the sides, and a counter
// that says how many there are. No library — a class toggle and a modulo index. The host carries
// its slides as direct children (figures or sections), its two arrows, and its counter, so one
// page can hold several carousels and each keeps its own index.

const MOD = "on";

export function mountCarousel(root, id) {
  const host = root.querySelector(`#${id}`);
  if (!host) return;
  const slides = [...host.children].filter((c) => c.matches("figure, section"));
  const prev = host.querySelector(":scope > .car-prev");
  const next = host.querySelector(":scope > .car-next");
  const count = host.querySelector(":scope > .car-count");
  if (!slides.length || !prev || !next) return;

  let i = 0;
  const show = (n) => {
    i = (n + slides.length) % slides.length;
    slides.forEach((slide, k) => slide.classList.toggle(MOD, k === i));
    if (count) count.textContent = `${i + 1} / ${slides.length}`;
  };
  prev.addEventListener("click", () => show(i - 1));
  next.addEventListener("click", () => show(i + 1));
  show(0);
  host.hidden = false;
}
