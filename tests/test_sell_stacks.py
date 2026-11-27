import os
import runpy, sys, io, contextlib
sys.argv = ["test_ui.py", sys.argv[1]]
with contextlib.redirect_stdout(io.StringIO()):
    ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L, g = ns["L"], ns["g"]
L.execute(r'''
POSTS = {}
BAGS = { [0] = { [1] = { itemID = 4306, stackCount = 7 } }, [5] = { [1] = { itemID = 4306, stackCount = 20 }, [2] = { itemID = 4306, stackCount = 20 }, [3] = { itemID = 4306, stackCount = 11 } } }
C_Container = {
  GetContainerNumSlots = function(b) return BAGS[b] and 4 or 0 end,
  GetContainerItemInfo = function(b, s) return BAGS[b] and BAGS[b][s] end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, b, s) return { b = b, s = s } end }
local function count() local n = 0 for _, bag in pairs(BAGS) do for _, it in pairs(bag) do n = n + it.stackCount end end return n end
C_Item.GetItemCount = function(id) return count() end
C_AuctionHouse.GetAvailablePostCount = function(loc) return BAGS[loc.b][loc.s].stackCount end
C_AuctionHouse.CalculateCommodityDeposit = function(_, _, q) return 2 * q end
C_AuctionHouse.HasFullCommoditySearchResults = function() return true end
C_AuctionHouse.MakeItemKey = function(id) return { itemID = id } end
C_AuctionHouse.SendSearchQuery = noop or function() end
PENDING = nil
C_AuctionHouse.PostCommodity = function(loc, d, q, p) table.insert(POSTS, { q = q, p = p, b = loc.b }); PENDING = loc end
TSM_API = { GetCustomPriceValue = function(src) if src == "DBRegionSoldPerDay" then return 9793 end end }
wb_AHSnipeDB.stats[4306] = { units = 200, spent = 200 * 150, won = 5, lost = 1 }
AuctionHouseFrame.CommoditiesBuyFrame:Hide()
wb_AHSnipe_SelectTab(2)
LIST = { {unitPrice=160, quantity=3, numOwnerItems=0}, {unitPrice=190, quantity=400, numOwnerItems=0}, {unitPrice=230, quantity=2000, numOwnerItems=0} }
''')
def show(label):
    L.execute("TICK()")
    p = g.wb_AHSnipeSettings.pages[2]
    print("==", label, "|", p.next._text, "|", p.nextDetail._text)
show("start")
L.execute("NOW=NOW+1; wb_AHSnipe_Buy(); FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 4306)")
show("planned")
for i in range(6):
    L.execute("NOW=NOW+0.3; wb_AHSnipe_Buy()")
    show(f"press {i+1} (no confirm yet)")
    L.execute("FIRE('AUCTION_HOUSE_AUCTION_CREATED'); if PENDING then BAGS[PENDING.b][PENDING.s] = nil; PENDING = nil; FIRE('BAG_UPDATE_DELAYED') end")
print("posts:", [dict(x.items()) for x in g.POSTS.values()])
print("chat:", [t for t in g.OUTPUT.values() if 'Posted' in t])
