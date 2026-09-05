#!/usr/bin/env python3
"""Fill the tables of MEASUREMENTS.md from the data files in data/.

Every table in MEASUREMENTS.md sits between a `<!-- table NAME -->` line and
a `<!-- /table -->` line. This script reads data/*.tsv with the reader of
plot.py, renders one markdown table per marker, and rewrites the document
in place; the prose around the markers is not touched. A table whose data
file is missing is left as it stands, with a note.

  python3 tables.py        reads data/*.tsv, rewrites ../MEASUREMENTS.md
"""
import os, re, statistics
from plot import read_tsv, num

D = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(D, "..", "MEASUREMENTS.md")
DASH = "—"

# ---- formats ------------------------------------------------------------------------

def f0(v):  return DASH if v is None else f"{v:,.0f}"
def f1(v):  return DASH if v is None else f"{v:.1f}"
def f2(v):  return DASH if v is None else f"{v:.2f}"
def f3(v):  return DASH if v is None else f"{v:.3f}"
def g4(v):  return DASH if v is None else f"{v:.4g}"
def fM(v):  return DASH if v is None else f"{v/1e6:.1f} M"
def ratio(a, b): return DASH if a is None or b is None or b == 0 else f"{a/b:.2f}"

def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" for _ in header) + " |"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return out

def best(rows, key, col):
    """The row with the smallest `col` per `key(row)`, in first-seen order."""
    seen, out = [], {}
    for r in rows:
        k = key(r)
        if k not in out:
            seen.append(k)
        if k not in out or num(r[col]) < num(out[k][col]):
            out[k] = r
    return seen, out

# ---- tables -------------------------------------------------------------------------

def t_gcbench():
    rows = read_tsv("gcbench.tsv")
    if not rows:
        return None
    order, runs = [], {}
    for r in rows:
        k = (r["set"], r["bench"], r["threads"])
        if k not in runs:
            order.append(k)
            runs[k] = {"vanilla": [], "regions": []}
        runs[k][r["binary"]].append(num(r["wall_ns"]) / 1e9)
    out = []
    for k in order:
        v, g = runs[k]["vanilla"], runs[k]["regions"]
        if not v or not g:
            continue
        spread = max((max(v) - min(v)) / min(v), (max(g) - min(g)) / min(g))
        out.append([os.path.basename(k[1]).replace(".jl", ""), k[2], f3(min(v)), f3(min(g)),
                    ratio(min(g), min(v)), min(len(v), len(g)), f"{100*spread:.0f} %"])
    return table(["benchmark", "threads", "vanilla (s)", "regions (s)", "ratio", "rounds", "spread"], out)

UNIT_COSTS = ["store_disarmed", "store_armed", "store_region", "window_pair", "switch_pair",
              "construct_two", "construct_shared", "box_twin", "alloc_stock", "alloc_region", "reset_slice", "stock_mark"]

def t_unit_costs():
    rows = read_tsv("unit_costs.tsv")
    if not rows:
        return None
    by = {(r["binary"], r["cost"]): r for r in rows}
    out = []
    for cost in UNIT_COSTS:
        cells = [by.get((b, cost)) for b in ("vanilla", "regions_stock", "regions")]
        unit = next((c["unit"] for c in cells if c), "")
        out.append([cost, unit] + [g4(num(c["value"])) if c else DASH for c in cells])
    return table(["cost", "unit", "vanilla", "regions, no window", "regions"], out)

def t_tail():
    rows = read_tsv("tail.tsv")
    if not rows:
        return None
    out = [[r["script"], r["variant"], f0(num(r["p50_ns"])), f0(num(r["p99_ns"])), f0(num(r["p999_ns"])),
            f0(num(r["p9999_ns"])), f0(num(r["max_ns"])), f0(num(r["over_100us"])), f0(num(r["gc_events"])),
            f1(num(r["gc_ms"])), f0(num(r["peak_rss_mb"]))] for r in rows]
    return table(["script", "variant", "p50 (ns)", "p99 (ns)", "p99.9 (ns)", "p99.99 (ns)", "max (ns)",
                  "over 100 µs", "collections", "GC (ms)", "peak RSS (MB)"], out)

def realworld_mode(r):
    if r["variant"] == "auto":  return "stock, own heuristics"
    if r["variant"] == "sched": return "stock, program schedule"
    return "regions, census" if num(r["every"]) else "regions, no census"

def t_realworld():
    rows = read_tsv("realworld.tsv")
    if not rows:
        return None
    out = [[("recording" if num(r["W"]) > 50 else "light") + f", W={r['W']}", realworld_mode(r),
            fM(num(r["events_per_s"])), f0(num(r["p50_ns"])), f0(num(r["p99_ns"])), f0(num(r["p9999_ns"])),
            f0(num(r["max_ns"])), f0(num(r["max_clean_ns"])), f0(num(r["stock_collections"])),
            f0(num(r["peak_rss_mb"]))] for r in rows]
    return table(["class", "mode", "events/s", "p50 (ns)", "p99 (ns)", "p99.99 (ns)", "max (ns)",
                  "max, no preemption (ns)", "stock collections", "peak RSS (MB)"], out)

def t_census_pause():
    rows = read_tsv("census_pause.tsv")
    if not rows:
        return None
    out = [[r["variant"], f0(num(r["K"])), f1(num(r["pause_p50_ms"]) * 1e3), f1(num(r["pause_max_ms"]) * 1e3),
            f1(num(r["stw_us"])) if num(r["stw_us"]) is not None else DASH,
            f1(num(r["mark_us"])) if num(r["mark_us"]) is not None else DASH,
            f1(num(r["sweep_us"])) if num(r["sweep_us"]) is not None else DASH,
            f0(num(r["live_cells"])), f0(num(r["freed_cells"]))] for r in rows]
    return table(["variant", "K", "pause p50 (µs)", "pause max (µs)", "stop the world (µs)", "mark (µs)",
                  "sweep (µs)", "live cells", "freed cells"], out)

def t_census_throughput():
    rows = read_tsv("census_throughput.tsv")
    if not rows:
        return None
    out = [[r["variant"], r["W"], r["B"], fM(num(r["events_per_s"])), f0(num(r["collections"])),
            f0(num(r["peak_rss_mb"]))] for r in rows]
    return table(["variant", "W", "B", "events/s", "collections", "peak RSS (MB)"], out)

def t_paced():
    rows = read_tsv("paced.tsv")
    if not rows:
        return None
    out = [[r["variant"], f0(num(r["events"])), f0(num(r["latency_p50_ns"])), f0(num(r["latency_max_ns"])),
            f0(num(r["lateness_p999_ns"])), f0(num(r["lateness_max_ns"])), f0(num(r["slot_misses"])),
            f0(num(r["gc_events"])), f1(num(r["gc_ms"]))] for r in rows]
    return table(["variant", "events", "latency p50 (ns)", "latency max (ns)", "lateness p99.9 (ns)",
                  "lateness max (ns)", "slot misses", "GC events", "GC (ms)"], out)

def t_endurance():
    rows = read_tsv("endurance.tsv")
    if not rows:
        return None
    rss = [num(r["rss_mb"]) for r in rows]
    out = [["samples (one per 100 000 events)", f0(len(rows))],
           ["events", f0(100_000 * len(rows))],
           ["wall (s)", f0(num(rows[-1]["t_s"]))],
           ["RSS at the first sample (MB)", f2(rss[0])],
           ["RSS at the last sample (MB)", f2(rss[-1])],
           ["RSS max (MB)", f2(max(rss))],
           ["allocated through the region, first to last sample (MB)",
            f0(num(rows[-1]["live_mb"]) - num(rows[0]["live_mb"]))],
           ["slot misses", f0(sum(num(r["misses"]) for r in rows))]]
    return table(["endurance", "value"], out)

def t_native():
    rows = read_tsv("native.tsv")
    if not rows:
        return None
    out = [[r["variant"], r["W"], fM(num(r["events_per_s"])), f0(num(r["censuses"])),
            f1(num(r["census_p50_ms"]) * 1e3) if num(r["census_p50_ms"]) is not None else DASH,
            f1(num(r["census_max_ms"]) * 1e3) if num(r["census_max_ms"]) is not None else DASH,
            f1(num(r["peak_rss_mb"]))] for r in rows]
    return table(["variant", "W", "events/s", "censuses", "census p50 (µs)", "census max (µs)", "peak RSS (MB)"], out)

def t_showcase():
    rows = read_tsv("showcase.tsv")
    if not rows:
        return None
    for r in rows:
        r["mode"] = "regions" if r["mode"] in ("region", "tree") else "stock"
    order, b = best(rows, lambda r: (r["showcase"], r["mode"]), "wall_s")
    rounds = {}
    for r in rows:
        rounds[(r["showcase"], r["mode"])] = rounds.get((r["showcase"], r["mode"]), 0) + 1
    out = []
    for k in sorted(order, key=lambda k: (["binarytree", "linkedlist", "tree"].index(k[0]), k[1] != "stock")):
        r = b[k]
        out.append([k[0], k[1], f3(num(r["wall_s"])), f0(num(r["collections"])), f1(num(r["gc_ms"])),
                    f0(num(r["peak_rss_mb"])), rounds[k]])
    return table(["showcase", "mode", "wall (s)", "collections", "GC (ms)", "peak RSS (MB)", "rounds"], out)

def t_census_bound():
    rows = read_tsv("census_bound.tsv")
    if not rows:
        return None
    by = {}
    for r in rows:
        by.setdefault(r["armed"], []).append((int(num(r["round"])), num(r["pages"])))
    last = {a: v[-1] for a, v in by.items()}
    top = {a: max(p for _, p in v) for a, v in by.items()}
    out = [["disarmed" if a == "0" else "armed", f0(last[a][0]), f0(last[a][1]), f0(top[a]),
            ratio(top["0"], top[a])] for a in ("0", "1") if a in by]
    return table(["census", "rounds", "pages at the last round", "pages max", "ratio disarmed / armed"], out)

def paired(rows, key):
    """(key, region row, stock row) per point, in first-seen order."""
    order, by = [], {}
    for r in rows:
        k = key(r)
        if k not in by:
            order.append(k)
            by[k] = {}
        by[k][r["mode"]] = r
    return [(k, by[k].get("region"), by[k].get("stock")) for k in order]

def point_label(r):
    return re.sub(r"\s+", " ", r["point"]).strip()

def t_demos():
    out = []
    for name in ("demo_a.tsv", "demo_b.tsv", "demo_c.tsv", "demo_d.tsv"):
        rows = read_tsv(name)
        if not rows:
            continue
        for k, g, s in paired(rows, lambda r: (r["demo"], r["point"], r["threads"])):
            if not g or not s:
                continue
            out.append([k[0], point_label(g), k[2], f1(num(s["wall_ms"])), f1(num(g["wall_ms"])),
                        ratio(num(s["wall_ms"]), num(g["wall_ms"])), f0(num(s["collections"])),
                        f0(num(g["collections"])), f1(num(s["gc_ms"])), f1(num(g["gc_ms"])),
                        f0(num(s["peak_rss_mb"])), f0(num(g["peak_rss_mb"]))])
    if not out:
        return None
    return table(["demo", "point", "threads", "wall stock (ms)", "wall regions (ms)", "stock / regions",
                  "collections stock", "collections regions", "GC stock (ms)", "GC regions (ms)",
                  "peak RSS stock (MB)", "peak RSS regions (MB)"], out)

def t_checker():
    rows = read_tsv("checker.tsv")
    if not rows:
        return None
    return table(["model", "events", "violations (stores)", "sites"],
                 [[r["model"], f0(num(r["events"])), f0(num(r["violations"])), f0(num(r["sites"]))] for r in rows])

def t_scaling():
    rows = read_tsv("scaling.tsv")
    if not rows:
        return None
    out = []
    for k, g, s in paired(rows, lambda r: (r["demo"], r["point"], r["threads"])):
        if not g or not s:
            continue
        out.append([k[0], point_label(g).split("(")[0].strip(), k[2], f1(num(s["wall_ms"])), f1(num(g["wall_ms"])),
                    ratio(num(s["wall_ms"]), num(g["wall_ms"])), f0(num(s["collections"])),
                    f0(num(g["collections"])), f1(num(s["gc_ms"])), f1(num(g["gc_ms"]))])
    return table(["demo", "point", "threads", "wall stock (ms)", "wall regions (ms)", "stock / regions",
                  "collections stock", "collections regions", "GC stock (ms)", "GC regions (ms)"], out)

TABLES = {"M1": t_gcbench, "M2": t_unit_costs, "M3": t_tail, "M4": t_realworld,
          "M5-pause": t_census_pause, "M5-throughput": t_census_throughput,
          "M6-paced": t_paced, "M6-endurance": t_endurance, "M7": t_native, "M8": t_showcase,
          "M9": t_census_bound, "M10": t_demos, "M11": t_checker, "M12": t_scaling}

# ---- the document -------------------------------------------------------------------

def main():
    with open(DOC) as f:
        text = f.read()
    for name, make in TABLES.items():
        pattern = re.compile(rf"(<!-- table {re.escape(name)} -->\n)(.*?)(<!-- /table -->)", re.S)
        if not pattern.search(text):
            print("no marker for", name)
            continue
        lines = make()
        if lines is None:
            print("kept:", name)
            continue
        text = pattern.sub(lambda m: m.group(1) + "\n".join(lines) + "\n" + m.group(3), text, count=1)
        print("wrote:", name, f"({len(lines) - 2} rows)")
    with open(DOC, "w") as f:
        f.write(text)

if __name__ == "__main__":
    main()
