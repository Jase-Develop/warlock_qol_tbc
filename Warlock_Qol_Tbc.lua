-- Warlock_Qol_Tbc.lua — Core logic: event handling, data management, say logic
--
-- WoW addons are event-driven. We register a frame to listen for game events
-- (spell casts, pet changes, etc.) and respond to them in an OnEvent handler.

-- Global table for this addon. Other files (like the UI) access shared
-- functions through this table rather than using globals directly.
Warlock_Qol_Tbc = {}
local WQ = Warlock_Qol_Tbc  -- local alias to keep code short

-- Maps each pet family to its summon spell ID. Spell IDs are stable across
-- locales, so we key off them (not localised names) for macro creation.
local SUMMON_SPELL_IDS = {
    Imp        = 688,
    Voidwalker = 697,
    Succubus   = 712,
    Incubus    = 713,
    Felhunter  = 691,
    Felguard   = 30146,
}

-- Ritual of Summoning — used to summon another player. Single spell, so it gets
-- its own constant rather than a family table.
local RITUAL_SPELL_ID = 698

-- Default ritual line shipped to new users and re-added by the Ritual page's Reset.
-- Kept as a named constant so first-run seeding and the Reset re-seed share one source
-- of truth. {star} is a raid-marker token that renders as the yellow star icon in chat.
local DEFAULT_RITUAL_LINE = "Summoning {star} {targetName} {star} to {location}. Click!"

-- Ritual of Souls — creates a Soul Well the group clicks for Healthstones. Like Ritual
-- of Summoning it's a single spell keyed by a stable ID (Rank 1; the spell name is shared
-- across ranks, so casting by name and the cast guard work for whatever rank is known).
-- Its line is just said in /say (no placeholders, no group requirement).
local RITUAL_OF_SOULS_SPELL_ID = 29893
local DEFAULT_SOULS_LINE = "Healthstones up — grab one! {square}"

-- Banish announcer defaults: one pool for a successful banish (aura landed) and one for a
-- resisted banish. Both seeded once (see InitDB) and editable on the Banish page.
local DEFAULT_BANISH_LINE        = "{targetName} has been banished!"
local DEFAULT_BANISH_RESIST_LINE = "{targetName} banish resisted"

-- The Soulstone announcer watches the combat log for the soulstone being CAST (by ANY
-- warlock, so the whole group gets visibility) — see the handler for why we key off the
-- cast, not the buff aura. Matched by name to stay rank-agnostic; this is the enUS spell
-- name (same as the user's WeakAura) — localise here if other client locales are needed.
local SOULSTONE_SPELL_NAME = "Soulstone Resurrection"
local SOULSTONE_THROTTLE   = 3   -- seconds; block a rapid duplicate announce for the same target
local DEFAULT_SOULSTONE_LINE = "A {circle} soulstone {circle} has been cast on {targetName}"

-- A combat-log unit counts as "in my group" if its affiliation flags include mine,
-- party or raid. We use this to ignore soulstones cast among strangers nearby — a
-- random warlock stoning a stranger shouldn't trigger our announcement. (`or 0x..`
-- fallbacks guard against the Blizzard constants not being set this early in load.)
local AFFILIATION_GROUP = bit.bor(
    COMBATLOG_OBJECT_AFFILIATION_MINE  or 0x1,
    COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2,
    COMBATLOG_OBJECT_AFFILIATION_RAID  or 0x4)
local function InMyGroup(unitFlags)
    return unitFlags ~= nil and bit.band(unitFlags, AFFILIATION_GROUP) ~= 0
end

-- A combat-log unit is "mine" if its affiliation includes the MINE flag (the player). The
-- Banish announcer uses this to fire only on the player's OWN banishes, unlike the
-- soulstone announcer which fires on any group member's cast.
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

-- Banish announcer: watches the combat log for MY OWN Banish landing (SPELL_AURA_APPLIED)
-- or resisting (SPELL_MISSED / "RESIST"). Detection is by spell NAME (rank-agnostic, so it
-- matches either rank); the rank itself is read from the cast's spell ID. The name is
-- derived from a spell ID rather than hardcoded in English (see CLAUDE.md) and memoised.
local BANISH_THROTTLE   = 3                       -- seconds; block a dup announce per target+kind
local BANISH_RANK_BY_ID = { [710] = 1, [18647] = 2 }  -- Banish Rank 1 / Rank 2 spell IDs

local banishName
local function BanishName()
    if not banishName then banishName = GetSpellNameByID(710) end
    return banishName
end

-- " (Rank N)" suffix for a cast's spell ID, always appended to a banish announcement.
-- Uses the known ID→rank map, falling back to parsing the localised rank subtext; returns
-- "" when the rank can't be determined (so nothing odd is appended).
local function BanishRankSuffix(spellID)
    local n = BANISH_RANK_BY_ID[spellID]
    if not n and GetSpellSubtext then
        local sub = GetSpellSubtext(spellID)       -- e.g. "Rank 2"
        n = sub and tonumber(sub:match("%d+"))
    end
    if n then return " (Rank " .. n .. ")" end
    return ""
end

-- Ordered list of families — used by the UI to build tabs in a consistent order.
WQ.PET_FAMILIES = { "Imp", "Voidwalker", "Succubus", "Incubus", "Felhunter", "Felguard" }

-- ── Saved Variables / DB ──────────────────────────────────────────────────────
--
-- Warlock_Qol_Tbc_DB is declared as a SavedVariable in the .toc file (account-wide on
-- disk). WoW loads it before ADDON_LOADED fires and saves it on logout. If it
-- doesn't exist yet (first install) it is nil — InitDB creates the skeleton.
--
-- Layout (ElvUI-style named profiles):
--
--   Warlock_Qol_Tbc_DB = {
--     profiles = {                     -- SHAREABLE config, keyed by profile name
--       ["<name>"] = {
--         lines, ritualLines, soulsLines, soulstoneLines,
--         banishLines, banishResistLines,          -- the six line pools
--         petEnabled, ritualEnabled, soulsEnabled,
--         soulstoneEnabled, banishEnabled, trackerEnabled,  -- the six feature flags
--         ritualSeeded, soulsSeeded, soulstoneSeeded, banishSeeded, -- the seed-once flags
--       },
--     },
--     chars = {                        -- PER-CHARACTER, never shared
--       ["<Name-Realm>"] = {
--         profile       = "<name>",    -- which profile this character is bound to
--         masterEnabled = true,        -- per-char master override
--         setupComplete = false,       -- per-char first-run flag
--         petNames      = {},          -- per-char runtime pet-name cache
--         ownCds        = {},          -- per-char: cdKey -> wall-clock time() expiry of MY
--                                      --   own tracked cooldown (so the HUD self-row survives
--                                      --   a /reload or relog; see RestoreOwnCooldowns)
--       },
--     },
--     ui = { ... },                    -- GLOBAL window geometry (top level, unchanged)
--   }
--
-- The account-wide SavedVariable is intentional: keeping profiles in one shared
-- table is what lets a player copy config across characters. Only the `chars`
-- entries are per-character (each binds to a profile); `ui` stays global.

-- ── Profile / character resolution ────────────────────────────────────────────
--
-- The active profile and this character's state are cached in module locals and
-- (re)resolved lazily. They MUST NOT be resolved at ADDON_LOADED — UnitName/
-- GetRealmName aren't reliable until PLAYER_LOGIN — so we resolve on PLAYER_LOGIN
-- (and again on any profile switch). Every config read goes through ActiveProfile()
-- and every per-character read through CharState().
local activeProfile          -- cached profiles[<bound name>] table for this character
local charState              -- cached chars[<Name-Realm>] table for this character

-- Forward declarations so the mutually-referencing helpers below share upvalues.
local ActiveProfile, CharState, ResolveActiveBinding, EnsureProfileSeeded

-- Stable per-character key. Only reliable at/after PLAYER_LOGIN; returns nil earlier
-- (callers treat nil as "can't resolve yet" and skip caching).
local function CharKey()
    local name = UnitName("player")
    if not name or name == "" then return nil end
    return name .. "-" .. (GetRealmName() or "")
end

-- Recursive deep copy so copied profiles never share table references with the source.
local function DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = DeepCopy(val) end
    return out
end

-- Make sure a profile table has every config field (idempotent). Used when creating a
-- profile, and defensively whenever a profile is bound, so old/partial profiles heal.
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
    if p.trackerEnabled   == nil then p.trackerEnabled   = true end
    -- HUD auto-show in a raid (per-profile; raid-only feature — there is no party mode).
    -- `trackedCds` maps a cooldown key -> false to stop tracking it; an absent key = tracked.
    if p.trackerShowRaid  == nil then p.trackerShowRaid  = true  end
    if not p.trackedCds   then p.trackedCds = {} end
    -- Missing Consumables (per-profile). consumablesEnabled = master feature flag;
    -- consumeShowRaid = auto-show the HUD when in a raid; consumeThreshold = the "about to
    -- expire" warning window in seconds (default 120 = 2 min); trackedConsumes maps a
    -- consumable key -> false to stop tracking it (an absent key = tracked).
    if p.consumablesEnabled == nil then p.consumablesEnabled = true end
    if p.consumeShowRaid    == nil then p.consumeShowRaid    = true end
    if p.consumeGlow        == nil then p.consumeGlow        = true end   -- glow the missing icons
    if p.consumeThreshold   == nil then p.consumeThreshold   = 120  end
    if not p.trackedConsumes then p.trackedConsumes = {} end
    -- Ensure every pet family has a lines table, even if empty.
    for _, family in ipairs(WQ.PET_FAMILIES) do
        if not p.lines[family] then p.lines[family] = {} end
    end
    return p
end

-- Add the default ritual line if it isn't already present (so repeated calls
-- don't pile up copies). Returns true if it was added. Used both for the one-time
-- per-profile seed and the on-demand Ritual Reset. Operates on the ACTIVE profile.
local function SeedRitualDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.ritualLines) do
        if line == DEFAULT_RITUAL_LINE then return false end
    end
    table.insert(p.ritualLines, DEFAULT_RITUAL_LINE)
    return true
end

-- Same idea for the Ritual of Souls default line (seed once / Reset re-seed).
local function SeedSoulsDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.soulsLines) do
        if line == DEFAULT_SOULS_LINE then return false end
    end
    table.insert(p.soulsLines, DEFAULT_SOULS_LINE)
    return true
end

-- Same idea for the Soulstone announcer's default line. The soulstone page has no macro/Reset,
-- so this is seed-once only, but kept dedup-safe like the others for consistency.
local function SeedSoulstoneDefaultLine()
    local p = ActiveProfile()
    if not p then return false end
    for _, line in ipairs(p.soulstoneLines) do
        if line == DEFAULT_SOULSTONE_LINE then return false end
    end
    table.insert(p.soulstoneLines, DEFAULT_SOULSTONE_LINE)
    return true
end

-- Seed the Banish announcer's two default lines (success + resist) once. Dedup-safe per
-- pool so a re-call never piles up copies, mirroring the ritual/souls seeds.
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

-- Seed a profile's default lines exactly once each (mirrors old first-run seeding, now
-- per profile). Gated on per-profile *Seeded flags so a line is never re-added after the
-- user edits or deletes it. Operates on the active profile.
EnsureProfileSeeded = function()
    local p = ActiveProfile()
    if not p then return end
    if not p.ritualSeeded then SeedRitualDefaultLine();  p.ritualSeeded = true end
    if not p.soulsSeeded  then SeedSoulsDefaultLine();   p.soulsSeeded  = true end
    if not p.soulstoneSeeded then SeedSoulstoneDefaultLine(); p.soulstoneSeeded = true end
    if not p.banishSeeded then SeedBanishDefaultLines(); p.banishSeeded = true end
end

-- Resolve (and cache) this character's binding: which profile it uses (activeProfile)
-- and its per-character state (charState). Safe to call repeatedly; it re-derives both
-- caches from the DB. No-op before PLAYER_LOGIN (CharKey is nil that early).
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

    -- Make sure the bound profile still exists (e.g. it may have been deleted while a
    -- different character was using it); fall back to any existing profile or a fresh one.
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

-- Accessors used throughout the file. Both lazily resolve the binding if a caller
-- reaches them before PLAYER_LOGIN, and return nil if that's still too early — callers
-- guard for nil (features simply stay silent until the binding is resolved).
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

-- Public read accessors for the UI: the active profile's config (line pools + flags) and
-- this character's per-char state (petNames/setupComplete/etc). Both are nil-safe — they
-- return nil if called before the PLAYER_LOGIN binding is resolved (the UI guards for it).
WQ.ActiveProfile = ActiveProfile
WQ.CharState     = CharState

-- Runs at ADDON_LOADED: ensure the DB skeleton exists. Deliberately does NOT resolve the
-- active profile — that waits for PLAYER_LOGIN, where CharKey() is reliable (see
-- ResolveActiveBinding).
local function InitDB()
    if not Warlock_Qol_Tbc_DB then Warlock_Qol_Tbc_DB = {} end
    Warlock_Qol_Tbc_DB.profiles = Warlock_Qol_Tbc_DB.profiles or {}
    Warlock_Qol_Tbc_DB.chars    = Warlock_Qol_Tbc_DB.chars or {}
    -- Warlock_Qol_Tbc_DB.ui is created/managed by the UI layer; left as-is here.
end

-- ── Public data helpers ───────────────────────────────────────────────────────
-- These are called by the UI file to modify saved data.

function WQ.AddLine(family, text)
    -- Trim leading/trailing whitespace before saving
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    table.insert(ActiveProfile().lines[family], text)
    return true
end

function WQ.DeleteLine(family, index)
    -- table.remove shifts remaining entries down automatically
    table.remove(ActiveProfile().lines[family], index)
end

-- Replace the line at `index` with new text (edit-in-place). Mirrors AddLine's
-- trim/empty-reject; returns false (leaving the line untouched) on empty text or a
-- bad index, so a stray edit can't blank out or misplace a line.
function WQ.UpdateLine(family, index, text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return false end
    local lines = ActiveProfile().lines[family]
    if not lines or not lines[index] then return false end
    lines[index] = text
    return true
end

-- Ritual lines are a single flat list (no per-family split, since there's only
-- one Ritual of Summoning), so they get their own add/delete helpers.
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

-- A feature fires only when the master switch is ON *and* that feature's own flag is ON.
-- The master switch (CharState().masterEnabled, per-character) is a quick "disable everything" override
-- that never mutates the per-feature flags, so turning it back on restores each feature to
-- its own setting. `flagKey` is the feature's DB field, e.g. "petEnabled".
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

    -- Pick a random line from the pool for this demon
    local line = lines[math.random(#lines)]

    -- {demonName} is the documented placeholder going forward (the warlock's pets are
    -- demons). {petName} is kept as a working back-compat alias because existing players
    -- have saved lines that still use it — both substitute to the same value.
    -- The pet-name cache is PER-CHARACTER (CharState), populated on UNIT_PET. Until the
    -- demon has been summoned once this session we don't know its given name, so we fall
    -- back to the demon's FAMILY (e.g. "Succubus") rather than stripping the placeholder —
    -- reads better than a gap, and only applies to that first pre-detection summon.
    local demonName = (CharState() and CharState().petNames[family]) or family
    line = line:gsub("{demonName}", demonName)
    line = line:gsub("{petName}", demonName)

    if line ~= "" then
        -- SendChatMessage(text, channel) — sends a chat message on your behalf.
        -- "SAY" is the /say channel, visible to nearby players.
        SendChatMessage(line, "SAY")
    end
end

-- Ritual of Summoning is a group activity (the Warlock plus two others are needed
-- to complete the summon), so its line goes to group chat for visibility: RAID when
-- in a raid, PARTY when in a party. If somehow ungrouped we fall back to SAY so the
-- line is never silently dropped.
local function GroupChatChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return "SAY"
end

-- Where the Warlock is standing — used for the {location} placeholder so the group
-- knows where to walk for the summon. Prefer the more precise subzone (e.g. an inn or
-- flight point name) and fall back to the broader zone. Both are standard globals.
local function GetLocationText()
    local sub = GetSubZoneText()
    if sub and sub ~= "" then return sub end
    return GetZoneText() or ""
end

-- Ritual of Summoning equivalent of SayLine. Picks a random ritual line and
-- substitutes the {targetName} and {location} placeholders. Each is stripped (along
-- with a trailing comma/space) if its value is unavailable, mirroring the pet-name
-- handling, so the sentence still reads naturally.
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

-- Soulstone announce. Unlike the others this is fired automatically from the combat
-- log (see the COMBAT_LOG_EVENT_UNFILTERED handler), with `targetName` = whoever
-- received the stone. Group-only by design (an announcement to /say while solo is
-- pointless), and throttled per-target so a duplicated cast event can't double-announce
-- within a few seconds.
local soulstoneRecent = {}   -- targetName -> GetTime() of the last announce
local function SaySoulstone(targetName)
    if not FeatureOn("soulstoneEnabled") then return end
    if not IsInGroup() then return end            -- group-only; stay silent when solo
    local p = ActiveProfile()
    if not p then return end
    local lines = p.soulstoneLines
    if not lines or #lines == 0 then return end

    -- Combat-log names can carry a "-Realm" suffix for cross-realm players; drop it.
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
        SendChatMessage(line, GroupChatChannel())
    end
end

-- Banish announce. Fired automatically from the combat log (see the handler) for the
-- player's OWN banishes. `resisted` picks the success vs. resist line pool; `rankSuffix`
-- (" (Rank N)") is appended to the end of whichever line is chosen. Group-only and
-- throttled per target+kind, mirroring the soulstone announcer.
local banishRecent = {}   -- "<kind>:<targetName>" -> GetTime() of the last announce
local function SayBanish(targetName, rankSuffix, resisted)
    if not FeatureOn("banishEnabled") then return end
    if not IsInGroup() then return end            -- group-only; stay silent when solo
    local p = ActiveProfile()
    if not p then return end
    local lines = resisted and p.banishResistLines or p.banishLines
    if not lines or #lines == 0 then return end

    -- Combat-log names can carry a "-Realm" suffix for cross-realm players; drop it.
    targetName = targetName and targetName:gsub("%-.*", "")
    if not targetName or targetName == "" then return end

    -- Throttle per target AND kind, so a resist immediately followed by a successful
    -- re-banish (or a combat-log aura re-fire on range change) doesn't double-announce.
    local now = GetTime()
    local key = (resisted and "r:" or "b:") .. targetName
    local last = banishRecent[key]
    if last and (now - last) < BANISH_THROTTLE then return end
    banishRecent[key] = now

    local line = lines[math.random(#lines)]
    line = line:gsub("{targetName}", targetName)
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then
        SendChatMessage(line .. (rankSuffix or ""), GroupChatChannel())
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

-- ── Public say + macro helpers ──────────────────────────────────────────────────

-- Macros we create are tagged two ways so we can recognise our own later: a
-- recognisable name prefix AND this signature inside the body. We only ever
-- edit/delete a macro that matches BOTH, so we never touch a user's own macro.
local MACRO_PREFIX    = "WQoL "                  -- e.g. "WQoL Succubus" (fits the 16-char name limit)
-- Common to every macro body we generate ("Warlock_Qol_Tbc.SaySummonLine" and
-- "Warlock_Qol_Tbc.SayRitualLine" both contain it), so one check recognises all ours.
local MACRO_SIGNATURE = "Warlock_Qol_Tbc.Say"

-- Public entry point used by the summon macros. Blizzard blocks addons from
-- sending to /say automatically, so the line must run from a hardware event —
-- i.e. the macro the player clicks. If 'family' is omitted we fall back to the
-- currently active pet's family.
function WQ.SaySummonLine(family)
    if not FeatureOn("petEnabled") then return end   -- feature (or master) off; macro still cast the pet
    family = family or (UnitExists("pet") and UnitCreatureFamily("pet")) or nil
    if not family then return end
    SayLine(family)
end

-- Public entry point used by the ritual macro. No cast-timing guard: Ritual of Summoning
-- is a CHANNELLED ritual (it was changed from instant to channelled long ago), and a
-- channel's state isn't reliably readable in the macro's same-frame /run — the old
-- UnitCastingInfo guard never passed, so the line never fired (same issue as Ritual of
-- Souls). Summoning requires a targeted group member, so we guard on having a player
-- target instead: it's synchronous, reliable, and keeps {targetName} meaningful.
function WQ.SayRitualLine()
    if not FeatureOn("ritualEnabled") then return end   -- feature (or master) off; macro still cast the ritual
    if not (UnitExists("target") and UnitIsPlayer("target")) then return end
    SayRitual()
end

-- Entry point for the Ritual of Souls macro. Unlike the targeted Ritual of Summoning,
-- there's NO cast guard here — Ritual of Souls is a channelled ritual whose channel state
-- isn't reliably readable in the same frame as the macro's /run, so a UnitCastingInfo/
-- UnitChannelInfo guard suppressed the line entirely. It has no target and no cooldown,
-- so we just say the line when the macro fires (same as the pet-summon lines).
function WQ.SaySoulsLine()
    if not FeatureOn("soulsEnabled") then return end   -- feature (or master) off; macro still cast the ritual
    SaySouls()
end

-- True only if the macro at this index was created by us (a name match alone is
-- not enough — a user could have their own macro with the same name).
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

-- Create or update one of OUR macros (recognised by signature). Same-named
-- macros that are NOT ours are left untouched. Returns one of: "created",
-- "updated", "conflict" (name taken by someone else's macro), or "nospace".
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

-- Delete a macro only if it's one of ours (verified by signature). Returns true
-- if it was removed. Looked up by name, so shifting indices between calls is fine.
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

-- Create/refresh a summon macro for every pet the character can currently
-- summon. Returns created, updated, conflicts (a list of names).
function WQ.CreateSummonMacros()
    if InCombatLockdown() then
        print("|cff9900ffWarlockQol|r: can't change macros in combat — try again afterwards.")
        return 0, 0, {}
    end

    local counts = { created = 0, updated = 0, conflicts = {} }
    for _, family in ipairs(WQ.PET_FAMILIES) do
        local spellID   = SUMMON_SPELL_IDS[family]
        local spellName = spellID and GetSpellNameByID(spellID)

        -- Build a macro for every pet family, even ones this character can't
        -- summon yet (e.g. Felguard without the Demonology talent). GetSpellNameByID
        -- reads the spell database, not the spellbook, so the name resolves regardless;
        -- the /cast just no-ops until the spell is learned. This keeps the full set of
        -- macros present so the user isn't confused by missing ones after a respec.
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

-- Create/refresh the single Ritual of Summoning macro.
-- The macro casts the spell then calls Warlock_Qol_Tbc.SayRitualLine() to say the line.
-- Built regardless of whether the spell is known (name resolves from the spell database;
-- the /cast no-ops until learned) so the full macro set is always present.
-- Returns created, updated, conflicts (same shape as CreateSummonMacros).
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

-- Create/refresh EVERY macro we manage in one pass (all summon families + both rituals),
-- aggregating the counts/conflicts so the UI can report a single summary. Combat-guarded
-- once here (each sub-creator is also guarded, but bailing up front avoids printing the
-- combat message three times). Returns created, updated, conflicts (same shape as the others).
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

-- Reset Macros: remove every macro we made (pet + ritual + souls). Saved lines, feature
-- toggles, and profiles are all kept. Driven by the Reset page's "Reset Macros" button.
function WQ.ResetMacros()
    local removed = WQ.RemoveSummonMacros() + WQ.RemoveRitualMacro() + WQ.RemoveSoulsMacro()
    print(("|cff9900ffWarlockQol|r: removed %d macro(s). Your saved lines were kept."):format(removed))
end

-- ── Raid Cooldown Tracker (core: comms + roster + combat-log fallback) ─────────
--
-- Tracks each raid warlock's tracked-cooldown state so a later HUD can show who has a
-- soulstone READY vs. counting down. Hybrid model: WarlockQol users broadcast their OWN
-- real remaining time over addon comms (authoritative, survives /reload, no range limit);
-- warlocks NOT running the addon are filled in approximately from the combat log (in range
-- only) using a fixed assumed duration. A comms entry ALWAYS supersedes a combat-log guess
-- for the same person. Roster is enumerated independently (UnitClass) so every warlock gets
-- a row — shown "Ready" until we have a timer for them.
--
-- Data-driven: each tracked cooldown is one entry in TRACKED_COOLDOWNS, so adding
-- Shadowburn / Death Coil / etc. later is a data edit, not new plumbing. `castName` matches
-- the SPELL_CAST_SUCCESS combat-log spell name; `duration` is the fixed fallback used ONLY
-- for combat-log guesses (real users send their true remaining time).
--
-- The TBC 2.5.5 soulstone cooldown is a fixed 30 min (confirmed in-game), so the fallback
-- constant below IS the true duration. ⚠ STILL OPEN: a LIVE cooldown read in
-- GetOwnCooldownRemaining, so my own remaining survives a /reload (mid-cooldown) instead of
-- resetting to a full 30 min — needs the right spell/item cooldown source, verified in-game.
local SOULSTONE_FALLBACK_CD = 1800  -- seconds (30 min) — confirmed in-game 2026-07-06
local TRACKED_COOLDOWNS = {
    soulstone = {
        key      = "soulstone",
        label    = "Soulstone",
        class    = "WARLOCK",
        castName = SOULSTONE_SPELL_NAME,   -- reuse the announcer's cast-name match
        duration = SOULSTONE_FALLBACK_CD,
        icon     = "Interface\\Icons\\Spell_Shadow_SoulGem",  -- HUD row icon
    },
}
-- Stable iteration order for the tracked cooldowns (one for now; keeps a fixed order for a
-- future multi-cooldown HUD). Exposed to the UI further down.
local TRACKED_ORDER = { "soulstone" }

-- Addon-message prefix (≤16 chars). Registered via C_ChatInfo.RegisterAddonMessagePrefix at
-- PLAYER_LOGIN so we can RECEIVE it. Wire format of the messages themselves:
--   "S:<cdKey>:<remaining>"  — I broadcast my own remaining seconds for one cooldown.
--   "R"                      — "send me your state"; recipients rebroadcast their cooldowns.
local TRACKER_PREFIX = "WQoLCD"

-- Runtime cooldown store — NOT saved (timers are ephemeral and re-synced via comms/combat
-- log on login). Shape: cdState[cdKey][unitName] = { expires = GetTime()+remaining, source }.
-- source is "comms" (authoritative) or "combatlog" (a guess); comms is never clobbered by a guess.
local cdState = {}
for _, key in ipairs(TRACKED_ORDER) do cdState[key] = {} end

-- Combat-log and comms names can carry a "-Realm" suffix for cross-realm players; drop it so
-- every code path keys the store on the bare character name.
local function StripRealm(name)
    return name and name:gsub("%-.*", "") or name
end

-- Enumerate every WARLOCK in the current group (raid or party), including the player. Returns
-- an array of { name = <bare name>, unit = <unitId>, isPlayer = <bool> }. Independent of
-- comms/combat log so every warlock gets a row regardless of whether we have a timer for them.
local function RaidWarlocks()
    local out = {}
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
    else
        -- Not in a raid: this is a raid-only feature, so we show only the player (used by the
        -- config-page preview to position the HUD). Party members are intentionally ignored.
        local _, myClass = UnitClass("player")
        if myClass == "WARLOCK" then
            out[#out + 1] = { name = StripRealm(UnitName("player")), unit = "player", isPlayer = true }
        end
    end
    return out
end

-- Record a cooldown timer for a unit. `source` = "comms" (authoritative, a WarlockQol user's
-- real remaining time) or "combatlog" (an approximate guess). A comms entry supersedes a guess
-- and is never overwritten by one; a comms "remaining <= 0" clears the timer (ready now).
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

-- Read the player's OWN remaining cooldown for a tracked spell. This is the single seam where
-- the accurate broadcast is produced. Stage 1 returns the fixed fallback duration; swap in a
-- live read here once the exact soulstone cooldown source is confirmed in-game, e.g.:
--   local start, dur = GetSpellCooldown(spec.spellId)          -- Create Soulstone spell, or
--   local start, dur = GetItemCooldown(<Master Soulstone item>) -- the item cooldown
--   if start and start > 0 and dur and dur > 0 then return (start + dur) - GetTime() end
local function GetOwnCooldownRemaining(spec)
    return spec.duration   -- ⚠ placeholder until the live cooldown read is verified in-game
end

-- Which channel to broadcast on. Raid-only feature, so comms go over RAID only; nil otherwise
-- (party/solo) means we simply don't send — nothing is displayed outside a raid anyway.
local function TrackerChannel()
    if IsInRaid() then return "RAID" end
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

-- Broadcast my current remaining time for one cooldown (read from my own store so a reply to a
-- late-joiner's request reflects elapsed time, not the full duration). Sends only if running.
local function BroadcastCooldown(cdKey)
    local rem = GetCooldownRemaining(cdKey, UnitName("player"))
    if rem > 0 then SendTracker(("S:%s:%d"):format(cdKey, math.floor(rem))) end
end

local function BroadcastAllCooldowns()
    for _, key in ipairs(TRACKED_ORDER) do BroadcastCooldown(key) end
end

-- Whether the tracker is active for this character (master switch + per-profile flag), routed
-- through the same FeatureOn helper the announcers use.
local function TrackerActive()
    return FeatureOn("trackerEnabled")
end

-- Whether a specific tracked cooldown is enabled for tracking (per-profile `trackedCds`).
-- Absent key = tracked (default on); only an explicit false turns it off.
local function IsCdTracked(cdKey)
    local p = ActiveProfile()
    if not p then return false end
    local t = p.trackedCds
    return not t or t[cdKey] ~= false
end

-- Ask everyone to rebroadcast their cooldowns so a late joiner catches up. Throttled because
-- GROUP_ROSTER_UPDATE fires rapidly while a raid is forming.
local lastSyncRequest = 0
local function RequestTrackerSync()
    if not TrackerActive() then return end
    local now = GetTime()
    if now - lastSyncRequest < 5 then return end
    lastSyncRequest = now
    SendTracker("R")
end

-- Handle an incoming tracker message. Our own broadcasts are echoed back to us — ignore them
-- (we're the source of truth for ourselves). Malformed messages are dropped silently.
local function OnTrackerMessage(msg, sender)
    sender = StripRealm(sender)
    if not sender or sender == "" then return end
    if sender == StripRealm(UnitName("player")) then return end   -- ignore our own echo
    local tag = msg:sub(1, 1)
    if tag == "S" then
        local cdKey, rem = msg:match("^S:([%w_]+):(%d+)$")
        if cdKey and rem and TRACKED_COOLDOWNS[cdKey] then
            SetCooldown(cdKey, sender, tonumber(rem), "comms")
            if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
        end
    elseif tag == "R" then
        BroadcastAllCooldowns()
    end
end

-- Persist MY own cooldown's expiry as a WALL-CLOCK time() timestamp (per-character, saved). The
-- runtime cdState uses GetTime() (client uptime) which is wiped on /reload and reset on relog;
-- time() is real-world seconds, so a saved expiry stays meaningful across both. remaining <= 0
-- clears the saved entry.
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

-- On login/reload, re-seed MY own cooldown timers from the saved wall-clock expiries. Needed
-- because cdState is wiped on reload and nobody rebroadcasts our own cooldown back to us — so
-- without this the self-row falsely resets to "Ready". Expired entries are dropped.
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

-- Combat-log hook for a tracked-spell cast. If it's MY cast, record my own authoritative timer
-- (via the GetOwnCooldownRemaining seam), persist it for reload survival, and broadcast it;
-- otherwise, for another group member's cast, record an approximate combat-log guess (which
-- SetCooldown will not let overwrite an existing comms entry — a WarlockQol user's broadcast
-- always wins).
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

-- ── Missing Consumables (Stage A: detection core) ──────────────────────────────
-- A purely LOCAL feature (no comms, no announce): scans the PLAYER's own buffs + main-hand
-- weapon enchant and reports which raid consumables are MISSING or about to EXPIRE, feeding a
-- small HUD (Stage B). Data-driven like TRACKED_COOLDOWNS, so adding a consumable is a data
-- edit. Detection is by buff NAME, not spell id — a deliberate exception to the addon's
-- "ids not names" rule: "Well Fed" has dozens of per-food spell ids but one stable name, and
-- the reference WeakAura matches by name too. (Assumes an enUS client, which the user runs.)
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
}
-- Stable display order (matches the reference WA: flask, oil, food).
local CONSUMABLE_ORDER = { "flask", "oil", "food" }

-- Feature active for this character? Master switch + per-profile flag, via the shared helper.
local function ConsumablesActive()
    return FeatureOn("consumablesEnabled")
end

-- Whether a specific consumable is tracked (per-profile `trackedConsumes`). Absent key =
-- tracked (default on); only an explicit false turns it off. Mirrors IsCdTracked.
local function IsConsumeTracked(key)
    local p = ActiveProfile()
    if not p then return false end
    local t = p.trackedConsumes
    return not t or t[key] ~= false
end

-- The "about to expire" warning window in seconds (per-profile; default/clamp 120 = 2 min).
local function ConsumeThreshold()
    local p = ActiveProfile()
    local v = p and p.consumeThreshold
    if type(v) ~= "number" or v <= 0 then return 120 end
    return v
end

-- Scan the player's current HELPFUL auras + main-hand weapon enchant. Returns a map keyed by
-- consumable key -> { present = bool, remaining = seconds (0 when present with no readable timer) }.
local function ScanConsumables()
    local out = {}
    for _, key in ipairs(CONSUMABLE_ORDER) do out[key] = { present = false, remaining = 0 } end

    -- Player buffs: match each buff NAME against the aura-kind consumables. UnitAura returns
    -- name(1) … duration(5), expirationTime(6); expirationTime is an absolute GetTime() stamp.
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

-- ── Event frame ───────────────────────────────────────────────────────────────
--
-- In WoW, only Frame objects can register for and receive events.
-- We create an invisible frame purely to act as an event listener.

local eventFrame = CreateFrame("Frame")

-- Forward declaration: the OnEvent handler below (PLAYER_LOGIN) calls this, but it's
-- defined further down — declare it here so the closure captures it as an upvalue. Drives
-- the shared combat-log listener used by both the soulstone and banish announcers.
local UpdateCombatLogRegistration
-- Same forward-declaration for the Raid CD Tracker's own listeners (comms + roster). Defined
-- after the OnEvent handler so it can capture `eventFrame`.
local UpdateTrackerRegistration

-- RegisterEvent tells WoW to call this frame's OnEvent script when the
-- named event fires anywhere in the game.
eventFrame:RegisterEvent("ADDON_LOADED")           -- fires when any addon finishes loading
eventFrame:RegisterEvent("PLAYER_LOGIN")           -- fires once after the UI (incl. chat) is ready
eventFrame:RegisterEvent("UNIT_PET")               -- fires when the player's active pet changes

eventFrame:SetScript("OnEvent", function(self, event, ...)
    -- All registered events share this one handler; we branch on 'event'.

    if event == "ADDON_LOADED" then
        -- ADDON_LOADED fires for every addon, so check it's ours before acting.
        local name = ...
        if name == "Warlock_Qol_Tbc" then
            -- DB must be ready as early as possible (UI and casts may need it),
            -- so initialise it here on ADDON_LOADED.
            InitDB()
        end

    elseif event == "PLAYER_LOGIN" then
        -- Print the load message here rather than on ADDON_LOADED: the chat
        -- frame isn't reliably ready that early, so messages can be dropped.
        -- Pull the version straight from the .toc so we only bump it in one
        -- place. C_AddOns.GetAddOnMetadata is the modern call; the bare
        -- global is the fallback for older clients.
        local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local version = getMeta and getMeta("Warlock_Qol_Tbc", "Version") or "?"
        -- |cRRGGBB....|r is WoW's colour markup syntax for chat/print
        print(("|cff9900ffWarlockQol|r v%s loaded successfully. Type |cffffd700/wq|r to open the menu."):format(version))

        -- PLAYER_LOGIN is the first point UnitName/GetRealmName are reliable, so this is
        -- where we resolve (and cache) this character's profile binding. Everything that
        -- reads ActiveProfile()/CharState() is safe from here on.
        ResolveActiveBinding()

        -- First run: show the one-page setup wizard (intro + Create Macros) so the player
        -- sees what's available and can build their macros. We never create them silently.
        -- setupComplete is per-character (a fresh alt should still see the wizard once) and
        -- is set when the wizard is DISMISSED (its OnHide), NOT here — so a /reload before the
        -- player finishes still re-shows it. Fall back to opening the hub directly if the
        -- wizard somehow isn't available.
        local cs = CharState()
        if cs and not cs.setupComplete then
            if WQ.ShowWizard then
                -- Defer one tick so the wizard opens AFTER the login event chain settles —
                -- frames shown mid-login can get swept closed (CloseSpecialWindows). Re-check
                -- the flag at fire time in case setup was completed in between.
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

        -- Raid CD Tracker: register our comms prefix so we can RECEIVE broadcasts, sync the
        -- tracker's own listeners (comms + roster) to the enabled flag, and ask the group for
        -- their current cooldown state so we start populated (no-op when solo).
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(TRACKER_PREFIX)
        end
        -- Re-seed my own cooldown timers from saved wall-clock expiries BEFORE registering /
        -- syncing, so a /reload or relog mid-cooldown keeps my self-row (and I rebroadcast the
        -- correct remaining time if someone requests a sync).
        RestoreOwnCooldowns()
        UpdateTrackerRegistration()
        RequestTrackerSync()

        -- Restore the tracker HUD's saved position + shown state now the DB is ready (the UI
        -- file defines this; it's a standalone frame, independent of the /wq config window).
        if WQ.InitTrackerHUD then WQ.InitTrackerHUD() end

        -- Same for the Missing Consumables HUD: restore its position, start its scan driver if
        -- the feature is on, and apply visibility for the current context.
        if WQ.InitConsumablesHUD then WQ.InitConsumablesHUD() end

        -- Position/show the minimap button now the per-character angle + hidden flag are known.
        if WQ.InitMinimap then WQ.InitMinimap() end

    elseif event == "UNIT_PET" then
        -- Fires whenever the player's pet slot changes (summon, dismiss, death).
        local unit = ...
        if unit ~= "player" then return end
        if not UnitExists("pet") then return end  -- pet was dismissed/died, not summoned

        -- UnitCreatureFamily returns the family string e.g. "Succubus"
        -- UnitName returns the individual pet's name e.g. "Kalneth"
        -- Both are reliable once UNIT_PET has fired and UnitExists is true.
        local family = UnitCreatureFamily("pet")
        local name   = UnitName("pet")

        if family and name then
            -- Persist the name — it's static per character so this only really
            -- needs to happen once per pet type, but updating each time is harmless.
            -- The cache is per-character (each toon has its own named demons).
            local cs = CharState()
            if cs then cs.petNames[family] = name end
            -- If the config UI is open, refresh it so the detected name appears
            if WQ.RefreshUI then WQ.RefreshUI() end
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- This event is only registered while the soulstone or banish announcer is enabled
        -- (see UpdateCombatLogRegistration), so it carries no cost when both are off.
        --
        -- We key off the soulstone being CAST (SPELL_CAST_SUCCESS), NOT the buff aura.
        -- Aura events (SPELL_AURA_APPLIED/REMOVED) are reported from what the client can
        -- currently see, so the combat log re-fires them whenever a buffed unit moves in/
        -- out of range or after a desync — which made the same soulstone re-announce
        -- repeatedly. A cast event fires exactly once, when a warlock actually casts it.
        --
        -- Only announce when it involves MY group — the caster OR the recipient is in my
        -- party/raid (or is me) — so a stranger nearby stoning a stranger is ignored.
        -- sourceFlags = arg 6, destName = arg 9, destFlags = arg 10. We also pull spellId
        -- (arg 12, for the banish rank) and the SPELL_MISSED missType (arg 15).
        local _, subevent, _, _, sourceName, sourceFlags, _, _, destName, destFlags, _, spellId, spellName, _, missType = CombatLogGetCurrentEventInfo()
        if subevent == "SPELL_CAST_SUCCESS" and spellName == SOULSTONE_SPELL_NAME then
            if InMyGroup(sourceFlags) or InMyGroup(destFlags) then
                SaySoulstone(destName)
            end
            -- Feed the Raid CD Tracker: attribute the cast to its caster and start a timer
            -- (my own cast broadcasts my real cooldown; a group member's is an approx guess).
            OnTrackedCast("soulstone", sourceName, sourceFlags)
        elseif spellName == BanishName() and IsMine(sourceFlags) then
            -- The Banish announcer fires only on MY OWN banishes (not other warlocks'),
            -- announcing when the banish lands or when it's resisted. Each path appends the
            -- cast's rank. (Unlike soulstone we key off the aura landing, since "banished!"
            -- should only fire when it actually sticks — see SayBanish for the throttle that
            -- guards against the combat log re-firing the aura on range changes.)
            if subevent == "SPELL_AURA_APPLIED" then
                SayBanish(destName, BanishRankSuffix(spellId), false)
            elseif subevent == "SPELL_MISSED" and missType == "RESIST" then
                SayBanish(destName, BanishRankSuffix(spellId), true)
            end
        end

    elseif event == "CHAT_MSG_ADDON" then
        -- Registered only while the tracker is active (see UpdateTrackerRegistration). Filter
        -- to our prefix; args are prefix, message, channel, sender.
        local prefix, message, _, sender = ...
        if prefix == TRACKER_PREFIX then
            OnTrackerMessage(message, sender)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Roster changed (someone joined/left). Ask for a fresh sync so a late joiner catches
        -- up (throttled inside RequestTrackerSync). Re-evaluate HUD visibility (raid↔party↔solo
        -- can change whether it shows) and refresh its rows.
        RequestTrackerSync()
        if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
        if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
    end
end)

-- Register/unregister the shared combat-log event to match the enabled flags. Both the
-- soulstone and banish announcers listen on COMBAT_LOG_EVENT_UNFILTERED, so we keep it
-- registered while EITHER is on and drop it (zero per-event overhead in raids) only when
-- both are off. (Forward-declared above.)
UpdateCombatLogRegistration = function()
    -- Master off drops the listener entirely (no cost while everything is disabled).
    -- masterEnabled is per-character (CharState); the two announcer flags are per-profile.
    local cs = CharState()
    local p  = ActiveProfile()
    -- The tracker's combat-log FALLBACK (attributing others' soulstone casts) also rides this
    -- listener, so keep it registered while the tracker is on too — not just the announcers.
    local want = cs and cs.masterEnabled and p
                 and (p.soulstoneEnabled or p.banishEnabled or p.trackerEnabled)
    if want then
        eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        eventFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
end

-- Register/unregister the Raid CD Tracker's OWN events (comms receive + roster changes) to
-- match its enabled state, so a disabled tracker costs nothing. The combat-log fallback is
-- handled separately by UpdateCombatLogRegistration (shared with the announcers). (Assigned to
-- the forward-declared upvalue so the OnEvent handler and setters can call it.)
UpdateTrackerRegistration = function()
    if TrackerActive() then
        eventFrame:RegisterEvent("CHAT_MSG_ADDON")
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    else
        eventFrame:UnregisterEvent("CHAT_MSG_ADDON")
        eventFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    end
end

-- The five per-feature flags now live on the ACTIVE PROFILE (shareable config), so their
-- getters/setters read/write ActiveProfile(). The master switch is PER-CHARACTER, so it
-- reads/writes CharState().
function WQ.IsSoulstoneEnabled()
    local p = ActiveProfile()
    return p and p.soulstoneEnabled or false
end

-- Toggle the soulstone announcer on/off (driven by the page's checkbox). Persists the
-- choice and updates event registration immediately.
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

-- Enable getters/setters for the three macro-based features. Unlike the soulstone
-- announcer these own no event, so the setter only needs to persist the flag — the
-- guard in each WQ.Say*Line entry point reads it the next time the macro fires.
function WQ.IsPetEnabled()    local p = ActiveProfile(); return p and p.petEnabled    or false end
function WQ.SetPetEnabled(on)    local p = ActiveProfile(); if p then p.petEnabled    = on and true or false end end

function WQ.IsRitualEnabled() local p = ActiveProfile(); return p and p.ritualEnabled or false end
function WQ.SetRitualEnabled(on) local p = ActiveProfile(); if p then p.ritualEnabled = on and true or false end end

function WQ.IsSoulsEnabled()  local p = ActiveProfile(); return p and p.soulsEnabled  or false end
function WQ.SetSoulsEnabled(on)  local p = ActiveProfile(); if p then p.soulsEnabled  = on and true or false end end

-- Master switch getter/setter. Per-character (CharState). Off silences every feature at
-- once without touching the per-feature flags; the setter also (un)registers the combat-log
-- listener so a fully disabled addon costs nothing. See FeatureOn / UpdateCombatLogRegistration.
function WQ.IsMasterEnabled() local cs = CharState(); return cs and cs.masterEnabled or false end
function WQ.SetMasterEnabled(on)
    local cs = CharState()
    if cs then cs.masterEnabled = on and true or false end
    UpdateCombatLogRegistration()
    UpdateTrackerRegistration()   -- master off also drops the tracker's comms/roster listeners
    -- Re-evaluate both standalone HUDs so they hide/show with the master switch (defensive: the
    -- UI file defines these; nil pre-login). Also stop/start the consumables scan driver.
    if WQ.UpdateTrackerHUDVisibility     then WQ.UpdateTrackerHUDVisibility()     end
    if WQ.UpdateConsumablesRegistration  then WQ.UpdateConsumablesRegistration()  end
    if WQ.UpdateConsumablesHUDVisibility then WQ.UpdateConsumablesHUDVisibility() end
end

-- ── Raid CD Tracker public API ────────────────────────────────────────────────
-- Used by the (Stage 2/3) HUD + config page; exposed now so Stage 1 can be exercised
-- in-game. The tracked-cooldown table + order are shared read-only for the UI to build rows.
WQ.TRACKED_COOLDOWNS = TRACKED_COOLDOWNS
WQ.TRACKED_ORDER     = TRACKED_ORDER

-- Enabled getter/setter (per-profile flag, like the announcers). The setter re-syncs the
-- combat-log fallback listener AND the tracker's own comms/roster listeners, then requests a
-- fresh sync so turning it on immediately catches up on the group's state.
function WQ.IsTrackerEnabled() local p = ActiveProfile(); return p and p.trackerEnabled or false end
function WQ.SetTrackerEnabled(on)
    local p = ActiveProfile()
    if p then p.trackerEnabled = on and true or false end
    UpdateCombatLogRegistration()
    UpdateTrackerRegistration()
    RequestTrackerSync()
    if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
end

-- Per-profile "auto-show the HUD in a raid" flag. Toggling it re-evaluates whether the HUD
-- should currently be shown (the UI owns that logic via UpdateTrackerHUDVisibility). This is a
-- raid-only feature — there is no party equivalent.
function WQ.IsTrackerShowRaid()  local p = ActiveProfile(); return p and p.trackerShowRaid  or false end
function WQ.SetTrackerShowRaid(on)
    local p = ActiveProfile(); if p then p.trackerShowRaid = on and true or false end
    if WQ.UpdateTrackerHUDVisibility then WQ.UpdateTrackerHUDVisibility() end
end

-- Per-cooldown tracking toggle (data-driven; soulstone is the only one for now). Off stops the
-- combat-log/comms recording for that cooldown (see IsCdTracked in OnTrackedCast).
function WQ.IsCooldownTracked(cdKey) return IsCdTracked(cdKey) end
function WQ.SetCooldownTracked(cdKey, on)
    local p = ActiveProfile(); if not p then return end
    p.trackedCds = p.trackedCds or {}
    p.trackedCds[cdKey] = on and true or false
    if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
end

-- Cheap single-lookup remaining-seconds getter (reads only the store, no roster scan) — the
-- HUD's per-frame tick uses this so it doesn't rebuild the roster every frame. 0 = ready/unknown.
function WQ.GetTrackerRemaining(cdKey, unitName)
    return GetCooldownRemaining(cdKey, unitName)
end

-- Snapshot the roster + each warlock's remaining time per tracked cooldown, for the HUD.
-- Returns an array of { name, isPlayer, cds = { [cdKey] = remainingSeconds (0 = ready) } }.
function WQ.GetTrackerSnapshot()
    local rows = {}
    for _, wl in ipairs(RaidWarlocks()) do
        local cds = {}
        for _, key in ipairs(TRACKED_ORDER) do
            cds[key] = GetCooldownRemaining(key, wl.name)
        end
        rows[#rows + 1] = { name = wl.name, isPlayer = wl.isPlayer, cds = cds }
    end
    -- Always list the player (whoever is running the addon) first, then everyone else by name.
    -- So each addon user sees their own row pinned at the top of their HUD.
    table.sort(rows, function(a, b)
        if a.isPlayer ~= b.isPlayer then return a.isPlayer end
        return a.name < b.name
    end)
    return rows
end

-- Stage-1 debug dump — no HUD yet, so call this in-game to verify the plumbing:
--   /dump Warlock_Qol_Tbc.DebugDumpCooldowns()   (or /run ...)
-- Prints whether the tracker is active and each grouped warlock's per-cooldown state.
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

-- ── Missing Consumables public API ─────────────────────────────────────────────
-- Used by the (Stage B) HUD + (Stage C) config page; exposed now so Stage A can be exercised
-- in-game. The data table + order are shared read-only for the UI to build the icon strip.
WQ.CONSUMABLES      = CONSUMABLES
WQ.CONSUMABLE_ORDER = CONSUMABLE_ORDER

-- Enabled getter/setter (per-profile flag, like the tracker). The HUD hooks (defined in the UI
-- file, Stage B) are called defensively — nil until then.
function WQ.IsConsumablesEnabled() local p = ActiveProfile(); return p and p.consumablesEnabled or false end
function WQ.SetConsumablesEnabled(on)
    local p = ActiveProfile()
    if p then p.consumablesEnabled = on and true or false end
    if WQ.UpdateConsumablesRegistration   then WQ.UpdateConsumablesRegistration()   end
    if WQ.UpdateConsumablesHUDVisibility   then WQ.UpdateConsumablesHUDVisibility()   end
end

-- Per-profile "auto-show the HUD in a raid" flag (raid-only, like the cooldown tracker).
function WQ.IsConsumeShowRaid() local p = ActiveProfile(); return p and p.consumeShowRaid or false end
function WQ.SetConsumeShowRaid(on)
    local p = ActiveProfile(); if p then p.consumeShowRaid = on and true or false end
    if WQ.UpdateConsumablesHUDVisibility then WQ.UpdateConsumablesHUDVisibility() end
end

-- Per-profile "glow the missing icons" flag. Off = plain (non-flashing) icons for anyone who
-- finds the proc glow too aggressive; the icon still appears (a missing icon with no countdown).
function WQ.IsConsumeGlow() local p = ActiveProfile(); return p and p.consumeGlow or false end
function WQ.SetConsumeGlow(on)
    local p = ActiveProfile(); if p then p.consumeGlow = on and true or false end
    if WQ.RefreshConsumablesHUD then WQ.RefreshConsumablesHUD() end   -- force a rebuild (status unchanged)
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

-- Snapshot the tracked consumables for the HUD/debug. Returns an ordered array (CONSUMABLE_ORDER)
-- of { key, label, icon, present, remaining, status } where status is:
--   "missing" — tracked but no buff present (HUD shows a glowing icon)
--   "low"     — present but <= threshold remaining (HUD shows the icon + countdown)
--   "ok"      — present and healthy (HUD hides it)
-- Untracked consumables are omitted. The HUD shows only "missing"/"low"; when none qualify it
-- hides completely.
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

-- Stage-A debug dump — no HUD yet, so call this in-game to verify detection:
--   /run Warlock_Qol_Tbc.DebugDumpConsumables()
-- Prints whether the feature is active, the threshold, and each tracked consumable's status.
function WQ.DebugDumpConsumables()
    print(("|cff9900ffWarlockQol|r Consumables — active: %s, threshold: %ds"):format(
        ConsumablesActive() and "yes" or "no", ConsumeThreshold()))
    for _, r in ipairs(WQ.GetConsumableSnapshot()) do
        local rem = r.remaining > 0 and (math.floor(r.remaining) .. "s") or "-"
        print(("  %s: %s (present=%s, rem=%s)"):format(r.label, r.status, tostring(r.present), rem))
    end
end

-- ── Profile management API ────────────────────────────────────────────────────
--
-- The UI (profile page) calls exactly these. All operations keep the runtime consistent:
-- the active-profile/char caches are refreshed and the combat-log listener is re-synced
-- whenever the bound profile or its feature flags may have changed.

-- Name of the profile the current character is bound to.
function WQ.GetActiveProfileName()
    local cs = CharState()
    return cs and cs.profile
end

-- All profile names, sorted alphabetically (a stable order for the UI dropdown/list).
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
    return true
end

-- Create a new default-seeded profile and switch the current character to it. Trims the
-- name; rejects empty (false,"empty") and a name that already exists (false,"exists").
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
    return true
end

-- Deep-copy the source profile's contents INTO the current active profile (overwrite),
-- staying bound to the active profile. Rejects copying onto itself (false,"same") and an
-- unknown source (false,"unknown"). The two profiles never share table references.
function WQ.CopyProfileInto(sourceName)
    if not (Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[sourceName]) then
        return false, "unknown"
    end
    local cs = CharState()
    if not cs then return false, "unknown" end
    if sourceName == cs.profile then return false, "same" end

    local src = Warlock_Qol_Tbc_DB.profiles[sourceName]
    local dst = ActiveProfile()
    -- Overwrite in place (preserve the dst table identity so caches/bindings stay valid):
    -- wipe every existing key, then deep-copy the source in.
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = DeepCopy(v) end
    InitProfile(dst)                -- heal skeleton in case the source was partial
    UpdateCombatLogRegistration()   -- copied announcer flags may differ
    return true
end

-- Delete a profile. Guards: cannot delete the currently-active profile (false,"active"),
-- cannot delete the last remaining profile (false,"last"), unknown (false,"unknown").
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

-- Hard Reset (ACCOUNT-WIDE): wipe the whole addon back to a fresh-install state. Removes THIS
-- character's macros, then discards the ENTIRE SavedVariables DB — every profile, every
-- character's binding/master switch/pet-name cache/first-run flag, and the saved window
-- geometry — and rebuilds the skeleton, re-resolving this character so it gets a fresh
-- default-seeded profile exactly as a first install would (the first-run hub will show again
-- next login, and every other character gets a fresh profile the next time it logs in). The DB
-- table is wiped IN PLACE (its identity is preserved) so nothing holding the SavedVariable
-- reference is left pointing at a stale table. Blocked in combat (macro edits are). Driven by
-- the Reset page's "Hard Reset" button.
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
    print(("|cff9900ffWarlockQol|r: reset EVERYTHING to defaults (all profiles and settings) and removed %d macro(s)."):format(removed))
    return true
end

-- ── Profile export / import (share strings) ───────────────────────────────────
--
-- A profile is a self-contained config table, so it can be shared between players as a
-- copy-paste string. Wire format:  WQT1!<base64( <checksum><serialized> )>
--   * "WQT1" is a format version so a future schema change can be rejected cleanly.
--   * <checksum> = 8 hex chars over the serialized body — catches a truncated/mangled
--     paste BEFORE we try to build a profile out of garbage.
--   * <serialized> is our own length-prefixed encoding (below), NOT a Lua chunk. Import
--     strings come from other players, so the parser only ever produces DATA and never
--     executes code (no loadstring / no sandboxed chunk — even an empty-env chunk can hang
--     the client via string-literal methods). The addon is dependency-free (see CLAUDE.md),
--     so base64 + serializer + parser are all hand-rolled here.

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

-- A Lua table is treated as an ARRAY when its only keys are 1..#t (empty counts as array),
-- otherwise as a string-keyed MAP. Our profile schema never mixes the two in one table.
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

-- Parse one value starting at `pos`. Returns nextPos, value on success; nil, "corrupt" on
-- any malformed input. `value` may be boolean false, so success is signalled by nextPos
-- being non-nil, never by the value. Purely constructs data — never executes anything.
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

-- Rebuild a clean profile table from a parsed/foreign table, pulling ONLY the known
-- shareable fields with the correct types (junk keys, wrong types, and non-string lines are
-- dropped). Used on both export (guarantee we ship a known shape) and import (never trust a
-- stranger's structure — this is what stops a malformed `lines` from crashing InitProfile).
local IMPORT_POOL_FIELDS = { "ritualLines", "soulsLines", "soulstoneLines", "banishLines", "banishResistLines" }
local IMPORT_FLAG_FIELDS = { "petEnabled", "ritualEnabled", "soulsEnabled", "soulstoneEnabled", "banishEnabled", "trackerEnabled", "trackerShowRaid", "consumablesEnabled", "consumeShowRaid", "consumeGlow" }
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
    -- per-cooldown tracking flags (map cdKey -> false). Only known cooldowns from
    -- TRACKED_ORDER, and only an explicit false travels (absent = tracked; InitProfile
    -- defaults the rest) so a foreign string can't inject arbitrary map keys.
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
    -- per-consumable tracking flags — same shape/rules as trackedCds, whitelisted to CONSUMABLE_ORDER.
    if type(raw.trackedConsumes) == "table" then
        local t
        for _, key in ipairs(CONSUMABLE_ORDER) do
            if raw.trackedConsumes[key] == false then
                t = t or {}
                t[key] = false
            end
        end
        if t then p.trackedConsumes = t end
    end
    -- consumable expiry threshold (seconds) — only a sane number travels; InitProfile defaults it.
    if type(raw.consumeThreshold) == "number" and raw.consumeThreshold >= 5 and raw.consumeThreshold <= 3600 then
        p.consumeThreshold = math.floor(raw.consumeThreshold)
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

-- Export the named profile as a shareable string, or nil if that profile doesn't exist.
-- Ships a clean known-shape copy plus the source name (for the importer's name prefill).
function WQ.ExportProfile(name)
    local prof = Warlock_Qol_Tbc_DB and Warlock_Qol_Tbc_DB.profiles and Warlock_Qol_Tbc_DB.profiles[name]
    if not prof then return nil end
    local out = {}
    SerializeValue({ name = name, profile = SanitizeProfile(prof) }, out)
    local body = table.concat(out)
    return "WQT1!" .. Base64Encode(Checksum(body) .. body)
end

-- Peek the source profile name embedded in an export string, for the UI's name prefill.
-- Returns the name string, or nil if the string can't be decoded.
function WQ.PeekImportName(str)
    local ok, tbl = DecodeExport(str)
    if not ok then return nil end
    return type(tbl.name) == "string" and tbl.name or nil
end

-- Import an export string as a NEW profile named `newName`. Never overwrites an existing
-- profile and never switches the character to it (the UI drives switching). Returns true,
-- or false + reason: "empty" (blank string/name), "badformat"/"badversion" (not our string),
-- "corrupt" (checksum/parse failure), "exists" (name already taken).
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
--
-- SlashCmdList is a global WoW table. Assigning a function to a key registers
-- that function as the handler for the matching SLASH_* command strings.

SLASH_WARLOCK_QOL_TBC1 = "/wq"
SlashCmdList["WARLOCK_QOL_TBC"] = function(msg)
    -- Toggle the window. Always reopen on the home page so "/wq" reliably
    -- lands on the hub.
    if Warlock_Qol_Tbc_Frame and Warlock_Qol_Tbc_Frame:IsShown() then
        Warlock_Qol_Tbc_Frame:Hide()
    elseif WQ.OpenHome then
        WQ.OpenHome()
    end
end
