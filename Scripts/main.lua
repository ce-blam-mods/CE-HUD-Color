--=====================================================================
--  CE HUD Color  -  a UE4SS mod for Halo: Campaign Evolved
--
--  Recolours the HUD. 
--
--  HOW IT WORKS
--    UUserWidget carries a ColorAndOpacity (FLinearColor) that Slate
--    MULTIPLIES into everything the widget and its children draw. Setting it
--    on WBP_ShieldHealthBar / WBP_WeaponCradle / etc. recolours that whole
--    element in one call
--
--    Two constraints drove the implementation, both established by earlier
--    probes in this repo (tools/harness/probes/umg_runtime_style*.lua):
--      * Once a widget is realised, WRITING the ColorAndOpacity property does
--        nothing -- UMG mirrors properties into the live SWidget at build
--        time. Only the setter UFunction pushes through. So we CALL
--        SetColorAndOpacity, never assign the property.
--      * FLinearColor marshals safely as a FLAT { R, G, B, A } table (the same
--        shape Border:SetBrushColor and SetRenderScale{X,Y} already use in
--        this codebase). NESTED struct construction (FSlateColor) is what has
--        crashed here before, so the only nested struct we go near is one we
--        MUTATE IN PLACE inside a hook -- see the text hook at the bottom.
--
--  TINT IS A MULTIPLY, NOT A REPAINT
--    The stock HUD is already a pale cyan, so multiplying by, say, red gives a
--    DARK red rather than a bright one (there is little red in the source
--    pixels to keep). That is what `intensity` is for: values above 1.0 are
--    legal in a linear colour and push the result back up to full brightness.
--    Reach for it whenever a preset lands dimmer than you expected.
--
--  Hotkeys:
--    Ctrl+Shift+J  - next colour preset
--    Ctrl+Shift+U  - previous colour preset
--    Ctrl+Shift+O  - brighter (intensity up)
--    Ctrl+Shift+I  - dimmer   (intensity down)
--    Ctrl+Shift+M  - tint on/off (off restores the stock colours)
--    Ctrl+Shift+G  - report: every HUD widget found, and whether it was tinted
--  Everything persists to this mod's own settings.ini.
--=====================================================================

local MOD_NAME = "CEHudColor"
-- Single source of truth for the version: the release workflow parses this
-- line and refuses to build if the git tag disagrees with it.
local MOD_VERSION = "1.0.0"
local ENFORCE_INTERVAL_MS = 1000
local RESCAN_EVERY_PASSES = 3      -- full FindAllOf every ~3s; re-tint every pass
local HUD_PATH = "/game/ui/hud/"

local function log(msg) print("[" .. MOD_NAME .. "] " .. tostring(msg) .. "\n") end

--------------------------------------------------------------------
--  SETTINGS
--
--  Lua's io paths resolve against the PROCESS working directory -- the game's
--  Win64 folder, not the mod folder. Writing a bare "settings.ini" therefore
--  drops a shadow file next to the exe that silently overrides the shipped
--  defaults. Proper location is the mod folder, reached relative to the exe
--  dir; the legacy path is still READ so nothing is lost if a build wrote it.
--------------------------------------------------------------------

local SETTINGS_FILE   = "ue4ss/Mods/" .. MOD_NAME .. "/settings.ini"
local LEGACY_SETTINGS = MOD_NAME .. "_settings.ini"

local function read_ini_into(path, t)
    local f = io.open(path, "r")
    if not f then return false end
    for line in f:lines() do
        if not line:match("^%s*#") then
            -- (.*) not (.+): an EMPTY value is meaningful here -- "key_report="
            -- is how you unbind an action -- and a one-or-more pattern skips
            -- the line entirely, so the default silently comes back instead.
            local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
            if k then t[k] = v:match("^%s*(.-)%s*$") end
        end
    end
    f:close()
    return true
end

local function read_settings()
    local t = {}
    read_ini_into(LEGACY_SETTINGS, t)
    read_ini_into(SETTINGS_FILE, t)   -- proper location wins on conflict
    return t
end

local function bool_val(s, default)
    if s == nil then return default end
    return s:lower() == "true"
end

local ini = read_settings()

--------------------------------------------------------------------
--  COLOURS
--
--  Presets are normalised so the brightest channel is 1.0: because the tint is
--  a multiply, a preset with every channel below 1 can only ever darken the
--  HUD. "stock" is the identity colour and is what "tint off" restores.
--------------------------------------------------------------------

local PRESETS = {
    { name = "stock",   r = 1.00, g = 1.00, b = 1.00 },  -- identity: untouched
    { name = "green",   r = 0.35, g = 1.00, b = 0.45 },  -- classic CE
    { name = "cyan",    r = 0.40, g = 0.90, b = 1.00 },
    { name = "blue",    r = 0.30, g = 0.55, b = 1.00 },
    { name = "yellow",  r = 1.00, g = 0.95, b = 0.20 },
    { name = "amber",   r = 1.00, g = 0.68, b = 0.15 },
    { name = "orange",  r = 1.00, g = 0.45, b = 0.10 },
    { name = "red",     r = 1.00, g = 0.25, b = 0.22 },
    { name = "pink",    r = 1.00, g = 0.35, b = 0.75 },
    { name = "purple",  r = 0.72, g = 0.35, b = 1.00 },
    { name = "white",   r = 1.00, g = 1.00, b = 1.00 },
}

-- Which HUD elements get tinted. Substrings, case-insensitive, matched against
-- each widget's class path, which is exactly what the Ctrl+Shift+G report
-- prints, so you can copy names straight out of it.
--
-- Note on motiontracker: the radar's contact blips are children of the tracker,
-- so tinting it repaints them too and the red-vs-yellow contact distinction
-- goes with them. It is in the defaults because a HUD with an untinted radar
-- looks half-finished -- drop it from `targets` if you want the blips back.
local DEFAULT_TARGETS = table.concat({
    "shieldhealthbar", "weaponcradle", "grenadecradle", "equipmenticon",
    "motiontracker",   -- radar (see the note above)
    "objective",       -- objectives panel, top-left
    "banner",          -- checkpoint / "...done" notifications
    "countdown",       -- mission announcements, hazard timers, banner text
}, ",")

local function parse_targets(s)
    local list = {}
    for word in tostring(s or ""):gmatch("[^,]+") do
        local w = word:match("^%s*(.-)%s*$"):lower()
        if #w > 0 then list[#list + 1] = w end
    end
    return list
end

local function find_preset(name)
    name = tostring(name or ""):lower()
    for i, p in ipairs(PRESETS) do
        if p.name == name then return i end
    end
    return nil
end

-- A colour is either a preset name or a literal "r,g,b" in 0..1 linear floats.
local function parse_custom(s)
    local r, g, b = tostring(s or ""):match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
    if not r then return nil end
    return { name = "custom", r = tonumber(r), g = tonumber(g), b = tonumber(b) }
end

local INTENSITY_MIN, INTENSITY_MAX, INTENSITY_STEP = 0.20, 4.00, 0.10

-- Everything below is re-derivable from the ini at runtime (see the reload
-- hotkey): `targets` is the main tuning knob and has no hotkey of its own, so
-- without a reload every tweak to it would cost a game restart AND a reload of
-- the level to see the HUD again.
--
-- TINT_TEXT and the keybinds are deliberately NOT reloadable: UE4SS registers
-- hooks and binds once, at load, and re-registering them would stack duplicate
-- callbacks rather than replace them.
local ENABLED, INTENSITY, TARGETS, TINT_RETICLE
local CUSTOM_COLOR, preset_index

-- PER-ELEMENT OVERRIDES. Any target key can be given its own colour and/or its
-- own intensity by prefixing it:
--
--     color_motiontracker=red
--     intensity_motiontracker=2.0
--     color_shieldhealthbar=0.9,0.2,0.4
--
-- Anything without an override follows the global `color` / `intensity`, which
-- the hotkeys still drive -- so the common case stays one colour on one key,
-- and the advanced case does not need a second config format. Intensity is
-- separately overridable because the tint is a multiply: elements do not all
-- start from the same base brightness, so the same colour can need a different
-- push on the radar than it does on the shield bar.
local OVERRIDE_COLOR, OVERRIDE_INTENSITY, OVERRIDE_KEYS

local function adopt(t)
    ENABLED   = bool_val(t.enabled, true)
    INTENSITY = tonumber(t.intensity) or 1.0
    TARGETS   = parse_targets(t.targets or DEFAULT_TARGETS)
    -- Reticle is its own switch: plenty of people want a coloured HUD but a
    -- neutral crosshair (or the reverse). It lives under /Game/UI/Hud/Reticle/,
    -- so it is just another target key -- kept as a plain true/false because
    -- that is how people think about the crosshair.
    TINT_RETICLE = bool_val(t.tint_reticle, false)
    CUSTOM_COLOR = parse_custom(t.color)
    preset_index = find_preset(t.color) or (CUSTOM_COLOR and 0) or find_preset("green") or 1

    OVERRIDE_COLOR, OVERRIDE_INTENSITY, OVERRIDE_KEYS = {}, {}, {}
    local seen = {}
    for k, v in pairs(t) do
        -- "color_" / "intensity_" are prefixes, so guard against the bare
        -- "color" and "intensity" keys sneaking in as an override named "".
        local ck = k:match("^color_(.+)$")
        local ik = k:match("^intensity_(.+)$")
        if ck and #ck > 0 then
            OVERRIDE_COLOR[ck:lower()] = v
            if not seen[ck:lower()] then seen[ck:lower()] = true end
        elseif ik and #ik > 0 then
            local n = tonumber(v)
            if n then
                OVERRIDE_INTENSITY[ik:lower()] = n
                if not seen[ik:lower()] then seen[ik:lower()] = true end
            end
        end
    end
    for key in pairs(seen) do OVERRIDE_KEYS[#OVERRIDE_KEYS + 1] = key end
    -- Sorted so the file this writes back is stable instead of reshuffling on
    -- every save (pairs() order is not defined).
    table.sort(OVERRIDE_KEYS)
end

adopt(ini)

local TINT_TEXT = bool_val(ini.tint_text, true)

-- KEYBINDS. Every action is rebindable from settings.ini, written the way you
-- would say it: "CONTROL+SHIFT+J". An EMPTY value leaves that action unbound,
-- which is the escape hatch when another mod already owns the combination.
-- Parsed and registered further down, in the HOTKEYS section.
local DEFAULT_BINDS = {
    key_next     = "CONTROL+SHIFT+J",
    key_prev     = "CONTROL+SHIFT+U",
    key_brighter = "CONTROL+SHIFT+O",
    key_dimmer   = "CONTROL+SHIFT+I",
    key_toggle   = "CONTROL+SHIFT+M",
    key_report   = "CONTROL+SHIFT+G",
    key_reload   = "CONTROL+SHIFT+R",
}
-- Fixed order so the written ini is stable rather than reshuffling on each save.
local BIND_ORDER = { "key_next", "key_prev", "key_brighter", "key_dimmer",
                     "key_toggle", "key_report", "key_reload" }
local BINDS = {}
for _, action in ipairs(BIND_ORDER) do
    -- An ini value of "" is a deliberate unbind, so only a MISSING key falls
    -- back to the default -- `or` on the raw value would silently rebind it.
    local v = ini[action]
    BINDS[action] = (v ~= nil) and v or DEFAULT_BINDS[action]
end

local function current_color()
    local p = CUSTOM_COLOR or PRESETS[preset_index] or PRESETS[1]
    -- Components above 1.0 are legal in a linear colour and are how a multiply
    -- tint gets back to full brightness; deliberately NOT clamped to 1.
    return {
        R = p.r * INTENSITY,
        G = p.g * INTENSITY,
        B = p.b * INTENSITY,
        A = 1.0,          -- alpha here would fade the HUD; that is RenderOpacity's job
    }, p.name
end

local IDENTITY = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

-- The colour ONE element should end up with: its own override if it has one,
-- otherwise the global colour. Colour and intensity resolve independently, so
-- "same colour as everything else, just brighter" is a one-line override.
local function color_for(key)
    local spec = key and OVERRIDE_COLOR[key]
    local p
    if spec and #spec > 0 then
        p = parse_custom(spec)
        if not p then
            local i = find_preset(spec)
            p = i and PRESETS[i] or nil
        end
        -- An unparseable override falls through to the global colour rather
        -- than to black: a typo should read as "my override did not take", not
        -- as "the element vanished".
    end
    p = p or CUSTOM_COLOR or PRESETS[preset_index] or PRESETS[1]
    local inten = (key and OVERRIDE_INTENSITY[key]) or INTENSITY
    return { R = p.r * inten, G = p.g * inten, B = p.b * inten, A = 1.0 }
end

local function write_settings()
    local _, pname = current_color()
    local col = CUSTOM_COLOR
        and string.format("%.3f,%.3f,%.3f", CUSTOM_COLOR.r, CUSTOM_COLOR.g, CUSTOM_COLOR.b)
        or pname
    local f = io.open(SETTINGS_FILE, "w")
    if not f then
        f = io.open(LEGACY_SETTINGS, "w")
        if f then SETTINGS_FILE = LEGACY_SETTINGS end
    end
    if not f then log("settings: could not write " .. SETTINGS_FILE); return end
    f:write("# CE HUD Color - settings\n")
    f:write("# color: a preset name (" )
    local names = {}
    for _, p in ipairs(PRESETS) do names[#names + 1] = p.name end
    f:write(table.concat(names, ", ") .. ") or a literal \"r,g,b\".\n")
    f:write("# intensity: multiplier; above 1.0 brightens (the tint is a multiply).\n")
    f:write("enabled=" .. tostring(ENABLED) .. "\n")
    f:write("color=" .. col .. "\n")
    f:write(string.format("intensity=%.2f\n", INTENSITY))
    f:write("targets=" .. table.concat(TARGETS, ",") .. "\n")
    f:write("tint_reticle=" .. tostring(TINT_RETICLE) .. "\n")
    f:write("tint_text=" .. tostring(TINT_TEXT) .. "\n")
    if #OVERRIDE_KEYS > 0 then
        f:write("# Per-element overrides: color_<element> / intensity_<element>.\n")
        for _, key in ipairs(OVERRIDE_KEYS) do
            if OVERRIDE_COLOR[key] then
                f:write("color_" .. key .. "=" .. OVERRIDE_COLOR[key] .. "\n")
            end
            if OVERRIDE_INTENSITY[key] then
                f:write(string.format("intensity_%s=%.2f\n", key, OVERRIDE_INTENSITY[key]))
            end
        end
    end
    f:write("# Keybinds: MODIFIER+MODIFIER+KEY (CONTROL/SHIFT/ALT, any order).\n")
    f:write("# Leave a value empty to unbind it. UE4SS binds at load, so a\n")
    f:write("# change here needs a restart.\n")
    for _, action in ipairs(BIND_ORDER) do
        f:write(action .. "=" .. tostring(BINDS[action] or "") .. "\n")
    end
    f:close()
end

local function save()
    local ok, err = pcall(write_settings)
    if not ok then log("settings: SAVE FAILED - " .. tostring(err)) end
end

--------------------------------------------------------------------
--  WIDGET HELPERS
--------------------------------------------------------------------

local function class_name(obj)
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return nil end
    local ok2, full = pcall(function() return cls:GetFullName() end)
    if not ok2 then return nil end
    return full
end

local function short_name(obj)
    local n = "?"
    pcall(function() n = obj:GetFName():ToString() end)
    return n
end

local function matches_any(name, list)
    for _, pat in ipairs(list) do
        if string.find(name, pat, 1, true) then return true end
    end
    return false
end

-- Should this widget be tinted? Class path must be a HUD asset AND match one
-- of the configured target keys. The reticle is gated separately.
-- Returns the TARGET KEY this widget matched, or nil. The key -- not just a
-- yes/no -- is what makes per-element colours possible: it is the name the
-- override is written against in settings.ini.
local function target_key(lname)
    if not string.find(lname, HUD_PATH, 1, true) then return nil end
    if string.find(lname, "reticle", 1, true) then
        return TINT_RETICLE and "reticle" or nil
    end
    for _, key in ipairs(TARGETS) do
        if string.find(lname, key, 1, true) then return key end
    end
    return nil
end

--------------------------------------------------------------------
--  THE TINT PASS
--
--  FindAllOf scans the whole UObject array (~395k entries here), so the scan
--  runs on a slow cadence and the per-pass work is just re-issuing the setter
--  on already-found widgets. Re-issuing matters: the game rebuilds HUD widgets
--  across level loads and mode changes, and a rebuilt widget comes back stock.
--------------------------------------------------------------------

local tinted = {}          -- cached list of live target widgets
local pass = 0
local last_report = {}     -- class -> true, for the Ctrl+Shift+G report

local function rescan()
    tinted = {}
    last_report = {}
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                -- Skip class-default objects: FindAllOf returns the CDO next to
                -- the live widget and setters on it do nothing but look like
                -- they worked.
                local key = target_key(ln)
                if key and not string.find(short_name(w):lower(), "default__", 1, true) then
                    tinted[#tinted + 1] = { w = w, key = key }
                    last_report[n] = key
                end
            end
        end
    end
end

-- `forced` paints every element the same colour regardless of overrides; it is
-- how switching off restores stock. Left nil, each element resolves its own.
local function apply_tint(forced)
    for _, rec in ipairs(tinted) do
        if rec.w:IsValid() then
            local c = forced or color_for(rec.key)
            -- Flat { R, G, B, A } -- the crash-safe FLinearColor marshal.
            pcall(function() rec.w:SetColorAndOpacity(c) end)
        end
    end
end

local function enforce()
    -- While the tint is off there is nothing to enforce: a HUD widget rebuilt
    -- in that state comes back stock, which is exactly what "off" means. So the
    -- loop costs nothing at all rather than scanning ~395k objects to re-assert
    -- the identity colour. (Switching off applies identity once, in refresh().)
    if not ENABLED then return end
    pass = pass + 1
    if (pass % RESCAN_EVERY_PASSES) == 1 or #tinted == 0 then rescan() end
    apply_tint()
end

--------------------------------------------------------------------
--  AMMO TEXT
--
--  The ammo counters are TextBlocks whose colour the game re-asserts on every
--  ammo change, so a one-shot set never sticks. Other HUD mods commonly force
--  those counters to a colour of their own through this same UFunction. Both
--  cases are handled the same way: hook the setter and
--  MUTATE the incoming struct in place before the call runs, which is the one
--  colour hijack shape proven stable in this game.
--
--  What we write depends on whether the parent cradle is being tinted:
--    * cradle tinted  -> write WHITE. The parent multiply then lands the text
--                        on exactly the tint colour, matching everything else.
--    * cradle untinted -> write the tint colour directly.
--  Only RGB is touched. Alpha is left exactly as the caller set it, so
--  a magazine number another mod has hidden by painting alpha 0 stays hidden
--  -- we must never resurrect it.
--
--  LOAD ORDER: hooks on one UFunction run in REGISTRATION order, so when
--  another HUD mod paints these counters too, whichever loaded LAST wins.
--  mods.txt is the only load order UE4SS defines -- mods enabled by an
--  enabled.txt file are started in a second pass its own log calls "no
--  defined load order" -- so list this mod in mods.txt BELOW any mod whose
--  ammo colours you want to override. Nothing breaks either way; the counter
--  simply keeps the other mod's colour.
--------------------------------------------------------------------

-- Reserve / total ammo fields only. Matching the magazine fields as well would
-- mean writing colour onto a widget another mod may be keeping invisible.
local RESERVE_NAMES = {
    ["maxammocounttextblock"] = true,
    ["halouinumerictextblock_ammototal"] = true,
}

local function text_rgb()
    local c = current_color()
    -- Is the cradle that hosts this text itself being tinted? If so the parent
    -- multiply supplies the colour and the text just needs to be neutral.
    if matches_any("weaponcradle", TARGETS) then return 1.0, 1.0, 1.0 end
    return c.R, c.G, c.B
end

if TINT_TEXT then
    local ok, err = pcall(function()
        RegisterHook("/Script/UMG.TextBlock:SetColorAndOpacity", function(self, InColor)
            if not ENABLED then return end
            pcall(function()
                local w = self:get()
                if not (w and w:IsValid()) then return end
                if not RESERVE_NAMES[short_name(w):lower()] then return end
                local c = InColor:get()
                local r, g, b = text_rgb()
                c.SpecifiedColor.R = r
                c.SpecifiedColor.G = g
                c.SpecifiedColor.B = b
                c.ColorUseRule = 0        -- use SpecifiedColor, not a style lookup
                -- alpha deliberately untouched (see note above)
            end)
        end)
    end)
    if ok then log("ammo-text hook active on TextBlock:SetColorAndOpacity")
    else log("ammo-text hook failed to register: " .. tostring(err)) end
end

--------------------------------------------------------------------
--  HOTKEYS
--------------------------------------------------------------------

-- Shorthands, so a bind can be written the way it is printed on the keycap
-- rather than as UE4SS's internal enum name. Anything not listed here is
-- looked up in UE4SS's Key table verbatim, so any name that build exposes
-- works even if it is not spelled out below.
local KEY_ALIASES = {
    CTRL = "CONTROL", CONTROL = "CONTROL", SHIFT = "SHIFT", ALT = "ALT",
    ESC = "ESCAPE", DELETE = "DEL", INSERT = "INS", RETURN = "ENTER",
    PGUP = "PAGE_UP", PGDN = "PAGE_DOWN",
    LEFT = "LEFT_ARROW", RIGHT = "RIGHT_ARROW",
    UP = "UP_ARROW", DOWN = "DOWN_ARROW",
    ["-"] = "OEM_MINUS", ["="] = "OEM_PLUS", ["["] = "OEM_4", ["]"] = "OEM_6",
    [";"] = "OEM_1", ["'"] = "OEM_7", [","] = "OEM_COMMA", ["."] = "OEM_PERIOD",
    ["/"] = "OEM_2", ["\\"] = "OEM_5", ["`"] = "OEM_3",
    ["0"] = "NUM_ZERO", ["1"] = "NUM_ONE", ["2"] = "NUM_TWO", ["3"] = "NUM_THREE",
    ["4"] = "NUM_FOUR", ["5"] = "NUM_FIVE", ["6"] = "NUM_SIX", ["7"] = "NUM_SEVEN",
    ["8"] = "NUM_EIGHT", ["9"] = "NUM_NINE",
}
local MODIFIER_NAMES = { CONTROL = true, SHIFT = true, ALT = true }

-- "CONTROL+SHIFT+J" -> Key.J, { ModifierKey.CONTROL, ModifierKey.SHIFT }
-- Returns nil plus a reason on anything malformed; the caller logs it and
-- leaves that one action unbound rather than failing the load.
local function parse_bind(spec)
    local mods, keyname = {}, nil
    for token in tostring(spec):gmatch("[^+]+") do
        local t = token:match("^%s*(.-)%s*$"):upper()
        t = KEY_ALIASES[t] or t
        if #t > 0 then
            if MODIFIER_NAMES[t] then
                if ModifierKey[t] == nil then
                    return nil, nil, "this UE4SS build has no modifier '" .. t .. "'"
                end
                mods[#mods + 1] = ModifierKey[t]
            elseif keyname ~= nil then
                return nil, nil, "more than one key in '" .. tostring(spec) .. "'"
            else
                keyname = t
            end
        end
    end
    if keyname == nil then return nil, nil, "no key in '" .. tostring(spec) .. "'" end
    if Key[keyname] == nil then return nil, nil, "unknown key name '" .. keyname .. "'" end
    return Key[keyname], mods, nil
end

-- Registers one action. Every failure mode -- unbound, misspelled, or already
-- taken by another mod -- ends in a log line and a still-working mod, never a
-- failed load: a typo in an ini should cost you one hotkey, not the tint.
local function bind(action, fn)
    local spec = BINDS[action]
    if spec == nil or spec:match("^%s*$") then
        log("bind " .. action .. ": unbound (empty in settings.ini)")
        return
    end
    local key, mods, err = parse_bind(spec)
    if key == nil then
        log("bind " .. action .. ": " .. err .. " -- left unbound")
        return
    end
    local ok = pcall(function()
        if #mods > 0 then RegisterKeyBind(key, mods, fn) else RegisterKeyBind(key, fn) end
    end)
    if not ok then
        log("bind " .. action .. " (" .. spec .. "): could not register -- "
            .. "already taken by another mod? Change it in settings.ini.")
    end
end

local function announce()
    local c, name = current_color()
    log(string.format("colour = %s  (%.2f, %.2f, %.2f)  intensity %.2f  %s",
        name, c.R, c.G, c.B, INTENSITY, ENABLED and "ON" or "OFF"))
end

local function refresh()
    -- Apply immediately instead of waiting up to a second for the enforce tick.
    -- Rescan first if we have never swept: a hotkey pressed in the first second
    -- after load would otherwise repaint an empty list and appear to do nothing.
    local ok, e = pcall(function()
        if #tinted == 0 then rescan() end
        -- NOT `ENABLED and nil or IDENTITY`: in Lua that yields IDENTITY
        -- either way, because the `and` arm is nil. Spell it out.
        if ENABLED then apply_tint() else apply_tint(IDENTITY) end
    end)
    if not ok then log("apply error: " .. tostring(e)) end
    announce()
    save()
end

local function cycle(delta)
    CUSTOM_COLOR = nil            -- stepping through presets drops a custom colour
    if preset_index == 0 then preset_index = 1 end
    preset_index = preset_index + delta
    if preset_index > #PRESETS then preset_index = 1 end
    if preset_index < 1 then preset_index = #PRESETS end
    ENABLED = true
    refresh()
end

bind("key_next", function() cycle(1) end)
bind("key_prev", function() cycle(-1) end)

local function step_intensity(d)
    INTENSITY = INTENSITY + d
    if INTENSITY < INTENSITY_MIN then INTENSITY = INTENSITY_MIN end
    if INTENSITY > INTENSITY_MAX then INTENSITY = INTENSITY_MAX end
    ENABLED = true
    refresh()
end

bind("key_brighter", function() step_intensity(INTENSITY_STEP) end)
bind("key_dimmer",   function() step_intensity(-INTENSITY_STEP) end)

bind("key_toggle", function()
    ENABLED = not ENABLED
    -- Turning it off writes the identity colour back, so the HUD returns to
    -- stock rather than freezing on the last tint.
    refresh()
end)

--------------------------------------------------------------------
--  WEAPON-SCREEN PROBE
--
--  The ammo readout ON THE GUN MODEL is not a Slate widget -- there is no
--  widget class for it anywhere in the reflected type set, and the HUD-path
--  scan never sees it. It is drawn by a MATERIAL on the first-person weapon
--  mesh, which is a different mechanism entirely: no ColorAndOpacity to set,
--  only material parameters.
--
--  Recolouring it would mean CreateDynamicMaterialInstance on the weapon mesh
--  and then SetVectorParameterValue -- which is reachable (the setter takes a
--  flat FLinearColor, the same crash-safe marshal used throughout this file),
--  but only once we know WHICH material slot and WHICH parameter name. Those
--  are per-asset and cannot be guessed offline, so this probe reads them off
--  the live weapon and prints them. Every read is guarded; on any build where
--  the shape differs it prints nothing rather than throwing.
--------------------------------------------------------------------

local function probe_weapon_materials()
    log("---- first-person weapon materials (screen-colour probe) ----")
    local comps = FindAllOf("SkeletalMeshComponent")
    if not comps then log("  (no skeletal mesh components -- in a mission?)"); return end

    local looked = 0
    for _, c in ipairs(comps) do
        if c:IsValid() then
            local nm = short_name(c):lower()
            -- first-person arms/weapon meshes; anything else is scenery or NPCs
            if string.find(nm, "weapon", 1, true) or string.find(nm, "firstperson", 1, true)
               or string.find(nm, "_fp", 1, true) or string.find(nm, "1p", 1, true) then
                looked = looked + 1
                if looked > 6 then break end        -- a handful is plenty to identify it
                log("  component: " .. short_name(c) .. "  [" .. short_class(c) .. "]")
                local count = 0
                pcall(function() count = c:GetNumMaterials() end)
                for i = 0, math.min(count, 8) - 1 do
                    local mat
                    pcall(function() mat = c:GetMaterial(i) end)
                    if mat and mat:IsValid() then
                        log(string.format("    [%d] %s", i, short_name(mat)))
                        -- VectorParameterValues is a reflected array on
                        -- MaterialInstance; a plain UMaterial has none, which
                        -- is itself the answer (nothing to drive).
                        local ok = pcall(function()
                            local params = mat.VectorParameterValues
                            params:ForEach(function(_, entry)
                                pcall(function()
                                    local v = entry:get()
                                    local pname = v.ParameterInfo.Name:ToString()
                                    local col = v.ParameterValue
                                    log(string.format("         vector param  %-28s = %.2f,%.2f,%.2f",
                                        pname, col.R, col.G, col.B))
                                end)
                            end)
                        end)
                        if not ok then
                            log("         (no readable vector parameters on this material)")
                        end
                    end
                end
            end
        end
    end
    if looked == 0 then
        log("  (no first-person weapon mesh matched -- hold a weapon and retry)")
    end
end

-- Diagnostic: what did the scan actually find, and what did it skip? If a HUD
-- element refuses to change colour, this tells us whether it was never matched
-- (fix the targets list) or was matched and ignored the tint (its material
-- does not sample the Slate vertex colour, which no runtime tint can fix).
-- Re-read settings.ini without restarting the game. `targets` has no hotkey
-- of its own, so this is what makes tuning it practical: edit the file, press
-- the key, see the result. Widgets that were tinted but are no longer targets
-- are returned to stock first -- otherwise dropping something from the list
-- would leave it wearing the old colour with nothing left to repaint it.
bind("key_reload", function()
    local ok, err = pcall(function()
        apply_tint(IDENTITY)          -- release the outgoing target set
        tinted = {}
        adopt(read_settings())
        rescan()
        -- NOT `ENABLED and nil or IDENTITY`: in Lua that yields IDENTITY
        -- either way, because the `and` arm is nil. Spell it out.
        if ENABLED then apply_tint() else apply_tint(IDENTITY) end
    end)
    if not ok then
        log("reload failed: " .. tostring(err))
        return
    end
    log("settings reloaded from " .. SETTINGS_FILE)
    log("  targets: " .. table.concat(TARGETS, ", "))
    announce()
    -- NOT saved: a reload is the file overwriting memory, so writing back here
    -- would be a no-op at best and, if the read half-failed, would overwrite
    -- the user's file with defaults.
end)

bind("key_report", function()
    rescan()
    log("---- tint targets (matched) ----")
    local n = 0
    for cls, key in pairs(last_report) do
        n = n + 1
        local c = color_for(key)
        log(string.format("  [%s] %.2f,%.2f,%.2f  %s", key, c.R, c.G, c.B, cls))
    end
    if n == 0 then log("  (none -- are you in a mission?)") end
    log("---- other live HUD widgets (not matched) ----")
    local widgets = FindAllOf("UserWidget")
    local seen = {}
    if widgets then
        for _, w in ipairs(widgets) do
            if w:IsValid() then
                local c = class_name(w)
                if c and string.find(c:lower(), HUD_PATH, 1, true)
                   and not last_report[c] and not seen[c] then
                    seen[c] = true
                    log("  " .. c)
                end
            end
        end
    end
    log("---- end (" .. n .. " tinted) ----")
    local okp, ep = pcall(probe_weapon_materials)
    if not okp then log("weapon-material probe error: " .. tostring(ep)) end
end)

--------------------------------------------------------------------
--  PERSISTENCE
--------------------------------------------------------------------

-- A HUD widget built after the last rescan (level load, mode change) comes back
-- stock-coloured; catch it as it appears rather than waiting for the sweep.
NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
    if not ENABLED then return end
    local n = class_name(widget)
    if not n then return end
    local key = target_key(n:lower())
    if not key then return end
    ExecuteWithDelay(50, function()
        pcall(function()
            if widget:IsValid() then widget:SetColorAndOpacity(color_for(key)) end
        end)
    end)
end)

LoopAsync(ENFORCE_INTERVAL_MS, function()
    local ok, e = pcall(enforce)
    if not ok then log("enforce error: " .. tostring(e)) end
    return false
end)

local _, pname = current_color()
log("Loaded  [v" .. MOD_VERSION .. "]")
log(string.format("  colour=%s  intensity=%.2f  enabled=%s  reticle=%s  text=%s",
    pname, INTENSITY, tostring(ENABLED), tostring(TINT_RETICLE), tostring(TINT_TEXT)))
log("  targets: " .. table.concat(TARGETS, ", "))
-- Print the binds that are ACTUALLY in force, not the shipped defaults: once
-- they are rebindable, a fixed banner is a banner that lies to whoever changed
-- them (and to anyone reading their UE4SS.log to help).
local BIND_LABELS = {
    key_next = "next colour", key_prev = "previous colour",
    key_brighter = "brighter",  key_dimmer = "dimmer",
    key_toggle = "tint on/off", key_report = "report",
    key_reload = "reload ini",
}
for _, action in ipairs(BIND_ORDER) do
    local spec = BINDS[action]
    log(string.format("  %-14s %s", BIND_LABELS[action] or action,
        (spec ~= nil and not spec:match("^%s*$")) and spec or "(unbound)"))
end
