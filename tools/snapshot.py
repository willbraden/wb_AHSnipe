"""Write Snapshot.lua: TSM numbers and your max prices for machines without TSM.

On a machine with TSM (your PC), wb_AHSnipe asks TSM directly. On one without
it (the Steam Deck), it reads Snapshot.lua instead:
  sale  TSM's region sale average per item (copper): what buyers actually paid
  sold  TSM's region sold per day per item
  caps  your max prices, copied to that machine once per new snapshot

Run on the PC before pushing:
  python snapshot.py <TradeSkillMaster_AppHelper/AppData.lua> <SavedVariables/wb_AHSnipe.lua> <out Snapshot.lua>
"""
import re, sys, time
import lupa

app_path, sv_path, out_path = sys.argv[1:4]

app = open(app_path, encoding="utf-8", errors="replace").read()
m = re.search(r'LoadData\("AUCTIONDB_REGION_SALE","([^"]+)",\[\[return \{downloadTime=(\d+),fields=\{([^}]*)\},data=\{(.*?)\}\}\]\]', app, re.S)
if not m:
    sys.exit("No AUCTIONDB_REGION_SALE data in AppData.lua (is the TSM desktop app syncing?)")
region, downloaded, fields, data = m.groups()
fields = [f.strip('"') for f in fields.split(",")]
i_sale, i_sold = fields.index("regionSale"), fields.index("regionSoldPerDay")

sale, sold = {}, {}
for row in re.findall(r"\{([^{}]*)\}", data):
    p = row.split(",")
    if not p[0].isdigit() or len(p) < len(fields):
        continue
    try:
        s_ = int(p[i_sale], 32) if p[i_sale] else 0
        d_ = int(p[i_sold], 32) / 1000 if p[i_sold] else 0
    except ValueError:
        continue
    if s_ > 0:
        sale[int(p[0])] = s_
    if d_ > 0:
        sold[int(p[0])] = round(d_, 1)

L = lupa.LuaRuntime()
L.execute(open(sv_path, encoding="utf-8", errors="replace").read())
db = L.globals().wb_AHSnipeDB
caps = {int(k): int(v) for k, v in db.caps.items()} if db and db.caps else {}
default = int(db.default) if db and db.default else None

def table(d):
    return "{" + ",".join(f"[{k}]={v}" for k, v in sorted(d.items())) + "}"

now = int(time.time())
with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("-- Written by tools/snapshot.py: TSM numbers and max prices for machines without TSM.\n")
    fh.write(f"-- Region {region}, TSM data from {time.strftime('%Y-%m-%d %H:%M', time.localtime(int(downloaded)))}.\n")
    fh.write(f"wb_AHSnipe_Snapshot = {{ at = {now}, tsmAt = {downloaded}, region = \"{region}\",\n")
    fh.write(f"  default = {default if default else 'nil'},\n")
    fh.write(f"  caps = {table(caps)},\n")
    fh.write(f"  sale = {table(sale)},\n")
    fh.write(f"  sold = {table(sold)},\n}}\n")
print(f"Snapshot.lua: {len(sale)} sale averages, {len(sold)} sold/day, {len(caps)} max prices ({region})")
