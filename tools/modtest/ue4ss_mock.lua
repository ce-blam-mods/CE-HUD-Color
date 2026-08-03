-- A synthetic UE4SS/Unreal environment, good enough to run a real mod's
-- main.lua with no game attached.
--
-- WHY THIS EXISTS
--   The mods are the part of this project that changes most often and is
--   hardest to test: the only other way to exercise one is to launch the game,
--   which costs minutes and (before tools/harness/) took the machine away from
--   whoever was at it. Worse, the failures that matter most -- "F4 no longer
--   gets me out of the free camera" -- are exactly the ones that are miserable
--   to reproduce by hand.
--
--   This runs the SHIPPED main.lua, unmodified, against a fake world. No game,
--   no renderer, no window, and a whole suite finishes in well under a second.
--
-- THE TWO UE4SS BEHAVIOURS THAT MUST BE REPRODUCED EXACTLY
--   Mods here are written around the difference between these, so a mock that
--   gets them wrong will pass code that crashes in the game:
--
--     1. Reading an ABSENT REFLECTED PROPERTY THROWS. It does not return nil.
--        This is why the mods are full of pcall-wrapped reads.
--     2. An absent reflected FUNCTION is simply nil, so calling it throws for
--        the ordinary Lua reason.
--
--   Both are modelled by `M.object` below. Give an object only the members the
--   shipping build actually reflects, and the mod under test will hit the same
--   walls it hits in the game.
--
--   The third is keybind dispatch: UE4SS compares a bind's required modifier
--   set against the modifiers actually held for EXACT equality
--   (Input/Handler.cpp), so F4 and CTRL+F4 are disjoint binds and only one of
--   them fires. `env.binds` is keyed by the full combination for that reason.
--
-- WHAT IS DELIBERATELY NOT MODELLED
--   Frame timing, the real reflection graph, actual rendering, and the Blam
--   simulation. This tier answers "is the mod's own logic right". Anything that
--   depends on the engine's real behaviour belongs in tools/harness/ against a
--   headless game.

local M = {}

-- The suite reporter's own output channel, captured at load time -- BEFORE any
-- env:install() replaces the global print with the mod-log collector.
--
-- Without this the reporter writes its own results into the fake game's log
-- instead of to the runner, so a green run prints almost nothing and a red one
-- prints its diagnosis into the very buffer it is about to dump. Found by
-- deliberately reintroducing the CEHarness priming bug and watching the suite
-- fail to say so.
local report = print

---------------------------------------------------------------------------
-- fake UObject
---------------------------------------------------------------------------

-- fields: the members the shipping build reflects. Anything absent behaves the
-- way the real thing does -- see the header.
function M.object(name, fields)
    local store = {}
    for key, value in pairs(fields or {}) do store[key] = value end
    store.__objname = name
    store.__dead = false

    return setmetatable({}, {
        __index = function(_, key)
            if key == "IsValid" then return function() return not store.__dead end end
            if key == "GetFullName" then return function() return store.__objname end end
            if key == "GetFName" then
                return function()
                    return { ToString = function() return store.__objname:match("^(%S+)") or store.__objname end }
                end
            end
            if key == "__store" then return store end
            local value = store[key]
            if value == nil then
                error("reflected member '" .. tostring(key) .. "' does not exist on "
                    .. store.__objname, 0)
            end
            return value
        end,
        __newindex = function(_, key, value)
            if store[key] == nil then
                error("cannot assign absent reflected property '" .. tostring(key)
                    .. "' on " .. store.__objname, 0)
            end
            store[key] = value
        end,
    })
end

-- Marks an object destroyed, so IsValid() goes false the way it does when the
-- engine tears something down mid-session.
function M.destroy(object)
    object.__store.__dead = true
end

---------------------------------------------------------------------------
-- environment
---------------------------------------------------------------------------

local Env = {}
Env.__index = Env

-- opts.env       extra os.getenv values
-- opts.files     virtual filesystem, { [path] = contents }
function M.newEnv(opts)
    opts = opts or {}
    local env = setmetatable({
        objects = {},      -- class name -> { instances }
        binds = {},        -- "CONTROL+F4" -> fn
        hooks = {},        -- "/Script/...:Fn" -> { fns }
        delayed = {},      -- pending ExecuteWithDelay
        log = {},          -- captured print lines
        files = {},        -- virtual filesystem
        statics = {},      -- StaticFindObject path -> object
        vars = { LOCALAPPDATA = "C:\\Users\\test\\AppData\\Local" },
        clock = 0.0,
        consoleCommands = {},
    }, Env)
    for key, value in pairs(opts.env or {}) do env.vars[key] = value end
    for path, contents in pairs(opts.files or {}) do env.files[path] = contents end
    return env
end

-- Makes `object` discoverable via FindAllOf(className).
function Env:register(className, object)
    self.objects[className] = self.objects[className] or {}
    table.insert(self.objects[className], object)
    return object
end

function Env:emit(line)
    for _, part in ipairs({ tostring(line):gsub("\n$", "") }) do
        self.log[#self.log + 1] = part
        break
    end
end

function Env:logContains(needle)
    for _, line in ipairs(self.log) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

function Env:logText()
    return table.concat(self.log, "\n")
end

---------------------------------------------------------------------------
-- virtual filesystem
---------------------------------------------------------------------------

-- Mods here write trace files and, in CEHarness's case, use files as their
-- whole transport. A real io.open would scatter junk across the machine and
-- make tests order-dependent, so io is virtualised instead.
function Env:_openFile(path, mode)
    mode = mode or "r"
    local files = self.files

    if mode:find("r") then
        local contents = files[path]
        if contents == nil then return nil, path .. ": No such file or directory" end
        local position = 1
        local handle = {}
        function handle:read(format)
            format = format or "l"
            if format == "a" or format == "*a" then
                local rest = contents:sub(position)
                position = #contents + 1
                return rest
            end
            if position > #contents then return nil end
            local newline = contents:find("\n", position, true)
            local line
            if newline then
                line = contents:sub(position, newline - 1)
                position = newline + 1
            else
                line = contents:sub(position)
                position = #contents + 1
            end
            return line
        end
        function handle:lines()
            return function() return handle:read("l") end
        end
        function handle:close() return true end
        return handle
    end

    if mode:find("w") then files[path] = "" end
    if files[path] == nil then files[path] = "" end
    local handle = {}
    function handle:write(...)
        for i = 1, select("#", ...) do
            files[path] = files[path] .. tostring((select(i, ...)))
        end
        return handle
    end
    function handle:close() return true end
    return handle
end

---------------------------------------------------------------------------
-- UE4SS globals
---------------------------------------------------------------------------

function Env:install()
    local env = self

    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        env:emit(table.concat(parts, "\t"))
    end

    _G.FindAllOf = function(className) return env.objects[className] end
    _G.StaticFindObject = function(path) return env.statics[path] end
    _G.FindObject = _G.StaticFindObject
    _G.LoadAsset = function() return nil end

    _G.ExecuteInGameThread = function(fn) fn() end
    _G.ExecuteWithDelay = function(ms, fn)
        env.delayed[#env.delayed + 1] = { ms = ms, fn = fn }
    end

    _G.RegisterKeyBind = function(key, modifiers, fn)
        if fn == nil then fn, modifiers = modifiers, nil end
        local name = key
        if modifiers ~= nil then
            local parts = {}
            for _, modifier in ipairs(modifiers) do parts[#parts + 1] = modifier end
            table.sort(parts)
            name = table.concat(parts, "+") .. "+" .. key
        end
        if env.binds[name] ~= nil then
            error("duplicate keybind registered: " .. name)
        end
        env.binds[name] = fn
    end

    _G.RegisterHook = function(path, fn)
        env.hooks[path] = env.hooks[path] or {}
        table.insert(env.hooks[path], fn)
    end
    _G.RegisterConsoleCommandHandler = function(name, fn)
        env.consoleCommands[name] = fn
    end
    _G.NotifyOnNewObject = function() end

    _G.Key = { PAGE_UP = "PAGE_UP", PAGE_DOWN = "PAGE_DOWN", HOME = "HOME",
               END = "END", DEL = "DEL", INS = "INS", ENTER = "ENTER" }
    for i = 1, 12 do _G.Key["F" .. i] = "F" .. i end
    for i = 0, 9 do _G.Key["NUM_" .. i] = "NUM_" .. i end
    _G.ModifierKey = { SHIFT = "SHIFT", CONTROL = "CONTROL", ALT = "ALT" }

    -- io/os are virtualised so tests never touch the real machine and never
    -- depend on wall-clock time.
    _G.io = setmetatable({
        open = function(path, mode) return env:_openFile(path, mode) end,
    }, { __index = io })
    _G.os = setmetatable({
        getenv = function(name) return env.vars[name] end,
        clock = function() return env.clock end,
        time = function() return 1780000000 end,
        date = function(format) return "2026-07-28 12:00:00" end,
        remove = function(path) env.files[path] = nil return true end,
        rename = function(from, to) env.files[to] = env.files[from]; env.files[from] = nil return true end,
    }, { __index = os })

    package.loaded.UEHelpers = self:makeUEHelpers()
    return self
end

-- Overridden wholesale by tests that need a different shape.
function Env:makeUEHelpers()
    local env = self
    return {
        GetWorld = function() return env.world end,
        GetEngine = function() return env.engine end,
        GetGameInstance = function() return env.gameInstance end,
        GetPlayerController = function() return env.playerController end,
        GetKismetSystemLibrary = function() return env.kismetSystemLibrary end,
    }
end

---------------------------------------------------------------------------
-- driving
---------------------------------------------------------------------------

-- Runs the real mod file. Anything it registers lands in this env.
function Env:loadMod(path)
    local chunk, err = loadfile(path)
    if chunk == nil then error("could not load " .. path .. ": " .. tostring(err), 0) end
    chunk()
    return self
end

-- ExecuteWithDelay callbacks can schedule more of themselves, so drain until
-- the queue is empty or the round budget runs out. A mod that reschedules
-- forever (CEHarness's pump does) is why there is a budget at all.
function Env:flush(rounds)
    for _ = 1, (rounds or 8) do
        local pending = self.delayed
        if #pending == 0 then return self end
        self.delayed = {}
        for _, entry in ipairs(pending) do entry.fn() end
    end
    return self
end

-- Advances the fake clock, then drains. For mods whose behaviour is timing
-- dependent without making tests actually wait.
function Env:tick(seconds, rounds)
    self.clock = self.clock + (seconds or 0)
    return self:flush(rounds)
end

function Env:press(bind)
    local fn = self.binds[bind]
    if fn == nil then error("no keybind registered for '" .. tostring(bind) .. "'", 0) end
    fn()
    return self
end

function Env:fireHook(path, ...)
    for _, fn in ipairs(self.hooks[path] or {}) do fn(...) end
    return self
end

---------------------------------------------------------------------------
-- test framework
---------------------------------------------------------------------------

local Suite = {}
Suite.__index = Suite

function M.suite(name)
    return setmetatable({ name = name, passed = 0, failed = 0, failures = {},
                          current = nil, env = nil }, Suite)
end

function Suite:report(line)
    report(line)
end

-- ALWAYS SNAPSHOT THE LOG BEFORE DUMPING IT. If the reporter is writing into
-- the same table it is walking, `ipairs` never reaches the end and the run
-- hangs forever instead of printing a failure. That is what happened the first
-- time a check here actually failed.
local function snapshot(lines)
    local copy = {}
    for index = 1, #lines do copy[index] = lines[index] end
    return copy
end

-- body receives the suite, so checks read `s:check(...)`.
function Suite:test(label, body)
    self.current = label
    self:report("  " .. label)
    local ok, err = pcall(body, self)
    if not ok then
        self.failed = self.failed + 1
        self.failures[#self.failures + 1] = label .. ": " .. tostring(err)
        self:report("    ERROR " .. tostring(err))
        if self.env then
            for _, line in ipairs(snapshot(self.env.log)) do self:report("          | " .. line) end
        end
    end
    self.current = nil
end

function Suite:check(label, condition)
    if condition then
        self.passed = self.passed + 1
        self:report("    PASS  " .. label)
    else
        self.failed = self.failed + 1
        self.failures[#self.failures + 1] = (self.current or "?") .. " / " .. label
        self:report("    FAIL  " .. label)
        if self.env then
            for _, line in ipairs(snapshot(self.env.log)) do self:report("          | " .. line) end
        end
    end
    return condition
end

function Suite:equals(label, actual, expected)
    return self:check(string.format("%s (got %s, want %s)", label,
        tostring(actual), tostring(expected)), actual == expected)
end

function Suite:finish()
    self:report("")
    if self.failed == 0 then
        self:report(string.format("%s: %d checks passed", self.name, self.passed))
    else
        self:report(string.format("%s: %d FAILED, %d passed", self.name, self.failed, self.passed))
        for _, failure in ipairs(self.failures) do self:report("  - " .. failure) end
    end
    return self.failed
end

return M
