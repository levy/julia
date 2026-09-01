#!/usr/bin/env python3
"""Draw the real-world plots from the CCDF dumps in logs/.

Plain python, no plotting library: the output is SVG, written directly, so
the plots are rebuilt from the logs with nothing but python3. Colors are
the reference palette of the data-viz method (validated): categorical
slots 1-3 on the light surface, text in ink tokens, 2px lines, 8px end
markers with a 2px surface ring, recessive grid.

  python3 plot_realworld.py     reads logs/ccdf_*.tsv, writes plots/*.svg
"""
import math, os

D = os.path.dirname(os.path.abspath(__file__))
SURFACE, GRID = "#fcfcfb", "#e8e7e4"
INK, INK2 = "#0b0b0b", "#52514e"
SERIES = [("stock collector", "#2a78d6"),
          ("regions, census every 100 k", "#eb6834"),
          ("regions, no census", "#1baf7a")]
FONT = 'font-family="DejaVu Sans, sans-serif"'

def read_ccdf(name):
    pts = []
    with open(os.path.join(D, "logs", name)) as f:
        for line in f:
            if line.startswith("#"):
                continue
            a, b = line.split()
            f_, ns = float(a), int(b)
            if ns > 0:
                pts.append((ns, f_))
    return pts

def fmt_ns(ns):
    if ns >= 1e6: return f"{ns/1e6:.0f} ms" if ns >= 2e6 else f"{ns/1e6:.1f} ms"
    if ns >= 1e3: return f"{ns/1e3:.0f} µs" if ns >= 2e3 else f"{ns/1e3:.1f} µs"
    return f"{ns:.0f} ns"

class Panel:
    """One log-log CCDF panel: x = latency ns, y = exceed fraction."""
    def __init__(self, x0, y0, w, h, xlo, xhi, ylo):
        self.x0, self.y0, self.w, self.h = x0, y0, w, h
        self.xlo, self.xhi, self.ylo = xlo, xhi, ylo
    def X(self, ns):
        return self.x0 + self.w * (math.log10(ns) - math.log10(self.xlo)) / \
               (math.log10(self.xhi) - math.log10(self.xlo))
    def Y(self, f):
        f = max(f, self.ylo)
        return self.y0 + self.h * (math.log10(f) / math.log10(self.ylo))

def ccdf_panel(svg, p, title, files, label_dy):
    x1, y1 = p.x0 + p.w, p.y0 + p.h
    svg.append(f'<text x="{p.x0}" y="{p.y0-14}" {FONT} font-size="15" fill="{INK}" font-weight="bold">{title}</text>')
    # The recessive grid: one line per decade, both axes.
    d = int(math.log10(p.xhi / p.xlo))
    for k in range(d + 1):
        x = p.X(p.xlo * 10 ** k)
        svg.append(f'<line x1="{x:.1f}" y1="{p.y0}" x2="{x:.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
        svg.append(f'<text x="{x:.1f}" y="{y1+18}" {FONT} font-size="12" fill="{INK2}" text-anchor="middle">{fmt_ns(p.xlo*10**k)}</text>')
    dy = int(-math.log10(p.ylo))
    for k in range(dy + 1):
        y = p.Y(10 ** -k)
        svg.append(f'<line x1="{p.x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
        lab = "all" if k == 0 else ("10<tspan dy=\"-4\" font-size=\"9\">-%d</tspan>" % k)
        svg.append(f'<text x="{p.x0-8}" y="{y+4:.1f}" {FONT} font-size="12" fill="{INK2}" text-anchor="end">{lab}</text>')
    # The curves, and the maximum of each as an 8px marker with a surface ring.
    for (name, color), fn, ldy in zip(SERIES, files, label_dy):
        pts = read_ccdf(fn)
        path = " ".join(f"{'M' if i==0 else 'L'}{p.X(ns):.1f},{p.Y(f):.1f}"
                        for i, (ns, f) in enumerate(pts) if ns >= p.xlo)
        svg.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        mx, mf = pts[-1]
        cx, cy = p.X(mx), p.Y(mf)
        svg.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
        svg.append(f'<text x="{cx:.1f}" y="{cy+ldy:.1f}" {FONT} font-size="12" fill="{INK}" text-anchor="end">max {fmt_ns(mx)}</text>')

def legend(svg, x, y):
    for name, color in SERIES:
        svg.append(f'<line x1="{x}" y1="{y-4}" x2="{x+22}" y2="{y-4}" stroke="{color}" stroke-width="3" stroke-linecap="round"/>')
        svg.append(f'<text x="{x+28}" y="{y}" {FONT} font-size="13" fill="{INK}">{name}</text>')
        x += 34 + 7.2 * len(name)

def write(svgname, w, h, body):
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" font-size="13">',
           f'<rect width="{w}" height="{h}" fill="{SURFACE}"/>'] + body + ["</svg>"]
    out = os.path.join(D, "plots", svgname)
    open(out, "w").write("\n".join(svg))
    print("wrote", out)

def main():
    # Figure 1: the two CCDF panels.
    body = []
    body.append(f'<text x="40" y="30" {FONT} font-size="17" fill="{INK}" font-weight="bold">How many events are at least this slow</text>')
    body.append(f'<text x="40" y="50" {FONT} font-size="13" fill="{INK2}">5 million events each, isolated core, SCHED_FIFO, memory locked, 512 MB heap reserve; the marker is the longest event</text>')
    legend(body, 40, 74)
    pa = Panel(80, 110, 380, 300, 1e1, 1e7, 1e-7)
    pb = Panel(560, 110, 380, 300, 1e1, 1e7, 1e-7)
    ccdf_panel(body, pa, "~1.7 KB of garbage per event",
               ["ccdf_auto_W200.tsv", "ccdf_census_W200.tsv", "ccdf_nocensus_W200.tsv"], [-10, -10, 20])
    ccdf_panel(body, pb, "~100 B of garbage per event",
               ["ccdf_auto_W3.tsv", "ccdf_census_W3.tsv", "ccdf_nocensus_W3.tsv"], [-10, -10, 20])
    body.append(f'<text x="510" y="445" {FONT} font-size="13" fill="{INK2}" text-anchor="middle">event latency</text>')
    body.append(f'<text x="20" y="260" {FONT} font-size="13" fill="{INK2}" transform="rotate(-90 20 260)" text-anchor="middle">fraction of events ≥ x</text>')
    write("latency_ccdf.svg", 980, 460, body)

    # Figure 2: the longest pause, a dot plot on a log axis (position, not
    # length, so the log scale is honest).
    body = []
    body.append(f'<text x="40" y="30" {FONT} font-size="17" fill="{INK}" font-weight="bold">The longest pause any event took</text>')
    legend(body, 40, 54)
    x0, x1w, xlo, xhi = 220, 660, 1e4, 1e7
    X = lambda ns: x0 + x1w * (math.log10(ns) - 4) / 3
    rows = [("~1.7 KB per event", 110, ["ccdf_auto_W200.tsv", "ccdf_census_W200.tsv", "ccdf_nocensus_W200.tsv"]),
            ("~100 B per event", 170, ["ccdf_auto_W3.tsv", "ccdf_census_W3.tsv", "ccdf_nocensus_W3.tsv"])]
    for k in range(4):
        x = X(xlo * 10 ** k)
        body.append(f'<line x1="{x:.1f}" y1="80" x2="{x:.1f}" y2="195" stroke="{GRID}" stroke-width="1"/>')
        body.append(f'<text x="{x:.1f}" y="215" {FONT} font-size="12" fill="{INK2}" text-anchor="middle">{fmt_ns(xlo*10**k)}</text>')
    for label, y, files in rows:
        body.append(f'<text x="{x0-16}" y="{y+5}" {FONT} font-size="13" fill="{INK}" text-anchor="end">{label}</text>')
        for (name, color), fn in zip(SERIES, files):
            mx = read_ccdf(fn)[-1][0]
            body.append(f'<circle cx="{X(mx):.1f}" cy="{y}" r="7" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
            body.append(f'<text x="{X(mx):.1f}" y="{y-14}" {FONT} font-size="12" fill="{INK}" text-anchor="middle">{fmt_ns(mx)}</text>')
    write("max_pause.svg", 960, 235, body)

main()
