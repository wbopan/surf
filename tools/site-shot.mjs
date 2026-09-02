// Screenshot the site's plugin band, one pane at a time, with headless Chromium.
//
//   node tools/site-shot.mjs                      # all 8 panes, light, 1440x900 → /tmp/site-pane-light-N.png
//   node tools/site-shot.mjs --pane 3 --scheme dark
//   node tools/site-shot.mjs --url http://localhost:8765/index.zh.html --out /tmp/zh
//   node tools/site-shot.mjs --width 800 --height 900      # narrow: the band is a click tab list there
//
// Needs the site served over http (python3 -m http.server -d site 8765) and the
// global playwright (npm i -g playwright && playwright install chromium).
import { execSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
const url = arg('url', 'http://localhost:8765/');
const scheme = arg('scheme', 'light');
const width = +arg('width', 1440), height = +arg('height', 900);
const out = arg('out', '/tmp/site-pane');
const only = arg('pane', null);
const settle = +arg('settle', 1600);   // ms to wait after a pane is selected (lets its entrance animation finish)

const root = execSync('npm root -g').toString().trim();
const { chromium } = await import(pathToFileURL(root + '/playwright/index.mjs'));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2, colorScheme: scheme });
await page.goto(url, { waitUntil: 'networkidle' });
const n = await page.evaluate(() => document.querySelectorAll('.plugins [role=tab]').length);
const wide = width > 860;
for (let i = 0; i < n; i++) {
  if (only !== null && +only !== i) continue;
  await page.evaluate(({ i, n, wide }) => {
    if (wide) {
      const t = document.querySelector('.band-track');
      const span = t.offsetHeight - innerHeight;
      scrollTo({ top: t.offsetTop + span * ((i + .5) / n), behavior: 'instant' });
    } else {
      const tab = document.querySelectorAll('.plugins [role=tab]')[i];
      tab.click();
      tab.scrollIntoView({ block: 'start', behavior: 'instant' });
    }
  }, { i, n, wide });
  await page.waitForTimeout(settle);
  const file = `${out}-${scheme}-${i}.png`;
  await page.screenshot({ path: file });
  console.log(file);
}
await browser.close();
