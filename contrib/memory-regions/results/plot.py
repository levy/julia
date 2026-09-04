#!/usr/bin/env python3
"""Draw every plot of MEASUREMENTS.md from the data files in data/.

Plain python, no plotting library: the output is SVG, written directly, so
the plots are rebuilt from the data with nothing but python3. One function
per plot; a plot whose data file is missing is skipped with a note. Each
plot carries a caption with the commit, the machine and the core from
data/context.tsv, which run_all.sh writes.

  python3 plot.py        reads data/*.tsv, writes plots/*.svg
"""
import math, os

D = os.path.dirname(os.path.abspath(__file__))
DATA, PLOTS = os.path.join(D, "data"), os.path.join(D, "plots")
SURFACE, GRID = "#fcfcfb", "#e8e7e4"
INK, INK2 = "#0b0b0b", "#52514e"
BLUE, YELLOW, ORANGE, GREEN = "#2a78d6", "#eda100", "#eb6834", "#1baf7a"
FONT = 'font-family="DejaVu Sans, sans-serif"'

# ---- data ---------------------------------------------------------------------

def read_tsv(name):
    """Rows as dicts keyed by the `# col\tcol` header; None when the file is absent."""
    path = os.path.join(DATA, name)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        print("skip: no", name)
        return None
    rows, cols = [], None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                cols = line[1:].strip().split("\t")
                continue
            rows.append(dict(zip(cols, line.split("\t"))))
    return rows

def num(s):
    return None if s in (None, "NA", "") else float(s)

def context():
    rows = read_tsv("context.tsv") or []
    return {r["key"]: r["value"] for r in rows}

def caption_text():
    c = context()
    parts = [f"julia {c.get('sha', '?')} ({c.get('julia', '?')})", c.get("cpu", "?"),
             f"core {c.get('core', '?')}", c.get("realtime", ""), c.get("date", "")]
    return " · ".join(p for p in parts if p)

# ---- formats ----------------------------------------------------------------------

def fmt_ns(ns):
    if ns == 0: return "0"
    if ns >= 1e9: return f"{ns/1e9:.1f} s"
    if ns >= 1e6: return f"{ns/1e6:.0f} ms" if ns >= 2e6 else f"{ns/1e6:.1f} ms"
    if ns >= 1e3: return f"{ns/1e3:.0f} µs" if ns >= 2e3 else f"{ns/1e3:.1f} µs"
    return f"{ns:.0f} ns" if ns >= 10 else f"{ns:.1f} ns"

def fmt_num(v):
    if v == 0: return "0"
    if abs(v) >= 1e6: return f"{v/1e6:g} M"
    if abs(v) >= 1e3: return f"{v/1e3:g} k"
    return f"{v:g}"

def fmt_ms(v):
    return fmt_ns(v * 1e6)

def nice_ticks(lo, hi, n=5):
    span = hi - lo
    if span <= 0:
        return [lo]
    raw = span / n
    mag = 10 ** math.floor(math.log10(raw))
    step = mag
    for m in (1, 2, 2.5, 5, 10):
        step = m * mag
        if span / step <= n:
            break
    v, ticks = math.ceil(lo / step) * step, []
    while v <= hi + step * 1e-9:
        ticks.append(round(v, 10))
        v += step
    return ticks

def decades(lo, hi):
    return [10.0 ** k for k in range(math.floor(math.log10(lo)), math.ceil(math.log10(hi)) + 1)]

def decade_bounds(values, lo_default, hi_default):
    # The whole decades that hold the values; one decade on each side when a
    # single value would leave the axis with no width.
    if not values:
        return lo_default, hi_default
    lo, hi = 10 ** math.floor(math.log10(min(values))), 10 ** math.ceil(math.log10(max(values)))
    if lo == hi:
        lo, hi = lo / 10, hi * 10
    return lo, hi

# ---- drawing ----------------------------------------------------------------------

def text(body, x, y, s, size=13, fill=INK, anchor="start", bold=False, extra=""):
    w = ' font-weight="bold"' if bold else ""
    body.append(f'<text x="{x:.1f}" y="{y:.1f}" {FONT} font-size="{size}" fill="{fill}" '
                f'text-anchor="{anchor}"{w}{extra}>{s}</text>')

def heading(body, title, subtitle):
    text(body, 40, 30, title, 17, bold=True)
    if subtitle:
        text(body, 40, 50, subtitle, 13, INK2)

def legend(body, x, y, series):
    for name, color in series:
        body.append(f'<line x1="{x}" y1="{y-4}" x2="{x+22}" y2="{y-4}" stroke="{color}" stroke-width="3" stroke-linecap="round"/>')
        text(body, x + 28, y, name, 13)
        x += 34 + max(7.2 * len(name), 36)

def caption(body, h):
    text(body, 40, h - 12, caption_text(), 11, INK2)

class Axes:
    """One panel; either axis linear or log10."""
    def __init__(self, x0, y0, w, h, xlo, xhi, ylo, yhi, xlog=False, ylog=False):
        self.x0, self.y0, self.w, self.h = x0, y0, w, h
        self.xlo, self.xhi, self.ylo, self.yhi = xlo, xhi, ylo, yhi
        self.xlog, self.ylog = xlog, ylog
    def X(self, v):
        if self.xlog:
            v = max(v, self.xlo)
            f = (math.log10(v) - math.log10(self.xlo)) / (math.log10(self.xhi) - math.log10(self.xlo))
        else:
            f = (v - self.xlo) / (self.xhi - self.xlo)
        return self.x0 + self.w * f
    def Y(self, v):
        if self.ylog:
            v = max(v, self.ylo)
            f = (math.log10(v) - math.log10(self.ylo)) / (math.log10(self.yhi) - math.log10(self.ylo))
        else:
            f = (v - self.ylo) / (self.yhi - self.ylo)
        return self.y0 + self.h - self.h * f
    def grid(self, body, xticks, yticks, xfmt, yfmt):
        y1 = self.y0 + self.h
        for v in xticks:
            x = self.X(v)
            body.append(f'<line x1="{x:.1f}" y1="{self.y0}" x2="{x:.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
            text(body, x, y1 + 18, xfmt(v), 12, INK2, "middle")
        for v in yticks:
            y = self.Y(v)
            body.append(f'<line x1="{self.x0}" y1="{y:.1f}" x2="{self.x0+self.w}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
            text(body, self.x0 - 8, y + 4, yfmt(v), 12, INK2, "end")
    def title(self, body, s):
        text(body, self.x0, self.y0 - 14, s, 15, bold=True)
    def xlabel(self, body, s):
        text(body, self.x0 + self.w / 2, self.y0 + self.h + 38, s, 13, INK2, "middle")
    def ylabel(self, body, s):
        x, y = self.x0 - 58, self.y0 + self.h / 2
        text(body, x, y, s, 13, INK2, "middle", extra=f' transform="rotate(-90 {x} {y})"')
    def line(self, body, pts, color, marker=True, dash=""):
        pts = [(x, y) for x, y in pts if x is not None and y is not None]
        if not pts:
            return
        d = " ".join(f"{'M' if i == 0 else 'L'}{self.X(x):.1f},{self.Y(y):.1f}" for i, (x, y) in enumerate(pts))
        dd = f' stroke-dasharray="{dash}"' if dash else ""
        body.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"{dd}/>')
        if marker:
            x, y = pts[-1]
            body.append(f'<circle cx="{self.X(x):.1f}" cy="{self.Y(y):.1f}" r="5" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
    def hline(self, body, v, color, label=None):
        y = self.Y(v)
        body.append(f'<line x1="{self.x0}" y1="{y:.1f}" x2="{self.x0+self.w}" y2="{y:.1f}" stroke="{color}" stroke-width="1.5" stroke-dasharray="6 4"/>')
        if label:
            text(body, self.x0 + self.w - 4, y - 6, label, 12, color, "end")

def bar_groups(body, ax, groups, series, values, fmt, sublabels=None, group_colors=None):
    """Grouped vertical bars from y=0. values[group][series] is a float or
    None. A group label may hold one newline; the second line is muted.
    group_colors, when given, paints the bars of each group in one color."""
    n, m = len(groups), len(series)
    slot = ax.w / n
    bw = slot * 0.72 / m
    base = ax.Y(0)
    for gi, g in enumerate(groups):
        gx = ax.x0 + slot * gi + slot * 0.14
        for si, (name, color) in enumerate(series):
            v = values[gi][si]
            if v is None:
                continue
            if group_colors:
                color = group_colors[gi]
            x, y = gx + si * bw, ax.Y(v)
            body.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw-3:.1f}" height="{base-y:.1f}" fill="{color}"/>')
            text(body, x + (bw - 3) / 2, y - 5, fmt(v), 10, INK, "middle")
        lines = g.split("\n")
        text(body, gx + slot * 0.36, base + 18, lines[0], 12, INK, "middle")
        if len(lines) > 1:
            text(body, gx + slot * 0.36, base + 33, lines[1], 11, INK2, "middle")
        if sublabels and sublabels[gi]:
            text(body, gx + slot * 0.36, base + 33 + 15 * (len(lines) - 1), sublabels[gi], 11, INK2, "middle")

def write(name, w, h, body):
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" font-size="13">',
           f'<rect width="{w}" height="{h}" fill="{SURFACE}"/>'] + body + ["</svg>"]
    os.makedirs(PLOTS, exist_ok=True)
    out = os.path.join(PLOTS, name)
    open(out, "w").write("\n".join(svg))
    print("wrote", out)

def ymax_of(values, floor=1.0):
    vs = [v for v in values if v is not None]
    return max(vs) * 1.18 if vs else floor

# ---- M1: zero cost when unused -----------------------------------------------------

def plot_gcbench():
    rows = read_tsv("gcbench.tsv")
    if not rows:
        return
    best = {}                                            # (set, bench, binary) -> min ns
    order = []
    for r in rows:
        k = (r["set"], r["bench"])
        if k not in order:
            order.append(k)
        kb = (r["set"], r["bench"], r["binary"])
        best[kb] = min(best.get(kb, float("inf")), float(r["wall_ns"]))
    rounds = max(int(r["round"]) for r in rows)
    groups, ratios, colors = [], [], []
    for s, b in order:
        v, g = best.get((s, b, "vanilla")), best.get((s, b, "regions"))
        if not v or not g:
            continue
        groups.append(os.path.basename(b).replace(".jl", "") + f"\nvanilla {fmt_ns(v)}")
        ratios.append([g / v])
        colors.append(YELLOW if s == "multithreaded" else BLUE)
    body = []
    heading(body, "The region runtime costs nothing while no region is in use",
            f"GCBenchmarks wall time, this branch / vanilla at the same base commit; the best of {rounds} rounds each; the dashed line is equal time")
    legend(body, 40, 74, [("one thread", BLUE), ("four threads", YELLOW)])
    ax = Axes(80, 100, max(90 * len(groups), 800), 260, 0, 1, 0, max(1.25, ymax_of([r[0] for r in ratios])))
    ax.grid(body, [], nice_ticks(0, ax.yhi, 5), fmt_num, lambda v: f"{v:.2f}")
    bar_groups(body, ax, groups, [("regions / vanilla", BLUE)], ratios, lambda v: f"{v:.3f}", group_colors=colors)
    ax.hline(body, 1.0, INK2)
    ax.ylabel(body, "wall time, regions / vanilla")
    h = ax.y0 + ax.h + 80
    caption(body, h)
    write("gcbench.svg", ax.x0 + ax.w + 40, h, body)

# ---- M2: unit costs -----------------------------------------------------------------

def plot_unit_costs():
    rows = read_tsv("unit_costs.tsv")
    if not rows:
        return
    costs, by = [], {}
    for r in rows:
        if r["cost"] not in costs:
            costs.append(r["cost"])
        by[(r["binary"], r["cost"])] = (float(r["value"]), r["unit"])
    vals = [v for v, _ in by.values() if v > 0]
    xlo, xhi = decade_bounds(vals, 1e-1, 1e2)
    body = []
    heading(body, "What one operation costs", "one row per micro-cost; a dot is the median of the runs; the axis is log")
    series = [("vanilla", BLUE), ("regions", ORANGE)]
    legend(body, 40, 74, series)
    x0, w, y0, rh = 260, 600, 100, 28
    X = lambda v: x0 + w * (math.log10(max(v, xlo)) - math.log10(xlo)) / (math.log10(xhi) - math.log10(xlo))
    y1 = y0 + rh * len(costs)
    for v in decades(xlo, xhi):
        body.append(f'<line x1="{X(v):.1f}" y1="{y0-10}" x2="{X(v):.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
        text(body, X(v), y1 + 18, fmt_ns(v), 12, INK2, "middle")
    for i, c in enumerate(costs):
        y = y0 + rh * i + rh / 2
        text(body, x0 - 16, y + 4, c, 13, INK, "end")
        for name, color in series:
            if (name, c) not in by:
                continue
            v, unit = by[(name, c)]
            body.append(f'<circle cx="{X(v):.1f}" cy="{y}" r="6" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
            dy = -9 if name == "vanilla" else 15
            text(body, X(v), y + dy, f"{v:g} {unit}", 10, INK, "middle")
    h = y1 + 60
    caption(body, h)
    write("unit_costs.svg", x0 + w + 60, h, body)

# ---- M3: the tail, one Bool apart ---------------------------------------------------

def plot_tail():
    rows = read_tsv("tail.tsv")
    if not rows:
        return
    names = {("yardstick", "alloc"): "yardstick: allocate per event",
             ("yardstick", "pooled"): "yardstick: pooled, no allocation",
             ("tail", "baseline"): "model: stock GC",
             ("tail", "regions"): "model: regions"}
    pct = [("p50", "p50_ns", BLUE), ("p99", "p99_ns", YELLOW), ("p99.9", "p999_ns", ORANGE),
           ("p99.99", "p9999_ns", GREEN), ("max", "max_ns", INK)]
    body = []
    heading(body, "Event latency: the percentiles and the longest event",
            f"{fmt_num(float(rows[0]['events']))} events per run, isolated core; a row is one run; the axis is log")
    legend(body, 40, 74, [(n, c) for n, _, c in pct])
    x0, w, y0, rh = 300, 600, 110, 34
    xlo, xhi = 1e1, 1e8
    X = lambda v: x0 + w * (math.log10(max(v, xlo)) - 1) / (math.log10(xhi) - 1)
    y1 = y0 + rh * len(rows)
    for v in decades(xlo, xhi):
        body.append(f'<line x1="{X(v):.1f}" y1="{y0-10}" x2="{X(v):.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
        text(body, X(v), y1 + 18, fmt_ns(v), 12, INK2, "middle")
    for i, r in enumerate(rows):
        y = y0 + rh * i + rh / 2
        text(body, x0 - 16, y + 4, names.get((r["script"], r["variant"]), f"{r['script']} {r['variant']}"), 13, INK, "end")
        xs = [num(r[col]) for _, col, _ in pct]
        lo, hi = min(x for x in xs if x), max(x for x in xs if x)
        body.append(f'<line x1="{X(lo):.1f}" y1="{y}" x2="{X(hi):.1f}" y2="{y}" stroke="{GRID}" stroke-width="2"/>')
        for (label, col, color), v in zip(pct, xs):
            if v is None:
                continue
            body.append(f'<circle cx="{X(v):.1f}" cy="{y}" r="6" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
        text(body, X(hi) + 12, y + 4, f"max {fmt_ns(hi)}, {r['over_100us']} events over 100 µs, {r['gc_events']} collections", 11, INK2)
    h = y1 + 60
    caption(body, h)
    write("tail.svg", x0 + w + 320, h, body)

# ---- M4: the real-world loop (the CCDF and the longest pause) ---------------------

REALWORLD = [("stock, heuristics", BLUE, "auto"),
             ("stock, scheduled", YELLOW, "sched"),
             ("regions, census every 100 k", ORANGE, "census"),
             ("regions, no census", GREEN, "nocensus")]

def read_ccdf(name):
    path = os.path.join(DATA, name)
    if not os.path.exists(path):
        return None
    pts = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            a, b = line.split()
            if int(b) > 0:
                pts.append((int(b), float(a)))
    return pts

def ccdf_panel(body, p, title, W, label_dy):
    x1, y1 = p.x0 + p.w, p.y0 + p.h
    p.title(body, title)
    for v in decades(p.xlo, p.xhi):
        x = p.X(v)
        body.append(f'<line x1="{x:.1f}" y1="{p.y0}" x2="{x:.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
        text(body, x, y1 + 18, fmt_ns(v), 12, INK2, "middle")
    for k in range(int(-math.log10(p.ylo)) + 1):
        y = p.Y(10 ** -k)
        body.append(f'<line x1="{p.x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
        lab = "all" if k == 0 else ("10<tspan dy=\"-4\" font-size=\"9\">-%d</tspan>" % k)
        text(body, p.x0 - 8, y + 4, lab, 12, INK2, "end")
    for (name, color, tag), ldy in zip(REALWORLD, label_dy):
        pts = read_ccdf(f"ccdf_{tag}_W{W}.tsv")
        if not pts:
            continue
        path = " ".join(f"{'M' if i == 0 else 'L'}{p.X(ns):.1f},{p.Y(f):.1f}"
                        for i, (ns, f) in enumerate(pts) if ns >= p.xlo)
        body.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        mx, mf = pts[-1]
        cx, cy = p.X(mx), p.Y(mf)
        body.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
        text(body, cx, cy + ldy, f"max {fmt_ns(mx)}", 12, INK, "end")

def plot_realworld():
    if not any(read_ccdf(f"ccdf_{t}_W{W}.tsv") for _, _, t in REALWORLD for W in (3, 200)):
        print("skip: no ccdf_*.tsv")
        return
    series = [(n, c) for n, c, _ in REALWORLD]
    body = []
    heading(body, "How many events are at least this slow",
            "5 million events each, isolated core, SCHED_FIFO, memory locked, 512 MB heap reserve; the marker is the longest event")
    legend(body, 40, 74, series)
    pa = Axes(80, 110, 380, 300, 1e1, 1e7, 1e-7, 1, True, True)
    pb = Axes(560, 110, 380, 300, 1e1, 1e7, 1e-7, 1, True, True)
    ccdf_panel(body, pa, "~1.7 KB of garbage per event", 200, [-10, 20, -10, 20])
    ccdf_panel(body, pb, "~100 B of garbage per event", 3, [-10, 20, -10, 20])
    text(body, 510, 445, "event latency", 13, INK2, "middle")
    text(body, 20, 260, "fraction of events ≥ x", 13, INK2, "middle", extra=' transform="rotate(-90 20 260)"')
    caption(body, 480)
    write("latency_ccdf.svg", 980, 480, body)

    body = []
    heading(body, "The longest pause any event took", "")
    legend(body, 40, 54, series)
    x0, x1w, xlo = 220, 660, 1e4
    X = lambda ns: x0 + x1w * (math.log10(ns) - 4) / 3
    for k in range(4):
        x = X(xlo * 10 ** k)
        body.append(f'<line x1="{x:.1f}" y1="80" x2="{x:.1f}" y2="195" stroke="{GRID}" stroke-width="1"/>')
        text(body, x, 215, fmt_ns(xlo * 10 ** k), 12, INK2, "middle")
    for label, y, W in [("~1.7 KB per event", 110, 200), ("~100 B per event", 170, 3)]:
        text(body, x0 - 16, y + 5, label, 13, INK, "end")
        for name, color, tag in REALWORLD:
            pts = read_ccdf(f"ccdf_{tag}_W{W}.tsv")
            if not pts:
                continue
            mx = pts[-1][0]
            body.append(f'<circle cx="{X(mx):.1f}" cy="{y}" r="7" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
            text(body, X(mx), y - 14, fmt_ns(mx), 12, INK, "middle")
    caption(body, 255)
    write("max_pause.svg", 960, 255, body)

# ---- M5: the census ----------------------------------------------------------------

def plot_census_pause():
    rows = read_tsv("census_pause.tsv")
    if not rows:
        return
    series = [("scoped: census of the region only", BLUE), ("coop: census, cooperative sweep", YELLOW),
              ("full: stock collection of the whole heap", ORANGE)]
    tags = ["scoped", "coop", "full"]
    body = []
    heading(body, "A census pause grows with the live cells, and only with them",
            f"{fmt_num(float(rows[0]['events']))} events, a census every {fmt_num(float(rows[0]['every']))}; K live cells kept across the census")
    legend(body, 40, 74, series)
    Ks = sorted({float(r["K"]) for r in rows})
    allp = [num(r[c]) for r in rows for c in ("pause_p50_ms", "pause_max_ms") if num(r[c])]
    ylo, yhi = decade_bounds(allp, 1e-3, 1e2)
    xlo, xhi = decade_bounds(Ks, 1e2, 1e5)
    panels = [("median pause", "pause_p50_ms", Axes(90, 110, 360, 280, xlo, xhi, ylo, yhi, True, True)),
              ("longest pause", "pause_max_ms", Axes(560, 110, 360, 280, xlo, xhi, ylo, yhi, True, True))]
    for title, col, ax in panels:
        ax.title(body, title)
        ax.grid(body, decades(xlo, xhi), decades(ylo, yhi), fmt_num, fmt_ms)
        for (name, color), tag in zip(series, tags):
            pts = sorted((float(r["K"]), num(r[col])) for r in rows if r["variant"] == tag)
            ax.line(body, pts, color)
        ax.xlabel(body, "K, live cells")
    panels[0][2].ylabel(body, "pause")
    caption(body, 470)
    write("census_pause.svg", 980, 470, body)

def plot_census_throughput():
    rows = read_tsv("census_throughput.tsv")
    if not rows:
        return
    def key(r):
        if r["variant"] == "batch":
            return f"batch B={int(float(r['B']))}"
        return r["variant"]
    names = {"autopool": "region, one reset per event", "pooled": "hand-pooled, no allocation"}
    variants = []
    for r in rows:
        k = key(r)
        if k not in variants:
            variants.append(k)
    Ws = sorted({int(float(r["W"])) for r in rows})
    series = [(names.get(v, v.replace("batch", "region, reset every")), c) for v, c in zip(variants, [BLUE, YELLOW, ORANGE, GREEN, INK2])]
    values = [[next((num(r["events_per_s"]) for r in rows if key(r) == v and int(float(r["W"])) == W), None)
               for v in variants] for W in Ws]
    body = []
    heading(body, "Throughput of the event loop: a region reset is cheap enough to do per event",
            f"{fmt_num(float(rows[0]['events']))} events, one core; W words of garbage per event")
    legend(body, 40, 74, series)
    ax = Axes(90, 100, 700, 260, 0, 1, 0, ymax_of([v for g in values for v in g]))
    ax.grid(body, [], nice_ticks(0, ax.yhi, 5), fmt_num, lambda v: f"{v/1e6:g} M")
    bar_groups(body, ax, [f"W = {W}" for W in Ws], series, values, lambda v: f"{v/1e6:.1f} M")
    ax.ylabel(body, "events per second")
    caption(body, 440)
    write("census_throughput.svg", 880, 440, body)

# ---- M6: endurance ------------------------------------------------------------------

def plot_endurance():
    rows = read_tsv("endurance.tsv")
    if not rows:
        return
    ts = [float(r["t_s"]) for r in rows]
    rss = [float(r["rss_mb"]) for r in rows]
    live = [float(r["live_mb"]) for r in rows]
    misses = int(float(rows[-1]["misses"]))
    body = []
    heading(body, "Memory stays flat over a long paced run",
            f"{fmt_ns(ts[-1]*1e9)} of paced events, one event per 100 µs slot; {misses} slot misses in total")
    series = [("resident set (RSS)", BLUE), ("live heap counter", ORANGE)]
    legend(body, 40, 74, series)
    ax = Axes(90, 100, 760, 260, 0, max(ts), 0, ymax_of(rss + live))
    ax.grid(body, nice_ticks(0, max(ts), 6), nice_ticks(0, ax.yhi, 5), lambda v: f"{v:g} s", lambda v: f"{v:g} MB")
    ax.line(body, list(zip(ts, rss)), BLUE)
    ax.line(body, list(zip(ts, live)), ORANGE)
    ax.xlabel(body, "time")
    ax.ylabel(body, "memory")
    caption(body, 440)
    write("endurance.svg", 940, 440, body)

def plot_paced():
    rows = read_tsv("paced.tsv")
    if not rows:
        return
    names = {"baseline": "stock GC", "regions": "regions"}
    cols = [("latency p50", "latency_p50_ns", BLUE), ("latency p99.9", "latency_p999_ns", YELLOW),
            ("latency max", "latency_max_ns", ORANGE), ("lateness max", "lateness_max_ns", GREEN)]
    body = []
    heading(body, "Paced events: how late the loop was at its worst",
            f"{fmt_num(float(rows[0]['events']))} events, one event per 100 µs slot; lateness is the delay past the slot start")
    legend(body, 40, 74, [(n, c) for n, _, c in cols])
    x0, w, y0, rh = 200, 640, 110, 40
    xlo, xhi = 1e1, 1e8
    X = lambda v: x0 + w * (math.log10(max(v, xlo)) - 1) / (math.log10(xhi) - 1)
    y1 = y0 + rh * len(rows)
    for v in decades(xlo, xhi):
        body.append(f'<line x1="{X(v):.1f}" y1="{y0-10}" x2="{X(v):.1f}" y2="{y1}" stroke="{GRID}" stroke-width="1"/>')
        text(body, X(v), y1 + 18, fmt_ns(v), 12, INK2, "middle")
    for i, r in enumerate(rows):
        y = y0 + rh * i + rh / 2
        text(body, x0 - 16, y + 4, names.get(r["variant"], r["variant"]), 13, INK, "end")
        for label, col, color in cols:
            v = num(r[col])
            if v is None:
                continue
            body.append(f'<circle cx="{X(v):.1f}" cy="{y}" r="6" fill="{color}" stroke="{SURFACE}" stroke-width="2"/>')
        text(body, X(xhi) + 12, y + 4, f"{r['slot_misses']} slot misses, {r['gc_events']} collections", 11, INK2)
    h = y1 + 60
    caption(body, h)
    write("paced.svg", x0 + w + 260, h, body)

# ---- M7: region-native against C++ -------------------------------------------------

def plot_native():
    rows = read_tsv("native.tsv")
    if not rows:
        return
    names = {"region": ("Julia, regions", ORANGE), "stock": ("Julia, stock GC", BLUE), "cpp": ("C++, malloc/free", INK2)}
    Ws = sorted({int(float(r["W"])) for r in rows})
    variants = [v for v in ("stock", "region", "cpp") if any(r["variant"] == v for r in rows)]
    series = [names[v] for v in variants]
    values = [[next((num(r["events_per_s"]) for r in rows if r["variant"] == v and int(float(r["W"])) == W), None)
               for v in variants] for W in Ws]
    body = []
    heading(body, "The same event loop, region-native Julia against C++",
            f"{fmt_num(float(rows[0]['events']))} events, one core; W words of garbage per event")
    legend(body, 40, 74, series)
    ax = Axes(90, 100, 560, 260, 0, 1, 0, ymax_of([v for g in values for v in g]))
    ax.grid(body, [], nice_ticks(0, ax.yhi, 5), fmt_num, lambda v: f"{v/1e6:g} M")
    bar_groups(body, ax, [f"W = {W}" for W in Ws], series, values, lambda v: f"{v/1e6:.1f} M")
    ax.ylabel(body, "events per second")
    caption(body, 440)
    write("native.svg", 740, 440, body)

# ---- M8: wholesale death, the showcases --------------------------------------------

def plot_showcase():
    rows = read_tsv("showcase.tsv")
    if not rows:
        return
    best = {}
    for r in rows:
        mode = "region" if r["mode"] in ("region", "tree") else "stock"
        k = (r["showcase"], mode)
        if k not in best or float(r["wall_s"]) < float(best[k]["wall_s"]):
            best[k] = r
    shows = [s for s in ("binarytree", "linkedlist", "tree") if (s, "stock") in best]
    labels = {"binarytree": lambda r: f"binary tree\ndepth {int(float(r['param']))}",
              "linkedlist": lambda r: f"linked list\n{int(float(r['param']))} MB",
              "tree": lambda r: f"shared tree\n{int(float(r['param']))} workers"}
    groups = [labels[s](best[(s, "stock")]) for s in shows]
    series = [("stock GC", BLUE), ("regions", ORANGE)]
    rounds = max(1, sum(1 for r in rows if r["showcase"] == shows[0] and r["mode"] == "stock"))
    body = []
    heading(body, "Wholesale death: a structure that dies at once is freed at once",
            f"the best of {rounds} rounds each; a bar pair is one program run twice, once per mode")
    legend(body, 40, 74, series)
    panels = [("wall time", "wall_s", lambda v: f"{v:.2f} s", lambda v: f"{v:g} s"),
              ("time in the collector", "gc_ms", lambda v: fmt_ms(v), lambda v: fmt_ms(v)),
              ("peak RSS", "peak_rss_mb", lambda v: f"{v:.0f} MB", lambda v: f"{v:g} MB")]
    x = 90
    for title, col, fmt, tick in panels:
        values = [[num(best[(s, m)][col]) if (s, m) in best else None for m, _ in (("stock", 0), ("region", 0))] for s in shows]
        ax = Axes(x, 110, 330, 240, 0, 1, 0, ymax_of([v for g in values for v in g]))
        ax.title(body, title)
        ax.grid(body, [], nice_ticks(0, ax.yhi, 4), fmt_num, tick)
        bar_groups(body, ax, groups, series, values, fmt)
        x += 400
    caption(body, 440)
    write("showcase.svg", x - 40, 440, body)

# ---- M9: the growth bound ------------------------------------------------------------

def plot_census_bound():
    rows = read_tsv("census_bound.tsv")
    if not rows:
        return
    series = [("no census threshold", BLUE), ("census threshold 64 pages", ORANGE)]
    body = []
    heading(body, "A census threshold bounds the pages a region can hold",
            "a loop that stores into a live region every round; pages of region 1 as the rounds go by")
    legend(body, 40, 74, series)
    xs = [float(r["round"]) for r in rows]
    ys = [float(r["pages"]) for r in rows]
    ax = Axes(90, 100, 760, 260, 0, max(xs), 0, ymax_of(ys))
    ax.grid(body, nice_ticks(0, max(xs), 6), nice_ticks(0, ax.yhi, 5), fmt_num, fmt_num)
    for armed, (name, color) in zip(("0", "1"), series):
        pts = [(float(r["round"]), float(r["pages"])) for r in rows if r["armed"] == armed]
        ax.line(body, pts, color)
    ax.hline(body, 64, ORANGE, "64 pages")
    ax.xlabel(body, "round")
    ax.ylabel(body, "pages held")
    caption(body, 440)
    write("census_bound.svg", 940, 440, body)

# ---- M10: the demonstrators ------------------------------------------------------------

DEMOS = {"A": ("demo_a.tsv", "bt_solver: backtracking search, one thread", "an instance is solved in a region; the search tree dies at once"),
         "B": ("demo_b.tsv", "pathtrace: rays in per-thread leaves", "each thread's rays die in its leaf; the image lives in the trunk"),
         "C": ("demo_c.tsv", "optimistic_bst: speculation that mostly aborts", "an aborted transaction's garbage dies in the leaf, uncollected"),
         "D": ("demo_d.tsv", "dmr: mesh refinement, the cavity per thread", "a cavity's scratch dies in the leaf; the mesh lives in the trunk")}

def plot_demo(demo):
    fname, title, sub = DEMOS[demo]
    rows = read_tsv(fname)
    if not rows:
        return
    points = []
    for r in rows:
        if r["point"] not in points:
            points.append(r["point"])
    def pick(p, mode):
        return next((r for r in rows if r["point"] == p and r["mode"] == mode), None)
    series = [("stock GC", BLUE), ("regions", ORANGE)]
    values, subs = [], []
    for p in points:
        s, g = pick(p, "stock"), pick(p, "region")
        values.append([num(s["wall_ms"]) if s else None, num(g["wall_ms"]) if g else None])
        if s and g:
            subs.append(f"{int(float(s['collections']))} → {int(float(g['collections']))} collections, ×{float(s['wall_ms'])/float(g['wall_ms']):.2f}")
        else:
            subs.append("")
    threads = rows[0]["threads"]
    body = []
    heading(body, title, f"{sub}; {threads} thread{'s' if threads != '1' else ''}; under a pair: collections stock → regions, and the speedup")
    legend(body, 40, 74, series)
    ax = Axes(90, 100, max(180 * len(points), 800), 260, 0, 1, 0, ymax_of([v for g in values for v in g]))
    ax.grid(body, [], nice_ticks(0, ax.yhi, 5), fmt_num, lambda v: fmt_ms(v))
    bar_groups(body, ax, points, series, values, lambda v: fmt_ms(v), subs)
    ax.ylabel(body, "wall time")
    caption(body, 440)
    write(f"demo_{demo.lower()}.svg", ax.x0 + ax.w + 40, 440, body)

def plot_demo_rss():
    groups, values = [], []
    for demo, (fname, title, _) in DEMOS.items():
        rows = read_tsv(fname)
        if not rows:
            continue
        last = rows[-1]["point"]
        s = next((r for r in rows if r["point"] == last and r["mode"] == "stock"), None)
        g = next((r for r in rows if r["point"] == last and r["mode"] == "region"), None)
        groups.append(f"{demo}: {title.split(':')[0]}, {last}")
        values.append([num(s["peak_rss_mb"]) if s else None, num(g["peak_rss_mb"]) if g else None])
    if not groups:
        return
    series = [("stock GC", BLUE), ("regions", ORANGE)]
    body = []
    heading(body, "Peak memory of the demonstrators at their largest point",
            "one process runs both modes, region first; the peak is the process maximum after each mode")
    legend(body, 40, 74, series)
    ax = Axes(90, 100, 200 * len(groups) + 40, 240, 0, 1, 0, ymax_of([v for g in values for v in g]))
    ax.grid(body, [], nice_ticks(0, ax.yhi, 5), fmt_num, lambda v: f"{v:g} MB")
    bar_groups(body, ax, groups, series, values, lambda v: f"{v:.0f} MB")
    ax.ylabel(body, "peak RSS")
    caption(body, 420)
    write("demo_rss.svg", ax.x0 + ax.w + 40, 420, body)

# ---- M12: thread scaling -----------------------------------------------------------------

def plot_scaling():
    rows = read_tsv("scaling.tsv")
    if not rows:
        return
    series = [("stock GC", BLUE), ("regions", ORANGE)]
    body = []
    heading(body, "The sibling leaves scale with the threads",
            "the largest point of each demonstrator, at 1, 2, 4 and 8 threads; wall time, lower is better")
    legend(body, 40, 74, series)
    demos = [d for d in ("B", "D") if any(r["demo"] == d for r in rows)]
    x = 90
    for d in demos:
        drows = [r for r in rows if r["demo"] == d]
        last = [r for r in drows if r["threads"] == drows[0]["threads"]][-1]["point"]
        pts = [r for r in drows if r["point"] == last]
        ts = sorted({int(r["threads"]) for r in pts})
        ws = [num(r["wall_ms"]) for r in pts]
        ax = Axes(x, 110, 340, 260, 1, max(ts), 0, ymax_of(ws), True, False)
        ax.title(body, f"{DEMOS[d][1].split(':')[0]}, {last}")
        ax.grid(body, ts, nice_ticks(0, ax.yhi, 5), lambda v: f"{int(v)}", lambda v: fmt_ms(v))
        for mode, (name, color) in zip(("stock", "region"), series):
            ax.line(body, sorted((int(r["threads"]), num(r["wall_ms"])) for r in pts if r["mode"] == mode), color)
        ax.xlabel(body, "threads")
        x += 440
    caption(body, 470)
    write("scaling.svg", x - 60, 470, body)

def main():
    plot_gcbench()
    plot_unit_costs()
    plot_tail()
    plot_realworld()
    plot_census_pause()
    plot_census_throughput()
    plot_paced()
    plot_endurance()
    plot_native()
    plot_showcase()
    plot_census_bound()
    for d in DEMOS:
        plot_demo(d)
    plot_demo_rss()
    plot_scaling()

main()
