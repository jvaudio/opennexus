// Minimal stand-in for the design-canvas runtime: renders a .dc.html artboard with React.
(function () {
  const LOWER = {};
  ['onClick','onDoubleClick','onMouseDown','onMouseUp','onMouseMove','onMouseEnter','onMouseLeave','onMouseOver','onMouseOut',
   'onKeyDown','onKeyUp','onKeyPress','onFocus','onBlur','onChange','onInput','onSubmit','onWheel','onScroll','onContextMenu',
   'onPointerDown','onPointerUp','onPointerMove','onPointerEnter','onPointerLeave','onDragStart','onDragOver','onDrop','onDragEnd',
   'tabIndex','autoFocus','spellCheck','readOnly','maxLength','colSpan','rowSpan','autoComplete','contentEditable','htmlFor',
   'crossOrigin','dateTime','srcSet','useMap','frameBorder','allowFullScreen','inputMode','enterKeyHint','draggable']
    .forEach(n => LOWER[n.toLowerCase()] = n);
  LOWER['class'] = 'className'; LOWER['for'] = 'htmlFor'; LOWER['ondblclick'] = 'onDoubleClick';

  const LIT = { 'true': true, 'false': false, 'null': null, 'undefined': undefined };
  function lookup(path, scopes) {
    path = path.trim();
    if (path in LIT) return LIT[path];
    if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
    const parts = path.split('.');
    for (const s of scopes) {
      if (s && typeof s === 'object' && parts[0] in s) {
        let v = s[parts[0]];
        for (let i = 1; i < parts.length; i++) v = v == null ? undefined : v[parts[i]];
        return v;
      }
    }
    return undefined;
  }
  const HOLE = /\{\{([^}]*)\}\}/g;
  function interp(str, scopes) {
    const whole = str.match(/^\s*\{\{([^}]*)\}\}\s*$/);
    if (whole) return lookup(whole[1], scopes);
    return str.replace(HOLE, (_, p) => { const v = lookup(p, scopes); return v == null ? '' : String(v); });
  }
  const probe = document.createElement('div');
  function styleObj(css) {
    probe.removeAttribute('style');
    probe.style.cssText = css;
    const o = {};
    for (let i = 0; i < probe.style.length; i++) {
      const k = probe.style[i];
      const key = k.startsWith('--') ? k : k.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      o[key] = probe.style.getPropertyValue(k) + (probe.style.getPropertyPriority(k) ? ' !important' : '');
    }
    return o;
  }

  function build(nodes, scopes, h, keyPrefix) {
    const out = [];
    let idx = 0;
    for (const node of nodes) {
      const key = keyPrefix + '.' + (idx++);
      if (node.nodeType === 3) {
        const t = node.nodeValue;
        if (!t.includes('{{')) { out.push(t); continue; }
        let last = 0; let m; HOLE.lastIndex = 0;
        while ((m = HOLE.exec(t))) {
          if (m.index > last) out.push(t.slice(last, m.index));
          const v = lookup(m[1], scopes);
          if (v != null && v !== false) out.push(typeof v === 'object' && v.$$typeof ? v : String(v));
          last = m.index + m[0].length;
        }
        if (last < t.length) out.push(t.slice(last));
        continue;
      }
      if (node.nodeType !== 1) continue;
      const tag = node.tagName.toLowerCase();
      if (tag === 'sc-for') {
        const list = interp(node.getAttribute('list') || '', scopes) || [];
        const as = node.getAttribute('as') || 'item';
        Array.from(list).forEach((item, i) => {
          out.push(h(React.Fragment, { key: key + ':' + i }, ...build(node.childNodes, [{ [as]: item, [as + 'Index']: i }, ...scopes], h, key + ':' + i)));
        });
        continue;
      }
      if (tag === 'sc-if') {
        const v = interp(node.getAttribute('value') || '', scopes);
        if (v) out.push(h(React.Fragment, { key }, ...build(node.childNodes, scopes, h, key)));
        continue;
      }
      const props = { key };
      for (const a of Array.from(node.attributes)) {
        let name = LOWER[a.name] || a.name;
        let val = a.value.includes('{{') ? interp(a.value, scopes) : a.value;
        if (name === 'style') { if (typeof val === 'string') val = styleObj(val); }
        else if (name === 'ref') { if (typeof val !== 'function' && typeof val !== 'object') continue; }
        else if (name === 'value' && (tag === 'textarea' || tag === 'input')) { name = 'defaultValue'; }
        else if (/^on[A-Z]/.test(name) && typeof val !== 'function') continue;
        if (val === undefined) continue;
        props[name] = val;
      }
      const kids = tag === 'textarea' ? [] : build(node.childNodes, scopes, h, key);
      const children = kids.length ? kids : undefined;
      out.push(children ? h(tag, props, ...children) : h(tag, props));
    }
    return out;
  }

  window.renderDC = function (source) {
    const doc = new DOMParser().parseFromString(source, 'text/html');
    const xdc = doc.querySelector('x-dc');
    const helmet = xdc.querySelector('helmet');
    if (helmet) for (const el of Array.from(helmet.children)) document.head.appendChild(document.importNode(el, true));
    if (doc.title) document.title = doc.title;
    const nodes = Array.from(xdc.childNodes).filter(n => !(n.nodeType === 1 && n.tagName.toLowerCase() === 'helmet'));
    const scriptEl = doc.querySelector('script[data-dc-script]');
    let props = {};
    try { props = JSON.parse(scriptEl.getAttribute('data-props') || '{}'); } catch (e) {}
    const preview = props.$preview || {};
    const h = React.createElement;
    class DCLogic extends React.Component {
      constructor(p) { super(p); if (!this.state) this.state = {}; }
      renderVals() { return {}; }
      render() {
        const vals = this.renderVals() || {};
        return h(React.Fragment, null, ...build(nodes, [vals, this, preview], h, 'r'));
      }
    }
    const Component = new Function('DCLogic', 'React', scriptEl.textContent + '\n;return Component;')(DCLogic, React);
    const mount = document.getElementById('mount');
    ReactDOM.createRoot(mount).render(h(Component, preview));
    return { width: preview.width || 1440, height: preview.height || 900 };
  };
})();
