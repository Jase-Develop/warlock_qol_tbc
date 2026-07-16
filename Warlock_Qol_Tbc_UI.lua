-- Warlock_Qol_Tbc_UI.lua — Config UI: ElvUI-style flat-dark window built in Lua (no XML, no libs).
-- One container frame: title bar + fixed-width left nav sidebar + content area of swappable
-- pages, one shown at a time via ShowPage(name). Loaded after the core, so WQ already exists.

local WQ = Warlock_Qol_Tbc

-- ── Window geometry ───────────────────────────────────────────────────────────
local FRAME_W  = 800   -- default frame width (resizable)
local FRAME_H  = 600   -- default frame height (resizable)
local MIN_W, MIN_H = 600, 558   -- shrink limit (fits the 3-section nav, pinned buttons, Profiles Share section)
local MAX_W, MAX_H = 940, 780   -- grow limit
local ROW_H    = 26    -- height of each line entry in the scroll list
local ROW_POOL = 24    -- row frames created per list (enough for MAX_H); visible count computed from list height

local PAD        = 8    -- outer/gutter padding between the chrome pieces
local TITLEBAR_H = 30   -- height of the top title strip (brand + close button)
local SIDEBAR_W  = 160  -- fixed width of the left nav column
local NAV_H      = 26   -- height of each nav item

-- Raid marker tokens → icon number in UI-RaidTargetingIcon_N (1–8), for the line-list preview.
-- DISPLAY ONLY — the stored line and what SendChatMessage sends stay as the raw token text.
local RAID_ICON_TOKENS = {
    star = 1, circle = 2, diamond = 3, triangle = 4,
    moon = 5, square = 6, cross = 7, x = 7, skull = 8,
    rt1 = 1, rt2 = 2, rt3 = 3, rt4 = 4, rt5 = 5, rt6 = 6, rt7 = 7, rt8 = 8,
}

-- The 8 raid markers in game order, each with the {token} its quick-insert button inserts.
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

-- Swap any {token} raid-marker for its inline texture escape (":0" scales to the font line height).
local function RenderIconTokens(text)
    if not text then return text end
    return (text:gsub("{(%w+)}", function(name)
        local n = RAID_ICON_TOKENS[name:lower()]
        if n then
            return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. n .. ":0|t"
        end
        return "{" .. name .. "}"  -- not a raid-icon token (e.g. {targetName}) — leave it
    end))
end

-- ── Theme ──────────────────────────────────────────────────────────────────────
-- ElvUI-style flat dark palette in one table (single-edit re-theme). RGB 0–1; hex is for |c…| text.
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

-- ── Accent colour (user-settable on the Settings page) ───────────────────────────
-- THEME.accent is mutated IN PLACE so the many handlers that read it live (hover borders, checkbox
-- state, nav highlight, row select) pick up a change on their next fire for free. The set-once
-- elements can't, so accentAppliers holds a re-tint closure per element (registered via AccentText/
-- AccentFill/RegisterAccent); WQ.ReapplyAccent mutates the colour then runs them all.
local accentAppliers = {}

local function HexToRGB(hex)
    return (tonumber(hex:sub(1, 2), 16) or 135) / 255,
           (tonumber(hex:sub(3, 4), 16) or 136) / 255,
           (tonumber(hex:sub(5, 6), 16) or 238) / 255
end
local function RGBToHex(r, g, b)
    return ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Colour a fontstring / texture with the accent AND register it for re-tint on accent change.
local function AccentText(fs)
    local fn = function() fs:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3]) end
    accentAppliers[#accentAppliers + 1] = fn; fn(); return fs
end
local function AccentFill(tex, alpha)
    local fn = function() tex:SetColorTexture(THEME.accent[1], THEME.accent[2], THEME.accent[3], alpha or 1) end
    accentAppliers[#accentAppliers + 1] = fn; fn(); return tex
end
-- Register a caller-supplied re-tint fn for state-driven bits (checkbox refresh, HUD padlock/rows,
-- the brand string). Runs it once now, and again on every accent change.
local function RegisterAccent(fn) accentAppliers[#accentAppliers + 1] = fn; fn() end

-- Mutate THEME.accent + HEX_ACCENT to the active profile's colour, then repaint every accented element.
function WQ.ReapplyAccent()
    local hex = (WQ.GetAccent and WQ.GetAccent()) or HEX_ACCENT
    THEME.accent[1], THEME.accent[2], THEME.accent[3] = HexToRGB(hex)
    HEX_ACCENT = hex
    for _, fn in ipairs(accentAppliers) do fn() end
end

-- ── Font ─────────────────────────────────────────────────────────────────────
-- The active UI font is chosen on the Settings page (a key into WQ.FONTS, stored per-profile). All
-- choices are stock client fonts (nothing bundled). CURRENT_FONT is the resolved path; the Settings
-- picker swaps it and calls WQ.ReapplyFont, which repaints every fontstring at once. SetFont returns
-- false on a bad/missing .ttf, so we always fall back to a stock font. Default = Arial Narrow.
local FONT_DEFAULT  = "Fonts\\ARIALN.TTF"
local FONT_FALLBACK = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local CURRENT_FONT  = FONT_DEFAULT   -- active path (updated by WQ.ReapplyFont)

-- Every styled fontstring is recorded here (keyed by the object, so re-styling just updates its entry)
-- so a font swap can repaint the whole UI + all HUDs in one pass.
local fontMeta = {}

-- Set obj's font to the active UI font (size in points, standard flag string), stock fallback on failure.
local function ApplyFont(obj, size, flags)
    flags = flags or ""
    fontMeta[obj] = { size = size, flags = flags }
    if not obj:SetFont(CURRENT_FONT, size, flags) then obj:SetFont(FONT_FALLBACK, size, flags) end
    return obj
end

-- Italic styling was dropped with the bundled PT Sans (stock fonts have no italic face); kept as an
-- alias so the few former-italic callers (the quote, the empty-list messages) render in the active font.
local ApplyFontItalic = ApplyFont

-- Repaint every recorded fontstring with the active font. Called from the core on login, profile
-- switch, hard reset, and when the Settings picker changes WQ.GetFont().
function WQ.ReapplyFont()
    local key = WQ.GetFont and WQ.GetFont() or "arialn"
    local opt = WQ.FONTS and WQ.FONTS[key]
    CURRENT_FONT = (opt and opt.path) or FONT_DEFAULT
    for obj, m in pairs(fontMeta) do
        if not obj:SetFont(CURRENT_FONT, m.size, m.flags) then obj:SetFont(FONT_FALLBACK, m.size, m.flags) end
    end
    if WQ.ApplyRangeFont then WQ.ApplyRangeFont() end   -- Range HUD width autosizes to the font
end

-- ── Flat-frame helper ───────────────────────────────────────────────────────────
-- Flat ElvUI-style backdrop: solid WHITE8X8 fill + optional 1px border (colour is whatever we set).
-- `frame` must have the BackdropTemplate mixin.
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
-- "BackdropTemplate" mixes in SetBackdrop (no longer a default method since 9.0).
local f = CreateFrame("Frame", "Warlock_Qol_Tbc_Frame", UIParent, "BackdropTemplate")
f:SetSize(FRAME_W, FRAME_H)
f:SetPoint("CENTER")  -- centre by default; player can drag it

-- Resizable (via the grip below), clamped. SetResizeBounds is modern; older clients use SetMin/MaxResize.
f:SetResizable(true)
if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
else
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end
end

-- Persist/restore frame size + position across sessions (in the DB).
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

-- Draggable (saves the new position on drag end).
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop",  function() f:StopMovingOrSizing(); SavePlacement() end)

-- DIALOG strata + toplevel: above most game UI, sorts above sibling DIALOG frames on click.
f:SetFrameStrata("DIALOG")
f:SetToplevel(true)
f:Hide()  -- hidden by default; /wq toggles it

-- Escape closes THIS window (name must match the global frame name).
tinsert(UISpecialFrames, "Warlock_Qol_Tbc_Frame")

-- Flat dark backdrop + 1px border; 0.8-alpha fill (subtle see-through, border stays solid — the
-- big frame reads as too transparent below this, unlike the HUDs' 0.5).
ApplyFlat(f, THEME.bg, true)
f:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.8)

-- ── Title bar (brand + close) ─────────────────────────────────────────────────
-- Charcoal strip across the top: addon name + version + close button.
local titleBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
titleBar:SetPoint("TOPLEFT",  f, "TOPLEFT",  PAD, -PAD)
titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -PAD)
titleBar:SetHeight(TITLEBAR_H)
ApplyFlat(titleBar, THEME.panel, true)

local function AddonVersion()
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return getMeta and getMeta("Warlock_Qol_Tbc", "Version") or "?"
end

-- App logo: Subjugate/Enslave Demon spell icon left of the brand (same art as the minimap button).
local logo = titleBar:CreateTexture(nil, "OVERLAY")
logo:SetSize(18, 18)
logo:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
logo:SetTexture("Interface\\Icons\\Spell_Shadow_EnslaveDemon")
logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local brand = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(brand, 15)
brand:SetPoint("LEFT", logo, "RIGHT", 6, 0)
-- Re-set on accent change (the brand bakes HEX_ACCENT into a |c…| colour code).
RegisterAccent(function()
    brand:SetText(("|cff%sWarlockQol (TBC)|r  |cff888888v%s|r"):format(HEX_ACCENT, AddonVersion()))
end)

-- Themed flat close button: a purple "X" on the flat field; hover brightens it; click hides the window.
local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
closeBtn:SetSize(22, 22)
closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
ApplyFlat(closeBtn, THEME.field, true)

local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
ApplyFont(closeX, 15)
closeX:SetPoint("CENTER")
closeX:SetText("X")
AccentText(closeX)

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
-- Pages fill this below a shared header. No backdrop and no mouse, so bottom-right clicks
-- fall through to the resize grip.
local content = CreateFrame("Frame", nil, f)
content:SetPoint("TOPLEFT",     sidebar, "TOPRIGHT",   PAD, 0)
content:SetPoint("BOTTOMRIGHT", f,       "BOTTOMRIGHT", -PAD, PAD)

-- Shared page header, built once (title top-left + "Enabled" toggle top-right, then subtitle, then
-- divider, then body). Wired by anchoring not pixels: divider hangs off subtitle, body off divider, so
-- a wrapped subtitle reflows everything and an empty one collapses the rule up under the title.
-- ShowPage only sets the subtitle text and toggle state per page.
local pageTitle = content:CreateFontString(nil, "OVERLAY")
ApplyFont(pageTitle, 16)
pageTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -6)
AccentText(pageTitle)

-- Forward-declared (created later, once StyleCheckbox exists) so ShowPage/NewPage capture them.
local pageSubtitle, pageDivider, enableCheck, enableLabel
local currentToggle   -- { get, set } toggle spec of the current page, or nil

-- ── Page navigation ───────────────────────────────────────────────────────────

local pages       = {}   -- name -> page frame
local titles      = {}   -- name -> header title text for that page
local subtitles   = {}   -- name -> description string shown under the title (or nil)
local toggleSpecs = {}   -- name -> { get, set } enable-toggle spec (or nil = no toggle)
local currentPage        -- name of the page currently shown
local UpdateNav          -- forward decl: highlights the nav item for the current page

-- Show one page (hiding the rest), update the header, refresh the nav highlight, run its refresh hook.
local function ShowPage(name)
    -- Abandon any in-progress edit on the page we're leaving (currentPage is still the outgoing one).
    local leaving = currentPage and pages[currentPage]
    if leaving and leaving.CancelEdit and leaving ~= pages[name] then
        leaving.CancelEdit()
    end

    for n, p in pairs(pages) do
        if n == name then p:Show() else p:Hide() end
    end
    currentPage = name
    pageTitle:SetText(titles[name] or "WarlockQol (TBC)")

    -- Setting the text is enough; the divider + body reflow via anchoring (empty = rule up under title).
    pageSubtitle:SetText(subtitles[name] or "")

    -- Top-right enable toggle: show + sync for pages that have one, else hide. Read by its OnClick.
    currentToggle = toggleSpecs[name]
    if currentToggle then
        enableCheck:Show(); enableLabel:Show()
        enableCheck:SetChecked(currentToggle.get and currentToggle.get() and true or false)
        enableCheck.RefreshStateColor()  -- sync the on/off colour
    else
        enableCheck:Hide(); enableLabel:Hide()
    end

    if UpdateNav then UpdateNav(name) end
    local p = pages[name]
    if p and p.OnPageShow then p.OnPageShow() end
end

-- Closing the window (X/Escape/toggle) also abandons an in-progress edit, so the next open is clean.
f:HookScript("OnHide", function()
    local p = currentPage and pages[currentPage]
    if p and p.CancelEdit then p.CancelEdit() end
end)

-- Re-run the current page's refresh hook (wired to resize so row count/widgets update live).
local function RefreshCurrent()
    local p = currentPage and pages[currentPage]
    if p and p.OnPageShow then p.OnPageShow() end
end
f:SetScript("OnSizeChanged", RefreshCurrent)

-- Open the window on the home page (slash command + first-run).
local placementRestored = false
function WQ.OpenHome()
    -- Restore saved size/position once per session (DB is ready by now).
    if not placementRestored then
        RestorePlacement()
        placementRestored = true
    end
    f:Show()
    ShowPage("home")
end

-- Create a page: a child frame filling the content area below the shared divider, hidden until
-- selected. The header (title/subtitle/divider/toggle) is shared, so a page lays out only its body.
--   subtitle : optional description under the title (nil = none).
--   toggle   : optional { get = fn()->bool, set = fn(checked) }; shows + wires the shared "Enabled" box.
-- Anchored to the divider's bottom so it reflows when a wrapped subtitle pushes the divider down.
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
-- Bottom-right drag handle. The content/page frames overlap it but are mouse-transparent, so it gets clicks.
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
-- The building blocks every page reuses, themed once here for consistency.

-- Flat dark button with an accent hover border. SetText/OnClick work as normal. Returns the button.
local function MakeFlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    if w and h then b:SetSize(w, h) end
    ApplyFlat(b, THEME.panel, true)

    local fs = b:CreateFontString(nil, "OVERLAY")
    ApplyFont(fs, 12)
    fs:SetPoint("CENTER")
    fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    b.label = fs
    -- Drive our own FontString and override :SetText — Button:SetText draws nothing without a
    -- font *object* (SetNormalFontObject), which is why the flat buttons showed blank.
    fs:SetText(text or "")
    b.SetText = function(self, t) self.label:SetText(t or "") end

    -- Accent border + text on hover; flat charcoal otherwise.
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

-- Small square button showing one raid-marker icon (`iconN` = 1–8) for the quick-insert row.
-- Caller wires OnClick to insert the {token}; hover shows an accent border + a tooltip naming it.
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

-- Flat single-line edit box. Caller wires OnEnterPressed/OnEscapePressed. Returns the EditBox.
local function MakeFlatEditBox(parent)
    local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    ApplyFlat(e, THEME.field, true)
    ApplyFont(e, 12)
    e:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    e:SetTextInsets(6, 6, 2, 2)
    e:SetAutoFocus(false)
    -- Focus feedback: accent border while typing.
    e:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    e:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    end)
    return e
end

-- Flat fixed-height MULTILINE box (Profiles export/import). The EditBox sits in a bare ScrollFrame
-- that CLIPS it — a multiline EditBox otherwise renders all its text past its height, over the
-- controls below. Mouse wheel scrolls overflow; Ctrl+C still copies the full text.
-- Returns the container FRAME; do text ops on `.edit` (the inner EditBox).
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

    -- Keep the edit as wide as the scroll frame so text wraps to the box width.
    scroll:SetScript("OnSizeChanged", function(_, w) edit:SetWidth(w) end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, edit:GetHeight() - self:GetHeight())
        local nv = self:GetVerticalScroll() - delta * 18
        if nv < 0 then nv = 0 elseif nv > maxScroll then nv = maxScroll end
        self:SetVerticalScroll(nv)
    end)

    -- Clicking anywhere in the box focuses the edit (content can be shorter than the box).
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)

    box.edit = edit
    return box
end

-- Reskin a UICheckButton as a flat square: accent block when checked, red when unchecked, so
-- on/off reads at a glance. Must be created with BackdropTemplate + UICheckButtonTemplate.
local function StyleCheckbox(cb)
    -- Strip all default box/check art (incl. the built-in checked texture) — we convey state via our own fill.
    if cb.SetNormalTexture   then cb:SetNormalTexture("")   end
    if cb.SetPushedTexture   then cb:SetPushedTexture("")   end
    if cb.SetHighlightTexture then cb:SetHighlightTexture("") end
    if cb.SetCheckedTexture  then cb:SetCheckedTexture("")  end
    ApplyFlat(cb, THEME.field, true)

    -- A single always-shown inset fill; its COLOUR conveys state (accent=on, red=off). At OVERLAY top
    -- sublevel so neither the backdrop nor the button's own art covers it.
    local fill = cb:CreateTexture(nil, "OVERLAY", nil, 7)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetPoint("TOPLEFT",     cb, "TOPLEFT",      3, -3)
    fill:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -3,  3)

    -- Recolour the fill to the checked state (immediate). Exposed for the caller's OnClick + ShowPage:
    -- we do NOT hook OnClick here (the caller's SetScript would wipe it), so the caller must call this.
    cb.RefreshStateColor = function()
        local c = cb:GetChecked() and THEME.accent or THEME.offRed
        fill:SetVertexColor(c[1], c[2], c[3])
    end
    RegisterAccent(cb.RefreshStateColor)   -- re-run on accent change (ON state uses accent)
end

-- ── Flat dropdown widget ────────────────────────────────────────────────────────
-- Themed single-select dropdown, hand-rolled (no Blizzard UIDropDownMenu — art/taint clashes).
-- MakeDropdown(parent, width) returns a flat button carrying:
--   dd:SetOptions(list)     -- array of strings ({} = disabled/empty look)
--   dd:SetValue(text)       -- set the displayed label
--   dd:SetOnSelect(fn)      -- fn(selectedText) on row click
-- Click toggles a drop list beneath it. List + full-screen click-catcher on FULLSCREEN_DIALOG strata
-- (above the DIALOG main window). Opening one closes any other; clicking off closes it; empty = inert.
local OPEN_DD   -- the dropdown whose list is currently open (or nil)

local function MakeDropdown(parent, width)
    local DD_ROW_H = 22

    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width or 160, 24)
    ApplyFlat(dd, THEME.field, true)
    dd.options = {}

    -- Selected-value/placeholder label (left), clipped short of the arrow.
    local label = dd:CreateFontString(nil, "OVERLAY")
    ApplyFont(label, 12)
    label:SetPoint("LEFT",  dd, "LEFT",   8, 0)
    label:SetPoint("RIGHT", dd, "RIGHT", -20, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    dd.labelFS = label

    -- Down-arrow affordance on the right (plain "v").
    local arrow = dd:CreateFontString(nil, "OVERLAY")
    ApplyFont(arrow, 10)
    arrow:SetPoint("RIGHT", dd, "RIGHT", -7, 0)
    arrow:SetText("v")
    arrow:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])

    -- Full-screen click-catcher: closes the list on an off-click. Parented to dd (auto-hides with it),
    -- just below the list so the list's rows get their clicks first.
    local catcher = CreateFrame("Button", nil, dd)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(dd:GetFrameLevel() + 10)
    catcher:SetAllPoints(UIParent)
    catcher:Hide()

    -- The drop list panel, flush under the button, stretched to its width.
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

    -- (Re)draw one row per dd.options entry, reusing a pooled frame set.
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
                AccentFill(hl, 0.20)
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
            -- Reposition every refresh (the list length can change under us).
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT",  list, "TOPLEFT",   2, -2 - (i - 1) * DD_ROW_H)
            r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -2, -2 - (i - 1) * DD_ROW_H)
            r.fs:SetText(text)
            -- Optional per-option font preview (the Settings font picker): render each row in its own
            -- typeface. Raw SetFont + drop from fontMeta so WQ.ReapplyFont never repaints these previews.
            local pf = dd.optionFonts and dd.optionFonts[i]
            if pf and r.fs:SetFont(pf, 14, "") then
                fontMeta[r.fs] = nil
            else
                ApplyFont(r.fs, 12)
            end
            local capText = text   -- capture per-row for the closure
            r:SetScript("OnClick", function()
                CloseList()
                if dd.onSelect then dd.onSelect(capText) end
            end)
            r:Show()
        end
        list:SetHeight(math.max(#opts * DD_ROW_H + 4, 4))
    end

    local function OpenListFrame()
        if #dd.options == 0 then return end   -- empty → inert
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
    function dd:SetOptions(l, fonts)
        self.options = l or {}
        self.optionFonts = fonts   -- optional parallel array of font paths for per-row previews
        self.empty = (#self.options == 0)
        if list:IsShown() then RebuildRows() end
    end
    function dd:SetValue(text)
        self.labelFS:SetText(text or "")
        -- Dim the label on an empty list so a disabled dropdown reads as inactive.
        local c = self.empty and THEME.textDim or THEME.text
        self.labelFS:SetTextColor(c[1], c[2], c[3])
    end
    function dd:SetOnSelect(fn) self.onSelect = fn end

    return dd
end

-- ── Shared header widgets (description + divider + enable toggle) ────────────────
-- Built once here (StyleCheckbox now exists), assigned to the forward-declared upvalues, before the
-- first NewPage call so pages can anchor to pageDivider.

-- Description line under the title. Word-wrap ON so it auto-grows; everything below hangs off its bottom.
pageSubtitle = content:CreateFontString(nil, "OVERLAY")
ApplyFont(pageSubtitle, 12)
pageSubtitle:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
-- Left x-offset MUST match pageTitle's (4) so it lines up flush under the title.
pageSubtitle:SetPoint("TOPLEFT",  content, "TOPLEFT",   4, -28)
pageSubtitle:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -28)
pageSubtitle:SetJustifyH("LEFT")

-- Horizontal rule hung off the description's bottom (drops with it). X offsets push the ends to
-- the content edges from the inset subtitle; height 1 = a crisp 1px line.
pageDivider = content:CreateTexture(nil, "ARTWORK")
pageDivider:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
pageDivider:SetPoint("TOPLEFT",  pageSubtitle, "BOTTOMLEFT",  -4, -6)
pageDivider:SetPoint("TOPRIGHT", pageSubtitle, "BOTTOMRIGHT",  8, -6)
pageDivider:SetHeight(1)

-- Top-right "Enabled" toggle (label left of the box so it hugs the corner). ShowPage shows/syncs it
-- per page; this OnClick routes to the current page's toggle spec.
enableCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate,BackdropTemplate")
enableCheck:SetSize(22, 22)
enableCheck:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)
StyleCheckbox(enableCheck)
enableCheck:SetScript("OnClick", function(self)
    if currentToggle and currentToggle.set then currentToggle.set(self:GetChecked()) end
    self.RefreshStateColor()  -- flip on/off colour immediately
end)

enableLabel = content:CreateFontString(nil, "OVERLAY")
ApplyFont(enableLabel, 12)
enableLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
enableLabel:SetPoint("RIGHT", enableCheck, "LEFT", -4, 0)
enableLabel:SetText("Enabled")

-- ── Master switch (title bar) ───────────────────────────────────────────────────
-- Title-bar override that disables EVERY feature at once (reachable from any page). Doesn't touch the
-- per-feature toggles, so turning it back on restores each. Same flat checkbox (accent=on, red=off).
local masterLabel = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(masterLabel, 12)
masterLabel:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
masterLabel:SetText("Enabled")

-- Minimap-icon toggle label, created now (before positioning) so both toggles centre as one group.
-- Checked = button shown. Per-character (WQ.Is/SetMinimapHidden, defined with the button).
local minimapLabel = titleBar:CreateFontString(nil, "OVERLAY")
ApplyFont(minimapLabel, 12)
minimapLabel:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
minimapLabel:SetText("Minimap Icon")

-- Centre the whole group on the title bar: offset the first label left of CENTER by half the group
-- width so the pair straddles the middle (anchored to CENTER, so it stays centred on resize).
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
    self.RefreshStateColor()  -- flip on/off colour immediately
end)
masterCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Enabled", THEME.text[1], THEME.text[2], THEME.text[3])
    GameTooltip:AddLine("Turns every feature off (or back on) at once.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Your individual feature toggles are kept.", 0.55, 0.55, 0.55, true)
    GameTooltip:Show()
end)
masterCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The minimap toggle chains right of the Enabled box, completing the centred group.
minimapLabel:SetPoint("LEFT", masterCheck, "RIGHT", GROUP_GAP, 0)

local minimapCheck = CreateFrame("CheckButton", nil, titleBar, "UICheckButtonTemplate,BackdropTemplate")
minimapCheck:SetSize(20, 20)
minimapCheck:SetPoint("LEFT", minimapLabel, "RIGHT", 6, 0)
StyleCheckbox(minimapCheck)
minimapCheck:SetScript("OnClick", function(self)
    if WQ.SetMinimapHidden then WQ.SetMinimapHidden(not self:GetChecked()) end
    self.RefreshStateColor()  -- flip on/off colour immediately
end)
minimapCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Minimap icon", THEME.text[1], THEME.text[2], THEME.text[3])
    GameTooltip:AddLine("Show the WarlockQol button on the minimap.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
minimapCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Sync both title-bar checkboxes to saved state on each window open (DB is ready by then).
f:HookScript("OnShow", function()
    local on = WQ.IsMasterEnabled and WQ.IsMasterEnabled()
    masterCheck:SetChecked(on and true or false)
    masterCheck.RefreshStateColor()

    local shown = not (WQ.IsMinimapHidden and WQ.IsMinimapHidden())
    minimapCheck:SetChecked(shown)
    minimapCheck.RefreshStateColor()
end)

-- ── Reusable line-list widget ──────────────────────────────────────────────────
-- The "scrollable list of lines + add box + edit/delete buttons" control shared by both feature
-- pages. `accessors` supplies the data:
--   get()             -> the table of lines to display
--   add(text)         -> truthy if the line was added (clears the input)
--   update(idx, text) -> truthy if the line at idx was updated (edit-in-place)
--   delete(idx)       -> remove the line at idx
--   help1             -> a single grey help string at the bottom
-- Each row has an edit + an X button; edit loads the line into the box and flips Add → "Update Line".
-- Returns a Refresh() the caller wires to page-show / external events.
local function BuildLineList(parent, yTop, accessors)
    local rows = {}

    -- Forward-declared: the row buttons are created before the input box but their handlers capture
    -- it, and Lua only captures locals that already exist, so declare here / assign below.
    local inputBox, addBtn, cancelBtn
    local editingIndex   -- nil = adding a new line; otherwise the index being edited
    local editingList    -- the lines table the edit began in (to detect a tab switch)
    local CancelEdit     -- resets back to "add" mode (defined once inputBox/addBtn exist)
    local EnterEditMode  -- loads a line into the box + switches to "update" mode

    -- FauxScrollFrame: standard scrollbar, we manage the visible content (the row pool below).
    -- CONTENT_L/R are the shared page margins (list, input box, quick-insert row, help lines, summon
    -- tabs) so everything lines up in one column; the right inset keeps the scrollbar off the row buttons.
    local CONTENT_L, CONTENT_R = 8, -32
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     parent, "TOPLEFT",     CONTENT_L, yTop)
    -- Bottom leaves room for the control stack (help line, input row, quick-insert row); list fills the rest.
    scrollFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", CONTENT_R, 98)

    -- Empty-state message (italic, dim) shown where the rows would be when the list is empty. Distinct
    -- from the per-row "(empty line…)" marker for a blank entry within a non-empty list.
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

        -- Abandon an in-progress edit if its target is gone (list switched / row deleted) so we
        -- never write the edited text onto the wrong line.
        if editingIndex and (lines ~= editingList or editingIndex > total) then
            CancelEdit()
        end

        -- How many rows fit the list's current height, capped by the row pool.
        local visible = math.floor(scrollFrame:GetHeight() / ROW_H)
        if visible < 1 then visible = 1 end
        if visible > #rows then visible = #rows end

        local offset = FauxScrollFrame_GetOffset(scrollFrame)
        FauxScrollFrame_Update(scrollFrame, total, visible, ROW_H)

        for i, row in ipairs(rows) do
            local idx = offset + i  -- actual index into the lines table
            if i <= visible and idx <= total then
                -- Defensive: the core rejects blank lines, but a nil hole / whitespace string from old
                -- data or a hand-edited SavedVariables would render as an invisible row — surface it
                -- as a dim clickable-to-remove marker instead.
                row.num:SetText(idx .. ".")  -- ordinal = absolute position in the list
                local val = lines[idx]
                if val == nil or (type(val) == "string" and val:match("^%s*$")) then
                    row.text:SetText("|cff666666(empty line — click X to remove)|r")
                else
                    row.text:SetText(RenderIconTokens(val))
                end
                local capturedIdx = idx   -- capture for the closures (Lua captures by reference)
                row.delBtn:SetScript("OnClick", function()
                    CancelEdit()   -- deleting shifts indices; cancel any pending edit first
                    accessors.delete(capturedIdx)
                    Refresh()
                end)
                row.editBtn:SetScript("OnClick", function()
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

    -- First-open fix: on the very first show the layout pass hasn't run, so GetHeight/Width read ~0
    -- (wrong row count + blank row text). Defer a Refresh one frame so it re-measures after layout.
    scrollFrame:SetScript("OnShow", function()
        if C_Timer and C_Timer.After then C_Timer.After(0, Refresh) else Refresh() end
    end)

    -- Row pool: create ROW_POOL frames once and reuse them. Parent to the PAGE, not the scroll frame
    -- (a FauxScrollFrame has no scroll child, so anything parented to it is clipped away); merely
    -- *anchor* the rows relative to scrollFrame.
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

        -- Ordinal number column, right-aligned in a fixed-width box so multi-digit numbers stay aligned.
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

        -- X button to delete the line (OnClick assigned in Refresh so it captures the row's index).
        local delBtn = MakeFlatButton(row, "X", 24, 20)
        delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.delBtn = delBtn

        -- Edit button left of the X — loads the line into the box for in-place editing (OnClick in Refresh).
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

    -- Leave edit mode: clear the box, restore "Add Line", hide Cancel, snap the box's right edge back.
    CancelEdit = function()
        editingIndex = nil
        editingList  = nil
        inputBox:SetText("")
        addBtn:SetText("Add Line")
        cancelBtn:Hide()
        inputBox:SetPoint("RIGHT", addBtn, "LEFT", -10, 0)
    end

    -- Expose CancelEdit on the page frame so ShowPage + the window's OnHide can abandon an in-progress
    -- edit (more reliable than a child OnHide, which doesn't fire when an ancestor hides).
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

    -- Cancel button: shown only while editing (left of Add/Update); click abandons the edit. Hidden by default.
    cancelBtn = MakeFlatButton(parent, "Cancel", 70, 24)
    cancelBtn:SetPoint("BOTTOMRIGHT", addBtn, "BOTTOMLEFT", -6, 0)
    cancelBtn:SetScript("OnClick", function()
        CancelEdit()
        inputBox:ClearFocus()
    end)
    cancelBtn:Hide()

    -- Stretch the input box from the left margin to the Add button so it widens with the frame.
    -- (EnterEditMode temporarily re-anchors this right edge to the Cancel button while editing.)
    inputBox:SetPoint("RIGHT", addBtn, "LEFT", -10, 0)

    -- Raid-marker quick-insert row above the input box: clicking drops its {token} at the cursor
    -- (focus first, preserving cursor for a mid-line insert). The box keeps raw {token} text; the
    -- list preview and chat render the icon (RenderIconTokens).
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

    -- Page-specific placeholder buttons ({demonName}/{targetName}/{location}), continuing the row
    -- right of the markers. `accessors.placeholders` = the tokens this feature supports (empty = none).
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

    -- Single feature-specific help line pinned to the bottom.
    local h1 = parent:CreateFontString(nil, "OVERLAY")
    ApplyFont(h1, 11)
    h1:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", CONTENT_L, 14)
    h1:SetText(accessors.help1 or "")

    return Refresh
end

-- Open Blizzard's macro UI (like /macro): load the on-demand addon first, then toggle the panel.
local function OpenMacroUI()
    if not MacroFrame then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then load("Blizzard_MacroUI") end
    end
    if MacroFrame then
        if MacroFrame:IsShown() then HideUIPanel(MacroFrame) else ShowUIPanel(MacroFrame) end
    end
end

-- Macro creation lives in the setup wizard (WQ.CreateAllMacros); resets live on the Reset page.
-- The per-page "Enabled" checkbox was retired for the shared header toggle (pages opt in via NewPage).

-- ── Reset confirmations ─────────────────────────────────────────────────────────
-- preferredIndex = 3 uses a high-index popup frame to avoid UI taint.

-- Reset page → "Reset Macros": clears every macro we made (demon + ritual + souls).
StaticPopupDialogs["WARLOCK_QOL_TBC_RESET_MACROS"] = {
    text = "Remove ALL macros WarlockQol created?\n\nYour saved lines, feature toggles, and profiles are kept.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() if WQ.ResetMacros then WQ.ResetMacros() end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Reset page → "Hard Reset": ACCOUNT-WIDE wipe to a fresh install (all profiles, every character's
-- settings, window geometry, this character's macros). Afterwards re-sync the master switch (forced ON).
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
-- Just a welcome/overview (the nav reaches features).
do
    local home = NewPage("home", "General")

    -- Flavour epigraph: an italic, dimmed Gul'dan quote; the welcome body anchors to its bottom.
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

-- ── Demon Summon Lines page ─────────────────────────
do
    local summon = NewPage("summon", "Demon Summoning",
        "Add individual summoning lines to each demon, a random line is said in /say when the cast begins.",
        { get = WQ.IsPetEnabled, set = WQ.SetPetEnabled })

    local selectedFamily = "Succubus"

    -- Forward-declared (the tab OnClick and refresh reference each other).
    local refreshSummon
    local petNameLabel
    local familyTabs = {}   -- family -> tab button, so refresh can highlight the active one

    -- Demon selector sub-tabs, one per family. Flat-themed, active family in the accent colour.
    -- Width is adaptive (the family list can grow): LayoutTabs divides the list's column width among
    -- the tabs (min-clamped, smaller font when narrow), left-aligned; re-run each refresh so it reflows on resize.
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

    -- Size + position the tab row for the current window width. Derived from f:GetWidth() (not the
    -- page's own width) so it reads correctly on the very first show, before the page width resolves.
    local function LayoutTabs()
        local contentW = f:GetWidth() - (SIDEBAR_W + PAD * 3)   -- see content-frame anchors
        -- Fill the same column the list occupies (8 → 32 gutter) so the tab row lines up above the rows.
        local avail = contentW - 8 - 32
        local tabW  = math.floor((avail - (n - 1) * TAB_GAP) / n)
        if tabW < TAB_MIN_W then tabW = TAB_MIN_W end
        -- Smaller label on narrow tabs so the longest names don't clip (esp. under the stock fallback font).
        local fontSize = (tabW >= 74) and 12 or 11
        local step = tabW + TAB_GAP
        for i, family in ipairs(WQ.PET_FAMILIES) do
            local btn = familyTabs[family]
            btn:SetWidth(tabW)
            ApplyFont(btn.label, fontSize)
            -- Left-anchor at the content margin and chain each tab rightward (shares the list's left edge).
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", summon, "TOPLEFT", 8 + (i - 1) * step, TAB_Y)
        end
    end
    LayoutTabs()  -- initial sizing (refreshSummon re-runs it on show / resize)

    -- Highlight the active family tab accent, rest flat (override its OnLeave so it stays accent off-hover).
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

    -- Demon name status label below the tab row. Left x=42 aligns with the list's LINE TEXT column
    -- (margin 8 + number column 34) so "Known as: <name>" sits above the first line.
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

    -- Page refresh = re-layout tabs + highlight active + redraw list + update the demon-name label.
    refreshSummon = function()
        LayoutTabs()
        HighlightTabs()
        refreshList()
        -- Pet names are per-character (on CharState, not the shared profile). Nil-guard as above.
        local char = WQ.CharState()
        local petName = char and char.petNames[selectedFamily]
        if petName then
            petNameLabel:SetText("|cff00ff00Known as: " .. petName .. "|r")
        else
            petNameLabel:SetText("|cffff8800Name unknown — summon demon to detect|r")
        end
    end

    summon.OnPageShow = refreshSummon
    WQ.RefreshUI = refreshSummon   -- so the core can refresh us after UNIT_PET detects a pet name
end

-- ── Ritual of Summoning page ──────────────────────────────────────────────────
do
    local ritual = NewPage("ritual", "Ritual of Summoning",
        "Add individual summoning lines, a random line is announced to your party/raid when the cast begins.",
        { get = WQ.IsRitualEnabled, set = WQ.SetRitualEnabled })

    local refreshRitual = BuildLineList(ritual, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.ritualLines end,
        add    = function(text) return WQ.AddRitualLine(text) end,
        update = function(idx, text) return WQ.UpdateRitualLine(idx, text) end,
        delete = function(idx)  WQ.DeleteRitualLine(idx) end,
        placeholders = { "{targetName}", "{location}" },
        help1  = "|cff8788eePlaceholders: |r|cffaaaaaa{targetName}|r|cff8788ee (target) and |r|cffaaaaaa{location}|r|cff8788ee (your zone)|r",
    })

    ritual.OnPageShow = refreshRitual   -- toggle synced by ShowPage; just redraw the list
end

-- ── Ritual of Souls page ──────────────────────────────────────────────────────
-- Macro-based like Ritual of Summoning, but said in /say with no placeholders.
do
    local souls = NewPage("souls", "Ritual of Souls",
        "Add individual summoning lines, a random line is said in /say when the cast begins.",
        { get = WQ.IsSoulsEnabled, set = WQ.SetSoulsEnabled })

    local refreshSouls = BuildLineList(souls, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.soulsLines end,
        add    = function(text) return WQ.AddSoulsLine(text) end,
        update = function(idx, text) return WQ.UpdateSoulsLine(idx, text) end,
        delete = function(idx)  WQ.DeleteSoulsLine(idx) end,
        help1  = "|cff8788eeA random line is said in |r|cffaaaaaa/say|r|cff8788ee when you cast Ritual of Souls|r",
    })

    souls.OnPageShow = refreshSouls   -- toggle synced by ShowPage; just redraw the list
end

-- ── Soulstone Announcement page ───────────────────────────────────────────────
-- No macro: fires automatically from the combat log (see core). The header toggle (un)registers the
-- listener via SetSoulstoneEnabled, so the page just needs the line list.
do
    local soulstone = NewPage("soulstone", "Soulstone Announcement",
        "When any soulstone is detected (by any warlock in group), a random line is announced to your party/raid.",
        { get = WQ.IsSoulstoneEnabled, set = WQ.SetSoulstoneEnabled })

    local refreshSoulstone = BuildLineList(soulstone, -12, {
        get    = function() local p = WQ.ActiveProfile(); return p and p.soulstoneLines end,
        add    = function(text) return WQ.AddSoulstoneLine(text) end,
        update = function(idx, text) return WQ.UpdateSoulstoneLine(idx, text) end,
        delete = function(idx)  WQ.DeleteSoulstoneLine(idx) end,
        placeholders = { "{targetName}" },
        help1  = "|cff8788eeUse |r|cffaaaaaa{targetName}|r|cff8788ee as a placeholder for who got the soulstone|r",
    })

    soulstone.OnPageShow = refreshSoulstone   -- toggle synced by ShowPage; just redraw the list
end

-- ── Banish Announcement page ──────────────────────────────────────────────────
-- Combat-log driven, no macro, but with TWO pools (landed vs. resisted) selected by a pair of
-- accent sub-tabs; one shared line list edits whichever is active. Core filters own banishes and
-- appends the rank, so the page just manages the text.
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

    -- Centre the two tabs across the page top (fixed width fits even at min size — no adaptive sizing).
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

    -- Resolve the DB list + the three helpers for the selected pool, so the one BuildLineList edits it.
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
-- Front-end to the core profile API (GetActiveProfileName/ListProfiles/SwitchProfile/CreateProfile/
-- CopyProfileInto/DeleteProfile). Plain settings page (no toggle). Every mutation routes through
-- RefreshProfilesPage() to keep labels + dropdowns in sync; the line pages rebuild on their next OnPageShow.
do
    local profiles = NewPage("profiles", "Profiles",
        "Each character has its own profile of lines and settings. Switch, copy, delete, or share profiles here.")

    -- Two-column body: labels in a left gutter, controls in a fixed column. Widths fit even at min size.
    local LABEL_X, CTRL_X, DD_W = 8, 120, 200   -- LABEL_X = shared content margin (matches the list pages)
    local PLACEHOLDER = "Select a profile..."

    -- Forward-declared: dropdown callbacks + StaticPopups call back into this to redraw.
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
        errorMsg:SetText("|cffff5555" .. msg .. "|r")   -- soft red
        errorMsg:Show()
    end
    -- Same line, green, for a success confirmation.
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
                RefreshProfilesPage()   -- line pages rebuild on their next show
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

    -- Create (button or Enter): trim, create (seeds + switches), clear the box, refresh.
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

    -- Copy From: confirm, copy on accept; reset the dropdown to placeholder (popup captured pendingCopy).
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
    -- Export a profile to a copy-paste string, or import a string as a NEW profile.
    local exportSel   -- which profile Export exports (defaults to the active one)

    local shareDivider = profiles:CreateTexture(nil, "ARTWORK")
    shareDivider:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    shareDivider:SetPoint("TOPLEFT",  profiles, "TOPLEFT",  LABEL_X, -196)
    shareDivider:SetPoint("TOPRIGHT", profiles, "TOPRIGHT", -12, -196)
    shareDivider:SetHeight(1)

    local shareHdr = profiles:CreateFontString(nil, "OVERLAY")
    ApplyFont(shareHdr, 12)
    shareHdr:SetPoint("TOPLEFT", profiles, "TOPLEFT", LABEL_X, -206)
    AccentText(shareHdr)
    shareHdr:SetText("SHARE PROFILE")

    -- Export row: pick a profile + Export → fills the box below; Clear empties it once copied.
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

    -- After a paste (focus leaves the box), prefill the name from the string unless the user typed one.
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
        -- Auto-suffix a same-minute collision, but only for auto-derived names (typed name → ask to change).
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

    -- Re-read profile state and repaint: current label, Existing dropdown (all, value=active), and the
    -- Copy/Delete dropdowns (all MINUS active — can't copy onto/delete active; empty → inert "No other profiles").
    RefreshProfilesPage = function()
        local active = (WQ.GetActiveProfileName and WQ.GetActiveProfileName()) or "?"
        currentLabel:SetText("Current Profile:  |cff" .. HEX_ACCENT .. active .. "|r")

        local all = (WQ.ListProfiles and WQ.ListProfiles()) or {}
        existingDD:SetOptions(all)
        existingDD:SetValue(active)

        -- Export picker: every profile, default active. Empty the output box so no stale string lingers.
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
-- Two destructive actions behind confirm popups; the core does the work (WQ.ResetMacros keeps
-- everything but macros; WQ.HardReset wipes the entire addon account-wide). This page is just buttons.
do
    local reset = NewPage("reset", "Reset",
        "Clean up the macros WarlockQol created, or reset the whole addon back to a fresh install.")

    local PAD_L, WRAP = 8, -16   -- PAD_L = shared content margin (matches the list pages)

    -- Section 1 — Reset Macros (accent heading).
    local h1 = reset:CreateFontString(nil, "OVERLAY")
    ApplyFont(h1, 13)
    AccentText(h1)
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
    AccentText(h3)
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
-- Settings-only page for the Raid Cooldown Tracker (the HUD is a separate frame at the end of the file).
-- Header toggle drives trackerEnabled; body = HUD display controls + per-cooldown track toggles.
-- Checkboxes re-sync on page show (a profile switch can change the flags).
do
    local track = NewPage("tracking", "Raid Cooldowns",
        "Track your raid's warlock cooldowns on a movable HUD. CTRL + click to announce.",
        { get = WQ.IsTrackerEnabled, set = WQ.SetTrackerEnabled })

    local PAD_L, WRAP = 8, -16
    local syncers = {}   -- checkboxes to re-sync from their get() on page show

    -- Flat checkbox + label row at (x/PAD_L, y), wired to get/set. Initial state is NOT read here (some
    -- HUD getters aren't defined until later); OnPageShow runs the registered syncer instead.
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
        AccentText(h)
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

    -- HUD visibility: two independent toggles side by side. LEFT = manual open/close; RIGHT = auto-show
    -- in a raid. Wrapped in closures because the HUD getter/setters live later in the file.
    Heading("HUD", -6)
    CheckRow("Show HUD", -32,
        function() return WQ.IsTrackerHUDOpen() end,  function(v) WQ.SetTrackerHUDOpen(v) end)
    CheckRow("Auto-show in raid", -32,
        function() return WQ.IsTrackerShowRaid() end,
        function(v)
            WQ.SetTrackerShowRaid(v)
            -- Enabling while already in a raid instance won't hit a transition, so open the HUD now.
            if v and IsInRaid() and select(2, IsInInstance()) == "raid" then WQ.SetTrackerHUDOpen(true) end
        end, 185)
    local cap = Caption("Auto-show opens it automatically whenever you're in a raid.", -60)
    cap:SetPoint("TOPRIGHT", track, "TOPRIGHT", WRAP, -60)
    cap:SetJustifyH("LEFT")

    Rule(-88)

    -- Tracked section — the CD checkboxes (data-driven, grows with TRACKED_ORDER) plus the standalone
    -- "Soulstone Active" toggle (who currently HAS a soulstone buff, vs. the caster's cooldown).
    Heading("Tracked", -104)
    local cap2 = Caption("Soulstone CD = each warlock's cooldown timer.  Soulstone Active = who currently has a soulstone.", -126)
    cap2:SetPoint("TOPRIGHT", track, "TOPRIGHT", WRAP, -126)
    cap2:SetJustifyH("LEFT")
    local y = -158
    for _, key in ipairs(WQ.TRACKED_ORDER or {}) do
        local spec = WQ.TRACKED_COOLDOWNS and WQ.TRACKED_COOLDOWNS[key]
        local label = spec and spec.label or key
        CheckRow(label, y,
            function() return WQ.IsCooldownTracked(key) end,
            function(v) WQ.SetCooldownTracked(key, v) end)
        y = y - 28
    end
    CheckRow("Soulstone Active", y,
        function() return WQ.IsSoulstoneActiveEnabled() end,
        function(v) WQ.SetSoulstoneActiveEnabled(v) end)
    y = y - 28

    -- Re-sync every checkbox. Runs on page show, and exposed so the HUD's X button can call it after
    -- flipping "Show HUD" off, keeping the page checkbox in sync.
    function WQ.SyncTrackerPage()
        for _, sync in ipairs(syncers) do sync() end
    end
    track.OnPageShow = WQ.SyncTrackerPage
end

-- ── Missing Consumables page (Raid) ────────────────────────────────────────────
-- Settings-only page for the Missing Consumables HUD (a separate strip at the end of the file). Header
-- toggle drives consumablesEnabled; body = HUD show controls + threshold + per-consumable list. Mirrors Tracking.
do
    local cons = NewPage("consumables", "Missing Consumables",
        "A HUD that pops up in a raid showing the consumables you're missing or about to lose.",
        { get = WQ.IsConsumablesEnabled, set = WQ.SetConsumablesEnabled })

    local PAD_L, WRAP = 8, -16
    local syncers = {}   -- widgets to re-sync from their getters on page show

    -- Flat checkbox + label row, as on the Tracking page (initial state set by the syncer on page show).
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
        AccentText(h)
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

    -- HUD show controls: manual "Show HUD" + "Auto-show in raid" (side by side, like Tracking).
    Heading("HUD", -6)
    Caption("Auto-hides when nothing is missing.", -26)
    CheckRow("Show HUD", -50,
        function() return WQ.IsConsumeHUDOpen() end, function(v) WQ.SetConsumeHUDOpen(v) end)
    CheckRow("Auto-show in raid", -50,
        function() return WQ.IsConsumeShowRaid() end,
        function(v)
            WQ.SetConsumeShowRaid(v)
            -- Enabling while already in a raid instance won't hit a transition, so open the HUD now.
            if v and IsInRaid() and select(2, IsInInstance()) == "raid" then WQ.SetConsumeHUDOpen(true) end
        end, 185)
    CheckRow("Glow missing icons", -76,
        function() return WQ.IsConsumeGlow() end, function(v) WQ.SetConsumeGlow(v) end)
    CheckRow("Transparent mode", -76,
        function() return WQ.IsConsumeTransparent() end, function(v) WQ.SetConsumeTransparent(v) end, 185)

    Rule(-108)

    -- Expiry-warning threshold. Stored in seconds; edited here in minutes.
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
    threshBox:HookScript("OnEditFocusLost", function() CommitThreshold() end)   -- commit on blur (Hook keeps the border-reset)
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

    -- Re-sync every widget (page show / profile switch); the HUD's X button calls it too (SetConsumeHUDOpen).
    function WQ.SyncConsumablesPage()
        for _, sync in ipairs(syncers) do sync() end
    end
    cons.OnPageShow = WQ.SyncConsumablesPage
end

-- ── Range Indicator page (Raid) ────────────────────────────────────────────────
-- Settings-only page for the Range HUD (a separate text frame at the end of the file). Header toggle
-- drives rangeEnabled; body = Show HUD + Transparent mode. A manual on/off tool: no auto-show-in-raid.
do
    local rng = NewPage("range", "Range Indicator",
        "A HUD showing your current target's name and your distance to it (as a yard range).",
        { get = WQ.IsRangeEnabled, set = WQ.SetRangeEnabled })

    local PAD_L, WRAP = 8, -16
    local syncers = {}   -- widgets to re-sync from their getters on page show

    local function CheckRow(label, y, get, set, x)
        local cb = CreateFrame("CheckButton", nil, rng, "UICheckButtonTemplate,BackdropTemplate")
        cb:SetSize(22, 22)
        cb:SetPoint("TOPLEFT", rng, "TOPLEFT", x or PAD_L, y)
        StyleCheckbox(cb)
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked())
            self.RefreshStateColor()
        end)
        local fs = rng:CreateFontString(nil, "OVERLAY")
        ApplyFont(fs, 12)
        fs:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        fs:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
        fs:SetText(label)
        syncers[#syncers + 1] = function() cb:SetChecked(get() and true or false); cb.RefreshStateColor() end
        return cb
    end

    local function Heading(text, y)
        local h = rng:CreateFontString(nil, "OVERLAY")
        ApplyFont(h, 13)
        AccentText(h)
        h:SetPoint("TOPLEFT", rng, "TOPLEFT", PAD_L, y)
        h:SetText(text)
        return h
    end
    local function Caption(text, y)
        local c = rng:CreateFontString(nil, "OVERLAY")
        ApplyFont(c, 11)
        c:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
        c:SetPoint("TOPLEFT", rng, "TOPLEFT", PAD_L, y)
        c:SetPoint("TOPRIGHT", rng, "TOPRIGHT", WRAP, y)
        c:SetJustifyH("LEFT")
        c:SetText(text)
        return c
    end
    local function Rule(y)
        local r = rng:CreateTexture(nil, "ARTWORK")
        r:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
        r:SetPoint("TOPLEFT",  rng, "TOPLEFT",  PAD_L, y)
        r:SetPoint("TOPRIGHT", rng, "TOPRIGHT", WRAP,  y)
        r:SetHeight(1)
    end

    Heading("HUD", -6)
    Caption("Shows your target's name and your distance as a yard range, e.g. (35-40) — WoW only " ..
            "reports range in brackets, not exact yards.", -26)
    CheckRow("Show HUD", -66,
        function() return WQ.IsRangeHUDOpen() end, function(v) WQ.SetRangeHUDOpen(v) end)
    CheckRow("Transparent mode", -66,
        function() return WQ.IsRangeTransparent() end, function(v) WQ.SetRangeTransparent(v) end, 185)
    CheckRow("Hide when no target", -92,
        function() return WQ.IsRangeHideNoTarget() end, function(v) WQ.SetRangeHideNoTarget(v) end)

    Rule(-124)

    -- Text size: one control drives both the target name and the range value (points, clamped 8–40).
    Heading("Text size", -140)
    local fontLabel = rng:CreateFontString(nil, "OVERLAY")
    ApplyFont(fontLabel, 12)
    fontLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    fontLabel:SetPoint("TOPLEFT", rng, "TOPLEFT", PAD_L, -166)
    fontLabel:SetText("Name & range text size")

    local fontBox = MakeFlatEditBox(rng)
    fontBox:SetSize(40, 22)
    fontBox:SetPoint("LEFT", fontLabel, "RIGHT", 8, 0)
    fontBox:SetJustifyH("CENTER")
    fontBox:SetMaxLetters(3)

    local fontUnit = rng:CreateFontString(nil, "OVERLAY")
    ApplyFont(fontUnit, 12)
    fontUnit:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    fontUnit:SetPoint("LEFT", fontBox, "RIGHT", 8, 0)
    fontUnit:SetText("points")

    local function RefreshFontBox() fontBox:SetText(("%d"):format(WQ.GetRangeFontSize())) end
    local function CommitFont()
        local n = tonumber(fontBox:GetText())
        if n then WQ.SetRangeFontSize(n) end
        RefreshFontBox()   -- reflect the stored (clamped) value
    end
    fontBox:SetScript("OnEnterPressed", function(self) CommitFont(); self:ClearFocus() end)
    fontBox:SetScript("OnEscapePressed", function(self) RefreshFontBox(); self:ClearFocus() end)
    fontBox:HookScript("OnEditFocusLost", function() CommitFont() end)
    syncers[#syncers + 1] = RefreshFontBox

    Rule(-198)
    Caption("Drag the HUD to reposition it. With no target it shows \"No target\" (or hides, if you tick " ..
            "the option above), and it reads \"(>60)\" when the target is beyond checking range.", -214)

    function WQ.SyncRangePage()
        for _, sync in ipairs(syncers) do sync() end
    end
    rng.OnPageShow = WQ.SyncRangePage
end

-- ── Settings page (Settings) ───────────────────────────────────────────────────
-- Cross-cutting look-and-feel options, saved to the active profile. First control: the UI font picker
-- (WQ.SetFont repaints everything live via WQ.ReapplyFont). More may join here later.
do
    local settings = NewPage("settings", "Settings",
        "Customise how the addon looks. These options are saved to the active profile.")

    local PAD_L = 8
    local syncers = {}

    local fontHdr = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(fontHdr, 13)
    AccentText(fontHdr)
    fontHdr:SetPoint("TOPLEFT", settings, "TOPLEFT", PAD_L, -6)
    fontHdr:SetText("Font")

    local fontCap = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(fontCap, 11)
    fontCap:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    fontCap:SetPoint("TOPLEFT",  settings, "TOPLEFT",  PAD_L, -26)
    fontCap:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -16,   -26)
    fontCap:SetJustifyH("LEFT")
    fontCap:SetText("Sets the font used across the whole addon: menus and HUDs. These fonts all " ..
                    "come with the game.")

    local fontLabel = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(fontLabel, 12)
    fontLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    fontLabel:SetPoint("TOPLEFT", settings, "TOPLEFT", PAD_L, -62)
    fontLabel:SetText("UI font")

    -- Map dropdown labels (what the user sees) to WQ.FONTS keys (what we store); the parallel paths
    -- array lets each row preview in its own typeface.
    local fontLabels, fontPaths, labelToKey = {}, {}, {}
    for i, key in ipairs(WQ.FONT_ORDER) do
        local o = WQ.FONTS[key]
        fontLabels[i] = o.label
        fontPaths[i]  = o.path
        labelToKey[o.label] = key
    end

    local fontDD = MakeDropdown(settings, 180)
    fontDD:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)
    fontDD:SetOptions(fontLabels, fontPaths)
    fontDD:SetOnSelect(function(text)
        local key = labelToKey[text]
        if key then
            WQ.SetFont(key)          -- repaints the UI (incl. this dropdown's label) into the new font
            fontDD:SetValue(text)    -- then show the new selection as the dropdown's value
        end
    end)

    local function RefreshFontDD()
        local o = WQ.FONTS[WQ.GetFont()]
        fontDD:SetValue(o and o.label or "")
    end
    syncers[#syncers + 1] = RefreshFontDD

    -- ── Accent colour ────────────────────────────────────────────────────────────
    local accentRule = settings:CreateTexture(nil, "ARTWORK")
    accentRule:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    accentRule:SetPoint("TOPLEFT",  settings, "TOPLEFT",  PAD_L, -100)
    accentRule:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -16,   -100)
    accentRule:SetHeight(1)

    local accentHdr = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(accentHdr, 13)
    AccentText(accentHdr)
    accentHdr:SetPoint("TOPLEFT", settings, "TOPLEFT", PAD_L, -114)
    accentHdr:SetText("Accent colour")

    local accentCap = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(accentCap, 11)
    accentCap:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    accentCap:SetPoint("TOPLEFT",  settings, "TOPLEFT",  PAD_L, -134)
    accentCap:SetPoint("TOPRIGHT", settings, "TOPRIGHT", -16,   -134)
    accentCap:SetJustifyH("LEFT")
    accentCap:SetText("The highlight colour used across the addon for selections, headings and borders. " ..
                      "Click the swatch to choose your own; the picker previews live.")

    local accentLabel = settings:CreateFontString(nil, "OVERLAY")
    ApplyFont(accentLabel, 12)
    accentLabel:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
    accentLabel:SetPoint("TOPLEFT", settings, "TOPLEFT", PAD_L, -176)
    accentLabel:SetText("Accent colour")

    -- Full-screen catcher so a click OFF the picker cancels it (and stops it dropping behind the app).
    -- Strata layering: catcher on FULLSCREEN (above the app's DIALOG window), picker raised to
    -- FULLSCREEN_DIALOG (above the catcher, so the picker's own controls stay clickable).
    local pickerCatcher = CreateFrame("Button", nil, UIParent)
    pickerCatcher:SetAllPoints(UIParent)
    pickerCatcher:SetFrameStrata("FULLSCREEN")
    pickerCatcher:Hide()
    ColorPickerFrame:HookScript("OnHide", function() pickerCatcher:Hide() end)

    -- Open the stock colour picker seeded to startHex; apply(hex) fires live while dragging, and on
    -- cancel (button OR click-away) we restore startHex. Shim: retail uses SetupColorPickerAndShow,
    -- TBC/Classic the .func + .cancelFunc + .previousValues fields. No opacity (accent is opaque).
    local function OpenAccentPicker(startHex, apply)
        local r0, g0, b0 = HexToRGB(startHex)
        local function onChange()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            apply(RGBToHex(r, g, b))
        end
        local function onCancel() apply(startHex) end
        pickerCatcher:SetScript("OnClick", function()
            onCancel()
            ColorPickerFrame:Hide()   -- OnHide hook hides the catcher
        end)
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r0, g = g0, b = b0, hasOpacity = false,
                swatchFunc = onChange, cancelFunc = onCancel,
            })
        else
            ColorPickerFrame.func       = onChange
            ColorPickerFrame.swatchFunc = onChange
            ColorPickerFrame.cancelFunc = onCancel
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.previousValues = { r0, g0, b0 }
            ColorPickerFrame:SetColorRGB(r0, g0, b0)
            ColorPickerFrame:Hide()   -- force OnShow to re-init with our values
            ColorPickerFrame:Show()
        end
        ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")   -- keep above the app + the catcher
        pickerCatcher:Show()
    end

    -- Clickable swatch showing the current accent; opens the picker.
    local swatch = CreateFrame("Button", nil, settings, "BackdropTemplate")
    swatch:SetSize(24, 24)
    swatch:SetPoint("LEFT", accentLabel, "RIGHT", 10, 0)
    ApplyFlat(swatch, THEME.field, true)
    local swatchFill = swatch:CreateTexture(nil, "ARTWORK")
    swatchFill:SetPoint("TOPLEFT",     swatch, "TOPLEFT",      3, -3)
    swatchFill:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -3,  3)
    local function RefreshSwatch() swatchFill:SetColorTexture(HexToRGB(WQ.GetAccent())) end
    swatch:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    swatch:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
    end)
    swatch:SetScript("OnClick", function()
        OpenAccentPicker(WQ.GetAccent(), function(hex) WQ.SetAccent(hex); RefreshSwatch() end)
    end)

    local resetBtn = MakeFlatButton(settings, "Reset to default")
    resetBtn:SetSize(120, 24)
    resetBtn:SetPoint("LEFT", swatch, "RIGHT", 12, 0)
    resetBtn:SetScript("OnClick", function()
        WQ.SetAccent(WQ.DEFAULT_ACCENT); RefreshSwatch()
    end)

    syncers[#syncers + 1] = RefreshSwatch

    function WQ.SyncSettingsPage()
        for _, sync in ipairs(syncers) do sync() end
    end
    settings.OnPageShow = WQ.SyncSettingsPage
end

-- ── Left nav items ────────────────────────────────────────────────────────────
-- Nav buttons (one per page) grouped under non-interactive section headers, built after the pages so
-- ShowPage is wired. Selected item = accent fill + dark text; rest transparent, accent on hover.
-- UpdateNav refreshes the highlight on ShowPage.
do
    -- Entries are either a clickable { label, page } item or a { header = "..." } section title, walked
    -- with a running offset `y` from the sidebar top so headers and items can differ in height/spacing.
    local NAV_ITEMS = {
        { label = "General",                page = "home"      },
        { header = "VOICE LINES" },
        { label = "Demon Summoning",        page = "summon"    },
        { label = "Ritual of Summoning",    page = "ritual"    },
        { label = "Ritual of Souls",        page = "souls"     },
        { header = "ANNOUNCEMENTS" },
        { label = "Soulstone",              page = "soulstone" },
        { label = "Banish",                 page = "banish"    },
        { header = "RAID" },
        { label = "Raid Cooldowns",         page = "tracking"     },
        { label = "Consumables",            page = "consumables"  },
        { label = "Range Indicator",        page = "range"        },
        { header = "SETTINGS" },
        { label = "Settings",               page = "settings"  },
        { label = "Profiles",               page = "profiles"  },
        { label = "Reset",                  page = "reset"     },
    }
    local navButtons = {}
    local y = 4   -- running distance from the sidebar's top edge

    for _, item in ipairs(NAV_ITEMS) do
        if item.header then
            -- Section title: dim uppercase label + a thin rule beneath. Not a navButton, so UpdateNav skips it.
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
            AccentFill(sel, 1)
            sel:Hide()
            b.sel = sel

            -- Hover highlight (faint gold) for unselected items.
            local hov = b:CreateTexture(nil, "HIGHLIGHT")
            hov:SetAllPoints()
            AccentFill(hov, 0.12)

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

    -- Highlight the nav item matching `name`: accent fill + dark text when selected, else transparent.
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
-- Macro creation lives in the setup wizard now, so only "Open Macros" stays pinned here — stretched
-- across the sidebar bottom, clear of the nav items, following the window on resize.
do
    local openMacros = MakeFlatButton(sidebar, "Open Macros")
    openMacros:SetHeight(24)
    openMacros:SetPoint("BOTTOMLEFT",  sidebar, "BOTTOMLEFT",   4, 4)
    openMacros:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -4, 4)
    openMacros:SetScript("OnClick", OpenMacroUI)
end

-- ── Raid Cooldown Tracker HUD ────────────────────────────────────────
-- Standalone movable HUD showing each raid warlock's cooldown state ("Ready" or a live countdown),
-- fed by the core tracker (comms + combat-log fallback). Structure vs. ticking are split:
-- WQ.RefreshTrackerHUD() rebuilds rows only on roster/comms/cast events; the per-frame OnUpdate just
-- re-reads each visible row's remaining seconds (cheap store-only WQ.GetTrackerRemaining, no roster scan).
do
    local HUD_W        = 172
    local HUD_ROW_H    = 22
    local HUD_HEADER_H = 20
    local HUD_PAD      = 6
    local HUD_BODY_TOP = HUD_PAD + HUD_HEADER_H + 4   -- y-offset of the first row below the header
    local HUD_SECT_H   = 16                           -- height of the "Soulstones Out" section label
    local HUD_KEY      = "soulstone"                  -- the one tracked cooldown for now

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

    -- Header strip: title (also the visual grip). No mouse, so drags fall through to the hud frame.
    local hudHeader = CreateFrame("Frame", nil, hud, "BackdropTemplate")
    hudHeader:SetPoint("TOPLEFT",  hud, "TOPLEFT",   HUD_PAD, -HUD_PAD)
    hudHeader:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -HUD_PAD, -HUD_PAD)
    hudHeader:SetHeight(HUD_HEADER_H)
    ApplyFlat(hudHeader, THEME.panel, true)

    local hudTitle = hudHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(hudTitle, 12)
    hudTitle:SetPoint("LEFT", hudHeader, "LEFT", 6, 0)
    AccentText(hudTitle)
    hudTitle:SetText("Raid Cooldowns")

    -- Persistence (position + shown + locked) — a top-level DB table like `ui`.
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

    -- Close button at the header's far right (like the main window's). Closes the HUD (same as unticking "Show HUD").
    local closeBtn = CreateFrame("Button", nil, hudHeader, "BackdropTemplate")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("RIGHT", hudHeader, "RIGHT", -3, 0)
    ApplyFlat(closeBtn, THEME.field, true)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    ApplyFont(closeX, 13)
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    AccentText(closeX)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        closeX:SetTextColor(0.78, 0.78, 1.0)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    closeBtn:SetScript("OnClick", function() if WQ.DismissTrackerHUD then WQ.DismissTrackerHUD() end end)

    -- Padlock toggle left of the close button: lock/unlock the HUD position. The Blizzard padlock art is
    -- desaturated + tinted (accent=locked, dim=unlocked). A click (not a drag), so it works while locked.
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
    -- Re-tint the padlock (accent when locked) and rebuild rows (own/selected row name uses accent) on
    -- an accent change; RefreshTrackerHUD is defined later, so guard for the build-time first run.
    RegisterAccent(function()
        RefreshLockIcon()
        if WQ.RefreshTrackerHUD then WQ.RefreshTrackerHUD() end
    end)
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

    -- Announce a warlock's cooldown to the group (e.g. "Rimm: Soulstone CD - 17:34 remaining" / "… - Ready").
    -- GROUP ONLY: RAID else PARTY; solo does nothing (never /say a group callout to strangers).
    -- The "CD" wording comes from the tracked cooldown's label (so it's clearly the cooldown, not a buff).
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

    -- Announce that a player currently HAS a soulstone (the buff), fired by CTRL+Click on a
    -- "Soulstones Out" row. Group-only, like AnnounceCooldown. Reads the live remaining time.
    local function AnnounceSoulstone(name)
        if not name or name == "" then return end
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or nil)
        if not channel then return end
        local rem = WQ.GetSoulstoneRemaining and WQ.GetSoulstoneRemaining(name)
        local msg
        if rem and rem > 0 then
            msg = ("%s has a Soulstone - %s remaining"):format(name, FormatCD(rem))
        else
            msg = ("%s has a Soulstone"):format(name)
        end
        SendChatMessage(msg, channel)
    end

    -- Shared row builder. Each row: [icon] [name] … [timer]. Rows are Buttons: a plain drag moves the
    -- HUD, CTRL+Click runs onCtrlClick(self.rowName). Used by both the CD rows and the soulstone rows.
    local function MakeRow(onCtrlClick)
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
        -- CTRL+Click announces this row; a plain click does nothing.
        row:SetScript("OnClick", function(self)
            if IsControlKeyDown() and onCtrlClick then onCtrlClick(self.rowName) end
        end)
        -- Subtle accent wash on hover so the rows read as interactive.
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

    -- CD-row pool (warlock cooldowns) + soulstone-row pool (who currently holds a stone).
    local hudRows = {}
    local ssRows  = {}
    local function MakeHUDRow() return MakeRow(AnnounceCooldown) end
    local function MakeSsRow()  return MakeRow(AnnounceSoulstone) end

    -- Shown when there are no warlocks to display (so the frame isn't a confusing empty box).
    local hudEmpty = hud:CreateFontString(nil, "OVERLAY")
    ApplyFontItalic(hudEmpty, 11)
    hudEmpty:SetPoint("TOP", hudHeader, "BOTTOM", 0, -8)
    hudEmpty:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    hudEmpty:SetText("No warlocks in group")
    hudEmpty:Hide()

    -- Dim section label above the soulstone rows (separates them from the CD rows). Positioned in Refresh.
    local ssHeader = hud:CreateFontString(nil, "OVERLAY")
    ApplyFont(ssHeader, 11)
    ssHeader:SetJustifyH("LEFT")
    ssHeader:SetTextColor(THEME.textDim[1], THEME.textDim[2], THEME.textDim[3])
    ssHeader:SetText("Soulstone Active")
    ssHeader:Hide()

    -- Active rows shown: { row, name }. The tick reads each name's remaining time without a rebuild.
    local hudActive = {}   -- CD rows
    local ssActive  = {}   -- soulstone rows

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
        for _, a in ipairs(ssActive) do
            local rem = WQ.GetSoulstoneRemaining and WQ.GetSoulstoneRemaining(a.name)
            if rem == nil then
                a.row.timer:SetText("")                                              -- gone; pruned next rebuild
            elseif rem > 0 then
                a.row.timer:SetText(FormatCD(rem))
                a.row.timer:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3]) -- buff up = neutral/white
            else
                a.row.timer:SetText("Active")                                         -- present, unknown duration
                a.row.timer:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
            end
        end
    end

    -- Rebuild the rows from the roster snapshot. Called on membership/data changes only.
    function WQ.RefreshTrackerHUD()
        if not hud:IsShown() then return end
        if WQ.RefreshActiveSoulstones then WQ.RefreshActiveSoulstones() end   -- freshen the store before we read it
        local snap = (WQ.GetTrackerSnapshot and WQ.GetTrackerSnapshot()) or {}
        local spec = WQ.TRACKED_COOLDOWNS and WQ.TRACKED_COOLDOWNS[HUD_KEY]
        wipe(hudActive)
        wipe(ssActive)

        -- Section 1: warlock cooldown rows.
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
            row.rowName = entry.name   -- CTRL+Click announce reads this
            -- Own row tinted accent; others off-white, so you spot yourself.
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
            y = y - HUD_ROW_H       -- reserve the empty-message line
        else
            hudEmpty:Hide()
        end

        -- Section 2: "Soulstones Out" — who currently HAS a soulstone buff (optional; toggle-gated).
        local ssList = (WQ.IsSoulstoneActiveEnabled and WQ.IsSoulstoneActiveEnabled()
                        and WQ.GetActiveSoulstones and WQ.GetActiveSoulstones()) or {}
        local ssShown = 0
        if #ssList > 0 then
            ssHeader:ClearAllPoints()
            ssHeader:SetPoint("TOPLEFT", hud, "TOPLEFT", HUD_PAD + 2, y - 2)
            ssHeader:Show()
            y = y - HUD_SECT_H
            for _, e in ipairs(ssList) do
                ssShown = ssShown + 1
                local row = ssRows[ssShown] or MakeSsRow()
                ssRows[ssShown] = row
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT",  hud, "TOPLEFT",   HUD_PAD, y)
                row:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -HUD_PAD, y)
                row.icon:SetTexture(spec and spec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.name:SetText(e.name)
                row.rowName = e.name
                if e.isPlayer then
                    row.name:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
                else
                    row.name:SetTextColor(THEME.text[1], THEME.text[2], THEME.text[3])
                end
                row:Show()
                ssActive[ssShown] = { row = row, name = e.name }
                y = y - HUD_ROW_H
            end
        else
            ssHeader:Hide()
        end
        for i = ssShown + 1, #ssRows do ssRows[i]:Hide() end

        hud:SetHeight(-y + HUD_PAD)   -- content bottom (-y) plus bottom padding
        UpdateHUDTimers()             -- paint immediately; don't wait for the next tick
    end

    -- Live tick — repaint the countdowns a few times a second (cheap: store reads only), and rescan the
    -- soulstone buffs on a slower ~1s cadence (rebuilds only when the set of stoned players changes).
    local acc, scanAcc = 0, 0
    hud:SetScript("OnUpdate", function(_, elapsed)
        scanAcc = scanAcc + elapsed
        if scanAcc >= 1 then
            scanAcc = 0
            if WQ.RefreshActiveSoulstones and WQ.RefreshActiveSoulstones() then
                WQ.RefreshTrackerHUD()   -- membership changed: rebuild rows
            end
        end
        acc = acc + elapsed
        if acc < 0.2 then return end
        acc = 0
        UpdateHUDTimers()
    end)

    -- Visibility = ONE persisted flag, trackerHUD.open (the "Show HUD" toggle + the X button set it
    -- directly, so Show HUD always takes effect). The "Auto-show in raid" toggle just drives that flag
    -- on raid-instance transitions: entering opens, leaving closes. Raid-only feature.
    -- "In a raid" here means inside a raid INSTANCE (matches the consumables HUD), not merely a raid group —
    -- GROUP_ROSTER_UPDATE fires at group-join in the world (easily missed/dismissed), so the transition is
    -- keyed off zoning into the instance instead (driven by the core's PLAYER_ENTERING_WORLD).
    local function InRaidInstance() return IsInRaid() and select(2, IsInInstance()) == "raid" end
    local wasInRaid = false   -- last-seen raid-instance state, to detect enter/leave transitions

    -- Recompute visibility and show/hide. Called on the feature flag, the auto-show toggle, roster
    -- changes, and zone changes (PLAYER_ENTERING_WORLD drives the raid-instance transition).
    local function ApplyHUDVisibility()
        local d = HUDdb()
        if not d then hud:Hide(); return end
        local nowRaid = InRaidInstance()
        if nowRaid ~= wasInRaid then
            -- Raid instance entered/left: auto-show opens on entering, closes on leaving.
            if WQ.IsTrackerShowRaid() then d.open = nowRaid and true or false end
            wasInRaid = nowRaid
        end
        -- Master switch also gates the HUD.
        local want = WQ.IsMasterEnabled() and WQ.IsTrackerEnabled() and d.open
        if want then hud:Show(); WQ.RefreshTrackerHUD() else hud:Hide() end
        -- Keep the Tracking page's "Show HUD" checkbox in step (X button / auto-show may have changed d.open).
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

    -- Called from PLAYER_LOGIN (DB ready): restore position + lock icon, then apply visibility.
    function WQ.InitTrackerHUD()
        RestoreHUDPlacement()
        RefreshLockIcon()
        ApplyHUDVisibility()
    end
end

-- ── Missing Consumables HUD ──────────────────────────────────────────
-- Standalone movable icon STRIP showing which raid consumables are missing (glowing icon) or about to
-- expire (icon + countdown). Purely local — reads WQ.GetConsumableSnapshot() (own buffs + weapon enchant).
-- Appears/disappears by data, so a lightweight driver re-scans a few times a second (even while hidden).
do
    local ICON      = 35                    -- visible icon size
    local GLOW_PAD  = 5                     -- transparent margin so the glow sits outside the icon
    local CELL      = ICON + GLOW_PAD * 2   -- the frame each icon lives in (the glow frames this)
    local GAP       = 0                     -- extra gap between cells (they already carry the glow margin)
    local PAD       = 6
    local HEADER_H  = 20
    local BODY_TOP  = PAD + HEADER_H + 4    -- y-offset of the icon row below the header
    local HUD_W     = 172                   -- fixed; matches the Raid Cooldowns HUD (icons centre within it)

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

    -- Header strip: title (also the visual grip). No mouse, so drags fall through to the hud frame.
    local hudHeader = CreateFrame("Frame", nil, hud, "BackdropTemplate")
    hudHeader:SetPoint("TOPLEFT",  hud, "TOPLEFT",   PAD, -PAD)
    hudHeader:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -PAD)
    hudHeader:SetHeight(HEADER_H)
    ApplyFlat(hudHeader, THEME.panel, true)

    local hudTitle = hudHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(hudTitle, 12)
    hudTitle:SetPoint("LEFT", hudHeader, "LEFT", 6, 0)
    AccentText(hudTitle)
    hudTitle:SetText("Missing Consumables")

    -- Persistence (position + open) — a top-level DB table like `trackerHUD`.
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
    AccentText(closeX)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        closeX:SetTextColor(0.78, 0.78, 1.0)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    closeBtn:SetScript("OnClick", function() if WQ.DismissConsumablesHUD then WQ.DismissConsumablesHUD() end end)

    -- Glow (the "missing" highlight): prefer Blizzard's stock proc glow (a FrameXML global, still
    -- dependency-free); fall back to a hand-rolled pulsing IconAlert texture if it's absent.
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
        -- If the stock glow ever errors, remember it and use the hand-rolled pulse from then on.
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

    -- Icon cell pool. Each cell: a themed slot + consumable icon + centred countdown (only for "low").
    -- Cells aren't mouse-enabled, so drags fall through to the hud (the whole strip drags).
    local cells = {}
    local function MakeCell()
        -- Cell = ICON + 2*GLOW_PAD; the icon sits in a centred themed slot so the margin is transparent
        -- and the glow (which frames the cell) sits outside the icon rather than clipping over it.
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
        -- Countdown above the icon (OVERLAY); OUTLINE + shadow makes the small white text read over the art.
        local timer = slot:CreateFontString(nil, "OVERLAY")
        ApplyFont(timer, 13, "OUTLINE")
        timer:SetPoint("CENTER", slot, "CENTER", 0, 0)
        timer:SetTextColor(1, 1, 1)
        timer:SetShadowColor(0, 0, 0, 1)
        timer:SetShadowOffset(1, -1)
        cell.timer = timer
        return cell
    end

    -- Lay out one cell per shown consumable; glow the missing ones ("low" ones get a countdown instead).
    local function Rebuild(shown)
        local n = #shown
        -- Centre the icon row within the fixed-width frame.
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
            -- Glow the missing ones, unless the player turned the glow off.
            if r.status == "missing" and WQ.IsConsumeGlow() then StartGlow(cell) else StopGlow(cell) end
            cell:Show()
        end
        for i = n + 1, #cells do StopGlow(cells[i]); cells[i]:Hide() end

        -- Width is fixed (matches the cooldown HUD); only the height is set here.
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

    -- Visibility / content. One evaluation used by the driver tick and the setters. want = active AND
    -- persistent "open" flag. Auto-show DRIVES that flag on raid-instance transitions (like the cooldown
    -- HUD), so "Show HUD" / the X stay authoritative and can turn it off even while in a raid. Content =
    -- ONLY missing/low; none → hide completely (no preview, healthy consumables never show) — that data
    -- gate is separate from "open", so "invisible when nothing's missing" always holds.
    local lastSig = nil
    local wasInRaid = false   -- last-seen raid-instance state, to detect enter/leave transitions
    local function Evaluate()
        if not WQ.IsConsumablesActive() then hud:Hide(); lastSig = nil; return end
        -- Dead/ghost drops buffs (e.g. Well Fed) — don't nag; re-appears once alive again.
        if UnitIsDeadOrGhost("player") then hud:Hide(); lastSig = nil; return end
        local d = HUDdb()
        -- Raid group AND inside a raid instance (not just any raid group). Entering opens the HUD,
        -- leaving closes it; between transitions the "open" flag is whatever the user last set.
        local nowRaid = IsInRaid() and select(2, IsInInstance()) == "raid"
        if nowRaid ~= wasInRaid then
            if WQ.IsConsumeShowRaid() and d then d.open = nowRaid and true or false end
            wasInRaid = nowRaid
        end
        if not (d and d.open) then hud:Hide(); lastSig = nil; return end

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
        -- No page checkbox sync here: Evaluate runs ~2.5×/s and would clobber the threshold edit
        -- box mid-type. It's synced in SetConsumeHUDOpen (the only thing that flips "Show HUD").
    end
    WQ.UpdateConsumablesHUDVisibility = Evaluate
    WQ.RefreshConsumablesHUD = function() lastSig = nil; Evaluate() end   -- force a rebuild

    -- Driver: a lightweight always-present frame that re-evaluates a few times a second while active.
    -- Needed so the strip APPEARS when something goes missing / a weapon oil silently expires (no event)
    -- even while hidden. Stopped when the feature is off, so a disabled feature costs nothing.
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
        -- Keep the config page's "Show HUD" checkbox in step (the X button may have flipped it).
        if WQ.SyncConsumablesPage then WQ.SyncConsumablesPage() end
    end
    function WQ.ToggleConsumablesHUD() WQ.SetConsumeHUDOpen(not WQ.IsConsumeHUDOpen()) end
    function WQ.DismissConsumablesHUD() WQ.SetConsumeHUDOpen(false) end   -- the HUD's X button

    -- Transparent mode: drop the frame backdrop (bg + border) and hide the header (title/X) so only the
    -- icon slots show. The whole frame stays mouse-enabled, so it's still draggable by its (now invisible)
    -- area. Off restores the standard flat frame + 50% fill. Called on login and whenever the flag flips.
    function WQ.ApplyConsumeTransparency()
        if WQ.IsConsumeTransparent and WQ.IsConsumeTransparent() then
            hud:SetBackdrop(nil)
            hudHeader:Hide()
        else
            ApplyFlat(hud, THEME.bg, true)
            hud:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.5)
            hudHeader:Show()
        end
    end

    -- Called from PLAYER_LOGIN (DB ready): restore position, start the driver if on, apply visibility.
    function WQ.InitConsumablesHUD()
        RestoreHUDPlacement()
        WQ.ApplyConsumeTransparency()
        WQ.UpdateConsumablesRegistration()
        Evaluate()
    end
end

-- ── Range Indicator HUD ──────────────────────────────────────────
-- Standalone movable TEXT frame: target name (top) + a bracketed distance (below), e.g. "35-40".
-- Purely local — reads WQ.GetTargetRange() (spell/item range checkers). A manual on/off tool, so
-- (unlike the raid HUDs) it has no auto-show; a 0.4s driver keeps the range fresh as you move.
do
    local PAD      = 6
    local HEADER_H = 20
    local TEXT_PAD = 6                       -- text inset per side; the frame is TEXT_PAD*2 wider than its text
    local HUD_MIN_W, HUD_MAX_W = 168, 300    -- width follows the target name, clamped to this range
    local HUD_H    = PAD + HEADER_H + 8 + 18 + 4 + 24 + PAD   -- header + name line + gap + range line

    local hud = CreateFrame("Frame", "Warlock_Qol_Tbc_RangeHUD", UIParent, "BackdropTemplate")
    hud:SetSize(HUD_MIN_W, HUD_H)
    hud:SetPoint("CENTER", UIParent, "CENTER", 320, 60)   -- default; user drags, then persisted
    hud:SetFrameStrata("MEDIUM")
    hud:SetClampedToScreen(true)
    ApplyFlat(hud, THEME.bg, true)
    hud:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.5)   -- ~50% transparent (border solid)
    hud:Hide()

    -- Header strip: title + close X (matches the other HUDs). No mouse, so drags fall through to hud.
    local hudHeader = CreateFrame("Frame", nil, hud, "BackdropTemplate")
    hudHeader:SetPoint("TOPLEFT",  hud, "TOPLEFT",   PAD, -PAD)
    hudHeader:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -PAD)
    hudHeader:SetHeight(HEADER_H)
    ApplyFlat(hudHeader, THEME.panel, true)

    local hudTitle = hudHeader:CreateFontString(nil, "OVERLAY")
    ApplyFont(hudTitle, 12)
    hudTitle:SetPoint("LEFT", hudHeader, "LEFT", 6, 0)
    AccentText(hudTitle)
    hudTitle:SetText("Range")

    -- Target name + range bracket, same white OUTLINE style (WeakAura look). Range anchors below the
    -- name. Font size, width and vertical layout are all set by LayoutRangeHUD (below).
    local nameFS = hud:CreateFontString(nil, "OVERLAY")
    ApplyFont(nameFS, 16, "OUTLINE")   -- default until LayoutRangeHUD runs at login
    nameFS:SetPoint("TOP", hud, "TOP", 0, -(PAD + HEADER_H + 8))
    nameFS:SetWidth(HUD_MIN_W - TEXT_PAD * 2)
    nameFS:SetWordWrap(false)   -- one line only; the frame widens to fit, so this only bites past HUD_MAX_W
    nameFS:SetJustifyH("CENTER")
    nameFS:SetTextColor(1, 1, 1)
    nameFS:SetShadowColor(0, 0, 0, 1)
    nameFS:SetShadowOffset(1, -1)

    local rangeFS = hud:CreateFontString(nil, "OVERLAY")
    ApplyFont(rangeFS, 16, "OUTLINE")
    rangeFS:SetPoint("TOP", nameFS, "BOTTOM", 0, -2)
    rangeFS:SetJustifyH("CENTER")
    rangeFS:SetTextColor(1, 1, 1)
    rangeFS:SetShadowColor(0, 0, 0, 1)
    rangeFS:SetShadowOffset(1, -1)

    -- Persistence (position + open) — a top-level DB table like consumeHUD / trackerHUD.
    local function HUDdb()
        local db = Warlock_Qol_Tbc_DB
        if not db then return nil end
        db.rangeHUD = db.rangeHUD or {}
        return db.rangeHUD
    end
    local function SaveHUDPlacement()
        local d = HUDdb(); if not d then return end
        local point, _, relPoint, x, y = hud:GetPoint()
        d.point, d.relPoint, d.x, d.y = point, relPoint, x, y
    end

    -- Re-anchor to CENTER without moving the frame on screen. The width tracks the target name
    -- (LayoutRangeHUD), and only a CENTER anchor grows it symmetrically: off a corner anchor the
    -- centred text would jump sideways every time the name length changed. StartMoving may leave any
    -- anchor behind, so normalise after a drag and after restoring a saved (possibly corner) point.
    local function NormalizeAnchor()
        local cx, cy = hud:GetCenter()
        if not cx then return end
        local ratio = hud:GetEffectiveScale() / UIParent:GetEffectiveScale()
        local px, py = UIParent:GetCenter()
        hud:ClearAllPoints()
        hud:SetPoint("CENTER", UIParent, "CENTER", cx * ratio - px, cy * ratio - py)
    end

    local function RestoreHUDPlacement()
        local d = HUDdb(); if not d or not d.point then return end
        hud:ClearAllPoints()
        hud:SetPoint(d.point, UIParent, d.relPoint, d.x, d.y)
        NormalizeAnchor()
    end

    hud:SetMovable(true)
    hud:EnableMouse(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", function() hud:StartMoving() end)
    hud:SetScript("OnDragStop", function()
        hud:StopMovingOrSizing()
        NormalizeAnchor()
        SaveHUDPlacement()
    end)

    -- Close button — clears the "Show HUD" flag (no auto-show, so it stays closed until re-enabled).
    local closeBtn = CreateFrame("Button", nil, hudHeader, "BackdropTemplate")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("RIGHT", hudHeader, "RIGHT", -3, 0)
    ApplyFlat(closeBtn, THEME.field, true)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    ApplyFont(closeX, 13)
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    AccentText(closeX)
    closeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
        closeX:SetTextColor(0.78, 0.78, 1.0)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(THEME.border[1], THEME.border[2], THEME.border[3])
        closeX:SetTextColor(THEME.accent[1], THEME.accent[2], THEME.accent[3])
    end)
    closeBtn:SetScript("OnClick", function() if WQ.DismissRangeHUD then WQ.DismissRangeHUD() end end)

    -- Size and re-flow the frame around its current text + font size. Called on login, on the
    -- font-size setter, whenever transparency toggles (the header's presence moves the text), and
    -- from Evaluate whenever the text changes (the width follows the target name).
    --
    -- Width: measured from the text, not fixed — a long boss name used to truncate at a hardcoded
    -- 168px, which the font-size option made worse (it re-flowed the height but never the width).
    -- The name is unconstrained before measuring so GetStringWidth reports the FULL natural width
    -- rather than the truncated one. GetStringWidth can read 0 before the first layout pass; the
    -- HUD_MIN_W clamp absorbs that, and Evaluate re-runs on the next tick anyway.
    local function LayoutRangeHUD()
        local sz = (WQ.GetRangeFontSize and WQ.GetRangeFontSize()) or 16
        ApplyFont(nameFS,  sz, "OUTLINE")
        ApplyFont(rangeFS, sz, "OUTLINE")

        nameFS:SetWidth(0)   -- unconstrain: measure the whole name, not what currently fits
        local want = math.max(nameFS:GetStringWidth() or 0, rangeFS:GetStringWidth() or 0)
                     + TEXT_PAD * 2
        if want < HUD_MIN_W then want = HUD_MIN_W elseif want > HUD_MAX_W then want = HUD_MAX_W end
        hud:SetWidth(want)
        nameFS:SetWidth(want - TEXT_PAD * 2)   -- re-constrain: names past the cap still truncate

        local transparent = WQ.IsRangeTransparent and WQ.IsRangeTransparent()
        local top = transparent and PAD or (PAD + HEADER_H + 6)   -- no header room when transparent
        nameFS:ClearAllPoints()
        nameFS:SetPoint("TOP", hud, "TOP", 0, -top)
        local lineH = sz + 6                                      -- approx rendered line height
        hud:SetHeight(top + lineH + 2 + lineH + PAD)
    end

    -- Format the bracket returned by WQ.GetTargetRange(), always parenthesised: "(8-10)" / "(>45)"
    -- / "(0-8)" / "(?)".
    local function FormatRange(lo, hi)
        if not lo and not hi then return "(?)" end
        if not hi then return ("(>%d)"):format(lo) end
        if lo == 0 then return ("(0-%d)"):format(hi) end
        return ("(%d-%d)"):format(lo, hi)
    end

    -- Visibility / content. want = active AND the persistent "open" flag. Stays visible while open
    -- (shows "No target" when untargeted) — no data gate, unlike the consumables strip.
    local lastName, lastRange   -- last text rendered; re-layout only when it actually changes
    local function Evaluate()
        if not WQ.IsRangeActive() then hud:Hide(); return end
        local d = HUDdb()
        if not (d and d.open) then hud:Hide(); return end

        local name, lo, hi = WQ.GetTargetRange()
        local nText, rText
        if not name then
            -- No target: hide entirely if the user opted in, else show a placeholder.
            if WQ.IsRangeHideNoTarget and WQ.IsRangeHideNoTarget() then hud:Hide(); return end
            nText, rText = "No target", ""
        else
            nText, rText = name, FormatRange(lo, hi)
        end
        -- Gate the re-layout: this runs 2.5x/sec, but the text only changes on a new target or a
        -- crossed range boundary, and only then does the frame need re-sizing.
        if nText ~= lastName or rText ~= lastRange then
            lastName, lastRange = nText, rText
            nameFS:SetText(nText)
            rangeFS:SetText(rText)
            LayoutRangeHUD()
        end
        if not hud:IsShown() then hud:Show() end
    end
    WQ.UpdateRangeHUDVisibility = Evaluate
    WQ.RefreshRangeHUD = Evaluate

    -- Driver: a lightweight frame re-reads the range a few times a second while the feature is active,
    -- so the bracket updates as you move. Stopped when the feature/master switch is off.
    local driver = CreateFrame("Frame", nil, UIParent)
    local acc = 0
    local function OnDriver(_, elapsed)
        acc = acc + elapsed
        if acc < 0.4 then return end
        acc = 0
        Evaluate()
    end
    function WQ.UpdateRangeRegistration()
        if WQ.IsRangeActive() then
            driver:SetScript("OnUpdate", OnDriver)
        else
            driver:SetScript("OnUpdate", nil)
            hud:Hide()
        end
    end

    -- Manual open/close: the "Show HUD" toggle, the HUD's X button, and /run ToggleRangeHUD().
    function WQ.IsRangeHUDOpen() local d = HUDdb(); return d and d.open or false end
    function WQ.SetRangeHUDOpen(on)
        local d = HUDdb(); if d then d.open = on and true or false end
        Evaluate()
        if WQ.SyncRangePage then WQ.SyncRangePage() end   -- keep the page's checkbox in step (X button)
    end
    function WQ.ToggleRangeHUD() WQ.SetRangeHUDOpen(not WQ.IsRangeHUDOpen()) end
    function WQ.DismissRangeHUD() WQ.SetRangeHUDOpen(false) end   -- the HUD's X button

    -- Public entry point for the font-size setter (the page's Text size box). LayoutRangeHUD does
    -- the work: font, width, and vertical re-flow.
    function WQ.ApplyRangeFont() LayoutRangeHUD() end

    -- Transparent mode: drop the frame backdrop + hide the header, leaving only the text (still
    -- draggable by its now-invisible area). Off restores the flat frame + 50% fill. Re-flows the
    -- text either way (the header's presence changes where the text sits).
    function WQ.ApplyRangeTransparency()
        if WQ.IsRangeTransparent and WQ.IsRangeTransparent() then
            hud:SetBackdrop(nil)
            hudHeader:Hide()
        else
            ApplyFlat(hud, THEME.bg, true)
            hud:SetBackdropColor(THEME.bg[1], THEME.bg[2], THEME.bg[3], 0.5)
            hudHeader:Show()
        end
        LayoutRangeHUD()
    end

    -- Called from PLAYER_LOGIN (DB ready): restore position, start the driver if on, apply visibility.
    function WQ.InitRangeHUD()
        RestoreHUDPlacement()
        WQ.ApplyRangeTransparency()   -- also applies the font + layout
        WQ.UpdateRangeRegistration()
        Evaluate()
    end
end

-- ── Minimap button ──────────────────────────────────────────────────────────────
-- Hand-rolled draggable minimap button (no LibDBIcon/LibStub). Left-click opens /wq; drag slides it
-- around the ring. Position (angle) + hidden state are PER-CHARACTER (CharState). Created here but
-- positioned/shown on PLAYER_LOGIN via WQ.InitMinimap; the title-bar checkbox drives WQ.Is/SetMinimapHidden.
do
    local DEFAULT_ANGLE = 200   -- degrees; lower-left, clear of the zoom +/- buttons

    -- Minimap SHAPE support so the button sits right on square minimaps (ElvUI) too, without LibDBIcon.
    -- Skinning addons expose GetMinimapShape(); each entry flags whether each QUADRANT is rounded (true)
    -- or squared (false), ordered {BR, BL, TR, TL}. Absent → ROUND. Same public table LibDBIcon uses.
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

    -- Subjugate/Enslave Demon spell icon, trimmed of its default border.
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

    -- Place the button from the current angle, hugging the minimap edge (on the circle for a rounded
    -- quadrant, clamped to the square edge otherwise). w/h from the live minimap size (+5px) so it tracks resizes.
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

    -- Public API + login init. Hidden state + angle are per-character (CharState); nil flag = shown,
    -- nil angle = DEFAULT_ANGLE.
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
-- One-page standalone welcome window shown once per character (PLAYER_LOGIN calls WQ.ShowWizard when
-- setupComplete is unset): intro + Create Macros; Finish dismisses it and opens the hub. Re-openable
-- from the Reset page. A Hard Reset resets setupComplete, so it returns on the next /reload.
-- IMPORTANT: setupComplete is set by FinishWizard, NOT on open (a mid-way /reload re-shows it), and the
-- frame is deliberately NOT a UISpecialFrame / does NOT complete on OnHide (see below).
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

    -- Draggable; position not persisted (transient one-shot).
    wiz:SetMovable(true)
    wiz:EnableMouse(true)
    wiz:RegisterForDrag("LeftButton")
    wiz:SetScript("OnDragStart", wiz.StartMoving)
    wiz:SetScript("OnDragStop",  wiz.StopMovingOrSizing)

    -- NOT registered in UISpecialFrames: the login-time CloseSpecialWindows() would hide it the instant
    -- it auto-opens, and the old OnHide completion then flipped the flag + opened the hub (the "flash" bug).
    -- Dismissal is the Finish button only.

    -- Title + divider (fixed offsets, like the Reset page).
    local title = wiz:CreateFontString(nil, "OVERLAY")
    ApplyFont(title, 16)
    title:SetPoint("TOPLEFT", wiz, "TOPLEFT", P, -P)
    AccentText(title)
    title:SetText("Welcome to WarlockQol")

    local div = wiz:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(THEME.border[1], THEME.border[2], THEME.border[3], 1)
    div:SetPoint("TOPLEFT",  wiz, "TOPLEFT",  P,  -(P + 26))
    div:SetPoint("TOPRIGHT", wiz, "TOPRIGHT", -P, -(P + 26))
    div:SetHeight(1)

    -- Intro body (accent inline highlights via HEX_ACCENT).
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

    -- Status line above the button row: a combat note (offRed) or a create-result message (accent).
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

    -- Combat gating: macro edits are blocked in combat, so disable Create + show a note in lockdown,
    -- restoring on leaving combat (without clobbering a create-result message).
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
        WQ.ReportMacroResult(c, u, conflicts)  -- detailed breakdown to chat
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

    -- Completion is EXPLICIT (the Finish button), never on OnHide (the login-time hide would else flip
    -- the flag). Setting it on dismiss (not open) means an unfinished wizard re-shows after a /reload.
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
