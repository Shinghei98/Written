/* The book viewer, in the manner of the Flipsnack player hinge.co embeds
   under "How We Do Things" (read 2026-09-06): a book centred on a dark
   stage, a spread at a time with the cover alone, pages that turn, and a
   bar beneath with the arrows, the page count, zoom out and in, the grid
   of every page, and full screen. Ours is built rather than embedded, so
   the pages are the ordinary HTML in the document - readable with no
   script, indexable, and typeset in the site's own faces - and the script
   only arranges them. Nothing here talks to a server. */
(function () {
  var root = document.querySelector('.book');
  var source = root && root.querySelector('.book-pages');
  if (!root || !source) return;

  var pages = Array.prototype.map.call(source.children, function (li) { return li; });
  var total = pages.length;
  if (!total) return;

  /* ---- build the stage --------------------------------------------- */
  var viewer = document.createElement('div');
  viewer.className = 'book-viewer';
  viewer.innerHTML =
    '<div class="book-stage" tabindex="0" aria-label="The book. Use the arrow keys to turn the pages.">' +
      '<button class="book-arrow book-prev" type="button" aria-label="Previous page"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
      '<div class="book-scroll"><div class="book-spread"><div class="book-leaf book-left"></div><div class="book-leaf book-right"></div></div></div>' +
      '<button class="book-arrow book-next" type="button" aria-label="Next page"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
    '</div>' +
    '<div class="book-bar" role="toolbar" aria-label="Book controls">' +
      '<button class="book-btn book-bar-prev" type="button" aria-label="Previous page"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
      '<span class="book-count" aria-live="polite"></span>' +
      '<button class="book-btn book-bar-next" type="button" aria-label="Next page"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
      '<span class="book-bar-gap"></span>' +
      '<button class="book-btn book-zoom-out" type="button" aria-label="Zoom out"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 11h6M16.5 16.5L21 21" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button>' +
      '<button class="book-btn book-zoom-in" type="button" aria-label="Zoom in"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 11h6M11 8v6M16.5 16.5L21 21" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button>' +
      '<button class="book-btn book-grid-btn" type="button" aria-label="All pages"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg></button>' +
      '<button class="book-btn book-full" type="button" aria-label="Full screen"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
    '</div>' +
    '<div class="book-grid" hidden>' +
      '<div class="book-grid-head"><span class="book-grid-title">All pages</span><button class="book-btn book-grid-close" type="button" aria-label="Close"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button></div>' +
      '<div class="book-grid-body"></div>' +
    '</div>';
  root.appendChild(viewer);
  source.hidden = true;

  var stage = viewer.querySelector('.book-stage');
  var scroll = viewer.querySelector('.book-scroll');
  var spread = viewer.querySelector('.book-spread');
  var leftLeaf = viewer.querySelector('.book-left');
  var rightLeaf = viewer.querySelector('.book-right');
  var count = viewer.querySelector('.book-count');
  var grid = viewer.querySelector('.book-grid');
  var gridBody = viewer.querySelector('.book-grid-body');

  /* ---- state ---------------------------------------------------------- */
  var index = 0;          /* the page on the right of the spread (0 = cover) */
  var zoom = 1;
  var turning = false;
  var single = function () { return window.matchMedia('(max-width: 767px)').matches; };

  /* `inside` is the cover seen from within the book - the cloth without
     the mark, as the inside of a cover is */
  function clone(i, inside) {
    var el = document.createElement('div');
    el.className = 'book-page' +
      (pages[i].classList.contains('book-cover') ? ' book-page-cover' : '') +
      (pages[i].classList.contains('book-back') ? ' book-page-cover book-page-back' : '') +
      (inside ? ' book-page-inside' : '');
    el.innerHTML = pages[i].innerHTML;
    return el;
  }

  /* On a desktop the spread shows [index-1, index]; the cover (0) stands
     alone on the right, as a closed book does, and so does a last page
     that falls on the left. On a phone one page shows at a time. */
  function fill(leaf, i) {
    leaf.innerHTML = '';
    leaf.classList.toggle('book-blank', i < 0 || i >= total);
    if (i >= 0 && i < total) leaf.appendChild(clone(i, leaf === leftLeaf && i === 0));
  }

  /* The closed book is centred on the stage; the open book is centred on
     its spine, as hinge.co's is. The spread is always two pages wide with
     the spine at the centre, so a lone cover is shifted half a page toward
     the middle and a lone last page half a page the other way, and the
     shift transitions while the leaf turns. */
  function centre(i) {
    var lastAlone = !single() && i === total - 1 && (total - 1) % 2 === 1 && false;
    spread.classList.toggle('book-closed', i === 0);
    spread.classList.toggle('book-last-alone', lastAlone);
  }

  function render() {
    if (single()) {
      leftLeaf.hidden = true;
      fill(rightLeaf, index);
      count.textContent = (index + 1) + ' / ' + total;
    } else {
      leftLeaf.hidden = false;
      var left = index === 0 ? -1 : index - 1;
      fill(leftLeaf, left);
      fill(rightLeaf, index);
      count.textContent = (index === 0 ? '1' : (left + 1) + '-' + Math.min(index + 1, total)) + ' / ' + total;
    }
    centre(index);
    viewer.querySelector('.book-prev').disabled = viewer.querySelector('.book-bar-prev').disabled = index <= 0;
    var last = single() ? index >= total - 1 : index >= total - 1;
    viewer.querySelector('.book-next').disabled = viewer.querySelector('.book-bar-next').disabled = last;
  }

  /* ---- turning ------------------------------------------------------- */
  /* Forward: a leaf lifts off the right page and swings to the left about
     the spine, showing the next left page on its back. Backward is the
     same swing in reverse from the left. On a phone every turn is a
     single page swinging about its left edge. */
  function turn(dir) {
    if (turning) return;
    var step = single() ? 1 : 2;
    var next;
    if (dir > 0) {
      next = index === 0 ? 1 : index + step;
      if (index >= total - 1) return;
      if (next > total - 1) next = total - 1;
      if (!single() && index !== 0 && next === index) return;
    } else {
      if (index <= 0) return;
      next = index === 1 ? 0 : index - step;
      if (next < 0) next = 0;
    }
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) { index = next; render(); return; }

    turning = true;
    centre(next);
    var leaf = document.createElement('div');
    leaf.className = 'book-turning ' + (dir > 0 ? 'book-turn-forward' : 'book-turn-back');
    var front = document.createElement('div'); front.className = 'book-face book-face-front';
    var back = document.createElement('div'); back.className = 'book-face book-face-back';
    if (dir > 0) {
      front.appendChild(clone(index));                              /* the page leaving */
      var backIdx = single() ? next : next - 1;
      if (backIdx >= 0 && backIdx < total) back.appendChild(clone(backIdx, !single() && backIdx === 0));
    } else {
      var leaving = single() ? index : index - 1;
      if (leaving >= 0) front.appendChild(clone(leaving, !single() && leaving === 0));
      back.appendChild(clone(next));
    }
    leaf.appendChild(front); leaf.appendChild(back);
    spread.appendChild(leaf);
    if (dir > 0) rightLeaf.classList.add('book-under'); else leftLeaf.classList.add('book-under');
    /* what shows beneath the moving leaf is the spread as it will be */
    var willLeft = single() ? -1 : (next === 0 ? -1 : next - 1);
    if (dir > 0) { fill(rightLeaf, next); }
    else { if (!single()) fill(leftLeaf, willLeft); else fill(rightLeaf, next); }

    requestAnimationFrame(function () { requestAnimationFrame(function () { leaf.classList.add('book-turn-go'); }); });
    var done = function () {
      leaf.removeEventListener('transitionend', done);
      if (leaf.parentNode) leaf.parentNode.removeChild(leaf);
      rightLeaf.classList.remove('book-under'); leftLeaf.classList.remove('book-under');
      index = next; turning = false; render();
    };
    leaf.addEventListener('transitionend', done);
    setTimeout(function () { if (turning) done(); }, 1100);
  }

  function goTo(i) { index = i; render(); }

  /* ---- sizing ---------------------------------------------------------- */
  /* A page is 5:7. At zoom 1 the spread fits the stage; the type is set
     from the page's width so a page reads the same at every size. */
  function size() {
    var box = stage.getBoundingClientRect();
    var pad = 32;
    var availH = box.height - pad * 2;
    var availW = box.width - (single() ? pad * 2 : 140);
    var perPage = single() ? 1 : 2;
    var w = Math.min(availW / perPage, availH * 5 / 7);
    w = Math.max(200, Math.floor(w * zoom));
    viewer.style.setProperty('--page-w', w + 'px');
    viewer.style.setProperty('--page-h', Math.round(w * 7 / 5) + 'px');
    viewer.style.setProperty('--page-fs', (w * 0.032).toFixed(2) + 'px');
    scroll.classList.toggle('book-zoomed', zoom > 1);
  }

  function setZoom(z) {
    zoom = Math.max(1, Math.min(2.5, z));
    size();
    viewer.querySelector('.book-zoom-out').disabled = zoom <= 1;
    viewer.querySelector('.book-zoom-in').disabled = zoom >= 2.5;
  }

  /* ---- the grid --------------------------------------------------------- */
  function openGrid() {
    if (!gridBody.childNodes.length) {
      pages.forEach(function (p, i) {
        var cell = document.createElement('button');
        cell.type = 'button';
        cell.className = 'book-thumb';
        cell.setAttribute('aria-label', 'Page ' + (i + 1));
        var frame = document.createElement('div'); frame.className = 'book-thumb-frame';
        frame.appendChild(clone(i));
        var num = document.createElement('span'); num.className = 'book-thumb-num'; num.textContent = i + 1;
        cell.appendChild(frame); cell.appendChild(num);
        cell.addEventListener('click', function () { closeGrid(); goTo(i); });
        gridBody.appendChild(cell);
      });
    }
    grid.hidden = false;
    root.classList.add('book-grid-open');
    viewer.querySelector('.book-grid-close').focus();
  }
  function closeGrid() {
    grid.hidden = true;
    root.classList.remove('book-grid-open');
    stage.focus();
  }

  /* ---- full screen -------------------------------------------------------- */
  function toggleFull() {
    var el = root;
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    } else if (el.requestFullscreen) el.requestFullscreen();
    else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen();
  }
  function onFullChange() {
    root.classList.toggle('book-fullscreen', !!(document.fullscreenElement || document.webkitFullscreenElement));
    size();
  }
  document.addEventListener('fullscreenchange', onFullChange);
  document.addEventListener('webkitfullscreenchange', onFullChange);

  /* ---- wiring --------------------------------------------------------------- */
  viewer.querySelector('.book-prev').addEventListener('click', function () { turn(-1); });
  viewer.querySelector('.book-next').addEventListener('click', function () { turn(1); });
  viewer.querySelector('.book-bar-prev').addEventListener('click', function () { turn(-1); });
  viewer.querySelector('.book-bar-next').addEventListener('click', function () { turn(1); });
  viewer.querySelector('.book-zoom-out').addEventListener('click', function () { setZoom(zoom - 0.25); });
  viewer.querySelector('.book-zoom-in').addEventListener('click', function () { setZoom(zoom + 0.25); });
  viewer.querySelector('.book-grid-btn').addEventListener('click', openGrid);
  viewer.querySelector('.book-grid-close').addEventListener('click', closeGrid);
  viewer.querySelector('.book-full').addEventListener('click', toggleFull);
  rightLeaf.addEventListener('click', function () { if (zoom === 1) turn(1); });
  leftLeaf.addEventListener('click', function () { if (zoom === 1) turn(-1); });
  stage.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowRight') { turn(1); e.preventDefault(); }
    else if (e.key === 'ArrowLeft') { turn(-1); e.preventDefault(); }
    else if (e.key === 'Escape' && !grid.hidden) closeGrid();
  });
  grid.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeGrid(); });

  /* a swipe turns a page on a phone */
  var touchX = null;
  stage.addEventListener('touchstart', function (e) { if (zoom === 1) touchX = e.touches[0].clientX; }, { passive: true });
  stage.addEventListener('touchend', function (e) {
    if (touchX === null) return;
    var dx = e.changedTouches[0].clientX - touchX; touchX = null;
    if (Math.abs(dx) > 40) turn(dx < 0 ? 1 : -1);
  }, { passive: true });

  var wasSingle = single();
  window.addEventListener('resize', function () {
    if (single() !== wasSingle) { wasSingle = single(); render(); }
    size();
  }, { passive: true });

  /* #book-7 opens the book at page 7: a deep link, and how the pages are
     screenshotted without a tap */
  var m = /^#book-(\d+)$/.exec(window.location.hash);
  if (m) index = Math.max(0, Math.min(total - 1, parseInt(m[1], 10) - 1));

  if (document.fonts && document.fonts.ready) document.fonts.ready.then(size);
  size();
  setZoom(1);
  render();
})();
