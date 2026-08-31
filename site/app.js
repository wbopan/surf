// The plugin switcher: one tab list, one visible pane.
(function () {
  const tabs = Array.from(document.querySelectorAll('.plugins [role="tab"]'));
  if (!tabs.length) return;

  const panes = tabs.map((tab) => document.getElementById(tab.getAttribute('aria-controls')));

  function select(index) {
    tabs.forEach((tab, i) => {
      tab.setAttribute('aria-selected', String(i === index));
      tab.tabIndex = i === index ? 0 : -1;
      if (panes[i]) panes[i].hidden = i !== index;
    });
  }

  tabs.forEach((tab, i) => {
    tab.tabIndex = i === 0 ? 0 : -1;
    tab.addEventListener('click', () => select(i));
    tab.addEventListener('keydown', (event) => {
      const step = event.key === 'ArrowDown' ? 1 : event.key === 'ArrowUp' ? -1 : 0;
      if (!step) return;
      event.preventDefault();
      const next = (i + step + tabs.length) % tabs.length;
      select(next);
      tabs[next].focus();
    });
  });

  select(0);
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
