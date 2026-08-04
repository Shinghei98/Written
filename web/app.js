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
  var ink     = document.getElementById('ink');
  var slogan  = document.getElementById('introSlogan');
  var skipBtn = document.getElementById('skipIntro');
  var banner  = document.getElementById('banner');
  var hero    = document.getElementById('hero');

  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  /* ---------------------------------------------------------------------
     The opening
     --------------------------------------------------------------------- */

  // The words rise one after another; the index drives the stagger so the
  // count can change in the HTML without touching the CSS.
  if (slogan) {
    Array.prototype.forEach.call(slogan.children, function (word, i) {
      word.style.setProperty('--i', i);
    });
  }

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

  function play() {
    if (!intro || !ink) return;

    document.documentElement.classList.add('intro-active');

    // Review affordances, the same pair the app's own logo animation carries:
    // `?p=0.6` freezes the write-on at a fraction so a still can be judged
    // without racing the clock, and `?intro=0` opens straight onto the page.
    // Screenshotting the live animation is not a substitute — a headless
    // browser paces requestAnimationFrame by frames rather than by seconds,
    // so a timed capture says nothing about what a reader sees.
    var params = new URLSearchParams(window.location.search);

    if (params.get('intro') === '0') {
      intro.classList.add('done');
      document.documentElement.classList.remove('intro-active');
      lifted = true;
      jumpToHash();
      return;
    }

    if (params.has('p')) {
      var p = Math.max(0, Math.min(1, parseFloat(params.get('p')) || 0));
      var total = ink.getTotalLength();
      ink.style.strokeDasharray = total;
      ink.style.strokeDashoffset = total * (1 - p);
      if (p >= 1 && slogan) slogan.classList.add('arrive');
      if (skipBtn) skipBtn.classList.add('show');
      return;
    }

    if (reduce) {
      ink.style.strokeDasharray = 'none';
      ink.style.strokeDashoffset = '0';
      if (slogan) slogan.classList.add('arrive');
      window.setTimeout(lift, 900);
      return;
    }

    // The dash has to be the path's real length or the stroke either stops
    // short of the nib or finishes before the animation does.
    var len = ink.getTotalLength();
    ink.style.strokeDasharray = len;
    ink.style.strokeDashoffset = len;

    // Frame by frame, not by transition: the path is inside `<defs>` and is
    // therefore not a rendered element, so a CSS transition on it never runs.
    // The same easing and the same 2600ms as the app's own write-on.
    var DUR = 2600, start = null;

    function frame(now) {
      if (start === null) start = now;
      var t = Math.min((now - start) / DUR, 1);
      var e = t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      ink.style.strokeDashoffset = len * (1 - e);
      if (t < 1 && !lifted) window.requestAnimationFrame(frame);
    }
    window.requestAnimationFrame(frame);

    // The writing finishes, then the words, then a beat to read them.
    window.setTimeout(function () { if (slogan) slogan.classList.add('arrive'); }, DUR - 100);
    window.setTimeout(function () { if (skipBtn) skipBtn.classList.add('show'); }, 700);
    window.setTimeout(lift, 4600);
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
