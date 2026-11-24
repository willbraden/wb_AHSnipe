-- wb_AHSnipe: refresh + buy keybinds for the stock auction house.
-- Refresh never sends a new search while the last one is unanswered,
-- which is what wedges the AH until a relog.

BINDING_HEADER_WBAHSNIPE = "wb_AH Snipe"
BINDING_NAME_WBAHSNIPE_REFRESH = "Refresh AH"
BINDING_NAME_WBAHSNIPE_FAVS = "Refresh favorites"
BINDING_NAME_WBAHSNIPE_CHECK = "Check prices (one favorite per press)"
BINDING_NAME_WBAHSNIPE_ROAM = "Toggle Stay on the open item"
BINDING_NAME_WBAHSNIPE_BUY = "Snipe (one button: refresh, quote, buy)"

local MIN_GAP = 0.6      -- seconds between searches
local STALE_GUARD = 8    -- forget our own pending flag after this long
local WARN_AFTER = 5     -- warn if the AH hasn't answered in this long
local QUOTE_TTL = 10     -- seconds a commodity price quote is trusted
local MIN_QTY = 2        -- commodities: skip unless at least this many are under your max
local BUY_PCT = 50       -- commodities: ask for this % of the cheap units, leaving room if others buy some
local AH_CUT_PCT = 5     -- the auction house keeps 5% of each sale
local MAX_PCT = 95       -- never ask for all of them: the last unit is bait you want left on the list

local pending, sentAt, warned = false, 0, false
local quote -- { itemID, qty, maxTotal, at, total }
local staleID -- commodity whose on-screen list is known to be out of date
local resultsAt = {} -- itemID -> when its commodity list last arrived
local queuedAt -- when an AH message started waiting its turn; sending another would drop it
local function Queued() return queuedAt and GetTime() - queuedAt < 3 end
local buying          -- { at, item, qty } while a confirmed purchase is in flight
local BUY_TIMEOUT = 4 -- seconds to wait for a purchase result before giving up
local bidding -- { item, price, at } after a single-item buy
local jumped, jumpAt, jumpPrice -- item the Snipe key opened from favorites
local itemResultsAt = 0 -- when the single-item list last arrived
local OVER_MAX_BACK = 10 -- presses in a row with nothing under max before going back to favorites
local EMPTY_JUMP_BACK = 3 -- ...or this many after a jump that found nothing under max, not even bait
local overCount = 0
local sawUnder = false   -- this item page has shown units under max (a deal or bait) since you landed
local BAIT_GIVEUP = 400  -- presses parked on bait with no real deal before buying the bait to move on
local baitPresses = 0
local lastBrowse = "text" -- "fav" when the browse list is showing your favorites
local FAV_ALERT = 0.25 -- favorites: flag price moves of at least 25% between refreshes
local favChanges = {}  -- itemID -> fraction change at the last price move
local itemStale = false -- single-item list needs a refresh (after a bid)
local lastSaid = {}     -- itemID -> list time we last printed "over your max" for
local function SayOnce(id, stamp, text)
  if lastSaid[id] ~= stamp then lastSaid[id] = stamp; wb_AHSnipe_Msg(text) end
end
local DB
local settings -- the AH Snipe window (built when the AH opens)

local OUT -- chat window the addon writes to (its own "AH Snipe" tab when set up)
local function msg(t)
  if OUT and OUT ~= DEFAULT_CHAT_FRAME then
    OUT:AddMessage(t)
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AHSnipe|r " .. t)
  end
end
wb_AHSnipe_Msg = msg
local function money(c) return GetMoneyString(c, true) end
local function ItemText(id)
  if not id then return "item" end
  local link = C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(id))
  return link or C_Item.GetItemNameByID(id) or ("item " .. id)
end
-- Table-style chat lines ---------------------------------------------------
-- Chat uses a proportional font, so spaces can't line columns up. Each cell is
-- measured in the chat font and padded with an invisible texture of the exact
-- missing width.
local SPACER = "Interface\\AddOns\\wb_AHSnipe\\spacer"
local COLS = {          -- w = pixels (any font), ch = characters (mono font)
  { w = 62, ch = 7 },                -- what happened
  { w = 34, ch = 4, right = true },  -- quantity
  { w = 170, ch = 20, trunc = true },-- item (long names are shortened)
  { w = 110, ch = 7, right = true }, -- price (999g 99s 99c = 7 digits)
  { w = 150, ch = 18 },               -- details ("(was …)", "(… each)", why it failed)
  { w = 120, ch = 15 },               -- your max
  { w = 0 },                         -- win rate for this item (last column)
}

-- Mono mode: count visible characters and pad with spaces. Exact, because
-- every character in a monospace font is the same width.
local function MonoOn() return DB and DB.monoChat ~= false end
local function Visible(t)
  t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""):gsub("|T.-|t", "  ")
  local n = 0
  for _ in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
  return n
end
local function TruncateChars(text, max)
  if Visible(text) <= max then return text end
  local pre, name, post = text:match("^(.-%[)(.-)(%].*)$")
  if not name then pre, name, post = "", text, "" end
  local chars = {}
  for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  for n = #chars - 1, 1, -1 do
    local t = pre .. table.concat(chars, "", 1, n) .. "…" .. post
    if Visible(t) <= max then return t end
  end
  return pre .. (chars[1] or "") .. "…" .. post
end
local measure
local function Width(text)
  -- Measure inside the chat window itself so its scale matches exactly.
  local target = OUT or DEFAULT_CHAT_FRAME
  if not measure or measure:GetParent() ~= target then
    measure = target:CreateFontString(nil, "OVERLAY")
    measure:Hide()
  end
  local f, size, flags = target:GetFont()
  measure:SetFont(f, size, flags)
  local plain, icons = text:gsub("|T.-|t", "")
  measure:SetText(plain)
  return measure:GetStringWidth() + icons * (size or 14)
end
local function Pad(px)
  px = math.floor(px + 0.5)
  if px <= 0 then return "" end
  return "|T" .. SPACER .. ":1:" .. px .. "|t"
end
-- Shorten "[Long Item Name]" (link or plain) until it fits the width.
local function Truncate(text, w)
  if Width(text) <= w then return text end
  local pre, name, post = text:match("^(.-%[)(.-)(%].*)$")
  if not name then pre, name, post = "", text, "" end
  local chars = {}
  for ch in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
  for n = #chars - 1, 1, -1 do
    local t = pre .. table.concat(chars, "", 1, n) .. "…" .. post
    if Width(t) <= w then return t end
  end
  return pre .. (chars[1] or "") .. "…" .. post
end

local function Row(cells)
  local out = {}
  if MonoOn() then
    for i, col in ipairs(COLS) do
      local text = tostring(cells[i] or "")
      if col.ch then
        if col.trunc then text = TruncateChars(text, col.ch) end
        local gap = string.rep(" ", math.max(0, col.ch - Visible(text)))
        local sep = (i >= 4) and "  " or " "
        out[#out + 1] = col.right and (gap .. text .. sep) or (text .. gap .. sep)
      else
        out[#out + 1] = text
      end
    end
    msg(table.concat(out))
    return
  end
  for i, col in ipairs(COLS) do
    local text = tostring(cells[i] or "")
    if col.trunc then text = Truncate(text, col.w) end
    if col.w > 0 then
      local gap = col.w - Width(text)
      if col.right then out[#out + 1] = Pad(gap) .. text .. Pad(i == 4 and 24 or 10)
      else out[#out + 1] = text .. Pad(gap + 10) end
    else
      out[#out + 1] = text
    end
  end
  msg(table.concat(out))
end

local function Coins(c)
  if not c then return "" end
  c = math.floor(c + 0.5)
  local g, sv, cv = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  -- Packed digits colored by coin: 4g 17s 29c reads as 41729.
  local G, S, C = "|cffffd100", "|cffc7c7cf", "|cffeda55f"
  if g > 0 then return ("%s%d|r%s%02d|r%s%02d|r"):format(G, g, S, sv, C, cv) end
  if sv > 0 then return ("%s%d|r%s%02d|r"):format(S, sv, C, cv) end
  return ("%s%d|r"):format(C, cv)
end

-- Grey out a cell (link colors, coin letters and all) so it reads as
-- background. Links stay clickable.
local GREY = "|cff7f7f7f"
local function Dim(t)
  if not t or t == "" then return t end
  t = t:gsub("|c%x%x%x%x%x%x%x%x", GREY):gsub("|cn[^:]*:", GREY):gsub("|r", "|r" .. GREY)
  return GREY .. t .. "|r"
end

-- "max 1s 50c" for the last column (or "no max").
local function MaxCell(id, dim)
  local cap = id and wb_AHSnipe_CapOf and wb_AHSnipe_CapOf(id)
  local t = cap and ("|cffaaaaaamax|r " .. Coins(cap)) or "|cffaaaaaano max|r"
  return dim and Dim(t) or t
end

-- Win/loss per item: this session, and all-time in DB.stats.
local session = {}

-- Learning the best Buy % per item -----------------------------------------
-- Explore mode tries these, least-tested first, for each item.
local PCTS = { 35, 50, 66, 85 }
local attemptPct = {} -- itemID -> Buy % used for the attempt in progress
local nextPct = {}    -- itemID -> Buy % Explore will try next (kept until that try finishes)

-- How many tries an item has at one Buy %.
local function Tries(id, p)
  local r = DB.tune and DB.tune[id] and DB.tune[id][p]
  return r and (r.won + r.lost) or 0
end

-- An item's proven Buy %: the most units won per try, among the ones with
-- at least MIN_TRIES tries. nil until one has enough.
local MIN_TRIES = 4
local function BestPct(id)
  local t = id and DB.tune and DB.tune[id]
  if not t then return end
  local best, bestEV
  for _, p in ipairs(PCTS) do
    local r = t[p]
    local n = r and (r.won + r.lost) or 0
    if n >= MIN_TRIES and (not bestEV or r.units / n > bestEV) then best, bestEV = p, r.units / n end
  end
  return best, bestEV
end

-- The Buy % an item uses with Explore off, and why: its proven best, else
-- the one you set for it, else your general Buy %.
local function SavedPct(id)
  local best = BestPct(id)
  if best then return math.min(MAX_PCT, best), "best" end
  local own = DB.itemPct and DB.itemPct[id]
  if own then return math.min(MAX_PCT, own), "item" end
  return math.min(MAX_PCT, DB.buyPct or BUY_PCT), "general"
end

-- Explore: give every Buy % MIN_TRIES tries first (least tried first). Once
-- they all have them, use the best and only test another one try in
-- EXPLORE_EVERY, so it settles instead of rotating forever.
local EXPLORE_EVERY = 5
local function PickPct(id)
  if not (DB.explore and id) then return (SavedPct(id)) end
  if nextPct[id] then return nextPct[id] end
  local t = DB.tune and DB.tune[id] or {}
  local function n(p) local r = t[p] return r and (r.won + r.lost) or 0 end
  local pick, pickN, total = nil, nil, 0
  for _, p in ipairs(PCTS) do
    total = total + n(p)
    if n(p) < MIN_TRIES and (not pick or n(p) < pickN or (n(p) == pickN and math.random() < 0.5)) then pick, pickN = p, n(p) end
  end
  if not pick then
    local best = BestPct(id)
    pick = best
    if total % EXPLORE_EVERY == 0 then
      for _, p in ipairs(PCTS) do
        if p ~= best and (pick == best or n(p) < n(pick)) then pick = p end
      end
    end
  end
  nextPct[id] = pick
  return pick
end

-- Record one attempt against Buy % and hour of day.
local function TallyTune(id, won, qty)
  local p = attemptPct[id]
  nextPct[id] = nil -- this try is done; Explore picks again next time
  DB.hourly = DB.hourly or {}
  local h = tonumber(date("%H"))
  local hr = DB.hourly[h] or { won = 0, lost = 0 }
  DB.hourly[h] = hr
  if won then hr.won = hr.won + 1 else hr.lost = hr.lost + 1 end
  if not p then return end
  DB.tune = DB.tune or {}
  DB.tune[id] = DB.tune[id] or {}
  local r = DB.tune[id][p] or { won = 0, lost = 0, units = 0 }
  DB.tune[id][p] = r
  if won then r.won = r.won + 1; r.units = r.units + (qty or 0) else r.lost = r.lost + 1 end
end

local function Tally(id, won, qty, total)
  if not id or not DB then return end
  TallyTune(id, won, qty)
  if won and qty and qty > 0 and total and wb_AHSnipe_LedgerBuy then wb_AHSnipe_LedgerBuy(id, qty, total) end
  DB.stats = DB.stats or {}
  for _, t in ipairs({ session, DB.stats }) do
    local r = t[id] or { won = 0, lost = 0, units = 0, spent = 0 }
    t[id] = r
    if won then
      r.won = r.won + 1
      r.units = r.units + (qty or 0)
      r.spent = r.spent + (total or 0)
    else
      r.lost = r.lost + 1
    end
  end
  if wb_AHSnipe_TuneRefresh then wb_AHSnipe_TuneRefresh() end
end

-- /snipe stats: one line per item, best win rate first.
function wb_AHSnipe_Stats(all)
  local src = all and (DB.stats or {}) or session
  local list = {}
  for id, r in pairs(src) do list[#list + 1] = { id = id, r = r } end
  if #list == 0 then msg(all and "No buys tracked yet." or "No buys this session yet. /snipe stats all for all-time.") return end
  table.sort(list, function(a, b)
    local ra = a.r.won / math.max(1, a.r.won + a.r.lost)
    local rb = b.r.won / math.max(1, b.r.won + b.r.lost)
    if ra ~= rb then return ra > rb end
    return a.r.units > b.r.units
  end)
  local function cell(t, n, right)
    t = tostring(t or "")
    local gap = string.rep(" ", math.max(0, n - Visible(t)))
    return right and (gap .. t) or (t .. gap)
  end
  msg("|cffffd100" .. (all and "All-time" or "This session") .. "|r")
  msg(cell("|cffaaaaaaItem|r", 22) .. " " .. cell("|cffaaaaaaWin|r", 5, true) .. "  " .. cell("|cffaaaaaaWon|r", 4, true)
    .. " " .. cell("|cffaaaaaaLost|r", 4, true) .. "  " .. cell("|cffaaaaaaUnits|r", 6, true)
    .. "  " .. cell("|cffaaaaaaAvg each|r", 12, true) .. "  " .. cell("|cffaaaaaaYour max|r", 12, true))
  local W, Ls, U, S = 0, 0, 0, 0
  for _, e in ipairs(list) do
    local r, n = e.r, e.r.won + e.r.lost
    local pct = math.floor(100 * r.won / math.max(1, n) + 0.5)
    local color = pct >= 60 and "|cff55ff55" or pct >= 30 and "|cffffd100" or "|cffff5555"
    local avg = r.units > 0 and Coins(r.spent / r.units) or ""
    local cap = wb_AHSnipe_CapOf and wb_AHSnipe_CapOf(e.id)
    msg(cell(TruncateChars(ItemText(e.id), 22), 22) .. " " .. cell(color .. pct .. "%|r", 5, true)
      .. "  " .. cell("|cffffd100" .. r.won .. "|r", 4, true) .. " " .. cell("|cffff5555" .. r.lost .. "|r", 4, true)
      .. "  " .. cell(r.units, 6, true) .. "  " .. cell(avg, 12, true) .. "  " .. cell(cap and Coins(cap) or "", 12, true))
    W, Ls, U, S = W + r.won, Ls + r.lost, U + r.units, S + r.spent
  end
  local pct = math.floor(100 * W / math.max(1, W + Ls) + 0.5)
  msg(cell("|cffaaaaaaTotal|r", 22) .. " " .. cell(pct .. "%", 5, true) .. "  " .. cell(W, 4, true) .. " " .. cell(Ls, 4, true)
    .. "  " .. cell(U, 6, true) .. "  " .. cell(Coins(S), 12, true))
end

local function Fail(qty, item, why)
  Tally(item, false)
  Row({ "|cffff5555Failed|r", "", item and Dim(ItemText(item)) or "", "", GREY .. why .. "|r" })
end

-- Log ----------------------------------------------------------------------
-- Every press, search, quote and purchase is written to wb_AHSnipeLog
-- (saved to disk on /reload or logout). /snipe log clear wipes it.

local LOG_MAX = 12000
local clock = GetTimePreciseSec or GetTime
local confirmAt = 0

-- Rows that repeat on every spammed press. A run of identical ones is folded
-- into a single row: rep = how many, t/ts = first, tEnd = last.
local NOISY = { key = true, press = true, refresh_skip = true }
local foldRows = {} -- signature -> row, since the last non-noisy event

local function L(event, data)
  local log = wb_AHSnipeLog
  if not log or log.off then return end
  local row = data or {}
  if NOISY[event] then
    -- key, press and refresh_skip interleave on every press, so fold by
    -- signature until something meaningful happens in between.
    local sig = event .. "|" .. tostring(row.step or row.why or row.view) .. "|" .. tostring(row.item)
    local prev = foldRows[sig]
    if prev then
      prev.rep = (prev.rep or 1) + 1
      prev.tEnd = string.format("%.3f", clock())
      return
    end
  end
  row.t = string.format("%.3f", clock())
  row.ts = time()
  row.e = event
  log.rows[#log.rows + 1] = row
  if NOISY[event] then
    foldRows[event .. "|" .. tostring(row.step or row.why or row.view) .. "|" .. tostring(row.item)] = row
  else
    foldRows = {}
  end
  if #log.rows > LOG_MAX then
    local keep = {}
    for i = #log.rows - LOG_MAX / 2, #log.rows do keep[#keep + 1] = log.rows[i] end
    log.rows = keep
  end
end

local function ms(sec) return math.floor(sec * 1000 + 0.5) end

local function get(o, ...)
  for i = 1, select("#", ...) do
    if not o then return nil end
    o = o[select(i, ...)]
  end
  return o
end

local function AH()
  local ah = AuctionHouseFrame
  if ah and ah:IsShown() then return ah end
end

local function KeyOf(frame)
  local disp = frame and frame.ItemDisplay
  if disp and disp.GetItemKey then
    local k = disp:GetItemKey()
    if k then return k end
  end
  return frame and frame.itemKey
end

local function OpenItemID()
  local ah = AH()
  if not ah then return end
  if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() then
    local k = KeyOf(ah.ItemBuyFrame); return k and k.itemID
  end
  if ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() then
    local k = KeyOf(get(ah.CommoditiesBuyFrame, "BuyDisplay")) or KeyOf(ah.CommoditiesBuyFrame)
    return k and k.itemID
  end
end

-- The open item's key (commodity or single item).
local function OpenKey()
  local ah = AH()
  if not ah then return end
  if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() then return KeyOf(ah.ItemBuyFrame) end
  if ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() then
    return KeyOf(get(ah.CommoditiesBuyFrame, "BuyDisplay")) or KeyOf(ah.CommoditiesBuyFrame)
  end
end

-- Snipe only buys your current favorites. A max you set stays saved after you
-- unstar an item, but it does nothing until you star it again.
local function IsFav(key)
  if not key or not C_AuctionHouse.IsFavoriteItem then return true end
  local ok, v = pcall(C_AuctionHouse.IsFavoriteItem, key)
  if not ok then return true end
  return v and true or false
end

-- How many sell per day across the region, from TSM's desktop app data
-- (AuctionDB "DBRegionSoldPerDay"). nil when TSM or its data isn't there.
local MIN_SOLD = 200
-- Without TSM (the Steam Deck), Snapshot.lua stands in: TSM's sale average
-- and sold per day, copied from the PC each time the addon is pushed.
local function Snap(kind, id)
  local s = wb_AHSnipe_Snapshot
  local t = type(s) == "table" and s[kind]
  return t and t[id]
end
local function TSMValue(source, id)
  if not (TSM_API and TSM_API.GetCustomPriceValue) then return end
  local ok, v = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. id)
  if ok and type(v) == "number" then return v end
end

local function SoldPerDay(id)
  if not id then return end
  return TSMValue("DBRegionSoldPerDay", id) or Snap("sold", id)
end

-- Snipe skips items that sell fewer than Min sold/day (Setup; 0 = off).
-- Items TSM has no number for are not blocked.
local function SlowSeller(id)
  local min = DB.minSold or MIN_SOLD
  if min <= 0 then return end
  local sold = SoldPerDay(id)
  if sold and sold < min then return sold, min end
end

-- What buyers actually paid across the region (TSM "DBRegionSaleAvg", copper).
local function SoldValue(id)
  if not id then return end
  local v = TSMValue("DBRegionSaleAvg", id) or Snap("sale", id)
  if v and v > 0 then return v end
end

-- Buy ceiling: never pay more than Max % of TSM (Setup; default 90, 0 = off)
-- of the sold value. Items without their own max use it as their max.
local TSM_PCT, GAP_PCT = 90, 20
local function Ceiling(id)
  local pct = DB.tsmPct or TSM_PCT
  if pct <= 0 then return end
  local v = SoldValue(id)
  return v and math.max(1, math.floor(v * pct / 100)) or nil
end

-- Your max for an item: its own max (or your default), lowered to the TSM
-- ceiling when that's cheaper. With neither, the TSM ceiling alone.
local function Cap(itemID)
  local own = (itemID and DB.caps[itemID]) or DB.default
  local c = itemID and Ceiling(itemID)
  if own and c then return math.min(own, c) end
  return own or c
end

-- Resale gap: only buy units at least Gap % (Setup; default 20, 0 = off)
-- under the next price tier above your max, which is about where you'd
-- relist them. Returns the max to use for this list and that next tier.
-- The max the resale gap allowed on each item's last loaded list. Favorites
-- only show a lowest price, not the tiers, so jumping uses this to skip an
-- item the gap just ruled out (instead of jumping in and out on a loop).
local gapSeen = {}
local GAP_MEMORY = 300 -- seconds

local function GapCap(itemID, cap)
  local gap = DB.gapPct or GAP_PCT
  if not cap or gap <= 0 then return cap end
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice > cap and r.quantity - (r.numOwnerItems or 0) > 0 then
      local g = math.min(cap, math.floor(r.unitPrice * (100 - gap) / 100))
      if g < cap then gapSeen[itemID] = { cap = g, at = GetTime() } else gapSeen[itemID] = nil end
      return g, r.unitPrice
    end
  end
  if n > 0 then gapSeen[itemID] = nil end
  return cap
end
wb_AHSnipe_CapOf = Cap

local function Clear()
  pending, warned = false, false
end

-- Refresh ----------------------------------------------------------------

function wb_AHSnipe_Refresh(fromBuy)
  local ah = AH()
  if not ah then return end
  if wb_AHSnipe_Checking then return end
  local now = GetTime()
  local src = fromBuy and "buy" or "key"
  if not fromBuy and now - sentAt < MIN_GAP then
    L("refresh_skip", { why = "gap", src = src, sinceLast = ms(now - sentAt) })
    return
  end
  if pending and now - sentAt > STALE_GUARD then
    L("pending_expired", { waited = ms(now - sentAt) })
    pending = false
  end

  if Queued() or buying then
    L("refresh_skip", { why = Queued() and "queued" or "buying", src = src })
    return
  end
  local ready = C_AuctionHouse.IsThrottledMessageSystemReady()
  if pending or not ready then
    L("refresh_skip", { why = pending and "waiting_reply" or "throttled", src = src, sinceLast = ms(now - sentAt) })
    if now - sentAt > WARN_AFTER and not warned then
      warned = true
      L("warn_no_answer", { waited = ms(now - sentAt) })
      msg("|cffff5555The AH hasn't answered in " .. WARN_AFTER .. "s. Stop refreshing for a bit. If it never recovers, relog.|r")
    end
    return
  end

  local b, view
  for _, name in ipairs({ "CommoditiesBuyFrame", "ItemBuyFrame" }) do
    local v = ah[name]
    if v and v:IsShown() then
      b, view = get(v, "ItemList", "RefreshFrame", "RefreshButton"), name
      break
    end
  end
  if not b then
    local fav = get(ah, "SearchBar", "FavoritesSearchButton")
    if lastBrowse == "fav" and fav then
      b, view = fav, "Favorites"
    else
      b, view = get(ah, "SearchBar", "SearchButton"), "Browse"
    end
  end
  if not b then msg("Couldn't find a refresh button.") L("error", { what = "no_refresh_button" }) return end

  L("search_sent", { view = view, src = src, sinceLast = ms(now - sentAt), item = OpenItemID() })
  pending, sentAt = true, now
  b:Click()
  return true
end

-- Buy: single items ------------------------------------------------------

-- Jump to deals from favorites ---------------------------------------------

-- Every favorite at or under its max, best deal (furthest under max) first.
local function Deals()
  local res = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults()
  local out = {}
  for _, r in ipairs(res or {}) do
    local id = r.itemKey and r.itemKey.itemID
    local cap = id and IsFav(r.itemKey) and not SlowSeller(id) and Cap(id)
    -- The resale gap ruled this price out on the item's last list (5 min).
    local g = id and gapSeen[id]
    if cap and g and GetTime() - g.at < GAP_MEMORY then cap = math.min(cap, g.cap) end
    if cap and r.minPrice and r.minPrice > 0 and r.minPrice <= cap then
      out[#out + 1] = { r = r, id = id, price = r.minPrice, cap = cap, score = (cap - r.minPrice) / cap }
    end
  end
  table.sort(out, function(a, b) return a.score > b.score end)
  return out
end

local function OpenDeal(r)
  local ah = AuctionHouseFrame
  local ok = ah and ah.SelectBrowseResult and pcall(ah.SelectBrowseResult, ah, r)
  if not ok and AuctionHouseBrowseResultsFrameMixin and AuctionHouseBrowseResultsFrameMixin.OnBrowseResultSelected then
    ok = pcall(AuctionHouseBrowseResultsFrameMixin.OnBrowseResultSelected, ah and ah.BrowseResultsFrame or {}, r)
  end
  return ok
end

-- Nothing under max on this press. After OVER_MAX_BACK in a row (and only
-- when you're working from favorites), go back to the favorites list.
-- A jump that lands after the cheap units are gone (nothing under max, not
-- even bait) goes back after EMPTY_JUMP_BACK presses instead of the full count.
local function BackLimit()
  return (jumped and not sawUnder) and EMPTY_JUMP_BACK or OVER_MAX_BACK
end

local function OverMax(itemID)
  overCount = overCount + 1
  if overCount >= BackLimit() and lastBrowse == "fav" and DB.pin ~= itemID then
    L("auto_back", { item = itemID, presses = overCount, empty = sawUnder and 0 or 1 })
    overCount = 0
    wb_AHSnipe_Favorites()
    return true
  end
end

local function BuyItem(frame)
  local key = KeyOf(frame)
  if not key then msg("No item open.") return end
  if not IsFav(key) then L("press", { step = "not_fav", item = key.itemID }) return end
  if SlowSeller(key.itemID) then L("press", { step = "slow_seller", item = key.itemID, sold = SoldPerDay(key.itemID) }) return end

  if Queued() then L("press", { step = "queued_wait", item = key.itemID }) return end
  if itemStale then
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "stale_refresh", item = key.itemID, sent = sent and 1 or 0 })
    return
  end

  local best
  for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
    local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
    if r and r.buyoutAmount and not r.containsOwnerItem
       and (not best or r.buyoutAmount < best.buyoutAmount) then
      best = r
    end
  end
  local cap = Cap(key.itemID)
  if not cap then SayOnce(key.itemID, "nomax", "No max set for " .. ItemText(key.itemID) .. ". Set one in the AH Snipe window.") return end
  if not best or best.buyoutAmount > cap then
    if OverMax(key.itemID) then return end
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "none_under", item = key.itemID, cap = cap, cheapest = best and best.buyoutAmount, sent = sent and 1 or 0 })
    return
  end
  if GetMoney() < best.buyoutAmount then msg("Not enough gold.") return end

  overCount = 0
  L("bid_sent", { item = key.itemID, price = best.buyoutAmount })
  itemStale = true
  C_AuctionHouse.PlaceBid(best.auctionID, best.buyoutAmount)
  bidding = { item = key.itemID, price = best.buyoutAmount, at = GetTime() }
end

-- Buy: commodities -------------------------------------------------------
-- Press 1: add up every unit listed at or under your max (and that you can
-- afford) and ask the server for a quote on that amount.
-- Press 2: buy it, if the quote still fits under your max.
-- If the list is out of date, a press refreshes it instead.

local function BuyCommodity()
  local itemID = OpenItemID()
  if not itemID then msg("No item open.") return end
  if not IsFav(OpenKey()) and not buying then L("press", { step = "not_fav", item = itemID }) return end
  if SlowSeller(itemID) and not buying then L("press", { step = "slow_seller", item = itemID, sold = SoldPerDay(itemID) }) return end
  local cap = Cap(itemID)
  if not cap then SayOnce(itemID, "nomax", "No max set for " .. ItemText(itemID) .. ". Set one (per unit) in the AH Snipe window.") return end

  local now = GetTime()

  -- A purchase is on its way: don't send anything that could knock it out.
  if buying then
    if now - buying.at < BUY_TIMEOUT then
      L("press", { step = "waiting_purchase", item = itemID, age = ms(now - buying.at) })
      return
    end
    L("purchase_timeout", { item = buying.item, qty = buying.qty, age = ms(now - buying.at) })
    Fail(buying.qty, buying.item, "no answer")
    buying = nil
    staleID = itemID
  end

  -- Another AH message is waiting its turn: sending now would drop it.
  if Queued() then
    L("press", { step = "queued_wait", item = itemID })
    return
  end

  -- Second press: confirm the quote.
  if quote and quote.itemID == itemID and now - quote.at < QUOTE_TTL then
    if not quote.total then
      L("press", { step = "waiting_quote", item = itemID, age = ms(now - quote.at) })
      return
    end
    if quote.total > quote.maxTotal then
      L("quote_rejected", { item = itemID, qty = quote.qty, total = quote.total, maxTotal = quote.maxTotal, est = quote.est, age = ms(now - quote.at) })
      local lostQty = quote.qty
      C_AuctionHouse.CancelCommoditiesPurchase()
      quote = nil
      staleID = itemID
      wb_AHSnipe_Refresh(true)
      Fail(lostQty, itemID, "price moved")
      return
    end
    if GetMoney() < quote.total then msg("Not enough gold.") L("press", { step = "no_gold" }) quote = nil return end
    L("confirm_sent", { item = itemID, qty = quote.qty, total = quote.total, quoteAge = ms(now - quote.at), priceAge = ms(now - (quote.priceAt or now)) })
    confirmAt = now
    buying = { at = now, item = itemID, qty = quote.qty, total = quote.total, gold = GetMoney() }
    C_AuctionHouse.ConfirmCommoditiesPurchase(itemID, quote.qty)
    quote = nil
    return
  end
  if quote then L("quote_expired", { item = quote.itemID, age = ms(now - quote.at) }) quote = nil end

  -- Out-of-date list: refresh first instead of quoting old listings.
  if staleID == itemID then
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "stale_refresh", item = itemID, sent = sent and 1 or 0 })
    return
  end

  -- First press: count everything under the max (lowered by the resale gap).
  local fullCap, nextTier = cap, nil
  cap, nextTier = GapCap(itemID, cap)
  local qty, total, gold = 0, 0, GetMoney()
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
  if n == 0 and GetTime() - sentAt < 2 then
    L("press", { step = "loading", item = itemID })
    return
  end
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if not r or r.unitPrice > cap then break end
    local c = r.quantity - (r.numOwnerItems or 0)
    if c > 0 then
      local afford = math.floor((gold - total) / r.unitPrice)
      if afford < c then c = afford end
      if c <= 0 then break end
      qty, total = qty + c, total + c * r.unitPrice
    end
  end
  local listAge = ms(now - (resultsAt[itemID] or now))

  if qty == 0 then
    if OverMax(itemID) then return end
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "none_under", item = itemID, cap = cap, cheapest = r and r.unitPrice, listings = n, listAge = listAge, sent = sent and 1 or 0 })
    return
  end

  local minQty = math.max(2, DB.minQty or MIN_QTY) -- 1 cheap unit is always bait
  local baitBuy = false
  if qty < minQty then
    overCount = 0 -- bait under max: stay parked
    baitPresses = baitPresses + 1
    if baitPresses < BAIT_GIVEUP then
      local sent = wb_AHSnipe_Refresh(true)
      L("press", { step = "under_min", item = itemID, qty = qty, min = minQty, listAge = listAge, sent = sent and 1 or 0 })
      return
    end
    -- No real deal after BAIT_GIVEUP presses: buy the bait so you can move on.
    baitBuy = true
    L("press", { step = "bait_buy", item = itemID, qty = qty, presses = baitPresses })
  end

  -- Ask for only part of the cheap units. If another buyer takes a few
  -- before you confirm, there are still enough left at the quoted price.
  local avail = qty
  local pct = PickPct(itemID)
  attemptPct[itemID] = pct
  local want = math.max(1, math.ceil(avail * pct / 100))
  want = math.min(want, avail - 1) -- always leave at least one unit
  if baitBuy then want = avail end  -- ...except when giving up on bait: take it
  if want < avail then
    qty, total = 0, 0
    for i = 1, n do
      local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
      if not r or r.unitPrice > cap then break end
      local c = math.min(r.quantity - (r.numOwnerItems or 0), want - qty)
      if c > 0 then qty, total = qty + c, total + c * r.unitPrice end
      if qty >= want then break end
    end
  end

  overCount, baitPresses = 0, 0
  quote = { itemID = itemID, qty = qty, maxTotal = qty * cap, at = now, est = total }
  L("quote_start", { item = itemID, qty = qty, avail = avail, pct = pct, est = total, cap = cap, listings = n, listAge = listAge })
  C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
end

local lastPressAt = 0
function wb_AHSnipe_Buy()
  local ah = AH()
  if not ah then return end
  if wb_AHSnipe_Checking then return end
  if wb_AHSnipe_StaleBlock and wb_AHSnipe_StaleBlock() then return end
  local now = GetTime()
  local view = (ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() and "item")
    or (ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() and "commodity")
    or (lastBrowse == "fav" and "favorites") or "browse"
  L("key", { view = view, item = OpenItemID(), gap = ms(now - lastPressAt), jumped = jumped })
  lastPressAt = now
  if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() then
    BuyItem(ah.ItemBuyFrame)
  elseif ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() then
    BuyCommodity()
  else
    if lastBrowse == "fav" then
      local deals = Deals()
      if #deals > 0 then
        if Queued() or buying or pending then L("press", { step = "jump_wait", deals = #deals }) return end
        local d = deals[1]
        local list = {}
        for k = 1, math.min(6, #deals) do list[k] = deals[k].id .. ":" .. deals[k].price .. "/" .. deals[k].cap end
        jumped, jumpAt, jumpPrice = d.id, GetTime(), d.price
        if OpenDeal(d.r) then
          pending, sentAt = true, GetTime()
          L("jump", { item = d.id, price = d.price, cap = d.cap, deals = #deals, all = table.concat(list, " ") })
          if DB.tick ~= false and wb_AHSnipe_PlayTick then wb_AHSnipe_PlayTick(d.id) end
          return
        end
        jumped, jumpAt, jumpPrice = nil, nil, nil
        L("error", { what = "jump_failed", item = d.id })
      end
    end
    wb_AHSnipe_Refresh(true)
  end
end

-- Events -----------------------------------------------------------------

local f = CreateFrame("Frame")
for _, e in ipairs({
  "ADDON_LOADED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_BROWSE_FAILURE",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "AUCTION_HOUSE_SHOW",
  "AUCTION_HOUSE_CLOSED",
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "UI_ERROR_MESSAGE",
}) do pcall(f.RegisterEvent, f, e) end

-- Expected profit per buy and per hour ------------------------------------
-- A buy's expected profit: what it should resell for (TSM's sale average,
-- else the market Snipe last saw) after the AH cut, minus what you paid.
-- The hourly rate counts only time the AH is open this session.
local sess = { profit = 0, ahTime = 0 }
local function AHTime()
  return sess.ahTime + (sess.openAt and (GetTime() - sess.openAt) or 0)
end
local function GoldText(c)
  c = math.floor(c + 0.5)
  return (c < 0 and "|cffff5555-|r" or "|cff55ff55+|r") .. Coins(math.abs(c))
end
-- "+8250/h  +41204": the session's rate per hour, then its total so far.
-- At least 5 minutes in the rate, so the first buy doesn't show a wild number.
local function SessionCell()
  if sess.profit == 0 then return "" end
  local rate = sess.profit / math.max(AHTime() / 3600, 1 / 12)
  return GoldText(rate) .. "|cffaaaaaa/h|r  " .. GoldText(sess.profit)
end

-- Returns the profit cell and the session cell for a Bought row.
local function BuyProfit(id, qty, total)
  local each = SoldValue(id) or (DB.mkt and DB.mkt[id] and DB.mkt[id].now)
  if not each or not total then return "|cff888888?|r", SessionCell() end
  local p = qty * each * (1 - AH_CUT_PCT / 100) - total
  sess.profit = sess.profit + p
  if session[id] then session[id].profit = (session[id].profit or 0) + p end
  return GoldText(p), SessionCell()
end
function wb_AHSnipe_SessionRate()
  local h = AHTime() / 3600
  return sess.profit, h, sess.profit / math.max(h, 1 / 12)
end

f:SetScript("OnEvent", function(_, e, arg1, arg2)
  if e == "AUCTION_HOUSE_SHOW" then sess.openAt = sess.openAt or GetTime() end
  if e == "AUCTION_HOUSE_CLOSED" and sess.openAt then
    sess.ahTime = sess.ahTime + (GetTime() - sess.openAt)
    sess.openAt = nil
  end
  if e == "ADDON_LOADED" then
    if arg1 == "wb_AHSnipe" then
      wb_AHSnipeDB = wb_AHSnipeDB or {}
      wb_AHSnipeDB.caps = wb_AHSnipeDB.caps or {}
      DB = wb_AHSnipeDB
      DB.roam = nil -- Jump is always on now; Stay is per item
      DB.baitOn = nil -- posting your own bait was removed
    end
    return
  end

  if e == "COMMODITY_PRICE_UPDATED" then
    if quote then quote.total = arg2 end -- arg1 unitPrice, arg2 totalPrice
    return
  elseif e == "COMMODITY_PRICE_UNAVAILABLE" then
    if quote then Fail(quote.qty, quote.itemID, "sold out") staleID = quote.itemID end
    quote = nil
    return
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
    local b = buying
    buying = nil
    if b then
      Tally(b.item, true, b.qty, b.total)
      local profit, hourly = BuyProfit(b.item, b.qty, b.total)
      Row({ "|cffffd100Bought|r", "|cffffd100" .. b.qty .. "|r", ItemText(b.item), profit, hourly })
    else
      msg("|cffffd100Bought.|r")
    end
    staleID = OpenItemID()
    return
  elseif e == "COMMODITY_PURCHASE_FAILED" then
    local b = buying
    buying = nil
    Fail(b and b.qty, b and b.item, "beaten to it")
    staleID = OpenItemID()
    return
  end

  if e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    if bidding then
      Tally(bidding.item, true, 1, bidding.price)
      local profit, hourly = BuyProfit(bidding.item, 1, bidding.price)
      Row({ "|cffffd100Bought|r", "|cffffd1001|r", ItemText(bidding.item), profit, hourly })
      bidding = nil
    end
    return
  elseif e == "UI_ERROR_MESSAGE" then
    if bidding and GetTime() - bidding.at < 3 then
      Fail(1, bidding.item, tostring(arg2))
      bidding = nil
    end
    return
  end

  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then staleID = nil end
  if e == "ITEM_SEARCH_RESULTS_UPDATED" then itemStale = false; itemResultsAt = GetTime() end

  if e == "AUCTION_HOUSE_CLOSED" then quote, buying, queuedAt, jumped = nil, nil, nil, nil end
  Clear()
end)

-- Slash ------------------------------------------------------------------

SLASH_WBAHSNIPE1 = "/snipe"
SlashCmdList.WBAHSNIPE = function(input)
  local cmd, val = strsplit(" ", strtrim(input or ""), 2)
  cmd = (cmd or ""):lower()
  local gold = tonumber(val)

  if cmd == "max" and gold then
    local id = OpenItemID()
    local c = math.floor(gold * 10000 + 0.5)
    if id then
      DB.caps[id] = c
      msg("Max for " .. (C_Item.GetItemNameByID(id) or ("item " .. id)) .. " set to " .. money(c) .. ".")
    else
      DB.default = c
      msg("No item open, so this is now your default max: " .. money(c) .. ".")
    end
  elseif cmd == "default" and gold then
    DB.default = math.floor(gold * 10000 + 0.5)
    msg("Default max set to " .. money(DB.default) .. ".")
  elseif cmd == "clear" then
    local id = OpenItemID()
    if id then DB.caps[id] = nil; msg("Cleared the max for this item.") else msg("Open an item to clear its max.") end
  elseif cmd == "log" then
    wb_AHSnipeLog = wb_AHSnipeLog or { rows = {} }
    if val == "clear" then wb_AHSnipeLog.rows = {} msg("Log cleared.")
    elseif val == "off" then wb_AHSnipeLog.off = true msg("Logging off.")
    elseif val == "on" then wb_AHSnipeLog.off = nil msg("Logging on.")
    else msg("Log has " .. #wb_AHSnipeLog.rows .. " entries" .. (wb_AHSnipeLog.off and " (logging is off)" or "") .. ". /reload to save it to disk. /snipe log clear | on | off") end
  elseif cmd == "tune" then
    if val == "apply" then wb_AHSnipe_TuneApplyAll() end
    wb_AHSnipe_TuneWindow()
  elseif cmd == "explore" then
    DB.explore = not DB.explore
    if settings and settings.explore then settings.explore:SetChecked(DB.explore) end
    msg("Explore Buy %: " .. (DB.explore and "|cff55ff55on|r" or "|cffff5555off|r"))
  elseif cmd == "stats" then
    wb_AHSnipe_Stats(val == "all")
  elseif cmd == "version" then
    msg("|cffaaaaaaInstalled:|r " .. tostring(wb_AHSnipe_Build or "unknown"))
  elseif cmd == "tab" then
    DB.ownTab = not (DB.ownTab ~= false)
    wb_AHSnipe_SetupTab()
    msg("Own chat tab " .. (DB.ownTab ~= false and "on." or "off. Messages go to your main chat."))
  elseif cmd == "mono" then
    DB.monoChat = not (DB.monoChat ~= false)
    wb_AHSnipe_ApplyMono()
    msg("Monospace chat " .. (DB.monoChat ~= false and "on." or "off."))
  elseif cmd == "profit" then
    wb_AHSnipe_ProfitReport()
  elseif cmd == "stay" or cmd == "pin" then
    local id = OpenItemID()
    if DB.pin and (not id or DB.pin == id) then
      DB.pin = nil; msg("Stay off: Snipe can go back to favorites again.")
    elseif id then
      DB.pin = id; msg("Staying on " .. ItemText(id) .. " until you uncheck Stay (or /snipe stay again).")
    else
      msg("Open an item first.")
    end
  elseif cmd == "market" then
    wb_AHSnipe_MarketReport()
  elseif cmd == "status" then
    msg("AH ready: " .. tostring(C_AuctionHouse.IsThrottledMessageSystemReady()) .. ", waiting on reply: " .. tostring(pending))
  else
    msg("/snipe max <gold>  (max for the open item, or default if none is open)")
    msg("/snipe default <gold>  |  /snipe clear  |  /snipe status")
    msg("Default max: " .. (DB.default and money(DB.default) or "none"))
  end
end

-- AH Snipe window -----------------------------------------------------------
-- One window to the right of the AH, with four tabs:
--   Snipe: what the next press will do, and the open item's own settings.
--   Sell:  what you paid vs the price you're posting at.
--   Setup: defaults, Explore, Check prices and its results.
--   Buy %: win rates per Buy %.
-- It follows the AH: the AH's Sell tab shows Sell, going back shows Snipe.

local TAB = { snipe = 1, sell = 2, setup = 3, tune = 4 }

local function SaveMax(b, id, quiet)
  local g = strtrim(b[1]:GetText() or "")
  local sv = strtrim(b[2]:GetText() or "")
  local cv = strtrim(b[3]:GetText() or "")
  if g == "" and sv == "" and cv == "" then
    if id then DB.caps[id] = nil; msg("Cleared the max for " .. ItemText(id) .. ". It uses your default now.")
    else DB.default = nil; msg("Cleared the default max.") end
    return
  end
  local c = (tonumber(g) or 0) * 10000 + (tonumber(sv) or 0) * 100 + (tonumber(cv) or 0)
  if c <= 0 then msg("Max must be more than 0.") return end
  if id then DB.caps[id] = c else DB.default = c end
  if not quiet then msg("Max " .. (id and ("for " .. ItemText(id)) or "default") .. ": " .. Coins(c)) end
end

-- Put a price into a set of gold/silver/copper boxes (unless you're typing in one).
local function ShowMax(b, v)
  if b[1]:HasFocus() or b[2]:HasFocus() or b[3]:HasFocus() then return end
  if v then
    b[1]:SetText(tostring(math.floor(v / 10000)))
    b[2]:SetText(tostring(math.floor(v / 100) % 100))
    b[3]:SetText(tostring(v % 100))
  else
    for k = 1, 3 do b[k]:SetText("") end
  end
end

-- Snipe always jumps into deals and back out when they're gone. Stay (per
-- item) keeps it on one item. This toggles Stay for the open item; the name
-- is kept so old keybinds and macros still work.
function wb_AHSnipe_ToggleRoam()
  local id = OpenItemID()
  if not id then msg("Open an item first.") return end
  DB.pin = (DB.pin ~= id) and id or nil
  L("pin", { item = id, on = DB.pin and 1 or 0 })
  msg(DB.pin and ("Staying on " .. ItemText(id) .. ".") or ("Stay off for " .. ItemText(id) .. "."))
end

function wb_AHSnipe_Favorites()
  local ah = AH()
  if not ah then return end
  -- Show the browse list first if an item is open.
  for _, name in ipairs({ "CommoditiesBuyFrame", "ItemBuyFrame" }) do
    local v = ah[name]
    if v and v:IsShown() and ah.SetDisplayMode and AuctionHouseFrameDisplayMode then
      ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    end
  end
  lastBrowse = "fav"
  jumped, jumpAt, jumpPrice = nil, nil, nil
  return wb_AHSnipe_Refresh(true)
end

-- On a machine without TSM, copy the PC's maxes from Snapshot.lua once per
-- new snapshot. Maxes you change here afterwards stay until the next one.
local function ApplySnapshotCaps()
  local s = wb_AHSnipe_Snapshot
  if type(s) ~= "table" or type(s.caps) ~= "table" or (TSM_API and TSM_API.GetCustomPriceValue) then return end
  if DB.snapApplied == s.at then return end
  local n = 0
  for id, v in pairs(s.caps) do
    if DB.caps[id] ~= v then DB.caps[id] = v; n = n + 1 end
  end
  if s.default then DB.default = s.default end
  DB.snapApplied = s.at
  msg("Copied " .. n .. " max prices from your PC (snapshot " .. date("%b %d %H:%M", s.at) .. ").")
  L("snapshot_caps", { changed = n, at = s.at })
end

local hooked
local function HookSearchButtons()
  if hooked or not AuctionHouseFrame then return end
  local fav = get(AuctionHouseFrame, "SearchBar", "FavoritesSearchButton")
  local search = get(AuctionHouseFrame, "SearchBar", "SearchButton")
  if fav then fav:HookScript("OnClick", function() lastBrowse = "fav" end) end
  for _, name in ipairs({ "CommoditiesBuyFrame", "ItemBuyFrame", "BrowseResultsFrame" }) do
    local fr = AuctionHouseFrame[name]
    if fr then
      fr:HookScript("OnShow", function()
        overCount = 0
        sawUnder = false
        baitPresses = 0
        L("view", { show = name, item = OpenItemID(), via = (jumped and GetTime() - (jumpAt or 0) < 1) and "jump" or "you", list = lastBrowse })
        if name == "BrowseResultsFrame" then jumped = nil end
      end)
    end
  end
  if search then search:HookScript("OnClick", function() lastBrowse = "text" end) end
  hooked = true
end

local function BigBox(parent, name, width, numeric, height, fontSize)
  local e
  if height and height > 28 then
    -- Plain flat box drawn at full size (the stock box art doesn't stretch).
    e = CreateFrame("EditBox", name, parent, "BackdropTemplate")
    -- Achievement-list look: thin rounded brown border on a dark panel,
    -- gold border while you're typing in it.
    e:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    e:SetBackdropColor(0.09, 0.07, 0.05, 0.95)
    local IDLE = { 0.48, 0.36, 0.24, 1 }
    local ACTIVE = { 1, 0.82, 0, 1 }
    e:SetBackdropBorderColor(unpack(IDLE))
    e:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(unpack(ACTIVE)) end)
    e:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(unpack(IDLE)) end)
    e:SetFontObject("ChatFontNormal")
    e:EnableMouse(true)
  else
    e = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    e:SetFontObject("ChatFontNormal")
  end
  e:SetSize(width, height or 28)
  e:SetAutoFocus(false)
  -- Clicking in selects everything, so typing replaces the old value.
  -- (Done a frame later, or the click itself puts the cursor back.)
  e:HookScript("OnEditFocusGained", function(self)
    C_Timer.After(0, function() if self:HasFocus() then self:HighlightText() end end)
  end)
  e:HookScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
  e:SetJustifyH("LEFT")
  if fontSize then
    local f, _, flags = e:GetFont()
    e:SetFont(f or STANDARD_TEXT_FONT, fontSize, flags or "")
  end
  e:SetTextInsets(10, 10, 0, 0)
  if numeric then e:SetNumeric(true) end
  e:SetTextColor(1, 1, 1)
  -- When a value is set from code, scroll back to the start so the whole
  -- number shows instead of just its last digits.
  hooksecurefunc(e, "SetText", function(self) if not self:HasFocus() then self:SetCursorPosition(0) end end)
  return e
end

-- Gold, silver and copper boxes in a row, styled like the AH's Sell screen.
-- Enter in any of them saves; Tab moves between them.
local COIN_TEX = { "Interface\\MoneyFrame\\UI-GoldIcon", "Interface\\MoneyFrame\\UI-SilverIcon", "Interface\\MoneyFrame\\UI-CopperIcon" }
local function MaxBoxes(parent, prefix, y, save)
  local b = {}
  for k, tex in ipairs(COIN_TEX) do
    -- Gold can run to 5 digits; silver and copper never pass 2.
    local e = BigBox(parent, prefix .. k, k == 1 and 96 or 66, true, 36, 16)
    e:SetMaxLetters(k == 1 and 5 or 2)
    e:SetTextInsets(10, 26, 0, 0)
    e:SetPoint("TOPLEFT", parent, "TOPLEFT", k == 1 and 16 or k == 2 and 122 or 198, y)
    local icon = e:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetTexture(tex)
    icon:SetPoint("RIGHT", e, "RIGHT", -8, 0)
    e:SetScript("OnEnterPressed", function(self) save(b); self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    b[k] = e
  end
  for k, e in ipairs(b) do e:SetScript("OnTabPressed", function() b[k % 3 + 1]:SetFocus() end) end
  return b
end

-- A window in the auction house's own style: stone border, gold title bar
-- and dark inset. Falls back to a plain dark box if the template is missing.
local function AHFrame(name, parent, titleText)
  local ok, f = pcall(CreateFrame, "Frame", name, parent, "ButtonFrameTemplate")
  if ok and f then
    if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
    if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
    if f.CloseButton then f.CloseButton:Hide() end
    f.titleFS = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
    if f.titleFS then f.titleFS:SetText(titleText)
    elseif f.SetTitle then f:SetTitle(titleText) end
    if not f.titleFS then
      f.titleFS = { SetText = function(_, t) if f.SetTitle then f:SetTitle(t) end end }
    end
    return f
  end
  f = CreateFrame("Frame", name, parent, "BackdropTemplate")
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f.titleFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.titleFS:SetPoint("TOP", 0, -8)
  f.titleFS:SetText(titleText)
  return f
end

local function Text(parent, font, x, y, text, width)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetJustifyH("LEFT")
  if width then fs:SetWidth(width); fs:SetWordWrap(false) end
  if text then fs:SetText(text) end
  return fs
end

-- Thin brown rounded border, like the achievement list.
local function Group(parent, x, y, w, h)
  local g = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  g:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  g:SetSize(w, h)
  g:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  g:SetBackdropColor(1, 1, 1, 0.04)
  g:SetBackdropBorderColor(0.48, 0.36, 0.24, 0.9)
  return g
end

-- What the next press will do -------------------------------------------------
-- Mirrors the Snipe key's own decisions without doing anything, so the window
-- can say it in words. Returns the main line, a detail line and a kind:
-- "go" (it will buy or jump), "wait", "idle" (it will refresh) or "stop".

local function Under(itemID, cap)
  local under, afford, cheapest, gold = 0, 0, nil, GetMoney()
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if not r then break end
    local c = r.quantity - (r.numOwnerItems or 0)
    if c > 0 and not cheapest then cheapest = r.unitPrice end
    if r.unitPrice > cap then break end
    if c > 0 then
      under = under + c
      local a = math.min(c, math.floor(gold / r.unitPrice))
      if a > 0 then afford, gold = afford + a, gold - a * r.unitPrice end
    end
  end
  return under, afford, cheapest, n
end

local function BackIn()
  if DB.pin and DB.pin == OpenItemID() then return "  Staying here (pinned)." end
  if lastBrowse == "fav" then
    return "  Back to favorites in " .. math.max(1, BackLimit() - overCount) .. "."
  end
  return ""
end

local function NextPress()
  local ah = AH()
  if not ah then return "", "", "idle" end
  if wb_AHSnipe_Checking then return "Price check running", "Snipe waits until it's done.", "wait" end
  if wb_AHSnipe_StalePending and wb_AHSnipe_StalePending() then
    return "Answer the price reminder", "Snipe won't buy until you do.", "stop"
  end
  local now = GetTime()
  local id = OpenItemID()
  if id and not IsFav(OpenKey()) and not buying then
    return "Not in your favorites", "Snipe only buys favorites. Star it to snipe it.", "stop"
  end
  local slowSold, slowMin = SlowSeller(id)
  if id and slowSold and not buying then
    return "Sells too slowly: " .. math.floor(slowSold + 0.5) .. " a day", "Min sold/day is " .. slowMin .. " (Setup).", "stop"
  end

  if ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() and id then
    local cap = Cap(id)
    if not cap then return "No max for this item", "Set one below.", "stop" end
    if buying and now - buying.at < BUY_TIMEOUT then return "Buying " .. buying.qty .. "...", "Waiting for the server.", "wait" end
    if Queued() then return "Waiting for the server", "A message is in line; pressing now would drop it.", "wait" end
    if quote and quote.itemID == id and now - quote.at < QUOTE_TTL then
      if not quote.total then return "Getting a quote for " .. quote.qty, "", "wait" end
      if quote.total > quote.maxTotal then return "Price moved: refresh", "The cheap units were taken.", "idle" end
      return "Buy " .. quote.qty .. " for " .. Coins(quote.total),
        Coins(math.floor(quote.total / quote.qty + 0.5)) .. " each, max " .. Coins(cap), "go"
    end
    if staleID == id then return "Refresh", "The list changed after your last buy.", "idle" end
    local fullCap, nextTier = cap, nil
    cap, nextTier = GapCap(id, cap)
    local under, afford, cheapest, n = Under(id, cap)
    if n == 0 then return "Loading listings", "", "wait" end
    if under == 0 then
      if cap < fullCap and cheapest and cheapest <= fullCap then
        return "No resale gap: refresh", "Next tier " .. Coins(nextTier) .. ", so buys at " .. Coins(cap) .. " or less." .. BackIn(), "idle"
      end
      return "Nothing under max: refresh", "Cheapest " .. (cheapest and Coins(cheapest) or "?") .. ", max " .. Coins(cap) .. "." .. BackIn(), "idle"
    end
    if afford == 0 then
      return "Can't afford: " .. Coins(cheapest) .. " each", "You have " .. Coins(GetMoney()) .. ".", "stop"
    end
    local minQty = math.max(2, DB.minQty or MIN_QTY)
    if afford < minQty then
      if baitPresses >= BAIT_GIVEUP - 1 then
        return "Buy the bait: " .. afford .. " from " .. Coins(cheapest), "No real deal in " .. BAIT_GIVEUP .. " presses, so it takes the bait to move on.", "go"
      end
      return "Bait: " .. afford .. " under max, refresh", "Buys at " .. minQty .. "+ (Min qty). Takes the bait in " .. (BAIT_GIVEUP - baitPresses) .. " presses.", "idle"
    end
    local pct = PickPct(id)
    local want = math.min(math.max(1, math.ceil(afford * pct / 100)), afford - 1)
    return "Quote " .. want .. " of " .. afford .. " from " .. Coins(cheapest),
      "Buy % " .. pct .. (DB.explore and (" (exploring, try " .. (Tries(id, pct) + 1) .. ")") or ""), "go"
  end

  if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() and id then
    local key = KeyOf(ah.ItemBuyFrame)
    local cap = Cap(id)
    if not cap then return "No max for this item", "Set one below.", "stop" end
    if Queued() then return "Waiting for the server", "", "wait" end
    if itemStale then return "Refresh", "The list changed after your last buy.", "idle" end
    local best
    for i = 1, (key and C_AuctionHouse.GetNumItemSearchResults(key) or 0) do
      local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
      if r and r.buyoutAmount and not r.containsOwnerItem and (not best or r.buyoutAmount < best) then best = r.buyoutAmount end
    end
    if not best or best > cap then
      return "Nothing under max: refresh", "Cheapest " .. (best and Coins(best) or "none") .. ", max " .. Coins(cap) .. "." .. BackIn(), "idle"
    end
    if GetMoney() < best then return "Can't afford: " .. Coins(best), "You have " .. Coins(GetMoney()) .. ".", "stop" end
    return "Buy for " .. Coins(best), "Max " .. Coins(cap) .. ".", "go"
  end

  if lastBrowse == "fav" then
    if pending and now - sentAt < STALE_GUARD then return "Waiting for favorites", "", "wait" end
    local deals = Deals()
    if #deals > 0 then
      local d = deals[1]
      return "Jump to " .. ItemText(d.id), Coins(d.price) .. ", max " .. Coins(d.cap) .. ". " .. #deals .. " under max.", "go"
    end
    return "Refresh favorites", "Nothing under max yet.", "idle"
  end
  return "Refresh search", "Open your favorites to snipe from them.", "idle"
end
wb_AHSnipe_NextPress = NextPress

-- Jump sound: plays when Snipe opens a favorite that's under your max, so
-- you know you've landed on a deal while you're spamming.
-- Sounds to pick from on the Setup tab (name, SOUNDKIT key, id if the key is missing).
local TICK_SOUNDS = {
  { "Ping", "MAP_PING", 3175 },
  { "Coins", "LOOT_WINDOW_COIN_SOUND", 120 },
  { "Whisper", "TELL_MESSAGE", 3081 },
  { "Raid warning", "RAID_WARNING", 8959 },
  { "Soft click", "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  { "Say item" }, -- text to speech: the item's name
}
function wb_AHSnipe_TickSound()
  local t = TICK_SOUNDS[DB.tickSound or 1] or TICK_SOUNDS[1]
  return t[1], (SOUNDKIT and SOUNDKIT[t[2]]) or t[3]
end
-- Text to speech, with the voice, speed and volume from the game's own
-- text to speech options (its volume is separate from Master Volume).
local function Speak(text)
  if type(C_VoiceChat) ~= "table" or not C_VoiceChat.SpeakText then return false end
  local voice, rate, volume = 0, 0, 100
  if type(C_TTSSettings) == "table" then
    if C_TTSSettings.GetVoiceOptionID and Enum and Enum.TtsVoiceType then
      voice = C_TTSSettings.GetVoiceOptionID(Enum.TtsVoiceType.Standard) or 0
    end
    if C_TTSSettings.GetSpeechRate then rate = C_TTSSettings.GetSpeechRate() or rate end
    if C_TTSSettings.GetSpeechVolume then volume = C_TTSSettings.GetSpeechVolume() or volume end
  end
  if C_VoiceChat.StopSpeakingText then pcall(C_VoiceChat.StopSpeakingText) end
  return pcall(C_VoiceChat.SpeakText, voice, text, rate, volume)
end

function wb_AHSnipe_PlayTick(itemID)
  local name, id = wb_AHSnipe_TickSound()
  if id == nil then -- Say item
    local text = itemID and (C_Item.GetItemNameByID(itemID) or (wb_AHSnipeLog.names and wb_AHSnipeLog.names[itemID])) or "Buy"
    if Speak(text) then return end
    id = (SOUNDKIT and SOUNDKIT.MAP_PING) or 3175 -- no text to speech: ping instead
  end
  PlaySound(id, "Master")
end
function wb_AHSnipe_NextTickSound()
  DB.tickSound = (DB.tickSound or 1) % #TICK_SOUNDS + 1
  wb_AHSnipe_PlayTick(OpenItemID())
  return (wb_AHSnipe_TickSound())
end

local KIND_COLOR = {
  go = { 0.33, 1, 0.33 }, wait = { 1, 0.82, 0 }, idle = { 0.6, 0.6, 0.6 }, stop = { 1, 0.33, 0.33 },
}

-- "This session: 82% won (9 of 11), avg 299"
local function StatLine(label, r)
  local n = r and (r.won + r.lost) or 0
  if n == 0 then return "|cffaaaaaa" .. label .. ":|r |cff888888no buys yet|r" end
  local pct = math.floor(100 * r.won / n + 0.5)
  local color = pct >= 60 and "|cff55ff55" or pct >= 30 and "|cffffd100" or "|cffff5555"
  local avg = (r.units or 0) > 0 and ("  avg " .. Coins(r.spent / r.units)) or ""
  return "|cffaaaaaa" .. label .. ":|r " .. color .. pct .. "%|r won |cff888888(" .. r.won .. " of " .. n .. ")|r" .. avg
end

local SNIPE_H, SETUP_H = 220, 384
local SNIPE_ITEM_H = 212 -- item card: name, max, one session line

-- One line under the max: this item's session win rate and expected profit.
local function SessionSummary(id)
  local r = session[id]
  local n = r and (r.won + r.lost) or 0
  if n == 0 then return "|cffaaaaaaThis session:|r |cff888888no buys yet|r" end
  local pct = math.floor(100 * r.won / n + 0.5)
  local color = pct >= 60 and "|cff55ff55" or pct >= 30 and "|cffffd100" or "|cffff5555"
  local t = "|cffaaaaaaThis session:|r " .. color .. pct .. "%|r won |cff888888(" .. r.won .. " of " .. n .. ")|r"
  if (r.profit or 0) ~= 0 then t = t .. "  " .. GoldText(r.profit) end
  return t
end

-- The item name's tooltip: what used to fill the card.
function wb_AHSnipe_ItemDetails(id)
  local out = {}
  local pct, why = PickPct(id), nil
  if DB.explore then why = "exploring"
  else
    local _, w = SavedPct(id)
    why = w == "best" and "its best" or w == "item" and "set for it" or "general"
  end
  out[#out + 1] = "|cffaaaaaaBuy %:|r " .. pct .. "% |cff888888(" .. why .. ")|r"
  out[#out + 1] = StatLine("All-time", DB.stats and DB.stats[id])
  local m1, m2 = wb_AHSnipe_MarketLines(id)
  if m1 and m1 ~= "" then out[#out + 1] = m1 end
  if m2 and m2 ~= "" then out[#out + 1] = m2 end
  local sold, min = SoldPerDay(id), DB.minSold or MIN_SOLD
  out[#out + 1] = "|cffaaaaaaSold/day:|r " .. (sold and ((min > 0 and sold < min and "|cffff5555" or "|cffffffff") .. math.floor(sold + 0.5) .. "|r"
    .. (min > 0 and (" |cff888888(min " .. min .. ")|r") or "")) or "|cff888888no TSM data|r")
  out[#out + 1] = wb_AHSnipe_ProfitLine(id)
  return out
end

-- Size the window for the tab that's showing.
function wb_AHSnipe_Layout()
  if not settings then return end
  local t = settings.tab
  if t == TAB.snipe then settings:SetSize(290, settings.snipeH or SNIPE_H)
  elseif t == TAB.sell then settings:SetSize(290, settings.sellH or 200)
  elseif t == TAB.setup then
    local res = settings.checkPanel and settings.checkPanel:IsShown()
    settings:SetSize(res and 430 or 290, SETUP_H + (res and settings.checkH or 0))
  end
end

local function BuildSnipePage(p)
  -- Next press
  local strip = Group(p, 12, -28, 266, 56)
  Text(strip, "GameFontNormalSmall", 10, -7, "Next press")
  strip.text = Text(strip, "GameFontHighlight", 10, -21, nil, 246)
  strip.detail = Text(strip, "GameFontDisableSmall", 10, -38, nil, 246)
  settings.strip = strip

  -- The open item
  local card = CreateFrame("Frame", nil, p)
  card:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -92)
  card:SetSize(290, 110)
  card.name = Text(card, "GameFontHighlightLarge", 14, -2, nil, 196)
  -- Stay: Snipe never leaves this item for favorites until you uncheck it.
  local stay = CreateFrame("CheckButton", "wb_AHSnipeStay", card, "UICheckButtonTemplate")
  stay:SetSize(24, 24)
  stay:SetPoint("TOPLEFT", card, "TOPLEFT", 214, 2)
  local stayText = stay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  stayText:SetPoint("LEFT", stay, "RIGHT", 2, 0)
  stayText:SetText("Stay")
  stay:SetScript("OnClick", function(self)
    local id = OpenItemID()
    DB.pin = self:GetChecked() and id or nil
    L("pin", { item = id, on = DB.pin and 1 or 0 })
  end)
  stay:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Stay on this item")
    GameTooltip:AddLine("Snipe won't jump back to favorites from this item until you uncheck it. Jumping into it from favorites still works.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  stay:SetScript("OnLeave", GameTooltip_Hide)
  card.stay = stay
  local maxLabel = Text(card, "GameFontNormal", 14, -26, "Max price")
  card.maxTag = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  card.maxTag:SetPoint("LEFT", maxLabel, "RIGHT", 8, 0)
  card.max = MaxBoxes(card, "wb_AHSnipeMax", -42, function(b) SaveMax(b, OpenItemID()) end)

  card.session = Text(card, "GameFontHighlightSmall", 14, -88, nil, 262)

  -- Everything else about the item: hover its name.
  local hit = CreateFrame("Frame", nil, card)
  hit:SetPoint("TOPLEFT", card, "TOPLEFT", 10, 0)
  hit:SetSize(200, 20)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    local id = OpenItemID()
    if not id then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ItemText(id))
    for _, line in ipairs(wb_AHSnipe_ItemDetails(id)) do GameTooltip:AddLine(line, 1, 1, 1) end
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", GameTooltip_Hide)
  settings.card = card

  -- No item open: what's under max on your favorites
  local favs = CreateFrame("Frame", nil, p)
  favs:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -92)
  favs:SetSize(290, 280)
  favs.title = Text(favs, "GameFontNormal", 14, -2, "Favorites under your max")
  favs.lines = {}
  for i = 1, 11 do favs.lines[i] = Text(favs, "GameFontHighlightSmall", 14, -10 - i * 17, nil, 262) end
  settings.favs = favs

end

local function BuildSetupPage(p)
  local dLabel = Text(p, "GameFontNormal", 14, -32, "Default max")
  local dTag = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  dTag:SetPoint("LEFT", dLabel, "RIGHT", 8, 0)
  dTag:SetText("for items without their own")
  settings.defMax = MaxBoxes(p, "wb_AHSnipeDefault", -48, function(b) SaveMax(b, nil) end)

  Text(p, "GameFontNormal", 14, -96, "Min qty")
  local minBox = BigBox(p, "wb_AHSnipeMinBox", 66, true, 36, 16)
  minBox:SetMaxLetters(4)
  minBox:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -112)
  minBox:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText())
    if n and n >= 1 then DB.minQty = n; msg("Min to buy (commodities): " .. n) end
    self:ClearFocus()
  end)
  minBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  settings.minBox = minBox

  Text(p, "GameFontNormal", 122, -96, "Check %")
  local ckBox = BigBox(p, "wb_AHSnipeCheckPct", 66, true, 36, 16)
  ckBox:SetMaxLetters(3)
  ckBox:SetPoint("TOPLEFT", p, "TOPLEFT", 122, -112)
  ckBox:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText())
    if n and n >= 1 and n <= 100 then DB.checkPct = n; msg("Check prices will suggest " .. n .. "% of market.") end
    self:ClearFocus()
  end)
  ckBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  settings.ckBox = ckBox

  Text(p, "GameFontNormal", 198, -96, "Sold/day")
  local soldBox = BigBox(p, "wb_AHSnipeMinSold", 76, true, 36, 16)
  soldBox:SetMaxLetters(6)
  soldBox:SetPoint("TOPLEFT", p, "TOPLEFT", 198, -112)
  soldBox:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText())
    if n and n >= 0 then
      DB.minSold = n
      msg(n > 0 and ("Only buys items that sell " .. n .. "+ a day (TSM region data).") or "Sold/day check off.")
    end
    self:ClearFocus()
  end)
  soldBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  soldBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Min sold per day")
    GameTooltip:AddLine("Snipe skips items that sell fewer than this a day across the region, from TSM's desktop app data. 0 turns it off. Items TSM has no number for aren't blocked.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  soldBox:SetScript("OnLeave", GameTooltip_Hide)
  settings.soldBox = soldBox

  local function PctBox(x, label, name, key, default, tip)
    Text(p, "GameFontNormal", x, -160, label)
    local b = BigBox(p, name, 66, true, 36, 16)
    b:SetMaxLetters(3)
    b:SetPoint("TOPLEFT", p, "TOPLEFT", x, -176)
    b:SetScript("OnEnterPressed", function(self)
      local n = tonumber(self:GetText())
      if n and n >= 0 and n <= 100 then
        DB[key] = n
        msg(label .. ": " .. (n > 0 and (n .. "%") or "off"))
      end
      self:ClearFocus()
    end)
    b:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(label)
      GameTooltip:AddLine(tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b.key, b.default = key, default
    return b
  end
  settings.tsmBox = PctBox(16, "Max % TSM", "wb_AHSnipeTsmPct", "tsmPct", TSM_PCT,
    "Never pay more than this % of what buyers actually paid (TSM region sale average). Items without their own max use it as their max. 0 turns it off.")
  settings.gapBox = PctBox(122, "Resale gap %", "wb_AHSnipeGapPct", "gapPct", GAP_PCT,
    "Only buy units at least this % under the next price tier above your max, about where you'd relist them. 0 turns it off.")

  -- General Buy % and Explore share a box: Explore takes over Buy % while it's on.
  local g = Group(p, 12, -224, 266, 72)
  local pctLabel = Text(g, "GameFontNormal", 10, -8, "General Buy %")
  settings.pctTag = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  settings.pctTag:SetPoint("LEFT", pctLabel, "RIGHT", 4, 0)
  local pct = BigBox(g, "wb_AHSnipeGeneralPct", 66, true, 36, 16)
  pct:SetMaxLetters(3)
  pct:SetPoint("TOPLEFT", g, "TOPLEFT", 10, -26)
  pct:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText())
    if n and n >= 1 then
      if n > MAX_PCT then n = MAX_PCT; msg("Buy % tops out at " .. MAX_PCT .. "% so the bait unit is never bought.") end
      DB.buyPct = n
      msg("General Buy %: " .. n .. "% (items with their own keep theirs).")
    end
    self:ClearFocus()
  end)
  pct:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  settings.genPct = pct

  local explore = CreateFrame("CheckButton", "wb_AHSnipeExplore", g, "UICheckButtonTemplate")
  explore:SetSize(28, 28)
  explore:SetPoint("LEFT", pct, "RIGHT", 12, 0)
  local exText = explore:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  exText:SetPoint("LEFT", explore, "RIGHT", 2, 6)
  exText:SetText("Explore")
  local exSub = explore:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  exSub:SetPoint("TOPLEFT", exText, "BOTTOMLEFT", 0, -2)
  exSub:SetText("sets Buy % automatically")
  explore:SetChecked(DB.explore and true or false)
  explore:SetScript("OnClick", function(self)
    DB.explore = self:GetChecked() and true or false
    L("explore", { on = DB.explore and 1 or 0 })
  end)
  settings.explore = explore

  local tick = CreateFrame("CheckButton", "wb_AHSnipeTick", p, "UICheckButtonTemplate")
  tick:SetSize(28, 28)
  tick:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -302)
  local tickText = tick:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  tickText:SetPoint("LEFT", tick, "RIGHT", 4, 0)
  tickText:SetText("Jump sound")
  tick:SetChecked(DB.tick ~= false)
  tick:SetScript("OnClick", function(self) DB.tick = self:GetChecked() and true or false end)
  -- Click to hear the next sound; the one you stop on is kept.
  local snd = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  snd:SetSize(84, 22)
  snd:SetPoint("TOPRIGHT", p, "TOPRIGHT", -14, -305)
  snd:SetText((wb_AHSnipe_TickSound()))
  snd:SetScript("OnClick", function(self) self:SetText(wb_AHSnipe_NextTickSound()) end)
  snd:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Jump sound")
    GameTooltip:AddLine("Click to hear the next sound. The one showing is the one you'll get.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  snd:SetScript("OnLeave", GameTooltip_Hide)

  local checkBtn = CreateFrame("Button", "wb_AHSnipeCheckButton", p, "UIPanelButtonTemplate")
  checkBtn:SetSize(258, 28)
  checkBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -340)
  checkBtn:SetText("Check prices")
  checkBtn:SetScript("OnClick", function() wb_AHSnipe_Check() end)
  settings.checkBtn = checkBtn

  local cancelBtn = CreateFrame("Button", "wb_AHSnipeCancelCheck", p, "UIPanelButtonTemplate")
  cancelBtn:SetSize(80, 28)
  cancelBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -340)
  cancelBtn:SetText("Cancel")
  cancelBtn:SetScript("OnClick", function() wb_AHSnipe_CancelCheck() end)
  cancelBtn:Hide()
  settings.cancelBtn = cancelBtn
end

local function UpdateSnipePage()
  local strip, card, favs = settings.strip, settings.card, settings.favs
  local text, detail, kind = NextPress()
  local c = KIND_COLOR[kind] or KIND_COLOR.idle
  strip.text:SetText(text)
  strip.text:SetTextColor(c[1], c[2], c[3])
  -- The detail line only explains a refresh or a block; buys and waits speak for themselves.
  strip.detail:SetText((kind == "idle" or kind == "stop") and detail or "")
  strip:SetBackdropBorderColor(c[1] * 0.7, c[2] * 0.7, c[3] * 0.7, 1)

  local id = OpenItemID()
  card:SetShown(id and true or false)
  favs:SetShown(not id)
  local h = id and SNIPE_ITEM_H or (92 + 30 + math.max(1, math.min(#favs.lines, #Deals())) * 17 + 14)
  if h ~= settings.snipeH then
    settings.snipeH = h
    if settings.tab == TAB.snipe then settings:SetHeight(h) end
  end
  if id then
    card.name:SetText(ItemText(id))
    card.stay:SetChecked(DB.pin == id)
    local own = DB.caps[id]
    local set = own or DB.default
    local eff = Cap(id)
    if eff and (not set or eff < set) then
      card.maxTag:SetText("|cff55ff55TSM " .. (DB.tsmPct or TSM_PCT) .. "%: " .. Coins(eff) .. "|r")
    else
      card.maxTag:SetText((own or DB.default) and "" or "none set")
    end
    ShowMax(card.max, set)

    card.session:SetText(SessionSummary(id))
  else
    local lines = favs.lines
    for i = 1, #lines do lines[i]:SetText("") end
    if lastBrowse ~= "fav" then
      favs.title:SetText("No item open")
      lines[1]:SetText("|cffaaaaaaOpen your favorites (the star) to snipe from them.|r")
    else
      local deals = Deals()
      favs.title:SetText(#deals > 0 and ("Favorites under your max (" .. #deals .. ")") or "Favorites under your max")
      if #deals == 0 then lines[1]:SetText("|cff888888None right now. Keep pressing Snipe to refresh.|r") end
      for i = 1, math.min(#lines, #deals) do
        local d = deals[i]
        local off = math.floor(100 * (d.cap - d.price) / d.cap + 0.5)
        lines[i]:SetText(ItemText(d.id) .. "  " .. Coins(d.price) .. " |cff888888/ " .. Coins(d.cap) .. "  -" .. off .. "%|r")
      end
    end
  end
end

local function UpdateSetupPage()
  ShowMax(settings.defMax, DB.default)
  if not settings.minBox:HasFocus() then settings.minBox:SetText(tostring(DB.minQty or MIN_QTY)) end
  if not settings.ckBox:HasFocus() then settings.ckBox:SetText(tostring(DB.checkPct or 70)) end
  if not settings.soldBox:HasFocus() then settings.soldBox:SetText(tostring(DB.minSold or MIN_SOLD)) end
  for _, b in ipairs({ settings.tsmBox, settings.gapBox }) do
    if not b:HasFocus() then b:SetText(tostring(DB[b.key] or b.default)) end
  end
  local pct = settings.genPct
  settings.explore:SetChecked(DB.explore and true or false)
  if DB.explore then
    if pct:HasFocus() then pct:ClearFocus() end
    pct:Disable()
    pct:SetNumeric(false) -- numeric boxes may refuse letters
    pct:SetText("auto")
    pct:SetTextColor(0.5, 0.5, 0.5)
    settings.pctTag:SetText("exploring")
  else
    if not pct:IsEnabled() then pct:Enable(); pct:SetNumeric(true); pct:SetTextColor(1, 1, 1) end
    if not pct:HasFocus() then pct:SetText(tostring(math.min(MAX_PCT, DB.buyPct or BUY_PCT))) end
    settings.pctTag:SetText("")
  end
end

local function BuildBox()
  if settings or not AuctionHouseFrame then return end

  settings = AHFrame("wb_AHSnipeSettings", AuctionHouseFrame, "AH Snipe")
  settings:SetSize(290, SNIPE_H)
  settings:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
  settings.pages = {}
  for i = 1, 4 do
    local pg = CreateFrame("Frame", nil, settings)
    pg:SetAllPoints(settings)
    pg:Hide()
    settings.pages[i] = pg
  end
  BuildSnipePage(settings.pages[TAB.snipe])
  BuildSetupPage(settings.pages[TAB.setup])

  -- Keep the showing page current, and follow the AH's Buy / Sell tabs.
  local t, onSell = 0, nil
  settings:SetScript("OnUpdate", function(_, el)
    t = t + el
    if t < 0.25 then return end
    t = 0
    local sell = wb_AHSnipe_SellShown and wb_AHSnipe_SellShown() or false
    if sell ~= onSell then
      onSell = sell
      if sell and settings.tab == TAB.snipe then wb_AHSnipe_SelectTab(TAB.sell)
      elseif not sell and settings.tab == TAB.sell then wb_AHSnipe_SelectTab(TAB.snipe) end
    end
    if settings.tab == TAB.snipe then pcall(UpdateSnipePage)
    elseif settings.tab == TAB.setup then pcall(UpdateSetupPage)
    elseif settings.tab == TAB.sell and wb_AHSnipe_UpdateSell then pcall(wb_AHSnipe_UpdateSell) end
  end)

  -- Tabs along the bottom edge, like the AH's Buy / Sell / Auctions.
  local tabs = { "Snipe", "Sell", "Setup", "Buy %" }
  for i, name in ipairs(tabs) do
    local ok, tab = pcall(CreateFrame, "Button", "wb_AHSnipeSettingsTab" .. i, settings, "PanelTabButtonTemplate")
    if not ok or not tab then tab = CreateFrame("Button", "wb_AHSnipeSettingsTab" .. i, settings, "UIPanelButtonTemplate"); tab:SetSize(70, 24) end
    tab:SetID(i)
    tab:SetText(name)
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    if i == 1 then tab:SetPoint("TOPLEFT", settings, "BOTTOMLEFT", 10, 2)
    else tab:SetPoint("LEFT", _G["wb_AHSnipeSettingsTab" .. (i - 1)], "RIGHT", 2, 0) end
    tab:SetScript("OnClick", function() wb_AHSnipe_SelectTab(i) end)
  end
  if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, settings, #tabs) end
  wb_AHSnipe_SelectTab(TAB.snipe)
end

-- Slow sellers in your favorites --------------------------------------------
-- When your favorites list loads, say once which favorites sell fewer than
-- your Sold/day (Snipe skips those) and which TSM has no number for (those
-- aren't blocked). It speaks again only if the list or Sold/day changes.
local slowSaid
local function CheckSlowFavorites()
  if lastBrowse ~= "fav" or not DB then return end
  local min = DB.minSold or MIN_SOLD
  if min <= 0 or not (TSM_API and TSM_API.GetCustomPriceValue or type(wb_AHSnipe_Snapshot) == "table") then return end
  local slow, unknown, sig = {}, {}, { min }
  for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    local id = r.itemKey and r.itemKey.itemID
    if id and IsFav(r.itemKey) then
      local sold = SoldPerDay(id)
      if not sold then unknown[#unknown + 1] = id; sig[#sig + 1] = id .. "?"
      elseif sold < min then slow[#slow + 1] = { id = id, sold = sold }; sig[#sig + 1] = id end
    end
  end
  local key = table.concat(sig, ",")
  if key == slowSaid then return end
  slowSaid = key
  if #slow == 0 and #unknown == 0 then return end
  table.sort(slow, function(a, b) return a.sold < b.sold end)
  if #slow > 0 then
    local parts = {}
    for _, x in ipairs(slow) do parts[#parts + 1] = ItemText(x.id) .. " |cffff5555" .. math.floor(x.sold + 0.5) .. "|r" end
    msg("|cffffd100Skipping " .. #slow .. " slow " .. (#slow == 1 and "seller" or "sellers") .. "|r |cffaaaaaa(under " .. min .. " sold/day):|r " .. table.concat(parts, ", "))
  end
  if #unknown > 0 then
    local parts = {}
    for _, id in ipairs(unknown) do parts[#parts + 1] = ItemText(id) end
    msg("|cffaaaaaaNo TSM sales data, so not checked:|r " .. table.concat(parts, ", "))
  end
  L("slow_favs", { min = min, slow = #slow, unknown = #unknown })
end

local sfw = CreateFrame("Frame")
sfw:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
sfw:SetScript("OnEvent", function() pcall(CheckSlowFavorites) end)

local ui = CreateFrame("Frame")
ui:RegisterEvent("AUCTION_HOUSE_SHOW")
ui:SetScript("OnEvent", function() pcall(ApplySnapshotCaps); BuildBox(); HookSearchButtons() end)


-- Highlight prices under your max in the native AH lists ----------------
-- Turns the price text green on any row at or under your max (item max,
-- or your default max). Works on the browse list, item lists and
-- commodity lists.

local GREEN = { 0.2, 1, 0.2 }

local function MoneyFontStrings(frame, out, inMoney, depth)
  depth = depth or 0
  if depth > 6 or not frame then return out end
  local isMoney = inMoney or (frame.SetAmount ~= nil) or (frame.GoldDisplay ~= nil)
  if isMoney then
    for _, r in ipairs({ frame:GetRegions() }) do
      if r.GetObjectType and r:GetObjectType() == "FontString" then out[#out + 1] = r end
    end
  end
  for _, c in ipairs({ frame:GetChildren() }) do
    MoneyFontStrings(c, out, isMoney, depth + 1)
  end
  return out
end

local function RowInfo(row)
  local d = (row.GetElementData and row:GetElementData()) or row.rowData
  if type(d) ~= "table" then return end
  local price = d.buyoutAmount or d.unitPrice or d.minPrice
  local id = d.itemID or (d.itemKey and d.itemKey.itemID)
  local mine = d.containsOwnerItem or ((d.numOwnerItems or 0) > 0 and d.numOwnerItems == d.quantity)
  return id, price, mine
end

local function PaintRow(row, showBadge)
  local id, price, mine = RowInfo(row)
  local cap = id and Cap(id)
  local under = price and cap and not mine and price <= cap

  row.wbMoneyFS = row.wbMoneyFS or MoneyFontStrings(row, {})
  for _, fs in ipairs(row.wbMoneyFS) do
    if not fs.wbOrig then fs.wbOrig = { fs:GetTextColor() } end
    if under then fs:SetTextColor(unpack(GREEN)) else fs:SetTextColor(unpack(fs.wbOrig)) end
  end

  -- Fallback if no price text was found in this row: a faint green tint.
  if #row.wbMoneyFS == 0 then
    if under and not row.wbTint then
      row.wbTint = row:CreateTexture(nil, "ARTWORK")
      row.wbTint:SetAllPoints()
      row.wbTint:SetColorTexture(0.2, 1, 0.2, 0.15)
    end
    if row.wbTint then row.wbTint:SetShown(under and true or false) end
  end

  -- Favorites: % badge beside the price for big moves.
  local pct = showBadge and lastBrowse == "fav" and id and favChanges[id]
  local noMax = showBadge and lastBrowse == "fav" and id and not Cap(id)
  if pct or noMax then
    if not row.wbBadge then row.wbBadge = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") end
    local anchor, left
    for _, fs in ipairs(row.wbMoneyFS) do
      local l = fs:IsShown() and (fs:GetText() or "") ~= "" and fs:GetLeft()
      if l and (not left or l < left) then anchor, left = fs, l end
    end
    row.wbBadge:ClearAllPoints()
    if anchor then row.wbBadge:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
    else row.wbBadge:SetPoint("LEFT", row, "LEFT", 8, 0) end
    if pct then
      local n = math.floor(math.abs(pct) * 100 + 0.5)
      row.wbBadge:SetText(pct < 0 and ("|cff33ff33-" .. n .. "%|r") or ("|cffff5555+" .. n .. "%|r"))
    else
      row.wbBadge:SetText("|cff999999no max|r")
    end
    row.wbBadge:Show()
  elseif row.wbBadge then
    row.wbBadge:Hide()
  end
end

local function PaintList(list, showBadge)
  local sb = list and list:IsVisible() and list.ScrollBox
  if not sb or not sb.EnumerateFrames then return end
  for _, row in sb:EnumerateFrames() do
    pcall(PaintRow, row, showBadge)
  end
end

local hl = CreateFrame("Frame")
local hlT = 0
hl:SetScript("OnUpdate", function(_, el)
  hlT = hlT + el
  if hlT < 0.2 then return end
  hlT = 0
  local ah = AH()
  if not ah or not DB then return end
  PaintList(get(ah, "BrowseResultsFrame", "ItemList"), true)
  PaintList(get(ah, "ItemBuyFrame", "ItemList"))
  PaintList(get(ah, "CommoditiesBuyFrame", "ItemList"))
end)

-- Log: server events -----------------------------------------------------

local lg = CreateFrame("Frame")
for _, e in ipairs({
  "PLAYER_LOGIN",
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "AUCTION_HOUSE_BROWSE_FAILURE",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED",
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_AUCTION_CREATED",
  "UI_ERROR_MESSAGE",
  "PLAYER_MONEY",
}) do pcall(lg.RegisterEvent, lg, e) end
local lastMoney = GetMoney and GetMoney() or 0

lg:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "PLAYER_LOGIN" then
    wb_AHSnipeLog = wb_AHSnipeLog or {}
    wb_AHSnipeLog.rows = wb_AHSnipeLog.rows or {}
    L("session", { date = date("%Y-%m-%d %H:%M:%S"), char = UnitName("player") .. "-" .. (GetRealmName() or "") })
    return
  end
  local now = GetTime()
  local short = e:gsub("^AUCTION_HOUSE_", "AH_")

  if e == "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED" then queuedAt = now
  elseif e == "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT" or e == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then queuedAt = nil end
  if e == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and buying then
    L("purchase_dropped", { item = buying.item, qty = buying.qty, age = ms(now - buying.at) })
  end

  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    resultsAt[a1] = now
    -- Bait: cheapest listing is fewer units than your Min qty and well
    -- under the next real price.
    local r1 = C_AuctionHouse.GetCommoditySearchResultInfo(a1, 1)
    local r2 = C_AuctionHouse.GetCommoditySearchResultInfo(a1, 2)
    if r1 and r2 and (r1.numOwnerItems or 0) == 0 and r1.quantity < (DB.minQty or MIN_QTY)
       and r1.unitPrice < r2.unitPrice * 0.85 then
      wb_AHSnipeLog.bait = wb_AHSnipeLog.bait or {}
      local k = a1 .. ":" .. r1.unitPrice
      local b = wb_AHSnipeLog.bait[k]
      local ts = time()
      if not b then
        b = { item = a1, price = r1.unitPrice, qty = r1.quantity, first = ts, seen = 0, days = {} }
        wb_AHSnipeLog.bait[k] = b
      end
      b.seen = b.seen + 1
      b.last = ts
      b.next = r2.unitPrice
      b.cap = Cap(a1)
      b.days[date("%Y-%m-%d")] = true
      wb_AHSnipeLog.names = wb_AHSnipeLog.names or {}
      wb_AHSnipeLog.names[a1] = wb_AHSnipeLog.names[a1] or C_Item.GetItemNameByID(a1)
    end
    local top = {}
    for i = 1, math.min(5, C_AuctionHouse.GetNumCommoditySearchResults(a1) or 0) do
      local r = C_AuctionHouse.GetCommoditySearchResultInfo(a1, i)
      if r then top[#top + 1] = r.unitPrice .. "x" .. r.quantity .. ((r.numOwnerItems or 0) > 0 and "(mine)" or "") end
    end
    local cap, under, underListings, n = Cap(a1), 0, 0, C_AuctionHouse.GetNumCommoditySearchResults(a1) or 0
    if cap then
      for i = 1, n do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(a1, i)
        if not r or r.unitPrice > cap then break end
        under = under + r.quantity - (r.numOwnerItems or 0)
        underListings = underListings + 1
      end
    end
    if under > 0 and a1 == OpenItemID() then sawUnder = true end
    L(short, { item = a1, latency = ms(now - sentAt), top = table.concat(top, " "), cap = cap,
      listings = n, underQty = under, underListings = underListings, jumped = jumped })
  elseif e == "ITEM_SEARCH_RESULTS_UPDATED" then
    local key = a1
    local id = key and key.itemID
    local cap, under, cheapest = id and Cap(id), 0, nil
    for i = 1, (key and C_AuctionHouse.GetNumItemSearchResults(key) or 0) do
      local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
      if r and r.buyoutAmount and not r.containsOwnerItem then
        if not cheapest or r.buyoutAmount < cheapest then cheapest = r.buyoutAmount end
        if cap and r.buyoutAmount <= cap then under = under + 1 end
      end
    end
    L(short, { item = id, latency = ms(now - sentAt), cap = cap, cheapest = cheapest, under = under })
  elseif e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    local row = { latency = ms(now - sentAt), list = lastBrowse }
    if lastBrowse == "fav" then
      local res = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
      local deals, noMax = Deals(), 0
      for _, r in ipairs(res) do
        local id = r.itemKey and r.itemKey.itemID
        if id and not Cap(id) then noMax = noMax + 1 end
      end
      local list = {}
      for k = 1, math.min(6, #deals) do list[k] = deals[k].id .. ":" .. deals[k].price .. "/" .. deals[k].cap end
      row.items, row.deals, row.noMax, row.dealList = #res, #deals, noMax, table.concat(list, " ")
    end
    L(short, row)
  elseif e == "COMMODITY_PRICE_UPDATED" then
    if quote then quote.priceAt = now end
    L(short, { unit = a1, total = a2, latency = quote and ms(now - quote.at), qty = quote and quote.qty, maxTotal = quote and quote.maxTotal })
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" or e == "COMMODITY_PURCHASE_FAILED" or e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    L(short, { latency = ms(now - confirmAt) })
  elseif e == "UI_ERROR_MESSAGE" then
    if AH() then L("ui_error", { msg = tostring(a2) }) end
  elseif e == "PLAYER_MONEY" then
    local m = GetMoney()
    if AH() then L("money", { gold = m, delta = m - lastMoney }) end
    lastMoney = m
  else
    L(short, { ready = C_AuctionHouse.IsThrottledMessageSystemReady() and 1 or 0 })
  end
end)

-- Favorites snapshots ----------------------------------------------------
-- Each time the favorites list loads, save every item's cheapest price and
-- total quantity with the real time. Only saved when something changed
-- since the last snapshot. Stored in wb_AHSnipeLog.favs.

local FAV_MAX = 5000
local lastFavSig
local prevFav -- itemID -> cheapest price at the previous favorites refresh
local warnedNoMax = {} -- favorites already flagged for having no max this session

local function SnapFavorites()
  if lastBrowse ~= "fav" or not wb_AHSnipeLog then return end
  local results = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults()
  if not results or #results == 0 then return end

  local missing = {}
  for _, r in ipairs(results) do
    local id = r.itemKey and r.itemKey.itemID
    if id and not Cap(id) and not warnedNoMax[id] then
      warnedNoMax[id] = true
      missing[#missing + 1] = C_Item.GetItemNameByID(id) or ("item " .. id)
    end
  end
  if #missing > 0 then
    msg("|cffffcc00No max set:|r " .. table.concat(missing, ", ") .. ". Open each one and type a max to snipe it.")
  end

  local parts, cur = {}, {}
  wb_AHSnipeLog.names = wb_AHSnipeLog.names or {}
  for _, r in ipairs(results) do
    local id = r.itemKey and r.itemKey.itemID
    if id and r.minPrice and r.minPrice > 0 and (not cur[id] or r.minPrice < cur[id]) then
      cur[id] = r.minPrice
    end
    if id and r.minPrice then
      parts[#parts + 1] = id .. ":" .. r.minPrice .. ":" .. (r.totalQuantity or 0)
      if not wb_AHSnipeLog.names[id] then
        wb_AHSnipeLog.names[id] = C_Item.GetItemNameByID(id)
      end
    end
  end
  table.sort(parts)
  local sig = table.concat(parts, " ")
  if sig == lastFavSig then return end
  lastFavSig = sig

  -- Baseline: the previous refresh this session, or the last saved
  -- snapshot if it's under 10 minutes old (survives a /reload).
  if not prevFav and wb_AHSnipeLog.favs then
    local last = wb_AHSnipeLog.favs[#wb_AHSnipeLog.favs]
    if last and time() - last.at < 600 then
      prevFav = {}
      for sid, sprice in last.d:gmatch("(%d+):(%d+):%d+") do
        local id, price = tonumber(sid), tonumber(sprice)
        if not prevFav[id] or price < prevFav[id] then prevFav[id] = price end
      end
    end
  end

  local changed = false
  for id, price in pairs(cur) do
    local old = prevFav and prevFav[id]
    if old and old > 0 and price ~= old then
      local pct = (price - old) / old
      if math.abs(pct) >= FAV_ALERT then
        favChanges[id] = pct
        changed = true
        local name = (wb_AHSnipeLog.names[id]) or C_Item.GetItemNameByID(id) or ("item " .. id)
        local n = math.floor(math.abs(pct) * 100 + 0.5)
        local tag = pct < 0 and ("|cff33ff33-" .. n .. "%|r") or ("|cffff5555+" .. n .. "%|r")
        -- Only drops to under your max get a line: those are the ones you can act on.
        local cap = Cap(id)
        if pct < 0 and cap and price <= cap then
          Row({ tag, "", ItemText(id), Coins(price), "|cffaaaaaa(was|r " .. Coins(old) .. "|cffaaaaaa)|r", MaxCell(id) })
        end
        L("fav_move", { item = id, old = old, new = price, pct = math.floor(pct * 1000 + 0.5) / 10 })
      else
        favChanges[id] = nil
      end
    end
  end
  prevFav = prevFav or {}
  for id, price in pairs(cur) do prevFav[id] = price end

  local favs = wb_AHSnipeLog.favs or {}
  wb_AHSnipeLog.favs = favs
  favs[#favs + 1] = { at = time(), d = sig }
  if #favs > FAV_MAX then table.remove(favs, 1) end
end

local fs = CreateFrame("Frame")
pcall(fs.RegisterEvent, fs, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
pcall(fs.RegisterEvent, fs, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
fs:SetScript("OnEvent", function() pcall(SnapFavorites) end)


-- Check prices -------------------------------------------------------------
-- Opens each favorite (one per press, so it never floods the AH), reads what
-- is really listed, and suggests a max. "Market" is the price you'd reach
-- after buying the cheapest 10% of what's listed (at least 5 units), so a
-- single cheap bait listing doesn't count. The suggestion is market times
-- your own usual ratio: the median of (your max / market) across items that
-- already have a max, or 70% if fewer than 3 do.

local CHECK_TIMEOUT = 3
local check        -- run in progress
local lastCheck    -- results of the last finished run
local checkPanel

local function FloorFromCommodity(id)
  local tiers, total = {}, 0
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(id) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
    if r then
      local q = r.quantity - (r.numOwnerItems or 0)
      if q > 0 then tiers[#tiers + 1] = { p = r.unitPrice, q = q }; total = total + q end
    end
  end
  if total == 0 then return end
  local target = math.max(5, math.ceil(total * 0.10))
  local cum = 0
  for _, t in ipairs(tiers) do
    cum = cum + t.q
    if cum >= target then return t.p, tiers[1].p, total end
  end
  return tiers[#tiers].p, tiers[1].p, total
end

local function FloorFromItem(key)
  local prices = {}
  for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
    local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
    if r and r.buyoutAmount and not r.containsOwnerItem then prices[#prices + 1] = r.buyoutAmount end
  end
  if #prices == 0 then return end
  table.sort(prices)
  return prices[math.max(1, math.ceil(#prices * 0.25))], prices[1], #prices
end

-- (Profit and market live in one do-block so their locals don't count
-- toward Lua's 200-locals limit for this file.)
do
-- Realized profit ------------------------------------------------------------
-- Snipe keeps its own live ledger, so profit updates the moment it happens:
--   buys:  every snipe you win (exact qty and price)
--   sales: every "Auction successful" mail, read when you open the mailbox
-- TSM's records (its saved data, as of your last /reload) fill in what the
-- ledger can't see: everything from before the ledger started, and AH buys
-- you made by hand. Each sale is matched to what you paid, oldest units
-- first. Sales are after the AH's cut (the mail says exactly what it took).
-- Units you didn't buy on the AH (farmed, crafted) have no cost and don't
-- count as profit.
local profitCache, tsmCache

local function SplitCSV(line)
  local t = {}
  for f in (line .. ","):gmatch("([^,]*),") do t[#t + 1] = f end
  return t
end

local function TSMRows(suffix)
  local out, db = {}, TradeSkillMasterDB
  if type(db) ~= "table" then return out end
  for k, v in pairs(db) do
    if type(k) == "string" and type(v) == "string" and k:sub(1, 2) == "r@" and k:sub(-#suffix) == suffix then
      local head
      for line in v:gmatch("[^\n]+") do
        local f = SplitCSV(line)
        if not head then
          head = {}
          for n, name in ipairs(f) do head[name] = n end
        else
          local id = tonumber((f[head.itemString or 0] or ""):match("^i:(%d+)"))
          if id then
            out[#out + 1] = {
              id = id, qty = tonumber(f[head.quantity or 0]) or 0, price = tonumber(f[head.price or 0]) or 0,
              ts = tonumber(f[head.time or 0]) or 0, source = f[head.source or 0],
            }
          end
        end
      end
    end
  end
  return out
end

local function Ledger()
  DB.ledger = DB.ledger or { start = time(), buys = {}, sales = {}, seen = {} }
  return DB.ledger
end

function wb_AHSnipe_LedgerBuy(id, qty, total)
  tinsert(Ledger().buys, { id = id, qty = qty, unit = total / qty, ts = time() })
  profitCache = nil
end

-- Item ID from a name (mail only gives the name).
local function IdFromName(name)
  if not name then return end
  for id, n in pairs(wb_AHSnipeLog and wb_AHSnipeLog.names or {}) do if n == name then return id end end
  if C_Item and C_Item.GetItemInfoInstant then
    local ok, id = pcall(C_Item.GetItemInfoInstant, name)
    if ok and type(id) == "number" then return id end
  end
end

-- Read every sale mail in the inbox. AH mail is kept 30 days, so the time it
-- was sent is now minus (30 - days left). Each sale is counted once.
local function ScanMail()
  if not (DB and GetInboxNumItems and GetInboxInvoiceInfo) then return end
  local led, added = Ledger(), 0
  for i = 1, GetInboxNumItems() do
    local info = { pcall(GetInboxInvoiceInfo, i) }
    if info[1] and info[2] == "seller" then
      local name, bid, consignment = info[3], info[5] or 0, info[8] or 0
      local qty = tonumber(info[12]) or 1
      local daysLeft = select(7, GetInboxHeaderInfo(i))
      if name and bid > 0 and daysLeft then
        local sent = math.floor(time() - (30 - daysLeft) * 86400)
        local key = name .. "|" .. qty .. "|" .. bid .. "|" .. math.floor(sent / 600)
        if not led.seen[key] then
          led.seen[key] = sent
          -- Sales sent before the ledger started are TSM's to report.
          if sent >= led.start then
            tinsert(led.sales, { name = name, id = IdFromName(name), qty = qty, net = bid - consignment, gross = bid, ts = sent })
            added = added + 1
          end
        end
      end
    end
  end
  if added > 0 then
    profitCache = nil
    L("mail_sales", { added = added })
  end
end

local mailFrame = CreateFrame("Frame")
mailFrame:RegisterEvent("MAIL_INBOX_UPDATE")
mailFrame:RegisterEvent("MAIL_SHOW")
mailFrame:SetScript("OnEvent", function() pcall(ScanMail) end)

local function BuildProfit()
  local led = Ledger()
  local start = led.start
  if not tsmCache then
    tsmCache = { buys = TSMRows("@internalData@csvBuys"), sales = TSMRows("@internalData@csvSales") }
  end
  local lots, sales = {}, {}
  local function Lot(id, qty, unit, ts)
    lots[id] = lots[id] or {}
    tinsert(lots[id], { left = qty, unit = unit, ts = ts })
  end
  local function Sale(id, qty, net, ts)
    sales[id] = sales[id] or {}
    tinsert(sales[id], { qty = qty, net = net, ts = ts })
  end
  -- Ledger buys, plus TSM's: all before the ledger started, and after that
  -- only ones that aren't a snipe already in the ledger (your buys by hand).
  for _, b in ipairs(led.buys) do Lot(b.id, b.qty, b.unit, b.ts) end
  for _, b in ipairs(tsmCache.buys) do
    if b.source == "Auction" and b.qty > 0 then
      local dup = false
      if b.ts >= start then
        for _, m in ipairs(led.buys) do
          if m.id == b.id and m.qty == b.qty and math.abs(m.ts - b.ts) <= 120 then dup = true break end
        end
      end
      if not dup then Lot(b.id, b.qty, b.price, b.ts) end
    end
  end
  -- Ledger sales, plus TSM's from before the ledger started.
  for _, x in ipairs(led.sales) do
    x.id = x.id or IdFromName(x.name)
    if x.id then Sale(x.id, x.qty, x.net, x.ts) end
  end
  for _, x in ipairs(tsmCache.sales) do
    if x.source == "Auction" and x.qty > 0 and x.ts < start then
      Sale(x.id, x.qty, x.price * x.qty, x.ts) -- TSM's sale prices are already after the cut
    end
  end

  local byTime = function(a, b) return a.ts < b.ts end
  local items, days, total = {}, {}, 0
  for id, list in pairs(sales) do
    table.sort(list, byTime)
    local ls = lots[id] or {}
    table.sort(ls, byTime)
    local it = { sold = 0, matched = 0, cost = 0, profit = 0, held = 0 }
    items[id] = it
    for _, sale in ipairs(list) do
      local netEach = sale.net / sale.qty
      local need, cost, got = sale.qty, 0, 0
      for _, lot in ipairs(ls) do
        if need <= 0 then break end
        if lot.left > 0 and lot.ts <= sale.ts + 60 then
          local take = math.min(lot.left, need)
          lot.left, need = lot.left - take, need - take
          got, cost = got + take, cost + take * lot.unit
          it.held = it.held + take * math.max(0, sale.ts - lot.ts) / 86400
        end
      end
      it.sold = it.sold + sale.qty
      if got > 0 then
        local p = netEach * got - cost
        it.matched, it.cost, it.profit = it.matched + got, it.cost + cost, it.profit + p
        local d = date("%Y-%m-%d", sale.ts)
        days[d] = (days[d] or 0) + p
        total = total + p
      end
    end
  end
  for id, ls in pairs(lots) do
    local it = items[id] or { sold = 0, matched = 0, cost = 0, profit = 0, held = 0 }
    items[id] = it
    local left = 0
    for _, lot in ipairs(ls) do left = left + lot.left end
    it.onHand = left
  end
  profitCache = { items = items, days = days, total = total }
end

function wb_AHSnipe_Profit(id)
  if not profitCache then BuildProfit() end
  return profitCache.items[id]
end

local function Signed(c)
  c = math.floor(c + 0.5)
  return (c < 0 and "|cffff5555-|r" or "|cff55ff55+|r") .. Coins(math.abs(c))
end

-- One line: "Profit: +81493 (43%) on 673 sold, 0.1d to sell"
function wb_AHSnipe_ProfitLine(id)
  local it = wb_AHSnipe_Profit(id)
  if not it or it.sold == 0 then
    return "|cffaaaaaaProfit:|r |cff888888none sold yet|r" .. ((it and (it.onHand or 0) > 0) and ("  |cff888888" .. it.onHand .. " on hand|r") or "")
  end
  if it.matched == 0 then return "|cffaaaaaaProfit:|r |cff888888" .. it.sold .. " sold, no AH buy cost on record|r" end
  local pct = it.cost > 0 and math.floor(100 * it.profit / it.cost + 0.5) or 0
  return "|cffaaaaaaProfit:|r " .. Signed(it.profit) .. " |cff888888(" .. pct .. "%) on " .. it.matched .. " sold, "
    .. ("%.1f"):format(it.held / it.matched) .. "d to sell|r"
end

-- /snipe profit: total, the last 7 days, and the top items.
function wb_AHSnipe_ProfitReport()
  BuildProfit()
  local c = profitCache
  msg("|cffffd100Realized profit|r |cffaaaaaa(after the AH cut; live since " .. date("%b %d", Ledger().start) .. ", TSM before that):|r " .. Signed(c.total))
  local line = {}
  for k = 6, 0, -1 do
    local d = date("%Y-%m-%d", time() - k * 86400)
    line[#line + 1] = date("%a", time() - k * 86400) .. " " .. (c.days[d] and Signed(c.days[d]) or "|cff8888880|r")
  end
  msg("|cffaaaaaaLast 7 days:|r " .. table.concat(line, "  "))
  local list = {}
  for id, it in pairs(c.items) do if it.matched > 0 then list[#list + 1] = { id = id, it = it } end end
  table.sort(list, function(a, b) return a.it.profit > b.it.profit end)
  for k = 1, math.min(10, #list) do
    local r = list[k]
    msg(TruncateChars(ItemText(r.id), 20) .. "  " .. wb_AHSnipe_ProfitLine(r.id):gsub("^|cffaaaaaaProfit:|r ", ""))
  end
  if #list > 10 then msg("|cff888888...and " .. (#list - 10) .. " more items. Full list: profit_items.csv from the export.|r") end
end

-- Market price by hour -------------------------------------------------------
-- Every time an item's listings load (sniping, price checks, anything), its
-- market price is noted: the same "market" Check prices uses. At most one
-- sample per item per 10 minutes goes into that hour's average, so a long
-- snipe session doesn't outweigh the rest of the day.
local MKT_EVERY = 600

local function RecordMarket(id, market, cheapest, listed)
  if not (id and market and DB) then return end
  DB.mkt = DB.mkt or {}
  local m = DB.mkt[id] or { h = {} }
  DB.mkt[id] = m
  local ts = time()
  m.now, m.nowAt = market, ts
  if m.at and ts - m.at < MKT_EVERY then return end
  m.at = ts
  local h = tonumber(date("%H"))
  local b = m.h[h] or { n = 0, sum = 0 }
  m.h[h] = b
  b.n, b.sum = b.n + 1, b.sum + market
  L("market", { item = id, market = market, cheapest = cheapest, listed = listed, hour = h })
end

local function HourText(h)
  if h == 0 then return "12am" elseif h < 12 then return h .. "am" elseif h == 12 then return "12pm" end
  return (h - 12) .. "pm"
end

-- usual = the average of each hour's average, so hours you play a lot don't
-- count extra. Also the cheapest and priciest hours as a % of usual.
function wb_AHSnipe_MarketInfo(id)
  local m = DB and DB.mkt and DB.mkt[id]
  if not m then return end
  local avg, sum, hours = {}, 0, 0
  for h, b in pairs(m.h) do
    if b.n > 0 then avg[h] = b.sum / b.n; sum = sum + avg[h]; hours = hours + 1 end
  end
  local info = { now = m.now, nowAt = m.nowAt, hours = hours, avg = avg }
  if hours == 0 then return info end
  info.usual = sum / hours
  for h, a in pairs(avg) do
    if not info.lo or a < avg[info.lo] then info.lo = h end
    if not info.hi or a > avg[info.hi] then info.hi = h end
  end
  info.loPct = math.floor(100 * avg[info.lo] / info.usual + 0.5)
  info.hiPct = math.floor(100 * avg[info.hi] / info.usual + 0.5)
  return info
end

local MKT_MIN_HOURS = 4 -- hours of data before naming a cheapest hour

-- Two short lines for the Snipe tab's item card.
function wb_AHSnipe_MarketLines(id)
  local m = wb_AHSnipe_MarketInfo(id)
  if not m or not m.now then return "|cffaaaaaaMarket:|r |cff888888no data yet|r", "" end
  local line1 = "|cffaaaaaaMarket:|r " .. Coins(m.now) .. " now"
  if m.usual then
    local pct = math.floor(100 * m.now / m.usual + 0.5)
    local color = pct <= 90 and "|cff55ff55" or pct >= 110 and "|cffff5555" or "|cffffffff"
    line1 = line1 .. ", " .. color .. pct .. "%|r of usual (" .. Coins(m.usual) .. ")"
  end
  local line2
  if m.hours < MKT_MIN_HOURS then
    line2 = "|cff888888Learning the day: " .. m.hours .. " of 24 hours seen.|r"
  else
    line2 = "|cffaaaaaaLowest|r " .. HourText(m.lo) .. " |cff55ff55" .. m.loPct .. "%|r"
      .. "  |cffaaaaaahighest|r " .. HourText(m.hi) .. " |cffff5555" .. m.hiPct .. "%|r"
      .. "  |cff888888(" .. m.hours .. "h seen)|r"
  end
  return line1, line2
end

-- /snipe market: one line per item, cheapest hour first.
function wb_AHSnipe_MarketReport()
  local list = {}
  for id in pairs(DB.mkt or {}) do
    local m = wb_AHSnipe_MarketInfo(id)
    if m and m.usual then list[#list + 1] = { id = id, m = m } end
  end
  if #list == 0 then msg("No market data yet. It builds up as item lists load.") return end
  table.sort(list, function(a, b) return (a.m.loPct or 100) < (b.m.loPct or 100) end)
  msg("|cffffd100Market by hour|r |cffaaaaaa(usual = average across the hours seen)|r")
  for _, r in ipairs(list) do
    local m = r.m
    local t = TruncateChars(ItemText(r.id), 20) .. "  usual " .. Coins(m.usual)
    if m.hours >= MKT_MIN_HOURS then
      t = t .. "  low " .. HourText(m.lo) .. " |cff55ff55" .. m.loPct .. "%|r  high " .. HourText(m.hi) .. " |cffff5555" .. m.hiPct .. "%|r"
    end
    msg(t .. "  |cff888888" .. m.hours .. "h|r")
  end
end

local mf = CreateFrame("Frame")
mf:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
mf:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
mf:SetScript("OnEvent", function(_, e, a1)
  if not DB or not a1 then return end
  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    RecordMarket(a1, FloorFromCommodity(a1))
  elseif type(a1) == "table" and a1.itemID then
    RecordMarket(a1.itemID, FloorFromItem(a1))
  end
end)
end

local function ShowCheckPanel()
  if not lastCheck or not settings then return end
  local page = settings.pages[3]
  if not checkPanel then
    checkPanel = CreateFrame("Frame", nil, page)
    checkPanel:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -378)
    checkPanel:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    checkPanel.title = checkPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    checkPanel.title:SetPoint("TOPLEFT", 14, 0)
    checkPanel.note = checkPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    checkPanel.note:SetPoint("TOPLEFT", 14, -16)
    local heads = { { "Item", 12 }, { "Market", 160 }, { "Now", 236 }, { "Suggest", 312 } }
    for _, h in ipairs(heads) do
      local fs = checkPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      fs:SetPoint("TOPLEFT", h[2], -36)
      fs:SetText(h[1])
    end
    checkPanel.rows = {}

    -- Scrolling list: 10 rows show at once; mouse wheel or scroll bar for the rest.
    local sf
    for _, tpl in ipairs({ "ScrollFrameTemplate", "UIPanelScrollFrameTemplate" }) do
      local ok, f = pcall(CreateFrame, "ScrollFrame", "wb_AHSnipeCheckScroll", checkPanel, tpl)
      if ok and f then sf = f break end
    end
    sf = sf or CreateFrame("ScrollFrame", "wb_AHSnipeCheckScroll", checkPanel)
    sf:SetPoint("TOPLEFT", checkPanel, "TOPLEFT", 0, -50)
    sf:SetPoint("BOTTOMRIGHT", checkPanel, "BOTTOMRIGHT", -28, 40)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
      local max = self:GetVerticalScrollRange()
      local v = math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40))
      self:SetVerticalScroll(v)
    end)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(392, 20)
    sf:SetScrollChild(content)
    checkPanel.scroll, checkPanel.content = sf, content

    local all = CreateFrame("Button", nil, checkPanel, "UIPanelButtonTemplate")
    all:SetSize(120, 24); all:SetPoint("BOTTOMLEFT", 12, 12); all:SetText("Apply all")
    all:SetScript("OnClick", function()
      local n = 0
      for _, r in ipairs(lastCheck.items) do
        if r.suggest then DB.caps[r.id] = r.suggest; n = n + 1 end
      end
      msg("Set " .. n .. " max prices from the price check.")
      ShowCheckPanel()
    end)
    local close = CreateFrame("Button", nil, checkPanel, "UIPanelButtonTemplate")
    close:SetSize(80, 24); close:SetPoint("BOTTOMRIGHT", -12, 12); close:SetText("Close")
    close:SetScript("OnClick", function() checkPanel:Hide(); wb_AHSnipe_Layout() end)
    settings.checkPanel = checkPanel
  end

  local items = lastCheck.items
  settings.checkH = 96 + math.min(#items, 10) * 20
  checkPanel:SetHeight(settings.checkH)
  checkPanel.content:SetSize(392, math.max(20, #items * 20))
  checkPanel.title:SetText("Price check: " .. #items .. " favorites")
  checkPanel.note:SetText(("Suggest = %d%% of market (Check %% above)"):format(math.floor(lastCheck.ratio * 100 + 0.5)))

  for i, r in ipairs(items) do
    local row = checkPanel.rows[i]
    if not row then
      row = CreateFrame("Frame", nil, checkPanel.content)
      row:SetSize(392, 20)
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", 12, 0); row.name:SetWidth(144); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
      row.market = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.market:SetPoint("LEFT", 160, 0)
      row.now = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.now:SetPoint("LEFT", 236, 0)
      row.suggest = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.suggest:SetPoint("LEFT", 312, 0)
      row.apply = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.apply:SetSize(40, 18); row.apply:SetPoint("RIGHT", -4, 0); row.apply:SetText("Set")
      checkPanel.rows[i] = row
    end
    row:SetPoint("TOPLEFT", checkPanel.content, "TOPLEFT", 0, -(i - 1) * 20)
    row.name:SetText(ItemText(r.id))
    row.market:SetText(r.market and Coins(r.market) or "|cff888888none|r")
    local cur = DB.caps[r.id]
    row.now:SetText(cur and Coins(cur) or "|cff888888none|r")
    row.suggest:SetText(r.suggest and Coins(r.suggest) or "")
    row.apply:SetShown(r.suggest and cur ~= r.suggest or false)
    row.apply:SetScript("OnClick", function()
      DB.caps[r.id] = r.suggest
      ShowCheckPanel()
    end)
    row:Show()
  end
  for i = #items + 1, #checkPanel.rows do checkPanel.rows[i]:Hide() end
  checkPanel:Show()
  wb_AHSnipe_SelectTab(3)
end

-- While a check runs: Cancel on the left, the progress button narrower on the right.
local function CheckButtons(running)
  if not (settings and settings.checkBtn) then return end
  local b, c = settings.checkBtn, settings.cancelBtn
  b:ClearAllPoints()
  if running then
    c:Show()
    b:SetSize(174, 28)
    b:SetPoint("TOPLEFT", settings.pages[3], "TOPLEFT", 100, -340)
    wb_AHSnipe_SelectTab(3)
  else
    c:Hide()
    b:SetSize(258, 28)
    b:SetPoint("TOPLEFT", settings.pages[3], "TOPLEFT", 16, -340)
    b:SetText("Check prices")
  end
end

function wb_AHSnipe_CancelCheck()
  if not check then CheckButtons(false) return end
  L("check_cancel", { at = check.i or 0, of = check.list and #check.list or 0 })
  check = nil
  wb_AHSnipe_Checking = nil
  CheckButtons(false)
  msg("Price check cancelled.")
end

local CHECK_PCT = 70 -- default: suggested max = 70% of market

local function FinishCheck()
  local ratio = (DB.checkPct or CHECK_PCT) / 100
  for _, r in ipairs(check.items) do
    if r.market then r.suggest = math.max(1, math.floor(r.market * ratio)) end
    L("price_check", { item = r.id, market = r.market, cheapest = r.cheapest, listed = r.listed,
      now = DB.caps[r.id], suggest = r.suggest, ratio = math.floor(ratio * 100 + 0.5) })
  end
  lastCheck = { items = check.items, ratio = ratio, at = time() }
  DB.lastCheckAt = time()
  check = nil
  wb_AHSnipe_Checking = nil
  CheckButtons(false)
  ShowCheckPanel()
  msg("Price check done. Review the suggestions and Apply.")
end

local function StartList()
  local res = C_AuctionHouse.GetBrowseResults() or {}
  local list = {}
  for _, r in ipairs(res) do if r.itemKey then list[#list + 1] = r end end
  if #list == 0 then
    msg("Your favorites list is empty.")
    wb_AHSnipe_CancelCheck()
    return
  end
  check.list, check.i, check.waitFav = list, 0, nil
  L("check_start", { count = #list })
end

-- One click: load favorites if needed, then check every item on its own,
-- one search at a time, waiting for the AH between searches.
function wb_AHSnipe_Check()
  local ah = AH()
  if not ah then return end
  if check then return end -- already running; use Cancel to stop
  check = { items = {} }
  wb_AHSnipe_Checking = true
  CheckButtons(true)
  local onFavs = lastBrowse == "fav" and ah.BrowseResultsFrame and ah.BrowseResultsFrame:IsShown()
  if onFavs and #(C_AuctionHouse.GetBrowseResults() or {}) > 0 then
    StartList()
  else
    check.waitFav = true
    if settings and settings.checkBtn then settings.checkBtn:SetText("Loading favorites") end
    wb_AHSnipe_Favorites()
  end
end

local SORT = { { sortOrder = (Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }

local driver = CreateFrame("Frame")
local dt = 0
driver:SetScript("OnUpdate", function(_, el)
  dt = dt + el
  if dt < 0.05 then return end
  dt = 0
  if not check or check.waitFav or not check.list then return end
  if not AH() then wb_AHSnipe_CancelCheck() return end
  local now = GetTime()

  -- Waiting for the current item's listings.
  if check.cur and not check.cur.done then
    if now - check.cur.at < CHECK_TIMEOUT then return end
    check.items[#check.items + 1] = { id = check.cur.id } -- no answer: mark "none"
    check.cur.done = true
  end
  if Queued() or buying or not C_AuctionHouse.IsThrottledMessageSystemReady() then return end

  check.i = check.i + 1
  local r = check.list[check.i]
  if not r then FinishCheck() return end
  check.cur = { id = r.itemKey.itemID, key = r.itemKey, at = now }
  if settings and settings.checkBtn then
    settings.checkBtn:SetText(("Checking %d of %d"):format(check.i, #check.list))
  end
  L("check_open", { item = check.cur.id, n = check.i, of = #check.list })
  local ok = pcall(C_AuctionHouse.SendSearchQuery, r.itemKey, SORT, true)
  if not ok then
    check.items[#check.items + 1] = { id = check.cur.id }
    check.cur.done = true
  end
end)

local cf = CreateFrame("Frame")
cf:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
cf:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
cf:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
cf:RegisterEvent("ADDON_ACTION_BLOCKED")
cf:SetScript("OnEvent", function(_, e, a1)
  if not check then return end
  if e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    if check.waitFav and lastBrowse == "fav" then StartList() end
    return
  end
  if e == "ADDON_ACTION_BLOCKED" then
    if a1 == "wb_AHSnipe" then
      msg("|cffff5555The game blocked the automatic price check.|r Cancelled.")
      wb_AHSnipe_CancelCheck()
    end
    return
  end
  local cur = check.cur
  if not cur or cur.done then return end
  local market, cheapest, listed
  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" and a1 == cur.id then
    market, cheapest, listed = FloorFromCommodity(cur.id)
  elseif e == "ITEM_SEARCH_RESULTS_UPDATED" and a1 and a1.itemID == cur.id then
    market, cheapest, listed = FloorFromItem(a1)
  else
    return
  end
  if not market then return end -- empty first update; wait for the real list
  cur.done = true
  check.items[#check.items + 1] = { id = cur.id, market = market, cheapest = cheapest, listed = listed }
end)

-- Stale prices reminder --------------------------------------------------------
-- Each time you open the AH, if your last finished Check prices was 1+ hour
-- ago, it asks whether to check prices first. Until you answer, the Snipe key
-- won't buy.

local STALE_HOURS = 1
local staleAsked, staleAnswered = false, false

StaticPopupDialogs["WBAHSNIPE_STALE"] = {
  text = "%s\n\nCheck prices before sniping?",
  button1 = "Check prices",
  button2 = "Not now",
  OnAccept = function() staleAnswered = true; wb_AHSnipe_Check() end,
  OnCancel = function() staleAnswered = true end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function wb_AHSnipe_StalePending() return staleAsked and not staleAnswered end

function wb_AHSnipe_StaleBlock()
  if not staleAsked or staleAnswered then return false end
  if not StaticPopup_Visible("WBAHSNIPE_STALE") then
    StaticPopup_Show("WBAHSNIPE_STALE", wb_AHSnipe_StaleText or "Your max prices may be out of date.")
  end
  return true
end

local sf = CreateFrame("Frame")
sf:RegisterEvent("AUCTION_HOUSE_SHOW")
sf:SetScript("OnEvent", function()
  staleAsked, staleAnswered = false, false -- ask again on every AH visit
  if not DB then return end
  local last = DB.lastCheckAt
  local hours = last and (time() - last) / 3600
  if last and hours < STALE_HOURS then return end
  local ago
  if hours and hours < 2 then ago = math.floor(hours * 60) .. " minutes"
  elseif hours and hours < 48 then ago = math.floor(hours) .. " hours"
  elseif hours then ago = math.floor(hours / 24) .. " days" end
  wb_AHSnipe_StaleText = last
    and ("|cffffd100AH Snipe|r\nYour max prices were last checked |cffffd100%s|r ago."):format(ago)
    or "|cffffd100AH Snipe|r\nYou haven't run Check prices yet."
  staleAsked = true
  StaticPopup_Show("WBAHSNIPE_STALE", wb_AHSnipe_StaleText)
end)


-- Monospace chat font ---------------------------------------------------------
-- Puts every chat window in JetBrains Mono (bundled in fonts\mono.ttf) at
-- its current size, so table lines and everything else line up. /snipe mono
-- turns it on or off. Default: on.

local MONO = "Interface\\AddOns\\wb_AHSnipe\\fonts\\mono.ttf"
local origFont = {}

function wb_AHSnipe_ApplyMono()
  if not DB then return end
  local on = DB.monoChat ~= false
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local cf = _G["ChatFrame" .. i]
    if cf and cf.GetFont then
      local f, size, flags = cf:GetFont()
      if f and f ~= MONO then origFont[i] = { f, flags } end
      if on then
        cf:SetFont(MONO, size or 14, flags or "")
      elseif origFont[i] then
        cf:SetFont(origFont[i][1], size or 14, origFont[i][2] or "")
      end
    end
  end
end

local mf = CreateFrame("Frame")
mf:RegisterEvent("PLAYER_ENTERING_WORLD")
mf:SetScript("OnEvent", function()
  -- After Blizzard applies saved chat settings.
  C_Timer.After(1, wb_AHSnipe_ApplyMono)
end)
if FCF_SetChatWindowFontSize then
  hooksecurefunc("FCF_SetChatWindowFontSize", function() C_Timer.After(0, wb_AHSnipe_ApplyMono) end)
end


-- Own chat tab -----------------------------------------------------------------
-- Messages go to a dedicated "AH Snipe" chat tab (docked with General) that
-- shows nothing else. /snipe tab switches back to the main chat window.

local TAB_NAME = "AH Snipe"

local function FindTab()
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local name = GetChatWindowInfo(i)
    if name == TAB_NAME then return _G["ChatFrame" .. i] end
  end
end

function wb_AHSnipe_SetupTab()
  if not DB or DB.ownTab == false then OUT = DEFAULT_CHAT_FRAME return end
  local f = FindTab()
  if not f and FCF_OpenNewWindow then
    pcall(FCF_OpenNewWindow, TAB_NAME)
    f = FindTab()
    if f then
      -- Nothing but our own messages.
      if ChatFrame_RemoveAllMessageGroups then ChatFrame_RemoveAllMessageGroups(f) end
      if ChatFrame_RemoveAllChannels then ChatFrame_RemoveAllChannels(f) end
    end
  end
  OUT = f or DEFAULT_CHAT_FRAME
  if wb_AHSnipe_ApplyMono then wb_AHSnipe_ApplyMono() end
end

-- Which install is running (set by the installer; "dev" on the PC copy).
local function ShowBuild()
  msg("|cffaaaaaaInstalled:|r " .. tostring(wb_AHSnipe_Build or "unknown"))
end

local tf = CreateFrame("Frame")
tf:RegisterEvent("PLAYER_ENTERING_WORLD")
tf:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  C_Timer.After(2, function() wb_AHSnipe_SetupTab(); ShowBuild() end) -- after Blizzard restores chat windows
end)


-- /snipe tune ------------------------------------------------------------------
-- For each item: win rate and units won per try at each Buy % tested.
-- "Best" = the most units won per try (with at least MIN_TRIES tries), since a
-- small sure win and a big risky one are both worth something.
-- With Explore off each item uses its best automatically.

function wb_AHSnipe_Tune(apply)
  local tune = DB.tune or {}
  local ids = {}
  for id in pairs(tune) do ids[#ids + 1] = id end
  if #ids == 0 then
    msg("No Buy % data yet. Turn on |cffffd100Explore|r in the Setup tab and snipe as usual.")
    return
  end
  table.sort(ids, function(a, b)
    local function n(id) local t = 0 for _, r in pairs(tune[id]) do t = t + r.won + r.lost end return t end
    return n(a) > n(b)
  end)
  local function cell(t, n, right)
    t = tostring(t or "")
    local gap = string.rep(" ", math.max(0, n - Visible(t)))
    return right and (gap .. t) or (t .. gap)
  end
  local applied = 0
  for _, id in ipairs(ids) do
    local t = tune[id]
    local best, bestEV, untested = nil, -1, {}
    local parts = {}
    for _, p in ipairs(PCTS) do
      local r = t[p]
      local n = r and (r.won + r.lost) or 0
      if n == 0 then
        untested[#untested + 1] = p .. "%"
        parts[#parts + 1] = cell("|cff666666" .. p .. "%  -|r", 16)
      else
        local win = math.floor(100 * r.won / n + 0.5)
        local ev = r.units / n
        if n >= MIN_TRIES and ev > bestEV then best, bestEV = p, ev end
        local color = win >= 60 and "|cff55ff55" or win >= 30 and "|cffffd100" or "|cffff5555"
        parts[#parts + 1] = cell(p .. "% " .. color .. win .. "%|r|cffaaaaaa/" .. n .. "|r", 16)
      end
    end
    msg(cell(TruncateChars(ItemText(id), 20), 20) .. " " .. table.concat(parts, ""))
    local cur = PickPct(id)
    local line
    if best then
      line = ("    best |cffffd100%d%%|r (%.1f units per try)"):format(best, bestEV)
      if apply then
        DB.itemPct = DB.itemPct or {}
        DB.itemPct[id] = best
        applied = applied + 1
        line = line .. "  |cff55ff55saved|r"
      elseif best ~= cur then
        line = line .. ("  |cffaaaaaa(using %d%%)|r"):format(cur)
      end
    else
      line = "    |cffaaaaaanot enough tries yet (need " .. MIN_TRIES .. " at one Buy %)|r"
    end
    if #untested > 0 then line = line .. "  |cffaaaaaatry next: " .. table.concat(untested, ", ") .. "|r" end
    msg(line)
  end
  -- Best hours overall
  local hours = {}
  for h, r in pairs(DB.hourly or {}) do
    local n = r.won + r.lost
    if n >= 5 then hours[#hours + 1] = { h = h, win = r.won / n, n = n } end
  end
  table.sort(hours, function(a, b) return a.win > b.win end)
  if #hours > 0 then
    local hs = {}
    for k = 1, math.min(3, #hours) do
      local e = hours[k]
      hs[#hs + 1] = ("%s %d%%"):format(date("%I%p", time({ year = 2000, month = 1, day = 1, hour = e.h })):gsub("^0", ""):lower(), math.floor(e.win * 100 + 0.5))
    end
    msg("|cffaaaaaaBest hours so far:|r " .. table.concat(hs, ", "))
  end
  if apply then
    msg(applied > 0 and ("Saved Buy % for " .. applied .. " items.") or "Nothing to save yet.")
  elseif not DB.explore then
    msg("|cffaaaaaaExplore is off: each item uses its best, or your general Buy % until it has one.|r")
  end
end


-- Buy % results window ------------------------------------------------------------
-- The /snipe tune report as a table: each item's win rate and tries at each
-- Buy %, the best one (most units won per try, 4+ tries), what it uses now,
-- and buttons to save the best.

local tuneWin

local function TuneData()
  local out = {}
  for id, t in pairs(DB.tune or {}) do
    local row = { id = id, cells = {}, n = 0, bestEV = -1 }
    for k, p in ipairs(PCTS) do
      local r = t[p]
      local n = r and (r.won + r.lost) or 0
      local c = { p = p, n = n }
      if n > 0 then
        c.win = math.floor(100 * r.won / n + 0.5)
        c.ev = r.units / n
        if n >= MIN_TRIES and c.ev > row.bestEV then row.best, row.bestEV = p, c.ev end
      end
      row.cells[k] = c
      row.n = row.n + n
    end
    out[#out + 1] = row
  end
  table.sort(out, function(a, b) return a.n > b.n end)
  return out
end

local function Using(id) return SavedPct(id) end

function wb_AHSnipe_TuneApplyAll()
  local n = 0
  for _, row in ipairs(TuneData()) do
    if row.best then
      DB.itemPct = DB.itemPct or {}
      DB.itemPct[row.id] = row.best
      n = n + 1
    end
  end
  msg(n > 0 and ("Saved the best Buy % for " .. n .. " items.") or "Not enough tries yet to save anything.")
end

local PCT_X, BEST_X, USING_X = 176, 480, 540

local function RenderTune()
  if not DB or not settings then return end
  if not tuneWin then
    tuneWin = CreateFrame("Frame", nil, settings.pages[4])
    tuneWin:SetPoint("TOPLEFT", settings, "TOPLEFT", 0, -24)
    tuneWin:SetPoint("BOTTOMRIGHT", settings, "BOTTOMRIGHT", 0, 0)

    local function Head(text, x)
      local fs = tuneWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      fs:SetPoint("TOPLEFT", x, -12)
      fs:SetText(text)
    end
    Head("Item", 16)
    for k, p in ipairs(PCTS) do Head(p .. "%", PCT_X + (k - 1) * 60) end
    Head("Best", BEST_X)
    Head("Using", USING_X)

    tuneWin.note = tuneWin:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tuneWin.note:SetJustifyH("LEFT")
    tuneWin.note:SetWidth(680)
    tuneWin.note:SetWordWrap(true)
    tuneWin.hours = tuneWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tuneWin.hours:SetJustifyH("LEFT")

    tuneWin.rows = {}
  end

  local data = TuneData()
  local n = math.max(1, #data)
  settings:SetSize(720, 136 + n * 22)

  for i, row in ipairs(data) do
    local r = tuneWin.rows[i]
    if not r then
      r = CreateFrame("Frame", nil, tuneWin)
      r:SetSize(700, 22)
      r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.name:SetPoint("LEFT", 16, 0); r.name:SetWidth(150); r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
      r.cells = {}
      for k = 1, #PCTS do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", PCT_X + (k - 1) * 60, 0)
        r.cells[k] = fs
      end
      r.best = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.best:SetPoint("LEFT", BEST_X, 0)
      r.using = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); r.using:SetPoint("LEFT", USING_X, 0)
      r.set = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.set:SetSize(84, 20); r.set:SetPoint("RIGHT", -8, 0)
      r.set:SetScript("OnLeave", GameTooltip_Hide)
      tuneWin.rows[i] = r
    end
    r:SetPoint("TOPLEFT", 0, -30 - (i - 1) * 22)
    r.name:SetText(ItemText(row.id))
    local nextUp = DB.explore and PickPct(row.id)
    for k, c in ipairs(row.cells) do
      local fs = r.cells[k]
      if c.n == 0 then
        fs:SetText("|cff555555-|r")
      else
        local color = c.win >= 60 and "|cff55ff55" or c.win >= 30 and "|cffffd100" or "|cffff5555"
        local mark = (c.p == row.best) and "|cffffd100*|r" or ""
        fs:SetText(color .. c.win .. "%|r |cff888888" .. c.n .. "|r" .. mark)
      end
      if DB.explore and c.p == nextUp then fs:SetText("|cff55ff55>|r" .. fs:GetText()) end
    end
    local using, why = Using(row.id)
    r.best:SetText(row.best and ("|cffffd100" .. row.best .. "%|r") or "|cff666666-|r")
    r.using:SetText(DB.explore and ("|cff55ff55" .. nextUp .. "% next|r")
      or (using .. "%" .. (why == "general" and " |cff888888(all)|r" or why == "item" and " |cff888888(set)|r" or "")))
    r.set:Hide()
    if row.best then r.set:SetText("Use " .. row.best .. "%") end
    r.set:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText("Use " .. (row.best or "") .. "% for this item")
      GameTooltip:AddLine("Saves " .. (row.best or "") .. "% as this item's own Buy %. Other items keep theirs.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    r.set:SetScript("OnClick", function()
      DB.itemPct = DB.itemPct or {}
      DB.itemPct[row.id] = row.best
      RenderTune()
    end)
    r:Show()
  end
  for i = #data + 1, #tuneWin.rows do tuneWin.rows[i]:Hide() end

  local y = -30 - n * 22 - 10
  tuneWin.note:ClearAllPoints()
  tuneWin.note:SetPoint("TOPLEFT", 16, y)
  if #data == 0 then
    tuneWin.note:SetText("No Buy % data yet. Turn on |cffffd100Explore|r in the Setup tab and snipe as usual.")
  else
    tuneWin.note:SetText("Each cell: win rate, then tries.  |cffffd100*|r = best (most units won per try, "
      .. MIN_TRIES .. "+ tries).\nUsing = the Buy % this item uses now: its best, or (all) your general Buy % until it has one.  |cff55ff55>|r = the Buy % Explore tries next.\n"
      .. (DB.explore and ("|cff55ff55Explore is on:|r it tries each Buy % " .. MIN_TRIES .. " times, then sticks to the best and tests another 1 try in " .. EXPLORE_EVERY .. ".")
                     or "Explore is off: each item uses its best. Nothing new is tested."))
  end

  local hours = {}
  for h, hr in pairs(DB.hourly or {}) do
    local tot = hr.won + hr.lost
    if tot >= 5 then hours[#hours + 1] = { h = h, win = hr.won / tot } end
  end
  table.sort(hours, function(a, b) return a.win > b.win end)
  local hs = {}
  for k = 1, math.min(4, #hours) do
    local e = hours[k]
    local label = date("%I%p", time({ year = 2000, month = 1, day = 1, hour = e.h })):gsub("^0", ""):lower()
    hs[#hs + 1] = label .. " " .. math.floor(e.win * 100 + 0.5) .. "%"
  end
  tuneWin.hours:ClearAllPoints()
  tuneWin.hours:SetPoint("TOPLEFT", 16, y - 46)
  tuneWin.hours:SetText(#hs > 0 and ("|cffaaaaaaBest hours:|r " .. table.concat(hs, "   ")) or "")
end

-- Tabs: 1 = Snipe, 2 = Sell, 3 = Setup, 4 = Buy % ---------------------------------
-- Called after each buy result so the Buy % tab updates while it's open.
function wb_AHSnipe_TuneRefresh()
  if tuneWin and tuneWin:IsVisible() then RenderTune() end
end

function wb_AHSnipe_SelectTab(i)
  if not settings then msg("Open the auction house first.") return end
  settings.tab = i
  for k, pg in ipairs(settings.pages) do pg:SetShown(k == i) end
  if i == 4 then
    RenderTune()
    tuneWin:Show()
  else
    wb_AHSnipe_Layout()
  end
  if PanelTemplates_SetTab then pcall(PanelTemplates_SetTab, settings, i) end
end

function wb_AHSnipe_TuneWindow() wb_AHSnipe_SelectTab(4) end

-- Bought vs selling ---------------------------------------------------------
-- On the AH's Sell tab, compare what you paid for the item in the sell slot
-- (this session and all-time) with the price you're about to post at, after
-- the auction house's 5% cut.

local AH_CUT = AH_CUT_PCT / 100
local sellPanel

local function SellFrame()
  local ah = AH()
  if not ah then return end
  for _, name in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
    local f = ah[name]
    if f and f:IsShown() then return f end
  end
end

local function SellItemID(f)
  local loc = (f.GetItem and select(2, pcall(f.GetItem, f))) or f.itemLocation
  if type(loc) ~= "table" then return end
  local ok, id = pcall(C_Item.GetItemID, loc)
  return ok and id or nil
end

local function SellPrice(f)
  local p = f.PriceInput
  if p and p.GetAmount then
    local ok, v = pcall(p.GetAmount, p)
    if ok and v and v > 0 then return v end
  end
end

local function SellQty(f)
  local q = f.QuantityInput
  if q and q.GetQuantity then
    local ok, v = pcall(q.GetQuantity, q)
    if ok and v and v > 0 then return v end
  end
  return 1
end

local function BuildSellPanel()
  sellPanel = settings.pages[2]
  -- Each line sits under the one before it, so wrapped text pushes the rest down.
  local last
  local function Line(font, gap)
    local fs = sellPanel:CreateFontString(nil, "OVERLAY", font)
    if last then fs:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -gap)
    else fs:SetPoint("TOPLEFT", sellPanel, "TOPLEFT", 14, -32) end
    fs:SetJustifyH("LEFT")
    fs:SetWidth(262)
    last = fs
    return fs
  end
  local function Labeled(label)
    sellPanel.labels = sellPanel.labels or {}
    local l = Line("GameFontNormalSmall", 10)
    l:SetText(label)
    tinsert(sellPanel.labels, l)
    return Line("GameFontHighlight", 2)
  end
  sellPanel.item = Line("GameFontHighlightLarge", 0)
  sellPanel.session = Labeled("Bought this session")
  sellPanel.alltime = Labeled("Bought all-time")
  sellPanel.realized = Labeled("Sold so far")
  sellPanel.selling = Labeled("Selling at")
  sellPanel.profit = Line("GameFontHighlightLarge", 12)
end

local function Avg(r) return r and r.units and r.units > 0 and (r.spent / r.units) or nil end

function wb_AHSnipe_SellShown() return SellFrame() ~= nil end

local function UpdateSellPanel()
  if not settings then return end
  if not sellPanel then BuildSellPanel() end
  local f = SellFrame()
  local id = f and SellItemID(f)
  for _, l in ipairs(sellPanel.labels) do l:SetShown(id and true or false) end
  if not id then
    sellPanel.item:SetText("|cffaaaaaaPut an item in the AH's Sell slot to compare what you paid with your price.|r")
    for _, k in ipairs({ "session", "alltime", "realized", "selling", "profit" }) do sellPanel[k]:SetText("") end
  else
    local s, a = session[id], DB.stats and DB.stats[id]
    local sAvg, aAvg = Avg(s), Avg(a)
    sellPanel.item:SetText(ItemText(id))
    sellPanel.session:SetText(sAvg and (s.units .. " at " .. Coins(sAvg) .. " avg  |cffaaaaaa(" .. Coins(s.spent) .. ")|r")
      or "|cff888888none|r")
    sellPanel.alltime:SetText(aAvg and (a.units .. " at " .. Coins(aAvg) .. " avg") or "|cff888888none|r")
    sellPanel.realized:SetText((wb_AHSnipe_ProfitLine(id):gsub("^|cffaaaaaaProfit:|r ", "")))

    local price, qty = SellPrice(f), SellQty(f)
    if not price then
      sellPanel.selling:SetText("|cff888888set a price|r")
      sellPanel.profit:SetText("")
    else
      local net = price * (1 - AH_CUT)
      sellPanel.selling:SetText(Coins(price) .. " each  |cffaaaaaa(you get " .. Coins(math.floor(net)) .. " after the 5% cut)|r")
      local cost = sAvg or aAvg
      if not cost then
        sellPanel.profit:SetText("|cffaaaaaaNo buys tracked for this item.|r")
      else
        local each = net - cost
        local pct = math.floor(100 * each / cost + 0.5)
        local color = each >= 0 and "|cff55ff55" or "|cffff5555"
        local sign = each >= 0 and "+" or "-"
        local per = sign .. Coins(math.floor(math.abs(each)))
        local tot = sign .. Coins(math.floor(math.abs(each) * qty))
        sellPanel.profit:SetText(color .. per .. " each (" .. sign .. math.abs(pct) .. "%)|r"
          .. (qty > 1 and ("  |cffaaaaaax" .. qty .. " =|r " .. color .. tot .. "|r") or "")
          .. ((not sAvg) and "\n|cff888888vs all-time avg|r" or ""))
      end
    end
  end
  -- Grow the window to fit whatever wrapped.
  local top, bottom = settings:GetTop(), (id and sellPanel.profit or sellPanel.item):GetBottom()
  if top and bottom then
    settings.sellH = math.max(140, math.floor(top - bottom + 18))
    if settings.tab == 2 then settings:SetHeight(settings.sellH) end
  end
end
wb_AHSnipe_UpdateSell = UpdateSellPanel
