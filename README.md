# Level Outfitter

An addon for **WoW Forever** (Interface 16001). It scans the auction house and builds leveling gear shopping lists from live prices: the best gear your gold can buy for the levels you pick, ready to buy.

**Download:** [LevelOutfitter.zip](https://github.com/Lhug1989/LevelOutfitter/releases/latest/download/LevelOutfitter.zip) (one click, always the newest version)

## What it does

- **Gear lists** for a level range you choose (by default your next 10 levels), rated with stat weights for your class.
- **A gold limit** with Cheapest / Smart / Best, so the list fits what you can spend.
- **Buy buttons**: one click buys one item. Nothing is ever bought without your own click.
- **Consumables** in sections (scrolls, elixirs and drinks, potions, weapon stones, food), each with Buy.
- **A buff bar** that shows a button when a scroll or elixir buff is missing and the item is in your bags.

Classes in this version: all nine (warrior, paladin, hunter, rogue, priest, shaman, mage, warlock, druid), with every leveling spec. The spec and its weapon setup are read from Forever Leveling BiS when that addon is installed; consumables follow the class and spec too.

## Install

1. Download the zip with the link above.
2. Unzip it into `World of Warcraft/_forever_/Interface/AddOns/` (you should end up with a folder `AddOns/LevelOutfitter`).
3. Start the game, open the auction house and press Scan.

Optional: if the addon **Forever Leveling BiS** is installed, Level Outfitter reads its live stat weights. Without it, a built-in copy is used.

## Commands

| Command | What it does |
|---|---|
| `/lo` | opens the window and shows the list of commands |
| `/lo status` | what it is doing and which stat weights are in use |
| `/lo levels 14 24` | shop for levels 14 to 24 (`/lo levels auto` follows your own level) |
| `/lo bar` | the buff bar (on, off, size, height, reset) |

## Credits

Item stats and stat weights come from the addon **Forever Leveling BiS** by Thunder. Item data was checked against Wowhead.
