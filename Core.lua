-- wb_AHSnipe: refresh + buy keybinds for the stock auction house.
-- Refresh never sends a new search while the last one is unanswered,
-- which is what wedges the AH until a relog.

BINDING_HEADER_WBAHSNIPE = "wb_AH Snipe"
BINDING_NAME_WBAHSNIPE_REFRESH = "Refresh AH"
BINDING_NAME_WBAHSNIPE_FAVS = "Refresh favorites"
BINDING_NAME_WBAHSNIPE_CHECK = "Check prices (one favorite per press)"
BINDING_NAME_WBAHSNIPE_ROAM = "Toggle jumping in and out of favorites"
BINDING_NAME_WBAHSNIPE_BUY = "Snipe (one button: refresh, quote, buy)"

local MIN_GAP = 0.6      -- seconds between searches
local STALE_GUARD = 8    -- forget our own pending flag after this long
local WARN_AFTER = 5     -- warn if the AH hasn't answered in this long
local QUOTE_TTL = 10     -- seconds a commodity price quote is trusted
local MIN_QTY = 2        -- commodities: skip unless at least this many are under your max
local BUY_PCT = 50       -- commodities: ask for this % of the cheap units, leaving room if others buy some

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
local overCount = 0
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
  { w = 170, ch = 22, trunc = true },-- item (long names are shortened)
  { w = 110, ch = 12, right = true },-- price
  { w = 150, ch = 18 },               -- details ("(was …)", "(… each)", why it failed)
  { w = 120, ch = 16 },               -- your max
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
        local sep = (i >= 4) and "   " or " "
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
  local G, S, C = "|cffffd100g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
  if g > 0 then return ("%d%s %02d%s %02d%s"):format(g, G, sv, S, cv, C) end
  if sv > 0 then return ("%d%s %02d%s"):format(sv, S, cv, C) end
  return ("%d%s"):format(cv, C)
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
local function Tally(id, won, qty, total)
  if not id or not DB then return end
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
end

-- "60% 3/5" for this session, colored by how often you win.
local function WinCell(id, dim)
  local r = id and session[id]
  if not r or r.won + r.lost == 0 then return "" end
  local n = r.won + r.lost
  local pct = math.floor(100 * r.won / n + 0.5)
  local color = pct >= 60 and "|cff55ff55" or pct >= 30 and "|cffffd100" or "|cffff5555"
  local t = color .. pct .. "%|r |cffaaaaaa" .. r.won .. "/" .. n .. "|r"
  return dim and Dim(t) or t
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
  Row({ "|cffff5555Failed|r", qty and ("|cffff5555" .. qty .. "|r") or "", item and Dim(ItemText(item)) or "", "", GREY .. why .. "|r", MaxCell(item, true), WinCell(item) })
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

local function Cap(itemID)
  return (itemID and DB.caps[itemID]) or DB.default
end
wb_AHSnipe_CapOf = Cap

local function Clear()
  pending, warned = false, false
end

-- Refresh ----------------------------------------------------------------

function wb_AHSnipe_Refresh(fromBuy)
  local ah = AH()
  if not ah then return end
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
    local cap = id and Cap(id)
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
local function OverMax(itemID)
  overCount = overCount + 1
  if overCount >= OVER_MAX_BACK and lastBrowse == "fav" and DB.roam ~= false then
    L("auto_back", { item = itemID, presses = overCount })
    overCount = 0
    wb_AHSnipe_Favorites()
    return true
  end
end

local function BuyItem(frame)
  local key = KeyOf(frame)
  if not key then msg("No item open.") return end

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
  if not cap then SayOnce(key.itemID, "nomax", "No max set for " .. ItemText(key.itemID) .. ". Type one in the box at the bottom right.") return end
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
  local cap = Cap(itemID)
  if not cap then SayOnce(itemID, "nomax", "No max set for " .. ItemText(itemID) .. ". Type one (per unit) in the box at the bottom right.") return end

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

  -- First press: count everything under the max.
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

  local minQty = DB.minQty or MIN_QTY
  if qty < minQty then
    overCount = 0 -- bait under max: stay parked
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "under_min", item = itemID, qty = qty, min = minQty, listAge = listAge, sent = sent and 1 or 0 })
    return
  end

  -- Ask for only part of the cheap units. If another buyer takes a few
  -- before you confirm, there are still enough left at the quoted price.
  local avail = qty
  local pct = DB.buyPct or BUY_PCT
  local want = math.max(1, math.ceil(avail * pct / 100))
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

  overCount = 0
  quote = { itemID = itemID, qty = qty, maxTotal = qty * cap, at = now, est = total }
  L("quote_start", { item = itemID, qty = qty, avail = avail, pct = pct, est = total, cap = cap, listings = n, listAge = listAge })
  C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
end

local lastPressAt = 0
function wb_AHSnipe_Buy()
  local ah = AH()
  if not ah then return end
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
    if lastBrowse == "fav" and DB.roam ~= false then
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
  "AUCTION_HOUSE_CLOSED",
  "COMMODITY_PRICE_UPDATED",
  "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "UI_ERROR_MESSAGE",
}) do pcall(f.RegisterEvent, f, e) end

f:SetScript("OnEvent", function(_, e, arg1, arg2)
  if e == "ADDON_LOADED" then
    if arg1 == "wb_AHSnipe" then
      wb_AHSnipeDB = wb_AHSnipeDB or {}
      wb_AHSnipeDB.caps = wb_AHSnipeDB.caps or {}
      DB = wb_AHSnipeDB
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
      local each = b.total and b.qty > 0 and math.floor(b.total / b.qty + 0.5)
      Tally(b.item, true, b.qty, b.total)
      Row({ "|cffffd100Bought|r", "|cffffd100" .. b.qty .. "|r", ItemText(b.item), Coins(b.total or 0),
        each and ("|cffaaaaaa(|r" .. Coins(each) .. " |cffaaaaaaeach)|r") or "", MaxCell(b.item), WinCell(b.item) })
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
      Row({ "|cffffd100Bought|r", "|cffffd1001|r", ItemText(bidding.item), Coins(bidding.price), "", MaxCell(bidding.item), WinCell(bidding.item) })
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
  elseif cmd == "stats" then
    wb_AHSnipe_Stats(val == "all")
  elseif cmd == "tab" then
    DB.ownTab = not (DB.ownTab ~= false)
    wb_AHSnipe_SetupTab()
    msg("Own chat tab " .. (DB.ownTab ~= false and "on." or "off. Messages go to your main chat."))
  elseif cmd == "mono" then
    DB.monoChat = not (DB.monoChat ~= false)
    wb_AHSnipe_ApplyMono()
    msg("Monospace chat " .. (DB.monoChat ~= false and "on." or "off."))
  elseif cmd == "status" then
    msg("AH ready: " .. tostring(C_AuctionHouse.IsThrottledMessageSystemReady()) .. ", waiting on reply: " .. tostring(pending))
  else
    msg("/snipe max <gold>  (max for the open item, or default if none is open)")
    msg("/snipe default <gold>  |  /snipe clear  |  /snipe status")
    msg("Default max: " .. (DB.default and money(DB.default) or "none"))
  end
end

-- Max price box ----------------------------------------------------------
-- Sits at the bottom right of the AH. Shows the saved max for the open item
-- (or your default when no item is open). Type a gold amount and press Enter.

local box, label
local sBox, cBox -- silver and copper boxes (box is gold)

local function GoldText(c)
  if not c then return "" end
  local s = string.format("%.4f", c / 10000):gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function SaveBox(quiet)
  local id = OpenItemID()
  local g = strtrim(box:GetText() or "")
  local sv = strtrim(sBox:GetText() or "")
  local cv = strtrim(cBox:GetText() or "")
  if g == "" and sv == "" and cv == "" then
    if id then DB.caps[id] = nil; msg("Cleared the max for this item.")
    else DB.default = nil; msg("Cleared the default max.") end
    return
  end
  local c = (tonumber(g) or 0) * 10000 + (tonumber(sv) or 0) * 100 + (tonumber(cv) or 0)
  if c <= 0 then msg("Max must be more than 0.") return end
  if id then DB.caps[id] = c else DB.default = c end
  if not quiet then msg("Max " .. (id and ("for " .. ItemText(id)) or "default") .. ": " .. money(c)) end
end

function wb_AHSnipe_ToggleRoam()
  DB.roam = not (DB.roam ~= false)
  if settings and settings.roam then settings.roam:SetChecked(DB.roam) end
  L("roam", { on = DB.roam and 1 or 0 })
  msg("Jump in and out of favorites: " .. (DB.roam and "|cff55ff55on|r" or "|cffff5555off|r (staying put)"))
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
  e:SetJustifyH("RIGHT")
  if fontSize then
    local f, _, flags = e:GetFont()
    e:SetFont(f or STANDARD_TEXT_FONT, fontSize, flags or "")
  end
  e:SetTextInsets(10, 12, 0, 0)
  if numeric then e:SetNumeric(true) end
  return e
end

-- Up/down arrows to the right of a box. Click = 1, Shift-click = 10.
local function Stepper(parent, e, onStep)
  local function Btn(dir)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22)
    local base = "Interface\\ChatFrame\\UI-ChatIcon-Scroll" .. (dir > 0 and "Up" or "Down")
    b:SetNormalTexture(base .. "-Up")
    b:SetPushedTexture(base .. "-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b:SetScript("OnClick", function() onStep(dir * (IsShiftKeyDown() and 10 or 1)) end)
    return b
  end
  local up, down = Btn(1), Btn(-1)
  up:SetPoint("BOTTOMLEFT", e, "RIGHT", 2, 1)
  down:SetPoint("TOPLEFT", e, "RIGHT", 2, -1)
  return up
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

local function BuildBox()
  if box or not AuctionHouseFrame then return end

  -- Settings window, to the right of the AH.
  settings = AHFrame("wb_AHSnipeSettings", AuctionHouseFrame, "AH Snipe")
  settings:SetSize(290, 236)
  settings:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)

  local function Row(text, y)
    local fs = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 14, y)
    fs:SetText(text)
    return fs
  end

  -- Max price
  local maxRow = Row("Max price", -32)
  label = settings:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  label:SetPoint("LEFT", maxRow, "RIGHT", 8, 0)

  -- Max price, styled like the AH's Sell screen: number on the left, coin
  -- icon inside on the right. Enter in any box saves; Tab moves between them.
    local coins = {
      { key = "g", tex = "Interface\\MoneyFrame\\UI-GoldIcon" },
      { key = "s", tex = "Interface\\MoneyFrame\\UI-SilverIcon" },
      { key = "c", tex = "Interface\\MoneyFrame\\UI-CopperIcon" },
    }
    local boxes = {}
    for k, coin in ipairs(coins) do
      -- Gold can run to 5 digits; silver and copper never pass 2.
      local w = coin.key == "g" and 96 or 56
      local x = coin.key == "g" and 16 or coin.key == "s" and 124 or 192
      local e = BigBox(settings, "wb_AHSnipeMax" .. coin.key, w, true, 36, 18)
      e:SetMaxLetters(coin.key == "g" and 5 or 2)
      e:SetJustifyH("LEFT")
      e:SetTextInsets(8, 24, 0, 0)
      e:SetPoint("TOPLEFT", settings, "TOPLEFT", x, -48)
      local icon = e:CreateTexture(nil, "OVERLAY")
      icon:SetSize(14, 14)
      icon:SetTexture(coin.tex)
      icon:SetPoint("RIGHT", e, "RIGHT", -8, 0)
      e:SetScript("OnEnterPressed", function(self) SaveBox(); self:ClearFocus() end)
      e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
      boxes[k] = e
    end
    for k, e in ipairs(boxes) do
      e:SetScript("OnTabPressed", function() boxes[k % 3 + 1]:SetFocus() end)
    end
    box, sBox, cBox = boxes[1], boxes[2], boxes[3]

  -- Min quantity (commodities)
  Row("Min qty", -96)
  local minBox = BigBox(settings, "wb_AHSnipeMinBox", 64, true, 36, 18)
  minBox:SetJustifyH("LEFT")
  minBox:SetTextInsets(8, 8, 0, 0)
  minBox:SetMaxLetters(4)
  minBox:SetPoint("TOPLEFT", settings, "TOPLEFT", 16, -112)
  minBox:SetText(tostring(DB.minQty or MIN_QTY))
  local function SaveMin(self, quiet)
    local n = tonumber(self:GetText())
    if n and n >= 1 then
      DB.minQty = n
      if not quiet then msg("Min to buy (commodities): " .. n) end
    end
    self:SetText(tostring(DB.minQty or MIN_QTY))
    self:ClearFocus()
  end
  minBox:SetScript("OnEnterPressed", SaveMin)
  minBox:SetScript("OnEscapePressed", function(self) self:SetText(tostring(DB.minQty or MIN_QTY)); self:ClearFocus() end)

  -- Buy %: share of the cheap units each buy asks for
  -- Same line as Min qty, lined up with the silver box above.
  local pctLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  pctLabel:SetPoint("TOPLEFT", settings, "TOPLEFT", 124, -96)
  pctLabel:SetText("Buy %")
  local pctBox = BigBox(settings, "wb_AHSnipePctBox", 64, true, 36, 18)
  pctBox:SetJustifyH("LEFT")
  pctBox:SetTextInsets(8, 8, 0, 0)
  pctBox:SetPoint("TOPLEFT", settings, "TOPLEFT", 124, -112)
  pctBox:SetMaxLetters(3)
  pctBox:SetText(tostring(DB.buyPct or BUY_PCT))
  local function SavePct(self, quiet)
    local n = tonumber(self:GetText())
    if n and n >= 1 and n <= 100 then
      DB.buyPct = n
      if not quiet then msg("Each buy asks for " .. n .. "% of the cheap units.") end
    end
    self:SetText(tostring(DB.buyPct or BUY_PCT))
    self:ClearFocus()
  end
  pctBox:SetScript("OnEnterPressed", SavePct)
  pctBox:SetScript("OnEscapePressed", function(self) self:SetText(tostring(DB.buyPct or BUY_PCT)); self:ClearFocus() end)

  local roam = CreateFrame("CheckButton", "wb_AHSnipeRoam", settings, "UICheckButtonTemplate")
  roam:SetSize(28, 28)
  roam:SetPoint("TOPLEFT", settings, "TOPLEFT", 12, -158)
  local roamText = roam:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  roamText:SetPoint("LEFT", roam, "RIGHT", 4, 0)
  roamText:SetText("Jump in and out of favorites")
  roam:SetChecked(DB.roam ~= false)
  roam:SetScript("OnClick", function(self)
    DB.roam = self:GetChecked() and true or false
    L("roam", { on = DB.roam and 1 or 0 })
  end)
  settings.roam = roam

  local checkBtn = CreateFrame("Button", "wb_AHSnipeCheckButton", settings, "UIPanelButtonTemplate")
  checkBtn:SetSize(258, 28)
  checkBtn:SetPoint("BOTTOM", settings, "BOTTOM", 0, 10)
  checkBtn:SetText("Check prices")
  checkBtn:SetScript("OnClick", function() wb_AHSnipe_Check() end)
  settings.checkBtn = checkBtn

  local cancelBtn = CreateFrame("Button", "wb_AHSnipeCancelCheck", settings, "UIPanelButtonTemplate")
  cancelBtn:SetSize(80, 28)
  cancelBtn:SetPoint("BOTTOMLEFT", settings, "BOTTOMLEFT", 16, 10)
  cancelBtn:SetText("Cancel")
  cancelBtn:SetScript("OnClick", function() wb_AHSnipe_CancelCheck() end)
  cancelBtn:Hide()
  settings.cancelBtn = cancelBtn

  minBox:SetTextColor(1, 1, 1)
  pctBox:SetTextColor(1, 1, 1)
  local t = 0
  box:SetScript("OnUpdate", function(self, el)
    t = t + el
    if t < 0.25 then return end
    t = 0
    if not minBox:HasFocus() then minBox:SetText(tostring(DB.minQty or MIN_QTY)) end
    if not pctBox:HasFocus() then pctBox:SetText(tostring(DB.buyPct or BUY_PCT)) end
    if self:HasFocus() or sBox:HasFocus() or cBox:HasFocus() then return end
    local id = OpenItemID()
    local saved = id and DB.caps[id]
    label:SetText(id and (saved and "for this item" or "using default") or "default for all items")
    local v = saved or DB.default
    if v then
      local g, sv, cv = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
      self:SetText(tostring(g))
      sBox:SetText(tostring(sv))
      cBox:SetText(tostring(cv))
    else
      self:SetText(""); sBox:SetText(""); cBox:SetText("")
    end
  end)
end

local ui = CreateFrame("Frame")
ui:RegisterEvent("AUCTION_HOUSE_SHOW")
ui:SetScript("OnEvent", function() BuildBox(); HookSearchButtons() end)


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
        if pct > 0 then
          -- Price went up: not actionable, so keep it quiet.
          Row({ tag, "", Dim(ItemText(id)), Dim(Coins(price)), Dim("(was " .. Coins(old) .. ")"), MaxCell(id, true) })
        else
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

local function ShowCheckPanel()
  if not lastCheck then return end
  if not checkPanel then
    checkPanel = AHFrame("wb_AHSnipeCheckPanel", AuctionHouseFrame, "Price check")
    checkPanel.title = checkPanel.titleFS
    checkPanel.note = checkPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    checkPanel.note:SetPoint("TOP", 0, -26)
    local heads = { { "Item", 12 }, { "Market", 140 }, { "Now", 220 }, { "Suggest", 300 } }
    for _, h in ipairs(heads) do
      local fs = checkPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      fs:SetPoint("TOPLEFT", h[2], -46)
      fs:SetText(h[1])
    end
    checkPanel.rows = {}
    local all = CreateFrame("Button", nil, checkPanel, "UIPanelButtonTemplate")
    all:SetSize(120, 24); all:SetPoint("BOTTOMLEFT", 12, 10); all:SetText("Apply all")
    all:SetScript("OnClick", function()
      local n = 0
      for _, r in ipairs(lastCheck.items) do
        if r.suggest then DB.caps[r.id] = r.suggest; n = n + 1 end
      end
      msg("Set " .. n .. " max prices from the price check.")
      ShowCheckPanel()
    end)
    local close = CreateFrame("Button", nil, checkPanel, "UIPanelButtonTemplate")
    close:SetSize(80, 24); close:SetPoint("BOTTOMRIGHT", -12, 10); close:SetText("Close")
    close:SetScript("OnClick", function() checkPanel:Hide() end)
  end

  local items = lastCheck.items
  checkPanel:ClearAllPoints()
  if settings then checkPanel:SetPoint("TOPLEFT", settings, "BOTTOMLEFT", 0, -6)
  else checkPanel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, -30) end
  checkPanel:SetSize(420, 100 + #items * 20)
  checkPanel.title:SetText("Price check: " .. #items .. " favorites")
  checkPanel.note:SetText(("Suggest = %d%% of market (%s)"):format(math.floor(lastCheck.ratio * 100 + 0.5),
    lastCheck.learned and "your usual ratio" or "default"))

  for i, r in ipairs(items) do
    local row = checkPanel.rows[i]
    if not row then
      row = CreateFrame("Frame", nil, checkPanel)
      row:SetSize(400, 20)
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", 12, 0); row.name:SetWidth(124); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
      row.market = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.market:SetPoint("LEFT", 140, 0)
      row.now = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.now:SetPoint("LEFT", 220, 0)
      row.suggest = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.suggest:SetPoint("LEFT", 300, 0)
      row.apply = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
      row.apply:SetSize(40, 18); row.apply:SetPoint("RIGHT", -4, 0); row.apply:SetText("Set")
      checkPanel.rows[i] = row
    end
    row:SetPoint("TOPLEFT", 0, -60 - (i - 1) * 20)
    row.name:SetText(ItemText(r.id))
    row.market:SetText(r.market and money(r.market) or "|cff888888none|r")
    local cur = DB.caps[r.id]
    row.now:SetText(cur and money(cur) or "|cff888888none|r")
    row.suggest:SetText(r.suggest and money(r.suggest) or "")
    row.apply:SetShown(r.suggest and cur ~= r.suggest or false)
    row.apply:SetScript("OnClick", function()
      DB.caps[r.id] = r.suggest
      ShowCheckPanel()
    end)
    row:Show()
  end
  for i = #items + 1, #checkPanel.rows do checkPanel.rows[i]:Hide() end
  checkPanel:Show()
end

-- While a check runs: Cancel on the left, the progress button narrower on the right.
local function CheckButtons(running)
  if not (settings and settings.checkBtn) then return end
  local b, c = settings.checkBtn, settings.cancelBtn
  b:ClearAllPoints()
  if running then
    c:Show()
    b:SetSize(170, 28)
    b:SetPoint("BOTTOMRIGHT", settings, "BOTTOMRIGHT", -16, 10)
  else
    c:Hide()
    b:SetSize(258, 28)
    b:SetPoint("BOTTOM", settings, "BOTTOM", 0, 10)
    b:SetText("Check prices")
  end
end

function wb_AHSnipe_CancelCheck()
  if not check then CheckButtons(false) return end
  L("check_cancel", { at = check.i, of = #check.list })
  check = nil
  CheckButtons(false)
  msg("Price check cancelled.")
end

local function FinishCheck()
  local ratios = {}
  for _, r in ipairs(check.items) do
    local cur = DB.caps[r.id]
    if cur and r.market and r.market > 0 then ratios[#ratios + 1] = cur / r.market end
  end
  table.sort(ratios)
  local ratio, learned = 0.70, false
  if #ratios >= 3 then
    ratio = ratios[math.ceil(#ratios / 2)]
    ratio = math.max(0.5, math.min(0.95, ratio))
    learned = true
  end
  for _, r in ipairs(check.items) do
    if r.market then r.suggest = math.max(1, math.floor(r.market * ratio)) end
    L("price_check", { item = r.id, market = r.market, cheapest = r.cheapest, listed = r.listed,
      now = DB.caps[r.id], suggest = r.suggest, ratio = math.floor(ratio * 100 + 0.5) })
  end
  lastCheck = { items = check.items, ratio = ratio, learned = learned, at = time() }
  check = nil
  CheckButtons(false)
  ShowCheckPanel()
  wb_AHSnipe_Favorites()
end

function wb_AHSnipe_Check()
  local ah = AH()
  if not ah then return end
  local now = GetTime()

  if not check then
    local onFavs = lastBrowse == "fav" and ah.BrowseResultsFrame and ah.BrowseResultsFrame:IsShown()
    local res = onFavs and C_AuctionHouse.GetBrowseResults() or {}
    if #res == 0 then
      msg("Opening favorites first. Press Check prices again once the list shows.")
      wb_AHSnipe_Favorites()
      return
    end
    local list = {}
    for _, r in ipairs(res) do if r.itemKey then list[#list + 1] = r end end
    check = { list = list, i = 0, items = {} }
    CheckButtons(true)
    L("check_start", { count = #list })
  end

  -- Still waiting for the last item's listings?
  if check.cur and not check.cur.done and now - check.cur.at < CHECK_TIMEOUT then return end
  if check.cur and not check.cur.done then
    check.items[#check.items + 1] = { id = check.cur.id }
    check.cur.done = true
  end
  -- Our own wait flag never outlives the timeout here.
  if pending and now - sentAt > CHECK_TIMEOUT then pending = false end
  if Queued() or buying or pending then return end

  check.i = check.i + 1
  local r = check.list[check.i]
  if not r then FinishCheck() return end
  check.cur = { r = r, id = r.itemKey.itemID, key = r.itemKey, at = now }
  pending, sentAt = true, now
  -- Opening an item from inside another item's page never sends a search,
  -- so step back to the list first. The new item page then loads normally.
  local inItem = (ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown()) or (ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown())
  if inItem and ah.SetDisplayMode and AuctionHouseFrameDisplayMode then
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  end
  L("check_open", { item = check.cur.id, n = check.i, of = #check.list, fromItem = inItem and 1 or 0 })
  if settings and settings.checkBtn then
    settings.checkBtn:SetText(("Checking %d of %d"):format(check.i, #check.list))
  end
  if not OpenDeal(r) then
    check.items[#check.items + 1] = { id = check.cur.id }
    check.cur.done = true
  end
end

local cf = CreateFrame("Frame")
cf:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
cf:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
cf:SetScript("OnEvent", function(_, e, a1)
  local cur = check and check.cur
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
  if check.i >= #check.list then
    if settings and settings.checkBtn then settings.checkBtn:SetText("Done: press once more to see results") end
  end
end)


-- Monospace chat font ---------------------------------------------------------
-- Puts every chat window in DejaVu Sans Mono (bundled in fonts\mono.ttf) at
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

local tf = CreateFrame("Frame")
tf:RegisterEvent("PLAYER_ENTERING_WORLD")
tf:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  C_Timer.After(2, wb_AHSnipe_SetupTab) -- after Blizzard restores chat windows
end)
