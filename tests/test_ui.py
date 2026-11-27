"""Load Core.lua against a stubbed WoW API and exercise the new window."""
import sys
import lupa

L = lupa.LuaRuntime(unpack_returned_tuples=True)
stub = r'''
local function noop() end
-- Frames: remember text, shown state and size; every other method is a no-op.
local Frame = {}
ALLFRAMES = {}
local frameMT
local function NewFrame(kind, name, parent)
  local f = setmetatable({ _kind = kind, _shown = true, _text = "", _children = {}, _scripts = {}, _parent = parent, _w = 0, _h = 0 }, frameMT)
  if name then _G[name] = f end
  table.insert(ALLFRAMES, f)
  return f
end
function Frame:SetText(t) self._text = t or "" end
function Frame:GetText() return self._text end
function Frame:Show() self._shown = true end
function Frame:Hide() self._shown = false end
function Frame:SetShown(v) self._shown = v and true or false end
function Frame:IsShown() return self._shown end
function Frame:IsVisible()
  local f = self
  while f do if not f._shown then return false end f = f._parent end
  return true
end
function Frame:SetSize(w, h) self._w, self._h = w, h end
function Frame:SetWidth(w) self._w = w end
function Frame:SetHeight(h) self._h = h end
function Frame:GetWidth() return self._w end
function Frame:GetHeight() return self._h end
function Frame:CreateFontString() return NewFrame("FontString", nil, self) end
function Frame:CreateTexture() return NewFrame("Texture", nil, self) end
function Frame:SetScript(k, fn) self._scripts[k] = fn end
function Frame:GetScript(k) return self._scripts[k] end
function Frame:HookScript(k, fn) self._scripts[k] = fn end
function Frame:HasFocus() return false end
function Frame:IsEnabled() return self._enabled ~= false end
function Frame:Enable() self._enabled = true end
function Frame:Disable() self._enabled = false end
function Frame:GetChecked() return self._checked end
function Frame:SetChecked(v) self._checked = v end
function Frame:GetFont() return "font", 12, "" end
function Frame:GetTop() return 500 end
function Frame:GetBottom() return 300 end
function Frame:GetChildren() return end
function Frame:RegisterEvent(e) local ev = rawget(self, "_events") or {}; rawset(self, "_events", ev); ev[e] = true end
function Frame:GetRegions() return end
function Frame:GetVerticalScrollRange() return 0 end
function Frame:GetVerticalScroll() return 0 end
function Frame:SetTextColor(r, g, b) self._color = { r, g, b } end
local VERBS = { "Set", "Get", "Enable", "Register", "Clear", "Highlight", "Add", "Hook", "Is", "Unregister", "Click", "Start", "Stop", "Raise", "Lower" }
frameMT = { __index = function(t, k)
  if Frame[k] then return Frame[k] end
  if type(k) ~= "string" then return nil end
  for _, v in ipairs(VERBS) do if k:sub(1, #v) == v then return noop end end
  return nil
end }
function CreateFrame(kind, name, parent) return NewFrame(kind, name, parent) end
hooksecurefunc = function(obj, name, fn)
  if type(obj) == "table" and fn then local old = obj[name]; obj[name] = function(...) local r = old and old(...); fn(...); return r end end
end
C_Timer = { After = function(_, fn) end }
NOW = 1000
GetTime = function() return NOW end
MONEY = 1000000
GetMoney = function() return MONEY end
GetMoneyString = function(c) return tostring(c) .. "c" end
time = os.time
date = os.date
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strsplit = function(sep, s, n) local a, b = s:match("^(%S*)%s*(.*)$"); return a, b end
tinsert = table.insert
unpack = table.unpack or unpack
STANDARD_TEXT_FONT = "font"
Enum = { AuctionHouseSortOrder = { Price = 0 } }
StaticPopupDialogs = {}
StaticPopup_Show = noop
StaticPopup_Visible = function() return false end
SlashCmdList = {}
DEFAULT_CHAT_FRAME = NewFrame("ChatFrame")
OUTPUT = {}
DEFAULT_CHAT_FRAME.AddMessage = function(_, t) table.insert(OUTPUT, t) end
ChatFrame1 = DEFAULT_CHAT_FRAME
NUM_CHAT_WINDOWS = 1
GetChatWindowInfo = function() return "General" end
FCF_OpenNewWindow = noop
C_Item = { GetItemInfo = function(id) return "Item" .. id, "[Item " .. id .. "]" end, GetItemNameByID = function(id) return "Item" .. id end, GetItemID = function() return nil end }
-- Auction house state the tests change.
LIST = {}
BROWSE = {}
UNFAV = {}
C_AuctionHouse = {
  IsThrottledMessageSystemReady = function() return true end,
  GetNumCommoditySearchResults = function() return #LIST end,
  GetCommoditySearchResultInfo = function(_, i) return LIST[i] end,
  GetBrowseResults = function() return BROWSE end,
  GetNumItemSearchResults = function() return 0 end,
  StartCommoditiesPurchase = noop, ConfirmCommoditiesPurchase = noop, CancelCommoditiesPurchase = noop,
  SendSearchQuery = noop, PlaceBid = noop,
  IsFavoriteItem = function(key) return not UNFAV[key.itemID] end,
}
AuctionHouseFrameDisplayMode = { Buy = 1 }
GetTimePreciseSec = function() return NOW end
UnitName = function() return "Will" end
GetRealmName = function() return "Realm" end
setmetatable(_G, { __index = function(_, k)
  if type(k) == "string" and k:match("^[A-Z]") and not k:match("^wb_") and not k:match("^[A-Z_]+$") then return noop end
end })
AuctionHouseFrame = NewFrame("Frame", "AuctionHouseFrame")
OPEN_ID = nil
AuctionHouseFrame.CommoditiesBuyFrame = NewFrame("Frame")
AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay = NewFrame("Frame")
AuctionHouseFrame.CommoditiesBuyFrame.BuyDisplay.ItemDisplay = { GetItemKey = function() return OPEN_ID and { itemID = OPEN_ID } end }
AuctionHouseFrame.ItemBuyFrame = NewFrame("Frame"); AuctionHouseFrame.ItemBuyFrame:Hide()
AuctionHouseFrame.BrowseResultsFrame = NewFrame("Frame")
AuctionHouseFrame.CommoditiesSellFrame = NewFrame("Frame"); AuctionHouseFrame.CommoditiesSellFrame:Hide()
AuctionHouseFrame.ItemSellFrame = NewFrame("Frame"); AuctionHouseFrame.ItemSellFrame:Hide()
AuctionHouseFrame.SearchBar = { FavoritesSearchButton = NewFrame("Button"), SearchButton = NewFrame("Button") }
'''
L.execute(stub)
src = open(sys.argv[1]).read()
L.execute(src)
g = L.globals()

# Fire ADDON_LOADED / PLAYER_LOGIN style setup: find frames with OnEvent and call them.
L.execute(r'''
wb_AHSnipeDB = wb_AHSnipeDB or {}
FIRE = function(event, ...)
  for _, f in ipairs(ALLFRAMES) do
    if rawget(f, "_events") and f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
  end
end
TICK = function()
  for _, f in ipairs(ALLFRAMES) do if f._scripts.OnUpdate then f._scripts.OnUpdate(f, 1) end end
end
''')

L.execute(r'''
FIRE("ADDON_LOADED", "wb_AHSnipe")
FIRE("PLAYER_LOGIN")
wb_AHSnipeDB.lastCheckAt = time()
FIRE("AUCTION_HOUSE_SHOW")
''')
def state(label):
    L.execute("TICK()")
    st = g.wb_AHSnipeSettings
    print("==", label, "| tab", st.tab, "size", st._w, st._h)
    print("   next:", st.strip.text._text, "|", st.strip.detail._text)
    if st.card._shown:
        print("   card:", st.card.name._text, "| max tag:", st.card.maxTag._text, "| boxes", [b._text for b in st.card.max.values()],
              "| h", st.settings_h if hasattr(st, "settings_h") else "")
        print("   ", st.card.session._text)
    if st.favs._shown:
        print("   favs:", st.favs.title._text, [l._text for l in st.favs.lines.values() if l._text])

L.execute("OPEN_ID = 2589; wb_AHSnipeDB.caps[2589] = 100; wb_AHSnipeDB.minQty = 2")
L.execute("LIST = { {unitPrice=90, quantity=1, numOwnerItems=0}, {unitPrice=200, quantity=50, numOwnerItems=0} }")
state("bait: 1 under max")
L.execute("LIST = { {unitPrice=90, quantity=6, numOwnerItems=0}, {unitPrice=200, quantity=50, numOwnerItems=0} }")
state("6 under max")
L.execute("MONEY = 50")
state("can't afford")
L.execute("MONEY = 1000000; LIST = { {unitPrice=200, quantity=50, numOwnerItems=0} }")
state("nothing under")
L.execute("wb_AHSnipeDB.explore = true; LIST = { {unitPrice=90, quantity=10, numOwnerItems=0} }")
state("explore on")
L.execute("wb_AHSnipeDB.caps[2589] = nil")
state("no max")
L.execute("OPEN_ID = nil; AuctionHouseFrame.CommoditiesBuyFrame:Hide()")
state("browse, not favorites")
L.execute("AuctionHouseFrame.SearchBar.FavoritesSearchButton._scripts.OnClick(); wb_AHSnipeDB.caps[3] = 500; BROWSE = { {itemKey={itemID=3}, minPrice=300}, {itemKey={itemID=4}, minPrice=10} }")
state("favorites with a deal")
L.execute("AuctionHouseFrame.CommoditiesSellFrame:Show()")
state("AH sell tab")
L.execute("AuctionHouseFrame.CommoditiesSellFrame:Hide()")
state("back to buy")
L.execute("wb_AHSnipe_SelectTab(3)")
state("setup tab")
L.execute("wb_AHSnipe_SelectTab(4)")
state("buy % tab")
print("chat:", list(g.OUTPUT.values())[-5:])


L.execute("wb_AHSnipe_SelectTab(1); OPEN_ID = 2589; wb_AHSnipeDB.caps[2589] = 100; wb_AHSnipeDB.explore = false; AuctionHouseFrame.CommoditiesBuyFrame:Show(); LIST = { {unitPrice=90, quantity=6, numOwnerItems=0} }")
L.execute("FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 2589)")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy()")
state("after first press (quote asked)")
L.execute("FIRE('COMMODITY_PRICE_UPDATED', 90, 270)")
state("quote back")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy(); FIRE('COMMODITY_PURCHASE_SUCCEEDED')")
state("bought")
L.execute("wb_AHSnipe_Check()")
state("check running")
L.execute("wb_AHSnipe_CancelCheck()")
state("check cancelled")
print("chat:", [t for t in g.OUTPUT.values()][-4:])

L.execute("wb_AHSnipe_SelectTab(1); UNFAV[2589] = true; LIST = { {unitPrice=90, quantity=6, numOwnerItems=0} }; staleFix = true")
L.execute("NOW = NOW + 5; FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 2589)")
state("unstarred item open")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy()")
state("after press on unstarred")
L.execute("OPEN_ID = nil; AuctionHouseFrame.CommoditiesBuyFrame:Hide(); UNFAV[3] = true; wb_AHSnipeDB.caps[4] = 50")
state("favorites, Item 3 unstarred, Item 4 under max")
