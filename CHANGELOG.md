## WarlockQol (TBC) - Changelog

All notable player-facing changes are listed here, newest first.

---

### [0.17] - 2026-07-15

#### Added
- **Range Indicator** a new movable HUD that shows your current target's name and your
  distance to it as a yard range (e.g. 35-40). Find it under **Range Indicator** in the menu; it's off by default,
  so switch it on when you need it.

---

### [0.16] - 2026-07-14

#### Added
- Missing Consumables now tracks **Elixirs** (the two warlock caster elixirs: Major Shadow
  Power and Major Firepower). It's **off by default**, since you can't use an elixir together
  with a flask.

---

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

---

### [0.14] - 2026-07-13

#### Fixed
- Raid Cooldown Tracker HUD now reliably pops up when you zone into a raid (it could
  previously fail to auto-show on entering the instance).
- Missing Consumables HUD: the **Show HUD** toggle and the close (**X**) button now always
  work while you're in a raid - auto-show no longer forces the strip back on.

---

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
