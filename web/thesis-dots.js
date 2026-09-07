/* The trail of dots after "more swipes" (owner, 2026-09-05): six round
   dots the size of the heading's period, the first gap its advance plus
   15px and each gap after wider by 2, 5.4, 14.6 then 39.4px. The
   first sits on the baseline where a typeset period would; from the
   second the trail leaves it and turns toward the top-left corner of "you need better
   representation." Drawn rather than typeset because Quicksand's period is
   not quite round at this size, and a drawn circle is. The corner moves
   with the viewport, so the trail is measured rather than fixed: the
   period's size, its advance and the font's descent come off a canvas, the
   dot centres are sampled along the curve, and the lot is redrawn on
   resize. */
(function () {
  var lead = document.querySelector('.thesis-lead');
  /* the corner aimed at is the first line's, so a right-aligned heading
     whose longest line is its last still points at "you need" */
  var turn = document.querySelector('.thesis-turn-first') || document.querySelector('.thesis-turn');
  var inner = document.querySelector('.thesis-inner');
  var pair = lead && lead.querySelector('.thesis-dots');
  if (!lead || !turn || !inner || !pair) return;

  var NS = 'http://www.w3.org/2000/svg';
  var svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('class', 'thesis-trail');
  svg.setAttribute('aria-hidden', 'true');
  var path = document.createElementNS(NS, 'path');
  inner.appendChild(svg);

  var canvas = document.createElement('canvas').getContext('2d');
  var dots = [];

  function draw() {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var cs = getComputedStyle(lead);
    var px = parseFloat(cs.fontSize);
    canvas.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
    var m = canvas.measureText('.');
    var h = m.actualBoundingBoxAscent || px * 0.09;
    var w = (m.actualBoundingBoxRight || 0) - (m.actualBoundingBoxLeft || 0) || h;
    var r = Math.min(h, w) / 2 * 1.25;                   /* round, never the glyph's taller side; a quarter over the period (owner, 2026-09-06) */
    var gap = m.width + 15;                             /* the period's advance, plus 15px (owner: 5, then 10 more) */
    var descent = m.fontBoundingBoxDescent || px * 0.25;

    var box = inner.getBoundingClientRect();
    var p = pair.getBoundingClientRect();
    var t = turn.getBoundingClientRect();
    svg.setAttribute('viewBox', '0 0 ' + box.width + ' ' + box.height);
    svg.setAttribute('width', box.width);
    svg.setAttribute('height', box.height);

    /* each dot's nudge off the computed curve, in px, set by eye against
       the owner's mock of 2026-09-06 */
    var nudge = [[0, 0], [1, -3], [6, -11], [16, -11], [16, -3], [8, 0]];
    var n = 0;
    dots = [];
    function dot(x, y) {
      var c = document.createElementNS(NS, 'circle');
      c.setAttribute('cx', x + nudge[n][0]);
      c.setAttribute('cy', y + nudge[n][1]);
      dots.push({ el: c, x: x + nudge[n][0], y: y + nudge[n][1] });
      n++;
      c.setAttribute('r', r);
      svg.appendChild(c);
    }

    /* the first sits on the baseline where a period would fall */
    var x0 = p.left - box.left + gap * 0.5 + 5;
    var y0 = p.bottom - box.top - descent - r;
    dot(x0, y0);

    /* the curve starts at the first dot and runs nearly level through
       the second, then falls toward the corner of "you need" without
       reaching it (owner, 2026-09-05: the second dot sat too low on every
       quadratic tried, since a quadratic's far end pulls its start down
       too). A cubic instead: the first control point two gaps out on the
       baseline holds the start flat, the second lies from there in the
       direction of the corner, and the end continues that line, so the
       last dots point at it */
    var sx = x0, sy = y0;
    var c1x = sx + gap * 2, c1y = sy;
    /* the aim is the corner of "you need" where it stands (owner,
       2026-09-05: re-aimed after the heading moved) */
    var tx = (t.left - box.left) - c1x, ty = (t.top - box.top) - c1y;
    /* on a phone the second half stands almost directly beneath, so a
       trail aimed at it would plunge; the six stay on the baseline there */
    /* the gaps open as the trail goes (owner, 2026-09-05): the first is
       the gap, then 2, 5.4, 14.6 and 39.4px wider - 2.7 times each step */
    var along = [0], extra = 0;
    for (var k = 1; k < 6; k++) {
      along.push(along[k - 1] + gap + extra);
      extra = extra ? extra * 2.7 : 2;
    }
    if (ty <= 0 || !window.matchMedia('(min-width: 768px)').matches) {
      for (var j = 1; j < 6; j++) dot(sx + along[j], sy);
      return;
    }
    var tl = Math.sqrt(tx * tx + ty * ty) || 1;
    var ux = tx / tl, uy = ty / tl;
    var c2x = c1x + ux * gap * 2, c2y = c1y + uy * gap * 2;
    /* the end runs on far enough that the last dot still lands on the
       curve, whatever the gaps add up to */
    var run = Math.max(1.6, along[5] / gap - 2.5);
    var ex = c2x + ux * gap * run, ey = c2y + uy * gap * run;

    path.setAttribute('d', 'M' + sx + ' ' + sy +
      ' C' + c1x + ' ' + c1y + ', ' + c2x + ' ' + c2y + ', ' + ex + ' ' + ey);
    var len = path.getTotalLength();
    for (var i = 1; i < 6; i++) {
      var pt = path.getPointAtLength(Math.min(along[i], len));
      dot(pt.x, pt.y);
    }
    arm(x0, y0, gap);
  }

  /* The reveal (owner, 2026-09-06), in three beats once the heading first
     comes into view: the first half wipes in from the left over 0.9s;
     then the whip - the six dots start level on the baseline, one gap
     apart, and fall to their places in turn, each a beat after the one
     before, land, bounce up a little and down, then up and down again by
     half as much; then the second half wipes in from the left. The
     wipes are CSS (a mask that slides), keyed off `thesis-in`; the whip
     is scripted here. The trail is redrawn when the fonts arrive and on
     resize, so a redraw during the whip continues it on the new dots
     from the same moment rather than restarting or dropping it. */
  var WIPE = 1800;                       /* each wipe, ms (owner: twice the first cut) */
  var WHIP_AT = 600;                     /* the whip starts as the wipe's soft edge clears the words (owner: 0.6s) */
  var reveal = 'IntersectionObserver' in window && 'animate' in svg &&
               !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var whipStart = null;
  if (reveal) inner.classList.add('thesis-reveal');   /* CSS hides both halves until `thesis-in` */

  function frames(d) {
    var at = function (ox, oy) { return 'translate(' + ox + 'px,' + oy + 'px)'; };
    return [
      { transform: at(d.sx - d.x, d.sy - d.y), offset: 0, easing: 'cubic-bezier(.55, 0, 1, .45)' },
      { transform: at(0, 0), offset: .5, easing: 'ease-out' },
      { transform: at(0, -8), offset: .64, easing: 'ease-in' },
      { transform: at(0, 0), offset: .78, easing: 'ease-out' },
      { transform: at(0, -4), offset: .89, easing: 'ease-in' },
      { transform: at(0, 0), offset: 1 }
    ];
  }
  function play() {
    var elapsed = performance.now() - whipStart;
    dots.forEach(function (d, k) {
      if (d.sx === undefined) return;               /* a phone: the six already sit level */
      var a = d.el.animate(frames(d), { duration: 1150, delay: WHIP_AT + k * 75, fill: 'both' });
      if (elapsed > 0) a.currentTime = elapsed;
    });
  }
  /* The first wipe carries the trail with it: the heading's own mask and
     a mask on the trail share one geometry - a gradient M wide, opaque
     for its first two fifths, where M is two and a half times the
     heading plus room for the dots - and slide together, so the soft
     edge that reveals "more swipes" runs straight on over the six. The
     slide itself is a CSS keyframe (thesis-wipe-px) reading --wipe-from
     and --wipe-to, set here in px: Chrome animates a mask position from a
     stylesheet and not from the script's animate(), measured 2026-09-06. */
  function measureWipe() {
    var box = inner.getBoundingClientRect(), lb = lead.getBoundingClientRect();
    var L = lb.left - box.left, W = lb.width, D = Math.max(160, W * 0.45);
    var M = 2.5 * (W + D);
    [[lead, 0], [svg, L]].forEach(function (pair) {
      var el = pair[0], base = pair[1];
      el.style.webkitMaskImage = el.style.maskImage = 'linear-gradient(to right, #000 40%, rgba(0,0,0,0) 60%)';
      el.style.webkitMaskRepeat = el.style.maskRepeat = 'no-repeat';
      el.style.webkitMaskSize = el.style.maskSize = M + 'px 100%';
      el.style.setProperty('--wipe-from', (base - 0.6 * M) + 'px');
      el.style.setProperty('--wipe-to', base + 'px');
      el.style.webkitMaskPosition = el.style.maskPosition = 'var(--wipe-from) 0px';
    });
  }

  /* called after the desktop dots are placed: where each starts from */
  function arm(x0, y0, gap) {
    if (!reveal) return;
    dots.forEach(function (d, k) { d.sx = x0 + gap * k; d.sy = y0; });
    if (whipStart !== null) {
      measureWipe();                                    /* the running wipe reads the new geometry */
      if (performance.now() - whipStart < WHIP_AT + 1700) play();   /* redrawn mid-whip: carry on */
      return;
    }
    dots.forEach(function (d) { d.el.style.transform = 'translate(' + (d.sx - d.x) + 'px,' + (d.sy - d.y) + 'px)'; });
    measureWipe();
  }
  if (reveal) {
    var io = new IntersectionObserver(function (entries) {
      if (!entries.some(function (e) { return e.isIntersecting; })) return;
      io.disconnect();
      inner.classList.add('thesis-in');
      whipStart = performance.now();
      play();
    }, { threshold: 0.6 });
    io.observe(lead);
  }

  var pending = null;
  function schedule() {
    if (pending) cancelAnimationFrame(pending);
    pending = requestAnimationFrame(function () { pending = null; draw(); });
  }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(schedule);
  window.addEventListener('load', schedule);
  window.addEventListener('resize', schedule);
  schedule();
})();
