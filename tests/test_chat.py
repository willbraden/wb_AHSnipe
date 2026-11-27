"""Chat table: money columns right-aligned, and the session total is exactly
the sum of the Bought rows' profits."""
import os, re, runpy, sys, tempfile, io, contextlib
# Expose a few locals to the test, from the end of the file where they're all in scope.
src = open(sys.argv[1]).read() + (
    "\nwb_AHSnipe_TestRow = function(c) Row(c) end\n"
    "wb_AHSnipe_TestBuy = function(id, q, t) return BuyProfit(id, q, t) end\n"
    "wb_AHSnipe_TestFail = function(id, why) Fail(id, why) end\n")
tmp = os.path.join(tempfile.mkdtemp(), "Core.lua")
open(tmp, "w").write(src)
sys.argv = ["test_ui.py", tmp]
with contextlib.redirect_stdout(io.StringIO()):
    ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L, g = ns["L"], ns["g"]
L.execute(r'''
OUTPUT = {}
local sale = { [4304] = 1773, [4338] = 510, [2592] = 160 }
TSM_API = { GetCustomPriceValue = function(src, s)
  local id = tonumber(s:match("%d+"))
  if src == "DBRegionSaleAvg" then return sale[id] end
  if src == "DBRegionSoldPerDay" then return 5000 end
end }
local function buy(id, q, each)
  local a, b, c = wb_AHSnipe_TestBuy(id, q, q * each)
  wb_AHSnipe_TestRow({ "|cffffd100Bought|r", "|cffffd100" .. q .. "|r", "[Item " .. id .. "]", a, b, c })
end
buy(2592, 2, 100)
buy(4338, 2, 137)
NOW = NOW + 700  -- past the 10 minutes before the rate shows
buy(4304, 37, 1001)
buy(4304, 9, 1001)
wb_AHSnipe_TestFail(4304, "beaten to it")
wb_AHSnipe_TestRow({ "|cff33ff33-47%|r", "", "[Rugged Leather]", "|cffc7c7cf10|r|cffeda55f01|r", "|cffaaaaaawas|r |cffc7c7cf18|r|cffeda55f90|r", "|cffaaaaaamax|r |cffc7c7cf12|r|cffeda55f73|r" })
''')
def plain(t): return re.sub(r"\|c[0-9a-fA-F]{8}|\|r|\|H.-\|h|\|h", "", t)
lines = [plain(t).replace("AHSnipe ", "", 1) for t in g.OUTPUT.values()]
for l in lines: print(l)
bought = [l for l in lines if l.startswith("Bought")]
# money columns end at the same character on every Bought row
ends = {tuple(m.end() for m in re.finditer(r"[+-]\d+(/h)?", l)) for l in bought[2:]}
print("aligned" if len(ends) == 1 else f"NOT aligned {ends}")
nums = [[int(x) for x in re.findall(r"[+-]\d+(?!/h)(?=\s|$)", l)] for l in bought]
running = nums[0][-1] - nums[0][0]  # the harness's earlier scenarios already bought some
ok = True
for n in nums:
    running += n[0]
    ok = ok and n[-1] == running
print("totals add up" if ok else f"totals off {nums}")
