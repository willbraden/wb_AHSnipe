"""Export the wb_AHSnipe log to CSV files.

purchases.csv  one row per buy attempt (bought, failed, rejected, no answer)
bait.csv       every bait listing seen (fewer units than Min qty, well under
               the next real price), rebuilt each run from the addon's saved list
prices.csv     results of each Check prices run
deals.csv      favorites dips at or under your max, how long they lasted,
               and whether you bought during the dip

Run it after a /reload. New rows are added; rows already in the CSVs are skipped.
Usage: python export.py <path to WTF/Account/<ACCOUNT>/SavedVariables/wb_AHSnipe.lua>
"""
import csv, os, re, sys, datetime
import lupa
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Denver")

HERE = os.path.dirname(os.path.abspath(__file__))
SV = sys.argv[1]

L = lupa.LuaRuntime()
L.execute(open(SV, encoding="utf-8", errors="replace").read())
g = L.globals()
log, db = g.wb_AHSnipeLog, g.wb_AHSnipeDB

def tbl(t):
    return dict(t.items()) if t else {}

rows = [tbl(log.rows[i]) for i in range(1, len(log.rows) + 1)] if log and log.rows else []
names = tbl(log.names) if log else {}
caps = tbl(db.caps) if db else {}
default_cap = db.default if db else None
favs = [tbl(log.favs[i]) for i in range(1, len(log.favs) + 1)] if log and log.favs else []

# Real time for each row. Newer rows carry ts; older ones are estimated from
# the file's save time and the game clock.
mtime = os.path.getmtime(SV)
t_last = float(rows[-1]["t"]) if rows else 0
def real(r):
    if r.get("ts"):
        return float(r["ts"])
    return mtime - (t_last - float(r["t"]))

def name(i):
    return names.get(i) or f"item {i}"

def cap(i):
    return caps.get(i, default_cap)

def gsc(c):
    if c is None or c == "":
        return ""
    c = int(round(c)); g_, s, cc = c // 10000, (c // 100) % 100, c % 100
    out = []
    if g_: out.append(f"{g_}g")
    if s or g_: out.append(f"{s}s")
    out.append(f"{cc}c")
    return " ".join(out)

def stamp(ts):
    d = datetime.datetime.fromtimestamp(ts, TZ)
    return d.strftime("%Y-%m-%d"), d.strftime("%H:%M:%S")

# ---------------------------------------------------------------- purchases
P_COLS = ["date", "time", "item", "item_id", "result", "qty", "unit_price", "total",
          "unit_copper", "total_copper", "your_max", "pct_of_max", "cheap_available",
          "buy_pct", "quote_ms", "press_ms", "result_ms", "key"]

purchases = []
quote = confirm = bid = None

def add(result, r, qty, unit, total, extra=None):
    ts = real(r)
    d, t = stamp(ts)
    item = (confirm or quote or bid or {}).get("item")
    mx = cap(item)
    row = {
        "date": d, "time": t, "item": name(item), "item_id": item, "result": result,
        "qty": qty, "unit_price": gsc(unit), "total": gsc(total),
        "unit_copper": unit, "total_copper": total,
        "your_max": gsc(mx), "pct_of_max": round(100 * unit / mx) if unit and mx else "",
        "cheap_available": (quote or {}).get("avail", ""),
        "buy_pct": (quote or {}).get("pct", ""),
        "quote_ms": (quote or {}).get("_qms", ""),
        "press_ms": (confirm or {}).get("priceAge", ""),
        "result_ms": r.get("latency", ""),
        "key": f"{int(ts)}-{item}-{qty}-{r['t']}",
        "_ts": ts,
    }
    if extra: row.update(extra)
    purchases.append(row)

for r in rows:
    e = r["e"]
    if e == "quote_start":
        quote, confirm = dict(r), None
    elif e == "COMMODITY_PRICE_UPDATED" and quote:
        quote["_unit"], quote["_total"], quote["_qms"] = r.get("unit"), r.get("total"), r.get("latency")
    elif e == "quote_rejected" and quote:
        add("rejected", r, r.get("qty"), quote.get("_unit"), r.get("total"))
        quote = None
    elif e == "confirm_sent":
        confirm, bid = dict(r), None
    elif e in ("COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED") and confirm:
        qty, total = confirm.get("qty"), confirm.get("total")
        unit = round(total / qty) if qty and total else None
        add("bought" if e.endswith("SUCCEEDED") else "failed", r, qty, unit, total)
        confirm = quote = None
    elif e == "purchase_timeout" and confirm:
        add("no answer", r, confirm.get("qty"), None, confirm.get("total"))
        confirm = quote = None
    elif e == "bid_sent":
        bid, confirm, quote = dict(r), None, None
    elif e == "AH_PURCHASE_COMPLETED" and bid:
        add("bought", r, 1, bid.get("price"), bid.get("price"))
        bid = None
    elif e == "ui_error" and bid:
        add("failed", r, 1, bid.get("price"), bid.get("price"))
        bid = None

# --------------------------------------------------------------------- deals
D_COLS = ["date", "start", "end", "seconds", "item", "item_id", "price", "your_max",
          "pct_under_max", "bought_during_dip", "key"]

bought_times = {}
for p in purchases:
    if p["result"] == "bought":
        bought_times.setdefault(p["item_id"], []).append(p["_ts"])

deals = []
open_dips = {}
for f in favs:
    at = f.get("at")
    seen = {}
    for sid, sprice, _ in re.findall(r"(\d+):(\d+):(\d+)", f.get("d", "")):
        i, p = int(sid), int(sprice)
        if i not in seen or p < seen[i]:
            seen[i] = p
    for i, p in seen.items():
        mx = cap(i)
        under = mx is not None and p <= mx
        if under and i not in open_dips:
            open_dips[i] = (at, p)
        elif under and p < open_dips[i][1]:
            open_dips[i] = (open_dips[i][0], p)
        elif not under and i in open_dips:
            start, low = open_dips.pop(i)
            d, ts = stamp(start)
            _, te = stamp(at)
            got = any(start - 2 <= b <= at + 2 for b in bought_times.get(i, []))
            deals.append({
                "date": d, "start": ts, "end": te, "seconds": at - start,
                "item": name(i), "item_id": i, "price": gsc(low), "your_max": gsc(mx),
                "pct_under_max": round(100 * (mx - low) / mx) if mx else "",
                "bought_during_dip": "yes" if got else "no",
                "key": f"{start}-{i}",
            })

# --------------------------------------------------------------------- write
def append(fname, cols, new):
    path = os.path.join(HERE, fname)
    have = set()
    if os.path.exists(path) and os.path.getsize(path) > 0:
        with open(path, newline="", encoding="utf-8") as fh:
            have = {r["key"] for r in csv.DictReader(fh)}
    add_rows = [r for r in new if r["key"] not in have]
    write_header = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        if write_header:
            w.writeheader()
        w.writerows(add_rows)
    return len(add_rows)

# ---------------------------------------------------------------------- bait
B_COLS = ["item", "item_id", "bait_price", "units", "next_real_price", "bait_pct_of_real",
          "your_max_last_seen", "at_or_under_max", "times_seen", "first_seen", "last_seen", "days_seen"]
bait_rows = []
bt = {k: tbl(v) for k, v in (tbl(log.bait) if log and log.bait else {}).items()}
# Also pick up bait from list snapshots still in the log (covers sessions
# from before the addon kept its own bait list).
min_qty = (db.minQty if db and db.minQty else 2)
for r in rows:
    if r["e"] != "COMMODITY_SEARCH_RESULTS_UPDATED" or not r.get("top"):
        continue
    tiers = []
    for tok in r["top"].split():
        mine = "(mine)" in tok
        pq = tok.replace("(mine)", "").split("x")
        tiers.append((int(pq[0]), int(pq[1]), mine))
    if len(tiers) < 2:
        continue
    (p1, q1, m1), (p2, _, _) = tiers[0], tiers[1]
    if m1 or q1 >= min_qty or p1 >= 0.85 * p2:
        continue
    i, ts = r.get("item"), int(real(r))
    k = f"{i}:{p1}"
    b = bt.setdefault(k, {"item": i, "price": p1, "qty": q1, "first": ts, "seen": 0, "days": {}, "_logonly": True})
    if b.get("_logonly"):
        b["seen"] += 1
        b["first"] = min(b["first"], ts)
        b["last"] = max(b.get("last") or ts, ts)
        b["next"] = p2
        b["cap"] = r.get("cap")
        b["days"][stamp(ts)[0]] = True
for k, b in bt.items():
    i, p, nxt, mx = b.get("item"), b.get("price"), b.get("next"), b.get("cap")
    f_d, f_t = stamp(b["first"]); l_d, l_t = stamp(b.get("last") or b["first"])
    bait_rows.append({
        "item": name(i), "item_id": i, "bait_price": gsc(p), "units": b.get("qty"),
        "next_real_price": gsc(nxt), "bait_pct_of_real": round(100 * p / nxt) if nxt else "",
        "your_max_last_seen": gsc(mx), "at_or_under_max": "yes" if mx and p <= mx else "no",
        "times_seen": b.get("seen"), "first_seen": f"{f_d} {f_t}", "last_seen": f"{l_d} {l_t}",
        "days_seen": len(b["days"] if isinstance(b.get("days"), dict) else tbl(b.get("days"))) if b.get("days") else 1,
    })
bait_rows.sort(key=lambda r: (r["item"], -r["times_seen"]))
with open(os.path.join(HERE, "bait.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=B_COLS)
    w.writeheader(); w.writerows(bait_rows)

# -------------------------------------------------------------------- prices
C_COLS = ["date", "time", "item", "item_id", "market", "cheapest", "listed", "max_before",
          "suggested", "ratio_pct", "market_copper", "suggested_copper", "key"]
checks = []
for r in rows:
    if r["e"] != "price_check":
        continue
    ts = real(r); d, t = stamp(ts); i = r.get("item")
    checks.append({
        "date": d, "time": t, "item": name(i), "item_id": i,
        "market": gsc(r.get("market")), "cheapest": gsc(r.get("cheapest")), "listed": r.get("listed", ""),
        "max_before": gsc(r.get("now")), "suggested": gsc(r.get("suggest")), "ratio_pct": r.get("ratio", ""),
        "market_copper": r.get("market", ""), "suggested_copper": r.get("suggest", ""),
        "key": f"{int(ts)}-{i}",
    })

n1 = append("purchases.csv", P_COLS, purchases)
n2 = append("deals.csv", D_COLS, deals)
print(f"purchases.csv: +{n1} rows ({len(purchases)} in this log)")
print(f"deals.csv: +{n2} rows ({len(deals)} in this log)")
n3 = append("prices.csv", C_COLS, checks)
print(f"prices.csv: +{n3} rows ({len(checks)} in this log)")
print(f"bait.csv: {len(bait_rows)} bait listings (rebuilt)")
