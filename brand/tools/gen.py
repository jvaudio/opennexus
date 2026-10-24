"""Generate the OpenNexus 'Aperture' brand asset kit (SVG masters + outlined wordmark)."""
import math, os, json, sys
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

OUT = sys.argv[1]
GEIST = sys.argv[2]  # Geist variable woff2

PAL = {
    'light': dict(ring='#5850EC', up='#0F9F9A', down='#E0A100', root='#17171C'),
    'dark': dict(ring='#8F89FF', up='#3FD3C9', down='#F2B135', root='#F5F5F7'),
    'icon': dict(ring='#FFFFFF', up='#8CF0E6', down='#FFD27A', root='#FFFFFF'),
    'black': dict(ring='#000000', up='#000000', down='#000000', root='#000000'),
    'white': dict(ring='#FFFFFF', up='#FFFFFF', down='#FFFFFF', root='#FFFFFF'),
}
IRIS_A, IRIS_B = '#6E67F6', '#4C43DB'


def f(x):
    return ('%.2f' % x).rstrip('0').rstrip('.')


def parts(p, b=1.0):
    """Aperture geometry on a 64-unit grid. b = optical size boost."""
    s = 1 + (b - 1) * 0.45
    a = math.radians(45 + (b - 1) * 12)
    ex, ey1, ey2 = 26 + 14 * math.cos(a), 32 - 14 * math.sin(a), 32 + 14 * math.sin(a)
    ring = f'<path d="M{f(ex)} {f(ey1)} A14 14 0 1 0 {f(ex)} {f(ey2)}" fill="none" stroke="{p["ring"]}" stroke-width="{f(5*b)}" stroke-linecap="round"/>'
    branches = (
        f'<path d="M26 32 C36 32 40 22 50 19" fill="none" stroke="{p["up"]}" stroke-width="{f(3.4*b)}" stroke-linecap="round"/>'
        f'<path d="M26 32 C36 32 40 42 50 45" fill="none" stroke="{p["down"]}" stroke-width="{f(3.4*b)}" stroke-linecap="round"/>'
        f'<circle cx="51" cy="18.6" r="{f(5*s)}" fill="{p["up"]}"/>'
        f'<circle cx="51" cy="45.4" r="{f(5*s)}" fill="{p["down"]}"/>'
    )
    root = f'<circle cx="26" cy="32" r="{f(6.2*s)}" fill="{p["root"]}"/>'
    return dict(ring=ring, branches=branches, root=root)


def mark_body(p, b=1.0):
    q = parts(p, b)
    return q['ring'] + q['branches'] + q['root']


# Tight bounds of the mark on the 64 grid (b=1): x 9.5..56, y 13.6..50.4 -> use a padded square viewBox centred on it.
VB = '8 8 50 50'  # square, mark optically centred


def svg(body, vb, w=None, h=None, title='OpenNexus'):
    size = f' width="{w}" height="{h}"' if w else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}"{size} role="img" aria-label="{title}"><title>{title}</title>{body}</svg>\n'


def write(rel, text):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(text)


# ---------- wordmark outlines ----------
def wordmark_paths(fill_open, fill_nexus, size=100, track=-0.03):
    """Return (svg_body, width, ascent, descent) for 'Open' (500) + 'Nexus' (700), outlined from Geist."""
    out, x = [], 0.0
    asc = desc = 0
    for text, wght, fill in (('Open', 500, fill_open), ('Nexus', 700, fill_nexus)):
        tt = TTFont(GEIST)
        inst = instantiateVariableFont(tt, {'wght': wght})
        upm = inst['head'].unitsPerEm
        asc, desc = inst['hhea'].ascent, inst['hhea'].descent
        import io
        buf = io.BytesIO(); inst.flavor = None; inst.save(buf); data = buf.getvalue()
        face = hb.Face(data); font = hb.Font(face)
        hbbuf = hb.Buffer(); hbbuf.add_str(text); hbbuf.guess_segment_properties()
        hb.shape(font, hbbuf, {'kern': True, 'liga': True})
        gs = inst.getGlyphSet(); order = inst.getGlyphOrder()
        k = size / upm
        for info, pos in zip(hbbuf.glyph_infos, hbbuf.glyph_positions):
            name = order[info.codepoint]
            pen = SVGPathPen(gs)
            tpen = TransformPen(pen, (k, 0, 0, -k, x + pos.x_offset * k, 0))
            gs[name].draw(tpen)
            d = pen.getCommands()
            if d:
                out.append(f'<path d="{d}" fill="{fill}"/>')
            x += pos.x_advance * k + track * size
        x -= track * size  # no tracking after the last glyph of a run
        x += track * size  # keep tracking between runs
    x -= track * size
    return ''.join(out), x, asc * size / upm, desc * size / upm


def lockup(pal, open_c, nexus_c, bg=None):
    # mark 120 units tall-ish at left, wordmark cap height aligned to mark centre
    # Proportions match 01 · Brand: mark height = 1.5 × wordmark font size.
    wm, w, asc, desc = wordmark_paths(open_c, nexus_c, size=79)
    cap = 0.71 * 79  # Geist cap height ≈ 0.71 em
    mark_size = 118
    gap = 26
    mx = 0
    # mark: viewBox 8..58 -> scale to mark_size
    k = mark_size / 50
    mark = f'<g transform="translate({f(mx)} 0) scale({f(k)}) translate(-8 -8)">{mark_body(PAL[pal])}</g>'
    tx = mark_size + gap
    ty = mark_size / 2 + cap / 2
    text = f'<g transform="translate({f(tx)} {f(ty)})">{wm}</g>'
    W, H = tx + w + 4, mark_size
    bgr = f'<rect x="-24" y="-24" width="{f(W+48)}" height="{f(H+48)}" fill="{bg}"/>' if bg else ''
    vb = f'-24 -24 {f(W+48)} {f(H+48)}'
    return svg(bgr + mark + text, vb, title='OpenNexus'), W, H


def stacked(pal, open_c, nexus_c):
    wm, w, asc, desc = wordmark_paths(open_c, nexus_c, size=60)
    mark_size = 140
    k = mark_size / 50
    W = max(w, mark_size)
    mark = f'<g transform="translate({f((W-mark_size)/2)} 0) scale({f(k)}) translate(-8 -8)">{mark_body(PAL[pal])}</g>'
    text = f'<g transform="translate({f((W-w)/2)} {f(mark_size + 30 + 42)})">{wm}</g>'
    H = mark_size + 30 + 42 + 14
    return svg(mark + text, f'-16 -16 {f(W+32)} {f(H+32)}')


# ---------- app icon ----------
def icon_mark_group(b=1.1, which=('ring', 'branches', 'root'), pal='icon'):
    # Tile 1024; mark occupies 78/112 of tile width in the design -> 713 px for the 64-unit viewBox.
    q = parts(PAL[pal] if isinstance(pal, str) else pal, b)
    k = 1024 * (78 / 112) / 64
    off = (1024 - 64 * k) / 2
    body = ''.join(q[w] for w in which)
    return f'<g transform="translate({f(off)} {f(off)}) scale({f(k)})">{body}</g>'


GRAD = f'<defs><linearGradient id="iris" x1="0.29" y1="0.05" x2="0.71" y2="0.95"><stop offset="0" stop-color="{IRIS_A}"/><stop offset="1" stop-color="{IRIS_B}"/></linearGradient></defs>'


def icon_full_bleed(pal='icon', bg='iris', b=1.1):
    fill = 'url(#iris)' if bg == 'iris' else bg
    return svg(GRAD + f'<rect width="1024" height="1024" fill="{fill}"/>' + icon_mark_group(b, pal=pal), '0 0 1024 1024', 1024, 1024)


def icon_macos_shaped(pal='icon', bg='iris', b=1.1):
    """Pre-shaped macOS icon (Big Sur grid): 824 squircle at 100,100 with shadow, for .appiconset fallback."""
    fill = 'url(#iris)' if bg == 'iris' else bg
    k = 824 / 1024
    defs = GRAD.replace('</defs>', '<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity=".28"/></filter><linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs>')
    body = (defs + f'<g filter="url(#sh)"><rect x="100" y="100" width="824" height="824" rx="185" fill="{fill}"/></g>'
            f'<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="url(#hl)" stroke-width="2"/>'
            f'<g transform="translate(100 100) scale({f(k)})">{icon_mark_group(b, pal=pal)}</g>')
    return svg(body, '0 0 1024 1024', 1024, 1024)


def doc_icon():
    # Page 1024 canvas: 640x820 page centred with folded corner; mark in the lower centre.
    x0, y0, w, h, fold = 192, 102, 640, 820, 150
    page = (f'<defs><filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity=".22"/></filter></defs>'
            f'<g filter="url(#sh)"><path d="M{x0+24} {y0} H{x0+w-fold} L{x0+w} {y0+fold} V{y0+h-24} Q{x0+w} {y0+h} {x0+w-24} {y0+h} H{x0+24} Q{x0} {y0+h} {x0} {y0+h-24} V{y0+24} Q{x0} {y0} {x0+24} {y0} Z" fill="#FFFFFF"/></g>'
            f'<path d="M{x0+w-fold} {y0} V{y0+fold-20} Q{x0+w-fold} {y0+fold} {x0+w-fold+20} {y0+fold} H{x0+w} Z" fill="#E6E6EC"/>')
    k = 420 / 64
    mark = f'<g transform="translate({f(512-32*k)} {f(560-32*k)}) scale({f(k)})">{mark_body(PAL["light"], 1.0)}</g>'
    return svg(page + mark, '0 0 1024 1024', 1024, 1024, title='OpenNexus document')


def favicon(b=1.5):
    body = GRAD + f'<rect width="64" height="64" rx="14" fill="url(#iris)"/>' + f'<g transform="translate(5 5) scale(.84375)">{mark_body(PAL["icon"], b)}</g>'
    return svg(body, '0 0 64 64', 64, 64)


def menubar_template():
    # 18pt template image: black only, alpha used by macOS. Mark fills ~16pt of the 18pt box.
    return svg(mark_body(PAL['black'], 1.7), '7 7 52 52', 18, 18, title='OpenNexus')


def social(w=1280, h=640):
    lk, LW, LH = lockup('dark', '#8A8A96', '#F5F5F7')
    inner = lk.split('>', 1)[1].rsplit('</svg>', 1)[0]
    inner = inner.split('</title>', 1)[1]
    vbw = LW + 48
    k = 900 / vbw
    body = (f'<rect width="{w}" height="{h}" fill="#121317"/>'
            f'<g transform="translate({f((w-900)/2 + 24*k)} {f(h/2 - (LH*k)/2)}) scale({f(k)})">{inner}</g>')
    return svg(body, f'0 0 {w} {h}', w, h)


# ---------- write everything ----------
write('svg/mark/opennexus-mark.svg', svg(mark_body(PAL['light']), VB))
write('svg/mark/opennexus-mark-on-dark.svg', svg(mark_body(PAL['dark']), VB))
write('svg/mark/opennexus-mark-32px.svg', svg(mark_body(PAL['light'], 1.5), VB))
write('svg/mark/opennexus-mark-16px.svg', svg(mark_body(PAL['light'], 1.9), VB))
write('svg/mark/opennexus-mark-on-dark-32px.svg', svg(mark_body(PAL['dark'], 1.5), VB))
write('svg/mark/opennexus-mark-on-dark-16px.svg', svg(mark_body(PAL['dark'], 1.9), VB))
write('svg/mark/opennexus-mark-mono-black.svg', svg(mark_body(PAL['black']), VB))
write('svg/mark/opennexus-mark-mono-white.svg', svg(mark_body(PAL['white']), VB))
write('svg/mark/opennexus-menubar-template.svg', menubar_template())
for pal, oc, nc, name in (('light', '#6B6B76', '#17171C', 'light'), ('dark', '#8A8A96', '#F5F5F7', 'dark')):
    write(f'svg/lockup/opennexus-lockup-{name}.svg', lockup(pal, oc, nc)[0])
    write(f'svg/lockup/opennexus-lockup-stacked-{name}.svg', stacked(pal, oc, nc))
write('svg/lockup/opennexus-lockup-mono-black.svg', lockup('black', '#000000', '#000000')[0])
write('svg/lockup/opennexus-lockup-mono-white.svg', lockup('white', '#FFFFFF', '#FFFFFF')[0])
wm, w, _, _ = wordmark_paths('#6B6B76', '#17171C', 100)
write('svg/lockup/opennexus-wordmark-light.svg', svg(f'<g transform="translate(0 80)">{wm}</g>', f'-4 0 {f(w+8)} 100'))
wm, w, _, _ = wordmark_paths('#8A8A96', '#F5F5F7', 100)
write('svg/lockup/opennexus-wordmark-dark.svg', svg(f'<g transform="translate(0 80)">{wm}</g>', f'-4 0 {f(w+8)} 100'))

# Icon Composer layers (1024 full-bleed; Icon Composer applies the shape and glass)
write('icon/icon-composer-layers/0-background.svg', svg(GRAD + '<rect width="1024" height="1024" fill="url(#iris)"/>', '0 0 1024 1024', 1024, 1024))
write('icon/icon-composer-layers/1-ring.svg', svg(icon_mark_group(which=('ring',)), '0 0 1024 1024', 1024, 1024))
write('icon/icon-composer-layers/2-branches.svg', svg(icon_mark_group(which=('branches',)), '0 0 1024 1024', 1024, 1024))
write('icon/icon-composer-layers/3-root.svg', svg(icon_mark_group(which=('root',)), '0 0 1024 1024', 1024, 1024))
write('icon/reference/appicon-default-fullbleed.svg', icon_full_bleed())
write('icon/reference/appicon-dark-fullbleed.svg', icon_full_bleed('dark', '#17181D'))
write('icon/reference/appicon-macos-shaped.svg', icon_macos_shaped())
write('icon/reference/appicon-macos-shaped-32px.svg', icon_macos_shaped(b=1.5))
write('icon/reference/appicon-macos-shaped-16px.svg', icon_macos_shaped(b=1.9))
write('web/favicon-16.svg', favicon(1.9))
write('web/avatar-fullbleed.svg', icon_full_bleed())
write('icon/document/nexus-document.svg', doc_icon())
write('web/favicon.svg', favicon())
write('web/social-preview.svg', social())
print('ok')
