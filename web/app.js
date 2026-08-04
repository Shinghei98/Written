/* ==========================================================================
   Written — one page
   --------------------------------------------------------------------------
   Three jobs: play the opening and get out of the way, tell the banner what
   is behind it, and grow the vine as the reader arrives at it.
   ========================================================================== */

(function () {
  'use strict';

  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  var intro   = document.getElementById('intro');
  var mark    = document.getElementById('introMark');
  var skipBtn = document.getElementById('skipIntro');
  var banner  = document.getElementById('banner');
  var hero    = document.getElementById('hero');

  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  /* ---------------------------------------------------------------------
     The opening
     --------------------------------------------------------------------- */

  var lifted = false;

  /* A deep link must land, not travel. `scroll-behavior: smooth` is right for
     a tapped link and wrong for arriving with a fragment already in the URL:
     the page sets off from the top and animates the whole painting past the
     reader before settling. Instant on arrival, smooth on click. */
  function jumpToHash() {
    if (!window.location.hash) return;
    var target;
    try { target = document.querySelector(window.location.hash); } catch (e) { return; }
    if (!target) return;
    var root = document.documentElement;
    var was = root.style.scrollBehavior;
    root.style.scrollBehavior = 'auto';
    target.scrollIntoView();
    root.style.scrollBehavior = was;
  }

  function lift() {
    if (lifted || !intro) return;
    lifted = true;
    if (skipBtn) skipBtn.classList.remove('show');
    intro.classList.add('lift');
    document.documentElement.classList.remove('intro-active');

    // Nothing may be left covering the page — a fixed layer with a transform
    // still catches clicks in some browsers even when it is off screen.
    window.setTimeout(function () {
      intro.classList.add('done');
      jumpToHash();          // arriving at /#privacy should end up at privacy
      window.dispatchEvent(new Event('scroll'));
    }, reduce ? 0 : 1200);
  }

  /* The frames run for 4.73s in total: the mark and the words are finished at
     about 2.9s and the last frame is held for 1.8s. Lifting at 4.2s leaves a
     beat to read the line and still clears the screen before the held frame
     has fully run out, so the reader never waits on a still picture.

     These numbers come from the file rather than from taste — see
     `webpmux -info assets/intro.webp`. Re-cut the animation and they move. */
  var INTRO_MS = 4200;

  function play() {
    if (!intro) return;

    document.documentElement.classList.add('intro-active');

    // `?intro=0` opens straight onto the page. There is no `?p=` any more:
    // freezing a fraction was a property of the vector reconstruction, and
    // these are baked frames.
    var params = new URLSearchParams(window.location.search);

    if (params.get('intro') === '0') {
      intro.classList.add('done');
      document.documentElement.classList.remove('intro-active');
      lifted = true;
      jumpToHash();
      return;
    }

    // **Reduced motion gets the last frame, not a faster version of the
    // animation.** An animated image cannot be paused from script, so the only
    // way to honour the preference is to serve a still instead — and because
    // it is a `<picture>`, the `<source>` has to go too or it keeps winning.
    if (reduce) {
      if (mark) {
        var source = mark.parentNode.querySelector('source');
        if (source) source.parentNode.removeChild(source);
        mark.src = '/assets/intro-still.png';
      }
      window.setTimeout(lift, 1200);
      return;
    }

    window.setTimeout(function () { if (skipBtn) skipBtn.classList.add('show'); }, 900);
    window.setTimeout(lift, INTRO_MS);
  }

  if (intro) {
    if (skipBtn) skipBtn.addEventListener('click', lift);
    intro.addEventListener('click', function (e) { if (e.target !== skipBtn) lift(); });
    window.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' || e.key === 'Enter' || e.key === ' ') lift();
    });
    // A finger or a wheel means "I have seen it".
    window.addEventListener('wheel', lift, { passive: true, once: true });
    window.addEventListener('touchmove', lift, { passive: true, once: true });

    if (document.readyState === 'complete') play();
    else window.addEventListener('load', play);
  }

  /* ---------------------------------------------------------------------
     The banner
     --------------------------------------------------------------------- */

  function paintBanner() {
    if (!banner || !hero) return;
    var overArt = hero.getBoundingClientRect().bottom > (banner.offsetHeight + 8);
    banner.classList.toggle('over-art', overArt);
  }

  var ticking = false;
  window.addEventListener('scroll', function () {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(function () { paintBanner(); ticking = false; });
  }, { passive: true });

  window.addEventListener('resize', paintBanner, { passive: true });
  paintBanner();

  /* ---------------------------------------------------------------------
     The vine
     --------------------------------------------------------------------- */

  var stages = document.querySelectorAll('.stage');
  var frame  = document.querySelector('.stages-frame');
  var rail   = document.getElementById('vineRail');

  var qs = new URLSearchParams(window.location.search);
  var grownParam = qs.get('grown') === '1';
  if (qs.get('flat') === '1') document.documentElement.classList.add('flat');

  var animate = !reduce && !grownParam && 'IntersectionObserver' in window;

  // Opting the page into the hidden state, rather than the stylesheet doing
  // it, is what keeps a script failure from erasing the prose.
  if (animate) document.documentElement.classList.add('js-reveal');

  if (!animate) {
    Array.prototype.forEach.call(stages, function (s) { s.classList.add('grown'); });
  } else {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('grown');
        seen.unobserve(entry.target);       // it grows once; it does not un-grow
      });
    }, { rootMargin: '0px 0px -18% 0px', threshold: 0.18 });

    Array.prototype.forEach.call(stages, function (s) { seen.observe(s); });

    // The stem follows the reader down rather than appearing in four jumps:
    // the tile is clipped to however far through the section they have come.
    // It never retreats — a vine that ungrows on the way back up reads as a
    // bug rather than as an effect.
    var reached = 0;

    var growVine = function () {
      if (!frame || !rail) return;
      var box = frame.getBoundingClientRect();
      var seenPx = window.innerHeight * 0.82 - box.top;
      var progress = Math.max(0, Math.min(1, seenPx / Math.max(box.height, 1)));
      if (progress <= reached) return;
      reached = progress;
      rail.style.setProperty('--ungrown', ((1 - reached) * 100).toFixed(2) + '%');
    };

    var vineTicking = false;
    window.addEventListener('scroll', function () {
      if (vineTicking) return;
      vineTicking = true;
      window.requestAnimationFrame(function () { growVine(); vineTicking = false; });
    }, { passive: true });

    window.addEventListener('resize', growVine, { passive: true });
    growVine();
  }
})();
