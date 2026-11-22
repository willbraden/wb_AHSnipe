# AGENTS.md: wb_AHSnipe

You are working on **wb_AHSnipe**, the user's World of Warcraft: Forever addon for sniping the stock auction house (retail-style AH, client interface 16001). This file tells you what each feature does, how the features depend on each other, and the rules you follow when you change any of them.

The user prefers concise, plain language and no em dashes, in code comments, chat text and replies alike.

## Where things are

| You need | You look at |
|---|---|
| All addon logic | `Core.lua` (one file, sections marked `-- Name ----`) |
| Install time stamp | `Build.lua` (`"dev"` in the repo; the Deck installer overwrites it) |
| Load order and saved data names | `wb_AHSnipe.toc` (`Build.lua`, `Snapshot.lua`, then `Core.lua`; saves `wb_AHSnipeDB`, `wb_AHSnipeLog`) |
| TSM numbers and maxes for machines without TSM | `Snapshot.lua`, written by `tools/snapshot.py` |
| Keybinds | `Bindings.xml` |
| Chat padding texture, chat font | `spacer.tga`, `fonts/mono.ttf` (JetBrains Mono, OFL) |
| Log to CSV export | `tools/export.py` |
| Steam Deck installer and updater | `tools/install-steamdeck.sh` |

In a game install, the addon lives in `<WoW folder>/_forever_/Interface/AddOns/wb_AHSnipe/` and the saved data in `_forever_/WTF/Account/<ACCOUNT>/SavedVariables/wb_AHSnipe.lua`, written only on `/reload` or logout. You find the account folder by looking for `SavedVariables/wb_AHSnipe.lua` under `WTF/Account/`; if there is more than one, you ask which. `tools/export.py` writes its CSVs to the folder you run it from.

## The rules you never break

1. **You never send an AH request while another is waiting.** The AH holds one queued message; a second one knocks the first out. Before any search, quote, confirm or bid, you check `Queued()` (set by `AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED`, cleared on `_SENT` or `_SYSTEM_READY`), `pending` (a refresh in flight) and `buying` (a confirmed purchase in flight). This rule fixed the biggest bug the addon ever had: confirmed buys silently dropped by the next press.
2. **You spend gold only on a real key press.** Quotes, confirms and bids run inside the Snipe keybind or a button click. You never buy from a timer, an event or `OnUpdate`. Searches (refresh, favorites, price check) may run from code; purchases may not.
3. **You never let a buy exceed the max.** A commodity confirm only goes through if the server's quote is at or under `qty × max`. Otherwise you cancel and refresh.
4. **You keep the chat table aligned.** With the mono font on, you pad by visible characters (`Visible()` strips color codes, including the newer `|cnIQ1:` form, and link markup). You never measure chat text in pixels when mono is on.
5. **You test before you hand it over.** After every edit you run a syntax check (`load()` the file in Lua, for example with Python's `lupa`), and for chat or layout logic you run the function against sample data. You back up `Core.lua` before editing it in a live install.

## Features and how they connect

### The Snipe key (`wb_AHSnipe_Buy`)
The one button the user spams. It only ever buys the user's **current favorites** (`IsFav()`, via `C_AuctionHouse.IsFavoriteItem`): a max stays saved after an item is unstarred but does nothing until it's starred again, and `Deals()` skips unstarred items still sitting on a stale favorites list. Each press does the next useful step for the screen they are on:
- **Favorites list:** if Jump is on and a favorite is at or under its max, you open the best one (furthest under max). Otherwise you refresh favorites.
- **Commodity page:** refresh if the list is stale; quote if enough cheap units are listed; confirm once the quote is back; wait while a buy is in flight.
- **Single-item page:** bid on the cheapest listing under max, or refresh.

It reads **Max price**, **Min qty** and **Buy %** from the window, feeds **Win tracking** and the **Log**, prints results to the **Chat tab**, and stays blocked while a **Price check** runs or the **Stale price reminder** is unanswered.

### Refresh and favorites
- `wb_AHSnipe_Refresh` reruns the current search (item page, favorites or text search). It is gated by rule 1 and by a 0.6s gap for manual presses.
- `wb_AHSnipe_Favorites` runs the favorites search and sets `lastBrowse = "fav"`. Hooks on the native star and Search buttons keep `lastBrowse` correct.
- **Jump in and out of favorites** (`DB.roam`): with it on, Snipe opens green favorites, and after 10 presses in a row with nothing under max (`OverMax`) you go back to favorites. If the page has shown nothing under max at all since the jump (not even bait, tracked by `sawUnder`), it goes back after 3 presses instead (`EMPTY_JUMP_BACK`, via `BackLimit()`). Bait (cheap units below Min qty) resets that count, because the user likes staying parked on bait.

### The AH Snipe window
One window to the right of the AH, with four tabs. It follows the AH: the AH's Sell tab switches it to **Sell**, going back switches it to **Snipe**. Setup and Buy % are only opened by a click. `wb_AHSnipe_SelectTab(i)` switches tabs and `wb_AHSnipe_Layout()` sizes the window for the tab.

- **Snipe:** the **Next press** line, then the open item's card (max, Buy %, win rate and average paid this session and all-time). With no item open, the card is replaced by your favorites under max. The Jump checkbox sits at the bottom.
- **Sell:** Bought vs selling.
- **Setup:** default max, Min qty, Check %, general Buy % with Explore, Check prices, and the price check results.
- **Buy %:** win rates per Buy %.

**Next press** (`NextPress()`, also `wb_AHSnipe_NextPress`) mirrors the Snipe key's decisions without sending anything: buy, quote, jump, bait, nothing under max, can't afford, no max, waiting for the server, price check running, or the price reminder. Its border is green (will buy or jump), yellow (waiting), gray (will refresh) or red (blocked). **When you change what the Snipe key decides, you change `NextPress()` the same way**, or the window will say one thing and the key will do another.

**Jump sound:** when the Snipe key jumps from favorites into a deal, `wb_AHSnipe_PlayTick(itemID)` plays the chosen sound (`DB.tickSound`, Ping by default) or speaks the item name with `C_VoiceChat.SpeakText` (falls back to Ping). Setup has the on/off checkbox (`DB.tick`) and a button that cycles and previews the sounds.

### Settings
- **Max price** (gold/silver/copper): saved per item in `DB.caps[itemID]` from the Snipe tab's card, or as `DB.default` from Setup. Everything that asks "is this a deal?" calls `Cap(itemID)`, which is the item's own max (or the default) **lowered to the TSM ceiling** when that's cheaper, or the TSM ceiling alone when neither is set.
- **Max % TSM** (`DB.tsmPct`, default 90, 0 = off): the TSM ceiling is this % of TSM's region sale average (`DBRegionSaleAvg`, what buyers actually paid). `Ceiling()` computes it.
- **Resale gap %** (`DB.gapPct`, default 20, 0 = off): `GapCap()` finds the first listing priced above the max (the next tier, about where you'd relist) and lowers the max for this list to that price minus the gap. The buy and `NextPress()` both apply it ("No resale gap: refresh").
- **Min qty** (`DB.minQty`): commodity buys skip unless at least this many units are under max. This is the bait filter.
- **Buy %**: the share of cheap units each commodity quote asks for, so another buyer taking a few doesn't sink the whole purchase. `DB.itemPct[itemID]` (Snipe tab card) if set, else `DB.buyPct` (Setup). `PickPct()` decides which applies. It tops out at 95% (`MAX_PCT`), and a buy always leaves at least 1 cheap unit, so bait is never bought.
- **Explore** (`DB.explore`, Setup): sits in a box with the general Buy % because it takes it over. While on, both Buy % inputs are locked and `PickPct()` rotates 35/50/66/85%, least-tested first. It keeps its pick for an item until that attempt finishes, so the % the window shows is the % the key uses.
- **Check %** (`DB.checkPct`, default 70): what Price check multiplies market by.

### Price check (`wb_AHSnipe_Check`)
One click loads favorites if needed, then searches every favorite in turn from a driver frame, waiting for the AH between searches. For each item it computes **market**: the price reached after the cheapest 10% of units (at least 5), so bait can't drag it down; for single items, the 25th percentile buyout. Suggested max = market × Check %. Results show under the button on the Setup tab (scrolling list, Set per row, Apply all), are logged as `price_check` rows, and set `DB.lastCheckAt`.

### Sold per day (TSM)
`SoldPerDay(id)` reads TSM's region sold-per-day (`TSM_API.GetCustomPriceValue("DBRegionSoldPerDay", "i:<id>")`, from the TSM desktop app's AppHelper data). `SlowSeller(id)` blocks buying, jumping and the Next press line when it's under **Min sold/day** (`DB.minSold`, default 200, Setup tab; 0 = off). Items TSM has no number for are not blocked, and nothing breaks if TSM isn't installed. The item card shows the number. When the favorites list loads, `CheckSlowFavorites()` prints once which favorites are under Sold/day (skipped) and which have no TSM number; it speaks again only when that list or Sold/day changes.

### TSM snapshot (machines without TSM)
The Steam Deck has no TSM. `Snapshot.lua` stands in: `wb_AHSnipe_Snapshot` holds TSM's region sale average (`sale`) and sold per day (`sold`) for every item, plus the PC's maxes (`caps`, `default`). `SoldValue()` and `SoldPerDay()` ask TSM first and fall back to the snapshot, so the ceiling, Sold/day and the slow-seller notice work everywhere. On a machine without TSM, `ApplySnapshotCaps()` copies the PC's maxes in once per new snapshot (`DB.snapApplied`); maxes changed there afterwards stay until the next snapshot. The PC never applies it (TSM is loaded). **Before every push, you regenerate it on the PC:** `python3 snapshot.py <AddOns>/TradeSkillMaster_AppHelper/AppData.lua <SavedVariables>/wb_AHSnipe.lua <AddOns>/wb_AHSnipe/Snapshot.lua` (the script lives in the user's AH Tracking folder and in `tools/`), then copy `Snapshot.lua` into the repo. It's a new file in the `.toc`, so the first install needs a full game restart.

### Realized profit (live ledger + TSM history)
Snipe keeps its own ledger in `DB.ledger` (started the first time it runs, `start`): every won snipe goes in from `Tally()` via `wb_AHSnipe_LedgerBuy`, and every "Auction successful" mail goes in when the mailbox opens (`ScanMail()` on `MAIL_SHOW` / `MAIL_INBOX_UPDATE`, from `GetInboxInvoiceInfo`: sale minus the AH cut, sent time = now minus (30 minus days left), each mail counted once via `seen`). TSM's saved records (`TradeSkillMasterDB["r@<realm>@internalData@csvSales"]` and `csvBuys`; **sale prices are already after the cut**, per unit) fill in what the ledger can't see: everything before `start`, and AH buys made by hand after it (TSM buys that don't match a ledger snipe by item, qty and 2 minutes). `BuildProfit()` matches sales to buys oldest-first. Units with no AH buy (farmed, crafted) don't count. The Snipe tab's item card and the Sell tab show it per item; `/snipe profit` prints the total, the last 7 days and the top items. `tools/export.py` does the TSM-only version offline (`profit.csv`, `profit_items.csv`, `profit_daily.csv`), so it reflects TSM's last save.

### Market price by hour
Whenever an item's listings load (sniping, jumping, price checks), `RecordMarket()` notes its market price (same math as Price check). At most one sample per item per 10 minutes goes into `DB.mkt[id].h[hour]`, so a long session doesn't outweigh the rest of the day; `m.now` always holds the latest. Usual = the average of the hour averages. The Snipe tab's item card shows market now as a % of usual, and after 4 hours of data, the cheapest and priciest hours. `/snipe market` lists every item, cheapest hour first. Each sample is logged as a `market` row and exported to `market.csv`.

### Stale price reminder
Every time the AH opens, if `DB.lastCheckAt` is 1+ hour old (or missing), a popup offers Check prices. Until the user answers, the Snipe key won't buy. It exists because the user once bought a lot at stale maxes.

### Win tracking and Buy % learning
- `Tally()` runs on every buy result: wins and losses per item, for this session (`session`) and all-time (`DB.stats`), plus per Buy % (`DB.tune[id][pct]`) and per hour (`DB.hourly`).
- The **Buy %** tab shows each item's win rate and tries at each Buy %, marks the best by units won per try (4+ tries), and saves it per item with **Use N%** or **Use best for all items**. `/snipe tune` opens it.
- `/snipe stats` prints the per-item win table to chat.
- **Bought vs selling** (on the AH Sell tab) reads `session` and `DB.stats` to show average cost against the posting price after the 5% AH cut.

### Chat output
- Messages go to a dedicated **AH Snipe** chat tab (`/snipe tab` switches back to main chat).
- `Row()` prints aligned columns: what happened, quantity, item, price, details, your max, win rate. `Fail()` and the Bought lines in the event handler are the main callers. Failed rows and price rises are grayed with `Dim()`.
- The mono font (`/snipe mono`) applies to every chat window; `Row()` relies on it for exact alignment.

### Native AH highlights
- Prices at or under your max turn green in the browse, item and commodity lists.
- Favorites get a `-32%` / `+40%` badge after a 25%+ move between refreshes, and `no max` when they lack a max.

### Logging and analysis
- `L(event, data)` writes rows to `wb_AHSnipeLog.rows` (12,000 kept, trimmed to 6,000). Repeated `key`, `press` and `refresh_skip` rows are folded into one row with a `rep` count.
- Separate saved tables keep favorites snapshots (`favs`), bait listings (`bait`) and item names.
- `tools/export.py` turns the log into `purchases.csv`, `deals.csv`, `bait.csv`, `prices.csv` and `winrates.csv`. The `wb-ahsnipe-log-analysis` skill reads the log and these CSVs.

### Steam Deck
`tools/install-steamdeck.sh` finds `_forever_`, installs from GitHub `main`, remembers the folder, stamps `Build.lua` with the install time (shown at login and by `/snipe version`), logs to `~/.config/wb_AHSnipe/last-update.log`, and keeps an **Update AH Snipe** launcher on the desktop and in Steam.

## How the pieces depend on each other

```
Window ──(Max, Min qty, Buy %)──▶ Snipe key ──▶ AH requests (rule 1 gate)
  ▲ Next press line mirrors ──────────┘
   ▲                                    │
   │ Use N% / Apply all                 ├──▶ Chat tab (Row, Fail)
   │                                    ├──▶ Tally ──▶ stats, tune, hourly
Buy % tab ◀── tune ◀────────────────────┘         │
                                                  └──▶ Bought vs selling
Price check ──(Check %)──▶ suggested maxes ──▶ Max (Setup results)
     ▲
Stale reminder (lastCheckAt) ──blocks──▶ Snipe key
Favorites refresh ──▶ Jump ──▶ item page ──(10 empty presses)──▶ back to favorites
Everything ──▶ L() log ──▶ export.py CSVs ──▶ analysis skill
```

## When you change something

- **You add a setting:** you store it in `wb_AHSnipeDB`. A per-item setting goes on the Snipe tab's card; a general one goes on Setup. You build it with `BigBox()` or a checkbox, refresh it in `UpdateSnipePage()` or `UpdateSetupPage()` so it always shows the saved value, and mention it in `README.md`.
- **You add an AH request:** you route it through the same checks as `wb_AHSnipe_Refresh` (rule 1), and you log it with `L()`.
- **You add a chat line:** you print it with `Row()` so it stays aligned, and you pass a `MaxCell()` and `WinCell()` if it is about an item.
- **You add a window or panel:** you don't. You add it to one of the window's tabs (or a new tab in `BuildBox()`), and size it in `wb_AHSnipe_Layout()`.
- **You add a log event:** you document it in the analysis skill's event table, and in `export.py` if a CSV should use it.
- **You add a top-level `local`:** you remember WoW's Lua allows 200 per file. `Core.lua` is close; split into files (and list them in the `.toc`) before adding many more.
- **You ship it:** you copy the files to the user's `AddOns/wb_AHSnipe` folder and stamp `Build.lua` with the time and commit (or push to GitHub when they ask, after regenerating `Snapshot.lua`), and you tell them whether `/reload` is enough or a full restart is needed (new files such as fonts or textures need a restart).
