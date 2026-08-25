# WarlockQol (TBC)

Quality-of-life tools for Warlocks on **TBC Anniversary**

Most chat features keep a pool of lines that are chosen at random and sent to chat. The summon and
ritual lines fire from one-click macros the addon generates for you; the rest announce automatically
off game events. WarlockQol is **dependency-free**. It runs stand-alone on the stock WoW API (a personal goal of mine).

## Features

- **Demon Summon Lines** - per-family lines said in `/say` when you summon a demon.
- **Ritual of Summoning** - a line announced to party/raid when you summon a player.
- **Ritual of Souls** - a plain line said in `/say` when cast.
- **Soulstone Announcement** - auto-announces to party/raid when a soulstone is cast in your group. Quiet in battlegrounds and arenas unless you opt in.
- **Banish Announcement** - announces your own banishes (separate landed & resisted pools, automatic rank suffix). Same battleground/arena opt-in.
- **Loss of Control** - announces when you lose control of your character (fear, mind control,
  incapacitate, stun, silence, root), naming the effect and how long it lasts, so the people around you
  know you are not driving. Said out loud inside an instance, sent to party/raid out in the world. Needs
  no spell list, so nothing needs updating as you meet new bosses. Same battleground/arena opt-in.
- **Cooldown Tracker** - a movable HUD showing each party/raid warlock's soulstone cooldown (Ready or a
  live countdown), and below it who currently has a soulstone on them with the time left. Ctrl+click any
  row to announce it to your group.
- **Missing Consumables** - a movable HUD flagging missing or soon-to-expire raid consumables (flask,
  weapon oil, food buff and elixir). It stays hidden while nothing needs attention.
- **Curse Tracker** - a movable HUD listing the curses your group's warlocks have out on any mob:
  who cast it, the target and its raid marker, which curse, and the time remaining. Auto-shows when you
  enter a raid.
- **Range Indicator** - a movable text HUD showing your current target's name and your distance to it as a yard range.
- **Profiles** - per-character config profiles, with copy and share-by-string export/import.
- **Appearance** - pick the accent colour and set the backdrop opacity of the window and each HUD
  independently. Saved per profile, so a shared profile carries your look with it.

Chat lines support WoW raid target markers (`{star}`, `{skull}`, …) via a quick-insert row.

## Installation

**From CurseForge** (recommended, and what auto-updaters such as WowUp follow):
install [WarlockQol (TBC)](https://www.curseforge.com/projects/1607660).

**From source:**

1. Download or clone this repository.
2. Copy its contents into a folder named exactly `Warlock_Qol_Tbc` under
   `World of Warcraft\_anniversary_\Interface\AddOns\`. The spelling and capitalisation matter: the
   addon identifies itself by its folder name, so it will not load from one named differently. Note
   that cloning gives you a lowercase folder with the files at its top level, so rename it.
3. Restart the client, or `/reload`, and enable **WarlockQol (TBC)** in the AddOns list.

## Usage

- Type **`/wq`** or click the **minimap icon** to open the configuration window.
- On first login a short setup wizard helps you create the macros - remember to drag each
  `WQoL` macro onto an action bar before use.
- The **Enabled** checkbox in the title bar is a master switch: it silences every feature at once
  without disturbing their individual settings.

## License

Copyright (C) 2026 Jase-Develop

WarlockQol (TBC) is free software: you can redistribute it and/or modify it under the terms of
the **GNU General Public License v3.0** as published by the Free Software Foundation. It is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY. See the full license
text in [`LICENSE`](LICENSE), or <https://www.gnu.org/licenses/gpl-3.0.html>.
