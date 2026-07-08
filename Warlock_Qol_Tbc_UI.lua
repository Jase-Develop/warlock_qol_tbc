-- Warlock_Qol_Tbc_UI.lua — Config UI: an ElvUI-style flat-dark window with a left nav.
--
-- This file builds the addon's interface entirely in Lua using WoW's frame API.
-- No XML, and (per the project's dependency-free rule) NO Ace3/AceGUI/LibStub or any
-- other external library — every frame and widget here is hand-rolled on the stock API.
-- ElvUI is only the *aesthetic* target, never a dependency.
--
-- Layout (the "one window, swappable pages" model from CLAUDE.md, restyled):
--
--   +-----------------------------------------------------------+
--   |  WarlockQol  v0.x                                    [X]   |  title bar
--   +----------------+------------------------------------------+
--   | General        |  Demon Summon Lines          (header)    |  <- accent page header
--   | Demon Summon...| ---------------------------------------- |
--   | Ritual of S... |  [ page body — one page shown at a time ]|
--   | Ritual of So.. |                                          |
--   | Soulstone...   |                                          |
--   +----------------+------------------------------------------+
--                                                          grip /
--
-- A single container frame (Warlock_Qol_Tbc_Frame) owns the chrome. A fixed-width left
-- SIDEBAR holds five flat nav items; the CONTENT area to its right hosts the "pages"
-- (child frames that fill the content area below a shared gold header). Exactly one
-- page shows at a time via ShowPage(name); the matching nav item highlights gold.
--
-- This is the FIRST PASS of the flat-dark re-skin: the nav shell, the shared theme +
-- flat widgets, and a standardized page/header template are in place, and the
-- **Demon Summon Lines** page is the fully-converted reference. The other four pages are
-- reachable and functional through the nav and inherit the flat widgets, but are not
-- yet individually fine-tuned.
--
-- Loaded after Warlock_Qol_Tbc.lua, so WarlockQol / WQ are already defined.

local WQ = Warlock_Qol_Tbc

-- ── Window geometry ───────────────────────────────────────────────────────────
-- The sidebar eats horizontal space the old single-column layout didn't need, so the
-- minimum width is larger than before to keep the Demon Summon tab row from overflowing
-- the (now narrower) content column. Height/position are still user-driven + persisted.
local FRAME_W  = 800   -- default frame width in pixels (the user can resize)
local FRAME_H  = 600   -- default frame height in pixels (the user can resize)
local MIN_W, MIN_H = 600, 500   -- smallest the user can shrink the frame to (tall enough for the 3-section nav + the two pinned Create/Open Macros buttons, and the Profiles page's Share section)
local MAX_W, MAX_H = 940, 780   -- largest the user can grow the frame to
local ROW_H    = 26    -- height of each line entry in the scroll list
local ROW_POOL = 24    -- row frames created per list — enough to fill MAX_H. The
                       -- number actually shown is computed from the list's height.

local PAD        = 8    -- outer/gutter padding between the chrome pieces
local TITLEBAR_H = 30   -- height of the top title strip (brand + close button)
local SIDEBAR_W  = 150  -- fixed width of the left nav column
local NAV_H      = 26   -- height of each nav item

-- Raid target marker tokens → their icon number in UI-RaidTargetingIcon_N (1–8).
-- The chat frame renders these tokens as icons when a line is sent; we mirror that in
-- the line-list preview so the user sees the icon rather than the literal "{star}" text.
-- Named aliases plus {rt1}–{rt8}, matching what the say code accepts. DISPLAY ONLY — the
-- stored line and what SendChatMessage sends stay as the raw token text.
local RAID_ICON_TOKENS = {
    star = 1, circle = 2, diamond = 3, triangle = 4,
    moon = 5, square = 6, cross = 7, x = 7, skull = 8,
    rt1 = 1, rt2 = 2, rt3 = 3, rt4 = 4, rt5 = 5, rt6 = 6, rt7 = 7, rt8 = 8,
}

-- The 8 raid markers in game order (1–8), each paired with the named {token} we insert
-- when its quick-insert button is clicked. Drives the icon-button row in BuildLineList.
local RAID_ICON_ORDER = {
    { n = 1, token = "{star}" },
    { n = 2, token = "{circle}" },
    { n = 3, token = "{diamond}" },
    { n = 4, token = "{triangle}" },
    { n = 5, token = "{moon}" },
    { n = 6, token = "{square}" },
    { n = 7, token = "{cross}" },
    { n = 8, token = "{skull}" },
}

-- Return text with any {token} raid-marker swapped for its inline texture escape. The
-- ":0" sizes the icon to the FontString's line height so it scales with the row font.
local function RenderIconTokens(text)
    if not text then return text end
    return (text:gsub("{(%w+)}", function(name)
        local n = RAID_ICON_TOKENS[name:lower()]
        if n then
            return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. n .. ":0|t"
        end
        -- Not a raid-icon token (e.g. {targetName}) — leave it untouched.
        return "{" .. name .. "}"
    end))
end

-- ── Theme ──────────────────────────────────────────────────────────────────────
-- ElvUI-style flat dark palette (see Docs/UI/WarlockQol_UI_Design_Doc.md). Kept in one
-- table so a future re-theme is a single edit. RGB are 0–1 floats; the matching hex
-- strings are for inline |cAARRGGBB| coloured FontString text.
local THEME = {
    bg      = { 0.063, 0.063, 0.063, 1 },  -- #101010 primary backdrop, zero transparency
    panel   = { 0.118, 0.118, 0.118, 1 },  -- #1e1e1e charcoal sub-panels
    field   = { 0.04,  0.04,  0.04,  1 },  -- darker fill for inputs/checkbox boxes
    accent  = { 0.529, 0.533, 0.933, 1 },  -- #8788EE Warlock class colour (accent / selection)
    offRed  = { 0.769, 0.118, 0.227, 1 },  -- #C41E3A Death Knight red (a disabled/off toggle)
    blue    = { 0.0,   0.659, 1.0,   1 },  -- #00a8ff active value / state
    border  = { 0.24,  0.24,  0.24,  1 },  -- thin 1px panel borders
    text    = { 0.85,  0.85,  0.85,  1 },  -- off-white body text
    textDim = { 0.55,  0.55,  0.55,  1 },  -- muted/secondary text
}
local HEX_ACCENT = "8788ee"  -- Warlock class colour, matches THEME.accent

-- ── Font ─────────────────────────────────────────────────────────────────────
-- Bundled PT Sans Narrow (OFL, redistributable) lives in the addon's Fonts/ folder.
-- CRITICAL: the load must degrade gracefully — if the .ttf is missing or the client
-- rejects it, SetFont returns false and we fall back to a stock WoW font so the UI is
-- never blank. Always route text through ApplyFont so that fallback applies everywhere.
local FONT_PATH    = "Interface\\AddOns\\Warlock_Qol_Tbc\\Fonts\\PTSansNarrow.ttf"
local FONT_FALLBACK = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

-- True italics need an italic FONT FILE — WoW's SetFont flags are only OUTLINE/
-- THICKOUTLINE/MONOCHROME, there is no "italic" flag. PT Sans *Narrow* has no italic face
-- on Google Fonts, so we bundle PT Sans Italic (regular width, same ParaType OFL
-- superfamily) for the rare italic accent (the empty-list message). Falls back to the
-- stock font if missing.
local FONT_ITALIC_PATH = "Interface\\AddOns\\Warlock_Qol_Tbc\\Fonts\\PTSansItalic.ttf"

-- Set a FontInstance's font to PT Sans Narrow, falling back to a stock font if the
-- bundled .ttf can't be used. `obj` is any FontString/EditBox; size in points; flags is
-- the standard SetFont flag string ("", "OUTLINE", …).
local function ApplyFont(obj, size, flags)
    flags = flags or ""
    local ok = obj:SetFont(FONT_PATH, size, flags)
    if not ok then obj:SetFont(FONT_FALLBACK, size, flags) end
    return obj
end

-- As ApplyFont, but with the bundled italic face (genuine italics). Falls back to the
-- stock font (upright — there's no stock italic) if the italic .ttf is unavailable.
local function ApplyFontItalic(obj, size, flags)
    flags = flags or ""
    local ok = obj:SetFont(FONT_ITALIC_PATH, size, flags)
    if not ok then obj:SetFont(FONT_FALLBACK, size, flags) end
    return obj
end

-- ── Flat-frame helper ───────────────────────────────────────────────────────────
-- Apply the flat ElvUI-style backdrop: a solid 1px-bordered fill. Uses WHITE8X8 for
-- both fill and edge so the colour is whatever we set (no baked-in art / gradients).
-- `frame` must have the BackdropTemplate mixin (created with "...,BackdropTemplate").
local function ApplyFlat(frame, color, border)
    if not frame.SetBackdrop then return end  -- graceful: skip if no backdrop mixin
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = border and "Interface\\Buttons\\WHITE8X8" or nil,
        edgeSize = 1,
    })
    frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
    if border then
        local b = THEME.border
        frame:SetBackdropBorderColor(b[1], b[2], b[3], b[4] or 1)
    end
end

-- ── Main container frame ──────────────────────────────────────────────────────
-- "BackdropTemplate" mixes in SetBackdrop (since 9.0 it's no longer a default method).

local f = CreateFrame("Frame", "Warlock_Qol_Tbc_Frame", UIParent, "BackdropTemplate")
f:SetSize(FRAME_W, FRAME_H)
f:SetPoint("CENTER")  -- centre on screen by default; player can drag it

-- Allow the user to resize the frame (via the grip added further down). Clamp how far
-- they can shrink/grow it. SetResizeBounds is the modern call; fall back to the old
-- SetMinResize/SetMaxResize on clients that predate it.
f:SetResizable(true)
if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
else
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end
end

-- Persist/restore the frame's size and position across sessions (stored in the DB).
local function SavePlacement()
    local db = Warlock_Qol_Tbc_DB
    if not db then return end
    db.ui = db.ui or {}
    db.ui.width, db.ui.height = f:GetWidth(), f:GetHeight()
    local point, _, relPoint, x, y = f:GetPoint()
    db.ui.point, db.ui.relPoint, db.ui.x, db.ui.y = point, relPoint, x, y
end

local function RestorePlacement()
    local ui = Warlock_Qol_Tbc_DB and Warlock_Qol_Tbc_DB.ui
    if not ui then return end
    if ui.width and ui.height then f:SetSize(ui.width, ui.height) end
    if ui.point then
        f:ClearAllPoints()
        f:SetPoint(ui.point, UIParent, ui.relPoint, ui.x, ui.y)
    end
end

-- Makes the frame draggable (and saves the new position when the drag ends).
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop",  function() f:StopMovingOrSizing(); SavePlacement() end)

-- DIALOG strata keeps this frame above most game UI but below things like the
-- error frame. SetToplevel ensures it sorts above other DIALOG frames when clicked.
f:SetFrameStrata("DIALOG")
f:SetToplevel(true)
f:Hide()  -- hidden by default; /wq toggles it

-- Register with the game so pressing Escape closes THIS window (like most app dialogs)
-- instead of popping the game menu over the top. UISpecialFrames hides the named frame on
-- Escape when it's shown; the name must match the global frame name ("Warlock_Qol_Tbc_Frame").
tinsert(UISpecialFrames, "Warlock_Qol_Tbc_Frame")

-- Flat dark backdrop with a crisp 1px border — the ElvUI look replaces the old
-- semi-transparent DialogBox art.
ApplyFlat(f, THEME.bg, true)
-- Semi-transparent fill (border stays solid). 0.8 = a subtle see-through, less than the
-- cooldown/consumables HUDs' 0.5 (the big main frame reads as too transparent lower than this).
f:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.8)

-- ── Title bar (brand + close) ─────────────────────────────────────────────────
-- A subtle charcoal strip across the very top carrying the addon name + version and
-- the close button. A thin divider under it separates it from the body.
local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, -PAD)
titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -PAD)
titleBar:SetHeight(TITLEBAR_H)
ApplyFlat(titleBar, THEME.panel, true)

local function AddonVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMeta and getMeta("Warlock_Qol_Tbc", "Version") or "?"
end

-- App logo: the Subjugate Demon (a.k.a. Enslave Demon) spell icon, sitting to the LEFT of the
-- brand text. Same art as the minimap button, so the addon reads as one identity.
local logo = titleBar:CreateTexture(nil, "OVERLAY")
logo:SetSize(18, 18)
logo:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
logo:SetTexture("Interface\\Icons\\Spell_Shadow_EnslaveDemon")
logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local brand = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(brand, 15)
brand:SetPoint("LEFT", logo, "RIGHT", 6, 0)
brand:SetText(("|cff%sWarlockQol (TBC)|r  |cff888888v%s|r"):format(HEX_ACCENT, AddonVersion()))

-- Themed flat close button (replaces the classic round UIPanelCloseButton art): a purple
-- "X" on the flat field so it matches the rest of the UI. Hover brightens the X and accents
-- the border. Clicking hides the window — as does Escape, via UISpecialFrames below.
local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
closeBtn:SetSize(22, 22)
closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
ApplyFlat(closeBtn, THEME.field, true)

local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
ApplyFont(closeX, 15)
closeX:SetPoint("CENTER")
closeX:SetText("X")
closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])

closeBtn:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    closeX:SetTextColor(0.78, 0.78, 1.0)
end)
closeBtn:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
end)
closeBtn:SetScript("OnClick", function() f:Hide() end)

-- ── Sidebar (left nav column) ─────────────────────────────────────────────────
local sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
sidebar:SetPoint("TOPLEFT",    titleBar, "BOTTOMLEFT", 0, -PAD)
sidebar:SetPoint("BOTTOMLEFT", f,        "BOTTOMLEFT", PAD, PAD)
sidebar:SetWidth(SIDEBAR_W)
ApplyFlat(sidebar, THEME.panel, true)

-- ── Content area (right pane) ─────────────────────────────────────────────────
-- Pages fill this below a shared gold header. It carries no backdrop of its own (it
-- sits on the flat window bg) and never enables the mouse, so clicks in its bottom-right
-- corner fall through to the resize grip.
local content = CreateFrame("Frame", nil, f)
content:SetPoint("TOPLEFT",     sidebar, "TOPRIGHT",   PAD, 0)
content:SetPoint("BOTTOMRIGHT", f,       "BOTTOMRIGHT", -PAD, PAD)

-- Shared page header — laid out identically for every content page (built in ONE place,
-- never hand-placed per page):
--
--   <Title>                              [x] Enabled   title top-left, toggle top-right
--   <Description / subtitle>                            directly beneath the title
--   --------------------------------------------------  divider, BELOW the description
--   [ page body ]                                       starts under the divider
--
-- The subtitle, divider and the pages are wired together by *anchoring*, not by measured
-- pixel offsets: the divider hangs off the subtitle's bottom and each page hangs off the
-- divider's bottom. So when the description wraps to more lines at narrow widths the rule
-- and the whole body drop to match automatically, and an empty subtitle collapses the
-- rule right up under the title. ShowPage only has to set the subtitle TEXT and the
-- toggle STATE per page — the geometry follows on its own.
local pageTitle = content:CreateFontString(nil, "OVERLAY")
ApplyFont(pageTitle, 16)
pageTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -6)
pageTitle:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])

-- Created further down (the toggle needs StyleCheckbox, which is defined later); forward-
-- declared here so ShowPage / NewPage can capture them as upvalues.
local pageSubtitle, pageDivider, enableCheck, enableLabel
local currentToggle   -- { get, set } toggle spec of the page currently shown, or nil

-- ── Page navigation ───────────────────────────────────────────────────────────

local pages       = {}   -- name -> page frame
local titles      = {}   -- name -> header title text for that page
local subtitles   = {}   -- name -> description string shown under the title (or nil)
local toggleSpecs = {}   -- name -> { get, set } enable-toggle spec (or nil = no toggle)
local currentPage        -- name of the page currently shown
local UpdateNav          -- forward decl: highlights the nav item for the current page

-- Show one page (hiding the rest), update the gold header, refresh the nav highlight,
-- and run the page's refresh hook so its contents are current. Exposed so the core /
-- nav buttons can navigate.
local function ShowPage(name)
    -- Abandon any in-progress line edit on the page we're leaving, so returning to it is a
    -- clean "Add Line" state rather than a stale half-finished edit. (currentPage still
    -- holds the outgoing page here — it's updated below.)
    local leaving = currentPage and pages[currentPage]
    if leaving and leaving.CancelEdit and leaving ~= pages[name] then
        leaving.CancelEdit()
    end

    for n, p in pairs(pages) do
        if n == name then p:Show() else p:Hide() end
    end
    currentPage = name
    pageTitle:SetText(titles[name] or "WarlockQol (TBC)")

    -- Shared description: drives the divider + body position purely via anchoring, so
    -- setting the text is all that's needed (empty string collapses the rule up under
    -- the title for pages with no description).
    pageSubtitle:SetText(subtitles[name] or "")

    -- Shared top-right enable toggle: show + sync it for pages that have one, hide it
    -- otherwise. currentToggle is read by the checkbox's OnClick handler.
    currentToggle = toggleSpecs[name]
    if currentToggle then
        enableCheck:Show(); enableLabel:Show()
        enableCheck:SetChecked(currentToggle.get and currentToggle.get() and true or false)
        enableCheck.RefreshStateColor()  -- sync the red "off" block to the new state
    else
        enableCheck:Hide(); enableLabel:Hide()
    end

    if UpdateNav then UpdateNav(name) end
    local p = pages[name]
    if p and p.OnPageShow then p.OnPageShow() end
end

-- Closing the whole window (X button, Escape, or /wq toggle) also abandons an in-progress
-- edit on the current page, so the next open is a clean slate. The main frame's own OnHide
-- fires reliably on a direct Hide(); we hook it (rather than replace) to preserve any other
-- OnHide behaviour.
f:HookScript("OnHide", function()
    local p = currentPage and pages[currentPage]
    if p and p.CancelEdit then p.CancelEdit() end
end)

-- Re-run the current page's refresh hook. Used after a resize so the visible row
-- count (and any stretched widgets) update live as the user drags the grip.
local function RefreshCurrent()
    local p = currentPage and pages[currentPage]
    if p and p.OnPageShow then p.OnPageShow() end
end
f:SetScript("OnSizeChanged", RefreshCurrent)

-- Open the window on the home page. Used by the slash command and by first-run.
local placementRestored = false
function WQ.OpenHome()
    -- Apply the saved size/position the first time we open this session — the DB is
    -- guaranteed ready by now (InitDB ran on ADDON_LOADED).
    if not placementRestored then
        RestorePlacement()
        placementRestored = true
    end
    f:Show()
    ShowPage("home")
end

-- Create a page: a child frame that fills the content area *below the shared divider*,
-- hidden until selected. The header (title / description / divider / enable toggle) is
-- owned by the template, so a page only lays out its own body — which starts at the
-- page's TOPLEFT (already below the divider) with no header chrome of its own.
--
--   subtitle : optional description string shown under the title (nil = none).
--   toggle   : optional enable-toggle spec { get = fn()->bool, set = fn(checked) }; when
--              present the shared top-right "Enabled" checkbox is shown and wired to it.
--
-- The page is anchored to the divider's bottom, so it automatically reflows down when a
-- longer (wrapped) description pushes the divider lower. pageDivider is created after this
-- function but before any NewPage *call*, so the upvalue is assigned by the time we anchor.
local function NewPage(name, titleText, subtitle, toggle)
    local p = CreateFrame("Frame", nil, content)
    p:SetPoint("TOPLEFT",     pageDivider, "BOTTOMLEFT",  0, -8)
    p:SetPoint("BOTTOMRIGHT", content,     "BOTTOMRIGHT", 0,  0)
    p:Hide()
    pages[name]       = p
    titles[name]      = titleText
    subtitles[name]   = subtitle
    toggleSpecs[name] = toggle
    return p
end

-- ── Resize grip ───────────────────────────────────────────────────────────────
-- Bottom-right drag handle. The content/page frames overlap this corner but are
-- mouse-transparent (they never call EnableMouse), so this child of the container
-- still receives the clicks.
local grip = CreateFrame("Button", nil, f)
grip:SetSize(16, 16)
grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    SavePlacement()
    RefreshCurrent()
end)

-- ── Reusable flat widgets ───────────────────────────────────────────────────────
-- These are the building blocks every page reuses, themed once here so the whole UI
-- stays consistent (and a future page only has to call these, never hand-roll art).

-- A flat dark button with a gold hover border. SetText/OnClick work as on a normal
-- button (we register a FontString so :SetText routes to it). Returns the button.
local function MakeFlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    if w and h then b:SetSize(w, h) end
    ApplyFlat(b, THEME.panel, true)

    local fs = b:CreateFontString(nil, "OVERLAY")
    ApplyFont(fs, 12)
    fs:SetPoint("CENTER")
    fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    b.label = fs
    -- Set the text DIRECTLY on our FontString rather than via Button:SetText. The
    -- Button:SetFontString + Button:SetText path only renders when the button also has a
    -- font *object* assigned (SetNormalFontObject); with only a SetFont'd FontString it
    -- silently draws nothing — which is exactly why the flat buttons/tabs showed blank.
    -- We drive the label ourselves and override :SetText so callers (e.g.
    -- addBtn:SetText("Update Line")) keep working.
    fs:SetText(text or "")
    b.SetText = function(self, t) self.label:SetText(t or "") end

    -- Gold border + gold text on hover; flat charcoal otherwise.
    b:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        fs:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    end)
    return b
end

-- A small square button showing one raid-target marker icon, used for the quick-insert
-- row above a line's input box. `iconN` is the 1–8 marker number. The caller wires
-- OnClick (to insert the matching {token}). Hover gives an accent border + a tooltip
-- naming the token so the user knows what typing it produces.
local ICON_BTN_SIZE = 20
local function MakeRaidIconButton(parent, iconN, token)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(ICON_BTN_SIZE, ICON_BTN_SIZE)
    ApplyFlat(b, THEME.field, true)

    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT",     b, "TOPLEFT",      2, -2)
    tex:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2,  2)
    tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. iconN)

    b:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(token, THEME.text[1], THEME.text[2], THEME.text[3])
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        GameTooltip:Hide()
    end)
    return b
end

-- A flat single-line edit box (replaces the gold InputBoxTemplate art). Caller wires the
-- OnEnterPressed / OnEscapePressed scripts. Returns the EditBox.
local function MakeFlatEditBox(parent)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    ApplyFlat(e, THEME.field, true)
    ApplyFont(e, 12)
    e:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    e:SetTextInsets(6, 6, 2, 2)
    e:SetAutoFocus(false)
    -- Focus feedback: gold border while typing.
    e:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    e:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    end)
    return e
end

-- A flat MULTILINE text box of fixed height — the Profiles page's export/import share-string
-- boxes. The EditBox lives inside a bare ScrollFrame so its text is CLIPPED to the box: a
-- multiline EditBox otherwise renders ALL its text past its own height, spilling over whatever
-- sits below it (here, the import controls). Mouse wheel scrolls any clipped overflow, and
-- HighlightText()/Ctrl+C still copy the FULL text regardless of what's scrolled into view.
-- Returns the container FRAME; do text ops on its `.edit` field (the inner EditBox).
local function MakeMultilineBox(parent, height)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    ApplyFlat(box, THEME.field, true)
    box:SetHeight(height)
    box:EnableMouse(true)

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT",     box, "TOPLEFT",      5, -4)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -5,  4)

    local edit = CreateFrame("EditBox", nil, scroll)
    ApplyFont(edit, 11)
    edit:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetTextInsets(2, 2, 2, 2)
    edit:SetWidth(1)   -- real width tracked in the scroll frame's OnSizeChanged below
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:HookScript("OnEditFocusGained", function()
        box:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    edit:HookScript("OnEditFocusLost", function()
        box:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    end)
    scroll:SetScrollChild(edit)

    -- Keep the edit as wide as the scroll frame so text wraps to the box width; a multiline
    -- EditBox auto-grows its height to fit content, and the ScrollFrame clips the overflow.
    scroll:SetScript("OnSizeChanged", function(_, w) edit:SetWidth(w) end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, edit:GetHeight() - self:GetHeight())
        local nv = self:GetVerticalScroll() - delta * 18
        if nv < 0 then nv = 0 elseif nv > maxScroll then nv = maxScroll end
        self:SetVerticalScroll(nv)
    end)

    -- Clicking anywhere in the box focuses the edit (its content can be shorter than the box).
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)

    box.edit = edit
    return box
end

-- Reskin a UICheckButton as a flat square box with a solid accent block when checked and a
-- solid red block when unchecked, so an on/off toggle reads at a glance. The checkbox must
-- be created with the BackdropTemplate mixin alongside UICheckButtonTemplate. Degrades
-- gracefully if SetBackdrop is unavailable.
local function StyleCheckbox(cb)
    -- Strip ALL the default box/check art — including the built-in checked texture, which
    -- otherwise draws above our fill and whose show/hide-on-toggle we don't want to fight.
    -- We convey on/off purely by recolouring our own fill below.
    if cb.SetNormalTexture   then cb:SetNormalTexture("")   end
    if cb.SetPushedTexture   then cb:SetPushedTexture("")   end
    if cb.SetHighlightTexture then cb:SetHighlightTexture("") end
    if cb.SetCheckedTexture  then cb:SetCheckedTexture("")  end
    ApplyFlat(cb, THEME.field, true)

    -- A single inset fill block, ALWAYS shown; its COLOUR conveys the state — accent purple
    -- when checked (on), Death Knight red (#C41E3A) when unchecked (off). Drawn at OVERLAY /
    -- top sublevel so neither the flat backdrop (ApplyFlat) nor the check button's own art can
    -- cover it — the earlier ARTWORK/BACKGROUND attempts drew behind those.
    local fill = cb:CreateTexture(nil, "OVERLAY", nil, 7)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetPoint("TOPLEFT",     cb, "TOPLEFT",      3, -3)
    fill:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -3,  3)

    -- Recolour the fill to match the checked state. Changing vertex colour takes effect
    -- immediately, so the on/off colour flips the instant the box is toggled. Exposed so the
    -- CALLER'S OnClick handler and ShowPage can both call it. NOTE: we deliberately do NOT
    -- HookScript("OnClick") here — the caller sets its own OnClick with SetScript afterwards,
    -- which would wipe any hook we add. So the caller must invoke RefreshStateColor itself.
    cb.RefreshStateColor = function()
        local c = cb:GetChecked() and THEME.accent or THEME.offRed
        fill:SetVertexColor(c[1], c[2], c[3])
    end
    cb.RefreshStateColor()
end

-- ── Flat dropdown widget ────────────────────────────────────────────────────────
-- A themed single-select dropdown built from scratch — the project is dependency-free and
-- we deliberately avoid Blizzard's UIDropDownMenu (its own art/taint quirks clash with our
-- flat look). MakeDropdown(parent, width) returns a flat button carrying:
--   dd:SetOptions(list)     -- array of strings to choose from ({} = disabled/empty look)
--   dd:SetValue(text)       -- set the displayed label (active value or a placeholder)
--   dd:SetOnSelect(fn)      -- fn(selectedText) fired when a row is clicked
-- Clicking the button toggles a drop list anchored directly beneath it. The list (and a
-- full-screen click-catcher behind it) live on FULLSCREEN_DIALOG strata so they draw above
-- the DIALOG-strata main window and its siblings. Opening one dropdown closes any other;
-- clicking anywhere off the list closes it (the catcher). An empty option list is inert
-- (dimmed label, clicking does nothing) rather than crashing.
local OPEN_DD   -- module-wide: the dropdown whose list is currently open (or nil)

local function MakeDropdown(parent, width)
    local DD_ROW_H = 22

    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width or 160, 24)
    ApplyFlat(dd, THEME.field, true)
    dd.options = {}

    -- Selected-value / placeholder label (left), clipped short of the arrow.
    local label = dd:CreateFontString(nil, "OVERLAY")
    ApplyFont(label, 12)
    label:SetPoint("LEFT",  dd, "LEFT",   8, 0)
    label:SetPoint("RIGHT", dd, "RIGHT", -20, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    dd.labelFS = label

    -- Down-arrow affordance on the right (plain "v" — no bundled glyph needed).
    local arrow = dd:CreateFontString(nil, "OVERLAY")
    ApplyFont(arrow, 10)
    arrow:SetPoint("RIGHT", dd, "RIGHT", -7, 0)
    arrow:SetText("v")
    arrow:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])

    -- Full-screen click-catcher: closes the list when the user clicks off it. Parented to
    -- dd so it hides automatically if the page/dropdown is hidden; raised just below the
    -- list so the list's own rows still receive their clicks first.
    local catcher = CreateFrame("Button", nil, dd)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(dd:GetFrameLevel() + 10)
    catcher:SetAllPoints(UIParent)
    catcher:Hide()

    -- The drop list panel, anchored flush under the button and stretched to its width.
    local list = CreateFrame("Frame", nil, dd, "BackdropTemplate")
    list:SetPoint("TOPLEFT",  dd, "BOTTOMLEFT",  0, -2)
    list:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetFrameLevel(catcher:GetFrameLevel() + 10)
    ApplyFlat(list, THEME.panel, true)
    list:Hide()

    local rowFrames = {}

    local function CloseList()
        list:Hide()
        catcher:Hide()
        if OPEN_DD == dd then OPEN_DD = nil end
    end
    dd.CloseList = CloseList

    -- (Re)draw one option row per entry in dd.options, reusing a pooled frame set.
    local function RebuildRows()
        for _, r in ipairs(rowFrames) do r:Hide() end
        local opts = dd.options
        for i, text in ipairs(opts) do
            local r = rowFrames[i]
            if not r then
                r = CreateFrame("Button", nil, list)
                r:SetHeight(DD_ROW_H)
                local hl = r:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 0.20)
                local rfs = r:CreateFontString(nil, "OVERLAY")
                ApplyFont(rfs, 12)
                rfs:SetPoint("LEFT",  r, "LEFT",   8, 0)
                rfs:SetPoint("RIGHT", r, "RIGHT", -6, 0)
                rfs:SetJustifyH("LEFT")
                rfs:SetWordWrap(false)
                rfs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                r.fs = rfs
                r:SetScript("OnEnter", function(self)
                    self.fs:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                end)
                r:SetScript("OnLeave", function(self)
                    self.fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                end)
                rowFrames[i] = r
            end
            -- Reposition every refresh (the option list length can change under us).
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT",  list, "TOPLEFT",   2, -2 - (i - 1) * DD_ROW_H)
            r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -2, -2 - (i - 1) * DD_ROW_H)
            r.fs:SetText(text)
            local capText = text   -- capture per-row so the closure fires with the right value
            r:SetScript("OnClick", function()
                CloseList()
                if dd.onSelect then dd.onSelect(capText) end
            end)
            r:Show()
        end
        list:SetHeight(math.max(#opts * DD_ROW_H + 4, 4))
    end

    local function OpenListFrame()
        if #dd.options == 0 then return end          -- empty → inert
        if OPEN_DD and OPEN_DD ~= dd then OPEN_DD.CloseList() end
        RebuildRows()
        catcher:Show()
        list:Show()
        OPEN_DD = dd
    end

    catcher:SetScript("OnClick", CloseList)
    dd:SetScript("OnClick", function()
        if list:IsShown() then CloseList() else OpenListFrame() end
    end)
    dd:SetScript("OnEnter", function(self)
        if #self.options > 0 then
            self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        end
    end)
    dd:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    end)

    -- Public API -----------------------------------------------------------------
    function dd:SetOptions(l)
        self.options = l or {}
        self.empty = (#self.options == 0)
        if list:IsShown() then RebuildRows() end
    end
    function dd:SetValue(text)
        self.labelFS:SetText(text or "")
        -- Dim the label when there's nothing to pick (or a placeholder is showing on an
        -- empty list) so a disabled dropdown reads as inactive.
        local c = self.empty and THEME.textDim or THEME.text
        self.labelFS:SetTextColor(c[1], c[2], c[3])
    end
    function dd:SetOnSelect(fn) self.onSelect = fn end

    return dd
end

-- ── Shared header widgets (description + divider + enable toggle) ────────────────
-- Built once here (now that StyleCheckbox exists) and reused by every page. Assigned to
-- the upvalues forward-declared up top so ShowPage/NewPage can drive them. Created before
-- the first NewPage call, so pages can anchor to pageDivider.

-- Description line, pinned just under the title. Word-wrap stays ON so it auto-grows in
-- height; everything below hangs off its bottom, which is how the layout reflows for a
-- two-/three-line description at narrow widths.
pageSubtitle = content:CreateFontString(nil, "OVERLAY")
ApplyFont(pageSubtitle, 12)
pageSubtitle:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
-- Left x-offset MUST match pageTitle's (4) so the description lines up flush under the
-- title; the right inset can differ (the line just wraps within it).
pageSubtitle:SetPoint("TOPLEFT",  content, "TOPLEFT",   4, -28)
pageSubtitle:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -28)
pageSubtitle:SetJustifyH("LEFT")

-- Horizontal rule, hung off the description's bottom (so it sits BELOW the text and drops
-- with it). The X offsets push the ends out to the content edges from the inset subtitle
-- (left −4 → x=0, right +8 → content right); height 1 = a crisp 1px line.
pageDivider = content:CreateTexture(nil, "ARTWORK")
pageDivider:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
pageDivider:SetPoint("TOPLEFT",  pageSubtitle, "BOTTOMLEFT",  -4, -6)
pageDivider:SetPoint("TOPRIGHT", pageSubtitle, "BOTTOMRIGHT",  8, -6)
pageDivider:SetHeight(1)

-- Top-right "Enabled" toggle, aligned with the title row at the far right of the content
-- area (opposite the title). Label sits to the LEFT so the box hugs the corner. ShowPage
-- shows/syncs it per page; this OnClick routes to whichever page's toggle spec is current.
enableCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate,BackdropTemplate")
enableCheck:SetSize(22, 22)
enableCheck:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)
StyleCheckbox(enableCheck)
enableCheck:SetScript("OnClick", function(self)
    if currentToggle and currentToggle.set then currentToggle.set(self:GetChecked()) end
    self.RefreshStateColor()  -- flip purple(on)/red(off) immediately on click
end)

enableLabel = content:CreateFontString(nil, "OVERLAY")
ApplyFont(enableLabel, 12)
enableLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
enableLabel:SetPoint("RIGHT", enableCheck, "LEFT", -4, 0)
enableLabel:SetText("Enabled")

-- ── Master switch (title bar) ───────────────────────────────────────────────────
-- A single override in the title bar (next to the brand, so it's reachable from any page)
-- that disables EVERY feature at once — handy for a quick "turn it all off" or on a
-- non-warlock character. It does NOT change the per-feature toggles, so turning it back on
-- restores each feature to its own saved setting (see WQ.SetMasterEnabled / FeatureOn in the
-- core). Same flat checkbox as the page toggles: accent purple = on, red = off. Created here
-- (after StyleCheckbox) but anchored into the title bar built earlier.
local masterLabel = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(masterLabel, 12)
masterLabel:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
masterLabel:SetText("Enabled")

-- Minimap-icon toggle label — created now (before positioning) so both toggles can be centred
-- together as ONE group. Checked = the minimap button is SHOWN. Per-character (the button's
-- angle + hidden flag live in CharState via WQ.Is/SetMinimapHidden, defined with the button).
local minimapLabel = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(minimapLabel, 12)
minimapLabel:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
minimapLabel:SetText("Minimap Icon")

-- Centre the WHOLE group (Enabled label + box + gap + Minimap Icon label + box) on the title
-- bar: offset the first label left of the bar's CENTER by half the group's total width so the
-- pair straddles the middle. Anchoring to the bar's CENTER keeps it centred as the window resizes.
local GROUP_GAP = 28   -- space between the two toggles
local groupW = masterLabel:GetStringWidth() + 6 + 20 + GROUP_GAP
             + minimapLabel:GetStringWidth() + 6 + 20
masterLabel:SetPoint("LEFT", titleBar, "CENTER", -groupW / 2, 0)

local masterCheck = CreateFrame("CheckButton", nil, titleBar, "UICheckButtonTemplate,BackdropTemplate")
masterCheck:SetSize(20, 20)
masterCheck:SetPoint("LEFT", masterLabel, "RIGHT", 6, 0)
StyleCheckbox(masterCheck)
masterCheck:SetScript("OnClick", function(self)
    if WQ.SetMasterEnabled then WQ.SetMasterEnabled(self:GetChecked()) end
    self.RefreshStateColor()  -- flip purple(on)/red(off) immediately on click
end)
masterCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Enabled", THEME.text[1], THEME.text[2], THEME.text[3])
    GameTooltip:AddLine("Turns every feature off (or back on) at once.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Your individual feature toggles are kept.", 0.55, 0.55, 0.55, true)
    GameTooltip:Show()
end)
masterCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The minimap-icon toggle chains to the RIGHT of the Enabled box, completing the centred group.
minimapLabel:SetPoint("LEFT", masterCheck, "RIGHT", GROUP_GAP, 0)

local minimapCheck = CreateFrame("CheckButton", nil, titleBar, "UICheckButtonTemplate,BackdropTemplate")
minimapCheck:SetSize(20, 20)
minimapCheck:SetPoint("LEFT", minimapLabel, "RIGHT", 6, 0)
StyleCheckbox(minimapCheck)
minimapCheck:SetScript("OnClick", function(self)
    if WQ.SetMinimapHidden then WQ.SetMinimapHidden(not self:GetChecked()) end
    self.RefreshStateColor()  -- flip purple(on)/red(off) immediately on click
end)
minimapCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Minimap icon", THEME.text[1], THEME.text[2], THEME.text[3])
    GameTooltip:AddLine("Show the WarlockQol button on the minimap.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
minimapCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Sync both title-bar checkboxes to their saved state each time the window opens (the DB is
-- ready by then). HookScript so we don't clobber other OnShow behaviour.
f:HookScript("OnShow", function()
    local on = WQ.IsMasterEnabled and WQ.IsMasterEnabled()
    masterCheck:SetChecked(on and true or false)
    masterCheck.RefreshStateColor()

    local shown = not (WQ.IsMinimapHidden and WQ.IsMinimapHidden())
    minimapCheck:SetChecked(shown)
    minimapCheck.RefreshStateColor()
end)

-- ── Reusable line-list widget ──────────────────────────────────────────────────
--
-- Both feature pages need the same "scrollable list of lines + add box + edit/delete
-- buttons" control, so we build it once here. `accessors` supplies the data:
--   get()             -> the table of lines to display
--   add(text)         -> truthy if the line was added (used to clear the input)
--   update(idx, text) -> truthy if the line at idx was updated (edit-in-place)
--   delete(idx)       -> remove the line at idx
--   help1             -> a single grey help string shown at the very bottom
-- Each row has a pencil (edit) button and an X (delete) button. Clicking the pencil
-- loads that line into the input box and flips the Add button to "Update Line".
-- Returns a Refresh() function the caller can wire to page-show / external events.

local function BuildLineList(parent, yTop, accessors)
    local rows = {}

    -- Forward declarations: the row buttons are created before the input box, but
    -- their click handlers need to reference the input box / Add button / edit state.
    -- Lua only captures locals that already exist where a closure is defined, so these
    -- must be declared up front (assigned further down) to be captured as upvalues.
    local inputBox, addBtn, cancelBtn
    local editingIndex   -- nil = adding a new line; otherwise the index being edited
    local editingList    -- the lines table the edit began in (to detect a tab switch)
    local CancelEdit     -- resets back to "add" mode (defined once inputBox/addBtn exist)
    local EnterEditMode  -- loads a line into the box + switches to "update" mode

    -- ScrollFrame with FauxScrollFrameTemplate: a standard scrollbar where we
    -- manage the visible content ourselves (the row pool below).
    -- CONTENT_L / CONTENT_R are the single left/right margins shared by EVERY element on a
    -- page (the list, the input box + Add button, the quick-insert row, the help lines — and
    -- the summon page's demon-name + tab layout), so all page content lines up in one clean
    -- column: left flush under the header title (which sits at +4) and right at a fixed inset
    -- wide enough that the list scrollbar never overlaps the row Edit/X buttons. The input
    -- box sits at the same width directly beneath the rows rather than jutting past them.
    local CONTENT_L, CONTENT_R = 8, -32
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     parent, "TOPLEFT",     CONTENT_L, yTop)
    -- Bottom leaves room only for the compact control stack below: one help line, the input
    -- row, and the raid-marker quick-insert row. The list extends as far down as possible so
    -- there's no dead space between the last row and the controls.
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", CONTENT_R, 98)

    -- Empty-state message, drawn where the rows would be when the list has ZERO entries
    -- (fresh install / a demon or feature with no lines yet). Genuine italics via the
    -- bundled italic face, dim/muted. Distinct from the per-row "(empty line…)" marker,
    -- which is for a blank entry *within* a non-empty list. Hidden whenever there's ≥1 line.
    local emptyMsg = parent:CreateFontString(nil, "OVERLAY")
    ApplyFontItalic(emptyMsg, 12)
    emptyMsg:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    emptyMsg:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 4, -6)
    emptyMsg:SetText("No lines added yet...")
    emptyMsg:Hide()

    -- Redraw the visible rows to match the current data + scroll offset.
    local function Refresh()
        local lines  = accessors.get() or {}
        local total  = #lines

        -- Empty list → show the italic placeholder, no rows; otherwise hide it.
        if total == 0 then emptyMsg:Show() else emptyMsg:Hide() end

        -- Abandon an in-progress edit if its target is gone — the user switched to a
        -- different list (e.g. another pet tab) or the row no longer exists — so we
        -- never write the edited text onto the wrong line.
        if editingIndex and (lines ~= editingList or editingIndex > total) then
            CancelEdit()
        end

        -- How many rows fit the list's current height (it grows when the user makes
        -- the frame taller), capped by the row pool we created up front.
        local visible = math.floor(scrollFrame:GetHeight() / ROW_H)
        if visible < 1 then visible = 1 end
        if visible > #rows then visible = #rows end

        local offset = FauxScrollFrame_GetOffset(scrollFrame)
        FauxScrollFrame_Update(scrollFrame, total, visible, ROW_H)

        for i, row in ipairs(rows) do
            local idx = offset + i  -- actual index into the lines table
            if i <= visible and idx <= total then
                -- Defensive display: the add/update helpers in the core trim and reject
                -- empty/whitespace text, so a blank entry can't be created through the
                -- UI — but a genuinely empty/whitespace string or a nil "hole" left in
                -- the saved array by older data or a hand-edited SavedVariables file
                -- would otherwise render as a mysteriously blank row (SetText(nil/"")
                -- draws nothing). Surface it as a dim, clickable-to-remove marker so the
                -- user can see and delete it rather than hunting an invisible line.
                row.num:SetText(idx .. ".")  -- ordinal = absolute position in the list
                local val = lines[idx]
                if val == nil or (type(val) == "string" and val:match("^%s*$")) then
                    row.text:SetText("|cff666666(empty line — click X to remove)|r")
                else
                    row.text:SetText(RenderIconTokens(val))
                end
                -- Capture idx in a local so the closure uses the right value
                -- (Lua closures capture variables by reference, not by value).
                local capturedIdx = idx
                row.delBtn:SetScript("OnClick", function()
                    -- Deleting shifts indices, which would leave a pending edit
                    -- pointing at the wrong line — cancel any edit first.
                    CancelEdit()
                    accessors.delete(capturedIdx)
                    Refresh()
                end)
                row.editBtn:SetScript("OnClick", function()
                    -- Load this line into the input box and switch to "update" mode.
                    EnterEditMode(capturedIdx, lines)
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    scrollFrame:SetScript("OnVerticalScroll", function(self, value)
        FauxScrollFrame_OnVerticalScroll(self, value, ROW_H, Refresh)
    end)

    -- First-open fix: the page (and this scroll frame) has no resolved on-screen size at
    -- the moment OnPageShow runs its synchronous Refresh — the very first time the page is
    -- shown the layout pass hasn't happened yet, so GetHeight()/GetWidth() read ~0. That
    -- makes the visible-row count wrong AND leaves the row FontStrings blank (a
    -- non-wrapping FontString stretched across a 0-width row clips to nothing). Symptom:
    -- correct row count but empty text until a later Refresh (tab switch / resize) fires.
    -- Defer a Refresh one frame via C_Timer so it re-measures after layout; fall back to an
    -- immediate Refresh if C_Timer is somehow unavailable.
    scrollFrame:SetScript("OnShow", function()
        if C_Timer and C_Timer.After then C_Timer.After(0, Refresh) else Refresh() end
    end)

    -- Row pool: create ROW_POOL frames once and reuse them. Parent the rows to the
    -- page, NOT the scroll frame — a FauxScrollFrame has no scroll child, so its
    -- content-clip region is empty and anything parented to it gets clipped away.
    -- We parent to the page and merely *anchor* the rows relative to scrollFrame.
    for i = 1, ROW_POOL do
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT",  scrollFrame, "TOPLEFT",  0, -(i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 0, -(i - 1) * ROW_H)

        -- Flat alternating row fills (charcoal vs. near-black) to aid readability.
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if i % 2 == 0 then
            bg:SetColorTexture(0.10, 0.10, 0.10, 0.9)
        else
            bg:SetColorTexture(0.07, 0.07, 0.07, 0.9)
        end

        -- Ordinal number column. Right-aligned in a fixed-width box so multi-digit
        -- numbers stay aligned and a long line truncating on the right never shoves the
        -- number around. The actual value is set per-refresh from the line's position.
        local num = row:CreateFontString(nil, "OVERLAY")
        ApplyFont(num, 12)
        num:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
        num:SetPoint("LEFT", row, "LEFT", 6, 0)
        num:SetWidth(22)
        num:SetJustifyH("RIGHT")
        row.num = num

        -- The line text, between the number column and the Edit/X buttons.
        local text = row:CreateFontString(nil, "OVERLAY")
        ApplyFont(text, 12)
        text:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
        text:SetPoint("LEFT",  num, "RIGHT", 6,   0)
        text:SetPoint("RIGHT", row, "RIGHT", -74, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)  -- keep each line on one row; long lines truncate
        row.text = text

        -- Small X button to delete that line. The OnClick is (re)assigned in
        -- Refresh so it captures the correct index for the row's current contents.
        local delBtn = MakeFlatButton(row, "X", 24, 20)
        delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.delBtn = delBtn

        -- "Edit" button just left of the X — loads this row's line into the input box for
        -- in-place editing. (Plain text label for now; an icon may replace it later.) Its
        -- OnClick is assigned in Refresh so it captures the row's current index.
        local editBtn = MakeFlatButton(row, "Edit", 40, 20)
        editBtn:SetPoint("RIGHT", delBtn, "LEFT", -2, 0)
        row.editBtn = editBtn

        row:Hide()  -- hidden until Refresh populates it
        rows[i] = row
    end

    -- Input box + Add/Update button. Flat-themed; SetAutoFocus(false) stops it stealing
    -- keyboard focus on open. (inputBox/addBtn were forward-declared above so the row
    -- buttons could capture them.)
    inputBox = MakeFlatEditBox(parent)
    inputBox:SetHeight(24)
    inputBox:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", CONTENT_L, 38)
    inputBox:SetMaxLetters(255)
    -- (right edge anchored to the Add button below, so it stretches with the frame)

    -- Enter edit mode for line `idx` of `list`: load it into the box, focus, flip the Add
    -- button to "Update Line", reveal the Cancel button, and re-anchor the box's right edge
    -- to Cancel's left so the two don't overlap.
    EnterEditMode = function(idx, list)
        editingIndex = idx
        editingList  = list
        inputBox:SetText(list[idx] or "")
        inputBox:SetFocus()
        addBtn:SetText("Update Line")
        cancelBtn:Show()
        inputBox:SetPoint("RIGHT", cancelBtn, "LEFT", -10, 0)
    end

    -- Leave edit mode: clear the box, restore the "Add Line" button, hide Cancel, and snap
    -- the box's right edge back to the Add button (reclaiming the width Cancel occupied).
    CancelEdit = function()
        editingIndex = nil
        editingList  = nil
        inputBox:SetText("")
        addBtn:SetText("Add Line")
        cancelBtn:Hide()
        inputBox:SetPoint("RIGHT", addBtn, "LEFT", -10, 0)
    end

    -- Expose this list's CancelEdit on the page frame so ShowPage (page nav) and the main
    -- frame's OnHide (window close) can abandon an in-progress edit when the user leaves —
    -- more reliable than a child OnHide, which doesn't fire when an ancestor is hidden. So
    -- returning to a page always lands in the clean "Add Line" state.
    parent.CancelEdit = CancelEdit

    -- Submit the input box: update the line being edited, or add a new one.
    local function Submit()
        if editingIndex then
            if accessors.update(editingIndex, inputBox:GetText()) then
                CancelEdit()
                Refresh()
            end
        else
            if accessors.add(inputBox:GetText()) then
                inputBox:SetText("")
                Refresh()
            end
        end
    end
    inputBox:SetScript("OnEnterPressed", Submit)  -- Enter submits
    inputBox:SetScript("OnEscapePressed", function()  -- Esc cancels an edit / clears
        CancelEdit()
        inputBox:ClearFocus()
    end)

    addBtn = MakeFlatButton(parent, "Add Line", 90, 24)
    addBtn:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", CONTENT_R, 38)  -- same right edge as the rows
    addBtn:SetScript("OnClick", Submit)  -- ...and so does the button

    -- Cancel button: shown only while editing an existing line (EnterEditMode reveals it,
    -- CancelEdit hides it). Sits just left of Add/Update; clicking abandons the edit and
    -- returns to the "Add Line" state. Hidden by default so the normal add flow is uncluttered.
    cancelBtn = MakeFlatButton(parent, "Cancel", 70, 24)
    cancelBtn:SetPoint("BOTTOMRIGHT", addBtn, "BOTTOMLEFT", -6, 0)
    cancelBtn:SetScript("OnClick", function()
        CancelEdit()
        inputBox:ClearFocus()
    end)
    cancelBtn:Hide()

    -- Stretch the input box from the left margin to the Add button, so it widens
    -- along with the frame instead of leaving a fixed gap on the right. (EnterEditMode
    -- temporarily re-anchors this right edge to the Cancel button while editing.)
    inputBox:SetPoint("RIGHT", addBtn, "LEFT", -10, 0)

    -- Raid-marker quick-insert row, just above the input box. Clicking a marker drops its
    -- {token} into the box so the user needn't type e.g. "{star}" by hand. We focus the
    -- box first (only if it isn't already focused, to preserve the cursor position for a
    -- mid-line insert) then Insert() at the cursor. The box keeps the raw {token} text —
    -- an EditBox can't render the icon inline — while the list preview and chat show the
    -- real icon (see RenderIconTokens).
    local lastQuick   -- rightmost button in the quick-insert row (icons, then placeholders)
    for i, spec in ipairs(RAID_ICON_ORDER) do
        local ib = MakeRaidIconButton(parent, spec.n, spec.token)
        ib:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT",
            CONTENT_L + (i - 1) * (ICON_BTN_SIZE + 4), 70)
        ib:SetScript("OnClick", function()
            if not inputBox:HasFocus() then inputBox:SetFocus() end
            inputBox:Insert(spec.token)
        end)
        lastQuick = ib
    end

    -- Page-specific placeholder buttons ({demonName}, {targetName}, {location}), continuing
    -- the quick-insert row to the right of the raid markers. `accessors.placeholders` is the
    -- list of tokens this feature supports (omitted / empty on pages with none, e.g. Ritual
    -- of Souls). Each is a flat text button sized to its label; clicking inserts the token
    -- the same way the icon buttons do.
    for _, token in ipairs(accessors.placeholders or {}) do
        local pb = MakeFlatButton(parent, token, 10, ICON_BTN_SIZE)
        pb:SetWidth(pb.label:GetStringWidth() + 16)
        pb:SetPoint("BOTTOMLEFT", lastQuick, "BOTTOMRIGHT", 8, 0)
        pb:SetScript("OnClick", function()
            if not inputBox:HasFocus() then inputBox:SetFocus() end
            inputBox:Insert(token)
        end)
        lastQuick = pb
    end

    -- Single feature-specific help line pinned to the very bottom (the old second help line
    -- and the shared raid-icon tip were removed to close up the dead space below the list).
    local h1 = parent:CreateFontString(nil, "OVERLAY")
    ApplyFont(h1, 11)
    h1:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", CONTENT_L, 14)
    h1:SetText(accessors.help1 or "")

    return Refresh
end

-- Open Blizzard's macro UI (same as typing /macro). It lives in an on-demand addon, so
-- load it first, then toggle the panel. Lets the user eyeball the macros we created.
local function OpenMacroUI()
    if not MacroFrame then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then load("Blizzard_MacroUI") end
    end
    if MacroFrame then
        if MacroFrame:IsShown() then HideUIPanel(MacroFrame) else ShowUIPanel(MacroFrame) end
    end
end

-- (Macro creation is no longer a per-page button. A single "Create Macros" button pinned
-- to the sidebar bottom builds every feature's macros in one click via WQ.CreateAllMacros;
-- see the sidebar section near the end of the file. Macro resets likewise live only on the
-- dedicated Reset page under Settings.)

-- (The per-page "Enabled" checkbox was retired in favour of the single shared toggle in
-- the page header — see ShowPage + the shared header widgets above. Pages opt in by
-- passing a { get, set } toggle spec to NewPage.)

-- ── Reset confirmations ─────────────────────────────────────────────────────────
--
-- preferredIndex = 3 uses a high-index popup frame to avoid UI taint.

-- Reset page → "Reset Macros": clears every macro we made (demon + ritual + souls).
StaticPopupDialogs["WARLOCK_QOL_TBC_RESET_MACROS"] = {
    text = "Remove ALL macros WarlockQol created?\n\nYour saved lines, feature toggles, and profiles are kept.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() if WQ.ResetMacros then WQ.ResetMacros() end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Reset page → "Hard Reset": ACCOUNT-WIDE wipe back to a fresh install (all profiles, every
-- character's settings, and the window geometry — plus this character's macros). Afterwards
-- re-sync the always-visible master switch (forced back ON) — the line-list/Profiles pages
-- refresh lazily on their next OnPageShow.
StaticPopupDialogs["WARLOCK_QOL_TBC_HARD_RESET"] = {
    text = "Hard reset EVERYTHING?\n\nThis wipes the whole addon back to a fresh install — ALL profiles, every character's lines, toggles and settings, and this character's macros. Nothing is kept.\n\nThis cannot be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        if WQ.HardReset and WQ.HardReset() then
            local on = WQ.IsMasterEnabled and WQ.IsMasterEnabled()
            masterCheck:SetChecked(on and true or false)
            masterCheck.RefreshStateColor()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ── General (home) page ─────────────────────────────────────────────────────────
-- The old centred button array is gone — the left nav is now the way to reach features,
-- so this page is just a welcome/overview.

do
    local home = NewPage("home", "General")

    -- Flavour epigraph: an italic, dimmed Gul'dan quote at the top of the page. Uses the
    -- bundled PT Sans Italic face; the welcome body below anchors to its bottom so the two
    -- reflow together.
    local quote = home:CreateFontString(nil, "OVERLAY")
    ApplyFontItalic(quote, 13)
    quote:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    quote:SetPoint("TOPLEFT",  home, "TOPLEFT",   6, -10)
    quote:SetPoint("TOPRIGHT", home, "TOPRIGHT", -16, -10)
    quote:SetJustifyH("LEFT")
    quote:SetSpacing(5)
    quote:SetText(
        "\"A true warlock doesn't need to summon infernal horrors when they are the " ..
        "infernal horror.\"\n— Gul'dan")

    local body = home:CreateFontString(nil, "OVERLAY")
    ApplyFont(body, 13)
    body:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    body:SetPoint("TOPLEFT",  quote, "BOTTOMLEFT",  0, -16)
    body:SetPoint("TOPRIGHT", quote, "BOTTOMRIGHT", 0, -16)
    body:SetJustifyH("LEFT")
    body:SetSpacing(5)
    body:SetText(
        "WarlockQol (TBC) adds quality-of-life tools for Warlocks — flavour chat lines for " ..
        "your demon summons and rituals, automatic Soulstone and Banish announcements, and " ..
        "raid HUDs for cooldowns and missing consumables.\n\n" ..
        "Most chat features run from one-click macros the addon builds for you.\n\n" ..
        "|cff8788eeImportant!|r Remember to drag/bind your macros to action bars before use. " ..
        "You can access the setup wizard once more from the |cff8788eereset|r option on the " ..
        "side-menu.\n\n" ..
        "A default profile has been created for you. You can create multiple profiles along " ..
        "with import/exporting from other characters/users.\n\n" ..
        "Enjoy!\n\n" ..
        "|cff8788eePick a feature from the side-menu to get started!|r\n\n" ..
        "Re-open this window anytime with command |cff8788ee/wq|r or with the minimap icon.")
end

-- ── Demon Summon Lines page (fully-converted reference) ─────────────────────────

do
    local summon = NewPage("summon", "Demon Summoning",
        "Add individual summoning lines to each demon, a random line is said in /say when the cast begins.",
        { get = WQ.IsPetEnabled, set = WQ.SetPetEnabled })

    local selectedFamily = "Succubus"

    -- Forward declarations: the tab buttons' OnClick and the page refresh both
    -- reference each other, so declare the upvalues before they're assigned.
    local refreshSummon
    local petNameLabel
    local familyTabs = {}   -- family -> tab button, so refresh can highlight the active one

    -- Demon selector sub-tabs, one per family, centred across the page top. (The page
    -- already starts below the shared header/divider, so the tabs sit at the page top.)
    -- Flat-themed with the active family shown in the accent colour (ElvUI sub-tab style).
    --
    -- The tab WIDTH is adaptive, not fixed: the family list can grow (it went 5 → 6 with
    -- the Incubus), so a hardcoded width would overflow the content column at the minimum
    -- window size. LayoutTabs() divides the line list's column width among #PET_FAMILIES
    -- tabs (min-clamped, shrinking the label font when the tabs get narrow)
    -- and left-aligns the row to the content margin. It's re-run on every refresh, so it
    -- also reflows live as the window is resized.
    local TAB_GAP, TAB_Y = 4, -8
    local TAB_MIN_W = 56
    local n = #WQ.PET_FAMILIES
    for i, family in ipairs(WQ.PET_FAMILIES) do
        local btn = MakeFlatButton(summon, family, TAB_MIN_W, 22)
        btn:SetScript("OnClick", function()
            selectedFamily = family
            refreshSummon()
        end)
        familyTabs[family] = btn
    end

    -- Size + position the tab row for the current window width. Width is derived from the
    -- container (f:GetWidth() minus the sidebar + paddings) rather than the page's own
    -- GetWidth(), because f has an explicit size so this reads correctly even on the very
    -- first show (before the page's anchored width has resolved).
    local function LayoutTabs()
        local contentW = f:GetWidth() - (SIDEBAR_W + PAD * 3)   -- see content-frame anchors
        -- Fill the SAME column the line list occupies below: from the shared content left
        -- margin (8) to the list's right gutter (32), so the tab row lines up flush above
        -- the rows at any window width (no max clamp — the tabs grow with the list).
        local avail = contentW - 8 - 32
        local tabW  = math.floor((avail - (n - 1) * TAB_GAP) / n)
        if tabW < TAB_MIN_W then tabW = TAB_MIN_W end
        -- Narrow tabs get a slightly smaller label so the longest names (Voidwalker,
        -- Felhunter) don't clip — especially under the wider stock fallback font.
        local fontSize = (tabW >= 74) and 12 or 11
        local step = tabW + TAB_GAP
        for i, family in ipairs(WQ.PET_FAMILIES) do
            local btn = familyTabs[family]
            btn:SetWidth(tabW)
            ApplyFont(btn.label, fontSize)
            -- Left-anchor the row at the content margin (8) and chain each tab rightward so
            -- it shares the line list's left edge instead of floating centred.
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", summon, "TOPLEFT", 8 + (i - 1) * step, TAB_Y)
        end
    end
    LayoutTabs()  -- initial sizing (refreshSummon re-runs it on show / resize)

    -- Highlight the active family tab in the accent colour; leave the rest flat. We
    -- override the hover handlers' leave-colour for the selected tab so it stays accent-
    -- coloured off-hover.
    local function HighlightTabs()
        for fam, btn in pairs(familyTabs) do
            if fam == selectedFamily then
                btn:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                btn.label:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                btn:SetScript("OnLeave", function(self)
                    self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                    self.label:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                end)
            else
                btn:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
                btn.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                btn:SetScript("OnLeave", function(self)
                    self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
                    self.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                end)
            end
        end
    end

    -- (Macro creation is no longer a per-page button — the single "Create Macros" button
    -- pinned to the sidebar bottom builds every feature's macros at once. See the sidebar
    -- section near the end of the file. The demon-name label + list sit directly under the
    -- tab row now that there's no Create button to clear.)

    -- Demon name status label (below the tab row). Left x is aligned with the LINE TEXT
    -- column of the list below — the list's left margin (8) plus its number column
    -- (num inset 6 + width 22 + gap 6 = 34) → 42 — so "Known as: <name>" sits directly
    -- above the first line rather than jutting out to its left.
    petNameLabel = summon:CreateFontString(nil, "OVERLAY")
    ApplyFont(petNameLabel, 12)
    petNameLabel:SetPoint("TOPLEFT", summon, "TOPLEFT", 42, -38)

    local refreshList = BuildLineList(summon, -58, {
        -- Read the active profile's per-family pool. WQ.ActiveProfile() is nil pre-login
        -- (the window only opens after PLAYER_LOGIN, but guard defensively); BuildLineList
        -- treats a nil return as an empty list, so no crash if it ever races login.
        get    = function()
            local prof = WQ.ActiveProfile()
            return prof and prof.lines[selectedFamily]
        end,
        add    = function(text) return WQ.AddLine(selectedFamily, text) end,
        update = function(idx, text) return WQ.UpdateLine(selectedFamily, idx, text) end,
        delete = function(idx)  WQ.DeleteLine(selectedFamily, idx) end,
        placeholders = { "{demonName}" },
        help1  = "|cff8788eeUse |r|cffaaaaaa{demonName}|r|cff8788ee as a placeholder for your demon's name|r",
    })

    -- Page refresh = re-size/centre the tab row (handles live resize) + highlight the
    -- active tab + redraw the list + update the demon-name label. (The Enabled toggle is
    -- synced by ShowPage via the page's toggle spec.)
    refreshSummon = function()
        LayoutTabs()
        HighlightTabs()
        refreshList()
        -- Pet names are PER-CHARACTER now (they live on the char's state, not the shared
        -- profile), so read them off WQ.CharState(). Nil-guard as above.
        local char = WQ.CharState()
        local petName = char and char.petNames[selectedFamily]
        if petName then
            petNameLabel:SetText("|cff00ff00Known as: " .. petName .. "|r")
        else
            petNameLabel:SetText("|cffff8800Name unknown — summon demon to detect|r")
        end
    end

    summon.OnPageShow = refreshSummon
    -- Exposed so Warlock_Qol_Tbc.lua can refresh us after UNIT_PET detects a pet name.
    WQ.RefreshUI = refreshSummon
end

-- ── Ritual of Summoning page ──────────────────────────────────────────────────

do
    local ritual = NewPage("ritual", "Ritual of Summoning",
        "Add individual summoning lines, a random line is announced to your party/raid when the cast begins.",
        { get = WQ.IsRitualEnabled, set = WQ.SetRitualEnabled })

    -- (Macro creation is the single "Create Macros" button in the sidebar bottom now — no
    -- per-page Create button, so the list starts right under the header like the soulstone page.)

    local refreshRitual = BuildLineList(ritual, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.ritualLines end,
        add    = function(text) return WQ.AddRitualLine(text) end,
        update = function(idx, text) return WQ.UpdateRitualLine(idx, text) end,
        delete = function(idx)  WQ.DeleteRitualLine(idx) end,
        placeholders = { "{targetName}", "{location}" },
        help1  = "|cff8788eePlaceholders: |r|cffaaaaaa{targetName}|r|cff8788ee (target) and |r|cffaaaaaa{location}|r|cff8788ee (your zone)|r",
    })

    -- The Enabled toggle is synced by ShowPage; OnPageShow just redraws the list.
    ritual.OnPageShow = refreshRitual
end

-- ── Ritual of Souls page ──────────────────────────────────────────────────────
--
-- Macro-based like Ritual of Summoning, but said in /say with no placeholders.

do
    local souls = NewPage("souls", "Ritual of Souls",
        "Add individual summoning lines, a random line is said in /say when the cast begins.",
        { get = WQ.IsSoulsEnabled, set = WQ.SetSoulsEnabled })

    -- (Macro creation is the single "Create Macros" button in the sidebar bottom now — no
    -- per-page Create button, so the list starts right under the header like the soulstone page.)

    local refreshSouls = BuildLineList(souls, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.soulsLines end,
        add    = function(text) return WQ.AddSoulsLine(text) end,
        update = function(idx, text) return WQ.UpdateSoulsLine(idx, text) end,
        delete = function(idx)  WQ.DeleteSoulsLine(idx) end,
        help1  = "|cff8788eeA random line is said in |r|cffaaaaaa/say|r|cff8788ee when you cast Ritual of Souls|r",
    })

    -- The Enabled toggle is synced by ShowPage; OnPageShow just redraws the list.
    souls.OnPageShow = refreshSouls
end

-- ── Soulstone Announcement page ───────────────────────────────────────────────
--
-- Unlike the others this feature has no macro: it fires automatically from the combat
-- log when a Soulstone Resurrection is cast (see Warlock_Qol_Tbc.lua). Its Enabled toggle (in
-- the shared header) persists and (un)registers the combat-log listener via the core's
-- SetSoulstoneEnabled, so the page just needs the line list — no Create/Reset row.

do
    local soulstone = NewPage("soulstone", "Soulstone Announcement",
        "When any soulstone is detected (by any warlock in group), a random line is announced to your party/raid.",
        { get = WQ.IsSoulstoneEnabled, set = WQ.SetSoulstoneEnabled })

    -- No macro row here, so the list starts right at the page top (below the header).
    local refreshSoulstone = BuildLineList(soulstone, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.soulstoneLines end,
        add    = function(text) return WQ.AddSoulstoneLine(text) end,
        update = function(idx, text) return WQ.UpdateSoulstoneLine(idx, text) end,
        delete = function(idx)  WQ.DeleteSoulstoneLine(idx) end,
        placeholders = { "{targetName}" },
        help1  = "|cff8788eeUse |r|cffaaaaaa{targetName}|r|cff8788ee as a placeholder for who got the soulstone|r",
    })

    -- The Enabled toggle is synced by ShowPage; OnPageShow just redraws the list.
    soulstone.OnPageShow = refreshSoulstone
end

-- ── Banish Announcement page ──────────────────────────────────────────────────
--
-- Like the soulstone page this feature is combat-log driven with no macro, but it has TWO
-- editable line pools — one for a banish that LANDS and one for a banish that's RESISTED —
-- selected by a pair of sub-tabs (the same accent-tab pattern as the Demon Summon page,
-- just two of them). One shared line list edits whichever pool the active tab points at.
-- Announces only the player's OWN banishes (the core filters on the MINE affiliation), and
-- the spell rank is appended automatically by the core, so the page just manages the text.

do
    local banish = NewPage("banish", "Banish Announcement",
        "When you banish a target, a random line is announced to your party/raid. Spell rank is added automatically.",
        { get = WQ.IsBanishEnabled, set = WQ.SetBanishEnabled })

    -- Which pool the list below edits: successful banishes vs. resisted ones.
    local selectedKind = "banished"   -- "banished" | "resisted"
    local refreshBanish               -- forward ref (tabs + refresh reference each other)
    local kindTabs = {}

    local KIND_TABS = {
        { key = "banished", label = "Banished" },
        { key = "resisted", label = "Resisted" },
    }
    local TAB_GAP, TAB_Y, TAB_W = 4, -8, 110
    for _, t in ipairs(KIND_TABS) do
        local btn = MakeFlatButton(banish, t.label, TAB_W, 22)
        btn:SetScript("OnClick", function()
            selectedKind = t.key
            refreshBanish()
        end)
        kindTabs[t.key] = btn
    end

    -- Centre the two tabs across the page top (only two, so a fixed width fits even at the
    -- minimum window size — no adaptive sizing needed here, unlike the six demon tabs).
    local n    = #KIND_TABS
    local step = TAB_W + TAB_GAP
    for i, t in ipairs(KIND_TABS) do
        kindTabs[t.key]:SetPoint("TOP", banish, "TOP", (i - (n + 1) / 2) * step, TAB_Y)
    end

    -- Accent-highlight the active tab; leave the other flat (mirrors the demon-tab style).
    local function HighlightKindTabs()
        for key, btn in pairs(kindTabs) do
            if key == selectedKind then
                btn:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                btn.label:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                btn:SetScript("OnLeave", function(self)
                    self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                    self.label:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                end)
            else
                btn:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
                btn.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                btn:SetScript("OnLeave", function(self)
                    self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
                    self.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                end)
            end
        end
    end

    -- Resolve the DB list + the three WQ helpers for the currently-selected pool, so the one
    -- BuildLineList below transparently edits whichever tab is active.
    local function active()
        local prof = WQ.ActiveProfile()   -- nil pre-login; pools resolve to nil → empty list
        if selectedKind == "resisted" then
            return prof and prof.banishResistLines,
                   WQ.AddBanishResistLine, WQ.UpdateBanishResistLine, WQ.DeleteBanishResistLine
        end
        return prof and prof.banishLines,
               WQ.AddBanishLine, WQ.UpdateBanishLine, WQ.DeleteBanishLine
    end

    local refreshList = BuildLineList(banish, -40, {
        get    = function()          local l = active();                 return l end,
        add    = function(text)      local _, add = active();            return add(text) end,
        update = function(idx, text) local _, _, upd = active();         return upd(idx, text) end,
        delete = function(idx)       local _, _, _, del = active();      del(idx) end,
        placeholders = { "{targetName}" },
        help1  = "|cff8788eeUse |r|cffaaaaaa{targetName}|r|cff8788ee as a placeholder for who you banished|r",
    })

    refreshBanish = function()
        HighlightKindTabs()
        refreshList()
    end

    banish.OnPageShow = refreshBanish
end

-- ── Profiles page ─────────────────────────────────────────────────────────────
--
-- The DB is profile-based: each character points at an active profile that holds all the
-- line pools + feature toggles, while pet names / setup flag / master switch stay per
-- character. This page is the front-end to the core's profile API (WQ.GetActiveProfileName
-- / ListProfiles / SwitchProfile / CreateProfile / CopyProfileInto / DeleteProfile). It's a
-- plain settings page (no Enabled toggle) reached from a dedicated sidebar button, not the
-- top nav list. Every mutation routes through RefreshProfilesPage() so the labels + the
-- three dropdowns stay in sync; switching/copying also lets the line-list pages pick up the
-- new active profile the next time they're shown (they rebuild in their OnPageShow).

do
    local profiles = NewPage("profiles", "Profiles",
        "Each character has its own profile of lines and settings. Switch, copy, delete, or share profiles here.")

    -- Two-column body: labels in a left gutter, controls in a fixed control column so the
    -- editbox/dropdowns line up. Widths chosen to fit even at the minimum window size (the
    -- content column is ~426px wide there: 120 gutter + 200 dropdown clears it comfortably).
    local LABEL_X, CTRL_X, DD_W = 8, 120, 200   -- LABEL_X = shared content margin (matches the list pages)
    local PLACEHOLDER = "Select a profile..."

    -- Forward decl: the dropdown callbacks + StaticPopups all call back into this to redraw.
    local RefreshProfilesPage

    -- Current-profile readout (the active name shown in the accent colour).
    local currentLabel = profiles:CreateFontString(nil, "OVERLAY")
    ApplyFont(currentLabel, 13)
    currentLabel:SetPoint("TOPLEFT", profiles, "TOPLEFT", LABEL_X, -10)
    currentLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])

    -- Inline error/status line pinned to the page bottom, hidden until something to say.
    local errorMsg = profiles:CreateFontString(nil, "OVERLAY")
    ApplyFont(errorMsg, 12)
    errorMsg:SetPoint("BOTTOMLEFT",  profiles, "BOTTOMLEFT",  LABEL_X, 12)
    errorMsg:SetPoint("BOTTOMRIGHT", profiles, "BOTTOMRIGHT", -12, 12)
    errorMsg:SetJustifyH("LEFT")
    errorMsg:Hide()
    local function ShowError(msg)
        errorMsg:SetText("|cffff5555" .. msg .. "|r")   -- soft red, matches the off-state feel
        errorMsg:Show()
    end
    -- Same line, green, for a success confirmation (e.g. "Imported '<name>'").
    local function ShowStatus(msg)
        errorMsg:SetText("|cff55dd55" .. msg .. "|r")
        errorMsg:Show()
    end
    local function ClearError() errorMsg:SetText(""); errorMsg:Hide() end

    -- Small helper for a left-gutter caption beside a control row.
    local function RowLabel(text, y)
        local fs = profiles:CreateFontString(nil, "OVERLAY")
        ApplyFont(fs, 12)
        fs:SetPoint("TOPLEFT", profiles, "TOPLEFT", LABEL_X, y)
        fs:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
        fs:SetText(text)
        return fs
    end

    -- Row 1 — New Profile: a labelled editbox + Create button.
    RowLabel("New Profile", -48)
    local newBox = MakeFlatEditBox(profiles)
    newBox:SetHeight(24)
    newBox:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -42)
    newBox:SetWidth(180)
    newBox:SetMaxLetters(50)

    local createBtn = MakeFlatButton(profiles, "Create", 70, 24)
    createBtn:SetPoint("LEFT", newBox, "RIGHT", 8, 0)

    -- Row 2 — Existing Profiles: switch the active profile.
    RowLabel("Existing Profiles", -84)
    local existingDD = MakeDropdown(profiles, DD_W)
    existingDD:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -78)

    -- Divider between the create/switch block and the copy/delete block.
    local divider = profiles:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    divider:SetPoint("TOPLEFT",  profiles, "TOPLEFT",  LABEL_X, -114)
    divider:SetPoint("TOPRIGHT", profiles, "TOPRIGHT", -12, -114)
    divider:SetHeight(1)

    -- Row 3 — Copy From: deep-copy another profile INTO the active one (overwrites it).
    RowLabel("Copy From", -132)
    local copyDD = MakeDropdown(profiles, DD_W)
    copyDD:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -126)

    -- Row 4 — Delete a Profile: remove a non-active profile.
    RowLabel("Delete a Profile", -168)
    local deleteDD = MakeDropdown(profiles, DD_W)
    deleteDD:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -162)

    -- Pending selections captured for the confirm popups (set on select, read on accept).
    local pendingCopy, pendingDelete

    -- Copy confirmation. Two %s in the text are filled by StaticPopup_Show(src, active).
    StaticPopupDialogs["WARLOCK_QOL_TBC_COPY_PROFILE"] = {
        text = "Copy all lines and settings from '%s' into the active profile '%s'?\n\nThis overwrites the active profile's current lines.",
        button1 = YES, button2 = NO,
        OnAccept = function()
            if not pendingCopy then return end
            local ok, reason = WQ.CopyProfileInto(pendingCopy)
            pendingCopy = nil
            if not ok then
                ShowError("Copy failed (" .. (reason or "?") .. ").")
            else
                -- Active profile's pools changed; RefreshProfilesPage covers this page and
                -- the hidden line-list pages rebuild on their next show.
                RefreshProfilesPage()
            end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    -- Delete confirmation.
    StaticPopupDialogs["WARLOCK_QOL_TBC_DELETE_PROFILE"] = {
        text = "Delete profile '%s'?\n\nThis cannot be undone.",
        button1 = YES, button2 = NO,
        OnAccept = function()
            if not pendingDelete then return end
            local ok, reason = WQ.DeleteProfile(pendingDelete)
            pendingDelete = nil
            if not ok then
                if reason == "last" then      ShowError("Can't delete the last remaining profile.")
                elseif reason == "active" then ShowError("Can't delete the active profile.")
                else                           ShowError("Delete failed (" .. (reason or "?") .. ").") end
            end
            RefreshProfilesPage()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    -- Create: on button click or Enter in the box. Trim, create (which seeds + switches to
    -- the new profile), then clear the box and refresh.
    local function DoCreate()
        ClearError()
        local name = (newBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then ShowError("Enter a profile name."); return end
        local ok, reason = WQ.CreateProfile(name)
        if not ok then
            if reason == "empty" then      ShowError("Enter a profile name.")
            elseif reason == "exists" then ShowError("A profile named '" .. name .. "' already exists.")
            else                           ShowError("Could not create profile (" .. (reason or "?") .. ").") end
            return
        end
        newBox:SetText("")
        newBox:ClearFocus()
        RefreshProfilesPage()
    end
    createBtn:SetScript("OnClick", DoCreate)
    newBox:SetScript("OnEnterPressed", DoCreate)
    newBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    -- Existing: switch the active profile. Ignore re-selecting the current one.
    existingDD:SetOnSelect(function(name)
        ClearError()
        if name == WQ.GetActiveProfileName() then return end
        local ok, reason = WQ.SwitchProfile(name)
        if not ok then ShowError("Could not switch profile (" .. (reason or "?") .. ").") ; return end
        RefreshProfilesPage()
    end)

    -- Copy From: confirm, then copy on accept. Reset the dropdown to its placeholder now
    -- (the popup already captured the source in pendingCopy).
    copyDD:SetOnSelect(function(src)
        ClearError()
        pendingCopy = src
        StaticPopup_Show("WARLOCK_QOL_TBC_COPY_PROFILE", src, WQ.GetActiveProfileName())
        copyDD:SetValue(PLACEHOLDER)
    end)

    -- Delete a Profile: confirm, then delete on accept. Reset to placeholder.
    deleteDD:SetOnSelect(function(name)
        ClearError()
        pendingDelete = name
        StaticPopup_Show("WARLOCK_QOL_TBC_DELETE_PROFILE", name)
        deleteDD:SetValue(PLACEHOLDER)
    end)

    -- ── Share Profile ────────────────────────────────────────────────────────
    -- Export any profile to a copy-paste string, or import a string as a NEW profile.
    -- Kept below the switch/copy/delete block so it reads as a distinct concern.
    local exportSel   -- which profile the Export button will export (defaults to the active one)

    local shareDivider = profiles:CreateTexture(nil, "ARTWORK")
    shareDivider:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    shareDivider:SetPoint("TOPLEFT",  profiles, "TOPLEFT",  LABEL_X, -196)
    shareDivider:SetPoint("TOPRIGHT", profiles, "TOPRIGHT", -12, -196)
    shareDivider:SetHeight(1)

    local shareHdr = profiles:CreateFontString(nil, "OVERLAY")
    ApplyFont(shareHdr, 12)
    shareHdr:SetPoint("TOPLEFT", profiles, "TOPLEFT", LABEL_X, -206)
    shareHdr:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    shareHdr:SetText("SHARE PROFILE")

    -- Export row: pick a profile (defaults to active) + Export button → fills the box below,
    -- and a Clear button to empty it again once copied.
    RowLabel("Export", -232)
    local exportDD = MakeDropdown(profiles, 140)
    exportDD:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -226)
    exportDD:SetOnSelect(function(name) exportSel = name end)

    local exportBtn = MakeFlatButton(profiles, "Export", 60, 22)
    exportBtn:SetPoint("LEFT", exportDD, "RIGHT", 8, 0)

    local clearBtn = MakeFlatButton(profiles, "Clear", 54, 22)
    clearBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)

    local exportBox = MakeMultilineBox(profiles, 42)
    exportBox:SetPoint("TOPLEFT",  profiles, "TOPLEFT",  LABEL_X, -256)
    exportBox:SetPoint("TOPRIGHT", profiles, "TOPRIGHT", -12, -256)

    exportBtn:SetScript("OnClick", function()
        ClearError()
        local name = exportSel or WQ.GetActiveProfileName()
        if not name then ShowError("No profile selected to export."); return end
        local str = WQ.ExportProfile and WQ.ExportProfile(name)
        if not str then ShowError("Could not export '" .. tostring(name) .. "'."); return end
        exportBox.edit:SetText(str)
        exportBox.edit:SetFocus()
        exportBox.edit:HighlightText()          -- select-all so Ctrl+C grabs the whole string
        ShowStatus("Exported '" .. name .. "'. Press Ctrl+C to copy, then Clear.")
    end)

    clearBtn:SetScript("OnClick", function()
        exportBox.edit:SetText("")
        exportBox.edit:ClearFocus()
        ClearError()
    end)

    -- Import row: paste a string, name the new profile (auto-prefilled), Import.
    RowLabel("Import as", -316)
    local importName = MakeFlatEditBox(profiles)
    importName:SetHeight(24)
    importName:SetPoint("TOPLEFT", profiles, "TOPLEFT", CTRL_X, -310)
    importName:SetWidth(180)
    importName:SetMaxLetters(50)

    local importBtn = MakeFlatButton(profiles, "Import", 70, 24)
    importBtn:SetPoint("LEFT", importName, "RIGHT", 8, 0)

    local importBox = MakeMultilineBox(profiles, 42)
    importBox:SetPoint("TOPLEFT",  profiles, "TOPLEFT",  LABEL_X, -340)
    importBox:SetPoint("TOPRIGHT", profiles, "TOPRIGHT", -12, -340)

    -- After a paste (focus leaves the box), prefill the name from the string — but only if
    -- the user hasn't already typed their own name. Name = "<source> MM-DD HH:MM" for uniqueness.
    importBox.edit:HookScript("OnEditFocusLost", function(self)
        if (importName:GetText() or "") == "" then
            local n = WQ.PeekImportName and WQ.PeekImportName(self:GetText())
            if n then importName:SetText(n .. " " .. date("%m-%d %H:%M")) end
        end
    end)

    local function DoImport()
        ClearError()
        local str = importBox.edit:GetText() or ""
        if str:gsub("%s", "") == "" then ShowError("Paste an import string first."); return end

        -- Name: the user's typed name if any, else derive from the string with a timestamp.
        local typed = (importName:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local name, userNamed
        if typed ~= "" then
            name, userNamed = typed, true
        else
            local n = WQ.PeekImportName and WQ.PeekImportName(str)
            name = (n and (n .. " " .. date("%m-%d %H:%M"))) or ("Imported " .. date("%m-%d %H:%M"))
            userNamed = false
        end

        local ok, reason = WQ.ImportProfile(str, name)
        -- Last-resort auto-suffix so a same-minute derived-name collision still lands. Only for
        -- auto-derived names — if the user typed a name that exists, we ask them to change it.
        if not ok and reason == "exists" and not userNamed then
            for i = 2, 50 do
                local alt = name .. " (" .. i .. ")"
                ok, reason = WQ.ImportProfile(str, alt)
                if ok then name = alt; break end
                if reason ~= "exists" then break end
            end
        end

        if not ok then
            if reason == "empty" then          ShowError("Enter a name for the imported profile.")
            elseif reason == "exists" then     ShowError("A profile named '" .. name .. "' already exists — change the name.")
            elseif reason == "badformat" then  ShowError("That doesn't look like a WarlockQol export string.")
            elseif reason == "badversion" then ShowError("That export string is from an incompatible version.")
            elseif reason == "corrupt" then    ShowError("Import string is corrupt or incomplete — copy the whole thing and try again.")
            else                               ShowError("Import failed (" .. (reason or "?") .. ").") end
            return
        end
        importBox.edit:SetText("");  importBox.edit:ClearFocus()
        importName:SetText(""); importName:ClearFocus()
        ShowStatus("Imported profile '" .. name .. "'. Switch to it with Existing Profiles above.")
        RefreshProfilesPage()
    end
    importBtn:SetScript("OnClick", DoImport)
    importName:SetScript("OnEnterPressed", DoImport)
    importName:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Re-read all profile state and repaint: current label, the Existing dropdown
    -- (all profiles, value = active), and the Copy/Delete dropdowns (all profiles MINUS the
    -- active one — you can't copy onto or delete the active profile). If that leaves no
    -- options the two dropdowns show a dimmed "No other profiles" and are inert.
    RefreshProfilesPage = function()
        local active = (WQ.GetActiveProfileName and WQ.GetActiveProfileName()) or "?"
        currentLabel:SetText("Current Profile:  |cff" .. HEX_ACCENT .. active .. "|r")

        local all = (WQ.ListProfiles and WQ.ListProfiles()) or {}
        existingDD:SetOptions(all)
        existingDD:SetValue(active)

        -- Export picker: every profile, defaulting to the active one. Also empty the export
        -- output box so a previously-exported string doesn't linger when the page is reopened.
        exportBox.edit:SetText("")
        exportDD:SetOptions(all)
        if not exportSel or not Warlock_Qol_Tbc_DB or not Warlock_Qol_Tbc_DB.profiles
           or not Warlock_Qol_Tbc_DB.profiles[exportSel] then
            exportSel = active
        end
        exportDD:SetValue(exportSel or active)

        local others = {}
        for _, n in ipairs(all) do
            if n ~= active then others[#others + 1] = n end
        end
        copyDD:SetOptions(others)
        deleteDD:SetOptions(others)
        if #others == 0 then
            copyDD:SetValue("No other profiles")
            deleteDD:SetValue("No other profiles")
        else
            copyDD:SetValue(PLACEHOLDER)
            deleteDD:SetValue(PLACEHOLDER)
        end
    end

    profiles.OnPageShow = RefreshProfilesPage
end

-- ── Reset page (Settings) ─────────────────────────────────────────────────────
-- Two destructive actions, each behind a confirm popup. The core owns the actual work
-- (WQ.ResetMacros keeps everything but the macros; WQ.HardReset wipes the ENTIRE addon —
-- every profile and all settings, account-wide — back to a fresh install). This page is
-- just the buttons + descriptions. Static layout with fixed offsets (like the Profiles page).
do
    local reset = NewPage("reset", "Reset",
        "Clean up the macros WarlockQol created, or reset the whole addon back to a fresh install.")

    local PAD_L, WRAP = 8, -16   -- PAD_L = shared content margin (matches the list pages)

    -- Section 1 — Reset Macros (accent heading).
    local h1 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(h1, 13)
    h1:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    h1:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -6)
    h1:SetText("Reset Macros")

    local d1 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(d1, 12)
    d1:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    d1:SetPoint("TOPLEFT",  reset, "TOPLEFT",  PAD_L, -26)
    d1:SetPoint("TOPRIGHT", reset, "TOPRIGHT", WRAP,  -26)
    d1:SetJustifyH("LEFT")
    d1:SetSpacing(4)
    d1:SetText("Removes every macro WarlockQol created. Your saved lines, feature toggles, and profiles are all kept — re-create the macros anytime from each feature page.")

    local btn1 = MakeFlatButton(reset, "Reset Macros", 130, 24)
    btn1:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -84)
    btn1:SetScript("OnClick", function() StaticPopup_Show("WARLOCK_QOL_TBC_RESET_MACROS") end)

    -- Divider between the two sections.
    local div = reset:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    div:SetPoint("TOPLEFT",  reset, "TOPLEFT",  PAD_L, -120)
    div:SetPoint("TOPRIGHT", reset, "TOPRIGHT", WRAP,  -120)
    div:SetHeight(1)

    -- Section 2 — Hard Reset (heading in the DK-red "off" colour to flag it as destructive).
    local h2 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(h2, 13)
    h2:SetTextColor(THEME.offRed[1], THEME.offRed[2], THEME.offRed[3])
    h2:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -140)
    h2:SetText("Hard Reset")

    local d2 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(d2, 12)
    d2:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    d2:SetPoint("TOPLEFT",  reset, "TOPLEFT",  PAD_L, -160)
    d2:SetPoint("TOPRIGHT", reset, "TOPRIGHT", WRAP,  -160)
    d2:SetJustifyH("LEFT")
    d2:SetSpacing(4)
    d2:SetText("Wipes the WHOLE addon back to a fresh install — deletes ALL profiles, every character's lines, feature toggles and settings, and this character's macros. Nothing is kept. This cannot be undone.")

    local btn2 = MakeFlatButton(reset, "Hard Reset", 130, 24)
    btn2:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -218)
    btn2:SetScript("OnClick", function() StaticPopup_Show("WARLOCK_QOL_TBC_HARD_RESET") end)

    -- Divider before the Setup Guide section.
    local div2 = reset:CreateTexture(nil, "ARTWORK")
    div2:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    div2:SetPoint("TOPLEFT",  reset, "TOPLEFT",  PAD_L, -254)
    div2:SetPoint("TOPRIGHT", reset, "TOPRIGHT", WRAP,  -254)
    div2:SetHeight(1)

    -- Section 3 — Setup Guide (re-open the first-run wizard; non-destructive, accent heading).
    local h3 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(h3, 13)
    h3:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    h3:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -274)
    h3:SetText("Setup Guide")

    local d3 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(d3, 12)
    d3:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    d3:SetPoint("TOPLEFT",  reset, "TOPLEFT",  PAD_L, -294)
    d3:SetPoint("TOPRIGHT", reset, "TOPRIGHT", WRAP,  -294)
    d3:SetJustifyH("LEFT")
    d3:SetSpacing(4)
    d3:SetText("Reopen the first-time welcome window with the intro and the Create Macros button.")

    local btn3 = MakeFlatButton(reset, "Show Setup Guide", 130, 24)
    btn3:SetPoint("TOPLEFT", reset, "TOPLEFT", PAD_L, -332)
    btn3:SetScript("OnClick", function() if WQ.ShowWizard then WQ.ShowWizard() end end)
end

-- ── Tracking page (Settings) ──────────────────────────────────────────────────
-- Settings-only page for the Raid Cooldown Tracker (the HUD itself is a separate standalone
-- frame built at the end of this file). The top-right shared "Enabled" toggle drives the whole
-- feature (trackerEnabled); the body has the HUD display controls + per-cooldown track toggles.
-- All checkboxes re-sync on page show (profile switches can change the underlying flags).
do
    local track = NewPage("tracking", "Raid Cooldowns",
        "Track your raid's warlock cooldowns on a movable HUD. CTRL + click to announce.",
        { get = WQ.IsTrackerEnabled, set = WQ.SetTrackerEnabled })

    local PAD_L, WRAP = 8, -16
    local syncers = {}   -- checkboxes to re-sync from their get() on page show

    -- A flat checkbox + label row at (PAD_L, y), wired to a get/set. Mirrors the shared
    -- header toggle's styling. The initial state is NOT read here (some getters — the HUD
    -- show/lock ones — aren't defined until the HUD block later in this file); OnPageShow
    -- runs the registered syncer to set it, which is fine since the page is hidden until then.
    local function CheckRow(label, y, get, set, x)
        local cb = CreateFrame("CheckButton", nil, track, "UICheckButtonTemplate,BackdropTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", track, "TOPLEFT", x or PAD_L, y)
        StyleCheckbox(cb)
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked())
            self.RefreshStateColor()
        end)

        local fs = track:CreateFontString(nil, "OVERLAY")
        ApplyFont(fs, 12)
        fs:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
        fs:SetText(label)

        syncers[#syncers + 1] = function() cb:SetChecked(get() and true or false); cb.RefreshStateColor() end
        return cb
    end

    -- Small accent section heading at y.
    local function Heading(text, y)
        local h = track:CreateFontString(nil, "OVERLAY")
        ApplyFont(h, 13)
        h:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        h:SetPoint("TOPLEFT", track, "TOPLEFT", PAD_L, y)
        h:SetText(text)
        return h
    end
    -- Dim caption at y.
    local function Caption(text, y)
        local c = track:CreateFontString(nil, "OVERLAY")
        ApplyFont(c, 11)
        c:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
        c:SetPoint("TOPLEFT", track, "TOPLEFT", PAD_L, y)
        c:SetText(text)
        return c
    end

    -- Horizontal rule spanning the body at y (section separator).
    local function Rule(y)
        local r = track:CreateTexture(nil, "ARTWORK")
        r:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        r:SetPoint("TOPLEFT",  track, "TOPLEFT",  PAD_L, y)
        r:SetPoint("TOPRIGHT", track, "TOPRIGHT", WRAP,  y)
        r:SetHeight(1)
    end

    -- HUD visibility: two independent toggles SIDE BY SIDE. LEFT = manual open/close (show the
    -- HUD now, anywhere); RIGHT = auto-show whenever you're in a raid. Both are wrapped in
    -- closures because the HUD getter/setters live later in the file (a direct reference would
    -- capture nil at page-build time). Raid-only feature — no party mode.
    Heading("HUD", -6)
    CheckRow("Show HUD", -32,
        function() return WQ.IsTrackerHUDOpen() end,  function(v) WQ.SetTrackerHUDOpen(v) end)
    CheckRow("Auto-show in raid", -32,
        function() return WQ.IsTrackerShowRaid() end,
        function(v)
            WQ.SetTrackerShowRaid(v)
            -- Enabling while ALREADY in a raid won't hit a transition, so open the HUD now.
            if v and IsInRaid() then WQ.SetTrackerHUDOpen(true) end
        end, 185)
    local cap = Caption("Auto-show opens it automatically whenever you're in a raid.", -60)
    cap:SetPoint("TOPRIGHT", track, "TOPRIGHT", WRAP, -60)
    cap:SetJustifyH("LEFT")

    Rule(-88)

    -- Tracked-cooldowns section — one checkbox per tracked cooldown (data-driven; soulstone
    -- is the only one for now, but this grows automatically as TRACKED_ORDER does).
    Heading("Tracked Cooldowns", -104)
    local y = -128
    for _, key in ipairs(WQ.TRACKED_ORDER or {}) do
        local spec = WQ.TRACKED_COOLDOWNS and WQ.TRACKED_COOLDOWNS[key]
        local label = spec and spec.label or key
        CheckRow(label, y,
            function() return WQ.IsCooldownTracked(key) end,
            function(v) WQ.SetCooldownTracked(key, v) end)
        y = y - 28
    end

    -- Re-sync every checkbox from its current value. Runs on page show (e.g. after a profile
    -- switch flips the per-profile flags; the shared header Enabled toggle is synced by ShowPage
    -- itself) AND is exposed so the HUD block can call it when the HUD's own X button flips
    -- "Show HUD" off — keeping the page checkbox from drifting out of sync.
    function WQ.SyncTrackerPage()
        for _, sync in ipairs(syncers) do sync() end
    end
    track.OnPageShow = WQ.SyncTrackerPage
end

-- ── Missing Consumables page (Raid) ────────────────────────────────────────────
-- Settings-only page for the Missing Consumables HUD (a separate standalone strip built at the
-- end of this file). Top-right shared "Enabled" toggle drives the whole feature
-- (consumablesEnabled); the body has the HUD show controls, the expiry-warning threshold, and
-- a per-consumable track list. Mirrors the Tracking page's structure/helpers.
do
    local cons = NewPage("consumables", "Missing Consumables",
        "A HUD that pops up in a raid showing the consumables you're missing or about to lose.",
        { get = WQ.IsConsumablesEnabled, set = WQ.SetConsumablesEnabled })

    local PAD_L, WRAP = 8, -16
    local syncers = {}   -- widgets to re-sync from their getters on page show

    -- A flat checkbox + label row at (x or PAD_L, y), wired to a get/set. Same as the Tracking
    -- page's; the initial state is set by the registered syncer on page show (some HUD getters
    -- aren't defined until the HUD block later in this file).
    local function CheckRow(label, y, get, set, x)
        local cb = CreateFrame("CheckButton", nil, cons, "UICheckButtonTemplate,BackdropTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", cons, "TOPLEFT", x or PAD_L, y)
        StyleCheckbox(cb)
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked())
            self.RefreshStateColor()
        end)
        local fs = cons:CreateFontString(nil, "OVERLAY")
        ApplyFont(fs, 12)
        fs:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
        fs:SetText(label)
        syncers[#syncers + 1] = function() cb:SetChecked(get() and true or false); cb.RefreshStateColor() end
        return cb
    end

    local function Heading(text, y)
        local h = cons:CreateFontString(nil, "OVERLAY")
        ApplyFont(h, 13)
        h:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        h:SetPoint("TOPLEFT", cons, "TOPLEFT", PAD_L, y)
        h:SetText(text)
        return h
    end
    local function Caption(text, y)
        local c = cons:CreateFontString(nil, "OVERLAY")
        ApplyFont(c, 11)
        c:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
        c:SetPoint("TOPLEFT", cons, "TOPLEFT", PAD_L, y)
        c:SetPoint("TOPRIGHT", cons, "TOPRIGHT", WRAP, y)
        c:SetJustifyH("LEFT")
        c:SetText(text)
        return c
    end
    local function Rule(y)
        local r = cons:CreateTexture(nil, "ARTWORK")
        r:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        r:SetPoint("TOPLEFT",  cons, "TOPLEFT",  PAD_L, y)
        r:SetPoint("TOPRIGHT", cons, "TOPRIGHT", WRAP,  y)
        r:SetHeight(1)
    end

    -- ── HUD show controls: manual "Show HUD" + "Auto-show in raid" (side by side, like Tracking).
    Heading("HUD", -6)
    Caption("Auto-hides when nothing is missing.", -26)   -- dim note under the heading
    CheckRow("Show HUD", -50,
        function() return WQ.IsConsumeHUDOpen() end, function(v) WQ.SetConsumeHUDOpen(v) end)
    CheckRow("Auto-show in raid", -50,
        function() return WQ.IsConsumeShowRaid() end, function(v) WQ.SetConsumeShowRaid(v) end, 185)
    CheckRow("Glow missing icons", -76,
        function() return WQ.IsConsumeGlow() end, function(v) WQ.SetConsumeGlow(v) end)

    Rule(-108)

    -- ── Expiry-warning threshold. Stored in seconds; edited here in MINUTES.
    Heading("Warn before expiry", -124)
    local threshLabel = cons:CreateFontString(nil, "OVERLAY")
    ApplyFont(threshLabel, 12)
    threshLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    threshLabel:SetPoint("TOPLEFT", cons, "TOPLEFT", PAD_L, -150)
    threshLabel:SetText("Show a countdown when under")

    local threshBox = MakeFlatEditBox(cons)
    threshBox:SetSize(40, 22)
    threshBox:SetPoint("LEFT", threshLabel, "RIGHT", 8, 0)
    threshBox:SetJustifyH("CENTER")
    threshBox:SetMaxLetters(4)

    local threshUnit = cons:CreateFontString(nil, "OVERLAY")
    ApplyFont(threshUnit, 12)
    threshUnit:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    threshUnit:SetPoint("LEFT", threshBox, "RIGHT", 8, 0)
    threshUnit:SetText("minutes")

    local function RefreshThresholdBox()
        local mins = WQ.GetConsumeThreshold() / 60
        if mins == math.floor(mins) then threshBox:SetText(("%d"):format(mins))
        else threshBox:SetText(("%.1f"):format(mins)) end
    end
    local function CommitThreshold()
        local mins = tonumber(threshBox:GetText())
        if mins and mins > 0 then WQ.SetConsumeThreshold(mins * 60) end
        RefreshThresholdBox()   -- reflect the stored (clamped) value
    end
    threshBox:SetScript("OnEnterPressed", function(self) CommitThreshold(); self:ClearFocus() end)
    threshBox:SetScript("OnEscapePressed", function(self) RefreshThresholdBox(); self:ClearFocus() end)
    threshBox:HookScript("OnEditFocusLost", function() CommitThreshold() end)   -- HookScript keeps the border-reset hook
    syncers[#syncers + 1] = RefreshThresholdBox

    Rule(-182)

    -- ── Tracked consumables: one checkbox per consumable (data-driven from CONSUMABLE_ORDER).
    Heading("Tracked Consumables", -198)
    local y = -222
    for _, key in ipairs(WQ.CONSUMABLE_ORDER or {}) do
        local spec  = WQ.CONSUMABLES and WQ.CONSUMABLES[key]
        local label = spec and spec.label or key
        CheckRow(label, y,
            function() return WQ.IsConsumeTracked(key) end,
            function(v) WQ.SetConsumeTracked(key, v) end)
        y = y - 28
    end

    -- Re-sync every widget from its current value (page show / profile switch), and let the HUD
    -- block call it when the HUD's X button flips "Show HUD" off (see SetConsumeHUDOpen).
    function WQ.SyncConsumablesPage()
        for _, sync in ipairs(syncers) do sync() end
    end
    cons.OnPageShow = WQ.SyncConsumablesPage
end

-- ── Left nav items ────────────────────────────────────────────────────────────
-- Nav column: ten flat nav buttons (one per page) grouped under non-interactive section
-- headers ("Voice Lines" / "Announcements" / "Raid" / "Settings"), built after the pages
-- so ShowPage is wired up.
-- The selected item fills gold with dark text; the rest are transparent with gold-on-
-- hover text. UpdateNav (forward-declared above) refreshes the highlight on ShowPage.

do
    -- Nav entries are either a clickable { label, page } item or a non-interactive
    -- { header = "..." } section title. We walk them with a running vertical offset
    -- (`y`, distance from the sidebar top) so headers — a dim uppercase label plus a
    -- 1px rule — and items can have different heights and spacing.
    local NAV_ITEMS = {
        { label = "General",                page = "home"      },
        { header = "VOICE LINES" },
        { label = "Demon Summoning",        page = "summon"    },
        { label = "Ritual of Summoning",    page = "ritual"    },
        { label = "Ritual of Souls",        page = "souls"     },
        { header = "ANNOUNCEMENTS" },
        { label = "Soulstone Announcement", page = "soulstone" },
        { label = "Banish Announcement",    page = "banish"    },
        { header = "RAID" },
        { label = "Raid Cooldowns",         page = "tracking"     },
        { label = "Missing Consumables",    page = "consumables"  },
        { header = "SETTINGS" },
        { label = "Profiles",               page = "profiles"  },
        { label = "Reset",                  page = "reset"     },
    }
    local navButtons = {}
    local y = 4   -- running distance from the sidebar's top edge

    for _, item in ipairs(NAV_ITEMS) do
        if item.header then
            -- Section title: a little extra gap above, a dim uppercase label, then a
            -- thin rule beneath. Not a navButton, so UpdateNav skips it (inert text).
            y = y + 8
            local hdr = sidebar:CreateFontString(nil, "OVERLAY")
            ApplyFont(hdr, 10)
            hdr:SetPoint("TOPLEFT",  sidebar, "TOPLEFT",   8, -y)
            hdr:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -4, -y)
            hdr:SetJustifyH("LEFT")
            hdr:SetWordWrap(false)
            hdr:SetText(item.header)
            hdr:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
            y = y + 15

            local rule = sidebar:CreateTexture(nil, "ARTWORK")
            rule:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
            rule:SetPoint("TOPLEFT",  sidebar, "TOPLEFT",   4, -y)
            rule:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -4, -y)
            rule:SetHeight(1)
            y = y + 1 + 4
        else
            local b = CreateFrame("Button", nil, sidebar)
            b:SetHeight(NAV_H)
            b:SetPoint("TOPLEFT",  sidebar, "TOPLEFT",   4, -y)
            b:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -4, -y)

            -- Gold selection fill (hidden unless this item is the current page).
            local sel = b:CreateTexture(nil, "BACKGROUND")
            sel:SetAllPoints()
            sel:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 1)
            sel:Hide()
            b.sel = sel

            -- Hover highlight (faint gold) for unselected items.
            local hov = b:CreateTexture(nil, "HIGHLIGHT")
            hov:SetAllPoints()
            hov:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], 0.12)

            local fs = b:CreateFontString(nil, "OVERLAY")
            ApplyFont(fs, 12)
            fs:SetPoint("LEFT", b, "LEFT", 8, 0)
            fs:SetPoint("RIGHT", b, "RIGHT", -4, 0)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetText(item.label)
            fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
            b.label = fs

            b.page = item.page
            b:SetScript("OnClick", function() ShowPage(item.page) end)
            navButtons[#navButtons + 1] = b

            y = y + NAV_H + 2
        end
    end

    -- Highlight the nav item matching `name`: gold fill + dark text when selected,
    -- transparent + off-white otherwise.
    UpdateNav = function(name)
        for _, b in ipairs(navButtons) do
            if b.page == name then
                b.sel:Show()
                b.label:SetTextColor(THEME.bg[1], THEME.bg[2], THEME.bg[3])  -- dark on gold
            else
                b.sel:Hide()
                b.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
            end
        end
    end
end

-- ── Persistent "Open Macros" button (sidebar bottom) ────────────────────────────
-- Macro CREATION lives in the setup wizard now (first-run, or re-opened from the Reset page's
-- "Show Setup Guide"), so the old sidebar "Create Macros" button was removed — only "Open
-- Macros" stays pinned here. It's stretched between the sidebar's left/right insets at its
-- bottom edge, clear of the nav items above, and follows the window as it resizes. The resize
-- grip sits in the content pane far to the right, so there's no overlap with it.
do
    local openMacros = MakeFlatButton(sidebar, "Open Macros")
    openMacros:SetHeight(24)
    openMacros:SetPoint("BOTTOMLEFT",  sidebar, "BOTTOMLEFT",   4, 4)
    openMacros:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -4, 4)
    openMacros:SetScript("OnClick", OpenMacroUI)
end

-- ── Raid Cooldown Tracker HUD (Stage 2) ────────────────────────────────────────
-- A standalone, movable HUD (separate from the /wq config window) that shows each grouped
-- warlock's tracked-cooldown state — "Ready" or a live countdown — fed by the core tracker
-- (comms + combat-log fallback). The addon's first live-ticking, networked display.
--
-- Structure vs. ticking are split for cheapness: WQ.RefreshTrackerHUD() rebuilds the ROWS
-- from the roster only when membership/data changes (roster/comms/cast events call it); the
-- per-frame OnUpdate merely re-reads each visible row's remaining seconds and repaints the
-- timer text (via the cheap store-only WQ.GetTrackerRemaining, no roster scan per frame).
do
    local HUD_W        = 172
    local HUD_ROW_H    = 22
    local HUD_HEADER_H = 20
    local HUD_PAD      = 6
    local HUD_BODY_TOP = HUD_PAD + HUD_HEADER_H + 4   -- y-offset of the first row below the header
    local HUD_KEY      = "soulstone"                  -- Stage-2 HUD shows the one tracked cooldown

    -- mm:ss for a minute+, else "Ns". Only called with remaining > 0.
    local function FormatCD(sec)
        sec = math.floor(sec + 0.5)
        if sec >= 60 then return ("%d:%02d"):format(math.floor(sec / 60), sec % 60) end
        return sec .. "s"
    end

    local hud = CreateFrame("Frame", "Warlock_Qol_Tbc_HUD", UIParent, "BackdropTemplate")
    hud:SetSize(HUD_W, HUD_BODY_TOP + HUD_ROW_H + HUD_PAD)
    hud:SetPoint("CENTER", UIParent, "CENTER", 320, 80)   -- default; user drags, then persisted
    hud:SetFrameStrata("MEDIUM")
    hud:SetClampedToScreen(true)
    ApplyFlat(hud, THEME.bg, true)
    hud:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.5)   -- ~50% transparent fill (border stays solid)
    hud:Hide()

    -- Header strip: title (also the visual grip). Mouse is NOT enabled on it, so drags fall
    -- through to the hud frame below, which owns the move.
    local hudHeader = CreateFrame("Frame", nil, hud, "BackdropTemplate")
    hudHeader:SetPoint("TOPLEFT",  hud, "TOPLEFT",   HUD_PAD, -HUD_PAD)
    hudHeader:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -HUD_PAD, -HUD_PAD)
    hudHeader:SetHeight(HUD_HEADER_H)
    ApplyFlat(hudHeader, THEME.panel, true)

    local hudTitle = hudHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(hudTitle, 12)
    hudTitle:SetPoint("LEFT", hudHeader, "LEFT", 6, 0)
    hudTitle:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    hudTitle:SetText("Raid Cooldowns")

    -- ── Persistence (position + shown + locked) — a top-level DB table like `ui`.
    local function HUDdb()
        local db = Warlock_Qol_Tbc_DB
        if not db then return nil end
        db.trackerHUD = db.trackerHUD or {}
        return db.trackerHUD
    end
    local function SaveHUDPlacement()
        local d = HUDdb(); if not d then return end
        local point, _, relPoint, x, y = hud:GetPoint()
        d.point, d.relPoint, d.x, d.y = point, relPoint, x, y
    end
    local function RestoreHUDPlacement()
        local d = HUDdb(); if not d or not d.point then return end
        hud:ClearAllPoints()
        hud:SetPoint(d.point, UIParent, d.relPoint, d.x, d.y)
    end

    -- Whole frame draggable (unless locked); saves position on release.
    hud:SetMovable(true)
    hud:EnableMouse(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", function()
        local d = HUDdb()
        if not (d and d.locked) then hud:StartMoving() end
    end)
    hud:SetScript("OnDragStop", function() hud:StopMovingOrSizing(); SaveHUDPlacement() end)

    -- Small close button at the header's far right, styled like the main window's (flat field,
    -- accent "X", hover-brighten). It closes the HUD (same as unticking "Show HUD"); it returns
    -- when you re-tick Show HUD, or on the next raid entry if Auto-show is on.
    local closeBtn = CreateFrame("Button", nil, hudHeader, "BackdropTemplate")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("RIGHT", hudHeader, "RIGHT", -3, 0)
    ApplyFlat(closeBtn, THEME.field, true)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    ApplyFont(closeX, 13)
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        closeX:SetTextColor(0.78, 0.78, 1.0)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    closeBtn:SetScript("OnClick", function() if WQ.DismissTrackerHUD then WQ.DismissTrackerHUD() end end)

    -- Padlock toggle in the header's top-right: lock/unlock the HUD's position right on the HUD
    -- (no need to open the config page). A small flat button matching the addon theme; the
    -- Blizzard padlock art is DESATURATED and tinted (accent = locked, dim = unlocked) so it
    -- reads cleanly on the dark header instead of the raw greenish button art. It's a button
    -- click (not a drag), so it still works while the HUD is locked.
    local lockBtn = CreateFrame("Button", nil, hudHeader, "BackdropTemplate")
    lockBtn:SetSize(16, 16)
    lockBtn:SetPoint("RIGHT", closeBtn, "LEFT", -3, 0)   -- sits just left of the close button
    ApplyFlat(lockBtn, THEME.field, true)
    local lockTex = lockBtn:CreateTexture(nil, "ARTWORK")
    lockTex:SetPoint("TOPLEFT",     lockBtn, "TOPLEFT",      2, -2)
    lockTex:SetPoint("BOTTOMRIGHT", lockBtn, "BOTTOMRIGHT", -2,  2)
    if lockTex.SetDesaturated then lockTex:SetDesaturated(true) end
    local function RefreshLockIcon()
        local locked = HUDdb() and HUDdb().locked
        lockTex:SetTexture(locked and "Interface\\Buttons\\LockButton-Locked-Up"
                                   or "Interface\\Buttons\\LockButton-Unlocked-Up")
        local c = locked and THEME.accent or THEME.textDim
        lockTex:SetVertexColor(c[1], c[2], c[3])
    end
    RefreshLockIcon()
    lockBtn:SetScript("OnClick", function()
        local d = HUDdb()
        WQ.SetTrackerHUDLocked(not (d and d.locked))   -- setter repaints the icon
    end)
    lockBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText((HUDdb() and HUDdb().locked) and "Unlock HUD position" or "Lock HUD position",
            THEME.text[1], THEME.text[2], THEME.text[3])
        GameTooltip:Show()
    end)
    lockBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        GameTooltip:Hide()
    end)

    -- CTRL+Click a row to announce that warlock's cooldown to the group, e.g.
    --   "Rimm: Soulstone - 17:34 remaining"   (or "… - Ready" when it's up).
    -- GROUP ONLY: RAID if in a raid, else PARTY if grouped; solo does nothing (never /say — it's
    -- a group callout, not something to broadcast to strangers).
    local function AnnounceCooldown(name)
        if not name or name == "" then return end
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if not channel then return end   -- not grouped: don't announce at all
        local spec  = WQ.TRACKED_COOLDOWNS and WQ.TRACKED_COOLDOWNS[HUD_KEY]
        local label = (spec and spec.label) or HUD_KEY
        local rem   = (WQ.GetTrackerRemaining and WQ.GetTrackerRemaining(HUD_KEY, name)) or 0
        local msg
        if rem and rem > 0 then
            msg = ("%s: %s - %s remaining"):format(name, label, FormatCD(rem))
        else
            msg = ("%s: %s - Ready"):format(name, label)
        end
        SendChatMessage(msg, channel)
    end

    -- ── Row pool. Each row: [cd icon] [warlock name] .......... [timer / Ready]. Rows are
    -- Buttons: a plain drag still moves the HUD (like the rest of the frame), and CTRL+Click
    -- announces that warlock's cooldown (see AnnounceCooldown).
    local hudRows = {}
    local function MakeHUDRow()
        local row = CreateFrame("Button", nil, hud)
        row:SetHeight(HUD_ROW_H)
        row:EnableMouse(true)

        -- Dragging a row moves the whole HUD (unless locked), matching the rest of the frame.
        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function()
            local dd = HUDdb()
            if not (dd and dd.locked) then hud:StartMoving() end
        end)
        row:SetScript("OnDragStop", function() hud:StopMovingOrSizing(); SaveHUDPlacement() end)
        -- CTRL+Click announces this row's warlock cooldown; a plain click does nothing.
        row:SetScript("OnClick", function(self)
            if IsControlKeyDown() then AnnounceCooldown(self.warlockName) end
        end)
        -- Subtle accent wash on hover so it's clear the rows are interactive. (The CTRL+Click
        -- action is documented in the Tracking page description rather than a per-row tooltip.)
        row:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        local hl = row:GetHighlightTexture()
        if hl then hl:SetVertexColor(THEME.accent[1], THEME.accent[2], THEME.accent[3], 0.12) end

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(HUD_ROW_H - 8, HUD_ROW_H - 8)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the default icon border
        row.icon = icon

        local timer = row:CreateFontString(nil, "OVERLAY")
        ApplyFont(timer, 12)
        timer:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        timer:SetJustifyH("RIGHT")
        row.timer = timer

        local name = row:CreateFontString(nil, "OVERLAY")
        ApplyFont(name, 12)
        name:SetPoint("LEFT",  icon,  "RIGHT", 5, 0)
        name:SetPoint("RIGHT", timer, "LEFT", -4, 0)   -- clip so a long name can't overrun the timer
        name:SetJustifyH("LEFT")
        row.name = name

        return row
    end

    -- Shown when there are no warlocks to display (so the frame isn't a confusing empty box).
    local hudEmpty = hud:CreateFontString(nil, "OVERLAY")
    ApplyFontItalic(hudEmpty, 11)
    hudEmpty:SetPoint("TOP", hudHeader, "BOTTOM", 0, -8)
    hudEmpty:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    hudEmpty:SetText("No warlocks in group")
    hudEmpty:Hide()

    -- Active rows currently shown: { row = <frame>, name = <warlock name> }. The tick reads
    -- each name's remaining time without a rebuild.
    local hudActive = {}

    local function UpdateHUDTimers()
        for _, a in ipairs(hudActive) do
            local rem = WQ.GetTrackerRemaining and WQ.GetTrackerRemaining(HUD_KEY, a.name) or 0
            if rem and rem > 0 then
                a.row.timer:SetText(FormatCD(rem))
                a.row.timer:SetTextColor(THEME.offRed[1], THEME.offRed[2], THEME.offRed[3])  -- on cooldown = red
            else
                a.row.timer:SetText("Ready")
                a.row.timer:SetTextColor(0.30, 0.80, 0.30)                                   -- ready = green
            end
        end
    end

    -- Rebuild the rows from the roster snapshot. Called on membership/data changes only.
    function WQ.RefreshTrackerHUD()
        if not hud:IsShown() then return end
        local snap = (WQ.GetTrackerSnapshot and WQ.GetTrackerSnapshot()) or {}
        local spec = WQ.TRACKED_COOLDOWNS and WQ.TRACKED_COOLDOWNS[HUD_KEY]
        wipe(hudActive)

        local y = -HUD_BODY_TOP
        local shown = 0
        for _, entry in ipairs(snap) do
            shown = shown + 1
            local row = hudRows[shown] or MakeHUDRow()
            hudRows[shown] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  hud, "TOPLEFT",   HUD_PAD, y)
            row:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -HUD_PAD, y)
            row.icon:SetTexture(spec and spec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(entry.name)
            row.warlockName = entry.name   -- CTRL+Click announce reads this
            -- The player's own row is tinted accent; others off-white, so you spot yourself.
            if entry.isPlayer then
                row.name:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
            else
                row.name:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
            end
            row:Show()
            hudActive[shown] = { row = row, name = entry.name }
            y = y - HUD_ROW_H
        end
        for i = shown + 1, #hudRows do hudRows[i]:Hide() end

        if shown == 0 then
            hudEmpty:Show()
            hud:SetHeight(HUD_BODY_TOP + HUD_ROW_H + HUD_PAD)
        else
            hudEmpty:Hide()
            hud:SetHeight(HUD_BODY_TOP + shown * HUD_ROW_H + HUD_PAD)
        end
        UpdateHUDTimers()   -- paint immediately; don't wait for the next tick
    end

    -- Live tick — repaint the countdowns a few times a second (cheap: store reads only).
    local acc = 0
    hud:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.2 then return end
        acc = 0
        UpdateHUDTimers()
    end)

    -- ── Show / lock. The HUD AUTO-shows based on the current group context and the per-profile
    -- auto-show toggles (raid on by default, party off) — there is no separate manual master.
    -- While the Tracking config page is open we FORCE it visible (a live preview) so it can be
    -- positioned even when solo.
    -- Visibility is driven by ONE persisted flag, trackerHUD.open (the "Show HUD" toggle and the
    -- HUD's X button both set it directly — so Show HUD ALWAYS takes effect). The separate
    -- per-profile "Auto-show in raid" toggle just DRIVES that flag on raid transitions: entering
    -- a raid opens the HUD, leaving it closes it (when auto-show is on). Raid-only feature.
    local wasInRaid = false   -- last-seen raid state, to detect enter/leave transitions

    -- Recompute visibility and show/hide. Exposed so the core calls it on the feature flag, the
    -- auto-show toggle, and roster changes (the roster call is what drives the raid transition).
    local function ApplyHUDVisibility()
        local d = HUDdb()
        if not d then hud:Hide(); return end
        local nowRaid = IsInRaid()
        if nowRaid ~= wasInRaid then
            -- Raid entered/left: auto-show opens the HUD on entering and closes it on leaving.
            -- (Manual "Show HUD" and the X button set d.open directly, independent of this.)
            if WQ.IsTrackerShowRaid() then d.open = nowRaid and true or false end
            wasInRaid = nowRaid
        end
        -- Master switch also gates the HUD (like the consumables HUD), so toggling it off hides this.
        local want = WQ.IsMasterEnabled() and WQ.IsTrackerEnabled() and d.open
        if want then hud:Show(); WQ.RefreshTrackerHUD() else hud:Hide() end
        -- Keep the Tracking page's "Show HUD" checkbox in step (e.g. the HUD's own X button, or
        -- auto-show opening/closing on a raid transition, changed d.open).
        if WQ.SyncTrackerPage then WQ.SyncTrackerPage() end
    end
    WQ.UpdateTrackerHUDVisibility = ApplyHUDVisibility

    -- Manual open/close: the "Show HUD" toggle, the HUD's X button, and /run ToggleTrackerHUD().
    function WQ.IsTrackerHUDOpen() local d = HUDdb(); return d and d.open or false end
    function WQ.SetTrackerHUDOpen(on)
        local d = HUDdb(); if d then d.open = on and true or false end
        ApplyHUDVisibility()
    end
    function WQ.ToggleTrackerHUD() WQ.SetTrackerHUDOpen(not WQ.IsTrackerHUDOpen()) end
    function WQ.DismissTrackerHUD() WQ.SetTrackerHUDOpen(false) end   -- the HUD's X button

    function WQ.IsTrackerHUDLocked() local d = HUDdb(); return d and d.locked or false end
    function WQ.SetTrackerHUDLocked(on)
        local d = HUDdb(); if d then d.locked = on and true or false end
        RefreshLockIcon()
    end

    -- Called from the core's PLAYER_LOGIN (DB guaranteed ready): restore saved position + lock
    -- icon, then apply auto-show visibility for the current context.
    function WQ.InitTrackerHUD()
        RestoreHUDPlacement()
        RefreshLockIcon()
        ApplyHUDVisibility()
    end
end

-- ── Missing Consumables HUD (Stage B) ──────────────────────────────────────────
-- A standalone, movable icon STRIP (separate from the /wq window) showing which raid
-- consumables are MISSING (glowing icon) or about to EXPIRE (icon + countdown). Purely local
-- (no comms) — it reads WQ.GetConsumableSnapshot(), which scans the player's own buffs +
-- weapon enchant. Unlike the cooldown HUD it APPEARS/DISAPPEARS by data, so a lightweight
-- driver re-scans a few times a second (even while hidden) to know when to pop it up.
do
    local ICON      = 35                    -- visible icon size
    local GLOW_PAD  = 5                     -- transparent margin around each icon so the glow sits OUTSIDE it
    local CELL      = ICON + GLOW_PAD * 2   -- the frame each icon lives in (the glow frames THIS)
    local GAP       = 0                     -- extra gap between cells (they already carry the glow margin)
    local PAD       = 6
    local HEADER_H  = 20
    local BODY_TOP  = PAD + HEADER_H + 4    -- y-offset of the icon row below the header
    local HUD_W     = 172                   -- fixed; matches the Raid Cooldowns HUD width (icons centre within it)

    -- mm:ss for a minute+, else "Ns". Only called with remaining > 0.
    local function FormatCD(sec)
        sec = math.floor(sec + 0.5)
        if sec >= 60 then return ("%d:%02d"):format(math.floor(sec / 60), sec % 60) end
        return sec .. "s"
    end

    local hud = CreateFrame("Frame", "Warlock_Qol_Tbc_ConsumeHUD", UIParent, "BackdropTemplate")
    hud:SetSize(HUD_W, BODY_TOP + CELL + PAD)
    hud:SetPoint("CENTER", UIParent, "CENTER", 320, -40)   -- default; user drags, then persisted
    hud:SetFrameStrata("MEDIUM")
    hud:SetClampedToScreen(true)
    ApplyFlat(hud, THEME.bg, true)
    hud:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.5)   -- ~50% transparent fill (border stays solid)
    hud:Hide()

    -- Header strip: title (also the visual grip). Mouse is NOT enabled on it, so drags fall
    -- through to the hud frame below, which owns the move. Matches the cooldown HUD's header.
    local hudHeader = CreateFrame("Frame", nil, hud, "BackdropTemplate")
    hudHeader:SetPoint("TOPLEFT",  hud, "TOPLEFT",   PAD, -PAD)
    hudHeader:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -PAD)
    hudHeader:SetHeight(HEADER_H)
    ApplyFlat(hudHeader, THEME.panel, true)

    local hudTitle = hudHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(hudTitle, 12)
    hudTitle:SetPoint("LEFT", hudHeader, "LEFT", 6, 0)
    hudTitle:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    hudTitle:SetText("Missing Consumables")

    -- ── Persistence (position + open + locked) — a top-level DB table like `trackerHUD`.
    local function HUDdb()
        local db = Warlock_Qol_Tbc_DB
        if not db then return nil end
        db.consumeHUD = db.consumeHUD or {}
        return db.consumeHUD
    end
    local function SaveHUDPlacement()
        local d = HUDdb(); if not d then return end
        local point, _, relPoint, x, y = hud:GetPoint()
        d.point, d.relPoint, d.x, d.y = point, relPoint, x, y
    end
    local function RestoreHUDPlacement()
        local d = HUDdb(); if not d or not d.point then return end
        hud:ClearAllPoints()
        hud:SetPoint(d.point, UIParent, d.relPoint, d.x, d.y)
    end

    -- Whole frame draggable (unless locked); saves position on release.
    hud:SetMovable(true)
    hud:EnableMouse(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", function() hud:StartMoving() end)
    hud:SetScript("OnDragStop", function() hud:StopMovingOrSizing(); SaveHUDPlacement() end)

    -- Close button (far right of the header) — same style as the main window / cooldown HUD.
    -- Closes the HUD (clears the manual "Show HUD" flag); auto-show re-opens it in a raid.
    local closeBtn = CreateFrame("Button", nil, hudHeader, "BackdropTemplate")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("RIGHT", hudHeader, "RIGHT", -3, 0)
    ApplyFlat(closeBtn, THEME.field, true)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    ApplyFont(closeX, 13)
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        closeX:SetTextColor(0.78, 0.78, 1.0)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    closeBtn:SetScript("OnClick", function() if WQ.DismissConsumablesHUD then WQ.DismissConsumablesHUD() end end)

    -- ── Glow (the "missing" highlight). Prefer Blizzard's stock proc glow (the exact
    -- `buttonOverlay` look the reference WA uses; a FrameXML global, so still dependency-free);
    -- fall back to a hand-rolled pulsing IconAlert texture if that global is absent on 2.5.5.
    local blizzGlowOK = ActionButton_ShowOverlayGlow and true or false   -- flipped off if it errors
    local function FallbackGlow(cell)
        if not cell._fallbackGlow then
            local g = cell:CreateTexture(nil, "OVERLAY")
            g:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
            g:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
            g:SetPoint("TOPLEFT",     cell, "TOPLEFT",     -6,  6)
            g:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT",  6, -6)
            g:SetBlendMode("ADD")
            local ag = g:CreateAnimationGroup()
            ag:SetLooping("BOUNCE")
            local a = ag:CreateAnimation("Alpha")
            a:SetFromAlpha(1.0); a:SetToAlpha(0.35); a:SetDuration(0.6)
            cell._fallbackGlow, cell._fallbackAG = g, ag
        end
        cell._fallbackGlow:Show(); cell._fallbackAG:Play()
    end
    local function StartGlow(cell)
        if cell._glowing then return end
        -- Prefer Blizzard's stock proc glow; if the call ever errors on this client, remember
        -- that and use the hand-rolled pulse from then on (never error the driver tick).
        if blizzGlowOK then
            local ok = pcall(ActionButton_ShowOverlayGlow, cell)
            if not ok then blizzGlowOK = false; FallbackGlow(cell) end
        else
            FallbackGlow(cell)
        end
        cell._glowing = true
    end
    local function StopGlow(cell)
        if not cell._glowing then return end
        if blizzGlowOK and ActionButton_HideOverlayGlow then pcall(ActionButton_HideOverlayGlow, cell) end
        if cell._fallbackGlow then cell._fallbackAG:Stop(); cell._fallbackGlow:Hide() end
        cell._glowing = false
    end

    -- ── Icon cell pool. Each cell: a themed slot + the consumable icon + a centered countdown
    -- (shown only for "low"). Cells are NOT mouse-enabled, so drags on them fall through to the
    -- hud (the whole strip drags).
    local cells = {}
    local function MakeCell()
        -- The cell is ICON + 2*GLOW_PAD; the icon lives in a themed slot centered inside it, so
        -- the extra margin is transparent and the glow (which frames the CELL) sits OUTSIDE the
        -- icon rather than clipping over it.
        local cell = CreateFrame("Frame", nil, hud)
        cell:SetSize(CELL, CELL)
        local slot = CreateFrame("Frame", nil, cell, "BackdropTemplate")
        slot:SetSize(ICON, ICON)
        slot:SetPoint("CENTER", cell, "CENTER", 0, 0)
        ApplyFlat(slot, THEME.field, true)
        local icon = slot:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT",     slot, "TOPLEFT",      2, -2)
        icon:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2,  2)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        cell.icon = icon
        -- Countdown parented to the slot (OVERLAY) so it draws above the icon. OUTLINE + shadow
        -- makes the small white text read clearly over the busy icon art (it's hard to see plain).
        local timer = slot:CreateFontString(nil, "OVERLAY")
        ApplyFont(timer, 13, "OUTLINE")
        timer:SetPoint("CENTER", slot, "CENTER", 0, 0)
        timer:SetTextColor(1, 1, 1)
        timer:SetShadowColor(0, 0, 0, 1)
        timer:SetShadowOffset(1, -1)
        cell.timer = timer
        return cell
    end

    -- Lay out one cell per shown consumable; glow the missing ones (the "low" ones instead get a
    -- countdown from UpdateTimers), size the frame to fit.
    local function Rebuild(shown)
        local n = #shown
        -- Centre the icon row within the fixed-width frame (so 1–3 icons sit in the middle, not
        -- packed to the left).
        local contentW = n * CELL + math.max(0, n - 1) * GAP
        local startX   = math.floor((HUD_W - contentW) / 2 + 0.5)
        for i = 1, n do
            local r    = shown[i]
            local cell = cells[i] or MakeCell()
            cells[i] = cell
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", hud, "TOPLEFT", startX + (i - 1) * (CELL + GAP), -BODY_TOP)
            cell.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            cell:SetAlpha(1)
            cell.timer:SetText("")
            -- Glow the missing ones, unless the player turned the glow off (then just a plain icon).
            if r.status == "missing" and WQ.IsConsumeGlow() then StartGlow(cell) else StopGlow(cell) end
            cell:Show()
        end
        for i = n + 1, #cells do StopGlow(cells[i]); cells[i]:Hide() end

        -- Width is fixed (matches the cooldown HUD); only the height is set here for clarity.
        hud:SetHeight(BODY_TOP + CELL + PAD)
    end

    -- Refresh just the countdown text on the "low" cells (called every tick so it counts down).
    local function UpdateTimers(shown)
        for i, r in ipairs(shown) do
            local cell = cells[i]
            if cell and cell:IsShown() and r.status == "low" and r.remaining > 0 then
                cell.timer:SetText(FormatCD(r.remaining))
            end
        end
    end

    -- ── Visibility / content. Single evaluation used by both the driver tick and the setters.
    -- want = feature active AND (manual "open" OR the raid auto-show context). Content = ONLY the
    -- missing/low consumables; when there are none the HUD hides COMPLETELY (present/healthy
    -- consumables never show — that's the whole point). No preview: "Show HUD" just enables the
    -- HUD to appear when something is actually missing, it does not force it visible.
    local lastSig = nil
    local function Evaluate()
        if not WQ.IsConsumablesActive() then hud:Hide(); lastSig = nil; return end
        local d = HUDdb()
        local open     = d and d.open
        local autoRaid = IsInRaid() and WQ.IsConsumeShowRaid()
        if not (open or autoRaid) then hud:Hide(); lastSig = nil; return end

        local snap = (WQ.GetConsumableSnapshot and WQ.GetConsumableSnapshot()) or {}
        local shown = {}
        for _, r in ipairs(snap) do
            if r.status == "missing" or r.status == "low" then shown[#shown + 1] = r end
        end
        if #shown == 0 then hud:Hide(); lastSig = nil; return end

        local sig = ""
        for _, r in ipairs(shown) do sig = sig .. r.key .. ":" .. r.status .. "," end
        if sig ~= lastSig then Rebuild(shown); lastSig = sig end
        UpdateTimers(shown)
        if not hud:IsShown() then hud:Show() end
        -- NOTE: the page checkbox sync is NOT done here — Evaluate runs ~2.5×/s from the driver,
        -- and re-syncing would clobber the threshold edit box mid-type. It's synced in
        -- SetConsumeHUDOpen instead (the only thing that changes the "Show HUD" flag).
    end
    WQ.UpdateConsumablesHUDVisibility = Evaluate
    WQ.RefreshConsumablesHUD = function() lastSig = nil; Evaluate() end   -- force a rebuild

    -- ── Driver: a lightweight always-present frame that re-evaluates a few times a second while
    -- the feature is active. Needed because the strip must APPEAR when something goes missing
    -- (or a weapon oil silently expires — which fires no event) even while the HUD is hidden.
    -- Stopped entirely when the feature is off, so a disabled feature costs nothing.
    local driver = CreateFrame("Frame", nil, UIParent)
    local acc = 0
    local function OnDriver(_, elapsed)
        acc = acc + elapsed
        if acc < 0.4 then return end
        acc = 0
        Evaluate()
    end
    function WQ.UpdateConsumablesRegistration()
        if WQ.IsConsumablesActive() then
            driver:SetScript("OnUpdate", OnDriver)
        else
            driver:SetScript("OnUpdate", nil)
            hud:Hide(); lastSig = nil
        end
    end

    -- Manual open/close: the "Show HUD" toggle, the HUD's X button, and /run ToggleConsumablesHUD().
    function WQ.IsConsumeHUDOpen() local d = HUDdb(); return d and d.open or false end
    function WQ.SetConsumeHUDOpen(on)
        local d = HUDdb(); if d then d.open = on and true or false end
        Evaluate()
        -- Keep the config page's "Show HUD" checkbox in step (e.g. the HUD's own X button flipped it).
        if WQ.SyncConsumablesPage then WQ.SyncConsumablesPage() end
    end
    function WQ.ToggleConsumablesHUD() WQ.SetConsumeHUDOpen(not WQ.IsConsumeHUDOpen()) end
    function WQ.DismissConsumablesHUD() WQ.SetConsumeHUDOpen(false) end   -- the HUD's X button

    -- Called from the core's PLAYER_LOGIN (DB ready): restore position, start the driver if the
    -- feature's on, and apply visibility for the current context.
    function WQ.InitConsumablesHUD()
        RestoreHUDPlacement()
        WQ.UpdateConsumablesRegistration()
        Evaluate()
    end
end

-- ── Minimap button ──────────────────────────────────────────────────────────────
-- A classic draggable minimap button, hand-rolled (dependency-free — no LibDBIcon/LibStub).
-- Left-click opens the /wq window; drag slides it around the minimap ring. Its position (an
-- angle in degrees) and hidden state are PER-CHARACTER, stored in CharState by the core. The
-- button frame is created here always but positioned/shown on PLAYER_LOGIN via WQ.InitMinimap
-- (once CharState is resolved). The title-bar "Minimap" checkbox drives WQ.Is/SetMinimapHidden.
do
    local DEFAULT_ANGLE = 200   -- degrees; lower-left by default, clear of the zoom +/- buttons

    -- Minimap SHAPE support (so the button sits correctly on SQUARE minimaps like ElvUI's, not
    -- just the default circle) WITHOUT LibDBIcon. Minimap-skinning addons expose a global
    -- GetMinimapShape() returning one of these names; each entry flags whether each QUADRANT is
    -- rounded (true) or squared (false), ordered {bottom-right, bottom-left, top-right, top-left}.
    -- Absent (stock Blizzard UI) → treat as ROUND. This is the same public shape table LibDBIcon
    -- uses — replicating ~20 lines of math is NOT a dependency.
    local MINIMAP_SHAPES = {
        ["ROUND"]                 = { true,  true,  true,  true  },
        ["SQUARE"]                = { false, false, false, false },
        ["CORNER-TOPLEFT"]        = { false, false, false, true  },
        ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
        ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
        ["CORNER-BOTTOMRIGHT"]    = { true,  false, false, false },
        ["SIDE-LEFT"]             = { false, true,  false, true  },
        ["SIDE-RIGHT"]            = { true,  false, true,  false },
        ["SIDE-TOP"]              = { false, false, true,  true  },
        ["SIDE-BOTTOM"]           = { true,  true,  false, false },
        ["TRICORNER-TOPLEFT"]     = { false, true,  true,  true  },
        ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true  },
        ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true  },
        ["TRICORNER-BOTTOMRIGHT"] = { true,  true,  true,  false },
    }

    local btn = CreateFrame("Button", "Warlock_Qol_Tbc_MinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp")   -- left-click only for now (may add more later)
    btn:RegisterForDrag("LeftButton")

    -- Subjugate Demon (a.k.a. Enslave Demon) spell icon — trimmed of its default border.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture("Interface\\Icons\\Spell_Shadow_EnslaveDemon")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Classic round bezel so it matches every other minimap button.
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Place the button from the current angle, hugging the minimap edge — on the circle for a
    -- rounded quadrant, clamped to the square's edge for a squared one. `w`/`h` come from the live
    -- minimap size (+5px) so this tracks whatever size ElvUI (or Blizzard) gives the minimap.
    local angle = DEFAULT_ANGLE
    local function UpdatePosition()
        local a = math.rad(angle)
        local x, y = math.cos(a), math.sin(a)
        local q = 1
        if x < 0 then q = q + 1 end
        if y > 0 then q = q + 2 end
        local shape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
        local quad  = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES["ROUND"]
        local w = (Minimap:GetWidth()  / 2) + 5
        local h = (Minimap:GetHeight() / 2) + 5
        if quad[q] then
            x, y = x * w, y * h                       -- rounded quadrant: sit on the ellipse
        else
            local dw = math.sqrt(2 * w * w) - 10      -- squared quadrant: clamp the ray to the edge
            local dh = math.sqrt(2 * h * h) - 10
            x = math.max(-w, math.min(x * dw, w))
            y = math.max(-h, math.min(y * dh, h))
        end
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- Reposition if the minimap is resized (ElvUI etc. can change its size after login).
    Minimap:HookScript("OnSizeChanged", function() UpdatePosition() end)

    -- Drag: turn the cursor's position (relative to the minimap centre) back into an angle.
    local dragging = false
    local function OnDragUpdate()
        local mx, my = Minimap:GetCenter()
        local scale  = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx, cy = cx / scale, cy / scale
        angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
        UpdatePosition()
    end
    btn:SetScript("OnDragStart", function(self)
        dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    btn:SetScript("OnDragStop", function(self)
        dragging = false
        self:SetScript("OnUpdate", nil)
        local cs = WQ.CharState and WQ.CharState()
        if cs then cs.minimapAngle = angle end   -- persist the new position (per-character)
    end)

    -- Left-click toggles the main window (open if closed, close if open) — same as /wq.
    btn:SetScript("OnClick", function()
        if f:IsShown() then f:Hide() elseif WQ.OpenHome then WQ.OpenHome() end
    end)

    btn:SetScript("OnEnter", function(self)
        if dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("WarlockQol (TBC)", THEME.accent[1], THEME.accent[2], THEME.accent[3])
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:Hide()   -- shown by InitMinimap once the per-character hidden flag is known

    -- Public API + login init. Hidden state + angle are per-character (CharState); a nil flag
    -- means "shown" (the default) and a nil angle means DEFAULT_ANGLE.
    function WQ.IsMinimapHidden()
        local cs = WQ.CharState and WQ.CharState()
        return (cs and cs.minimapHide) and true or false
    end
    function WQ.SetMinimapHidden(hide)
        hide = hide and true or false
        local cs = WQ.CharState and WQ.CharState()
        if cs then cs.minimapHide = hide end
        if hide then btn:Hide() else btn:Show() end
    end
    -- Called from the core's PLAYER_LOGIN once CharState is resolved.
    function WQ.InitMinimap()
        local cs = WQ.CharState and WQ.CharState()
        if cs and cs.minimapAngle then angle = cs.minimapAngle end
        UpdatePosition()
        if cs and cs.minimapHide then btn:Hide() else btn:Show() end
    end
end

-- ── First-run Setup Wizard ─────────────────────────────────────────────────────
-- A one-page standalone welcome window shown once per character on first login (the core's
-- PLAYER_LOGIN calls WQ.ShowWizard when the per-char setupComplete flag is unset). It gives a
-- short intro and a Create Macros button; the Finish button dismisses it and opens the main hub.
-- Re-openable from the Reset page's "Show Setup Guide". A Hard Reset recreates this char's
-- CharState with setupComplete=false, so the wizard returns on the next /reload.
--
-- IMPORTANT: setupComplete is set by FinishWizard (the Finish button), NOT on open — so a
-- /reload part-way through re-shows it. It is deliberately NOT a UISpecialFrame and does NOT
-- complete on OnHide (see the notes below — a login-time hide must not corrupt the flag). Uses
-- the same THEME/ApplyFlat/ApplyFont/MakeFlatButton helpers as the rest of the UI; it's a
-- separate frame on UIParent (not a page in the /wq window).
do
    local W, H, P = 460, 300, 16
    local wiz = CreateFrame("Frame", "Warlock_Qol_Tbc_Wizard", UIParent, "BackdropTemplate")
    wiz:SetSize(W, H)
    wiz:SetPoint("CENTER")
    wiz:SetFrameStrata("FULLSCREEN_DIALOG")  -- above the main /wq window (DIALOG strata)
    wiz:SetToplevel(true)
    ApplyFlat(wiz, THEME.bg, true)
    wiz:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.8)  -- match the main frame's subtle fill
    wiz:Hide()

    -- Draggable anywhere on its body. Position isn't persisted — it's a transient one-shot.
    wiz:SetMovable(true)
    wiz:EnableMouse(true)
    wiz:RegisterForDrag("LeftButton")
    wiz:SetScript("OnDragStart", wiz.StartMoving)
    wiz:SetScript("OnDragStop",  wiz.StopMovingOrSizing)

    -- Deliberately NOT registered in UISpecialFrames. The game calls CloseSpecialWindows()
    -- during the login sequence, which would hide the wizard the instant it auto-opens on
    -- first run — and that stray Hide used to fire the completion logic (flag + open hub),
    -- so the wizard "flashed" and the player only ever saw the main window. Dismissal is the
    -- Finish button only (FinishWizard, below), which matches the one-page spec anyway.

    -- Title + divider (fixed offsets, like the Reset page).
    local title = wiz:CreateFontString(nil, "OVERLAY")
    ApplyFont(title, 16)
    title:SetPoint("TOPLEFT", wiz, "TOPLEFT", P, -P)
    title:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    title:SetText("Welcome to WarlockQol")

    local div = wiz:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    div:SetPoint("TOPLEFT",  wiz, "TOPLEFT",  P,  -(P + 26))
    div:SetPoint("TOPRIGHT", wiz, "TOPRIGHT", -P, -(P + 26))
    div:SetHeight(1)

    -- Intro body. Accent-coloured inline highlights match the rest of the UI (HEX_ACCENT).
    local body = wiz:CreateFontString(nil, "OVERLAY")
    ApplyFont(body, 12)
    body:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    body:SetPoint("TOPLEFT",  wiz, "TOPLEFT",  P,  -(P + 40))
    body:SetPoint("TOPRIGHT", wiz, "TOPRIGHT", -P, -(P + 40))
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(5)
    body:SetText(
        "WarlockQol adds quality-of-life tools for Warlocks — flavour chat lines for your "..
        "demon summons and rituals, automatic Soulstone and Banish announcements, and raid "..
        "HUDs for cooldowns and missing consumables.\n\n"..
        ("Most chat features run from one-click macros the addon builds for you. Click "..
         "|cff%sCreate Macros|r below to generate them, then drag each |cff%sWQoL|r macro "..
         "onto an action bar.\n\n"):format(HEX_ACCENT, HEX_ACCENT)..
        ("Re-open this window anytime with command |cff%s/wq|r or with the minimap icon."):format(HEX_ACCENT))

    -- Status line: either a combat note (offRed) or a create-result message (accent). Sits
    -- just above the button row.
    local status = wiz:CreateFontString(nil, "OVERLAY")
    ApplyFont(status, 12)
    status:SetJustifyH("LEFT")
    status:SetSpacing(4)
    status:SetPoint("BOTTOMLEFT",  wiz, "BOTTOMLEFT",  P, P + 34)
    status:SetPoint("BOTTOMRIGHT", wiz, "BOTTOMRIGHT", -P, P + 34)
    status:SetText("")

    -- Buttons: Create Macros (left) / Finish (right).
    local createBtn = MakeFlatButton(wiz, "Create Macros", 130, 26)
    createBtn:SetPoint("BOTTOMLEFT", wiz, "BOTTOMLEFT", P, P)

    local finishBtn = MakeFlatButton(wiz, "Finish", 110, 26)
    finishBtn:SetPoint("BOTTOMRIGHT", wiz, "BOTTOMRIGHT", -P, P)

    -- Combat gating: macro edits are blocked in combat, so disable Create + show a note while
    -- in lockdown, and restore on leaving combat (without clobbering a create-result message).
    local function ShowCombatNote()
        status:SetTextColor(THEME.offRed[1], THEME.offRed[2], THEME.offRed[3])
        status:SetText("You're in combat — macros can't be created until you leave combat.")
        status.mode = "combat"
    end
    local function UpdateCombat()
        if InCombatLockdown() then
            createBtn:Disable()
            createBtn.label:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
            ShowCombatNote()
        else
            createBtn:Enable()
            createBtn.label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
            if status.mode == "combat" then status:SetText(""); status.mode = nil end
        end
    end

    createBtn:SetScript("OnClick", function()
        if InCombatLockdown() then ShowCombatNote(); return end
        local c, u, conflicts = WQ.CreateAllMacros()
        WQ.ReportMacroResult(c, u, conflicts)  -- prints the detailed breakdown to chat
        status:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        status.mode = "result"
        if conflicts and #conflicts > 0 then
            status:SetText("Macros created — some names clashed with your own (see chat). "..
                           "Drag each 'WQoL' macro onto an action bar.")
        else
            status:SetText("Macros ready — drag each 'WQoL' macro onto an action bar. "..
                           "(Details in chat.)")
        end
    end)

    -- Completion is EXPLICIT (the Finish button), never on OnHide. Marking setup complete on
    -- OnHide meant ANY hide — including the login-time CloseSpecialWindows sweep noted above —
    -- flipped the flag and opened the hub behind the player. Setting the flag on dismiss (not
    -- on open) still means an unfinished wizard re-shows after a /reload.
    local function FinishWizard()
        local ch = WQ.CharState and WQ.CharState()
        if ch then ch.setupComplete = true end
        wiz:Hide()
        if WQ.OpenHome then WQ.OpenHome() end
    end
    finishBtn:SetScript("OnClick", FinishWizard)

    wiz:SetScript("OnEvent", function() UpdateCombat() end)

    wiz:SetScript("OnShow", function(self)
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        status:SetText(""); status.mode = nil
        UpdateCombat()
    end)

    -- OnHide only tears down the combat listeners — NO completion side effects (see FinishWizard).
    wiz:SetScript("OnHide", function(self)
        self:UnregisterEvent("PLAYER_REGEN_DISABLED")
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end)

    function WQ.ShowWizard()   wiz:Show() end
    function WQ.ToggleWizard() if wiz:IsShown() then wiz:Hide() else wiz:Show() end end
end

-- Start on the home page so the first /wq (or first-run OpenHome) lands on the hub.
ShowPage("home")
