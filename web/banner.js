/* The banner takes the colour of what is under it, as hinge.co's header
   does (read 2026-09-06: their header is white, and a `dark` class turns
   it black with white links whenever a dark section is beneath it, on a
   300ms colour transition). Anything marked data-banner="dark" - the
   methods band, the footer - turns ours coal with white type while its
   bottom edge is under the banner's. The homepage's painting is handled by
   app.js's own `over-art`, which this never touches: the two cannot be
   true at once, the painting being at the top and the dark bands at the
   bottom. */
(function () {
  var banner = document.getElementById('banner');
  var bands = document.querySelectorAll('[data-banner="dark"]');
  if (!banner || !bands.length) return;

  function paint() {
    var edge = banner.getBoundingClientRect().bottom;
    var over = false;
    for (var i = 0; i < bands.length; i++) {
      var r = bands[i].getBoundingClientRect();
      if (r.top <= edge && r.bottom > edge) { over = true; break; }
    }
    banner.classList.toggle('over-dark', over);
  }

  var ticking = false;
  window.addEventListener('scroll', function () {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(function () { paint(); ticking = false; });
  }, { passive: true });
  window.addEventListener('resize', paint, { passive: true });
  window.addEventListener('load', paint);
  paint();
})();
