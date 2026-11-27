import os
import runpy, sys, io, contextlib
sys.argv = ["test_ui.py", sys.argv[1]]
with contextlib.redirect_stdout(io.StringIO()):
    ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L, g = ns["L"], ns["g"]
L.execute(r'''
C_AuctionHouse.MakeItemKey = function(id) return { itemID = id } end
local function run(list, id)
  LIST = list
  FIRE('COMMODITY_SEARCH_RESULTS_UPDATED', id)
end
wb_AHSnipeDB.dips = nil
run({ {unitPrice=79, quantity=11, numOwnerItems=0}, {unitPrice=99, quantity=8, numOwnerItems=0}, {unitPrice=198, quantity=500, numOwnerItems=0} }, 4306)
run({ {unitPrice=79, quantity=11, numOwnerItems=0}, {unitPrice=99, quantity=8, numOwnerItems=0}, {unitPrice=198, quantity=500, numOwnerItems=0} }, 4306) -- same dip: skipped
run({ {unitPrice=190, quantity=81, numOwnerItems=0}, {unitPrice=198, quantity=228, numOwnerItems=0} }, 4306) -- cheapest is a wall: no dip
run({ {unitPrice=100, quantity=3, numOwnerItems=0}, {unitPrice=105, quantity=300, numOwnerItems=0} }, 2589) -- wall without jump: no dip
run({ {unitPrice=100, quantity=3, numOwnerItems=3}, {unitPrice=150, quantity=30, numOwnerItems=0} }, 2589) -- only my own cheap units: no dip
''')
d = g.wb_AHSnipeDB.dips
print(len(d) if d else 0, "dips")
for v in (d.values() if d else []): print(dict(v.items()))
