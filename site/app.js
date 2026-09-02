// The plugin band: one tab list, one visible pane. On a wide screen the band
// holds one screen still and the scroll steps through the panes; narrower than
// that (see styles.css) it stays a tab list you click.
(function () {
  const tabs = Array.from(document.querySelectorAll('.plugins [role="tab"]'));
  if (!tabs.length) return;

  const panes = tabs.map((tab) => document.getElementById(tab.getAttribute('aria-controls')));
  const track = document.querySelector('.band-track');
  const stepped = window.matchMedia('(min-width: 901px)');
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  let current = -1;

  function select(index) {
    if (index === current) return;
    current = index;
    tabs.forEach((tab, i) => {
      tab.setAttribute('aria-selected', String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
      if (panes[i]) panes[i].classList.toggle('is-on', i === index);
    });
  }

  /* Where the page has to be for pane i to be the one showing. The track is
     n * --step tall plus one screen, and the sticky screen sits still for the
     whole of it, so each pane owns an equal slice of that scroll. */
  function offsetFor(index) {
    const span = track.offsetHeight - window.innerHeight;
    return track.offsetTop + span * ((index + 0.5) / tabs.length);
  }

  function scrollToPane(index) {
    if (!driven()) return;
    window.scrollTo({ top: offsetFor(index), behavior: still.matches ? 'auto' : 'smooth' });
  }

  function driven() { return track && stepped.matches && !still.matches; }

  function frame() {
    queued = false;
    if (!driven()) return;
    const r = track.getBoundingClientRect();
    const span = r.height - window.innerHeight;
    const p = span > 0 ? -r.top / span : 0;
    select(Math.max(0, Math.min(tabs.length - 1, Math.floor(p * tabs.length))));
  }

  let queued = false;
  function tick() { if (!queued) { queued = true; requestAnimationFrame(frame); } }

  tabs.forEach((tab, i) => {
    tab.tabIndex = i === 0 ? 0 : -1;
    tab.addEventListener('click', () => { select(i); scrollToPane(i); });
    tab.addEventListener('keydown', (event) => {
      const step = event.key === 'ArrowDown' ? 1 : event.key === 'ArrowUp' ? -1 : 0;
      if (!step) return;
      event.preventDefault();
      const next = (i + step + tabs.length) % tabs.length;
      select(next);
      scrollToPane(next);
      tabs[next].focus();
    });
  });

  select(0);
  window.addEventListener('scroll', tick, { passive: true });
  window.addEventListener('resize', tick);
  frame();
})();

/* The same list, read as a rack of Swift modules. A hairline rail carries one
   accent cursor that slides to the selected row, and every row shows a six-hex
   generation. Settle on a row for 150 ms and it rebuilds: the generation rolls
   for 600 ms while a line sweeps the row, then lands on a new one and is marked
   `swapped`. Rows scrolled past are not rebuilt — that is what the 150 ms is
   for. Selection itself belongs to the tab list above; this only watches
   aria-selected. */
(function () {
  var list = document.querySelector('.plugins');
  if (!list) return;
  var tabs = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));
  var rail = list.querySelector('.p-rail');
  var cursor = list.querySelector('.p-cursor');
  if (!tabs.length || !rail || !cursor) return;

  var still = window.matchMedia('(prefers-reduced-motion: reduce)');
  var HEX = '0123456789abcdef';

  function gen6() {
    var s = '';
    for (var i = 0; i < 6; i++) s += HEX[(Math.random() * 16) | 0];
    return s;
  }

  function selected() {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].getAttribute('aria-selected') === 'true') return i;
    }
    return -1;
  }

  function place(animate) {
    var i = selected();
    if (i < 0) return;
    var first = tabs[0];
    var last = tabs[tabs.length - 1];
    var btn = tabs[i];
    rail.style.top = first.offsetTop + 'px';
    rail.style.height = (last.offsetTop + last.offsetHeight - first.offsetTop) + 'px';
    // '' restores the duration from the stylesheet; '0s' makes this call a jump
    cursor.style.transitionDuration = animate && !still.matches ? '' : '0s';
    cursor.style.height = btn.offsetHeight + 'px';
    cursor.style.transform = 'translateY(' + btn.offsetTop + 'px)';
  }

  function mark(btn, gen) {
    var old = btn.querySelector('.p-swap');
    if (old) old.remove();
    var tag = document.createElement('span');
    tag.className = 'p-swap';
    tag.textContent = 'swapped';
    gen.insertAdjacentElement('afterend', tag);
    setTimeout(function () {
      tag.classList.add('is-out');
      setTimeout(function () { tag.remove(); }, 300);
    }, 900);
  }

  var rolling = null;
  function rebuild(btn) {
    var gen = btn.querySelector('.p-gen');
    if (!gen) return;
    if (rolling) { clearInterval(rolling.timer); rolling.done(); }

    btn.classList.remove('is-rebuilding', 'is-built');
    void btn.offsetWidth;                       // restart the sweep
    btn.classList.add('is-rebuilding');

    var landed = gen6();
    var elapsed = 0;
    var state = {
      done: function () {
        rolling = null;
        gen.textContent = landed;
        btn.classList.remove('is-rebuilding');
        btn.classList.add('is-built');
        setTimeout(function () { btn.classList.remove('is-built'); }, 900);
        mark(btn, gen);
      }
    };
    state.timer = setInterval(function () {
      elapsed += 40;
      if (elapsed >= 600) { clearInterval(state.timer); state.done(); return; }
      gen.textContent = gen6();
    }, 40);
    rolling = state;
  }

  var settle = 0;
  var built = selected();                       // the row we open on is already built
  function onSelect() {
    place(true);
    clearTimeout(settle);
    var i = selected();
    if (i < 0 || i === built || still.matches) return;
    settle = setTimeout(function () {
      if (selected() !== i) return;
      built = i;
      rebuild(tabs[i]);
    }, 150);
  }

  new MutationObserver(onSelect).observe(list, {
    subtree: true, attributes: true, attributeFilter: ['aria-selected'],
  });
  window.addEventListener('resize', function () { place(false); });
  place(false);
})();

/* Scroll reveal: dsh in a browser tab → the same session in the Surf window.
   --p is progress through the whole section, --w the wipe (a held start and a
   held finish), --e a bell curve used for the light at the wipe edge. */
(function () {
  var sec = document.querySelector('.reveal');
  if (!sec) return;
  var scene = sec.querySelector('.scene');

  // The design space is 1204 x 736 (see the reveal section in styles.css).
  function fit() {
    var byWidth = Math.min(sec.clientWidth - 48, 1204);
    var byHeight = (window.innerHeight - 150) * (1204 / 736);
    var k = Math.min(byWidth, byHeight) / 1204;
    scene.style.setProperty('--k', Math.max(0.3, Math.min(1, k)).toFixed(4));
  }

  function frame() {
    queued = false;
    var r = sec.getBoundingClientRect();
    var span = r.height - window.innerHeight;
    var p = span > 0 ? -r.top / span : 1;
    p = p < 0 ? 0 : p > 1 ? 1 : p;
    var w = (p - 0.16) / 0.56;
    w = w < 0 ? 0 : w > 1 ? 1 : w;
    var e = Math.sin(Math.PI * w);
    sec.style.setProperty('--p', p.toFixed(4));
    sec.style.setProperty('--w', w.toFixed(4));
    sec.style.setProperty('--e', (e * e).toFixed(4));
  }

  var queued = false;
  function tick() { if (!queued) { queued = true; requestAnimationFrame(frame); } }

  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    sec.style.setProperty('--p', 1);
    sec.style.setProperty('--w', 1);
    sec.style.setProperty('--e', 0);
    fit();
    window.addEventListener('resize', fit);
    return;
  }

  window.addEventListener('scroll', tick, { passive: true });
  window.addEventListener('resize', function () { fit(); tick(); });
  fit();
  frame();
})();

/* One window, eight viewpoints. #surf-window is cloned into every .app-view;
   the clone sits in a fixed 984 x 636 design space (.app) that is scaled to
   the frame and then pushed in on the region that pane is about. data-zoom is
   the magnification and data-ox / data-oy the design-space point that lands in
   the middle of the frame; the frame crops whatever falls outside. */
(function () {
  var tpl = document.getElementById('surf-window');
  var views = Array.prototype.slice.call(document.querySelectorAll('.app-view'));
  if (!tpl || !views.length) return;

  var W = 984, H = 636;

  function place(view) {
    var app = view.firstElementChild;
    if (!app) return;
    var w = view.clientWidth, h = view.clientHeight;
    if (!w || !h) return;
    var k = Math.min(w / W, h / H);
    var s = k * (parseFloat(view.dataset.zoom) || 1);
    var ox = parseFloat(view.dataset.ox), oy = parseFloat(view.dataset.oy);
    if (isNaN(ox)) ox = W / 2;
    if (isNaN(oy)) oy = H / 2;
    app.style.transform = 'translate(' + (w / 2 - s * ox).toFixed(2) + 'px,'
      + (h / 2 - s * oy).toFixed(2) + 'px) scale(' + s.toFixed(4) + ')';
  }

  views.forEach(function (view) {
    var app = document.createElement('div');
    app.className = 'app';
    if (view.dataset.state) app.dataset.state = view.dataset.state;
    app.appendChild(tpl.content.cloneNode(true));
    view.appendChild(app);
    place(view);
  });

  if (window.ResizeObserver) {
    var ro = new ResizeObserver(function (entries) {
      entries.forEach(function (entry) { place(entry.target); });
    });
    views.forEach(function (view) { ro.observe(view); });
  } else {
    window.addEventListener('resize', function () { views.forEach(place); });
  }
})();
