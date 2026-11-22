"""Export the wb_AHSnipe log to CSV files.

purchases.csv  one row per buy attempt (bought, failed, rejected, no answer)
bait.csv       every bait listing seen (fewer units than Min qty, well under
               the next real price), rebuilt each run from the addon's saved list
prices.csv     results of each Check prices run
winrates.csv   win rate by item, Buy %, hour, weekday and cheap units listed,
               rebuilt from all of purchases.csv each run
deals.csv      favorites dips at or under your max, how long they lasted,
               and whether you bought during the dip
profit.csv     every AH sale (from TSM's records) matched to what you paid,
               oldest units first, with profit after the AH cut and days held
profit_items.csv  profit, margin, days to sell and units on hand per item
profit_daily.csv  realized profit per day
market.csv     each item's market price over time (at most one sample per item
               per 10 minutes), with the hour of day, for charting by hour

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

# -------------------------------------------------------------------- market
M_COLS = ["date", "time", "hour", "weekday", "item", "item_id", "market", "cheapest", "listed",
          "market_copper", "cheapest_copper", "key"]
markets = []
for r in rows:
    if r["e"] != "market":
        continue
    ts = real(r); d, t = stamp(ts); i = r.get("item")
    dt = datetime.datetime.fromtimestamp(ts, TZ)
    markets.append({
        "date": d, "time": t, "hour": dt.hour, "weekday": dt.strftime("%a"), "item": name(i), "item_id": i,
        "market": gsc(r.get("market")), "cheapest": gsc(r.get("cheapest")), "listed": r.get("listed", ""),
        "market_copper": r.get("market", ""), "cheapest_copper": r.get("cheapest", ""),
        "key": f"{int(ts)}-{i}",
    })

n1 = append("purchases.csv", P_COLS, purchases)
n2 = append("deals.csv", D_COLS, deals)
print(f"purchases.csv: +{n1} rows ({len(purchases)} in this log)")
print(f"deals.csv: +{n2} rows ({len(deals)} in this log)")
n3 = append("prices.csv", C_COLS, checks)
print(f"prices.csv: +{n3} rows ({len(checks)} in this log)")
print(f"bait.csv: {len(bait_rows)} bait listings (rebuilt)")
n4 = append("market.csv", M_COLS, markets)
print(f"market.csv: +{n4} rows ({len(markets)} in this log)")


# ------------------------------------------------------------------ winrates
# Built from the full purchases.csv history, not just this log.
W_COLS = ["dimension", "item", "bucket", "tries", "won", "win_pct", "units_won", "units_per_try"]
path = os.path.join(HERE, "purchases.csv")
hist = list(csv.DictReader(open(path, newline="", encoding="utf-8"))) if os.path.exists(path) else []
groups = {}
def add(dim, item, bucket, r):
    g = groups.setdefault((dim, item, bucket), {"tries": 0, "won": 0, "units": 0})
    g["tries"] += 1
    if r["result"] == "bought":
        g["won"] += 1
        g["units"] += int(r["qty"] or 0)
def avail_bucket(v):
    try: v = int(v)
    except (TypeError, ValueError): return "unknown"
    return "1-5" if v <= 5 else "6-20" if v <= 20 else "21-50" if v <= 50 else "51+"
for r in hist:
    if r.get("result") not in ("bought", "failed", "rejected", "no answer"):
        continue
    hour = r["time"][:2]
    wd = datetime.datetime.strptime(r["date"], "%Y-%m-%d").strftime("%a")
    add("item", r["item"], "all", r)
    add("item_buy_pct", r["item"], r.get("buy_pct") or "?", r)
    add("item_hour", r["item"], hour, r)
    add("item_cheap_listed", r["item"], avail_bucket(r.get("cheap_available")), r)
    add("hour", "all", hour, r)
    add("weekday", "all", wd, r)
    add("buy_pct", "all", r.get("buy_pct") or "?", r)
    add("cheap_listed", "all", avail_bucket(r.get("cheap_available")), r)
wrows = []
for (dim, item, bucket), g in sorted(groups.items()):
    wrows.append({"dimension": dim, "item": item, "bucket": bucket, "tries": g["tries"], "won": g["won"],
                  "win_pct": round(100 * g["won"] / g["tries"]), "units_won": g["units"],
                  "units_per_try": round(g["units"] / g["tries"], 1)})
with open(os.path.join(HERE, "winrates.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=W_COLS); w.writeheader(); w.writerows(wrows)
print(f"winrates.csv: {len(wrows)} rows from {len(hist)} purchase attempts (rebuilt)")


# -------------------------------------------------------------------- profit
# Realized profit from TSM's own sales and buys records (TSM Accounting,
# which reads your AH mail). Each sale is matched to what you paid using
# first-in, first-out: the oldest units you bought are the first ones sold.
# TSM stores sale prices after the AH's cut (sale minus cut, per unit).
TSM_SV = os.path.join(os.path.dirname(os.path.abspath(SV)), "TradeSkillMaster.lua")

def tsm_rows(db, suffix):
    out = []
    for k in db.keys():
        if not (isinstance(k, str) and k.startswith("r@") and k.endswith("@internalData@" + suffix)):
            continue
        lines = (db[k] or "").split("\n")
        if not lines:
            continue
        head = lines[0].split(",")
        for line in lines[1:]:
            if not line:
                continue
            parts = line.split(",")
            if len(parts) != len(head):
                continue
            r = dict(zip(head, parts))
            m = re.match(r"i:(\d+)", r.get("itemString", ""))
            if not m:
                continue
            r["id"] = int(m.group(1))
            r["qty"] = int(r.get("quantity") or 0)
            r["ts"] = int(r.get("time") or 0)
            if "price" in r:
                r["price"] = int(r["price"] or 0)
            out.append(r)
    return out

if os.path.exists(TSM_SV):
    T = lupa.LuaRuntime()
    T.execute(open(TSM_SV, encoding="utf-8", errors="replace").read())
    tdb = T.globals().TradeSkillMasterDB
    t_sales = [r for r in tsm_rows(tdb, "csvSales") if r.get("source") == "Auction"]
    t_buys = [r for r in tsm_rows(tdb, "csvBuys") if r.get("source") == "Auction"]
    t_expired = tsm_rows(tdb, "csvExpired")

    # Which buys were snipes: same item and qty in purchases.csv within 2 minutes.
    snipes = {}
    for p in hist:
        if p.get("result") != "bought":
            continue
        try:
            ts = datetime.datetime.strptime(p["date"] + " " + p["time"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=TZ).timestamp()
            snipes.setdefault((int(p["item_id"]), int(p["qty"])), []).append(ts)
        except (KeyError, ValueError):
            pass
    def is_snipe(b):
        return any(abs(t - b["ts"]) <= 120 for t in snipes.get((b["id"], b["qty"]), []))

    lots = {}
    for b in sorted(t_buys, key=lambda r: r["ts"]):
        lots.setdefault(b["id"], []).append({"qty": b["qty"], "left": b["qty"], "unit": b["price"], "ts": b["ts"], "snipe": is_snipe(b)})

    sale_rows, item_sum, day_sum = [], {}, {}
    for s_ in sorted(t_sales, key=lambda r: r["ts"]):
        i, q, ts = s_["id"], s_["qty"], s_["ts"]
        net_each = s_["price"]
        cost, matched, snipe_q, held = 0, 0, 0, 0.0
        for lot in lots.get(i, []):
            if matched >= q:
                break
            if lot["left"] <= 0 or lot["ts"] > ts:
                continue
            take = min(lot["left"], q - matched)
            lot["left"] -= take
            matched += take
            cost += take * lot["unit"]
            held += take * (ts - lot["ts"]) / 86400
            if lot["snipe"]:
                snipe_q += take
        d, t = stamp(ts)
        profit = net_each * matched - cost if matched else None
        sale_rows.append({
            "date": d, "time": t, "item": name(i), "item_id": i, "qty": q,
            "sell_each": gsc(s_["price"]), "net_each": gsc(net_each),
            "cost_each": gsc(cost / matched) if matched else "",
            "profit": gsc(profit) if profit is not None and profit >= 0 else ("-" + gsc(-profit) if profit is not None else ""),
            "profit_copper": round(profit) if profit is not None else "",
            "profit_pct": round(100 * (net_each * matched - cost) / cost) if matched and cost else "",
            "days_held": round(held / matched, 1) if matched else "",
            "matched_qty": matched, "snipe_qty": snipe_q, "buyer": s_.get("otherPlayer", ""),
        })
        it = item_sum.setdefault(i, {"sold": 0, "rev": 0.0, "cost": 0, "matched": 0, "profit": 0.0, "held": 0.0, "last": ""})
        it["sold"] += q; it["rev"] += net_each * q; it["matched"] += matched; it["cost"] += cost
        it["held"] += held; it["last"] = f"{d} {t}"
        if matched:
            it["profit"] += net_each * matched - cost
            dd = day_sum.setdefault(d, {"rev": 0.0, "cost": 0, "profit": 0.0, "units": 0})
            dd["rev"] += net_each * matched; dd["cost"] += cost; dd["profit"] += net_each * matched - cost; dd["units"] += matched

    expired = {}
    for e in t_expired:
        expired[e["id"]] = expired.get(e["id"], 0) + e["qty"]

    PS_COLS = ["date", "time", "item", "item_id", "qty", "sell_each", "net_each", "cost_each", "profit",
               "profit_copper", "profit_pct", "days_held", "matched_qty", "snipe_qty", "buyer"]
    with open(os.path.join(HERE, "profit.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=PS_COLS); w.writeheader(); w.writerows(sale_rows)

    PI_COLS = ["item", "item_id", "bought_units", "spent", "sold_units", "revenue_net", "cost_of_sold", "profit",
               "profit_copper", "margin_pct", "avg_days_to_sell", "on_hand_units", "on_hand_cost",
               "snipe_units_bought", "expired_units", "last_sale"]
    irows = []
    for i in set(lots) | set(item_sum):
        bl = lots.get(i, [])
        it = item_sum.get(i, {"sold": 0, "rev": 0, "cost": 0, "matched": 0, "profit": 0, "held": 0, "last": ""})
        on_hand = sum(l["left"] for l in bl)
        irows.append({
            "item": name(i), "item_id": i,
            "bought_units": sum(l["qty"] for l in bl), "spent": gsc(sum(l["qty"] * l["unit"] for l in bl)),
            "sold_units": it["sold"], "revenue_net": gsc(it["rev"]), "cost_of_sold": gsc(it["cost"]),
            "profit": (gsc(it["profit"]) if it["profit"] >= 0 else "-" + gsc(-it["profit"])) if it["matched"] else "",
            "profit_copper": round(it["profit"]) if it["matched"] else "",
            "margin_pct": round(100 * it["profit"] / it["cost"]) if it["cost"] else "",
            "avg_days_to_sell": round(it["held"] / it["matched"], 1) if it["matched"] else "",
            "on_hand_units": on_hand, "on_hand_cost": gsc(sum(l["left"] * l["unit"] for l in bl)),
            "snipe_units_bought": sum(l["qty"] for l in bl if l["snipe"]),
            "expired_units": expired.get(i, 0), "last_sale": it["last"],
        })
    irows.sort(key=lambda r: -(r["profit_copper"] or 0))
    with open(os.path.join(HERE, "profit_items.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=PI_COLS); w.writeheader(); w.writerows(irows)

    PD_COLS = ["date", "units_sold", "revenue_net", "cost", "profit", "profit_copper"]
    drows = [{"date": d, "units_sold": v["units"], "revenue_net": gsc(v["rev"]), "cost": gsc(v["cost"]),
              "profit": gsc(v["profit"]) if v["profit"] >= 0 else "-" + gsc(-v["profit"]),
              "profit_copper": round(v["profit"])} for d, v in sorted(day_sum.items())]
    with open(os.path.join(HERE, "profit_daily.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=PD_COLS); w.writeheader(); w.writerows(drows)

    total = sum(v["profit"] for v in day_sum.values())
    print(f"profit.csv: {len(sale_rows)} AH sales from TSM, profit_items.csv: {len(irows)} items, "
          f"profit_daily.csv: {len(drows)} days (rebuilt). Realized profit: {gsc(total) if total >= 0 else '-' + gsc(-total)}")
else:
    print("profit: TSM's saved data not found next to wb_AHSnipe.lua, skipped")
