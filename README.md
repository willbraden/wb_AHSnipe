# wb_AHSnipe

A World of Warcraft: Forever addon for fast auction house sniping with the stock AH window. One key refreshes, quotes and buys anything listed under your max price, jumps to deals on your favorites list, and never jams the auction house.

## Features

- **One-button snipe.** Each press does the next step: refresh, quote, confirm, then refresh again after a buy.
- **Never jams the AH.** It won't send a new request while one is still waiting, so a confirmed purchase can't be knocked out by your next press.
- **Max price per item**, set in gold, silver and copper boxes with up/down steppers (click = 1, Shift-click = 10). Items without their own max use your default.
- **Min qty** for commodities. Skips bait listings smaller than this.
- **Buy %.** Each commodity buy asks for this share of the cheap units, so another buyer taking a few doesn't sink your whole purchase.
- **Favorites mode.** On your favorites list, Snipe opens the best deal (furthest under its max). After 10 presses with nothing under max, it goes back to favorites. A checkbox (or keybind) turns this off so you can camp one item.
- **Check prices.** Opens each favorite one press at a time, reads what's really listed, and suggests a max based on your usual discount from market.
- **Green prices** in the native AH lists for anything at or under your max, plus `-32%` / `+40%` badges on favorites that moved 25% or more between refreshes and a `no max` tag on favorites without a max.
- **Table-style chat results** for buys, failures and price moves, aligned with an invisible spacer. Optional monospace chat font (DejaVu Sans Mono, bundled).
- **Session log** of every press, search, quote and purchase, plus a saved list of bait listings.

## Install

Copy the `wb_AHSnipe` folder into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

Restart the game (new files such as the font are only picked up on a full restart).

## Setup

1. In Keybindings, under **wb_AH Snipe**, bind:
   - **Snipe (one button: refresh, quote, buy)**
   - **Refresh favorites**
   - Optional: **Refresh AH**, **Check prices**, **Toggle jumping in and out of favorites**
2. Open the AH and click into an item. Set its max in the AH Snipe window to the right of the AH.
3. Spam the Snipe key.

Macros, if you prefer:

```
/run wb_AHSnipe_Buy()
/run wb_AHSnipe_Refresh()
/run wb_AHSnipe_Favorites()
/run wb_AHSnipe_Check()
/run wb_AHSnipe_ToggleRoam()
```

## Commands

| Command | What it does |
| --- | --- |
| `/snipe max <gold>` | Max for the open item, or your default if none is open |
| `/snipe default <gold>` | Default max for items without their own |
| `/snipe clear` | Remove the open item's max |
| `/snipe status` | Show whether the AH is ready |
| `/snipe mono` | Turn the monospace chat font on or off |
| `/snipe log` | Log size. `clear`, `on`, `off` |

## Log and CSV export

The log saves to `WTF\Account\<ACCOUNT>\SavedVariables\wb_AHSnipe.lua` on `/reload` or logout.

`tools/export.py` turns it into CSV files next to the script (needs Python and `pip install lupa`):

```
python tools/export.py "<path to>/wb_AHSnipe.lua"
```

- `purchases.csv`: every buy attempt with price, max, timing and result
- `deals.csv`: favorites dips at or under your max, and whether you bought
- `bait.csv`: bait listings seen, with the next real price
- `prices.csv`: Check prices results

Running it again only adds new rows.

## Notes

- Commodities (herbs, ore, cloth) take two presses to buy: one for the server's price quote, one to confirm. Blizzard requires a separate key press for each.
- Every action needs a real key press. The addon never buys on its own.
- DejaVu Sans Mono is free to redistribute; its license is in `fonts/DejaVu-LICENSE.txt`.
