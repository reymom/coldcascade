// The Cascade's charts, as a product gallery: one at a time, arrows on the sides, and a counter
// that says how many there are. No library — a class toggle and a modulo index.

const MOD = "on";

export function mountCarousel(root, id) {
  const host = root.querySelector(`#${id}`);
  if (!host) return;
  const panels = host.querySelector("#panels");
  const slides = [...panels.querySelectorAll(":scope > section")];
  const count = root.querySelector(".car-count");
  const prev = host.querySelector(".car-prev");
  const next = host.querySelector(".car-next");
  if (!slides.length) return;

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
