"""Spam the Snipe key 2,000 times against a simulated auction house.

The server: four favorites with listings that change every 0.2s (other
buyers take cheap units, sellers relist), message queue timing, quotes and
purchases that can fail. Checks the addon's rules on every server call.
"""
import os, runpy, sys

core = sys.argv[1]
seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
sys.argv = ["test_ui.py", core]
ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L, g = ns["L"], ns["g"]
L.execute(f"SEED = {seed}")
L.execute(r'''
math.randomseed(SEED)
UNFAV = {}; TSM_API = nil
local ah = AuctionHouseFrame
wb_AHSnipeDB.gapPct = 20; wb_AHSnipeDB.tsmPct = 0; wb_AHSnipeDB.minQty = 2; wb_AHSnipeDB.explore = false; wb_AHSnipeDB.buyPct = 50
wb_AHSnipeDB.roam = true; wb_AHSnipeDB.lastCheckAt = time() + 99999; wb_AHSnipeDB.minSold = 0
MONEY = 10000000

-- Items: cap, normal tier, and what cheap listings look like.
ITEMS = {
  [101] = { cap = 100, tier = 125, cheap = 80, kind = "deal" },     -- real deals, gap ok (100 >= 80, gap max 100)
  [102] = { cap = 100, tier = 105, cheap = 95, kind = "gaptrap" },  -- under max, but next tier too close
  [103] = { cap = 100, tier = 140, cheap = 50, kind = "bait" },     -- single cheap unit
  [104] = { cap = 50,  tier = 100, cheap = nil, kind = "never" },   -- never under max
}
for id, it in pairs(ITEMS) do wb_AHSnipeDB.caps[id] = it.cap end
MARKET = {}
local function Refill(id)
  local it = ITEMS[id]
  local m = { { unitPrice = it.tier, quantity = 500, numOwnerItems = 0 }, { unitPrice = it.tier + 10, quantity = 800, numOwnerItems = 0 } }
  MARKET[id] = m
end
for id in pairs(ITEMS) do Refill(id) end
local function Sort(m) table.sort(m, function(a, b) return a.unitPrice < b.unitPrice end) end
local function ServerTick()
  for id, it in pairs(ITEMS) do
    local m = MARKET[id]
    -- sellers: sometimes post a cheap listing
    if it.cheap and math.random() < 0.04 then
      local q = it.kind == "bait" and 1 or math.random(4, 30)
      table.insert(m, { unitPrice = it.cheap, quantity = q, numOwnerItems = 0 }); Sort(m)
    end
    -- other buyers: often take cheap units
    if m[1].unitPrice < it.tier and math.random() < 0.12 then
      local take = math.random(1, m[1].quantity)
      m[1].quantity = m[1].quantity - take
      if m[1].quantity <= 0 then table.remove(m, 1) end
    end
  end
end

-- Event queue with message timing.
Q = {}
local function At(dt, fn) table.insert(Q, { t = NOW + dt, fn = fn }) end
STATS = { sendWhileQueued = 0, overMax = 0, tookAll = 0, starts = 0, confirms = 0, clicks = 0, errors = 0, ok = 0, fail = 0, unavailable = 0, gapTrapJumps = 0, lastErr = nil }
local inFlight = false -- server has a message queued and not yet sent
local function Message(fn)
  if inFlight then STATS.sendWhileQueued = STATS.sendWhileQueued + 1 end
  inFlight = true
  FIRE("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED")
  At(0.1, function() inFlight = false; FIRE("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT") end)
  At(0.3 + math.random() * 0.3, function() FIRE("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED"); fn(); FIRE("AUCTION_HOUSE_THROTTLED_SYSTEM_READY") end)
end

-- What the client sees: a snapshot of the market at response time.
VIEW = {}
C_AuctionHouse.GetNumCommoditySearchResults = function(id) return VIEW[id] and #VIEW[id] or 0 end
C_AuctionHouse.GetCommoditySearchResultInfo = function(id, i) return VIEW[id] and VIEW[id][i] end
local function Snapshot(id) local t = {}; for i, r in ipairs(MARKET[id]) do t[i] = { unitPrice = r.unitPrice, quantity = r.quantity, numOwnerItems = 0 } end; VIEW[id] = t end
local function BrowseNow()
  local b = {}
  for id in pairs(ITEMS) do b[#b + 1] = { itemKey = { itemID = id }, minPrice = MARKET[id][1].unitPrice } end
  BROWSE = b
end

-- Native buttons.
local list = CreateFrame("Frame")
list.RefreshFrame = { RefreshButton = { Click = function()
  STATS.clicks = STATS.clicks + 1
  local id = OPEN_ID
  Message(function() if OPEN_ID == id then Snapshot(id); FIRE("COMMODITY_SEARCH_RESULTS_UPDATED", id) end end)
end } }
ah.CommoditiesBuyFrame.ItemList = list
local fav = ah.SearchBar.FavoritesSearchButton
fav.Click = function()
  STATS.clicks = STATS.clicks + 1
  if fav._scripts.OnClick then fav._scripts.OnClick() end
  Message(function() BrowseNow(); FIRE("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end)
end
ah.SetDisplayMode = function()
  OPEN_ID = nil; ah.CommoditiesBuyFrame:Hide(); ah.BrowseResultsFrame:Show(); ah.BrowseResultsFrame._scripts.OnShow()
end
ah.SelectBrowseResult = function(_, r)
  local id = r.itemKey.itemID
  if ITEMS[id].kind == "gaptrap" then STATS.gapTrapJumps = STATS.gapTrapJumps + 1 end
  OPEN_ID = id; VIEW[id] = nil
  ah.BrowseResultsFrame:Hide(); ah.CommoditiesBuyFrame:Show(); ah.CommoditiesBuyFrame._scripts.OnShow()
  Message(function() if OPEN_ID == id then Snapshot(id); FIRE("COMMODITY_SEARCH_RESULTS_UPDATED", id) end end)
  return true
end

-- Purchases.
local pendingBuy
C_AuctionHouse.StartCommoditiesPurchase = function(id, qty)
  STATS.starts = STATS.starts + 1
  Message(function()
    local m, got, total = MARKET[id], 0, 0
    for _, r in ipairs(m) do local c = math.min(r.quantity, qty - got); got, total = got + c, total + c * r.unitPrice; if got >= qty then break end end
    if got < qty then STATS.unavailable = STATS.unavailable + 1; FIRE("COMMODITY_PRICE_UNAVAILABLE") return end
    pendingBuy = { id = id, qty = qty, unit = math.ceil(total / qty), total = total }
    FIRE("COMMODITY_PRICE_UPDATED", pendingBuy.unit, total)
  end)
end
C_AuctionHouse.ConfirmCommoditiesPurchase = function(id, qty)
  STATS.confirms = STATS.confirms + 1
  local p = pendingBuy
  if p and p.unit > ITEMS[id].cap then STATS.overMax = STATS.overMax + 1 end
  -- Leave-one rule: how many units were under max when confirming?
  local under = 0
  for _, r in ipairs(MARKET[id]) do if r.unitPrice <= ITEMS[id].cap then under = under + r.quantity end end
  Message(function()
    local m, got, total = MARKET[id], 0, 0
    for _, r in ipairs(m) do if r.unitPrice <= (p and p.unit or 0) then got = got + r.quantity end end
    if p and got >= qty then
      local need = qty
      while need > 0 and m[1] do local c = math.min(m[1].quantity, need); m[1].quantity = m[1].quantity - c; need = need - c; if m[1].quantity <= 0 then table.remove(m, 1) end end
      if #m == 0 then Refill(id) end
      STATS.ok = STATS.ok + 1; FIRE("COMMODITY_PURCHASE_SUCCEEDED")
    else
      STATS.fail = STATS.fail + 1; FIRE("COMMODITY_PURCHASE_FAILED")
    end
    pendingBuy = nil
  end)
end
C_AuctionHouse.CancelCommoditiesPurchase = function() pendingBuy = nil end
local origSay = wb_AHSnipe_PlayTick
PlaySound = function() end

-- Start on favorites.
ah.SetDisplayMode()
fav._scripts.OnClick()
BrowseNow()

local function Pump()
  table.sort(Q, function(a, b) return a.t < b.t end)
  while Q[1] and Q[1].t <= NOW do
    local e = table.remove(Q, 1)
    local ok, err = pcall(e.fn)
    if not ok then STATS.errors = STATS.errors + 1; STATS.lastErr = err end
  end
end

function RUN(n)
  for i = 1, n do
    for k = 1, 4 do NOW = NOW + 0.05; ServerTick(); Pump() end -- a press every 0.2s
    local ok, err = pcall(wb_AHSnipe_Buy)
    if not ok then STATS.errors = STATS.errors + 1; STATS.lastErr = err end
    if i % 5 == 0 then local ok2, err2 = pcall(TICK); if not ok2 then STATS.errors = STATS.errors + 1; STATS.lastErr = err2 end end
  end
end
''')
L.execute("RUN(2000)")
S = {k: v for k, v in g.STATS.items()}
rows = [dict(r.items()) for r in g.wb_AHSnipeLog.rows.values()]
from collections import Counter
ev = Counter(r["e"] for r in rows)
backs = [r for r in rows if r["e"] == "auto_back"]
jumps = Counter(r.get("item") for r in rows if r["e"] == "jump")
steps = Counter()
for r in rows:
    if r["e"] == "press": steps[r.get("step")] += r.get("rep", 1)
print(f"2000 presses ({core.split('/')[-1]}, seed {seed})")
print(f"  buys: {S['ok']} won, {S['fail']} beaten, {ev['quote_rejected']} quotes rejected, {S['unavailable']} sold out before quote")
print(f"  jumps: {sum(jumps.values())} total  deal item {jumps.get(101,0)}  gap-trap item {jumps.get(102,0)}  bait item {jumps.get(103,0)}  never item {jumps.get(104,0)}")
print(f"  back to favorites: {len(backs)} ({sum(1 for b in backs if b.get('empty') == 1)} after empty landings)")
print(f"  press outcomes: {dict(steps.most_common(8))}")
print(f"  RULE CHECKS  sent while queued: {S['sendWhileQueued']}  confirmed over max: {S['overMax']}  errors: {S['errors']}")
if S.get("lastErr"): print("  last error:", S['lastErr'])
qs = [r for r in rows if r["e"] == "quote_start"]
print(f"  leave-one check: {sum(1 for r in qs if r.get('qty',0) >= r.get('avail',0))} quotes took every cheap unit (of {len(qs)})")
