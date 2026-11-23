# wb_AHSnipe

A World of Warcraft: Forever addon for fast auction house sniping with the stock AH window. One key refreshes, quotes and buys anything listed under your max price, jumps to deals on your favorites list, and never jams the auction house.

## Features

- **One-button snipe.** Each press does the next step: refresh, quote, confirm, then refresh again after a buy.
- **Post your own bait (experiment).** Check **Bait** on the Snipe tab's item card and Snipe keeps 1 of that item listed at your max, posting it on a press that would otherwise just refresh. Sellers who undercut the lowest price then post under it, where you can snipe them. Needs the item in your bags; at most once a minute and 10 times per item per session.
- **Stay on an item.** Check **Stay** on the Snipe tab's item card (or `/snipe stay`) and Snipe won't jump back to favorites from that item until you uncheck it.
- **Jump sound.** Plays when Snipe jumps from your favorites into an item that's under your max. Pick the sound (Ping, Coins, Whisper, Raid warning, Soft click, or Say item, which speaks the item name with the game's text to speech) or turn it off on the Setup tab.
- **Profit on every buy.** Each Bought line shows what that buy should make when you resell it (at TSM's sale average, after the AH cut) and your expected gold per hour and total so far this session, counting only time the AH is open.
- **Next press line.** The AH Snipe window says what your next press will do and why: buy, quote, jump to a deal, bait, nothing under max, can't afford, waiting for the server. Green means it will buy or jump, gray means it will refresh, red means something is blocking it.
- **One window, four tabs.** **Snipe** shows the next press and the open item (its max, Buy %, win rate and average paid), or your favorites under max when no item is open. **Sell** shows Bought vs selling. **Setup** holds your defaults, Explore and Check prices. **Buy %** shows win rates. The window follows the AH's own Buy and Sell tabs.
- **Never jams the AH.** It won't send a new request while one is still waiting, so a confirmed purchase can't be knocked out by your next press.
- **Max price per item**, set in AH-style gold, silver and copper boxes (click to select, type, Enter). Items without their own max use your default.
- **Min qty** for commodities. Skips bait listings smaller than this (never less than 2). If you stay parked on bait for 400 presses with no real deal, Snipe buys the bait so you can move on.
- **Buy %.** Each commodity buy asks for this share of the cheap units, so another buyer taking a few doesn't sink your whole purchase. It tops out at 95% and always leaves at least 1 cheap unit on the list.
- **Favorites mode.** On your favorites list, Snipe opens the best deal (furthest under its max). After 10 presses with nothing under max, it goes back to favorites, or after 3 if the cheap units were already gone when it landed (no deal and no bait). A checkbox (or keybind) turns this off so you can camp one item.
- **Check prices.** One click checks every favorite automatically and suggests a max at your **Check %** of market (default 70%). If it's been an hour since your last check, opening the AH asks you to check first, and Snipe won't buy until you answer.
- **Explore Buy %.** Rotates Buy % (35 to 85%) to learn what wins per item. The **Buy %** tab shows win rate and tries for each, and saves the best per item.
- **Realized profit.** Records your snipes and every sale mail live when you open the mailbox, and uses TSM's records for history and buys you made by hand. Each sale is matched to what you paid (oldest units first, after the AH cut). The Snipe and Sell tabs show profit, margin and days to sell per item; `/snipe profit` shows your total, the last 7 days and your best items. The CSV export writes `profit.csv`, `profit_items.csv` and `profit_daily.csv`.
- **TSM buy ceiling.** Never pays more than **Max % TSM** (default 90%) of what buyers actually paid across the region (TSM's sale average). Items without their own max use it as their max, so new favorites work right away.
- **Resale gap.** Only buys units at least **Resale gap %** (default 20%) under the next price tier above your max, about where you'd relist them.
- **Works without TSM (Steam Deck).** Each update carries a snapshot of TSM's sale averages and sold per day, plus your PC's max prices, so the buy ceiling and Sold/day work on a machine without TSM. Your PC's maxes are copied in once per new snapshot.
- **Sold per day (TSM).** If you use TSM with its desktop app, Snipe skips items that sell fewer than **Sold/day** across the region (default 200, Setup tab, 0 turns it off). Items TSM has no number for aren't blocked.
- **Market price by hour.** Every time an item's listings load, its market price is noted by hour of day (at most every 10 minutes per item). The Snipe tab shows the market now as a % of usual and, once it has 4 hours of data, the cheapest and priciest hours. `/snipe market` lists every item; the CSV export adds `market.csv` for charts.
- **Bought vs selling.** On the AH's Sell tab, shows what you paid for that item (this session and all-time average), the price you're posting at after the 5% AH cut, and your profit per unit and in total.
- **Green prices** in the native AH lists for anything at or under your max, plus `-32%` / `+40%` badges on favorites that moved 25% or more between refreshes and a `no max` tag on favorites without a max.
- **Its own "AH Snipe" chat tab** with table-style results for buys, failures and price moves, each showing your max and your win rate for that item. Failures and price rises are grayed out. Columns line up exactly with the bundled monospace font (JetBrains Mono); `/snipe tab` sends messages back to your main chat.
- **Session log** of every press, search, quote and purchase, plus a saved list of bait listings.

## Install

Copy the `wb_AHSnipe` folder into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

Restart the game (new files such as the font are only picked up on a full restart).

### Steam Deck / Linux

From Desktop Mode, in Konsole:

```
curl -fsSL https://raw.githubusercontent.com/willbraden/wb_AHSnipe/main/tools/install-steamdeck.sh | bash
```

It finds your `World of Warcraft/_forever_` folder (Steam Proton prefix, SD card, Heroic or Lutris), downloads the latest version and installs it. It remembers the folder and adds an **Update AH Snipe** icon to your desktop: double-click it to update, or right-click it > Add to Steam to update from Game Mode (it runs without a window there). Each update stamps the install time; the AH Snipe chat tab shows "Installed: <time>" at login (or `/snipe version`), and the full output is in `~/.config/wb_AHSnipe/last-update.log`. If it can't find WoW, pass the folder: `bash install-steamdeck.sh "/path/to/World of Warcraft/_forever_"`.

## Setup

1. In Keybindings, under **wb_AH Snipe**, bind:
   - **Snipe (one button: refresh, quote, buy)**
   - **Refresh favorites**
   - Optional: **Refresh AH**, **Check prices**, **Toggle jumping in and out of favorites**
2. Open the AH. In the AH Snipe window to the right, set a default max on the **Setup** tab, or click into an item and set its own max on the **Snipe** tab.
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
| `/snipe tune` | Open the Buy % tab (`/snipe tune apply` saves each item's best) |
| `/snipe explore` | Turn Explore Buy % on or off |
| `/snipe version` | Show when this copy was installed |
| `/snipe stats` | Win rate, units and average price per item this session (`/snipe stats all` for all-time) |
| `/snipe status` | Show whether the AH is ready |
| `/snipe mono` | Turn the monospace chat font on or off |
| `/snipe tab` | Use the AH Snipe chat tab, or your main chat |
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
- JetBrains Mono is free to redistribute under the SIL Open Font License; see `fonts/JetBrainsMono-OFL.txt`.
