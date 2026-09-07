/* The methods band's numbers write themselves when the cards first come
   into view, as hinge.co's do: each digit's outline clips a pen stroke
   along its centreline (see the markup), and `is-written` on the band
   starts the strokes in order, card after card. Runs once. */
(function () {
  var band = document.querySelector('.methods');
  var cards = band && band.querySelector('.methods-cards');
  if (!band || !cards) return;
  if (!('IntersectionObserver' in window) ||
      window.matchMedia('(prefers-reduced-motion: reduce)').matches) { band.classList.add('is-written'); return; }
  var io = new IntersectionObserver(function (entries) {
    if (!entries.some(function (e) { return e.isIntersecting; })) return;
    io.disconnect();
    band.classList.add('is-written');
  }, { threshold: 0.3 });
  io.observe(cards);
})();
