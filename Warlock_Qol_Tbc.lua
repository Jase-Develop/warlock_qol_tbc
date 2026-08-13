-- Warlock_Qol_Tbc.lua — Core: events, saved-variables/data, say logic, macros.

-- Shared table; the UI file reads WQ.* from here (avoid raw globals).
Warlock_Qol_Tbc = {}
local WQ = Warlock_Qol_Tbc

-- Pet family -> summon spell ID (IDs are stable across locales; names resolved at runtime).
local SUMMON_SPELL_IDS = {
    Imp        = 688,
    Voidwalker = 697,
    Succubus   = 712,
    Incubus    = 713,
    Felhunter  = 691,
    Felguard   = 30146,
}

-- Ritual of Summoning (summons a player).
local RITUAL_SPELL_ID = 698

-- Default ritual line, seeded on first run / hard reset. {star} = raid marker token.
local DEFAULT_RITUAL_LINE = "Summoning {star} {targetName} {star} to {location}. Click!"

-- Ritual of Souls. Line said in /say, no placeholders.
local RITUAL_OF_SOULS_SPELL_ID = 29893
local DEFAULT_SOULS_LINE = "Healthstones up — grab one! {square}"

-- Banish announcer default lines: landed pool + resisted pool.
local DEFAULT_BANISH_LINE        = "{targetName} has been banished!"
local DEFAULT_BANISH_RESIST_LINE = "{targetName} banish resisted!"

-- Soulstone announce keys off the CAST, matched by name (enUS, rank-agnostic).
local SOULSTONE_SPELL_NAME = "Soulstone Resurrection"
local SOULSTONE_THROTTLE   = 3   -- seconds; block a duplicate announce for the same target
local DEFAULT_SOULSTONE_LINE = "A {circle} soulstone {circle} has been cast on {targetName}"

-- Loss of Control (BETA) announce categories. Data-driven like CURSES / CONSUMABLES / TRACKED_COOLDOWNS:
-- adding one is a data edit. Per entry:
--   label    the word the announce leads with ("Feared!", "Mind controlled!")
--   option   the checkbox label on the config page (the effect, not the state)
--   flag     the per-profile boolean gating it. The fear/charm names PREDATE this table and are kept
--            deliberately, so an existing profile carries its settings across unchanged.
--   default  whether that flag seeds on
-- Messages are deliberately NOT user-editable line pools: they need to be short enough to read at a
-- glance while you are out of action, and are wrapped in plain >> << brackets rather than raid marker
-- tokens so the chat line and the local echo read identically (see ControlMessage).
local CONTROL_TYPES = {
    fear    = { label = "Feared",         option = "Fear",         flag = "controlFear",    default = true  },
    charm   = { label = "Mind controlled",option = "Mind control", flag = "controlCharm",   default = true  },
    incap   = { label = "Incapacitated",  option = "Incapacitate", flag = "controlIncap",   default = true  },
    stun    = { label = "Stunned",        option = "Stun",         flag = "controlStun",    default = true  },
    silence = { label = "Silenced",       option = "Silence",      flag = "controlSilence", default = true  },
    root    = { label = "Rooted",         option = "Root",         flag = "controlRoot",    default = true  },
}
local CONTROL_TYPE_ORDER = { "fear", "charm", "incap", "stun", "silence", "root" }

-- C_LossOfControl locType -> one of the categories above. Several collapse onto one on purpose: HORROR
-- reads as a fear and POSSESS as a charm, because the difference does not change what anyone watching
-- should do about it. An unmapped locType is IGNORED, not guessed at, and recorded for DebugDumpControl
-- so a type this client reports and we do not know about is visible rather than silently dropped.
local CONTROL_LOC_TYPES = {
    FEAR    = "fear",    HORROR  = "fear",
    CHARM   = "charm",   POSSESS = "charm",
    CONFUSE = "incap",   SLEEP   = "incap",   DISORIENT = "incap",
    STUN    = "stun",    STUN_MECHANIC = "stun",
    SILENCE = "silence", PACIFY  = "silence", PACIFYSILENCE = "silence", SCHOOL_INTERRUPT = "silence",
    ROOT    = "root",    SNARE   = "root",
}

local CONTROL_THROTTLE = 3   -- seconds; block a dup announce per category if the latch never clears

-- True if a combat-log unit's affiliation is mine/party/raid (ignore nearby strangers).
local AFFILIATION_GROUP = bit.bor(
    COMBATLOG_OBJECT_AFFILIATION_MINE  or 0x1,
    COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2,
    COMBATLOG_OBJECT_AFFILIATION_RAID  or 0x4)
local function InMyGroup(unitFlags)
    return unitFlags ~= nil and bit.band(unitFlags, AFFILIATION_GROUP) ~= 0
end

-- True if a combat-log unit is the player (banish fires on my own casts only).
local AFFILIATION_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1
local function IsMine(unitFlags)
    return unitFlags ~= nil and bit.band(unitFlags, AFFILIATION_MINE) ~= 0
end

-- Spell info helpers that work on both modern (C_Spell) and older clients.
local function GetSpellNameByID(spellID)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
    return (GetSpellInfo(spellID))
end

local function GetSpellTextureByID(spellID)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spellID) end
    if GetSpellTexture then return GetSpellTexture(spellID) end
    return nil
end

-- Banish spell name (from ID 710, memoised) for rank-agnostic combat-log matching.
local BANISH_THROTTLE   = 3                       -- seconds; block a dup announce per target+kind
local BANISH_RANK_BY_ID = { [710] = 1, [18647] = 2 }  -- Banish Rank 1 / Rank 2 spell IDs

local banishName
local function BanishName()
    if not banishName then banishName = GetSpellNameByID(710) end
    return banishName
end

-- " (Rank N)" suffix for a banish spell ID (map, then GetSpellSubtext fallback; "" if unknown).
local function BanishRankSuffix(spellID)
    local n = BANISH_RANK_BY_ID[spellID]
    if not n and GetSpellSubtext then
        local sub = GetSpellSubtext(spellID)       -- e.g. "Rank 2"
        n = sub and tonumber(sub:match("%d+"))
    end
    if n then return " (Rank " .. n .. ")" end
    return ""
end

-- Ordered family list (UI tab order).
WQ.PET_FAMILIES = { "Imp", "Voidwalker", "Succubus", "Incubus", "Felhunter", "Felguard" }

-- ── Saved Variables / DB ──────────────────────────────────────────────────────
-- Account-wide SavedVariable (declared in the .toc). Layout:
--   profiles[<name>] = shareable config (six line pools, *Enabled/*Seeded flags, tracker/
--                      consumables settings)   -- account-wide so config can be copied between chars
--   chars[<Name-Realm>] = { profile, masterEnabled, setupComplete, classDefaultApplied, petNames, ownCds }  -- per-char
--   ui = window geometry (top-level, global)
-- InitDB creates the skeleton on first install. See CLAUDE.md for the full field list.

-- ── Profile / character resolution ────────────────────────────────────────────
-- Active profile + per-char state are cached locals, resolved on PLAYER_LOGIN (UnitName isn't
-- reliable earlier) and on profile switch. Reads go through ActiveProfile() / CharState().
local activeProfile          -- cached profiles[<bound name>] for this character
local charState              -- cached chars[<Name-Realm>] for this character

-- Forward decls for the mutually-referencing helpers below.
local ActiveProfile, CharState, ResolveActiveBinding, EnsureProfileSeeded

-- Per-character key; nil before PLAYER_LOGIN (callers skip caching then).
local function CharKey()
    local name = UnitName("player")
    if not name or name == "" then return nil end
    return name .. "-" .. (GetRealmName() or "")
end

-- Deep copy (copied profiles share no table refs with the source).
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = DeepCopy(val) end
    return out
end

-- Accent colour (Settings page). Stored per-profile as a 6-hex string; DEFAULT_ACCENT = Warlock purple
-- (the "reset" target). The UI mutates THEME.accent + repaints via WQ.ReapplyAccent.
WQ.DEFAULT_ACCENT = "8788ee"

-- Backdrop opacity. Per-profile whole percent, the shared default + "reset" target for FOUR independent
-- values: the main window (Settings page) and each standalone HUD (its own page). Drives the FILL only
-- (text/icons/borders stay solid) via the UI's WQ.ReapplyOpacity; the percent is literal (100% = solid).
WQ.DEFAULT_OPACITY = 80

-- Ensure a profile has every config field (idempotent; heals old/partial profiles).
local function InitProfile(p)
    p = p or {}
    if not p.lines             then p.lines             = {} end
    if not p.ritualLines       then p.ritualLines       = {} end
    if not p.soulsLines        then p.soulsLines        = {} end
    if not p.soulstoneLines    then p.soulstoneLines    = {} end
    if not p.banishLines       then p.banishLines       = {} end
    if not p.banishResistLines then p.banishResistLines = {} end
    -- Feature flags default ON, only when absent so a saved choice sticks.
    if p.petEnabled       == nil then p.petEnabled       = true end
    if p.ritualEnabled    == nil then p.ritualEnabled    = true end
    if p.soulsEnabled     == nil then p.soulsEnabled     = true end
    if p.soulstoneEnabled == nil then p.soulstoneEnabled = true end
    if p.banishEnabled    == nil then p.banishEnabled    = true end
    -- Per-feature party/raid announce toggles (both default on). The main *Enabled flag still
    -- overrides both; these only decide which group context (party vs raid) actually announces.
    if p.soulstonePartyEnabled == nil then p.soulstonePartyEnabled = true end
    if p.soulstoneRaidEnabled  == nil then p.soulstoneRaidEnabled  = true end
    if p.banishPartyEnabled    == nil then p.banishPartyEnabled    = true end
    if p.banishRaidEnabled     == nil then p.banishRaidEnabled     = true end
    -- Battleground/arena announce toggles, default OFF (the other way to the pair above): a BG groups
    -- you with up to 39 strangers, so this stays silent until deliberately switched on. Opt-in rather
    -- than a hard block so a premade group can still use it.
    if p.soulstonePvpEnabled   == nil then p.soulstonePvpEnabled   = false end
    if p.banishPvpEnabled      == nil then p.banishPvpEnabled      = false end
    if p.trackerEnabled   == nil then p.trackerEnabled   = true end
    -- trackerShowRaid/Party = auto-show HUD on entering a raid / party dungeon (raid on, party OFF by
    -- default). trackedCds[key]=false disables a cooldown (absent = tracked).
    if p.trackerShowRaid  == nil then p.trackerShowRaid  = true  end
    if p.trackerShowParty == nil then p.trackerShowParty = false end
    -- soulstoneActiveEnabled = show the "Soulstones Out" section (who currently HAS a soulstone buff).
    if p.soulstoneActiveEnabled == nil then p.soulstoneActiveEnabled = true end
    if not p.trackedCds   then p.trackedCds = {} end
    -- Missing Consumables: consumeShowRaid/Party = auto-show on entering a raid / party dungeon (raid on,
    -- party OFF by default); consumeThreshold = expiry warning window (secs, default 120);
    -- trackedConsumes[key]=false disables one (absent = tracked).
    if p.consumablesEnabled == nil then p.consumablesEnabled = true end
    if p.consumeShowRaid    == nil then p.consumeShowRaid    = true end
    if p.consumeShowParty   == nil then p.consumeShowParty   = false end
    if p.consumeGlow        == nil then p.consumeGlow        = true end   -- glow the missing icons
    -- consumeTransparent defaults ON since 0.29 (user call), matching rangeTransparent: bare icons read
    -- better than a framed strip, and the frame stays mouse-enabled so it is still draggable. Caveat
    -- carried over from the Range HUD: with no header there is no X, so closing it means the page's
    -- Show HUD.
    if p.consumeTransparent == nil then p.consumeTransparent = true  end  -- hide HUD frame/header, icons only
    if p.consumeThreshold   == nil then p.consumeThreshold   = 120  end
    if not p.trackedConsumes then p.trackedConsumes = {} end
    -- Range Indicator: manual on/off tool (default enabled here, but its HUD.open defaults OFF so
    -- nothing shows until the user ticks Show HUD). rangeTransparent (text-only, no frame/header)
    -- defaults ON for the clean WeakAura-style look. rangeFontSize = name/value text size (points).
    if p.rangeEnabled      == nil then p.rangeEnabled      = true  end
    if p.rangeTransparent  == nil then p.rangeTransparent  = true  end
    if p.rangeHideNoTarget == nil then p.rangeHideNoTarget = false end  -- on = hide HUD when untargeted
    if p.rangeFontSize     == nil then p.rangeFontSize     = 16    end
    -- Curse Tracker: out of beta as of 0.29, so it now seeds like its Cooldowns/Consumables peers:
    -- feature on, auto-show in a raid instance on, party (a 5-man) off. The four curses default ON
    -- (trackedCurses[key]=false disables one, absent = tracked). curseHideInactive defaults OFF, unlike
    -- the pre-0.29 beta seeding: a HUD that auto-appears in a raid showing its placeholder is how the
    -- user discovers it and drags it somewhere, where one that hides itself until a curse lands is not.
    -- curseHUD.open stays off (it is top-level, not seeded here), so the auto-show drives first display.
    -- GOTCHA: none of this reaches an existing profile. Those already store an explicit false from the
    -- beta build, and InitProfile only ever seeds a nil, so a current user keeps the feature switched off.
    if p.cursesEnabled     == nil then p.cursesEnabled     = true  end
    if p.curseShowRaid     == nil then p.curseShowRaid     = true  end
    if p.curseShowParty    == nil then p.curseShowParty    = false end
    if p.curseHideInactive == nil then p.curseHideInactive = false end
    if not p.trackedCurses then p.trackedCurses = {} end
    -- Loss of Control (BETA): same rule, the feature itself defaults OFF. Inside it both effect kinds
    -- default on and controlCombatOnly filters out taxi flights and other harmless control loss.
    -- controlEcho prints the line to your own chat frame, so enabling the feature always does something
    -- visible even with no announce channel live.
    -- controlRaidEnabled defaults **ON** as of 0.29 (user call), so party and raid now match the
    -- soulstone/banish pair. It shipped OFF in 0.26 on the reasoning that a mass-fear mechanic makes
    -- every addon user announce at once, which is still true and still the argument for the aggregated
    -- version. What changed is the weighting: the feature itself is off until switched on, so anyone
    -- turning it on is opting into the whole thing, and these two toggles only bite OUT IN THE WORLD
    -- anyway (inside an instance ControlChannel returns SAY), so a raid night never touches raid chat.
    if p.controlEnabled      == nil then p.controlEnabled      = false end
    -- Per-category announce flags, seeded from the table so adding a category needs no change here.
    -- ALL SIX default ON (user call 2026-08-03): the feature itself is off until switched on, so anyone
    -- who turns it on is opting into the whole thing, and a category they do not want is one click away.
    -- This reverses the original stun/silence/root default of OFF, which was reasoned from "nobody can
    -- help with those and they fire constantly": still true, so watch the announce volume in a raid.
    for _, ckey in ipairs(CONTROL_TYPE_ORDER) do
        local cspec = CONTROL_TYPES[ckey]
        if p[cspec.flag] == nil then p[cspec.flag] = cspec.default end
    end
    if p.controlPartyEnabled == nil then p.controlPartyEnabled = true  end
    if p.controlRaidEnabled  == nil then p.controlRaidEnabled  = true  end
    if p.controlCombatOnly   == nil then p.controlCombatOnly   = true  end
    if p.controlEcho         == nil then p.controlEcho         = true  end
    -- Battlegrounds and arenas are silent unless asked for (default OFF): PvP is wall-to-wall crowd
    -- control, so the announce fires constantly and says nothing anyone can act on. Worse, a BG/arena
    -- IS an instance, so the announce takes the /say path there and broadcasts your CC state to any
    -- enemy standing next to you. Most people will never want this on.
    if p.controlPvpEnabled   == nil then p.controlPvpEnabled   = false end
    -- Settings: accent colour (6-hex; default = Warlock purple).
    if p.accent == nil then p.accent = WQ.DEFAULT_ACCENT end
    -- Backdrop opacity (whole percent, default 80): one for the main window (Settings page) plus one
    -- per standalone HUD (each on that HUD's own page), all five independent.
    if p.opacity        == nil then p.opacity        = WQ.DEFAULT_OPACITY end
    if p.trackerOpacity == nil then p.trackerOpacity = WQ.DEFAULT_OPACITY end
    if p.consumeOpacity == nil then p.consumeOpacity = WQ.DEFAULT_OPACITY end
    if p.rangeOpacity   == nil then p.rangeOpacity   = WQ.DEFAULT_OPACITY end
    if p.curseOpacity   == nil then p.curseOpacity   = WQ.DEFAULT_OPACITY end
    -- Ensure every pet family has a lines table, even if empty.
    for _, family in ipairs(WQ.PET_FAMILIES) do
        if not p.lines[family] then p.lines[family] = {} end
    end
    return p
end

-- Add the default ritual line if absent (dedup-safe). Returns true if added.
local function SeedRitualDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.ritualLines) do
        if line == DEFAULT_RITUAL_LINE then return false end
    end
    table.insert(p.ritualLines, DEFAULT_RITUAL_LINE)
    return true
end

-- Same for the Ritual of Souls default line.
local function SeedSoulsDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.soulsLines) do
        if line == DEFAULT_SOULS_LINE then return false end
    end
    table.insert(p.soulsLines, DEFAULT_SOULS_LINE)
    return true
end

-- Same for the Soulstone default line (seed-once, dedup-safe).
local function SeedSoulstoneDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.soulstoneLines) do
        if line == DEFAULT_SOULSTONE_LINE then return false end
    end
    table.insert(p.soulstoneLines, DEFAULT_SOULSTONE_LINE)
    return true
end

-- Seed the Banish default lines (landed + resisted), dedup-safe per pool.
local function SeedBanishDefaultLines()
    local p = ActiveProfile()
    if not p then return end
    local function seedOne(list, default)
        for _, line in ipairs(list) do
            if line == default then return end
        end
        table.insert(list, default)
    end
    seedOne(p.banishLines,       DEFAULT_BANISH_LINE)
    seedOne(p.banishResistLines, DEFAULT_BANISH_RESIST_LINE)
end

-- Seed each pool's default line once per profile, gated on the *Seeded flags.
EnsureProfileSeeded = function()
    local p = ActiveProfile()
    if not p then return end
    if not p.ritualSeeded then SeedRitualDefaultLine();  p.ritualSeeded = true end
    if not p.soulsSeeded  then SeedSoulsDefaultLine();   p.soulsSeeded  = true end
    if not p.soulstoneSeeded then SeedSoulstoneDefaultLine(); p.soulstoneSeeded = true end
    if not p.banishSeeded then SeedBanishDefaultLines(); p.banishSeeded = true end
end

-- True if the player is a Warlock (class token is locale-independent). Reliable at PLAYER_LOGIN.
local function IsWarlock()
    local _, class = UnitClass("player")
    return class == "WARLOCK"
end

-- Resolve + cache this character's binding (activeProfile + charState). No-op pre-PLAYER_LOGIN.
ResolveActiveBinding = function()
    if not Warlock_Qol_Tbc_DB then return end
    local key = CharKey()
    if not key then return end                        -- too early; leave caches nil
    Warlock_Qol_Tbc_DB.profiles = Warlock_Qol_Tbc_DB.profiles or {}
    Warlock_Qol_Tbc_DB.chars    = Warlock_Qol_Tbc_DB.chars or {}

    local cs = Warlock_Qol_Tbc_DB.chars[key]
    if not cs then
        -- First time we've seen this character: create a profile named after it and bind to it.
        cs = { masterEnabled = true, setupComplete = false, petNames = {} }
        cs.profile = key
        Warlock_Qol_Tbc_DB.profiles[key] = InitProfile(Warlock_Qol_Tbc_DB.profiles[key])
        Warlock_Qol_Tbc_DB.chars[key] = cs
    end

    -- Heal any missing per-character fields (robustness against partial saves).
    if cs.masterEnabled == nil then cs.masterEnabled = true end
    if cs.setupComplete == nil then cs.setupComplete = false end
    if not cs.petNames  then cs.petNames = {} end
    if not cs.ownCds    then cs.ownCds   = {} end

    -- If the bound profile was deleted, fall back to any existing profile (or a fresh one).
    if not Warlock_Qol_Tbc_DB.profiles[cs.profile] then
        local fallback
        for pname in pairs(Warlock_Qol_Tbc_DB.profiles) do fallback = pname; break end
        if not fallback then
            fallback = "Default"
            Warlock_Qol_Tbc_DB.profiles[fallback] = InitProfile({})
        end
        cs.profile = fallback
    end

    charState     = cs
    activeProfile = InitProfile(Warlock_Qol_Tbc_DB.profiles[cs.profile])
    EnsureProfileSeeded()   -- seed this profile's defaults on first bind
end

-- Accessors: lazily resolve the binding; return nil pre-PLAYER_LOGIN (callers nil-guard).
ActiveProfile = function()
    if activeProfile then return activeProfile end
    ResolveActiveBinding()
    return activeProfile
end

CharState = function()
    if charState then return charState end
    ResolveActiveBinding()
    return charState
end

-- Public accessors for the UI (nil-safe pre-login).
WQ.ActiveProfile = ActiveProfile
WQ.CharState     = CharState

-- ADDON_LOADED: ensure the DB skeleton exists (the binding is resolved later, at PLAYER_LOGIN).
local function InitDB()
    if not Warlock_Qol_Tbc_DB then Warlock_Qol_Tbc_DB = {} end
    Warlock_Qol_Tbc_DB.profiles = Warlock_Qol_Tbc_DB.profiles or {}
    Warlock_Qol_Tbc_DB.chars    = Warlock_Qol_Tbc_DB.chars or {}
    -- Warlock_Qol_Tbc_DB.ui is created/managed by the UI layer; left as-is here.
end

-- ── Public data helpers ───────────────────────────────────────────────────────
-- These are called by the UI file to modify saved data.

function WQ.AddLine(family, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().lines[family], text)
    return true
end

function WQ.DeleteLine(family, index)
    table.remove(ActiveProfile().lines[family], index)
end

-- Edit-in-place; returns false (line untouched) on empty text or bad index.
function WQ.UpdateLine(family, index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().lines[family]
    if not lines or not lines[index] then return false end
    lines[index] = text
    return true
end

-- Ritual lines: a single flat list.
function WQ.AddRitualLine(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().ritualLines, text)
    return true
end

function WQ.DeleteRitualLine(index)
    table.remove(ActiveProfile().ritualLines, index)
end

function WQ.UpdateRitualLine(index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().ritualLines
    if not lines[index] then return false end
    lines[index] = text
    return true
end

-- Ritual of Souls lines: another flat list, mirroring the ritual helpers.
function WQ.AddSoulsLine(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().soulsLines, text)
    return true
end

function WQ.DeleteSoulsLine(index)
    table.remove(ActiveProfile().soulsLines, index)
end

function WQ.UpdateSoulsLine(index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().soulsLines
    if not lines[index] then return false end
    lines[index] = text
    return true
end

-- Soulstone lines: another flat list, mirroring the ritual helpers.
function WQ.AddSoulstoneLine(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().soulstoneLines, text)
    return true
end

function WQ.DeleteSoulstoneLine(index)
    table.remove(ActiveProfile().soulstoneLines, index)
end

function WQ.UpdateSoulstoneLine(index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().soulstoneLines
    if not lines[index] then return false end
    lines[index] = text
    return true
end

-- Banish lines: two flat lists (success + resist), same shape as the soulstone helpers.
function WQ.AddBanishLine(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().banishLines, text)
    return true
end

function WQ.DeleteBanishLine(index)
    table.remove(ActiveProfile().banishLines, index)
end

function WQ.UpdateBanishLine(index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().banishLines
    if not lines[index] then return false end
    lines[index] = text
    return true
end

function WQ.AddBanishResistLine(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().banishResistLines, text)
    return true
end

function WQ.DeleteBanishResistLine(index)
    table.remove(ActiveProfile().banishResistLines, index)
end

function WQ.UpdateBanishResistLine(index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().banishResistLines
    if not lines[index] then return false end
    lines[index] = text
    return true
end

-- ── Say logic ────────────────────────────────────────────────────────────────

-- A feature fires only when the per-char master switch AND its own flag are on.
local function FeatureOn(flagKey)
    local cs = CharState()
    local p  = ActiveProfile()
    return cs and cs.masterEnabled and p and p[flagKey] and true or false
end

local function SayLine(family)
    local p = ActiveProfile()
    if not p then return end
    local lines = p.lines[family]
    if not lines or #lines == 0 then return end  -- nothing configured, stay silent

    local line = lines[math.random(#lines)]

    -- {demonName}/{petName} (alias) -> the pet's name from the per-char cache, or the family
    -- name (e.g. "Succubus") until it's been summoned once this session.
    local demonName = (CharState() and CharState().petNames[family]) or family
    line = line:gsub("{demonName}", demonName)
    line = line:gsub("{petName}", demonName)

    if line ~= "" then
        SendChatMessage(line, "SAY")
    end
end

-- A battleground or arena, matching the instance-type style the HUD auto-shows use (UI-side
-- InRaidInstance / InPartyInstance). Read by GroupAnnounceChannel below and by the Loss of Control
-- announcer further down, which both count a BG as an instance and would otherwise blast it.
-- Deliberately the INSTANCE TYPE and not UnitIsPVP: a place you are in rather than a state you are in,
-- so nothing flaps as the PvP flag ticks on and off, and a PvP realm (permanently flagged out in
-- contested territory) still announces normally for ordinary outdoor group play.
local function InPvpInstance()
    local t = select(2, IsInInstance())
    return t == "pvp" or t == "arena"
end

-- Group chat channel: RAID in a raid, PARTY in a party, else SAY.
local function GroupChatChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return "SAY"
end

-- Announce channel for a group-only feature (soulstone/banish) that carries independent per-context
-- toggles. Returns "RAID"/"PARTY" when the current group context is enabled, or nil to suppress
-- (solo, or that context's toggle is off). `feature` is "soulstone" or "banish"; it reads
-- <feature>PartyEnabled / <feature>RaidEnabled from the active profile (both default on: only an
-- explicit false suppresses, so an unhealed old profile still announces).
--
-- A battleground or arena is decided by a THIRD toggle, <feature>PvpEnabled, and that one REPLACES the
-- party/raid pair for the duration rather than stacking with it: a player who keeps Raid off for raid
-- nights can still opt into premade announces without the two settings contradicting each other. It
-- also defaults the other way, OFF, so absent suppresses: a BG puts you in a raid of up to 40, so
-- without this every allied warlock's soulstone would blast the whole BG raid chat, once per addon
-- user. The channel itself still follows the group shape (RAID in a BG, PARTY in an arena).
--
-- Loss of Control also calls this with "control", but only ever from OUTSIDE an instance (ControlChannel
-- returns SAY first), so the PvP branch is unreachable for it and its own controlPvpEnabled opt-in stays
-- the single gate there. The flag name happens to line up and carries the same opt-in meaning, so the two
-- would agree even if that short-circuit were ever removed.
local function GroupAnnounceChannel(feature)
    local p = ActiveProfile()
    if not p then return nil end
    if InPvpInstance() then
        if not p[feature .. "PvpEnabled"] then return nil end
        if IsInRaid()  then return "RAID"  end
        if IsInGroup() then return "PARTY" end
        return nil
    end
    if IsInRaid() then
        if p[feature .. "RaidEnabled"] == false then return nil end
        return "RAID"
    elseif IsInGroup() then
        if p[feature .. "PartyEnabled"] == false then return nil end
        return "PARTY"
    end
    return nil   -- solo: these features are group-only
end

-- {location} text: subzone if available, else zone.
local function GetLocationText()
    local sub = GetSubZoneText()
    if sub and sub ~= "" then return sub end
    return GetZoneText() or ""
end

-- Random ritual line with {targetName}/{location} filled in (or stripped if unavailable).
local function SayRitual()
    local p = ActiveProfile()
    if not p then return end
    local lines = p.ritualLines
    if not lines or #lines == 0 then return end

    local line = lines[math.random(#lines)]

    local target = UnitName("target")
    if target then
        line = line:gsub("{targetName}", target)
    else
        line = line:gsub("{targetName}%s*,?%s*", "")
    end

    local location = GetLocationText()
    if location ~= "" then
        line = line:gsub("{location}", location)
    else
        line = line:gsub("{location}%s*,?%s*", "")
    end

    line = line:match("^%s*(.-)%s*$")  -- trim once after any placeholder removal

    if line ~= "" then
        SendChatMessage(line, GroupChatChannel())
    end
end

-- Soulstone announce (fired from the combat log). Group-only, throttled per target.
local soulstoneRecent = {}   -- targetName -> GetTime() of the last announce
local function SaySoulstone(targetName)
    if not FeatureOn("soulstoneEnabled") then return end
    local channel = GroupAnnounceChannel("soulstone")   -- nil = solo, or party/raid toggle off
    if not channel then return end
    local p = ActiveProfile()
    if not p then return end
    local lines = p.soulstoneLines
    if not lines or #lines == 0 then return end

    -- Strip any "-Realm" suffix.
    targetName = targetName and targetName:gsub("%-.*", "")
    if not targetName or targetName == "" then return end

    local now = GetTime()
    local last = soulstoneRecent[targetName]
    if last and (now - last) < SOULSTONE_THROTTLE then return end
    soulstoneRecent[targetName] = now

    local line = lines[math.random(#lines)]
    line = line:gsub("{targetName}", targetName)
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
        SendChatMessage(line, channel)
    end
end

-- Banish announce (from the combat log, my own banishes). `resisted` picks the pool;
-- `rankSuffix` is appended. Group-only, throttled per target+kind.
local banishRecent = {}   -- "<kind>:<targetName>" -> GetTime() of the last announce
local function SayBanish(targetName, rankSuffix, resisted)
    if not FeatureOn("banishEnabled") then return end
    local channel = GroupAnnounceChannel("banish")   -- nil = solo, or party/raid toggle off
    if not channel then return end
    local p = ActiveProfile()
    if not p then return end
    local lines = resisted and p.banishResistLines or p.banishLines
    if not lines or #lines == 0 then return end

    -- Strip any "-Realm" suffix.
    targetName = targetName and targetName:gsub("%-.*", "")
    if not targetName or targetName == "" then return end

    -- Throttle per target+kind (avoids double-announce on re-banish / aura re-fire).
    local now = GetTime()
    local key = (resisted and "r:" or "b:") .. targetName
    local last = banishRecent[key]
    if last and (now - last) < BANISH_THROTTLE then return end
    banishRecent[key] = now

    local line = lines[math.random(#lines)]
    line = line:gsub("{targetName}", targetName)
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
        SendChatMessage(line .. (rankSuffix or ""), channel)
    end
end

-- Ritual of Souls just says a flavour line in /say when cast — no placeholders, no
-- group requirement (mirrors the pet-summon /say behaviour).
local function SaySouls()
    local p = ActiveProfile()
    if not p then return end
    local lines = p.soulsLines
    if not lines or #lines == 0 then return end

    local line = lines[math.random(#lines)]
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
        SendChatMessage(line, "SAY")
    end
end

-- ── Loss of Control announcer (BETA) ─────────────────────────────────────────
-- TWO detection paths, deliberately, because only one of them is confirmed to work on 2.5.6:
--
-- PRIMARY: LOSS_OF_CONTROL_ADDED via C_LossOfControl. The namespace is confirmed PRESENT on this client
-- (probed in-game 2026-07-30) and each entry carries locType / displayText / duration, so the announce
-- can NAME the effect and say how long it lasts instead of guessing between two fixed strings. It also
-- reaches stuns, silences and roots, which the fallback below is structurally blind to, and it needs no
-- taxi filter (a flight path is not a loss-of-control event).
--
-- FALLBACK: PLAYER_CONTROL_LOST, a vanilla-era event that fires whenever the player cannot drive their
-- own character (fear, charm, mind control, taxi). It carries NO payload, so it can only report that
-- SOMETHING took the wheel: the category is guessed from UnitIsCharmed, and anything that is neither a
-- charm nor a fear is mislabelled "Feared!". It is kept ONLY because C_LossOfControl EXISTING on 2.5.6
-- does not prove LOSS_OF_CONTROL_ADDED FIRES there, and a silently dead announcer would be worse than a
-- roughly-labelled one.
--
-- The two are coordinated so they can never both announce: the primary fires immediately and stamps
-- controlLocAt, the fallback waits CONTROL_BACKSTOP_DELAY and stands down if that stamp is fresh.
-- ONCE THE IN-GAME TEST SETTLES WHETHER THE EVENT FIRES, DELETE THE PATH THAT LOST.

-- Accessor shim for C_LossOfControl. The namespace is present but WHICH accessor it carries is not
-- known: retail 9.0+ exposes GetActiveLossOfControlData(i) returning a table, older builds exposed
-- GetEventInfo(i) returning a flat tuple. Same shape as the GetSpellNameByID / ItemInRange shims:
-- prefer the modern name, fall back to the old one, and hand back one normalised table so no caller
-- has to care which client it is on.
local function LossOfControlData(index)
    local C = C_LossOfControl
    -- Type-checked, not just nil-checked: the event's payload shape is unverified on 2.5.6, so a
    -- non-numeric arg must fall through to the scan rather than be handed to the accessor.
    if not (C and type(index) == "number") then return nil end
    if C.GetActiveLossOfControlData then
        local d = C.GetActiveLossOfControlData(index)
        return (type(d) == "table" and d.locType) and d or nil
    end
    if C.GetEventInfo then
        local locType, spellID, displayText, _, startTime, timeRemaining, duration = C.GetEventInfo(index)
        if not locType then return nil end
        return { locType = locType, spellID = spellID, displayText = displayText,
                 startTime = startTime, timeRemaining = timeRemaining, duration = duration }
    end
    return nil
end

local function LossOfControlCount()
    local C = C_LossOfControl
    if not C then return 0 end
    if C.GetActiveLossOfControlDataCount then return C.GetActiveLossOfControlDataCount() or 0 end
    if C.GetNumEvents then return C.GetNumEvents() or 0 end
    return 0
end

-- Build the announce text: ">> Stunned! (4s) <<". The label names WHAT HAPPENED (from the event's
-- locType, not a guess), and the duration tells the group whether it is worth reacting to. Kept SHORT
-- deliberately (user call 2026-08-01): this is read at a glance by someone mid-fight, so the effect's
-- own name (C_LossOfControl's displayText, e.g. "War Stomp") is NOT included even though we have it.
-- The duration is optional and the format degrades to just ">> Stunned! <<" without it, which is what
-- the payload-free fallback path always produces.
--
-- The >> << brackets replaced {skull} raid marker tokens, which rendered as an icon in chat but showed
-- as raw "{skull}" text in the local echo. Plain characters read identically in both.
local function ControlMessage(cat, duration)
    local spec  = CONTROL_TYPES[cat]
    local label = (spec and spec.label) or "Out of control"
    local secs  = (type(duration) == "number" and duration > 0) and math.floor(duration + 0.5) or nil

    if secs then return (">> %s! (%ds) <<"):format(label, secs) end
    return (">> %s! <<"):format(label)
end

-- Channel for the announce. "SAY" is what the feature was asked for, and it IS available here, but only
-- inside an instance: automated SAY/YELL is blocked OUT IN THE WORLD, which is a different rule from the
-- one v0.26 inferred. The v0.26 test (2026-07-30) sent from a /run and from a C_Timer callback while
-- standing in the world, saw the timer send silently dropped, and concluded that the hardware-event
-- restriction was what blocked it. That reading was too broad: permission is granted by EITHER a
-- hardware event OR being in an instance, and the test only ever varied the first. Confirmed 2026-08-01
-- against WeakAuras, which guards its own say action with exactly this test and documents it in its
-- options UI ("Automated Messages to SAY and YELL are blocked outside of Instances"), and against a
-- combat-log-triggered TBC Anniversary WeakAura observed announcing in /say in-game.
--
-- So: a bubble over your head inside a dungeon or raid, which is where being feared or MC'd matters and
-- where the people who can help are already looking. Out in the world (world PvP) it falls back to the
-- party/raid toggles, and is nil when solo.
local function ControlChannel()
    if IsInInstance() then return "SAY" end
    return GroupAnnounceChannel("control")
end

-- (InPvpInstance is defined up with the announce-channel helpers: the soulstone and banish announcers
-- gate on it too. Both count as an instance to ControlChannel above, so without the opt-out this
-- would /say through a whole BG.)

-- FALLBACK-PATH ONLY category guess: "charm" when something else is driving (charm / mind control /
-- possession), else "fear". Existence-guarded like the other version shims. This is the guess the
-- primary path exists to replace: with no payload to read, anything that is neither a charm nor a fear
-- comes out as "Feared!". Never call it from the C_LossOfControl path, which knows the real answer.
local function ControlKindGuess()
    if UnitIsCharmed and UnitIsCharmed("player") then return "charm" end
    return "fear"
end

-- Announce one loss of control. `cat` is a CONTROL_TYPES key; duration comes from C_LossOfControl on
-- the primary path and is nil on the fallback (see ControlMessage, which degrades to a bare label).
local controlRecent = {}   -- category -> GetTime() of the last announce
local function SayControl(cat, duration)
    if not FeatureOn("controlEnabled") then return end
    local p    = ActiveProfile()
    local spec = CONTROL_TYPES[cat]
    if not (p and spec) then return end

    -- Per-category opt-out. Absent reads as the category's own default, so a profile written before
    -- this category existed behaves as if it had been seeded.
    local on = p[spec.flag]
    if on == nil then on = spec.default end
    if not on then return end

    -- PvP opt-in (default off). Silences the WHOLE announce in a battleground or arena, echo included:
    -- there is no point printing to your own chat frame what you can already see happening to you, and
    -- a BG is where this fires most. Deliberately keyed on the INSTANCE TYPE rather than your PvP flag,
    -- so it is a place you are in rather than a state you are in: world PvP is left announcing, where
    -- it goes to party/raid (already gated by those toggles) instead of over an enemy's head.
    if InPvpInstance() and not p.controlPvpEnabled then return end

    -- nil = solo, or that context's toggle is off. Not a bail on its own: the local echo is still
    -- worth printing when there is nobody to announce to.
    local channel = ControlChannel()
    if not channel and not p.controlEcho then return end

    -- Secondary safety only: the caller's transition latch is what normally stops a repeat.
    local now  = GetTime()
    local last = controlRecent[cat]
    if last and (now - last) < CONTROL_THROTTLE then return end
    controlRecent[cat] = now

    local msg = ControlMessage(cat, duration)
    if channel then SendChatMessage(msg, channel) end

    -- Local echo of exactly what was sent (or would have been, when solo). Now literally identical to
    -- the chat line: the >> << brackets are plain characters, unlike the {skull} token they replaced,
    -- which rendered as an icon in chat but printed as raw "{skull}" text here.
    if p.controlEcho then
        print(("|cff9900ffWarlockQol|r %s"):format(msg))
    end
end

-- PRIMARY detection. The event's payload differs across builds (some pass the index of the new entry,
-- some pass nothing), so the index is used when supplied and the active list is scanned for the newest
-- entry otherwise: either way this ends up with one normalised entry.
local controlLocAt   = 0    -- GetTime() when this path last announced; tells the fallback to stand down
local controlLocSeen = {}   -- locType strings this client reported that CONTROL_LOC_TYPES lacks
local controlLocFired = false   -- has the event EVER fired here? The one thing the in-game test settles

local function OnLossOfControlAdded(index)
    if not FeatureOn("controlEnabled") then return end
    controlLocFired = true

    local d = LossOfControlData(index)
    if not d then
        local best
        for i = 1, LossOfControlCount() do
            local e = LossOfControlData(i)
            if e and (not best or (e.startTime or 0) >= (best.startTime or 0)) then best = e end
        end
        d = best
    end
    if not d then return end

    local cat = CONTROL_LOC_TYPES[d.locType]
    if not cat then
        controlLocSeen[d.locType] = true   -- surfaced by DebugDumpControl rather than guessed at
        return
    end

    -- No taxi filter here: a flight path is not a loss-of-control event, which is one of the reasons
    -- this path is preferred. The combat filter still applies, since it is a noise preference.
    local p = ActiveProfile()
    if p and p.controlCombatOnly and not UnitAffectingCombat("player") then return end

    controlLocAt = GetTime()
    -- displayText is deliberately NOT passed on: the message is kept short (see ControlMessage).
    SayControl(cat, d.duration or d.timeRemaining)
end

-- Transition latch. PLAYER_CONTROL_LOST can fire several times for one effect (chain fears; a
-- druid's form changes fire it repeatedly), so only the EDGE into loss-of-control announces.
-- Clearing this is the only reason PLAYER_CONTROL_GAINED is handled: it is never announced.
local controlLost = false

-- How long the fallback waits before announcing. Two jobs: it gives LOSS_OF_CONTROL_ADDED first refusal
-- (both events fire for the same effect and their order is not guaranteed, so a plain "has the primary
-- run yet" check would lose the race), and it lets the unit flags the filters read settle. Imperceptible
-- in play, so prefer raising it over shaving it.
local CONTROL_BACKSTOP_DELAY = 0.5

local function OnControlLost()
    if controlLost then return end
    controlLost = true
    if not FeatureOn("controlEnabled") then return end

    -- GOTCHA: EVERY filter is evaluated LATE, inside the delayed callback, never here. The unit flags
    -- they read are not settled at the instant PLAYER_CONTROL_LOST fires: checking UnitOnTaxi at this
    -- point read FALSE while boarding a flight, so a taxi ride announced "Feared!" (reported in-game
    -- 2026-08-01, with controlCombatOnly off so the combat filter was not covering for it). Combat is
    -- the same shape in reverse: a fear that starts the fight may not have flagged you in combat yet.
    -- If a taxi ever leaks through again, raise CONTROL_BACKSTOP_DELAY rather than adding a filter.
    local function fire()
        -- Stand down if C_LossOfControl already announced this effect: it NAMED it, we would only
        -- repeat it worse. Everything this path can say is a guess (see ControlKindGuess).
        if (GetTime() - controlLocAt) < 1 then return end
        -- Taxi flights fire this event too and are never worth saying out loud. The primary path needs
        -- no equivalent: a taxi is not a loss-of-control event there, which is why it stayed silent.
        if UnitOnTaxi and UnitOnTaxi("player") then return end
        -- Anything that fears or charms you has already put you in combat, so this filter costs no real
        -- detections while removing the remaining harmless cases (a flight path, a shapeshift).
        local p = ActiveProfile()
        if p and p.controlCombatOnly and not UnitAffectingCombat("player") then return end
        SayControl(ControlKindGuess())
    end
    if C_Timer and C_Timer.After then C_Timer.After(CONTROL_BACKSTOP_DELAY, fire) else fire() end
end

local function OnControlGained()
    controlLost = false
end

-- ── Public say + macro helpers ──────────────────────────────────────────────────

-- Our macros are tagged two ways (name prefix + body signature); we only edit/delete a
-- macro matching the signature, so a user's own same-named macro is never touched.
local MACRO_PREFIX    = "WQoL "                  -- name prefix (fits the 16-char limit)
local MACRO_SIGNATURE = "Warlock_Qol_Tbc.Say"   -- present in every generated body

-- Summon-macro entry point (must run from the clicked macro — /say needs a hardware event).
-- `family` defaults to the active pet's family.
function WQ.SaySummonLine(family)
    if not FeatureOn("petEnabled") then return end   -- feature (or master) off; macro still cast the pet
    family = family or (UnitExists("pet") and UnitCreatureFamily("pet")) or nil
    if not family then return end
    SayLine(family)
end

-- Ritual-macro entry point. No cast guard (Ritual of Summoning is channelled; its state
-- isn't readable in the macro's /run) — we guard on having a player target instead.
function WQ.SayRitualLine()
    if not FeatureOn("ritualEnabled") then return end   -- feature (or master) off; macro still cast the ritual
    if not (UnitExists("target") and UnitIsPlayer("target")) then return end
    SayRitual()
end

-- Ritual of Souls macro entry point. No cast guard (channelled; state unreadable in /run) —
-- no target or cooldown, so just say the line.
function WQ.SaySoulsLine()
    if not FeatureOn("soulsEnabled") then return end   -- feature (or master) off; macro still cast the ritual
    SaySouls()
end

-- True only if the macro at this index is ours (matched by body signature, not name).
local function IsOurMacro(index)
    if not index or index <= 0 then return false end
    local _, _, body = GetMacroInfo(index)
    return body ~= nil and body:find(MACRO_SIGNATURE, 1, true) ~= nil
end

-- Print a standard summary of a create/update run.
function WQ.ReportMacroResult(created, updated, conflicts)
    if created > 0 or updated > 0 then
        print(("|cff9900ffWarlockQol|r: %d macro(s) created, %d updated. Open |cffffd700/macro|r and drag them onto your action bars."):format(created, updated))
    else
        print("|cff9900ffWarlockQol|r: nothing to do — your macros are already up to date.")
    end
    if conflicts and #conflicts > 0 then
        print("|cff9900ffWarlockQol|r: skipped (a macro with this name already exists that we didn't make): " .. table.concat(conflicts, ", "))
    end
end

-- Create/update one of our macros. Returns "created"/"updated"/"conflict"/"nospace".
local function UpsertMacro(macroName, icon, body)
    local index = GetMacroIndexByName(macroName)
    if index and index > 0 then
        if IsOurMacro(index) then
            EditMacro(index, macroName, icon, body)
            return "updated"
        end
        return "conflict"
    end
    local _, charCount = GetNumMacros()
    local maxChar = MAX_CHARACTER_MACROS or 18
    if (charCount or 0) >= maxChar then return "nospace" end
    CreateMacro(macroName, icon, body, true)  -- true = per-character macro
    return "created"
end

-- Delete a macro only if it's ours (by signature). Returns true if removed.
local function RemoveSignedMacro(macroName)
    local index = GetMacroIndexByName(macroName)
    if index and index > 0 and IsOurMacro(index) then
        DeleteMacro(index)
        return true
    end
    return false
end

-- Fold a single UpsertMacro result into the running counters.
local function Tally(result, macroName, counts)
    if result == "created" then
        counts.created = counts.created + 1
    elseif result == "updated" then
        counts.updated = counts.updated + 1
    elseif result == "conflict" then
        table.insert(counts.conflicts, macroName)
    elseif result == "nospace" then
        table.insert(counts.conflicts, macroName .. " (no free character macro slots)")
    end
end

-- Create/refresh a summon macro for every pet family. Returns created, updated, conflicts.
function WQ.CreateSummonMacros()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0, 0, {}
    end

    local counts = { created = 0, updated = 0, conflicts = {} }
    for _, family in ipairs(WQ.PET_FAMILIES) do
        local spellID   = SUMMON_SPELL_IDS[family]
        local spellName = spellID and GetSpellNameByID(spellID)

        -- Built for every family even if unlearned (name resolves from the spell DB;
        -- the /cast just no-ops until learned).
        if spellName and spellID then
            local macroName = MACRO_PREFIX .. family
            local body = ("#showtooltip %s\n/cast %s\n/run Warlock_Qol_Tbc.SaySummonLine(\"%s\")")
                :format(spellName, spellName, family)
            local icon = GetSpellTextureByID(spellID) or 134400  -- 134400 = "?" icon
            Tally(UpsertMacro(macroName, icon, body), macroName, counts)
        end
    end
    return counts.created, counts.updated, counts.conflicts
end

-- Create/refresh the Ritual of Summoning macro (built even if unlearned). Returns
-- created, updated, conflicts.
function WQ.CreateRitualMacro()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0, 0, {}
    end

    local counts = { created = 0, updated = 0, conflicts = {} }
    local spellName = GetSpellNameByID(RITUAL_SPELL_ID)
    if spellName then
        local macroName = MACRO_PREFIX .. "Ritual"
        local body = ("#showtooltip %s\n/cast %s\n/run Warlock_Qol_Tbc.SayRitualLine()")
            :format(spellName, spellName)
        local icon = GetSpellTextureByID(RITUAL_SPELL_ID) or 134400
        Tally(UpsertMacro(macroName, icon, body), macroName, counts)
    end
    return counts.created, counts.updated, counts.conflicts
end

-- Create/refresh the single Ritual of Souls macro. The macro casts the spell then calls
-- Warlock_Qol_Tbc.SaySoulsLine() to say the line. Built regardless of whether the spell is
-- known (name resolves from the spell database; the /cast no-ops until learned) so the full
-- macro set is always present. Same shape as the others.
function WQ.CreateSoulsMacro()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0, 0, {}
    end

    local counts = { created = 0, updated = 0, conflicts = {} }
    local spellName = GetSpellNameByID(RITUAL_OF_SOULS_SPELL_ID)
    if spellName then
        local macroName = MACRO_PREFIX .. "Souls"
        local body = ("#showtooltip %s\n/cast %s\n/run Warlock_Qol_Tbc.SaySoulsLine()")
            :format(spellName, spellName)
        local icon = GetSpellTextureByID(RITUAL_OF_SOULS_SPELL_ID) or 134400
        Tally(UpsertMacro(macroName, icon, body), macroName, counts)
    end
    return counts.created, counts.updated, counts.conflicts
end

-- Create/refresh every macro in one pass (summon families + both rituals), aggregating the
-- counts. Combat-guarded once here so the message isn't printed three times.
function WQ.CreateAllMacros()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0, 0, {}
    end

    local created, updated, conflicts = 0, 0, {}
    for _, create in ipairs({ WQ.CreateSummonMacros, WQ.CreateRitualMacro, WQ.CreateSoulsMacro }) do
        local c, u, cf = create()
        created, updated = created + c, updated + u
        for _, name in ipairs(cf) do conflicts[#conflicts + 1] = name end
    end
    return created, updated, conflicts
end

-- Delete only the pet summon macros we created. Returns count removed.
function WQ.RemoveSummonMacros()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0
    end
    local removed = 0
    for _, family in ipairs(WQ.PET_FAMILIES) do
        if RemoveSignedMacro(MACRO_PREFIX .. family) then removed = removed + 1 end
    end
    return removed
end

-- Delete the ritual macro if we created it. Returns count removed (0 or 1).
function WQ.RemoveRitualMacro()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0
    end
    return RemoveSignedMacro(MACRO_PREFIX .. "Ritual") and 1 or 0
end

-- Delete the Ritual of Souls macro if we created it. Returns count removed (0 or 1).
function WQ.RemoveSoulsMacro()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0
    end
    return RemoveSignedMacro(MACRO_PREFIX .. "Souls") and 1 or 0
end

-- Reset Macros: remove every macro we made (lines/toggles/profiles kept).
function WQ.ResetMacros()
    local removed = WQ.RemoveSummonMacros() + WQ.RemoveRitualMacro() + WQ.RemoveSoulsMacro()
    print(("|cff9900ffWarlockQol|r: removed %d macro(s). Your saved lines were kept."):format(removed))
end

-- ── Cooldown Tracker (core: comms + roster + combat-log fallback; party AND raid) ─────────
-- Tracks each party/raid warlock's cooldown state for the HUD. Hybrid: addon users broadcast their
-- own real remaining over comms (authoritative); non-users are guessed from the combat log
-- (in range only) using a fixed duration. Comms always supersedes a combat-log guess. Roster
-- comes from UnitClass so every warlock gets a row ("Ready" until we have a timer).
-- Data-driven via TRACKED_COOLDOWNS; `castName` matches the combat-log spell, `duration` is
-- the combat-log fallback only.
local SOULSTONE_FALLBACK_CD = 1800  -- seconds (30 min); soulstone CD is a fixed 30 min
local TRACKED_COOLDOWNS = {
    soulstone = {
        key      = "soulstone",
        label    = "Soulstone CD",
        class    = "WARLOCK",
        castName = SOULSTONE_SPELL_NAME,   -- reuse the announcer's cast-name match
        duration = SOULSTONE_FALLBACK_CD,
        icon     = "Interface\\Icons\\Spell_Shadow_SoulGem",  -- HUD row icon
    },
}
-- Stable iteration order for tracked cooldowns.
local TRACKED_ORDER = { "soulstone" }

-- Addon-message prefix (registered at PLAYER_LOGIN). Messages:
--   "S:<cdKey>:<remaining>"  — broadcast my own remaining for one cooldown.
--   "R"                      — request resync; recipients rebroadcast their cooldowns.
local TRACKER_PREFIX = "WQoLCD"

-- Runtime store (NOT saved): cdState[cdKey][name] = { expires, source="comms"|"combatlog" }.
-- comms is authoritative and never clobbered by a combatlog guess.
local cdState = {}
for _, key in ipairs(TRACKED_ORDER) do cdState[key] = {} end

-- Drop any "-Realm" suffix so the store keys on the bare name.
local function StripRealm(name)
    return name and name:gsub("%-.*", "") or name
end

-- Every WARLOCK in the raid (or just the player when not in one). Returns { name, unit, isPlayer } entries.
-- Warlocks in the current group. In a raid: every raid member. In a party: the player + party1..4.
-- Solo (or non-warlock): just the player if a warlock. Roster only — the HUD/comms decide what to show.
local function GroupWarlocks()
    local out = {}
    local function addPlayer()
        local _, myClass = UnitClass("player")
        if myClass == "WARLOCK" then
            out[#out + 1] = { name = StripRealm(UnitName("player")), unit = "player", isPlayer = true }
        end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local _, class = UnitClass(unit)
                if class == "WARLOCK" then
                    out[#out + 1] = { name = StripRealm(UnitName(unit)), unit = unit, isPlayer = UnitIsUnit(unit, "player") }
                end
            end
        end
    elseif IsInGroup() then
        -- Party: party units are the OTHER members, so add the player explicitly.
        addPlayer()
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local _, class = UnitClass(unit)
                if class == "WARLOCK" then
                    out[#out + 1] = { name = StripRealm(UnitName(unit)), unit = unit, isPlayer = false }
                end
            end
        end
    else
        addPlayer()   -- solo: show only the player
    end
    return out
end

-- Record a cooldown timer. source "comms" (authoritative) supersedes "combatlog" (guess) and
-- is never overwritten by one; comms remaining <= 0 clears the timer.
local function SetCooldown(cdKey, unitName, remaining, source)
    unitName = StripRealm(unitName)
    if not unitName or unitName == "" then return end
    local store = cdState[cdKey]
    if not store then return end
    if remaining and remaining > 0 then
        local existing = store[unitName]
        if source == "combatlog" and existing and existing.source == "comms" then
            return   -- never let a guess clobber an authoritative broadcast
        end
        store[unitName] = { expires = GetTime() + remaining, source = source }
    elseif source == "comms" then
        store[unitName] = nil   -- comms says it's up — clear any timer
    end
end

-- Remaining seconds for a unit's tracked cooldown, or 0 if ready/unknown. Prunes on expiry.
local function GetCooldownRemaining(cdKey, unitName)
    local store = cdState[cdKey]
    if not store then return 0 end
    unitName = StripRealm(unitName)
    local e = store[unitName]
    if not e then return 0 end
    local rem = e.expires - GetTime()
    if rem <= 0 then store[unitName] = nil; return 0 end
    return rem
end

-- The player's OWN remaining for a tracked spell (the seam that produces the broadcast).
-- Returns the fixed fallback duration; a live cooldown read could replace it later.
local function GetOwnCooldownRemaining(spec)
    return spec.duration   -- ⚠ placeholder until the live cooldown read is verified in-game
end

-- Broadcast channel: RAID in a raid, PARTY in a party, nil (solo) = don't send.
local function TrackerChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function SendTracker(msg)
    local chan = TrackerChannel()
    if not chan then return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(TRACKER_PREFIX, msg, chan)
    elseif SendAddonMessage then
        SendAddonMessage(TRACKER_PREFIX, msg, chan)
    end
end

-- Broadcast my remaining time for one cooldown (from my store, so it reflects elapsed time).
local function BroadcastCooldown(cdKey)
    local rem = GetCooldownRemaining(cdKey, UnitName("player"))
    if rem > 0 then SendTracker(("S:%s:%d"):format(cdKey, math.floor(rem))) end
end

local function BroadcastAllCooldowns()
    for _, key in ipairs(TRACKED_ORDER) do BroadcastCooldown(key) end
end

-- Tracker active for this character (master switch + per-profile flag).
local function TrackerActive()
    return FeatureOn("trackerEnabled")
end

-- Whether a cooldown is tracked (per-profile trackedCds; absent = tracked, only false disables).
local function IsCdTracked(cdKey)
    local p = ActiveProfile()
    if not p then return false end
    local t = p.trackedCds
    return not t or t[cdKey] ~= false
end

-- Ask everyone to rebroadcast (late-joiner catch-up). Throttled (GROUP_ROSTER_UPDATE spams).
local lastSyncRequest  = 0
local lastSyncResponse = 0   -- rate-limits our reply to incoming "R" so a flood can't make us spam
local function RequestTrackerSync()
    if not TrackerActive() then return end
    local now = GetTime()
    if now - lastSyncRequest < 5 then return end
    lastSyncRequest = now
    SendTracker("R")
end

-- Handle an incoming tracker message (ignore our own echo; drop malformed).
local function OnTrackerMessage(msg, sender)
    sender = StripRealm(sender)
    if not sender or sender == "" then return end
    if sender == StripRealm(UnitName("player")) then return end   -- ignore our own echo
    local tag = msg:sub(1, 1)
    if tag == "S" then
        local cdKey, rem = msg:match("^S:([%w_]+):(%d+)$")
        local spec = cdKey and TRACKED_COOLDOWNS[cdKey]
        if spec and rem then
            -- Clamp to the cooldown's own max so a crafted message can't show a bogus huge countdown.
            local secs = math.min(tonumber(rem), spec.duration or SOULSTONE_FALLBACK_CD)
            SetCooldown(cdKey, sender, secs, "comms")
            if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
        end
    elseif tag == "R" then
        -- Rate-limit our reply so a "R" flood can't turn us into an addon-message spammer.
        local now = GetTime()
        if now - lastSyncResponse < 5 then return end
        lastSyncResponse = now
        BroadcastAllCooldowns()
    end
end

-- Persist my own cooldown expiry as a wall-clock time() stamp (survives /reload, unlike GetTime).
local function PersistOwnCooldown(cdKey, remaining)
    local cs = CharState()
    if not cs then return end
    cs.ownCds = cs.ownCds or {}
    if remaining and remaining > 0 then
        cs.ownCds[cdKey] = time() + remaining
    else
        cs.ownCds[cdKey] = nil
    end
end

-- On login, re-seed my own timers from the saved expiries (cdState is wiped on reload). Drops expired.
local function RestoreOwnCooldowns()
    local cs = CharState()
    if not cs or not cs.ownCds then return end
    local myName = UnitName("player")
    for cdKey, expiry in pairs(cs.ownCds) do
        local remaining = expiry - time()
        if remaining > 0 and cdState[cdKey] then
            SetCooldown(cdKey, myName, remaining, "comms")   -- authoritative (it's mine)
        else
            cs.ownCds[cdKey] = nil   -- expired/unknown cooldown; drop the stale entry
        end
    end
end

-- Combat-log hook for a tracked cast. Mine: record/persist/broadcast my own timer. Someone
-- else's: record a combat-log guess (won't overwrite a comms entry).
local function OnTrackedCast(cdKey, sourceName, sourceFlags)
    if not TrackerActive() then return end
    if not IsCdTracked(cdKey) then return end   -- this cooldown's tracking is toggled off
    local spec = TRACKED_COOLDOWNS[cdKey]
    if not spec then return end
    if IsMine(sourceFlags) then
        local rem = GetOwnCooldownRemaining(spec)
        SetCooldown(cdKey, UnitName("player"), rem, "comms")
        PersistOwnCooldown(cdKey, rem)
        BroadcastCooldown(cdKey)
    elseif InMyGroup(sourceFlags) then
        SetCooldown(cdKey, sourceName, spec.duration, "combatlog")
    end
    if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
end

-- ── Soulstone Active tracker (who currently HAS a soulstone buff) ──────────────
-- Distinct from the cooldown tracker above (that's the CASTER's 30-min CD); this is the 30-min
-- resurrection buff sitting on the TARGET. Detected by scanning group members' HELPFUL auras for
-- the soulstone buff (same name the announcer matches). LOCAL only — everyone scans their own group,
-- so no comms. ssActive[name] = { expires (GetTime domain, 0 = active but unknown time), isPlayer }.
local ssActive = {}

-- Units to scan: every raid member in a raid, else the player + party (works in party AND raid).
local function GroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    else
        units[#units + 1] = "player"
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
    end
    return units
end

-- Return the soulstone buff's expirationTime on a unit (GetTime domain), or nil if absent.
local function UnitSoulstoneExpiry(unit)
    for i = 1, 40 do
        local name, _, _, _, _, expiration = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if name == SOULSTONE_SPELL_NAME then return expiration or 0 end
    end
    return nil
end

-- Active for this character = master + tracker on + the per-profile "Soulstone Active" flag.
local function ActiveSoulstonesActive()
    local p = ActiveProfile()
    return TrackerActive() and p and p.soulstoneActiveEnabled and true or false
end

-- Rescan the group and rebuild ssActive. Returns true if the SET of stoned players changed (so the
-- HUD knows to rebuild rows vs. just re-tick the countdowns). Clears the store when the feature is off.
local function ScanActiveSoulstones()
    if not ActiveSoulstonesActive() then
        local had = next(ssActive) ~= nil
        ssActive = {}
        return had
    end
    local seen = {}
    for _, unit in ipairs(GroupUnits()) do
        if UnitExists(unit) then
            local exp = UnitSoulstoneExpiry(unit)
            if exp then
                local name = StripRealm(UnitName(unit))
                if name and name ~= "" then
                    seen[name] = { expires = exp, isPlayer = UnitIsUnit(unit, "player") }
                end
            end
        end
    end
    local changed = false
    for name in pairs(seen)     do if not ssActive[name] then changed = true break end end
    if not changed then for name in pairs(ssActive) do if not seen[name] then changed = true break end end end
    ssActive = seen
    return changed
end

-- ── Missing Consumables (detection core) ──────────────────────────────────────
-- LOCAL only (no comms/announce): scans the player's buffs + main-hand enchant for MISSING or
-- soon-to-EXPIRE raid consumables, feeding the HUD. Data-driven. Detection is by buff NAME
-- (deliberate exception to "ids not names": "Well Fed" has one stable name; assumes enUS).
local CONSUMABLES = {
    flask = {
        label = "Flask",
        icon  = "Interface\\Icons\\INV_Potion_115",   -- Flask of Pure Death (used for both flasks)
        kind  = "aura",
        auras = { "Flask of Pure Death", "Supreme Power" },   -- Supreme Power = Flask of Supreme Power
    },
    oil = {
        label = "Weapon Oil",
        icon  = "Interface\\Icons\\INV_Potion_141",   -- Superior Wizard Oil (used for both oils)
        kind  = "weapon",   -- a temporary MAIN-HAND enchant (Wizard/Mana Oil), NOT a buff aura
    },
    food = {
        label = "Well Fed",
        icon  = "Interface\\Icons\\Spell_Misc_Food",
        kind  = "aura",
        auras = { "Well Fed" },
    },
    elixir = {
        label = "Elixir",
        icon  = "Interface\\Icons\\INV_Potion_105",   -- caster elixir (Major Shadow/Fire Power)
        kind  = "aura",
        -- The two warlock caster elixirs. Matched by buff NAME; both the item-name and short-spell-name
        -- forms are listed so we catch whichever string the client uses. NOTE: you can't run an elixir
        -- alongside a flask, so this one DEFAULTS OFF (enable it + turn Flask off for non-flask nights).
        auras = { "Elixir of Major Shadow Power", "Major Shadow Power",
                  "Elixir of Major Firepower",    "Major Firepower" },
        defaultOff = true,   -- absent from trackedConsumes = NOT tracked (opposite of the others)
    },
}
-- Stable display order.
local CONSUMABLE_ORDER = { "flask", "oil", "food", "elixir" }

-- Feature active for this character (master switch + per-profile flag).
local function ConsumablesActive()
    return FeatureOn("consumablesEnabled")
end

-- Whether a consumable is tracked. Explicit true/false in the per-profile trackedConsumes wins; when
-- absent, fall back to the consumable's default (all default ON except ones flagged defaultOff, e.g.
-- elixirs, which start OFF because they can't be used with a flask).
local function IsConsumeTracked(key)
    local p = ActiveProfile()
    if not p then return false end
    local v = p.trackedConsumes and p.trackedConsumes[key]
    if v == nil then
        local spec = CONSUMABLES[key]
        return not (spec and spec.defaultOff)
    end
    return v ~= false
end

-- The "about to expire" warning window in seconds (per-profile; default/clamp 120 = 2 min).
local function ConsumeThreshold()
    local p = ActiveProfile()
    local v = p and p.consumeThreshold
    if type(v) ~= "number" or v <= 0 then return 120 end
    return v
end

-- Scan the player's HELPFUL auras + main-hand enchant. Returns key -> { present, remaining }.
local function ScanConsumables()
    local out = {}
    for _, key in ipairs(CONSUMABLE_ORDER) do out[key] = { present = false, remaining = 0 } end

    -- Match each buff NAME against the aura-kind consumables (expirationTime is a GetTime() stamp).
    local i = 1
    while true do
        local name, _, _, _, _, expiration = UnitAura("player", i, "HELPFUL")
        if not name then break end
        for _, key in ipairs(CONSUMABLE_ORDER) do
            local spec = CONSUMABLES[key]
            if spec.kind == "aura" and not out[key].present then
                for _, an in ipairs(spec.auras) do
                    if name == an then
                        out[key].present   = true
                        out[key].remaining = (expiration and expiration > 0) and (expiration - GetTime()) or 0
                        break
                    end
                end
            end
        end
        i = i + 1
    end

    -- Weapon oil = a temporary MAIN-HAND enchant. GetWeaponEnchantInfo gives has-enchant +
    -- remaining MILLISECONDS but no name, so for a warlock any main-hand temp enchant is taken
    -- as the oil slot (virtually always a Wizard/Mana Oil).
    local hasMain, mainExpMs = GetWeaponEnchantInfo()
    for _, key in ipairs(CONSUMABLE_ORDER) do
        if CONSUMABLES[key].kind == "weapon" and hasMain then
            out[key].present   = true
            out[key].remaining = (mainExpMs and mainExpMs / 1000) or 0
        end
    end
    return out
end

-- ── Curse Tracker (core: combat-log fed; party AND raid) ──────────────────────
-- Shows which raid curses group warlocks currently have out, on ANY mob (not only your target),
-- with who cast each one and how long it has left. Purely combat-log driven, and deliberately so:
-- UnitAura can read only a unit we hold a token for (target/focus/nameplate), which would miss every
-- mob nobody is looking at and could not reliably name the caster. One combat-log event carries the
-- caster, the target, the target's raid marker and the spell together.
--
-- Durations come from a fixed table because the log never reports them. Unlike the cooldown tracker's
-- fallback this is not a guess: no TBC talent modifies curse duration, so the timer is exact from the
-- moment we see the event.
--
-- Data-driven like TRACKED_COOLDOWNS / CONSUMABLES: adding a curse is a table edit. `baseId` is the
-- rank 1 spell ID, used ONLY to resolve the localised name (all ranks share it) so matching stays
-- rank-agnostic and locale-safe, exactly like BanishName().
local CURSES = {
    elements = { label = "Elements",     baseId = 1490, duration = 300, icon = "Interface\\Icons\\Spell_Shadow_ChillTouch"       },
    reckless = { label = "Recklessness", baseId = 704,  duration = 120, icon = "Interface\\Icons\\Spell_Shadow_UnholyStrength"   },
    weakness = { label = "Weakness",     baseId = 702,  duration = 120, icon = "Interface\\Icons\\Spell_Shadow_CurseOfMannoroth" },
    tongues  = { label = "Tongues",      baseId = 1714, duration = 30,  icon = "Interface\\Icons\\Spell_Shadow_CurseOfTounges"   },
}
-- Stable iteration order (UI checkbox order).
local CURSE_ORDER = { "elements", "reckless", "weakness", "tongues" }

-- Hard cap on HUD rows. A trash pull with several warlocks can curse a lot of mobs at once; past this
-- the list stops being readable, and the snapshot is sorted so the rows that survive are the ones that
-- matter (own curses, then soonest to drop).
local CURSE_MAX_ROWS = 6

-- Runtime store (NOT saved): curseState["<destGUID>:<curseKey>"] = entry. Keyed that way because TBC
-- allows one curse PER CASTER per target, so several warlocks' different curses coexist on one mob and
-- each needs its own row, while the same curse recast by a second warlock simply replaces the first.
local curseState = {}

-- Localised spell name -> curse key, memoised. Only a COMPLETE map is cached: spell data can be
-- unavailable for a moment early in the login sequence, and caching a partial map would blind us to a
-- curse for the rest of the session.
local curseByName
local function CurseKeyForSpell(spellName)
    if not spellName then return nil end
    if curseByName then return curseByName[spellName] end
    local map, complete = {}, true
    for key, spec in pairs(CURSES) do
        local n = GetSpellNameByID(spec.baseId)
        if n then map[n] = key else complete = false end
    end
    if complete then curseByName = map end   -- otherwise retry on the next event
    return map[spellName]
end

-- Row icon: prefer the client's own art for the spell, falling back to the hardcoded path.
local curseIcons = {}
local function CurseIcon(key)
    local icon = curseIcons[key]
    if not icon then
        local spec = CURSES[key]
        icon = GetSpellTextureByID(spec.baseId) or spec.icon
        curseIcons[key] = icon
    end
    return icon
end

-- Feature active for this character (master switch + per-profile flag).
local function CursesActive()
    return FeatureOn("cursesEnabled")
end

-- Whether a curse is tracked (per-profile trackedCurses; absent = tracked, only false disables).
local function IsCurseTracked(key)
    local p = ActiveProfile()
    if not p then return true end
    local v = p.trackedCurses and p.trackedCurses[key]
    if v == nil then return true end
    return v and true or false
end

-- The target's raid marker (1-8) or nil. destRaidFlags carries it as a COMBATLOG_OBJECT_RAIDTARGET1..8
-- bitmask, so the skull/cross icon comes free off the event: no GUID-to-unit resolution and no
-- nameplate scan. It is a snapshot from when the curse landed, so a marker changed afterwards stays
-- stale until that curse is refreshed.
local function RaidMarker(raidFlags)
    if not raidFlags or raidFlags == 0 then return nil end
    for i = 1, 8 do
        if bit.band(raidFlags, bit.lshift(1, i - 1)) ~= 0 then return i end
    end
    return nil
end

-- Drop expired rows. Called on every application (the only path that grows the table), so the store
-- stays bounded even while the HUD is hidden and nothing is reading the snapshot.
local function PruneCurses()
    local now = GetTime()
    for rowKey, e in pairs(curseState) do
        if e.expires - now <= 0 then curseState[rowKey] = nil end
    end
end

-- Forget every row on one mob. Fired by UNIT_DIED so a dead target's curses vanish instead of ticking
-- down to nothing. Returns true if anything was removed (the caller only refreshes the HUD then).
local function ClearCursesForGuid(guid)
    if not guid then return false end
    local hit = false
    for rowKey, e in pairs(curseState) do
        if e.guid == guid then curseState[rowKey] = nil; hit = true end
    end
    return hit
end

local function ClearAllCurses()
    if next(curseState) == nil then return false end
    wipe(curseState)
    return true
end

-- Curse debuff name for a key (rank-independent, so it matches any rank on the unit), memoised.
local curseNameByKey = {}
local function CurseNameByKey(key)
    local n = curseNameByKey[key]
    if not n then n = GetSpellNameByID(CURSES[key].baseId); curseNameByKey[key] = n end
    return n
end

-- Whether `unit` currently carries curse `key` (a HARMFUL-aura name scan). Returns true when the name
-- can't be resolved, so a lookup we can't trust never clears a row.
local function UnitHasCurse(unit, key)
    local want = CurseNameByKey(key)
    if not want then return true end
    for i = 1, 40 do
        local n = UnitAura(unit, i, "HARMFUL")
        if not n then break end
        if n == want then return true end
    end
    return false
end

-- Fixed unit tokens to resolve a stored curse's GUID back to a live unit (the group tokens are added
-- per call). target/focus/mouseover/boss cover mobs; player + raid/party cover a mind-controlled group
-- member who got cursed while hostile.
local RECONCILE_UNITS = { "player", "target", "focus", "mouseover", "boss1", "boss2", "boss3", "boss4", "boss5" }

-- Safety net over the combat-log death events: for any tracked curse whose target we can currently SEE,
-- clear the row when that unit is dead OR no longer actually carries the curse. The aura re-check is
-- what catches a curse ending with no SPELL_AURA_REMOVED reaching us: a dispel we were out of range
-- for, an expiry desync, or a mind-control breaking on a group member. A target we can't see is left
-- alone (out of range but alive is normal) and relies on UNIT_DIED / the combat-end clear / expiry.
-- Cheap: the store is capped at a handful of rows and this runs on a slow HUD cadence, not per event.
-- Returns true if the store changed. Public so the HUD tick can drive it.
local function ReconcileCurses()
    if next(curseState) == nil then return false end
    local seen   -- guid -> unit token, for every unit we can currently query
    local function note(unit)
        if UnitExists(unit) then
            local g = UnitGUID(unit)
            if g and not (seen and seen[g]) then seen = seen or {}; seen[g] = unit end
        end
    end
    for _, unit in ipairs(RECONCILE_UNITS) do note(unit) end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do note("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, 4 do note("party" .. i) end
    end
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if u then note(u) end
        end
    end
    if not seen then return false end
    local hit = false
    for rowKey, e in pairs(curseState) do
        local unit = seen[e.guid]
        if unit and (UnitIsDead(unit) or not UnitHasCurse(unit, e.curse)) then
            curseState[rowKey] = nil
            hit = true
        end
    end
    return hit
end
WQ.ReconcileCurses = ReconcileCurses

-- Record / refresh / drop one curse from a combat-log aura event. Only curses cast by a warlock in MY
-- group count (InMyGroup, as the soulstone announcer does), so a stranger's curses never appear.
-- Returns true when the store changed, i.e. when the HUD needs a rebuild.
local function OnCurseAura(subevent, sourceName, sourceFlags, destGUID, destName, destRaidFlags, spellName)
    if not CursesActive() then return false end
    local key = CurseKeyForSpell(spellName)
    if not key or not destGUID then return false end
    local rowKey = destGUID .. ":" .. key

    if subevent == "SPELL_AURA_REMOVED" then
        -- Clear the row however the curse ended (expired, dispelled, or replaced by the same warlock's
        -- next curse), but ONLY if the removal belongs to the caster we have stored. When one warlock's
        -- curse overwrites another's on the same mob, the removal of the old one and the application of
        -- the new one are two events on this same row key, and an out-of-order pair would otherwise
        -- delete the row that had just been created for the new caster.
        local e = curseState[rowKey]
        if e and (sourceName == nil or e.caster == StripRealm(sourceName)) then
            curseState[rowKey] = nil
            return true
        end
        return false
    end

    if not InMyGroup(sourceFlags) then return false end
    -- Note: an UNTRACKED curse is still stored. Filtering happens in GetCurseSnapshot, so ticking a
    -- curse back on shows the ones already out instead of waiting for them to be recast.
    PruneCurses()
    curseState[rowKey] = {
        guid    = destGUID,
        curse   = key,
        caster  = StripRealm(sourceName) or "?",
        isMine  = IsMine(sourceFlags),
        target  = StripRealm(destName) or "?",
        marker  = RaidMarker(destRaidFlags),
        expires = GetTime() + CURSES[key].duration,
    }
    return true
end

-- ── Event frame ───────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")

-- Forward decls (defined below the OnEvent handler, which calls them).
local UpdateCombatLogRegistration   -- shared combat-log listener (soulstone + banish + tracker + curses)
local UpdateTrackerRegistration     -- Raid CD Tracker listeners (comms + roster)
local UpdateCursesRegistration      -- Curse Tracker listeners (zone change, for auto-show)
local UpdateControlRegistration     -- Loss of Control listeners (PLAYER_CONTROL_LOST/GAINED)

eventFrame:RegisterEvent("ADDON_LOADED")           -- an addon finished loading
eventFrame:RegisterEvent("PLAYER_LOGIN")           -- UI (incl. chat) ready
eventFrame:RegisterEvent("UNIT_PET")               -- active pet changed

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        -- ADDON_LOADED fires for every addon, so check it's ours before acting.
        local name = ...
        if name == "Warlock_Qol_Tbc" then
            InitDB()   -- init the DB early (UI/casts may need it)
        end

    elseif event == "PLAYER_LOGIN" then
        -- Load message (printed here, not ADDON_LOADED, once chat is ready). Version from the .toc.
        local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local version = getMeta and getMeta("Warlock_Qol_Tbc", "Version") or "?"
        print(("|cff9900ffWarlockQol|r v%s loaded. Enjoy!"):format(version))

        -- First reliable point for UnitName/realm — resolve this character's profile binding.
        ResolveActiveBinding()

        local cs = CharState()

        -- One-time per-char default for the master switch, by class: warlocks default ON, everyone
        -- else OFF (non-warlocks can still open the app and enable it themselves). Applied once via
        -- classDefaultApplied so it never overrides a later manual toggle, and it corrects existing
        -- characters on their next login too.
        if cs and not cs.classDefaultApplied then
            cs.masterEnabled = IsWarlock()
            cs.classDefaultApplied = true
        end

        -- First run: show the setup wizard — WARLOCKS only (per-char setupComplete gates it; the
        -- wizard sets the flag on dismiss, not here). Non-warlocks skip it (still reachable from the
        -- Settings page's Show Setup Guide). Fall back to the hub if the wizard is unavailable.
        if cs and not cs.setupComplete and IsWarlock() then
            if WQ.ShowWizard then
                -- Defer one tick (frames shown mid-login can be swept closed); re-check the flag.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        local c2 = CharState()
                        if c2 and not c2.setupComplete then WQ.ShowWizard() end
                    end)
                else
                    WQ.ShowWizard()
                end
            elseif WQ.OpenHome then
                WQ.OpenHome()
                cs.setupComplete = true
            end
        end

        -- Start listening on the combat log if either announcer (soulstone / banish) is on.
        UpdateCombatLogRegistration()

        -- Raid CD Tracker: register comms prefix, re-seed my own timers before syncing (survives a
        -- mid-cooldown reload), sync listeners, request a state sync.
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(TRACKER_PREFIX)
        end
        RestoreOwnCooldowns()
        UpdateTrackerRegistration()
        RequestTrackerSync()

        -- Curse Tracker: no listeners of its own beyond the shared combat log + the zone-change event.
        UpdateCursesRegistration()

        -- Loss of Control: its own two events, nothing shared.
        UpdateControlRegistration()

        -- Restore the standalone HUDs (defined in the UI file) + position the minimap button.
        if WQ.InitTrackerHUD then WQ.InitTrackerHUD() end

        if WQ.InitConsumablesHUD then WQ.InitConsumablesHUD() end

        if WQ.InitRangeHUD then WQ.InitRangeHUD() end

        if WQ.InitCursesHUD then WQ.InitCursesHUD() end

        if WQ.InitMinimap then WQ.InitMinimap() end

        if WQ.ReapplyAccent then WQ.ReapplyAccent() end  -- apply the active profile's saved accent colour
        if WQ.ReapplyOpacity then WQ.ReapplyOpacity() end  -- ...and its saved backdrop opacity

    elseif event == "UNIT_PET" then
        local unit = ...
        if unit ~= "player" then return end
        if not UnitExists("pet") then return end  -- pet dismissed/died, not summoned

        -- family e.g. "Succubus", name e.g. "Kalneth" (both reliable after UNIT_PET fires).
        local family = UnitCreatureFamily("pet")
        local name   = UnitName("pet")

        if family and name then
            -- Cache the name (per-character; each toon names its own demons).
            local cs = CharState()
            if cs then cs.petNames[family] = name end
            if WQ.RefreshUI then WQ.RefreshUI() end   -- refresh the config UI if open
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Registered only while an announcer is on. Soulstone keys off the CAST (SPELL_CAST_SUCCESS
        -- fires once; aura events re-fire on range/desync) and only when it involves my group.
        -- Args: sourceFlags(6), destGUID(8), destName(9), destFlags(10), destRaidFlags(11),
        -- spellId(12), missType(15). destGUID/destRaidFlags feed the Curse Tracker (row key + marker).
        local _, subevent, _, _, sourceName, sourceFlags, _, destGUID, destName, destFlags, destRaidFlags, spellId, spellName, _, missType = CombatLogGetCurrentEventInfo()
        if subevent == "SPELL_CAST_SUCCESS" and spellName == SOULSTONE_SPELL_NAME then
            if InMyGroup(sourceFlags) or InMyGroup(destFlags) then
                SaySoulstone(destName)
            end
            -- Feed the Raid CD Tracker (my cast broadcasts real time; a group member's is a guess).
            OnTrackedCast("soulstone", sourceName, sourceFlags)
            -- A stone was just cast on someone — refresh the "Soulstones Out" list immediately.
            if ActiveSoulstonesActive() then
                ScanActiveSoulstones()
                if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
            end
        elseif spellName == BanishName() and IsMine(sourceFlags) then
            -- Fires only on MY banishes: landed (aura applied) or resisted. Rank appended.
            if subevent == "SPELL_AURA_APPLIED" then
                SayBanish(destName, BanishRankSuffix(spellId), false)
            elseif subevent == "SPELL_MISSED" and missType == "RESIST" then
                SayBanish(destName, BanishRankSuffix(spellId), true)
            end
        end

        -- Curse Tracker rides this same listener. Its own `if` rather than another elseif: the
        -- announcers above match on spell name, which can never be one of ours, so the two are
        -- independent. Subevent compares come first because this runs on EVERY combat-log event.
        -- The three death/despawn subevents all drop a unit's rows: UNIT_DIED (normal kill),
        -- UNIT_DESTROYED / UNIT_DISSIPATES (a summoned add going away without a normal death).
        local isGone = subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" or subevent == "UNIT_DISSIPATES"
        if isGone or subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH"
           or subevent == "SPELL_AURA_REMOVED" then
            local changed
            if isGone then
                changed = ClearCursesForGuid(destGUID)   -- unit gone: drop its rows, don't tick them out
            else
                changed = OnCurseAura(subevent, sourceName, sourceFlags, destGUID, destName, destRaidFlags, spellName)
            end
            -- One call, not a refresh plus a visibility check: a first curse landing (or the last one
            -- dropping) can change whether the HUD is shown at all, since "Hide when no curses are
            -- active" is data-gated, and the visibility pass rebuilds the rows whenever it ends up shown.
            if changed and WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
        end

    elseif event == "CHAT_MSG_ADDON" then
        -- Registered only while the tracker is active. Filter to our prefix.
        local prefix, message, _, sender = ...
        if prefix == TRACKER_PREFIX then
            OnTrackerMessage(message, sender)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Roster changed: request a sync, re-evaluate HUD visibility, refresh rows.
        RequestTrackerSync()
        if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
        if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Zoning (incl. entering/leaving a raid or party instance) — GROUP_ROSTER_UPDATE does NOT fire on
        -- a zone change, so drive the tracker's auto-show transitions off this event too.
        if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
        if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
        -- Same for the curse HUD, and drop any rows left over from the zone we just left.
        ClearAllCurses()
        if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end

    elseif event == "LOSS_OF_CONTROL_ADDED" then
        -- Primary detection: the entry carries locType / displayText / duration, so the announce can
        -- name the effect. The arg is the new entry's index on the builds that pass one.
        OnLossOfControlAdded(...)

    elseif event == "PLAYER_CONTROL_LOST" then
        -- Fallback only. No payload: this event says nothing but "you are not driving any more".
        -- OnControlLost does the filtering (taxi, combat), waits for the primary path to have its say,
        -- and only then guesses the category.
        OnControlLost()

    elseif event == "PLAYER_CONTROL_GAINED" then
        OnControlGained()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Left combat: whatever we were fighting is now dead, despawned, evaded or reset, so any curse
        -- still in the store is stale. Clears leftovers a missed UNIT_DIED would otherwise strand (a
        -- wipe/leash fires no death event at all). Live curses re-appear within a second of re-cursing.
        if ClearAllCurses() and WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
    end
end)

-- Keep the shared combat-log event registered while master is on AND any of soulstone / banish /
-- tracker is on (the tracker's fallback rides this listener too); drop it otherwise.
UpdateCombatLogRegistration = function()
    local cs = CharState()
    local p  = ActiveProfile()
    local want = cs and cs.masterEnabled and p
                 and (p.soulstoneEnabled or p.banishEnabled or p.trackerEnabled or p.cursesEnabled)
    if want then
        eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        eventFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
end

-- PLAYER_ENTERING_WORLD drives the raid/party-instance auto-show transitions for BOTH the cooldown HUD
-- and the curse HUD, so it is registered while EITHER is active and owned by neither (each feature's
-- own Update*Registration handles its other events, then calls this).
local function UpdateWorldRegistration()
    if TrackerActive() or CursesActive() then
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")   -- fires on zone-in (raid/party instance entry)
    else
        eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end

-- Register/unregister the tracker's OWN events (comms receive + roster) to match its enabled
-- state. The combat-log fallback is handled separately by UpdateCombatLogRegistration.
UpdateTrackerRegistration = function()
    if TrackerActive() then
        eventFrame:RegisterEvent("CHAT_MSG_ADDON")
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    else
        eventFrame:UnregisterEvent("CHAT_MSG_ADDON")
        eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    end
    UpdateWorldRegistration()
end

-- The curse tracker rides the shared combat log; on top of it, it needs the zone-change event (shared,
-- for auto-show) and PLAYER_REGEN_ENABLED (its own, to clear stale curses when a fight ends).
UpdateCursesRegistration = function()
    UpdateWorldRegistration()
    if CursesActive() then
        eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
        eventFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end
end

-- The Loss of Control announcer owns all three of its events outright: nothing else in the addon listens
-- for them, so unlike the shared PLAYER_ENTERING_WORLD (see UpdateWorldRegistration) plain
-- register/unregister pairs are safe here. Turning the feature on also clears the transition latch, so a
-- latch stranded by a missed PLAYER_CONTROL_GAINED can be cleared without a /reload.
local function ControlActive() return FeatureOn("controlEnabled") end

UpdateControlRegistration = function()
    if ControlActive() then
        controlLost = false
        eventFrame:RegisterEvent("PLAYER_CONTROL_LOST")
        eventFrame:RegisterEvent("PLAYER_CONTROL_GAINED")
        -- pcall because RegisterEvent RAISES on an event name the client does not know. C_LossOfControl
        -- is present on 2.5.6 so this should hold, but a wrong guess here must not break the fallback.
        if C_LossOfControl then
            pcall(eventFrame.RegisterEvent, eventFrame, "LOSS_OF_CONTROL_ADDED")
        end
    else
        eventFrame:UnregisterEvent("PLAYER_CONTROL_LOST")
        eventFrame:UnregisterEvent("PLAYER_CONTROL_GAINED")
        pcall(eventFrame.UnregisterEvent, eventFrame, "LOSS_OF_CONTROL_ADDED")
    end
end

-- Re-sync everything the curse tracker owns after the ACTIVE PROFILE changed (switch / copy / reset),
-- since all of its flags live on the profile. The callers already re-run UpdateCombatLogRegistration.
local function SyncCursesToProfile()
    ClearAllCurses()   -- rows were collected under the old profile's tracked-curse set
    UpdateCursesRegistration()
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end

-- Per-feature flags live on the active profile; the master switch is per-character (CharState).
function WQ.IsSoulstoneEnabled()
    local p = ActiveProfile()
    return p and p.soulstoneEnabled or false
end

-- Toggle the soulstone announcer; persists + updates event registration.
function WQ.SetSoulstoneEnabled(on)
    local p = ActiveProfile()
    if p then p.soulstoneEnabled = on and true or false end
    UpdateCombatLogRegistration()
end

function WQ.IsBanishEnabled()
    local p = ActiveProfile()
    return p and p.banishEnabled or false
end

-- Toggle the Banish announcer (same pattern as soulstone — it shares the combat-log event).
function WQ.SetBanishEnabled(on)
    local p = ActiveProfile()
    if p then p.banishEnabled = on and true or false end
    UpdateCombatLogRegistration()
end

-- Per-context party/raid announce toggles for soulstone & banish (default ON). These only gate which
-- group context announces — they DON'T touch event registration (the combat-log listener stays keyed
-- off the main *Enabled flag), so the setters just persist. Getters treat nil/absent as ON.
function WQ.IsSoulstonePartyEnabled()
    local p = ActiveProfile(); return p ~= nil and p.soulstonePartyEnabled ~= false
end
function WQ.SetSoulstonePartyEnabled(on)
    local p = ActiveProfile(); if p then p.soulstonePartyEnabled = on and true or false end
end
function WQ.IsSoulstoneRaidEnabled()
    local p = ActiveProfile(); return p ~= nil and p.soulstoneRaidEnabled ~= false
end
function WQ.SetSoulstoneRaidEnabled(on)
    local p = ActiveProfile(); if p then p.soulstoneRaidEnabled = on and true or false end
end
function WQ.IsBanishPartyEnabled()
    local p = ActiveProfile(); return p ~= nil and p.banishPartyEnabled ~= false
end
function WQ.SetBanishPartyEnabled(on)
    local p = ActiveProfile(); if p then p.banishPartyEnabled = on and true or false end
end
function WQ.IsBanishRaidEnabled()
    local p = ActiveProfile(); return p ~= nil and p.banishRaidEnabled ~= false
end
function WQ.SetBanishRaidEnabled(on)
    local p = ActiveProfile(); if p then p.banishRaidEnabled = on and true or false end
end

-- Battleground/arena announce toggles. Same shape as the pair above with the default INVERTED: absent
-- reads as OFF, so these getters test for an explicit true rather than for `~= false`.
function WQ.IsSoulstonePvpEnabled()
    local p = ActiveProfile(); return p ~= nil and p.soulstonePvpEnabled == true
end
function WQ.SetSoulstonePvpEnabled(on)
    local p = ActiveProfile(); if p then p.soulstonePvpEnabled = on and true or false end
end
function WQ.IsBanishPvpEnabled()
    local p = ActiveProfile(); return p ~= nil and p.banishPvpEnabled == true
end
function WQ.SetBanishPvpEnabled(on)
    local p = ActiveProfile(); if p then p.banishPvpEnabled = on and true or false end
end

-- Macro-feature flags: no event, so the setter just persists (the Say*Line guard reads it).
function WQ.IsPetEnabled()    local p = ActiveProfile(); return p and p.petEnabled    or false end
function WQ.SetPetEnabled(on)    local p = ActiveProfile(); if p then p.petEnabled    = on and true or false end end

function WQ.IsRitualEnabled() local p = ActiveProfile(); return p and p.ritualEnabled or false end
function WQ.SetRitualEnabled(on) local p = ActiveProfile(); if p then p.ritualEnabled = on and true or false end end

function WQ.IsSoulsEnabled()  local p = ActiveProfile(); return p and p.soulsEnabled  or false end
function WQ.SetSoulsEnabled(on)  local p = ActiveProfile(); if p then p.soulsEnabled  = on and true or false end end

-- Master switch (per-character). Off silences everything without touching per-feature flags;
-- the setter also drops the combat-log + tracker listeners and re-evaluates both HUDs.
function WQ.IsMasterEnabled() local cs = CharState(); return cs and cs.masterEnabled or false end
function WQ.SetMasterEnabled(on)
    local cs = CharState()
    if cs then cs.masterEnabled = on and true or false end
    UpdateCombatLogRegistration()
    UpdateTrackerRegistration()
    if WQ.UpdateTrackerHUDVisibility     then WQ.UpdateTrackerHUDVisibility()     end
    if WQ.UpdateConsumablesRegistration  then WQ.UpdateConsumablesRegistration()  end
    if WQ.UpdateConsumablesHUDVisibility then WQ.UpdateConsumablesHUDVisibility() end
    if WQ.UpdateRangeRegistration        then WQ.UpdateRangeRegistration()        end
    if WQ.UpdateRangeHUDVisibility       then WQ.UpdateRangeHUDVisibility()       end
    UpdateCursesRegistration()
    if WQ.UpdateCursesHUDVisibility      then WQ.UpdateCursesHUDVisibility()      end
    UpdateControlRegistration()
end

-- ── Raid CD Tracker public API ────────────────────────────────────────────────
-- The tracked-cooldown table + order are exposed read-only for the UI to build rows.
WQ.TRACKED_COOLDOWNS = TRACKED_COOLDOWNS
WQ.TRACKED_ORDER     = TRACKED_ORDER

-- Enabled flag (per-profile). Setter re-syncs listeners and requests a fresh state sync.
function WQ.IsTrackerEnabled() local p = ActiveProfile(); return p and p.trackerEnabled or false end
function WQ.SetTrackerEnabled(on)
    local p = ActiveProfile()
    if p then p.trackerEnabled = on and true or false end
    UpdateCombatLogRegistration()
    UpdateTrackerRegistration()
    RequestTrackerSync()
    if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
end

-- Per-profile "auto-show HUD" flags: raid (default on) + party (default off). Re-evaluate HUD visibility.
function WQ.IsTrackerShowRaid()  local p = ActiveProfile(); return p and p.trackerShowRaid  or false end
function WQ.SetTrackerShowRaid(on)
    local p = ActiveProfile(); if p then p.trackerShowRaid = on and true or false end
    if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
end
function WQ.IsTrackerShowParty() local p = ActiveProfile(); return p and p.trackerShowParty or false end
function WQ.SetTrackerShowParty(on)
    local p = ActiveProfile(); if p then p.trackerShowParty = on and true or false end
    if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
end

-- Per-cooldown tracking toggle. Off stops recording that cooldown.
function WQ.IsCooldownTracked(cdKey) return IsCdTracked(cdKey) end
function WQ.SetCooldownTracked(cdKey, on)
    local p = ActiveProfile(); if not p then return end
    p.trackedCds = p.trackedCds or {}
    p.trackedCds[cdKey] = on and true or false
    if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
end

-- Cheap store-only remaining getter (HUD's per-frame tick uses this). 0 = ready/unknown.
function WQ.GetTrackerRemaining(cdKey, unitName)
    return GetCooldownRemaining(cdKey, unitName)
end

-- Snapshot for the HUD: { name, isPlayer, cds = { [cdKey] = remaining (0 = ready) } } per warlock.
function WQ.GetTrackerSnapshot()
    local rows = {}
    for _, wl in ipairs(GroupWarlocks()) do
        local cds = {}
        for _, key in ipairs(TRACKED_ORDER) do
            cds[key] = GetCooldownRemaining(key, wl.name)
        end
        rows[#rows + 1] = { name = wl.name, isPlayer = wl.isPlayer, cds = cds }
    end
    -- Player first, then everyone else alphabetically (self-row pinned to the top).
    table.sort(rows, function(a, b)
        if a.isPlayer ~= b.isPlayer then return a.isPlayer end
        return a.name < b.name
    end)
    return rows
end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpCooldowns()): tracker state + each warlock's cooldowns.
function WQ.DebugDumpCooldowns()
    print(("|cff9900ffWarlockQol|r Tracker — active: %s"):format(TrackerActive() and "yes" or "no"))
    local snap = WQ.GetTrackerSnapshot()
    if #snap == 0 then print("  (no warlocks in group — solo shows only you if you're a warlock)") end
    for _, row in ipairs(snap) do
        local parts = {}
        for _, key in ipairs(TRACKED_ORDER) do
            local rem = row.cds[key]
            parts[#parts + 1] = ("%s=%s"):format(key, rem > 0 and (math.floor(rem) .. "s") or "Ready")
        end
        print(("  %s%s: %s"):format(row.name, row.isPlayer and " (you)" or "", table.concat(parts, ", ")))
    end
end

-- ── Soulstone Active public API ────────────────────────────────────────────────
-- Per-profile flag driving the HUD's "Soulstones Out" section. Setter rescans + rebuilds the HUD.
function WQ.IsSoulstoneActiveEnabled() local p = ActiveProfile(); return p and p.soulstoneActiveEnabled or false end
function WQ.SetSoulstoneActiveEnabled(on)
    local p = ActiveProfile(); if p then p.soulstoneActiveEnabled = on and true or false end
    ScanActiveSoulstones()
    if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
end

-- Rescan the group for soulstone buffs; returns true if the set of stoned players changed. The HUD's
-- driver calls this on a slow (~1s) tick and rebuilds its rows when it returns true.
function WQ.RefreshActiveSoulstones() return ScanActiveSoulstones() end

-- Sorted snapshot for the HUD: { name, remaining (nil = active/unknown time), isPlayer }, self first.
function WQ.GetActiveSoulstones()
    local list = {}
    for name, info in pairs(ssActive) do
        local rem
        if info.expires and info.expires > 0 then
            rem = info.expires - GetTime()
            if rem < 0 then rem = 0 end
        end
        list[#list + 1] = { name = name, remaining = rem, isPlayer = info.isPlayer }
    end
    table.sort(list, function(a, b)
        if a.isPlayer ~= b.isPlayer then return a.isPlayer end
        return a.name < b.name
    end)
    return list
end

-- Cheap store-only remaining getter for the HUD's per-frame tick. nil = not active; 0 = active but
-- unknown duration; >0 = seconds left.
function WQ.GetSoulstoneRemaining(name)
    local info = ssActive[StripRealm(name)]
    if not info then return nil end
    if not info.expires or info.expires <= 0 then return 0 end
    local rem = info.expires - GetTime()
    return rem > 0 and rem or 0
end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpSoulstones()): RAW group scan, bypassing the enable
-- toggle, so it's a pure feasibility probe — does the client report the soulstone buff (and its
-- duration) on each group member, including out-of-range ones? Matched by name = SOULSTONE_SPELL_NAME.
function WQ.DebugDumpSoulstones()
    print(("|cff9900ffWarlockQol|r Soulstones Out — feature active: %s (matching buff \"%s\")")
        :format(ActiveSoulstonesActive() and "yes" or "no", SOULSTONE_SPELL_NAME))
    local found = 0
    for _, unit in ipairs(GroupUnits()) do
        if UnitExists(unit) then
            local exp = UnitSoulstoneExpiry(unit)
            if exp then
                found = found + 1
                local t = (exp > 0) and (math.floor(exp - GetTime()) .. "s left") or "present, NO duration reported"
                print(("  %s (%s)%s: %s"):format(StripRealm(UnitName(unit)) or "?", unit,
                    UnitIsUnit(unit, "player") and " (you)" or "", t))
            end
        end
    end
    if found == 0 then print("  (no group member currently shows the soulstone buff — cast one and retry)") end
end

-- ── Missing Consumables public API ─────────────────────────────────────────────
-- The data table + order are exposed read-only for the UI to build the icon strip.
WQ.CONSUMABLES      = CONSUMABLES
WQ.CONSUMABLE_ORDER = CONSUMABLE_ORDER

-- Enabled flag (per-profile). HUD hooks are called defensively (nil pre-UI).
function WQ.IsConsumablesEnabled() local p = ActiveProfile(); return p and p.consumablesEnabled or false end
function WQ.SetConsumablesEnabled(on)
    local p = ActiveProfile()
    if p then p.consumablesEnabled = on and true or false end
    if WQ.UpdateConsumablesRegistration   then WQ.UpdateConsumablesRegistration()   end
    if WQ.UpdateConsumablesHUDVisibility   then WQ.UpdateConsumablesHUDVisibility()   end
end

-- Per-profile "auto-show the HUD" flags: raid (default on) + party dungeon (default off).
function WQ.IsConsumeShowRaid() local p = ActiveProfile(); return p and p.consumeShowRaid or false end
function WQ.SetConsumeShowRaid(on)
    local p = ActiveProfile(); if p then p.consumeShowRaid = on and true or false end
    if WQ.UpdateConsumablesHUDVisibility then WQ.UpdateConsumablesHUDVisibility() end
end
function WQ.IsConsumeShowParty() local p = ActiveProfile(); return p and p.consumeShowParty or false end
function WQ.SetConsumeShowParty(on)
    local p = ActiveProfile(); if p then p.consumeShowParty = on and true or false end
    if WQ.UpdateConsumablesHUDVisibility then WQ.UpdateConsumablesHUDVisibility() end
end

-- Per-profile "glow missing icons" flag. Off = plain icons (still shown, no glow).
function WQ.IsConsumeGlow() local p = ActiveProfile(); return p and p.consumeGlow or false end
function WQ.SetConsumeGlow(on)
    local p = ActiveProfile(); if p then p.consumeGlow = on and true or false end
    if WQ.RefreshConsumablesHUD then WQ.RefreshConsumablesHUD() end   -- force a rebuild (status unchanged)
end

-- Per-profile "transparent mode" flag. On = drop the HUD frame background/border + header (icons only).
function WQ.IsConsumeTransparent() local p = ActiveProfile(); return p and p.consumeTransparent or false end
function WQ.SetConsumeTransparent(on)
    local p = ActiveProfile(); if p then p.consumeTransparent = on and true or false end
    if WQ.ApplyConsumeTransparency then WQ.ApplyConsumeTransparency() end
end

-- Per-consumable tracking toggle (data-driven). Off removes it from the HUD entirely.
function WQ.IsConsumeTracked(key) return IsConsumeTracked(key) end
function WQ.SetConsumeTracked(key, on)
    local p = ActiveProfile(); if not p then return end
    p.trackedConsumes = p.trackedConsumes or {}
    p.trackedConsumes[key] = on and true or false
    if WQ.RefreshConsumablesHUD then WQ.RefreshConsumablesHUD() end
end

-- Expiry-warning threshold. Stored in SECONDS; the config page edits it in minutes. Clamped
-- to a sane 5s–60min so a shared/typo'd value can't break the HUD.
function WQ.GetConsumeThreshold() return ConsumeThreshold() end
function WQ.SetConsumeThreshold(secs)
    local p = ActiveProfile(); if not p then return end
    secs = tonumber(secs)
    if not secs or secs < 5 then secs = 120 elseif secs > 3600 then secs = 3600 end
    p.consumeThreshold = math.floor(secs)
    if WQ.RefreshConsumablesHUD then WQ.RefreshConsumablesHUD() end
end

function WQ.IsConsumablesActive() return ConsumablesActive() end

-- Snapshot of tracked consumables for the HUD. Each: { key, label, icon, present, remaining,
-- status } where status = "missing" / "low" (<= threshold) / "ok". Untracked ones omitted;
-- the HUD shows only missing/low.
function WQ.GetConsumableSnapshot()
    local scan      = ScanConsumables()
    local threshold = ConsumeThreshold()
    local rows = {}
    for _, key in ipairs(CONSUMABLE_ORDER) do
        if IsConsumeTracked(key) then
            local spec = CONSUMABLES[key]
            local s    = scan[key]
            local status
            if not s.present then
                status = "missing"
            elseif s.remaining > 0 and s.remaining <= threshold then
                status = "low"
            else
                status = "ok"
            end
            rows[#rows + 1] = {
                key = key, label = spec.label, icon = spec.icon,
                present = s.present, remaining = s.remaining, status = status,
            }
        end
    end
    return rows
end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpConsumables()): active state, threshold, each status.
function WQ.DebugDumpConsumables()
    print(("|cff9900ffWarlockQol|r Consumables — active: %s, threshold: %ds"):format(
        ConsumablesActive() and "yes" or "no", ConsumeThreshold()))
    for _, r in ipairs(WQ.GetConsumableSnapshot()) do
        local rem = r.remaining > 0 and (math.floor(r.remaining) .. "s") or "-"
        print(("  %s: %s (present=%s, rem=%s)"):format(r.label, r.status, tostring(r.present), rem))
    end
end

-- ── Range Indicator (detection core) ──────────────────────────────────────────
-- LOCAL only: reports a bracketed distance (min–max yards) to the current target, feeding the Range
-- HUD. WoW gives no exact distance — only yes/no "is the unit within checker X's range?" via
-- IsItemInRange (fixed-range items) / UnitInRange. We stack a ladder of checkers at KNOWN ranges and
-- report the tightest bracket the target is in. Same principle + data as LibRangeCheck (the item lists
-- are replicated public data, NOT the library, so we stay dependency-free — like the LibDBIcon math).
--
-- ITEMS ONLY, no warlock spells: a spell's range shifts with talents (Destructive Reach 30→36 on Shadow
-- Bolt, Grim Reach +20% on affliction spells), which would report a WRONG fixed yard value. Items have
-- a fixed range, so they never lie. Each RUNG lists MULTIPLE candidate item IDs (a rung resolves if ANY
-- candidate is a working checker on this client) — this is what keeps the bracket tight (a single dead/
-- un-cached item at 15 or 20yd would otherwise open a big gap). Bucket = the tightest 5yd step we can
-- hit; where every rung resolves, brackets stay 5 wide like the reference WeakAura.

-- Harmful checkers (ATTACKABLE unit), rung → candidate item IDs, ascending. TBC-available only.
local RANGE_HARM = {
    {   5, { 8149 } },                 -- Voodoo Charm
    {   8, { 34368, 33278 } },         -- Attuned Crystal Cores / Burning Torch
    {  10, { 32321, 17626 } },         -- Sparrowhawk Net / Frostwolf Muzzle
    {  15, { 33069 } },                -- Sturdy Rope
    {  20, { 10645 } },                -- Gnomish Death Ray
    {  25, { 24268, 31463, 13289 } },  -- Netherweave Net / Zezzak's Shard / Egan's Blaster
    {  30, { 835, 7734 } },            -- Large Rope Net / Six Demon Bag
    {  35, { 24269, 18904 } },         -- Heavy Netherweave Net / Zorbin's Ultra-Shrinker
    {  40, { 28767 } },                -- The Decapitator
    {  45, { 23836 } },                -- Goblin Rocket Launcher
    {  60, { 32825 } },                -- Soul Cannon (ceiling: anything past 60yd is well beyond
                                       -- warlock cast range, so ">60" is enough)
}
-- Friendly checkers (nets/harm items return nil on a friend, so friends need their own set). The 40yd
-- UnitInRange (group members only) is added at runtime as a reliable anchor.
local RANGE_FRIEND = {
    {   5, { 8149 } },                 -- Voodoo Charm
    {   8, { 34368, 33278 } },         -- Attuned Crystal Cores / Burning Torch
    {  10, { 32321, 17626 } },         -- Sparrowhawk Net / Frostwolf Muzzle
    {  15, { 21990, 34721, 14529, 14530 } },  -- bandages (Netherweave/Heavy Netherweave/Runecloth)
    {  20, { 21519 } },                -- Mistletoe (the only 20yd friendly checker; resolves year-round)
    {  25, { 31463, 13289 } },         -- Zezzak's Shard / Egan's Blaster
    {  30, { 1180, 1478 } },           -- Scroll of Stamina / Scroll of Spirit
    {  35, { 18904 } },                -- Zorbin's Ultra-Shrinker
    {  40, { 34471 } },                -- Vial of the Sunwell
    {  45, { 32698 } },                -- Wrangling Rope
    {  60, { 32825 } },                -- Soul Cannon (ceiling)
}
-- Fallback checkers for a unit that is neither attackable NOR assistable: a friendly NPC. NO item
-- resolves on one (IsItemInRange answers "could I use this on that unit, distance aside?", and a
-- bandage on a quest giver is not a valid action), so both ladders above return nil on every rung and
-- the bracket would read "(?)". Interact distance is the only range signal an NPC exposes, so this is
-- as good as it gets: coarse, and blind past ~28yd. LibRangeCheck has the same fallback and the same
-- ceiling. Rung → candidate CheckInteractDistance indices, ascending.
local RANGE_MISC = {
    {  8, { 3 } },        -- duel
    {  9, { 2 } },        -- trade (may not resolve on an NPC — DebugDumpRange shows whether it does)
    { 28, { 4, 1 } },     -- follow / inspect
}

-- Feature active for this character (master switch + per-profile flag).
local function RangeActive()
    return FeatureOn("rangeEnabled")
end

-- The global IsItemInRange became a PROTECTED function in the 2.5.6-era client update: calling it
-- taints in combat and spams ADDON_ACTION_BLOCKED ("tried to call the protected function ...") even
-- though the range read still nominally works. C_Item.IsItemInRange (same (itemID, unit) signature,
-- returns bool/nil, flagged AllowedWhenUntainted) is the safe namespaced replacement and IS present in
-- 2.5.6. Prefer it, falling back to the old global only where the namespaced one is missing — same
-- shape as the GetSpellNameByID / AddonVersion shims.
local ItemInRange
do
    local cf = C_Item and C_Item.IsItemInRange
    ItemInRange = cf and function(id, unit) return cf(id, unit) end or IsItemInRange
end

-- IsItemInRange returns nil until the item is cached; GetItemInfo requests the load. So keep warming
-- every call until all items resolve (then stop) — self-heals the "gap in the first few seconds" case.
-- The attempt cap stops the loop even if an item never resolves (e.g. a bad ID not in this client's
-- DB) so it can't retry forever; every VALID item caches within seconds.
local rangeAllCached, rangeWarmAttempts = false, 0
local RANGE_WARM_MAX_ATTEMPTS = 40
local function WarmRange()
    if rangeAllCached then return end
    rangeWarmAttempts = rangeWarmAttempts + 1
    local missing = 0
    for _, ladder in ipairs({ RANGE_HARM, RANGE_FRIEND }) do
        for _, rung in ipairs(ladder) do
            for _, id in ipairs(rung[2]) do
                if not GetItemInfo(id) then missing = missing + 1 end
            end
        end
    end
    if missing == 0 or rangeWarmAttempts >= RANGE_WARM_MAX_ATTEMPTS then rangeAllCached = true end
end

-- Resolve one rung against a unit: try each candidate item; the first that returns non-nil wins
-- → true (in range) / false (out of range). nil = no candidate resolved (rung is a gap this call).
local function RungResult(ids, unit)
    for _, id in ipairs(ids) do
        local r = ItemInRange(id, unit)
        if r ~= nil then return r and true or false end
    end
    return nil
end

-- Same contract as RungResult, but for the interact-distance rungs (RANGE_MISC).
local function InteractResult(indices, unit)
    for _, idx in ipairs(indices) do
        local r = CheckInteractDistance(unit, idx)
        if r ~= nil then return r and true or false end
    end
    return nil
end

-- Which ladder applies to a unit. THREE reaction classes, not two — the "not attackable = friendly
-- player" assumption was wrong and left friendly NPCs with no working checker at all:
--   harm   → attackable            → item ladder
--   friend → assistable (players)  → item ladder + the UnitInRange anchor
--   misc   → neither (NPCs)        → interact distance only
local function ReactionClass(unit)
    if UnitCanAttack("player", unit) then return "harm" end
    if UnitCanAssist("player", unit) then return "friend" end
    return "misc"
end

-- Ladder + rung resolver for a reaction class.
local function LadderFor(class)
    if class == "harm"   then return RANGE_HARM,   RungResult end
    if class == "friend" then return RANGE_FRIEND, RungResult end
    return RANGE_MISC, InteractResult
end

-- Item/interact range checks (IsItemInRange, C_Item.IsItemInRange, CheckInteractDistance) are PROTECTED
-- while in combat on a NON-attackable unit (a friendly player or friendly NPC): calling them then taints
-- and fires ADDON_ACTION_BLOCKED. Attackable targets are always safe, and everything is safe out of
-- combat. This is LibRangeCheck-3.0's exact guard — when it's true we skip the item/interact ladder and
-- rely on the non-protected UnitInRange anchor (group members only), so a friendly target in combat may
-- read "(?)" instead of a bracket. Namespaced C_Item.IsItemInRange alone does NOT dodge this.
local function RangeChecksBlocked(unit)
    return InCombatLockdown() and not UnitCanAttack("player", unit)
end

-- Bracket the current target's distance. Returns:
--   nil            → no target
--   name, lo, hi   → lo < dist ≤ hi (lo defaults 0 = within the smallest checker; hi nil = beyond
--                    the furthest checker, i.e. ">lo")
--   name, nil, nil → have a target but no checker resolved (unknown)
function WQ.GetTargetRange()
    local unit = "target"
    if not UnitExists(unit) then return nil end
    local name = UnitName(unit) or "?"

    WarmRange()
    local class = ReactionClass(unit)
    local ladder, resolve = LadderFor(class)

    -- Accumulate: lo = largest OUT-of-range rung, hi = smallest IN-range rung. nil rungs skip.
    -- OUT rungs only count while no IN has been seen yet (ascending order → the first IN is the
    -- boundary; a later "OUT" at a larger range is checker disagreement, not real, so ignore it).
    local lo, hi, any = 0, nil, false
    local function consider(yards, res)
        if res == nil then return end
        any = true
        if res then
            if hi == nil or yards < hi then hi = yards end
        elseif hi == nil and yards > lo then
            lo = yards
        end
    end

    -- Friendly group members get the reliable ~40yd UnitInRange anchor first (NOT protected, safe in
    -- combat) — this is the only signal left on a friendly unit while the item ladder is blocked.
    if class == "friend" and UnitInRange and (UnitInParty(unit) or UnitInRaid(unit)) then
        consider(40, UnitInRange(unit) and true or false)
    end
    -- The item/interact ladder taints on a non-attackable unit in combat; skip it then (see above).
    if not RangeChecksBlocked(unit) then
        for _, rung in ipairs(ladder) do consider(rung[1], resolve(rung[2], unit)) end
    end

    if not any then return name, nil, nil end
    if hi and lo >= hi then lo = 0 end   -- guard an impossible bracket from checker disagreement
    return name, lo, hi
end

-- ── Range Indicator public API ─────────────────────────────────────────────────
function WQ.IsRangeActive() return RangeActive() end

-- Enabled flag (per-profile). HUD hooks are called defensively (nil pre-UI).
function WQ.IsRangeEnabled() local p = ActiveProfile(); return p and p.rangeEnabled or false end
function WQ.SetRangeEnabled(on)
    local p = ActiveProfile()
    if p then p.rangeEnabled = on and true or false end
    if WQ.UpdateRangeRegistration   then WQ.UpdateRangeRegistration()   end
    if WQ.UpdateRangeHUDVisibility  then WQ.UpdateRangeHUDVisibility()  end
end

-- Per-profile "transparent mode" flag. On = drop the HUD frame background/border + header (text only).
function WQ.IsRangeTransparent() local p = ActiveProfile(); return p and p.rangeTransparent or false end
function WQ.SetRangeTransparent(on)
    local p = ActiveProfile(); if p then p.rangeTransparent = on and true or false end
    if WQ.ApplyRangeTransparency then WQ.ApplyRangeTransparency() end
end

-- Per-profile "hide when no target" flag. On = the HUD disappears entirely with no target (default
-- off = stays put showing "No target").
function WQ.IsRangeHideNoTarget() local p = ActiveProfile(); return p and p.rangeHideNoTarget or false end
function WQ.SetRangeHideNoTarget(on)
    local p = ActiveProfile(); if p then p.rangeHideNoTarget = on and true or false end
    if WQ.UpdateRangeHUDVisibility then WQ.UpdateRangeHUDVisibility() end
end

-- Per-profile HUD text size (points), for the target name + range value. Clamped to a sane range.
local RANGE_FONT_MIN, RANGE_FONT_MAX = 8, 40
function WQ.GetRangeFontSize()
    local p = ActiveProfile()
    local v = p and p.rangeFontSize
    if type(v) ~= "number" then return 16 end
    if v < RANGE_FONT_MIN then return RANGE_FONT_MIN end
    if v > RANGE_FONT_MAX then return RANGE_FONT_MAX end
    return v
end
function WQ.SetRangeFontSize(n)
    n = tonumber(n); if not n then return end
    n = math.floor(n + 0.5)
    if n < RANGE_FONT_MIN then n = RANGE_FONT_MIN end
    if n > RANGE_FONT_MAX then n = RANGE_FONT_MAX end
    local p = ActiveProfile(); if p then p.rangeFontSize = n end
    if WQ.ApplyRangeFont then WQ.ApplyRangeFont() end
end

-- Per-profile accent colour (Settings page). Stored as a 6-hex string; the UI's WQ.ReapplyAccent
-- mutates THEME.accent and repaints every accented element.
function WQ.GetAccent()
    local p = ActiveProfile()
    local hex = p and p.accent
    if type(hex) == "string" and hex:match("^%x%x%x%x%x%x$") then return hex:lower() end
    return WQ.DEFAULT_ACCENT
end
function WQ.SetAccent(hex)
    if type(hex) ~= "string" or not hex:match("^%x%x%x%x%x%x$") then return end
    local p = ActiveProfile(); if p then p.accent = hex:lower() end
    if WQ.ReapplyAccent then WQ.ReapplyAccent() end   -- live repaint (defined in the UI file)
end

-- Per-profile backdrop opacity, a whole percent 0-100. There are FIVE independent values, each with the
-- same shape: the main window (`opacity`, Settings page) plus one per standalone HUD (`trackerOpacity`,
-- `consumeOpacity`, `rangeOpacity`, `curseOpacity`, each on that HUD's own page). WQ.ReapplyOpacity repaints
-- every registered frame fill, each frame reading its own value.
local OPACITY_MIN, OPACITY_MAX = 0, 100
-- Read `field` off the active profile, clamped, defaulting when absent/pre-login.
local function ReadOpacity(field)
    local p = ActiveProfile()
    local v = p and p[field]
    if type(v) ~= "number" then return WQ.DEFAULT_OPACITY end
    if v < OPACITY_MIN then return OPACITY_MIN end
    if v > OPACITY_MAX then return OPACITY_MAX end
    return v
end
-- Write `field` (rounded + clamped) and repaint. n=nil/non-number is ignored.
local function WriteOpacity(field, n)
    n = tonumber(n); if not n then return end
    n = math.floor(n + 0.5)
    if n < OPACITY_MIN then n = OPACITY_MIN end
    if n > OPACITY_MAX then n = OPACITY_MAX end
    local p = ActiveProfile(); if p then p[field] = n end
    if WQ.ReapplyOpacity then WQ.ReapplyOpacity() end   -- live repaint (defined in the UI file)
end
function WQ.GetOpacity()         return ReadOpacity("opacity")        end
function WQ.SetOpacity(n)        WriteOpacity("opacity", n)           end
function WQ.GetTrackerOpacity()  return ReadOpacity("trackerOpacity") end
function WQ.SetTrackerOpacity(n) WriteOpacity("trackerOpacity", n)    end
function WQ.GetConsumeOpacity()  return ReadOpacity("consumeOpacity") end
function WQ.SetConsumeOpacity(n) WriteOpacity("consumeOpacity", n)    end
function WQ.GetRangeOpacity()    return ReadOpacity("rangeOpacity")   end
function WQ.SetRangeOpacity(n)   WriteOpacity("rangeOpacity", n)      end
function WQ.GetCurseOpacity()    return ReadOpacity("curseOpacity")   end
function WQ.SetCurseOpacity(n)   WriteOpacity("curseOpacity", n)      end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpRange()): the current target's bracket PLUS every rung's
-- result (in/out/— with the item ID that resolved it). Use it to spot a dead rung (all candidates "—",
-- i.e. a gap) so its item IDs can be swapped for working ones during tuning.
function WQ.DebugDumpRange()
    print(("|cff9900ffWarlockQol|r Range — active: %s, items cached: %s"):format(
        RangeActive() and "yes" or "no", rangeAllCached and "yes" or "no"))
    if not UnitExists("target") then print("  (no target)") ; return end

    local name, lo, hi = WQ.GetTargetRange()
    local bracket = (not lo and not hi) and "unknown" or (not hi and (">"..lo) or (lo.."-"..hi))
    print(("  %s → (%s yd)"):format(name or "?", bracket))

    local class = ReactionClass("target")
    local ladder = LadderFor(class)
    local misc = (class == "misc")
    print(("  reaction: %s%s"):format(class, misc and " (NPC — interact distance only, coarse)" or ""))
    if RangeChecksBlocked("target") then
        print("  |cffffcc00item/interact checks skipped (in combat on a non-attackable unit — protected)|r")
        return
    end
    for _, rung in ipairs(ladder) do
        local shown = nil
        for _, id in ipairs(rung[2]) do
            -- misc rungs are CheckInteractDistance indices, not item IDs. Can't fold this into an
            -- and/or chain: a false result would fall through to the item branch.
            local r
            if misc then r = CheckInteractDistance("target", id) else r = ItemInRange(id, "target") end
            if r ~= nil then
                shown = (r and "IN  via " or "OUT via ") .. (misc and ("interact " .. id) or id)
                break
            end
        end
        print(("    %3dyd: %s"):format(rung[1], shown or "— (no candidate resolved)"))
    end
end

-- ── Curse Tracker public API ──────────────────────────────────────────────────
-- The curse table + order are exposed read-only so the UI can build its checkbox list.
WQ.CURSES      = CURSES
WQ.CURSE_ORDER = CURSE_ORDER

function WQ.IsCursesActive() return CursesActive() end

-- Enabled flag (per-profile, default ON since 0.29 took this out of beta). Setter re-syncs the shared
-- combat-log listener and the HUD.
function WQ.IsCursesEnabled() local p = ActiveProfile(); return p and p.cursesEnabled or false end
function WQ.SetCursesEnabled(on)
    local p = ActiveProfile()
    if p then p.cursesEnabled = on and true or false end
    if not (p and p.cursesEnabled) then ClearAllCurses() end   -- turning off drops the store
    UpdateCombatLogRegistration()
    UpdateCursesRegistration()
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end

-- Per-profile "auto-show HUD" flags, matching the Cooldowns/Consumables pair since 0.29: raid on,
-- party (a 5-man dungeon) opt-in.
function WQ.IsCurseShowRaid()  local p = ActiveProfile(); return p and p.curseShowRaid  or false end
function WQ.SetCurseShowRaid(on)
    local p = ActiveProfile(); if p then p.curseShowRaid = on and true or false end
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end
function WQ.IsCurseShowParty() local p = ActiveProfile(); return p and p.curseShowParty or false end
function WQ.SetCurseShowParty(on)
    local p = ActiveProfile(); if p then p.curseShowParty = on and true or false end
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end

-- Per-profile "hide when no curses are active" flag (default OFF since 0.29). Off = the HUD stays put
-- showing a placeholder line, which is also how you find it to drag it somewhere.
function WQ.IsCurseHideInactive() local p = ActiveProfile(); return p and p.curseHideInactive or false end
function WQ.SetCurseHideInactive(on)
    local p = ActiveProfile(); if p then p.curseHideInactive = on and true or false end
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end

-- Per-curse tracking flags (absent = tracked, only an explicit false disables).
function WQ.IsCurseTracked(key) return IsCurseTracked(key) end
function WQ.SetCurseTracked(key, on)
    local p = ActiveProfile(); if not p or not CURSES[key] then return end
    p.trackedCurses = p.trackedCurses or {}
    p.trackedCurses[key] = on and true or false
    -- Untracking can empty the list, so re-run visibility (it rebuilds the rows when still shown).
    if WQ.UpdateCursesHUDVisibility then WQ.UpdateCursesHUDVisibility() end
end

-- Snapshot for the HUD: one entry per live curse, as
--   { key, label, icon, caster, isMine, target, marker, remaining }
-- sorted own-curses-first then soonest-to-drop, capped at CURSE_MAX_ROWS. Expired rows are pruned as
-- we go, so this doubles as the read-side cleanup. Example:
--   for _, c in ipairs(WQ.GetCurseSnapshot()) do print(c.caster, c.target, c.label, c.remaining) end
function WQ.GetCurseSnapshot()
    local now, rows = GetTime(), {}
    for rowKey, e in pairs(curseState) do
        local rem = e.expires - now
        if rem <= 0 then
            curseState[rowKey] = nil
        elseif IsCurseTracked(e.curse) then
            rows[#rows + 1] = {
                key    = e.curse,  label  = CURSES[e.curse].label, icon   = CurseIcon(e.curse),
                caster = e.caster, isMine = e.isMine,              target = e.target,
                marker = e.marker, remaining = rem,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.isMine ~= b.isMine then return a.isMine end          -- own curses pinned to the top
        if a.remaining ~= b.remaining then return a.remaining < b.remaining end
        if a.target ~= b.target then return a.target < b.target end
        return a.key < b.key
    end)
    for i = #rows, CURSE_MAX_ROWS + 1, -1 do rows[i] = nil end
    return rows
end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpCurses()): feature state, the resolved spell names (a nil
-- there means the name lookup failed and nothing will ever match), and every live row.
function WQ.DebugDumpCurses()
    print(("|cff9900ffWarlockQol|r Curses - active: %s, rows: %d"):format(
        CursesActive() and "yes" or "no", #WQ.GetCurseSnapshot()))
    for _, key in ipairs(CURSE_ORDER) do
        print(("  %-12s %-28s tracked=%s"):format(
            key, tostring(GetSpellNameByID(CURSES[key].baseId)), IsCurseTracked(key) and "yes" or "no"))
    end
    for _, c in ipairs(WQ.GetCurseSnapshot()) do
        print(("    %s → %s: %s, %ds left%s%s"):format(
            c.caster, c.target, c.label, math.floor(c.remaining),
            c.marker and (" [mark " .. c.marker .. "]") or "", c.isMine and " (mine)" or ""))
    end
end

-- ── Loss of Control public API (BETA) ─────────────────────────────────────────

function WQ.IsControlActive() return ControlActive() end

-- Enabled flag (per-profile, default OFF: beta). Setter re-syncs the two listeners.
function WQ.IsControlEnabled() local p = ActiveProfile(); return p and p.controlEnabled or false end
function WQ.SetControlEnabled(on)
    local p = ActiveProfile()
    if p then p.controlEnabled = on and true or false end
    UpdateControlRegistration()
end

-- Per-category announce flags, driven by the CONTROL_TYPES table so the config page can build itself
-- from CONTROL_TYPE_ORDER. No event and no HUD, so these setters just persist: SayControl reads them on
-- fire. Absent reads as the category's own default, so a profile written before a category existed
-- behaves as if it had been seeded.
WQ.CONTROL_TYPES      = CONTROL_TYPES
WQ.CONTROL_TYPE_ORDER = CONTROL_TYPE_ORDER

function WQ.IsControlType(key)
    local spec, p = CONTROL_TYPES[key], ActiveProfile()
    if not (spec and p) then return false end
    local v = p[spec.flag]
    if v == nil then return spec.default end
    return v and true or false
end
function WQ.SetControlType(key, on)
    local spec, p = CONTROL_TYPES[key], ActiveProfile()
    if spec and p then p[spec.flag] = on and true or false end
end

-- Named fear/charm accessors kept as thin aliases: they are published API and predate the table.
function WQ.IsControlFear()  return WQ.IsControlType("fear") end
function WQ.SetControlFear(on)  WQ.SetControlType("fear", on) end

function WQ.IsControlCharm() return WQ.IsControlType("charm") end
function WQ.SetControlCharm(on) WQ.SetControlType("charm", on) end

function WQ.IsControlCombatOnly() local p = ActiveProfile(); return p and p.controlCombatOnly or false end
function WQ.SetControlCombatOnly(on) local p = ActiveProfile(); if p then p.controlCombatOnly = on and true or false end end

function WQ.IsControlEcho() local p = ActiveProfile(); return p and p.controlEcho or false end
function WQ.SetControlEcho(on) local p = ActiveProfile(); if p then p.controlEcho = on and true or false end end

-- Opt in to announcing in battlegrounds and arenas. Default OFF, so absent reads as off (unlike the
-- party/raid pair, where absent reads as on).
function WQ.IsControlPvpEnabled() local p = ActiveProfile(); return p and p.controlPvpEnabled or false end
function WQ.SetControlPvpEnabled(on) local p = ActiveProfile(); if p then p.controlPvpEnabled = on and true or false end end

-- Per-context party/raid announce toggles, read by GroupAnnounceChannel("control"). Same contract as
-- the soulstone/banish pairs: default ON, nil/absent counts as on, and the setters just persist (the
-- two PLAYER_CONTROL_* listeners stay keyed off controlEnabled alone).
function WQ.IsControlPartyEnabled()
    local p = ActiveProfile(); return p ~= nil and p.controlPartyEnabled ~= false
end
function WQ.SetControlPartyEnabled(on)
    local p = ActiveProfile(); if p then p.controlPartyEnabled = on and true or false end
end
function WQ.IsControlRaidEnabled()
    local p = ActiveProfile(); return p ~= nil and p.controlRaidEnabled ~= false
end
function WQ.SetControlRaidEnabled(on)
    local p = ActiveProfile(); if p then p.controlRaidEnabled = on and true or false end
end

-- Debug dump (/run Warlock_Qol_Tbc.DebugDumpControl()): feature state, the live unit state the filters
-- read, which of the two detection paths this client can actually use, and any locType it has reported
-- that CONTROL_LOC_TYPES does not map. This is the readout the in-game test is built around: the ONE
-- question it exists to answer is whether LOSS_OF_CONTROL_ADDED ever fires here (locFired below).
function WQ.DebugDumpControl()
    local p = ActiveProfile()
    print(("|cff9900ffWarlockQol|r Loss of Control - active: %s, channel: %s, latched: %s"):format(
        ControlActive() and "yes" or "no",
        ControlChannel() or "none (solo, or that context is off): echo only",
        controlLost and "yes" or "no"))
    -- The channel above hinges on this: SAY is only permitted to an addon inside an instance.
    print(("  inInstance=%s (say is instance-only; outside it falls back to party/raid)"):format(
        IsInInstance() and "yes" or "no"))
    -- A BG/arena is an instance, so without the opt-in this would say through the whole thing.
    if InPvpInstance() then
        print(("  inPvpInstance=YES -> %s"):format(
            (p and p.controlPvpEnabled) and "announcing (PvP opted in)" or "SILENT (PvP announcing is off)"))
    end

    local flags = {}
    for _, key in ipairs(CONTROL_TYPE_ORDER) do
        flags[#flags + 1] = ("%s=%s"):format(key, WQ.IsControlType(key) and "on" or "off")
    end
    print("  announce: " .. table.concat(flags, " "))
    print(("  party=%s raid=%s pvp=%s combatOnly=%s echo=%s"):format(
        tostring(WQ.IsControlPartyEnabled()), tostring(WQ.IsControlRaidEnabled()),
        tostring(WQ.IsControlPvpEnabled()),
        p and tostring(p.controlCombatOnly) or "?", p and tostring(p.controlEcho) or "?"))
    print(("  now: inCombat=%s onTaxi=%s charmed=%s -> fallback would guess %s"):format(
        UnitAffectingCombat("player") and "yes" or "no",
        (UnitOnTaxi and UnitOnTaxi("player")) and "yes" or "no",
        (UnitIsCharmed and UnitIsCharmed("player")) and "yes" or "no",
        ControlKindGuess()))

    -- Which accessor the shim resolved to. "none" with C_LossOfControl=yes means the namespace exists
    -- but carries neither known accessor, and the primary path can never produce data.
    local C = C_LossOfControl
    local accessor = "none"
    if C and C.GetActiveLossOfControlData then accessor = "GetActiveLossOfControlData (retail 9.0+ shape)"
    elseif C and C.GetEventInfo           then accessor = "GetEventInfo (legacy shape)" end
    print(("  API: UnitIsCharmed=%s C_LossOfControl=%s accessor=%s"):format(
        UnitIsCharmed and "yes" or "no", C and "yes" or "no", accessor))
    print(("  primary path: locFired=%s activeEntries=%d  <- locFired=no after a real fear means the"):format(
        controlLocFired and "YES" or "no", LossOfControlCount()))
    print("                event does not fire here, so keep the fallback and drop the primary.")

    for i = 1, LossOfControlCount() do
        local d = LossOfControlData(i)
        if d then
            print(("    [%d] locType=%s -> %s  text=%s dur=%s"):format(
                i, tostring(d.locType), tostring(CONTROL_LOC_TYPES[d.locType] or "UNMAPPED"),
                tostring(d.displayText), tostring(d.duration or d.timeRemaining)))
        end
    end
    for locType in pairs(controlLocSeen) do
        print(("  UNMAPPED locType seen this session: %s (add it to CONTROL_LOC_TYPES)"):format(locType))
    end
end

-- Fire the real announce path from a timer callback, so there is NO hardware event behind the send
-- (/run Warlock_Qol_Tbc.DebugSayControl("fear")). Calling SendChatMessage straight from a /run would be
-- a false pass, because typing the command and pressing Enter IS a hardware event, and that alone is
-- enough to let a SAY through anywhere. WHERE you run this is now part of the test: in the world the
-- say path is blocked by design and you should see nothing, inside an instance it should appear as a
-- bubble. Bypasses the transition latch and the taxi/combat filters, but not the feature's own flags.
-- `cat` is any CONTROL_TYPES key (fear / charm / incap / stun / silence / root), defaulting to fear.
-- The sample effect name and duration are passed so the message reads like a real one from the primary
-- path rather than the bare fallback string.
function WQ.DebugSayControl(cat)
    cat = CONTROL_TYPES[cat] and cat or "fear"
    if not ControlActive() then
        print("|cff9900ffWarlockQol|r Loss of Control is off (feature flag or master switch); nothing sent.")
        return
    end
    if not WQ.IsControlType(cat) then
        print(("|cff9900ffWarlockQol|r %s announcing is switched off on the page; nothing will be sent."):format(cat))
        return
    end
    if not ControlChannel() then
        print("|cff9900ffWarlockQol|r No announce channel: solo out in the world, or party/raid is toggled off. Echo only.")
    end
    -- No fallback to a direct call on a client without C_Timer: that would run inside the /run's own
    -- hardware event and pass when the real thing fails, which is worse than not testing.
    if not (C_Timer and C_Timer.After) then
        print("|cff9900ffWarlockQol|r No C_Timer on this client, so this test cannot be run honestly.")
        return
    end
    print(("|cff9900ffWarlockQol|r Loss of Control: saying the %s line in 1s, from a timer (no hardware event)."):format(cat))
    controlRecent[cat] = nil   -- so a repeated test is not eaten by the throttle
    C_Timer.After(1, function() SayControl(cat, 8) end)
end

-- ── Profile management API ────────────────────────────────────────────────────
-- Called by the Profiles page. Each op refreshes the caches + re-syncs the combat-log listener
-- when the bound profile or its flags may have changed.

-- Name of the profile the current character is bound to.
function WQ.GetActiveProfileName()
    local cs = CharState()
    return cs and cs.profile
end

-- All profile names, sorted.
function WQ.ListProfiles()
    local names = {}
    if Warlock_Qol_Tbc_DB and Warlock_Qol_Tbc_DB.profiles then
        for name in pairs(Warlock_Qol_Tbc_DB.profiles) do names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

-- Bind the current character to an existing profile. Returns true, or false,"unknown".
function WQ.SwitchProfile(name)
    if not (Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[name]) then
        return false, "unknown"
    end
    local cs = CharState()
    if not cs then return false, "unknown" end
    cs.profile    = name
    activeProfile = InitProfile(Warlock_Qol_Tbc_DB.profiles[name])
    EnsureProfileSeeded()
    UpdateCombatLogRegistration()   -- the new profile's announcer flags may differ
    SyncCursesToProfile()
    UpdateControlRegistration()     -- controlEnabled is per-profile too
    if WQ.ReapplyAccent then WQ.ReapplyAccent() end  -- the new profile may pick a different accent colour
    if WQ.ReapplyOpacity then WQ.ReapplyOpacity() end  -- ...and a different backdrop opacity
    return true
end

-- Create a default-seeded profile and switch to it. Rejects empty / existing name.
function WQ.CreateProfile(name)
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then return false, "empty" end
    if Warlock_Qol_Tbc_DB.profiles[name] then return false, "exists" end
    Warlock_Qol_Tbc_DB.profiles[name] = InitProfile({})
    local cs = CharState()
    if cs then cs.profile = name end
    activeProfile = Warlock_Qol_Tbc_DB.profiles[name]
    EnsureProfileSeeded()           -- seed the fresh profile's default lines
    UpdateCombatLogRegistration()
    SyncCursesToProfile()
    UpdateControlRegistration()     -- controlEnabled is per-profile too
    return true
end

-- Deep-copy a source profile INTO the active profile (overwrite). Rejects same/unknown source.
function WQ.CopyProfileInto(sourceName)
    if not (Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[sourceName]) then
        return false, "unknown"
    end
    local cs = CharState()
    if not cs then return false, "unknown" end
    if sourceName == cs.profile then return false, "same" end

    local src = Warlock_Qol_Tbc_DB.profiles[sourceName]
    local dst = ActiveProfile()
    -- Overwrite in place (preserve the table identity so caches stay valid).
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = DeepCopy(v) end
    InitProfile(dst)                -- heal skeleton in case the source was partial
    UpdateCombatLogRegistration()   -- copied announcer flags may differ
    SyncCursesToProfile()
    UpdateControlRegistration()     -- controlEnabled is per-profile too
    return true
end

-- Delete a profile. Can't delete the active one ("active"), the last one ("last"), or unknown.
function WQ.DeleteProfile(name)
    if not (Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[name]) then
        return false, "unknown"
    end
    local cs = CharState()
    if cs and name == cs.profile then return false, "active" end
    local count = 0
    for _ in pairs(Warlock_Qol_Tbc_DB.profiles) do count = count + 1 end
    if count <= 1 then return false, "last" end
    Warlock_Qol_Tbc_DB.profiles[name] = nil
    return true
end

-- Hard Reset (ACCOUNT-WIDE): remove this character's macros, then wipe the ENTIRE DB in place
-- (all profiles + every char's state + window geometry) and rebuild, re-resolving this char to
-- a fresh default profile. Wiped in place so the SavedVariable identity is preserved. Blocked in combat.
function WQ.HardReset()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return false
    end
    local removed = WQ.RemoveSummonMacros() + WQ.RemoveRitualMacro() + WQ.RemoveSoulsMacro()

    -- Discard everything and rebuild from scratch, exactly like a first install.
    if Warlock_Qol_Tbc_DB then
        for k in pairs(Warlock_Qol_Tbc_DB) do Warlock_Qol_Tbc_DB[k] = nil end
    else
        Warlock_Qol_Tbc_DB = {}
    end
    activeProfile, charState = nil, nil          -- drop caches pointing into the old DB
    InitDB()                                     -- rebuild the empty profiles/chars skeleton
    ResolveActiveBinding()                       -- recreate this char's default-seeded profile + binding

    UpdateCombatLogRegistration()                -- listener state reset with the fresh (all-ON) flags
    SyncCursesToProfile()                        -- ...and the curse tracker back to its default (off)
    UpdateControlRegistration()                  -- ...and the Loss of Control announcer (also off)
    if WQ.ReapplyAccent then WQ.ReapplyAccent() end  -- back to the default accent colour
    if WQ.ReapplyOpacity then WQ.ReapplyOpacity() end  -- back to the default backdrop opacity
    print(("|cff9900ffWarlockQol|r: reset EVERYTHING to defaults (all profiles and settings) and removed %d macro(s)."):format(removed))
    return true
end

-- ── Profile export / import (share strings) ───────────────────────────────────
-- A profile is a self-contained config table, shareable as a copy-paste string.
-- Wire format:  WQT1!<base64( <8-hex-checksum><serialized> )>
--   * WQT1     = format version (rejected if it ever changes).
--   * checksum = catches a truncated/mangled paste before we build a profile from garbage.
--   * serialized = our own length-prefixed encoding, NOT a Lua chunk — the parser only produces
--     DATA, never executes code (no loadstring). Base64/serializer/parser are hand-rolled (dep-free).

-- Base64 (standard alphabet). Operates on an arbitrary byte string.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}
for i = 1, #B64 do B64DEC[B64:sub(i, i)] = i - 1 end

local function Base64Encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local c1 = data:byte(i)
        local c2 = data:byte(i + 1)
        local c3 = data:byte(i + 2)
        local n = c1 * 65536 + (c2 or 0) * 256 + (c3 or 0)
        local e1 = math.floor(n / 262144) % 64
        local e2 = math.floor(n / 4096) % 64
        local e3 = math.floor(n / 64) % 64
        local e4 = n % 64
        out[#out + 1] = B64:sub(e1 + 1, e1 + 1)
        out[#out + 1] = B64:sub(e2 + 1, e2 + 1)
        out[#out + 1] = c2 and B64:sub(e3 + 1, e3 + 1) or "="
        out[#out + 1] = c3 and B64:sub(e4 + 1, e4 + 1) or "="
    end
    return table.concat(out)
end

local function Base64Decode(str)
    local out = {}
    local buf, bits = 0, 0
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "=" then break end
        local v = B64DEC[ch]
        if not v then return nil end          -- invalid character → not a valid string
        buf = buf * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local p = 2 ^ bits
            out[#out + 1] = string.char(math.floor(buf / p) % 256)
            buf = buf % p                      -- drop consumed high bits so buf stays small
        end
    end
    return table.concat(out)
end

-- djb2-style rolling checksum, 8 hex chars. Kept under 2^53 so double math stays exact.
local function Checksum(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

-- Array if its only keys are 1..#t, else a string-keyed map (our schema never mixes them).
local function IsArrayTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

-- Serialize a value into `out` (a string-piece array). Length-prefixed so no escaping is
-- needed: b1/b0 (bool), s<len>:<bytes> (string), n<len>:<digits> (number),
-- l<count>:<values> (array), m<count>:<key,value pairs> (map, keys sorted for determinism).
local function SerializeValue(v, out)
    local tv = type(v)
    if tv == "boolean" then
        out[#out + 1] = v and "b1" or "b0"
    elseif tv == "number" then
        local s = tostring(v)
        out[#out + 1] = "n" .. #s .. ":" .. s
    elseif tv == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif tv == "table" then
        if IsArrayTable(v) then
            out[#out + 1] = "l" .. #v .. ":"
            for i = 1, #v do SerializeValue(v[i], out) end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "m" .. #keys .. ":"
            for _, k in ipairs(keys) do
                out[#out + 1] = "s" .. #k .. ":" .. k
                SerializeValue(v[k], out)
            end
        end
    else
        out[#out + 1] = "l0:"   -- nil/function/etc → empty array (shouldn't occur in our schema)
    end
end

local MAX_PARSE_DEPTH = 12   -- our real data is ~4 deep; caps a crafted string's recursion

-- Parse one value at `pos`. Returns nextPos, value; or nil, "corrupt". Success = nextPos
-- non-nil (value may be false). Only constructs data, never executes.
local function ParseValue(s, pos, depth)
    if depth > MAX_PARSE_DEPTH then return nil, "corrupt" end
    local tag = s:sub(pos, pos)
    if tag == "b" then
        return pos + 2, (s:sub(pos + 1, pos + 1) == "1")
    elseif tag == "s" or tag == "n" then
        local colon = s:find(":", pos + 1, true)
        if not colon then return nil, "corrupt" end
        local len = tonumber(s:sub(pos + 1, colon - 1))
        if not len or len < 0 then return nil, "corrupt" end
        local startB = colon + 1
        local val = s:sub(startB, startB + len - 1)
        if #val ~= len then return nil, "corrupt" end
        if tag == "n" then
            val = tonumber(val)
            if val == nil then return nil, "corrupt" end
        end
        return startB + len, val
    elseif tag == "l" then
        local colon = s:find(":", pos + 1, true)
        if not colon then return nil, "corrupt" end
        local count = tonumber(s:sub(pos + 1, colon - 1))
        if not count or count < 0 then return nil, "corrupt" end
        local t, p = {}, colon + 1
        for i = 1, count do
            local np, v = ParseValue(s, p, depth + 1)
            if not np then return nil, "corrupt" end
            t[i], p = v, np
        end
        return p, t
    elseif tag == "m" then
        local colon = s:find(":", pos + 1, true)
        if not colon then return nil, "corrupt" end
        local count = tonumber(s:sub(pos + 1, colon - 1))
        if not count or count < 0 then return nil, "corrupt" end
        local t, p = {}, colon + 1
        for i = 1, count do
            local kp, k = ParseValue(s, p, depth + 1)
            if not kp or type(k) ~= "string" then return nil, "corrupt" end
            local vp, v = ParseValue(s, kp, depth + 1)
            if not vp then return nil, "corrupt" end
            t[k], p = v, vp
        end
        return p, t
    end
    return nil, "corrupt"
end

-- Rebuild a clean profile from a foreign table, keeping ONLY known shareable fields with the
-- right types (drops junk/wrong-typed keys and non-string lines). Used on export AND import.
local IMPORT_POOL_FIELDS = { "ritualLines", "soulsLines", "soulstoneLines", "banishLines", "banishResistLines" }
local IMPORT_FLAG_FIELDS = { "petEnabled", "ritualEnabled", "soulsEnabled", "soulstoneEnabled", "soulstonePartyEnabled", "soulstoneRaidEnabled", "soulstonePvpEnabled", "banishEnabled", "banishPartyEnabled", "banishRaidEnabled", "banishPvpEnabled", "trackerEnabled", "trackerShowRaid", "trackerShowParty", "soulstoneActiveEnabled", "consumablesEnabled", "consumeShowRaid", "consumeShowParty", "consumeGlow", "consumeTransparent", "rangeEnabled", "rangeTransparent", "rangeHideNoTarget", "cursesEnabled", "curseShowRaid", "curseShowParty", "curseHideInactive", "controlEnabled", "controlFear", "controlCharm", "controlIncap", "controlStun", "controlSilence", "controlRoot", "controlPartyEnabled", "controlRaidEnabled", "controlCombatOnly", "controlEcho", "controlPvpEnabled" }
local IMPORT_SEED_FIELDS = { "ritualSeeded", "soulsSeeded", "soulstoneSeeded", "banishSeeded" }

local function StringArray(src)
    local arr = {}
    if type(src) == "table" then
        for _, line in ipairs(src) do
            if type(line) == "string" then arr[#arr + 1] = line end
        end
    end
    return arr
end

local function SanitizeProfile(raw)
    local p = {}
    if type(raw) ~= "table" then raw = {} end
    -- per-family summon lines
    if type(raw.lines) == "table" then
        p.lines = {}
        for _, fam in ipairs(WQ.PET_FAMILIES) do
            if type(raw.lines[fam]) == "table" then p.lines[fam] = StringArray(raw.lines[fam]) end
        end
    end
    -- flat string-array pools
    for _, key in ipairs(IMPORT_POOL_FIELDS) do
        if type(raw[key]) == "table" then p[key] = StringArray(raw[key]) end
    end
    -- boolean flags (only when explicitly boolean; InitProfile defaults the rest)
    for _, key in ipairs(IMPORT_FLAG_FIELDS) do
        if type(raw[key]) == "boolean" then p[key] = raw[key] end
    end
    for _, key in ipairs(IMPORT_SEED_FIELDS) do
        if type(raw[key]) == "boolean" then p[key] = raw[key] end
    end
    -- Per-cooldown flags: only TRACKED_ORDER keys, only explicit false (so a foreign string
    -- can't inject arbitrary keys).
    if type(raw.trackedCds) == "table" then
        local t
        for _, cdKey in ipairs(TRACKED_ORDER) do
            if raw.trackedCds[cdKey] == false then
                t = t or {}
                t[cdKey] = false
            end
        end
        if t then p.trackedCds = t end
    end
    -- per-consumable tracking flags — whitelisted to CONSUMABLE_ORDER. Both booleans travel (unlike
    -- trackedCds) because some consumables default OFF (elixirs), so an explicit `true` is meaningful.
    if type(raw.trackedConsumes) == "table" then
        local t
        for _, key in ipairs(CONSUMABLE_ORDER) do
            if type(raw.trackedConsumes[key]) == "boolean" then
                t = t or {}
                t[key] = raw.trackedConsumes[key]
            end
        end
        if t then p.trackedConsumes = t end
    end
    -- Per-curse tracking flags: whitelisted to CURSE_ORDER, only an explicit false (absent = tracked,
    -- as with trackedCds), so a foreign string can't inject arbitrary keys.
    if type(raw.trackedCurses) == "table" then
        local t
        for _, key in ipairs(CURSE_ORDER) do
            if raw.trackedCurses[key] == false then
                t = t or {}
                t[key] = false
            end
        end
        if t then p.trackedCurses = t end
    end
    -- consumable expiry threshold (seconds) — only a sane number travels; InitProfile defaults it.
    if type(raw.consumeThreshold) == "number" and raw.consumeThreshold >= 5 and raw.consumeThreshold <= 3600 then
        p.consumeThreshold = math.floor(raw.consumeThreshold)
    end
    -- range HUD text size (points) — only a sane number travels; InitProfile defaults it.
    if type(raw.rangeFontSize) == "number" and raw.rangeFontSize >= 8 and raw.rangeFontSize <= 40 then
        p.rangeFontSize = math.floor(raw.rangeFontSize)
    end
    -- Accent colour (Settings) — only a well-formed 6-hex string travels; InitProfile defaults it.
    if type(raw.accent) == "string" and raw.accent:match("^%x%x%x%x%x%x$") then p.accent = raw.accent:lower() end
    -- Backdrop opacity (main window + the three HUDs) — only a sane percent travels each; InitProfile
    -- defaults them.
    for _, field in ipairs({ "opacity", "trackerOpacity", "consumeOpacity", "rangeOpacity", "curseOpacity" }) do
        local v = raw[field]
        if type(v) == "number" and v >= 0 and v <= 100 then p[field] = math.floor(v) end
    end
    return p
end

-- Decode + validate an export string into its transport table { name=<string>, profile=<table> }.
-- Returns true, tbl on success; false, reason on failure ("empty"/"badformat"/"badversion"/"corrupt").
local function DecodeExport(str)
    str = (str or ""):gsub("%s", "")            -- tolerate wrapped/space-padded pastes
    if str == "" then return false, "empty" end
    local ver, b64 = str:match("^(WQT%d+)!(.+)$")
    if not ver then return false, "badformat" end
    if ver ~= "WQT1" then return false, "badversion" end
    local payload = Base64Decode(b64)
    if not payload or #payload < 8 then return false, "corrupt" end
    local sum, body = payload:sub(1, 8), payload:sub(9)
    if Checksum(body) ~= sum then return false, "corrupt" end
    local np, tbl = ParseValue(body, 1, 1)
    if not np or type(tbl) ~= "table" then return false, "corrupt" end
    return true, tbl
end

-- Export the named profile as a shareable string (nil if it doesn't exist).
function WQ.ExportProfile(name)
    local prof = Warlock_Qol_Tbc_DB and Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[name]
    if not prof then return nil end
    local out = {}
    SerializeValue({ name = name, profile = SanitizeProfile(prof) }, out)
    local body = table.concat(out)
    return "WQT1!" .. Base64Encode(Checksum(body) .. body)
end

-- Peek the source name embedded in an export string (for name prefill), or nil.
function WQ.PeekImportName(str)
    local ok, tbl = DecodeExport(str)
    if not ok then return nil end
    return type(tbl.name) == "string" and tbl.name or nil
end

-- Import an export string as a NEW profile `newName` (never overwrites, never switches).
-- Returns true, or false + "empty"/"badformat"/"badversion"/"corrupt"/"exists".
function WQ.ImportProfile(str, newName)
    local ok, tbl = DecodeExport(str)
    if not ok then return false, tbl end        -- tbl is the reason string here
    newName = newName and newName:match("^%s*(.-)%s*$") or ""
    if newName == "" then return false, "empty" end
    if not (Warlock_Qol_Tbc_DB and Warlock_Qol_Tbc_DB.profiles) then return false, "corrupt" end
    if Warlock_Qol_Tbc_DB.profiles[newName] then return false, "exists" end
    local rawProfile = type(tbl.profile) == "table" and tbl.profile or tbl
    Warlock_Qol_Tbc_DB.profiles[newName] = InitProfile(SanitizeProfile(rawProfile))
    return true
end

-- ── Slash command ─────────────────────────────────────────────────────────────
SLASH_WARLOCK_QOL_TBC1 = "/wq"
SlashCmdList["WARLOCK_QOL_TBC"] = function(msg)
    -- Toggle the window (always reopen on the home page).
    if Warlock_Qol_Tbc_Frame and Warlock_Qol_Tbc_Frame:IsShown() then
        Warlock_Qol_Tbc_Frame:Hide()
    elseif WQ.OpenHome then
        WQ.OpenHome()
    end
end
