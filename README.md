# WoWCensus

A World of Warcraft add-on that counts who's online on your realm, using `/who` in the background while you play. The results help build the realm population numbers on [wowcensus.io](https://wowcensus.io).

It works on Retail, Classic Era, Season of Discovery, TBC Anniversary, MoP Classic and Forever.

## Install

1. Download the latest version from the [Releases](https://github.com/wowcensus/addon/releases) page.
2. Unzip it and put the `WoWCensus` folder into `World of Warcraft/<your game version>/Interface/AddOns/`. For example, use `_retail_` for Retail or `_classic_era_` for Classic Era.
3. Restart WoW and make sure **WoWCensus** is ticked in the AddOns list on the character screen.

## Using it

Just play. The add-on starts on its own when you log in, and moves forward a step each time you walk or click in the game world. WoW only allows `/who` after real player input, so it can't run by itself while you're idle.

- `/wc` or the minimap button opens the window and shows progress.
- If it asks for your region, type `/wc region us`. Use `eu`, `kr`, `tw` or `cn` if that's your region.
- **Auto: On / Off** in the window pauses or resumes it. Right-clicking the minimap button does the same.
- `/wc minimap` shows or hides the minimap button.
- On Retail, the add-on also passively records names exposed by joined chat-channel rosters. Use `/wc roster` (or `/wcroster`) to scan immediately and print channel totals. Use `/wc roster off` or `/wc roster on` to control channel collection separately.

## Other add-on data (optional)

WoWCensus can also copy what some popular add-ons already record about your own play, so wowcensus.io can show things like how long items take to sell. This is **off by default**. Turn it on with the **Collect other addon data** box in the window, or `/wc market on` (`/wc market off` turns it off again).

When it's on, WoWCensus copies from whichever of these you have installed:

- **Journalator**: your auction posts, sales, purchases, expired and cancelled auctions, vendor buys and sells, repairs, quests, loot, flight paths, trainer costs, mail and trades.
- **TradeSkillMaster**: your auction sales, purchases, expired and cancelled auctions.
- **Auctionator**: your posting history.
- **Dungeon Journal**: everything it saves, such as dungeon runs, kills and the quest text it has learned.

Other players' names, mail subjects and mail text are never copied. Only the last 90 days are kept. If none of these add-ons are installed, nothing happens.

## Share your results

To send your results to wowcensus.io automatically, install the [WoWCensus Companion](https://github.com/wowcensus/companion) app. Without it, the data stays on your computer.
