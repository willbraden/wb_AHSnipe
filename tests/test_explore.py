"""Explore: tries each Buy % MIN_TRIES times, then settles on the best."""
import os, runpy, sys, tempfile, io, contextlib
# Expose PickPct and TallyTune to the test through two globals.
src = open(sys.argv[1]).read().replace("local function Tally(id, won, qty, total)",
    "wb_AHSnipe_TestPick = function(id) return PickPct(id) end\n"
    "wb_AHSnipe_TestTally = function(id, p, won, q) attemptPct[id] = p; TallyTune(id, won, q) end\n"
    "local function Tally(id, won, qty, total)", 1)
tmp = os.path.join(tempfile.mkdtemp(), "Core.lua")
open(tmp, "w").write(src)
sys.argv = ["test_ui.py", tmp]
with contextlib.redirect_stdout(io.StringIO()):
    ns = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_ui.py"))
L = ns["L"]
print(L.execute(r'''
math.randomseed(3)
local DB = wb_AHSnipeDB
DB.explore = true; DB.buyPct = 50; DB.tune = {}; DB.itemPct = {}
-- simulate 60 tries on item 7: 66% wins 3 units, others 1 unit, all win half the time
local seq, counts = {}, {}
for i = 1, 60 do
  local p = wb_AHSnipe_TestPick(7)
  seq[#seq+1] = p
  counts[p] = (counts[p] or 0) + 1
  wb_AHSnipe_TestTally(7, p, i % 2 == 0, p == 66 and 3 or 1)
end
local out = table.concat(seq, " ", 1, 20) .. "\n   ...  last 20: " .. table.concat(seq, " ", 41, 60)
DB.explore = false
out = out .. "\nExplore off picks: " .. wb_AHSnipe_TestPick(7) .. " (untested item uses " .. wb_AHSnipe_TestPick(8) .. ")"
for _, l in ipairs(wb_AHSnipe_ItemDetails(7)) do out = out .. "\n  tip: " .. l end
return out
'''))
