# wb_AHSnipe

A World of Warcraft: Forever addon for fast auction house sniping with the stock AH window. One key refreshes, quotes and buys anything listed under your max price, without jamming the auction house.

## Features

- **One-button snipe.** Each press does the next step: refresh, quote, confirm, then refresh again after a buy.
- **Max price per item.** Set it in the box at the bottom right of the AH. It's saved per item, with a default for everything else.
- **Min quantity for commodities.** Skips bait listings of 1 (or whatever minimum you set).
- **Buys every unit under your max** for commodities, capped at what you can afford.
- **Green prices** in the native AH lists for anything at or under your max.
- **Quick Post.** Drop an item on the panel beside the AH, set a price, and post 1 per press. Remembers the price per item.
- **Never jams the AH.** It won't send a new request while one is still waiting, so a confirmed purchase can't be knocked out by your next press.
- **Session log** for debugging timing (`/snipe log`).

## Install

Copy the `wb_AHSnipe` folder into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

Then `/reload` or restart the game.

## Setup

1. In Keybindings, under **wb_AH Snipe**, bind **Snipe (one button: refresh, quote, buy)**. Optional: **Quick Post 1** and **Refresh AH**.
2. Open the AH, click into an item, and type your max price (in gold) in the box at the bottom right. `.01` = 1 silver.
3. Spam the Snipe key.

Prefer macros? Use these:

```
/run wb_AHSnipe_Buy()
/run wb_AHSnipe_Refresh()
/run wb_AHSnipe_Post()
```

## Commands

| Command | What it does |
| --- | --- |
| `/snipe max <gold>` | Max for the open item, or your default if none is open |
| `/snipe default <gold>` | Default max for items without their own |
| `/snipe clear` | Remove the open item's max |
| `/snipe status` | Show whether the AH is ready |
| `/snipe log` | Log size. `clear`, `on`, `off` |

The log saves to `WTF\Account\<ACCOUNT>\SavedVariables\wb_AHSnipe.lua` on `/reload` or logout.

## Notes

- Commodities (herbs, ore, cloth) take two presses to buy: one to get a price quote from the server, one to confirm. Blizzard requires a separate key press for each.
- Every action needs a real key press. The addon never buys on its own.
