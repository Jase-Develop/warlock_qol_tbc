## WarlockQol (TBC) - Changelog

All notable player-facing changes are listed here, newest first.

### [0.32] - 2026-08-28

Housekeeping. The addon has a proper icon in the game's AddOn list, and the install instructions no
longer describe steps that cannot work.

#### Added
- **An icon in the AddOn list.** WarlockQol showed a plain question mark beside its name on the AddOns
  screen. It now uses the same Subjugate Demon artwork as the minimap button and the window's title
  bar, so it is easy to pick out of a long list. Nothing extra is bundled to do this: it uses artwork
  already in the game.

#### Fixed
- **The install-from-source steps could not work.** They told you to move a `Warlock_Qol_Tbc` folder
  out of a download, but a download gives you a lowercase folder with the files loose inside it and no
  such folder to move. Followed literally they left you with an addon that loaded and then quietly did
  nothing at all, because the addon checks its own folder name exactly. The steps now tell you to name
  the folder `Warlock_Qol_Tbc` yourself. This only ever affected installing from source. The CurseForge
  download, and anything installed through WowUp, were always correct.

#### Notes
- **The README now links to CurseForge**, which is the recommended way to install and what WowUp
  follows. It also covers three things that were in the addon but never written down: the cooldown
  HUD's second section listing who currently has a soulstone (and that ctrl+clicking a row announces
  it), what Missing Consumables actually tracks and the fact that it hides itself when nothing needs
  attention, and the accent colour and backdrop opacity settings.
- **Phase 3 did not change the game client**, which is still 2.5.6, so this release needs no
  compatibility update.

### [0.31] - 2026-08-25

Loss of Control is out of beta, and it now speaks up for crowd control that starts a fight.

#### Changed
- **Loss of Control is no longer beta.** It moved out of the **Beta** menu section and now sits under
  **Party/Raid** with the other announcers, between Banish and Consumables. The **Beta** section has gone
  with it, as that was the last page in it. Everything the label was warning about has now been tested
  in-game: it speaks up properly inside an instance, the battleground/arena opt-in behaves itself, and
  the announce lands in a real group.
- With that, it starts up like the Soulstone and Banish announcers instead of switched off: the feature
  is **on**, with all six effect categories ticked.
- **"Only while in combat" now starts off**, so crowd control that lands before a fight begins is
  announced. The case that matters is a **rogue's sap**: it can only land out of combat and it does not
  put you in combat, so it was never announced at all before. Stealth openers and the sneaking assassins
  in Shadow Labyrinth and Shattered Halls are the same story. A session with it off turned up nothing
  unwanted, which fits: flight paths do not reach this feature, and being dazed is ignored on purpose.
  Tick it on the Loss of Control page if you would rather only hear about crowd control mid-fight.
- The page's note on that option used to give a flight path as its example. That stopped being true in
  0.30, when the old backup detection was removed, so it now says what the option actually costs you.
- **Your existing settings carry over.** If Loss of Control is switched off for you, or you have "Only
  while in combat" ticked, it stays that way: the new defaults only apply to a brand new profile. Change
  them on the page, or use Hard Reset to start over.

### [0.30] - 2026-08-19

Loss of Control (still **beta**) got a lot more accurate. It now tells you **what** hit you.

#### Changed
- **Announces name the effect.** A sheep reads **"Polymorphed! (10s)"** instead of the general
  "Incapacitated!", and a counterspell reads **"Interrupted!"**. Where the game only reports the broad
  kind of effect the wording is unchanged, so a line is never less informative than before. This is as
  specific as the game gets: effects that work the same way share a name, so a gouge and a repentance
  both still read "Incapacitated!".
- **A real mind control says so.** The game calls both a priest's Mind Control and a succubus's
  Seduction "Charmed", since mechanically they are the same kind of effect. They are not the same
  problem for your group, so a mind control now reads **"Mind controlled!"** and a seduction
  **"Charmed!"**.
- **The tick boxes have not changed**, deliberately: **Incapacitate** is the honest name for the switch
  governing sheep, gouge, repentance and hibernate together. Only the message got more specific.

#### Fixed
- **A lot more is caught.** Being **sheeped, sapped, frozen, cycloned or banished** announced nothing
  at all before, and a **kick or counterspell** did not count as a silence. All of them now announce
  under the tick box you would expect.
- **Fears announce with their duration**, like stuns and roots always have.
- **Crowd control that starts a fight is announced properly.** With **Only while in combat** ticked,
  anything that opened the fight used to be announced as a generic "Feared!" with no duration, whatever
  it really was, because the game had not registered you as in combat yet. Some effects, silences
  especially, were dropped entirely. That is fixed, and the announce is quicker than it was.
- **Detection is now a single, more accurate path.** A backup detector used to run alongside the main
  one for anything it might miss, but it could not tell what had actually hit you and said "Feared!"
  regardless. Everything is now confirmed working through the main detection, so it is gone.

#### Notes
- **Sap needs "Only while in combat" turned off.** A rogue can only sap you out of combat and the sap
  does not put you in combat, so with that option ticked (the default) it is never announced. Untick it
  on the Loss of Control page if you want saps called out, which is worth it in a heroic and in PvP.
  Whether that option should stay on by default is under review for a later version.
- **Daze and disarm stay ignored on purpose.** Ordinary melee dazes you constantly while running, and
  neither is something anyone else can help with, so announcing them would just be noise.

### [0.29] - 2026-08-13

#### Changed
- **The Cooldowns page has merged into the Soulstone page.** Both were about soulstones, and the cooldown
  tracker was only ever going to track the one, so keeping them apart cost you a menu item and a page for
  nothing. **Soulstone** now has a **Cooldowns HUD** half (show, auto-show and opacity) above an
  **Announcement** half (the party/raid/BG toggles and your line pool), and the **Cooldowns** menu item
  is gone.
- The page's **Enabled** toggle now covers both halves. If you want the cooldown HUD without the chat
  announces, untick Party, Raid and BG/Arena under Announcement: the HUD keeps running.
- **The "Soulstone CD" and "Soulstone Active" tick boxes are gone.** Both are just what the cooldown HUD
  does now: it shows who has the cooldown running and who is currently carrying a stone, and the page's
  Enabled toggle is the switch for all of it. Nothing was lost, there is simply one less thing to set.
- Your existing settings all carry over.
- **The Curse Tracker is no longer beta.** It moved out of the **Beta** menu section and now sits under
  **Party/Raid** with the other group HUDs, between Consumables and Range Indicator. It has been tested
  in a raid since 0.25, including the multi-warlock and target-death cases, so there was nothing left
  for the label to warn about.
- With that, it now starts up like its neighbours instead of switched off: the feature is **on**,
  **Auto-show in raid** is **on**, and Auto-show in party stays off. All four curses are tracked.
- **Hide when no curses are active** now defaults **off**, so the HUD appears with a "No curses active"
  placeholder when you first walk into a raid. That is deliberate: a HUD that hides itself until a curse
  lands is one you cannot find in order to drag it where you want it. Tick the option once it is parked.
- **Missing Consumables** now starts in **Transparent mode**, so you get the bare glowing icons rather
  than a framed strip, matching how the Range Indicator has always started. Untick it on the page if you
  prefer the frame. Note that with no frame there is no close X, so use **Show HUD** to put it away.
- **Loss of Control**'s **Raid** announce toggle now starts **on**, so it matches Party and the two other
  announcers. Worth remembering that both toggles only apply out in the open world: inside an instance
  the announce is said out loud instead, so a raid night never touches raid chat either way.
- The default **banish resisted** line gained its missing exclamation mark.
- **None of those default changes reach an existing setup.** They apply to a new profile only, so if you
  were already running the addon everything stays exactly as you left it, Curse Tracker included. A
  **Hard Reset** or a brand new profile picks up the new defaults. The page merge above is the one thing
  everyone sees, and it carries your current settings across untouched.

### [0.28] - 2026-08-04

#### Added
- The **Soulstone** and **Banish** announcers gained a third announce toggle, **BG/Arena**, next to the
  existing Party and Raid ones, and it is **off by default**. A battleground puts you in a raid of up to
  40 strangers, so until now every soulstone cast anywhere near you went out to the whole battleground
  raid chat, once for each person running the addon. It now stays quiet there unless you ask for it.
- Because it is a toggle rather than a block, a premade or PvP guild that finds the announces useful can
  simply switch them back on.

#### Changed
- **Loss of Control**'s battleground/arena option moved up next to its Party and Raid toggles and now
  reads **BG/Arena**, so all three announce pages carry the same row of controls in the same place. It
  was previously called "Announce in PvP" and sat further down under Behaviour. Only its position and
  name changed: your setting carries over and it does exactly what it did before.
- Inside a battleground or arena the new toggle **replaces** Party and Raid rather than being checked on
  top of them. So you can leave Raid off for raid nights and still have announces in a premade, and the
  two settings can never contradict each other.
- World PvP is deliberately **unaffected**. The toggle keys on being in a battleground or arena, not on
  carrying the PvP flag, so ordinary outdoor group play announces exactly as before, including on a PvP
  realm where you are flagged permanently in contested territory.

### [0.27] - 2026-08-03

#### Added
- **Loss of Control** gained an **Also announce in battlegrounds and arenas** option, **off by default**.
  PvP is constant crowd control, so the announce fires far more often than it is useful there, and
  because a battleground counts as an instance it would be said out loud right next to the enemy who
  cast it. World PvP is unaffected: out in the open it still goes to party or raid chat as before.

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
