-- CEHudColor: the HUD recolour mod.
--
-- What this pins down, in order of how much it would hurt to get wrong:
--   * the tint reaches the elements it is configured for and NOTHING else --
--     in particular not the class-default object (a setter on the CDO reports
--     success and changes nothing on screen), and
--     not the radar or the reticle unless they were opted in;
--   * the ammo-text hook never touches ALPHA, because a HUD mod running
--     alongside this one may be hiding the magazine number with alpha 0, and
--     resurrecting it would be a visible regression in that mod;
--   * switching the tint off actually restores the stock colour instead of
--     freezing on the last one;
--   * the settings file round-trips, so a tuned colour survives a restart.

local M = require("ue4ss_mock")

local MOD = MODTEST_ROOT .. "/Scripts/main.lua"
local INI = "ue4ss/Mods/CEHudColor/settings.ini"
local suite = M.suite("CEHudColor")

---------------------------------------------------------------------------
-- world
---------------------------------------------------------------------------

-- The mock ships the globals the existing suites need. Two more are added
-- here rather than in ue4ss_mock.lua so this suite stays a pure addition:
--   * letter keys -- the mock's Key table only carries F-keys and numbers;
--   * LoopAsync   -- captured so tests drive the enforce sweep by hand
--                    instead of depending on a real timer.
local function extend(env)
    for letter in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
        _G.Key[letter] = letter
    end
    env.loops = {}
    _G.LoopAsync = function(ms, fn) env.loops[#env.loops + 1] = { ms = ms, fn = fn } end
    env.newObjectCallbacks = {}
    _G.NotifyOnNewObject = function(_, fn)
        env.newObjectCallbacks[#env.newObjectCallbacks + 1] = fn
    end
    return env
end

local function runLoops(env, times)
    for _ = 1, (times or 1) do
        for _, loop in ipairs(env.loops) do loop.fn() end
    end
    return env
end

-- A HUD widget as the mod sees it: a class whose full name is the asset path
-- (that path is the entire basis for "is this a HUD element"), plus the one
-- setter the mod calls. Every applied colour is recorded on the env so a test
-- can assert what each element ended up as.
local function widget(env, instanceName, classPath)
    local class = M.object(classPath, {})
    local w
    w = M.object(instanceName .. " /Game/Level.Level:WidgetTree." .. instanceName, {
        GetClass = function() return class end,
        SetColorAndOpacity = function(_, color)
            env.tints = env.tints or {}
            env.tints[instanceName] = color
        end,
    })
    env:register("UserWidget", w)
    return w
end

local function hudWorld(env)
    env.tints = {}
    widget(env, "WBP_ShieldHealthBar_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/ShieldHealthBar/WBP_ShieldHealthBar.WBP_ShieldHealthBar_C")
    widget(env, "WBP_WeaponCradle_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/WeaponCradle/WBP_WeaponCradle.WBP_WeaponCradle_C")
    widget(env, "WBP_GrenadeCradle_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/GrenadeCradle/WBP_GrenadeCradle.WBP_GrenadeCradle_C")
    widget(env, "WBP_EquipmentIcon_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/EquipmentIcon/WBP_EquipmentIcon.WBP_EquipmentIcon_C")
    widget(env, "WBP_MotionTracker_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/MotionTracker/WBP_MotionTracker.WBP_MotionTracker_C")
    widget(env, "WBP_WeaponAim_Scope_Shared_C_0",
        "BlueprintGeneratedClass /Game/UI/Hud/Reticle/Widgets/WBP_WeaponAim_Scope_Shared.WBP_WeaponAim_Scope_Shared_C")
    -- FindAllOf hands back the class-default object next to the live widget.
    widget(env, "Default__WBP_ShieldHealthBar_C",
        "BlueprintGeneratedClass /Game/UI/Hud/ShieldHealthBar/WBP_ShieldHealthBar.WBP_ShieldHealthBar_C")
    -- A menu widget, to prove the HUD-path test is doing real work.
    widget(env, "WBP_PauseMenu_C_0",
        "BlueprintGeneratedClass /Game/UI/Menus/Pause/WBP_PauseMenu.WBP_PauseMenu_C")
    return env
end

local function start(iniBody)
    local files = {}
    if iniBody then files[INI] = iniBody end
    local env = M.newEnv({ files = files }):install()
    extend(env)
    hudWorld(env)
    env:loadMod(MOD)
    return env
end

local function tintOf(env, name) return env.tints[name] end

local function isColor(c, r, g, b)
    if c == nil then return false end
    local function near(a, want) return math.abs(a - want) < 0.005 end
    return near(c.R, r) and near(c.G, g) and near(c.B, b) and near(c.A, 1.0)
end

---------------------------------------------------------------------------
-- per-element overrides
---------------------------------------------------------------------------

local BASE = "enabled=true\ncolor=green\nintensity=1.00\ntint_reticle=true\n"
    .. "tint_text=true\ntargets=shieldhealthbar,weaponcradle,motiontracker\n"

suite:test("an element can be given its own colour", function(s)
    local env = start(BASE .. "color_motiontracker=red\n")
    s.env = env
    runLoops(env)

    s:check("overridden element uses its own colour",
        isColor(tintOf(env, "WBP_MotionTracker_C_0"), 1.00, 0.25, 0.22))
    s:check("everything else still follows the global colour",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.35, 1.00, 0.45))
end)

suite:test("an element can be given its own intensity", function(s)
    local env = start(BASE .. "intensity_motiontracker=2.00\n")
    s.env = env
    runLoops(env)

    -- colour inherited from the global, brightness its own
    s:check("overridden element scales independently",
        isColor(tintOf(env, "WBP_MotionTracker_C_0"), 0.70, 2.00, 0.90))
    s:check("global element unaffected",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.35, 1.00, 0.45))
end)

suite:test("colour and intensity overrides compose, and literals work", function(s)
    local env = start(BASE .. "color_weaponcradle=0.900,0.200,0.400\n"
        .. "intensity_weaponcradle=2.00\n")
    s.env = env
    runLoops(env)
    s:check("literal rgb times its own intensity",
        isColor(tintOf(env, "WBP_WeaponCradle_C_0"), 1.80, 0.40, 0.80))
end)

suite:test("the reticle is an overridable element like any other", function(s)
    local env = start(BASE .. "color_reticle=amber\n")
    s.env = env
    runLoops(env)
    s:check("crosshair takes its own colour",
        isColor(tintOf(env, "WBP_WeaponAim_Scope_Shared_C_0"), 1.00, 0.68, 0.15))
end)

suite:test("a typo'd override falls back instead of blacking the element out", function(s)
    local env = start(BASE .. "color_motiontracker=greeen\n")
    s.env = env
    runLoops(env)
    s:check("unparseable override falls through to the global colour",
        isColor(tintOf(env, "WBP_MotionTracker_C_0"), 0.35, 1.00, 0.45))
end)

suite:test("hotkeys move the global colour without disturbing overrides", function(s)
    local env = start(BASE .. "color_motiontracker=red\n")
    s.env = env
    runLoops(env)
    env:press("CONTROL+SHIFT+J")      -- global green -> cyan

    s:check("global element followed the hotkey",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.40, 0.90, 1.00))
    s:check("overridden element stayed put",
        isColor(tintOf(env, "WBP_MotionTracker_C_0"), 1.00, 0.25, 0.22))
end)

suite:test("overrides survive a save/reload round-trip", function(s)
    local env = start(BASE .. "color_motiontracker=red\nintensity_weaponcradle=2.00\n")
    s.env = env
    runLoops(env)
    env:press("CONTROL+SHIFT+J")      -- any action saves

    local written = env.files[INI]
    s:check("colour override written back",
        written:find("color_motiontracker=red", 1, true) ~= nil)
    s:check("intensity override written back",
        written:find("intensity_weaponcradle=2.00", 1, true) ~= nil)
    -- A save that dropped the overrides would silently reset an advanced setup
    -- the first time the user touched a hotkey.
    local env2 = M.newEnv({ files = { [INI] = written } }):install()
    extend(env2); hudWorld(env2); env2:loadMod(MOD); runLoops(env2)
    s:check("override still in force after reload",
        isColor(tintOf(env2, "WBP_MotionTracker_C_0"), 1.00, 0.25, 0.22))
end)

---------------------------------------------------------------------------
-- live reload
---------------------------------------------------------------------------

suite:test("reload picks up an edited targets list without a restart", function(s)
    local env = start(BASE)
    s.env = env
    runLoops(env)
    s:check("radar tinted to begin with", tintOf(env, "WBP_MotionTracker_C_0") ~= nil)

    -- edit the file underneath the running mod: drop the radar, add a colour
    env.files[INI] = "enabled=true\ncolor=red\nintensity=1.00\ntint_text=true\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\n"
    env:press("CONTROL+SHIFT+R")

    s:check("new colour applied", isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 1.00, 0.25, 0.22))
    -- The important half: an element dropped from targets must be RETURNED to
    -- stock, not left wearing the old tint with nothing left to repaint it.
    s:check("dropped element restored to stock",
        isColor(tintOf(env, "WBP_MotionTracker_C_0"), 1.00, 1.00, 1.00))
    s:check("said what it reloaded", env:logContains("targets: shieldhealthbar"))
end)

suite:test("reload does not write the file back over the user's edit", function(s)
    local env = start(BASE)
    s.env = env
    runLoops(env)
    local edited = "enabled=true\ncolor=purple\nintensity=1.00\ntint_text=true\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\n"
    env.files[INI] = edited
    env:press("CONTROL+SHIFT+R")
    s:equals("file untouched by the reload", env.files[INI], edited)
end)

suite:test("a reload of a missing file cannot wedge the mod", function(s)
    local env = start(BASE)
    s.env = env
    runLoops(env)
    env.files[INI] = nil
    env:press("CONTROL+SHIFT+R")
    -- No file means no settings, so it falls back to shipped defaults and
    -- carries on rather than throwing inside the keybind handler.
    s:check("still tinting", tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
    s:check("no reload failure logged", not env:logContains("reload failed"))
end)

---------------------------------------------------------------------------
-- keybinds
---------------------------------------------------------------------------

suite:test("keybinds are taken from settings.ini", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n"
        .. "key_next=ALT+P\nkey_toggle=SHIFT+CONTROL+ALT+F5\n")
    s.env = env
    runLoops(env)

    s:check("custom single-modifier bind registered", env.binds["ALT+P"] ~= nil)
    s:check("modifier order does not matter",
        env.binds["ALT+CONTROL+SHIFT+F5"] ~= nil)
    s:check("the default it replaced is gone", env.binds["CONTROL+SHIFT+J"] == nil)
    s:check("untouched actions keep their defaults", env.binds["CONTROL+SHIFT+U"] ~= nil)

    env:press("ALT+P")
    s:check("the rebound key actually cycles the colour",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.40, 0.90, 1.00))
end)

suite:test("an empty keybind value unbinds that action", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n"
        .. "key_report=\n")
    s.env = env
    s:check("nothing registered for the emptied action",
        env.binds["CONTROL+SHIFT+G"] == nil)
    s:check("said so in the log", env:logContains("key_report: unbound"))
    -- an empty value is a deliberate unbind, NOT a request for the default
    runLoops(env)
    s:check("the mod still works", tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
end)

suite:test("a misspelled keybind costs one hotkey, not the mod", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n"
        .. "key_next=CONTROL+SHIFT+NOPE\nkey_prev=CONTROL+SHIFT\n")
    s.env = env
    s:check("unknown key name reported", env:logContains("unknown key name 'NOPE'"))
    s:check("a modifier-only bind is reported", env:logContains("no key in"))
    s:check("neither was registered", env.binds["CONTROL+SHIFT+NOPE"] == nil)
    runLoops(env)
    s:check("everything else still loaded and works",
        tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
end)

suite:test("keybinds survive a save/reload round-trip", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n"
        .. "key_next=ALT+P\nkey_report=\n")
    s.env = env
    runLoops(env)
    env:press("ALT+P")             -- any action saves

    local written = env.files[INI]
    s:check("custom bind written back", written:find("key_next=ALT+P", 1, true) ~= nil)
    s:check("the unbind stayed an unbind", written:find("key_report=\n", 1, true) ~= nil)

    local env2 = M.newEnv({ files = { [INI] = written } }):install()
    extend(env2)
    hudWorld(env2)
    env2:loadMod(MOD)
    s:check("custom bind still in force after reload", env2.binds["ALT+P"] ~= nil)
    s:check("unbind was not resurrected by the save",
        env2.binds["CONTROL+SHIFT+G"] == nil)
end)

---------------------------------------------------------------------------
-- tests
---------------------------------------------------------------------------

suite:test("tints the configured elements and leaves everything else alone", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar,weaponcradle,grenadecradle,equipmenticon\n"
        .. "tint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    s:check("shield bar tinted green",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.35, 1.00, 0.45))
    s:check("weapon cradle tinted", tintOf(env, "WBP_WeaponCradle_C_0") ~= nil)
    s:check("grenade cradle tinted", tintOf(env, "WBP_GrenadeCradle_C_0") ~= nil)
    s:check("equipment icon tinted", tintOf(env, "WBP_EquipmentIcon_C_0") ~= nil)

    s:check("radar left alone (blip colours survive)",
        tintOf(env, "WBP_MotionTracker_C_0") == nil)
    s:check("reticle left alone by default",
        tintOf(env, "WBP_WeaponAim_Scope_Shared_C_0") == nil)
    s:check("class-default object never touched",
        tintOf(env, "Default__WBP_ShieldHealthBar_C") == nil)
    s:check("non-HUD widget never touched", tintOf(env, "WBP_PauseMenu_C_0") == nil)
end)

suite:test("opt-in targets reach the radar and the reticle", function(s)
    local env = start("enabled=true\ncolor=amber\nintensity=1.00\n"
        .. "targets=shieldhealthbar,motiontracker\ntint_reticle=true\ntint_text=true\n")
    s.env = env
    runLoops(env)

    s:check("radar tinted when asked for", tintOf(env, "WBP_MotionTracker_C_0") ~= nil)
    s:check("reticle tinted when asked for",
        tintOf(env, "WBP_WeaponAim_Scope_Shared_C_0") ~= nil)
    s:check("cradle dropped from the target list is not tinted",
        tintOf(env, "WBP_WeaponCradle_C_0") == nil)
end)

suite:test("a literal r,g,b colour is honoured", function(s)
    local env = start("enabled=true\ncolor=0.900,0.200,0.400\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)
    s:check("custom colour applied",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.90, 0.20, 0.40))
end)

suite:test("intensity scales the tint and can push past 1.0", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    env:press("CONTROL+SHIFT+O")   -- brighter
    env:press("CONTROL+SHIFT+O")
    local c = tintOf(env, "WBP_ShieldHealthBar_C_0")
    -- The whole point of allowing >1: green's G channel is already 1.0, so a
    -- clamped implementation could not brighten at all.
    s:check("green channel pushed above 1.0", c ~= nil and c.G > 1.05)
    s:check("channels scale together", c ~= nil and math.abs(c.R - 0.35 * 1.2) < 0.01)

    for _ = 1, 40 do env:press("CONTROL+SHIFT+I") end   -- dimmer, past the floor
    c = tintOf(env, "WBP_ShieldHealthBar_C_0")
    s:check("intensity clamps at the floor instead of inverting",
        c ~= nil and c.G > 0.19 and c.G < 0.21)
end)

suite:test("cycling presets applies immediately and wraps", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    env:press("CONTROL+SHIFT+J")
    s:check("next preset is cyan",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.40, 0.90, 1.00))
    env:press("CONTROL+SHIFT+U")
    s:check("previous preset returns to green",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 0.35, 1.00, 0.45))

    for _ = 1, 12 do env:press("CONTROL+SHIFT+J") end
    s:check("wrapping the list never lands on a nil preset",
        tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
end)

suite:test("a hotkey pressed before the first sweep still lands", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    -- deliberately NO runLoops() first: this is the first second after load
    env:press("CONTROL+SHIFT+J")
    s:check("colour applied without waiting for the enforce tick",
        tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
end)

suite:test("switching off restores the stock colour and stops working", function(s)
    local env = start("enabled=true\ncolor=red\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)
    s:check("tinted while on", not isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 1, 1, 1))

    env:press("CONTROL+SHIFT+M")
    s:check("identity colour written on switch-off",
        isColor(tintOf(env, "WBP_ShieldHealthBar_C_0"), 1.0, 1.0, 1.0))

    -- and the sweep must not quietly repaint it afterwards
    env.tints["WBP_ShieldHealthBar_C_0"] = nil
    runLoops(env, 5)
    s:check("enforce loop is idle while off",
        tintOf(env, "WBP_ShieldHealthBar_C_0") == nil)

    env:press("CONTROL+SHIFT+M")
    s:check("switching back on repaints",
        tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
end)

suite:test("a widget rebuilt mid-session is caught", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    local rebuilt = widget(env, "WBP_ShieldHealthBar_C_1",
        "BlueprintGeneratedClass /Game/UI/Hud/ShieldHealthBar/WBP_ShieldHealthBar.WBP_ShieldHealthBar_C")
    for _, fn in ipairs(env.newObjectCallbacks) do fn(rebuilt) end
    env:flush()
    s:check("newly built HUD widget tinted without waiting for a rescan",
        tintOf(env, "WBP_ShieldHealthBar_C_1") ~= nil)
end)

---------------------------------------------------------------------------
-- the ammo text hook
---------------------------------------------------------------------------

-- The hook receives UE4SS parameter wrappers, not raw values.
local function fireText(env, instanceName, color)
    local w = M.object(instanceName .. " /Game/Level.Level:WidgetTree." .. instanceName, {})
    env:fireHook("/Script/UMG.TextBlock:SetColorAndOpacity",
        { get = function() return w end },
        { get = function() return color end })
    return color
end

local function slateColor(r, g, b, a)
    return { SpecifiedColor = { R = r, G = g, B = b, A = a }, ColorUseRule = 1 }
end

suite:test("ammo text is neutralised so the parent tint colours it", function(s)
    local env = start("enabled=true\ncolor=red\nintensity=1.00\n"
        .. "targets=shieldhealthbar,weaponcradle\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    local c = fireText(env, "MaxAmmoCountTextBlock", slateColor(0.4, 0.9, 1.0, 1.0))
    s:check("reserve counter written white (the cradle supplies the colour)",
        math.abs(c.SpecifiedColor.R - 1.0) < 0.005
        and math.abs(c.SpecifiedColor.G - 1.0) < 0.005
        and math.abs(c.SpecifiedColor.B - 1.0) < 0.005)
    s:equals("ColorUseRule switched to the specified colour", c.ColorUseRule, 0)
end)

suite:test("ammo text takes the colour directly when the cradle is not tinted", function(s)
    local env = start("enabled=true\ncolor=red\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    local c = fireText(env, "HaloUINumericTextBlock_AmmoTotal", slateColor(0.4, 0.9, 1.0, 1.0))
    s:check("reserve counter painted red itself",
        math.abs(c.SpecifiedColor.R - 1.0) < 0.005
        and math.abs(c.SpecifiedColor.G - 0.25) < 0.005)
end)

suite:test("the hook never touches alpha or the magazine number", function(s)
    local env = start("enabled=true\ncolor=red\nintensity=1.00\n"
        .. "targets=weaponcradle\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)

    -- A HUD mod may hide the magazine by painting alpha 0. Both halves matter:
    -- the mag must not be recoloured at all, and alpha must survive on the
    -- reserve too, or we would undo a hide in someone else's mod.
    local mag = fireText(env, "CurrentAmmoCountTextBlock", slateColor(0.4, 0.9, 1.0, 0.0))
    s:check("magazine number left entirely alone",
        mag.SpecifiedColor.R == 0.4 and mag.SpecifiedColor.A == 0.0 and mag.ColorUseRule == 1)

    local res = fireText(env, "MaxAmmoCountTextBlock", slateColor(0.4, 0.9, 1.0, 0.7))
    s:equals("alpha preserved on the reserve", res.SpecifiedColor.A, 0.7)
end)

suite:test("the text hook is silent while the tint is off", function(s)
    local env = start("enabled=false\ncolor=red\nintensity=1.00\n"
        .. "targets=weaponcradle\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    local c = fireText(env, "MaxAmmoCountTextBlock", slateColor(0.4, 0.9, 1.0, 1.0))
    s:check("the other mod's colour left in place", c.SpecifiedColor.R == 0.4)
end)

suite:test("tint_text=false registers no hook at all", function(s)
    local env = start("enabled=true\ncolor=red\nintensity=1.00\n"
        .. "targets=weaponcradle\ntint_reticle=false\ntint_text=false\n")
    s.env = env
    s:check("no hook on TextBlock:SetColorAndOpacity",
        env.hooks["/Script/UMG.TextBlock:SetColorAndOpacity"] == nil)
end)

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------

suite:test("settings round-trip through the mod folder, not the exe folder", function(s)
    local env = start("enabled=true\ncolor=green\nintensity=1.00\n"
        .. "targets=shieldhealthbar\ntint_reticle=false\ntint_text=true\n")
    s.env = env
    runLoops(env)
    env:press("CONTROL+SHIFT+J")   -- -> cyan, saves
    env:press("CONTROL+SHIFT+O")   -- -> intensity 1.10, saves

    local written = env.files[INI]
    s:check("wrote to the mod folder", written ~= nil)
    s:check("colour persisted", written:find("color=cyan", 1, true) ~= nil)
    s:check("intensity persisted", written:find("intensity=1.10", 1, true) ~= nil)
    s:check("targets persisted", written:find("targets=shieldhealthbar", 1, true) ~= nil)

    -- and the file it just wrote must load back as the same state
    local env2 = M.newEnv({ files = { [INI] = written } }):install()
    extend(env2)
    hudWorld(env2)
    env2:loadMod(MOD)
    runLoops(env2)
    local c = tintOf(env2, "WBP_ShieldHealthBar_C_0")
    s:check("reloaded state matches what was saved",
        c ~= nil and math.abs(c.R - 0.40 * 1.10) < 0.01 and math.abs(c.B - 1.00 * 1.10) < 0.01)
end)

suite:test("a missing settings file falls back to shipped defaults", function(s)
    local env = start(nil)
    s.env = env
    runLoops(env)
    s:check("still tints something", tintOf(env, "WBP_ShieldHealthBar_C_0") ~= nil)
    -- The shipped defaults now include the radar; the reticle is still the one
    -- element that stays out until asked for.
    s:check("radar tinted by default", tintOf(env, "WBP_MotionTracker_C_0") ~= nil)
    s:check("reticle still opt-in",
        tintOf(env, "WBP_WeaponAim_Scope_Shared_C_0") == nil)
end)

suite:test("a widget without the setter cannot take the mod down", function(s)
    local env = M.newEnv({ files = {} }):install()
    extend(env)
    env.tints = {}
    -- SetColorAndOpacity deliberately absent: an absent reflected function is
    -- nil in UE4SS, so calling it throws for the ordinary Lua reason.
    local class = M.object(
        "BlueprintGeneratedClass /Game/UI/Hud/ShieldHealthBar/WBP_ShieldHealthBar.WBP_ShieldHealthBar_C", {})
    env:register("UserWidget", M.object("WBP_ShieldHealthBar_C_0 /Game/Level.Level:WT.Bar", {
        GetClass = function() return class end,
    }))
    env:loadMod(MOD)
    s.env = env
    runLoops(env, 3)
    s:check("loop survived a widget that cannot be tinted",
        not env:logContains("enforce error"))
end)

return suite
