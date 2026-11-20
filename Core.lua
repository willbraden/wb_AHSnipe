-- wb_AHSnipe: refresh + buy keybinds for the stock auction house.
-- Refresh never sends a new search while the last one is unanswered,
-- which is what wedges the AH until a relog.

BINDING_HEADER_WBAHSNIPE = "wb_AH Snipe"
BINDING_NAME_WBAHSNIPE_REFRESH = "Refresh AH"
BINDING_NAME_WBAHSNIPE_BUY = "Snipe (one button: refresh, quote, buy)"

local MIN_GAP = 0.6      -- seconds between searches
local STALE_GUARD = 8    -- forget our own pending flag after this long
local WARN_AFTER = 5     -- warn if the AH hasn't answered in this long
local QUOTE_TTL = 10     -- seconds a commodity price quote is trusted
local MIN_QTY = 2        -- commodities: skip unless at least this many are under your max

local pending, sentAt, warned = false, 0, false
local quote -- { itemID, qty, maxTotal, at, total }
local staleID -- commodity whose on-screen list is known to be out of date
local resultsAt = {} -- itemID -> when its commodity list last arrived
local queuedAt -- when an AH message started waiting its turn; sending another would drop it
local function Queued() return queuedAt and GetTime() - queuedAt < 3 end
local buying          -- { at, item, qty } while a confirmed purchase is in flight
local BUY_TIMEOUT = 4 -- seconds to wait for a purchase result before giving up
local itemStale = false -- single-item list needs a refresh (after a bid)
local lastSaid = {}     -- itemID -> list time we last printed "over your max" for
local function SayOnce(id, stamp, text)
  if lastSaid[id] ~= stamp then lastSaid[id] = stamp; msg(text) end
end
local DB

local function msg(t) print("|cff33ff99AHSnipe|r " .. t) end
local function money(c) return GetMoneyString(c, true) end

-- Log ----------------------------------------------------------------------
-- Every press, search, quote and purchase is written to wb_AHSnipeLog
-- (saved to disk on /reload or logout). /snipe log clear wipes it.

local LOG_MAX = 6000
local clock = GetTimePreciseSec or GetTime
local confirmAt = 0

local function L(event, data)
  local log = wb_AHSnipeLog
  if not log or log.off then return end
  local row = data or {}
  row.t = string.format("%.3f", clock())
  row.e = event
  log.rows[#log.rows + 1] = row
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
  if not b then b, view = get(ah, "SearchBar", "SearchButton"), "Browse" end
  if not b then msg("Couldn't find a refresh button.") L("error", { what = "no_refresh_button" }) return end

  L("search_sent", { view = view, src = src, sinceLast = ms(now - sentAt), item = OpenItemID() })
  pending, sentAt = true, now
  b:Click()
  return true
end

-- Buy: single items ------------------------------------------------------

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
  if not cap then msg("No max price set. Type a max in the box at the bottom right.") return end
  if not best or best.buyoutAmount > cap then
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "none_under", item = key.itemID, cap = cap, cheapest = best and best.buyoutAmount, sent = sent and 1 or 0 })
    return
  end
  if GetMoney() < best.buyoutAmount then msg("Not enough gold.") return end

  L("bid_sent", { item = key.itemID, price = best.buyoutAmount })
  itemStale = true
  C_AuctionHouse.PlaceBid(best.auctionID, best.buyoutAmount)
  msg("Buying for " .. money(best.buyoutAmount))
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
  if not cap then msg("No max price set. Type a max (per unit) in the box at the bottom right.") return end

  local now = GetTime()

  -- A purchase is on its way: don't send anything that could knock it out.
  if buying then
    if now - buying.at < BUY_TIMEOUT then
      L("press", { step = "waiting_purchase", item = itemID, age = ms(now - buying.at) })
      return
    end
    L("purchase_timeout", { item = buying.item, qty = buying.qty, age = ms(now - buying.at) })
    msg("No answer on that purchase. Refreshing.")
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
      C_AuctionHouse.CancelCommoditiesPurchase()
      quote = nil
      staleID = itemID
      if wb_AHSnipe_Refresh(true) then
        msg("Cheap ones were already gone. Cancelled and refreshed the list.")
      else
        msg("Cheap ones were already gone. Cancelled. Press again to refresh.")
      end
      return
    end
    if GetMoney() < quote.total then msg("Not enough gold.") L("press", { step = "no_gold" }) quote = nil return end
    L("confirm_sent", { item = itemID, qty = quote.qty, total = quote.total, quoteAge = ms(now - quote.at), priceAge = ms(now - (quote.priceAt or now)) })
    confirmAt = now
    buying = { at = now, item = itemID, qty = quote.qty }
    C_AuctionHouse.ConfirmCommoditiesPurchase(itemID, quote.qty)
    msg("Buying " .. quote.qty .. " for " .. money(quote.total))
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
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "none_under", item = itemID, cap = cap, cheapest = r and r.unitPrice, listings = n, listAge = listAge, sent = sent and 1 or 0 })
    if r and r.unitPrice then
      SayOnce(itemID, resultsAt[itemID], "Cheapest is " .. money(r.unitPrice) .. " each, over your max. Watching...")
    end
    return
  end

  local minQty = DB.minQty or MIN_QTY
  if qty < minQty then
    local sent = wb_AHSnipe_Refresh(true)
    L("press", { step = "under_min", item = itemID, qty = qty, min = minQty, listAge = listAge, sent = sent and 1 or 0 })
    SayOnce(itemID, resultsAt[itemID], "Only " .. qty .. " under your max (min " .. minQty .. "). Watching...")
    return
  end

  quote = { itemID = itemID, qty = qty, maxTotal = qty * cap, at = now, est = total }
  L("quote_start", { item = itemID, qty = qty, est = total, cap = cap, listings = n, listAge = listAge })
  C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
  msg("Found " .. qty .. " at or under " .. money(cap) .. " each (about " .. money(total) .. ").")
end

function wb_AHSnipe_Buy()
  local ah = AH()
  if not ah then return end
  if ah.ItemBuyFrame and ah.ItemBuyFrame:IsShown() then
    BuyItem(ah.ItemBuyFrame)
  elseif ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame:IsShown() then
    BuyCommodity()
  else
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
    if quote then msg("Those listings sold or changed. Press again to refresh.") staleID = quote.itemID end
    quote = nil
    return
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
    buying = nil
    msg("|cff55ff55Bought.|r")
    staleID = OpenItemID()
    return
  elseif e == "COMMODITY_PURCHASE_FAILED" then
    buying = nil
    msg("|cffff5555Purchase failed.|r Someone may have beaten you to it. Press again to refresh.")
    staleID = OpenItemID()
    return
  end

  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then staleID = nil end
  if e == "ITEM_SEARCH_RESULTS_UPDATED" then itemStale = false end

  if e == "AUCTION_HOUSE_CLOSED" then quote, buying, queuedAt = nil, nil, nil end
  if e == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" or e == "AUCTION_HOUSE_BROWSE_FAILURE" then
    msg("Search was dropped by the server. Wait a moment before refreshing.")
  end
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

local function GoldText(c)
  if not c then return "" end
  local s = string.format("%.4f", c / 10000):gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function SaveBox()
  local id = OpenItemID()
  local txt = strtrim(box:GetText() or "")
  local gold = tonumber(txt)
  if txt == "" then
    if id then DB.caps[id] = nil; msg("Cleared the max for this item.") end
  elseif gold then
    local c = math.floor(gold * 10000 + 0.5)
    if id then DB.caps[id] = c else DB.default = c end
    msg("Max " .. (id and "for this item" or "default") .. ": " .. money(c))
  else
    msg("Enter a gold amount, like 1.5 or .01")
  end
end

local function BuildBox()
  if box or not AuctionHouseFrame then return end
  box = CreateFrame("EditBox", "wb_AHSnipeMaxBox", AuctionHouseFrame, "InputBoxTemplate")
  box:SetSize(70, 20)
  box:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -12, 6)
  box:SetAutoFocus(false)
  box:SetJustifyH("RIGHT")
  box:SetScript("OnEnterPressed", function(self) SaveBox(); self:ClearFocus() end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  label = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("RIGHT", box, "LEFT", -8, 0)

  -- Min quantity box (commodities): left of the max label.
  local minBox = CreateFrame("EditBox", "wb_AHSnipeMinBox", AuctionHouseFrame, "InputBoxTemplate")
  minBox:SetSize(36, 20)
  minBox:SetPoint("RIGHT", label, "LEFT", -16, 0)
  minBox:SetAutoFocus(false)
  minBox:SetNumeric(true)
  minBox:SetJustifyH("RIGHT")
  minBox:SetText(tostring(DB.minQty or MIN_QTY))
  local function SaveMin(self)
    local n = tonumber(self:GetText())
    if n and n >= 1 then
      DB.minQty = n
      msg("Min to buy (commodities): " .. n)
    end
    self:SetText(tostring(DB.minQty or MIN_QTY))
    self:ClearFocus()
  end
  minBox:SetScript("OnEnterPressed", SaveMin)
  minBox:SetScript("OnEscapePressed", function(self) self:SetText(tostring(DB.minQty or MIN_QTY)); self:ClearFocus() end)
  local minLabel = minBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  minLabel:SetPoint("RIGHT", minBox, "LEFT", -8, 0)
  minLabel:SetText("Min qty:")

  local t = 0
  box:SetScript("OnUpdate", function(self, el)
    t = t + el
    if t < 0.25 then return end
    t = 0
    if self:HasFocus() then return end
    local id = OpenItemID()
    local saved = id and DB.caps[id]
    label:SetText(id and (saved and "Max (g), this item:" or "Max (g), default:") or "Default max (g):")
    self:SetText(GoldText(saved or DB.default))
  end)
end

local ui = CreateFrame("Frame")
ui:RegisterEvent("AUCTION_HOUSE_SHOW")
ui:SetScript("OnEvent", BuildBox)

-- Quick Post -------------------------------------------------------------
-- A small panel beside the AH: drop an item on the slot, type a price,
-- press Post (or the keybind). Posts 1 at that price for 24 hours and
-- remembers the price for that item.

BINDING_NAME_WBAHSNIPE_POST = "Quick Post 1"

local POST_DURATION = 2 -- 1 = 12h, 2 = 24h, 3 = 48h

local post -- panel
local postID, postLink

local function FindInBags(id)
  for bag = 0, 5 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == id and not info.isLocked then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if C_AuctionHouse.IsSellItemValid(loc, false) then return loc end
      end
    end
  end
end

local function SetPostItem(id, link)
  postID, postLink = id, link
  DB.postItem = id
  local icon = id and C_Item.GetItemIconByID(id)
  post.slot.icon:SetTexture(icon or "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
  post.name:SetText(link or (id and C_Item.GetItemNameByID(id)) or "|cff888888Drop an item here|r")
  local p = id and DB.postPrices[id]
  post.price:SetText(p and GoldText(p) or "")
end

function wb_AHSnipe_Post()
  if not AH() or not post then return end
  if not postID then msg("Drop an item on the Quick Post slot first.") return end

  local gold = tonumber(strtrim(post.price:GetText() or ""))
  if not gold or gold <= 0 then msg("Type a post price first.") return end
  local c = math.floor(gold * 10000 + 0.5)
  DB.postPrices[postID] = c
  post.price:ClearFocus()

  if Queued() or not C_AuctionHouse.IsThrottledMessageSystemReady() then msg("AH is busy. Try again in a moment.") return end

  local loc = FindInBags(postID)
  if not loc then msg("None of that item left in your bags.") return end

  local status = C_AuctionHouse.GetItemCommodityStatus(loc)
  local COMMODITY = (Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity) or 2
  local ITEM = (Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Item) or 1

  if status == COMMODITY then
    C_AuctionHouse.PostCommodity(loc, POST_DURATION, 1, c)
  elseif status == ITEM then
    C_AuctionHouse.PostItem(loc, POST_DURATION, 1, nil, c)
  else
    msg("Item info still loading. Press Post again.")
    return
  end
  msg("Posting 1 " .. (postLink or "") .. " for " .. money(c))
end

local function BuildPost()
  if post or not AuctionHouseFrame then return end
  DB.postPrices = DB.postPrices or {}

  post = CreateFrame("Frame", "wb_AHSnipePost", AuctionHouseFrame, "BackdropTemplate")
  post:SetSize(180, 118)
  post:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, -30)
  post:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })

  local title = post:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", 0, -8)
  title:SetText("Quick Post")

  local slot = CreateFrame("Button", nil, post)
  slot:SetSize(34, 34)
  slot:SetPoint("TOPLEFT", 12, -28)
  slot.icon = slot:CreateTexture(nil, "ARTWORK")
  slot.icon:SetAllPoints()
  slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  local function Drop()
    local kind, id, link = GetCursorInfo()
    if kind == "item" then SetPostItem(id, link); ClearCursor() end
  end
  slot:SetScript("OnReceiveDrag", Drop)
  slot:SetScript("OnClick", function(_, btn)
    if btn == "RightButton" then SetPostItem(nil) else Drop() end
  end)
  slot:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if postID then GameTooltip:SetItemByID(postID)
    else GameTooltip:SetText("Drop an item here.\nRight-click to clear.") end
    GameTooltip:Show()
  end)
  slot:SetScript("OnLeave", GameTooltip_Hide)
  post.slot = slot

  post.name = post:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  post.name:SetPoint("LEFT", slot, "RIGHT", 6, 0)
  post.name:SetPoint("RIGHT", post, "RIGHT", -8, 0)
  post.name:SetJustifyH("LEFT")
  post.name:SetWordWrap(true)

  local pl = post:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pl:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -12)
  pl:SetText("Price (g):")

  post.price = CreateFrame("EditBox", nil, post, "InputBoxTemplate")
  post.price:SetSize(70, 20)
  post.price:SetPoint("LEFT", pl, "RIGHT", 10, 0)
  post.price:SetAutoFocus(false)
  post.price:SetJustifyH("RIGHT")
  post.price:SetScript("OnEnterPressed", function(self)
    local g = tonumber(strtrim(self:GetText() or ""))
    if postID and g then DB.postPrices[postID] = math.floor(g * 10000 + 0.5) end
    self:ClearFocus()
  end)
  post.price:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  local btn = CreateFrame("Button", nil, post, "UIPanelButtonTemplate")
  btn:SetSize(156, 22)
  btn:SetPoint("BOTTOM", 0, 10)
  btn:SetText("Post 1")
  btn:SetScript("OnClick", wb_AHSnipe_Post)

  if DB.postItem then SetPostItem(DB.postItem) else SetPostItem(nil) end
end

local pf = CreateFrame("Frame")
pf:RegisterEvent("AUCTION_HOUSE_SHOW")
pf:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
pf:SetScript("OnEvent", function(_, e)
  if e == "AUCTION_HOUSE_SHOW" then BuildPost()
  elseif e == "AUCTION_HOUSE_AUCTION_CREATED" then msg("|cff55ff55Posted.|r") end
end)

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

local function PaintRow(row)
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
end

local function PaintList(list)
  local sb = list and list:IsVisible() and list.ScrollBox
  if not sb or not sb.EnumerateFrames then return end
  for _, row in sb:EnumerateFrames() do
    pcall(PaintRow, row)
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
  PaintList(get(ah, "BrowseResultsFrame", "ItemList"))
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
}) do pcall(lg.RegisterEvent, lg, e) end

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
    local top = {}
    for i = 1, math.min(5, C_AuctionHouse.GetNumCommoditySearchResults(a1) or 0) do
      local r = C_AuctionHouse.GetCommoditySearchResultInfo(a1, i)
      if r then top[#top + 1] = r.unitPrice .. "x" .. r.quantity .. ((r.numOwnerItems or 0) > 0 and "(mine)" or "") end
    end
    L(short, { item = a1, latency = ms(now - sentAt), top = table.concat(top, " "), cap = Cap(a1) })
  elseif e == "ITEM_SEARCH_RESULTS_UPDATED" or e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    L(short, { latency = ms(now - sentAt) })
  elseif e == "COMMODITY_PRICE_UPDATED" then
    if quote then quote.priceAt = now end
    L(short, { unit = a1, total = a2, latency = quote and ms(now - quote.at), qty = quote and quote.qty, maxTotal = quote and quote.maxTotal })
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" or e == "COMMODITY_PURCHASE_FAILED" or e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    L(short, { latency = ms(now - confirmAt) })
  elseif e == "UI_ERROR_MESSAGE" then
    if AH() then L("ui_error", { msg = tostring(a2) }) end
  else
    L(short, { ready = C_AuctionHouse.IsThrottledMessageSystemReady() and 1 or 0 })
  end
end)
