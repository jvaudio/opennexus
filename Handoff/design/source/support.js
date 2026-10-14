/*
 * OpenNexus design viewer bootstrap.
 * Every *.dc.html artboard loads this file. It renders the <x-dc> template with
 * React so the artboard can be opened directly in Chrome/Safari/Firefox (file:// works).
 * Template rules: {{a.b}} dotted lookups, <sc-for list as>, <sc-if value>,
 * logic in <script type="text/x-dc" data-dc-script> (class Component extends DCLogic).
 */
(function () {
  var base = (document.currentScript && document.currentScript.src || '').replace(/[^/]*$/, '');
  var lib = base + '../viewer/lib/';
  var fonts = base + '../viewer/fonts/';
  var css = document.createElement('style');
  css.textContent =
    'x-dc{display:none!important}html,body{margin:0;background:#fff}' +
    "@font-face{font-family:'Bricolage Grotesque';font-weight:200 800;src:url(" + fonts + "BricolageGrotesque.woff2) format('woff2')}" +
    "@font-face{font-family:'Geist';font-weight:100 900;src:url(" + fonts + "Geist.woff2) format('woff2')}" +
    "@font-face{font-family:'Geist Mono';font-weight:100 900;src:url(" + fonts + "GeistMono.woff2) format('woff2')}" +
    "@font-face{font-family:'Newsreader';font-weight:200 800;src:url(" + fonts + "Newsreader.woff2) format('woff2')}" +
    "@font-face{font-family:'Kalam';font-weight:400;src:url(" + fonts + "Kalam-Regular.woff2) format('woff2')}" +
    "@font-face{font-family:'Kalam';font-weight:700;src:url(" + fonts + "Kalam-Bold.woff2) format('woff2')}";
  document.head.appendChild(css);
  function load(src) {
    return new Promise(function (ok, bad) {
      var s = document.createElement('script'); s.src = src; s.onload = ok; s.onerror = bad; document.head.appendChild(s);
    });
  }
  function start() {
    var source = '<!doctype html>' + document.documentElement.outerHTML;
    var tpl = document.querySelector('x-dc'); if (tpl) tpl.remove();
    load(lib + 'react.js').then(function () { return load(lib + 'react-dom.js'); })
      .then(function () { return load(lib + 'dc-shim.js'); })
      .then(function () {
        var m = document.createElement('div'); m.id = 'mount'; document.body.appendChild(m);
        window.renderDC(source);
      })
      .catch(function (e) { console.error('OpenNexus viewer failed to load', e); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
