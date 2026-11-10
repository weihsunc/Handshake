"""Turn Phosphor icons (256x256 filled-outline SVGs, @phosphor-icons/core
assets/regular or assets/fill) into custom SF Symbol templates, so they size,
weight and baseline-align like system symbols (toolbars, Labels, menus).

usage: python3 Tools/ph2symbol.py <svg dir> <Assets.xcassets/Phosphor> ph-name=file[,ph-name=file...]
  e.g. ... ph-phone=phone,ph-check-circle-fill=check-circle-fill

Notes (each one cost a crash or a blank icon):
- Asset names use dashes, never dots: UIImage(named:) reads "ph.list" as file
  "ph" with extension "list", so toolbars and Form rows draw nothing.
- The template ships Ultralight-S, Regular-S and Black-S (identical outlines)
  so iOS can interpolate every weight and scale; Regular-M alone renders in
  plain SwiftUI views but is blank in toolbars and List rows.
- The three outlines must have identical point counts or CoreUI throws
  CUIVectorGlyphIncompatiblePointsException at draw time: coordinates are
  rounded before the column offset is added, and the columns sit in the same
  float32 range (1024-2048).
"""
import re, sys, os, json
S = 0.40 * 0.783                 # small-scale sources; medium is derived (~102 units)
BASE, CAP = 696.0, 625.541       # small-scale guides (Apple template)
MID = BASE - (BASE - CAP) / 2    # centre on the cap-height midline
TY = MID - 128 * S
COLS = {'Ultralight-S': 1100.0, 'Regular-S': 1400.0, 'Black-S': 1700.0}  # same float32 binade, so all three parse identically
TX = 0.0
num = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
def f(v): return ('%.4f' % v).rstrip('0').rstrip('.')
def rnd(v): return round(v, 3)
def transform(d):
    toks = re.findall(r'[A-Za-z]|' + num, d)
    out, i, cmd = [], 0, None
    def take(): 
        nonlocal i; i += 1; return float(toks[i-1])
    def flag():
        nonlocal i
        t = toks[i]
        if t in ('0', '1'): i += 1; return t
        # compacted flags like "01" or "11.5"
        ch = t[0]; toks[i] = t[1:]; return ch
    while i < len(toks):
        t = toks[i]
        if re.fullmatch('[A-Za-z]', t): cmd = t; i += 1; out.append(cmd)
        if cmd in 'Zz': continue
        ab = cmd.isupper(); sx = (lambda v: rnd(S*v)+TX) if ab else (lambda v: rnd(S*v)); sy = (lambda v: rnd(S*v+TY)) if ab else (lambda v: rnd(S*v))
        c = cmd.upper()
        if c in 'MLT':
            out += [f(sx(take())), f(sy(take()))]
        elif c == 'H': out.append(f(sx(take())))
        elif c == 'V': out.append(f(sy(take())))
        elif c == 'C': out += [f(sx(take())), f(sy(take())), f(sx(take())), f(sy(take())), f(sx(take())), f(sy(take()))]
        elif c in 'SQ': out += [f(sx(take())), f(sy(take())), f(sx(take())), f(sy(take()))]
        elif c == 'A':
            rx, ry, rot = take(), take(), take(); fa, fs = flag(), flag()
            out += [f(rx*S), f(ry*S), f(rot), fa, fs, f(sx(take())), f(sy(take()))]
        else: raise ValueError(cmd)
        if cmd == 'M': cmd = 'L'
        elif cmd == 'm': cmd = 'l'
    return ' '.join(out)
TEMPLATE = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!-- Phosphor Icons ({src}), MIT License, Copyright (c) 2023 Phosphor Icons -->
 <g id="Notes">
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1953)">Template v.3.0</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
{margins}
 </g>
 <g id="Symbols">
{groups}
 </g>
</svg>
'''
src_dir, out_dir, pairs = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out_dir, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, open(os.path.join(out_dir, 'Contents.json'), 'w'), indent=2)
for pair in pairs.split(','):
    name, file = pair.split('=')
    svg = open(os.path.join(src_dir, file + '.svg')).read()
    d = re.search(r'<path d="([^"]+)"', svg).group(1)
    folder = os.path.join(out_dir, name + '.symbolset'); os.makedirs(folder, exist_ok=True)
    margins, groups = [], []
    for g, col in COLS.items():
        TX = col
        margins.append('  <line id="left-margin-%s" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="%s" x2="%s" y1="600.785" y2="720.121"/>' % (g, f(col), f(col)))
        margins.append('  <line id="right-margin-%s" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="%s" x2="%s" y1="600.785" y2="720.121"/>' % (g, f(col + 256 * S), f(col + 256 * S)))
        groups.append('  <g id="%s">\n   <path d="%s"/>\n  </g>' % (g, transform(d)))
    open(os.path.join(folder, name + '.svg'), 'w').write(TEMPLATE.format(src=file, margins='\n'.join(margins), groups='\n'.join(groups)))
    json.dump({"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": name + '.svg', "idiom": "universal"}]},
              open(os.path.join(folder, 'Contents.json'), 'w'), indent=2)
print('ok', len(pairs.split(',')))
