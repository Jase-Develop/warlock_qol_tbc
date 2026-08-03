## WarlockQol (TBC) - Changelog

All notable player-facing changes are listed here, newest first.

### [0.26] - 2026-08-03

#### Added
- **Loss of Control (Beta)** - announces when you lose control of your character, so the people around
  you know you are out of action and can dispel you, drop a Tremor Totem or break the mind control.
- The announce **names what hit you and how long it lasts** rather than saying something generic, for
  example ">> Stunned! (4s) <<". Six categories, each with its own toggle: fear, mind control,
  incapacitate, stun, silence and root, all on once you switch the feature on. Untick any you would
  rather not announce; stun in particular can be chatty on some fights.
- Inside a dungeon or raid it is **said out loud**, so it appears as a speech bubble over your character
  where the person who can help is already looking, rather than as a line scrolling past in group chat.
  Out in the world the game does not allow an addon to speak, so it falls back to party or raid chat
  there, with independent Party and Raid toggles like the Soulstone and Banish announcers.
- Detection needs **no spell list**, so nothing needs updating as you meet new bosses.
- **Only while in combat** (on by default) filters out the harmless cases the game reports the same way,
  most obviously flight paths. There is also an optional local chat echo, on by default, which is what
  you see when there is nowhere to announce.
- Like every beta feature, **the whole thing is off until you turn it on**, under the **Beta** section.

#### Changed
- The addon's CurseForge description now lists the Range Indicator and Curse Tracker, which it had been
  missing.

### [0.25] - 2026-07-23

#### Added
- **Curse Tracker (Beta)** - a new HUD listing the curses your group's warlocks currently have out, in
  a new **Beta** menu section. Each row shows who cast it, the target (with its raid marker), which
  curse, and the time remaining, turning red in the last 10 seconds. It tracks every cursed mob, not
  just your current target, and your own curses sort to the top, followed by whichever is closest to
  dropping. Curse of the Elements, Recklessness, Weakness and Tongues are each tracked with their own
  toggle.
- Because it is a beta feature, **everything about it is off until you turn it on**: the feature
  itself, Show HUD, and both auto-show options all default to off. Nothing changes for anyone who does
  not go looking for it. The HUD also hides itself whenever no curses are active (optional), and it has
  a padlock and its own opacity setting like the other HUDs.

### [0.24] - 2026-07-20

#### Fixed
- Fully stopped the Range Indicator "tried to call the protected function" errors (v0.23 only covered
  part of it). The distance check now skips its item-based checks while you are in combat and targeting
  something you cannot attack (a friendly player or NPC), which is the case the game now blocks. In that
  situation a friendly target may show "(?)" instead of a distance; attackable targets are unaffected
  and everything works normally out of combat.

### [0.23] - 2026-07-20

#### Fixed
- Stopped the Range Indicator from spamming "AddOn tried to call the protected function" errors after
  a recent game update. The distance check now uses the current, combat-safe range API, falling back
  to the older one only on clients that lack it.

### [0.22] - 2026-07-20

#### Changed
- Maintenance release: no in-game changes. Repository and packaging cleanup only (the packaged
  addon no longer bundles an internal development file).

### [0.21] - 2026-07-20

#### Added
- **Soulstone** and **Banish** announcements each gained independent **Announce in party** and
  **Announce in raid** toggles (both on by default), so you can choose which group type they fire in.
  The top-right Enabled switch still turns the whole feature off.
- **Cooldowns** and **Missing Consumables** now work in a **party** as well as a raid, each with a new
  **Auto-show in party** option (off by default). The cooldown tracker now also shows and shares other
  party members' cooldowns, not just your own.

#### Changed
- Renamed **Raid Cooldowns** to **Cooldowns** and grouped it with Soulstone, Banish, Consumables and
  Range Indicator under a single **Party/Raid** menu section.
- A round of appearance and layout tidy-ups across the menu (spacing, alignment, wording and page
  organisation) for a cleaner, more consistent look. The addon font is now fixed to the game's Arial Narrow.

### [0.20] - 2026-07-17

#### Changed
- **Backdrop opacity** is now set separately for the main window and for each HUD (Raid Cooldowns,
  Missing Consumables, Range Indicator). Each HUD's slider lives on its own page; the main window's
  stays on the Settings page. The percentage is now literal, so 100% is fully solid. Note that on
  first load the HUDs will look a little more solid than before at the default 80%; drag each one
  down if you preferred them lighter.

### [0.19] - 2026-07-17

#### Added
- New **Settings** page in the menu, for how the addon looks. Everything on it is saved to the
  active profile, so your look travels with an exported profile.
- **UI font**: pick the font used across the whole addon, menus and HUDs alike. All of the
  choices come with the game.
- **Accent colour**: choose your own highlight colour for selections, headings and borders
  instead of the fixed purple. Click the swatch to open the colour picker; it previews live as
  you drag it.
- **Backdrop opacity**: set how see-through the background of the window and the HUDs is, with
  a slider or by typing an exact percentage. Text, icons and borders stay solid at any setting.

### [0.18] - 2026-07-15

#### Fixed
- **Range Indicator** now sizes itself to fit the target's name instead of cutting off longer
  ones. It grows with the **Text size** setting too, so a larger font no longer clips the name.
- **Range Indicator** now shows a range for friendly NPCs, which previously always read `(?)`.
  The game gives no precise distance for them, so expect a wider bracket than usual and no
  reading past about 28 yards.

### [0.17] - 2026-07-15

#### Added
- **Range Indicator** a new movable HUD that shows your current target's name and your
  distance to it as a yard range (e.g. 35-40). Find it under **Range Indicator** in the menu; it's off by default,
  so switch it on when you need it.

### [0.16] - 2026-07-14

#### Added
- Missing Consumables now tracks **Elixirs** (the two warlock caster elixirs: Major Shadow
  Power and Major Firepower). It's **off by default**, since you can't use an elixir together
  with a flask.

### [0.15] - 2026-07-14

#### Added
- Raid Cooldowns HUD now has a **Soulstone Active** section showing which players currently
  have a soulstone on them and how long it has left so you can see at a glance who's still
  covered (and who used theirs). CTRL+Click a name to announce it to the group.

#### Changed
- The old **Soulstone** tracking toggle is now labelled **Soulstone CD** (the warlock's
  cooldown), to tell it apart from the new **Soulstone Active** tracker above.
- Raid Cooldowns HUD: the group announcement (CTRL+Click a warlock's row) now reads
  "Name: Soulstone **CD** - 17:34 remaining", so it's clear you're calling out the
  cooldown timer, not a soulstone that's active on someone.
- Hardened the raid cooldown-sharing messages against spam and malformed data from other
  players (rate-limited resync replies; sanity-clamped incoming timers).

### [0.14] - 2026-07-13

#### Fixed
- Raid Cooldown Tracker HUD now reliably pops up when you zone into a raid (it could
  previously fail to auto-show on entering the instance).
- Missing Consumables HUD: the **Show HUD** toggle and the close (**X**) button now always
  work while you're in a raid - auto-show no longer forces the strip back on.

### [0.13] - 2026-07-12

Initial public release on CurseForge. Quality-of-life tools for Warlocks on TBC Anniversary
(2.5.6):

- **Pet Summon Lines** - say a random line in /say when you summon each demon, with the
  demon's name auto-filled.
- **Ritual of Summoning** - announce to party/raid when you summon someone, with target
  name and location filled in.
- **Ritual of Souls** - say a random line when you conjure the soulwell.
- **Ritual of Souls** and **Soulstone** announcements to your group.
- **Soulstone Announcement** - automatically tells your group when a soulstone is cast on a
  group member.
- **Banish Announcement** - announce your own banishes landing (and resists), with the
  spell rank added automatically.
- **Raid Cooldown Tracker** - a movable HUD showing every raid warlock's soulstone
  cooldown: who's Ready and who's on a live countdown. CTRL+Click a row to call it out to
  your group.
- **Missing Consumables** - a movable HUD that pops up in a raid to remind you what you're
  missing or about to lose (flask, weapon oil, well-fed food), and hides when you're all set.
  Optional glow, countdown, and transparent mode.
- **Profiles** - save multiple line/setting sets and switch between characters, plus
  export/import to share a profile with other players as a copy-paste string.
- **Minimap button** and a one-click **/wq** window to configure everything.
