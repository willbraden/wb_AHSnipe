"""Run every test against Core.lua and say PASS or FAIL for each.

  python tests/run_all.py            (from the repo folder; needs: pip install lupa)

Each test loads Core.lua against a stubbed WoW API (test_ui.py):
  test_ui.py           the window, Next press line and tabs through a series of states
  test_sim2000.py      2000 random presses: never sends while a message is queued,
                       never confirms over max, no Lua errors
  test_sell.py         selling: search, plan, post, hold under cost, queued guard
  test_sell_stacks.py  posting every stack (bags and reagent bag), Posted row with a late bag update
  test_dips.py         the thin-dip record keeps real dips and skips the rest
  test_explore.py      Explore settles on the best Buy %, Explore off uses it
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "..", "Core.lua")

CHECKS = {
    "test_ui.py": [],
    "test_sim2000.py": [r"sent while queued: 0\s+confirmed over max: 0\s+errors: 0"],
    "test_sell.py": [r"posts: \[\{.*'q': 120.*\}\]", r"held", r"sent while queued:\s*0", r"low hour \d+%, best"],
    "test_sell_stacks.py": [r"'q': 7.*'q': 20.*'q': 20.*'q': 11", r"Posted.*58"],
    "test_dips.py": [r"^1 dips"],
    "test_explore.py": [r"Explore off picks: 66"],
}

failed = 0
for name, patterns in CHECKS.items():
    r = subprocess.run([sys.executable, os.path.join(HERE, name), CORE], capture_output=True, text=True)
    out = r.stdout + r.stderr
    bad = r.returncode != 0 or "Traceback" in out or any(not re.search(p, out, re.M) for p in patterns)
    print(("FAIL " if bad else "PASS ") + name)
    if bad:
        failed += 1
        print("\n".join("    " + l for l in out.strip().splitlines()[-15:]))
print("all passed" if not failed else f"{failed} failed")
sys.exit(1 if failed else 0)
