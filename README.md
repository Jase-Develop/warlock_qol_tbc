# WarlockQol (TBC)

Quality-of-life tools for Warlocks on **TBC Anniversary**

Most chat features keep a pool of lines that are chosen at random and sent to chat, fired by
one-click macros the addon generates for you. WarlockQol is **dependency-free**. It runs stand-alone on the stock WoW API (a personal goal of mine).

## Features

- **Demon Summon Lines** - per-family lines said in `/say` when you summon a demon.
- **Ritual of Summoning** - a line announced to party/raid when you summon a player.
- **Ritual of Souls** - a plain line said in `/say` when cast.
- **Soulstone Announcement** - auto-announces to party/raid when a soulstone is cast in your group. Quiet in battlegrounds and arenas unless you opt in.
- **Banish Announcement** - announces your own banishes (separate landed & resisted pools, automatic rank suffix). Same battleground/arena opt-in.
- **Cooldown Tracker** - a movable HUD showing each party/raid warlock's tracked cooldown (Ready / live countdown).
- **Missing Consumables** - a movable HUD flagging missing or soon-to-expire raid consumables.
- **Range Indicator** - a movable text HUD showing your current target's name and your distance to it as a yard range.
- **Curse Tracker** *(beta)* - a movable HUD listing the curses your group's warlocks have out on any mob:
  who cast it, the target and its raid marker, which curse, and the time remaining. Off by default; turn it
  on under the **Beta** section.
- **Loss of Control** *(beta)* - announces when you lose control of your character (fear, mind control,
  incapacitate, stun, silence, root), naming the effect and how long it lasts, so the people around you
  know you are not driving. Said out loud inside an instance, sent to party/raid out in the world. Needs
  no spell list, so nothing needs updating as you meet new bosses. Off by default; turn it on under the
  **Beta** section.
- **Profiles** - per-character config profiles, with copy and share-by-string export/import.

Chat lines support WoW raid target markers (`{star}`, `{skull}`, …) via a quick-insert row.

## Installation

1. Clone or download this repository.
2. Put the `Warlock_Qol_Tbc` folder into your `World of Warcraft\_anniversary_\Interface\AddOns\` directory.
3. Restart the client, or `/reload`, and enable **WarlockQol (TBC)** in the AddOns list.

## Usage

- Type **`/wq`** or click the **minimap icon** to open the configuration window.
- On first login a short setup wizard helps you create the macros - remember to drag each
  `WQoL` macro onto an action bar before use.

## License

Copyright (C) 2026 Jase-Develop

WarlockQol (TBC) is free software: you can redistribute it and/or modify it under the terms of
the **GNU General Public License v3.0** as published by the Free Software Foundation. It is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY. See the full license
text in [`LICENSE`](LICENSE), or <https://www.gnu.org/licenses/gpl-3.0.html>.
