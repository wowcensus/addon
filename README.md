# WoWCensus

A World of Warcraft add-on that counts who's online on your realm, using `/who` in the background while you play. The results help build the realm population numbers on [wowcensus.io](https://wowcensus.io).

It works on Retail, Classic Era, Season of Discovery, TBC Anniversary, MoP Classic and Forever.

## Install

1. Download the latest version from the [Releases](https://github.com/wowcensus/addon/releases) page.
2. Unzip it and put the `WoWCensus` folder into `World of Warcraft/<your game version>/Interface/AddOns/`. For example, use `_retail_` for Retail or `_classic_era_` for Classic Era.
3. Restart WoW and make sure **WoWCensus** is ticked in the AddOns list on the character screen.

## Using it

Just play. The add-on starts on its own when you log in, and moves forward a step each time you walk or click in the game world. WoW only allows `/who` after real player input, so it can't run by itself while you're idle.

- `/wc` opens the window and shows progress.
- If it asks for your region, type `/wc region us`. Use `eu`, `kr`, `tw` or `cn` if that's your region.
- **Auto: On / Off** in the window pauses or resumes it.

## Share your results

To send your results to wowcensus.io automatically, install the [WoWCensus Companion](https://github.com/wowcensus/companion) app. Without it, the data stays on your computer.
