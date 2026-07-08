# WarlockQol (TBC)

Quality-of-life tools for Warlocks on **TBC Anniversary** (client 2.5.6, `## Interface: 20506`).

Most chat features keep a pool of lines that are chosen at random and sent to chat, fired by
one-click macros the addon generates for you. WarlockQol is **dependency-free** — no Ace3,
LibStub, or other libraries required; it runs standalone on the stock WoW API.

## Features

- **Demon Summon Lines** — per-family lines said in `/say` when you summon a demon (`{demonName}` placeholder).
- **Ritual of Summoning** — a line announced to party/raid when you summon a player (`{targetName}`, `{location}`).
- **Ritual of Souls** — a plain line said in `/say` when cast.
- **Soulstone Announcement** — auto-announces to party/raid when a soulstone is cast in your group.
- **Banish Announcement** — announces your own banishes (separate landed & resisted pools, automatic rank suffix).
- **Raid Cooldown Tracker** — a movable HUD showing each raid warlock's tracked cooldown (Ready / live countdown).
- **Missing Consumables** — a movable HUD flagging missing or soon-to-expire raid consumables (flask / weapon oil / food).
- **Profiles** — per-character config profiles, with copy and share-by-string export/import.

Chat lines support WoW raid target markers (`{star}`, `{skull}`, …) via a quick-insert row.

## Installation

1. Clone or download this repository.
2. Put the `Warlock_Qol_Tbc` folder into your `World of Warcraft\_classic_\Interface\AddOns\` directory
   (cloning the repo already gives you a correctly named `Warlock_Qol_Tbc` folder).
3. Restart the client, or `/reload`, and enable **WarlockQol (TBC)** in the AddOns list.

## Usage

- Type **`/wq`** or click the **minimap icon** to open the configuration window.
- On first login a short setup wizard helps you create the macros — remember to drag each
  `WQoL` macro onto an action bar before use.

## License

Bundled font PT Sans is licensed under the SIL Open Font License — see `Fonts/OFL.txt`.
