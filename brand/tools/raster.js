// Usage: node raster.js <kitDir>  — rasterises SVG masters to PNG with Chromium
const path = require('path');
const fs = require('fs');
const { chromium } = require(process.env.PW || 'playwright');
const K = path.resolve(process.argv[2]);
const jobs = [];
const add = (src, out, w, h) => jobs.push({ src, out, w, h: h === 0 ? 0 : (h || w) });

const ICON = 'icon/reference/appicon-macos-shaped.svg';
const ICON32 = 'icon/reference/appicon-macos-shaped-32px.svg';
const ICON16 = 'icon/reference/appicon-macos-shaped-16px.svg';
const pick = (px) => (px <= 16 ? ICON16 : px <= 64 ? ICON32 : ICON);
const set = [[16, 1], [16, 2], [32, 1], [32, 2], [128, 1], [128, 2], [256, 1], [256, 2], [512, 1], [512, 2]];
for (const [pt, sc] of set) {
  const px = pt * sc; const name = `icon_${pt}x${pt}${sc === 2 ? '@2x' : ''}.png`;
  add(pick(px), `xcode/AppIcon.appiconset/${name}`, px);
  add(pick(px), `macos/AppIcon.iconset/${name}`, px);
  const doc = 'icon/document/nexus-document.svg';
  add(doc, `macos/NexusDocument.iconset/${name}`, px);
}
add('svg/mark/opennexus-menubar-template.svg', 'xcode/MenuBarIcon.imageset/MenuBarIconTemplate.png', 18);
add('svg/mark/opennexus-menubar-template.svg', 'xcode/MenuBarIcon.imageset/MenuBarIconTemplate@2x.png', 36);
add('svg/mark/opennexus-mark.svg', 'png/opennexus-mark-1024.png', 1024);
add('svg/mark/opennexus-mark-on-dark.svg', 'png/opennexus-mark-on-dark-1024.png', 1024);
add(ICON, 'png/opennexus-appicon-1024.png', 1024);
add('icon/reference/appicon-dark-fullbleed.svg', 'png/opennexus-appicon-dark-fullbleed-1024.png', 1024);
add('svg/lockup/opennexus-lockup-light.svg', 'png/opennexus-lockup-light-1600.png', 1600, 0);
add('svg/lockup/opennexus-lockup-dark.svg', 'png/opennexus-lockup-dark-1600.png', 1600, 0);
add('web/favicon-16.svg', 'web/favicon-16.png', 16);
add('web/favicon.svg', 'web/favicon-32.png', 32);
add('web/favicon.svg', 'web/favicon-48.png', 48);
add('web/avatar-fullbleed.svg', 'web/apple-touch-icon.png', 180);
add('web/avatar-fullbleed.svg', 'web/icon-192.png', 192);
add('web/avatar-fullbleed.svg', 'web/icon-512.png', 512);
add('web/avatar-fullbleed.svg', 'web/github-avatar-512.png', 512);
add('web/social-preview.svg', 'web/social-preview-1280x640.png', 1280, 640);

(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium' });
  const page = await b.newPage();
  for (const j of jobs) {
    const svg = fs.readFileSync(path.join(K, j.src), 'utf8');
    const vb = svg.match(/viewBox="([^"]+)"/)[1].split(/\s+/).map(Number);
    let w = j.w, h = j.h;
    if (!h) h = Math.round(w * vb[3] / vb[2]);
    await page.setViewportSize({ width: w, height: h });
    const uri = 'data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64');
    await page.setContent(`<html><body style="margin:0;background:transparent"><img src="${uri}" style="display:block;width:${w}px;height:${h}px"></body></html>`);
    await page.waitForFunction(() => document.images[0].complete);
    const out = path.join(K, j.out); fs.mkdirSync(path.dirname(out), { recursive: true });
    await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: w, height: h } });
  }
  await b.close();
  console.log('rendered', jobs.length);
})();
