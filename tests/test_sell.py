import os
import runpy, sys
sys.argv = ["test_ui.py", sys.argv[1]]
import io, contextlib
with contextlib.redirect_stdout(io.StringIO()):
    ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L, g = ns["L"], ns["g"]
L.execute(r'''
POSTS = {}
SENT = {}
BAGS = { [0] = { [1] = { itemID = 4306, stackCount = 120 }, [3] = { itemID = 9999, stackCount = 5 } } }
C_Container = {
  GetContainerNumSlots = function(b) return BAGS[b] and 4 or 0 end,
  GetContainerItemInfo = function(b, s) return BAGS[b] and BAGS[b][s] end,
}
ItemLocation = { CreateFromBagAndSlot = function(_, b, s) return { b = b, s = s } end }
C_Item.GetItemCount = function(id) return id == 4306 and 120 or 5 end
C_AuctionHouse.GetAvailablePostCount = function() return 120 end
C_AuctionHouse.CalculateCommodityDeposit = function(_, _, q) return 2 * q end
C_AuctionHouse.HasFullCommoditySearchResults = function() return true end
C_AuctionHouse.MakeItemKey = function(id) return { itemID = id } end
C_AuctionHouse.SendSearchQuery = function(key) table.insert(SENT, key.itemID) end
C_AuctionHouse.PostCommodity = function(loc, d, q, p) table.insert(POSTS, { d = d, q = q, p = p }) end
TSM_API = { GetCustomPriceValue = function(src, s) if src == "DBRegionSoldPerDay" then return 9793 * 1000 / 1000 end end }
wb_AHSnipeDB.stats = wb_AHSnipeDB.stats or {}
wb_AHSnipeDB.stats[4306] = { units = 200, spent = 200 * 150, won = 5, lost = 1 }
AuctionHouseFrame.CommoditiesBuyFrame:Hide()
AuctionHouseFrame.CommoditiesSellFrame:Show()
''')
def show(label):
    L.execute("TICK()")
    p = g.wb_AHSnipeSettings.pages[2]
    print("==", label, "| tab", g.wb_AHSnipeSettings.tab)
    print("   next:", p.next._text, "|", p.nextDetail._text)
    print("   list:", p.list._text.replace("\n", " // "))
show("open sell tab")
# bait 3 units at 160, wall 400 at 190, 300 at 199, 2000 at 230
L.execute("LIST = { {unitPrice=160, quantity=3, numOwnerItems=0}, {unitPrice=190, quantity=400, numOwnerItems=0}, {unitPrice=199, quantity=300, numOwnerItems=0}, {unitPrice=230, quantity=2000, numOwnerItems=0} }")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy()")
print("   searched:", list(g.SENT.values()))
show("after search press")
L.execute("FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 4306)")
show("results back")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy()")
print("   posts:", [dict(x.items()) for x in g.POSTS.values()])
show("posted")
print("   chat:", list(g.OUTPUT.values())[-1])
# below cost case
L.execute("wb_AHSnipeDB.stats[4306].spent = 200 * 260; wb_AHSnipe_SellDone = nil; FIRE('AUCTION_HOUSE_SHOW'); AuctionHouseFrame.CommoditiesSellFrame:Show()")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy(); FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 4306)")
show("below cost")
L.execute("NOW = NOW + 1; wb_AHSnipe_Buy()")
show("held, pressed again")
# queued guard
L.execute("FIRE('AUCTION_HOUSE_SHOW'); AuctionHouseFrame.CommoditiesSellFrame:Show(); wb_AHSnipeDB.stats[4306].spent = 200*150; FIRE('AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED'); n0 = #SENT; NOW = NOW + 0.5; wb_AHSnipe_Buy(); print('   sent while queued:', #SENT - n0)")
# low hour: market now well under its usual -> price shows with a low-hour note
L.execute("FIRE('AUCTION_HOUSE_THROTTLED_SYSTEM_READY'); FIRE('AUCTION_HOUSE_SHOW'); wb_AHSnipeDB.stats[4306].spent = 200 * 100; "
          "wb_AHSnipeDB.mkt = { [4306] = { now = 150, nowAt = 0, h = { [4] = { n = 3, sum = 450 }, [20] = { n = 3, sum = 690 }, [9] = { n = 2, sum = 400 }, [13] = { n = 2, sum = 400 } } } }; "
          "LIST = { {unitPrice=150, quantity=3000, numOwnerItems=0}, {unitPrice=152, quantity=3000, numOwnerItems=0} }; "
          "NOW = NOW + 1; wb_AHSnipe_Buy(); FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', 4306)")
show("low hour")
