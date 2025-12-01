-- ======================================================================
--  v25.8.3  –  EVENTTAP EDITION: O(1) Latency, Lazy Cache, NoRepeat
--  Anchor Fix: Setting anchor stays on current window
-- ======================================================================
local SHOW_UI_DELAY = 0.20
local VEL_THRESHOLD = 0.30
local CACHE_REFRESH = 0.5
local DEV_MODE      = false
local state = {
    active = false, windows = {}, allWindows = {}, index = 1,
    memoryAnchor = nil, lastWindowBeforeAnchor = nil,
    space = nil, ui = nil, uiTimer = nil, janitor = nil,
    firstUse = true
}
local lastRelease = 0
local cacheReady  = false
local function log(msg) if DEV_MODE then print("[V25.7] " .. msg) end end

-- ---- boot pre-cache ---------------------------------------------------
local function eagerCache()
    if cacheReady then return end
    local wins   = hs.window.orderedWindows()
    local need   = 0
    for _, w in ipairs(wins) do if w and w:isVisible() then need = need + 1 end end
    if need == 0 then cacheReady = true; return end
    local done   = 0
    local timer  = nil
    timer = hs.timer.doEvery(0.15, function()
        for i = 1, 5 do
            if done >= need then
                timer:stop(); cacheReady = true
                hs.alert.show("✅ Cache warm – first switch instant", 1)
                return
            end
            local w = wins[done + 1]
            if w and w:isVisible() then
                pcall(function() w:snapshot() end); done = done + 1
            end
        end
        if done % 20 == 0 then
            hs.alert.show(string.format("⏳ warming %d/%d", done, need), 0.4)
        end
    end)
end
eagerCache()
-- ---- 30-browser restore watcher ---------------------------------------
local BROWSERS = {
    ["Google Chrome"] = true, ["Chrome"] = true,
    ["Chromium"] = true,
    ["Brave Browser"] = true, ["Brave"] = true,
    ["Microsoft Edge"] = true, ["Edge"] = true,
    ["Safari"] = true,
    ["Firefox"] = true, ["FirefoxDeveloperEdition"] = true, ["Firefox Nightly"] = true,
    ["Opera"] = true, ["Opera GX"] = true,
    ["Vivaldi"] = true,
    ["Arc"] = true,
    ["Orion"] = true,
    ["Tor Browser"] = true,
    ["SigmaOS"] = true,
    ["Wavebox"] = true,
    ["Sidekick"] = true,
    ["Coomet"] = true,
    ["GenSpark"] = true,
    ["CCleaner Browser"] = true,
    ["Avast Secure Browser"] = true,
    ["AVG Secure Browser"] = true,
    ["Norton Secure Browser"] = true,
    ["Sleipnir"] = true,
    ["Roccat"] = true,
    ["DuckDuckGo"] = true,
    ["LibreWolf"] = true,
    ["Waterfox"] = true,
    ["Floorp"] = true,
    ["Mullvad Browser"] = true,
    ["Yandex"] = true,
    ["Whale"] = true,
    ["Slimjet"] = true
}
local restoreWatcher = hs.application.watcher.new(function(appName, event, app)
    if event ~= hs.application.watcher.launched then return end
    if not BROWSERS[appName] then return end
    hs.timer.doAfter(2, function()
        local wins = app:allWindows()
        if #wins >= 5 then
            log(appName .. " restore – warming " .. #wins)
            for _, w in ipairs(wins) do
                if w and w:isVisible() then pcall(function() w:snapshot() end) end
            end
            updateAllWindows()
        end
    end)
end)
restoreWatcher:start()
-- ---- window lists -----------------------------------------------------
local function updateAllWindows()
    local raw = hs.window.orderedWindows()
    local clean = {}
    for _, w in ipairs(raw) do
        if w and w:isVisible() and w:screen() then
            clean[#clean + 1] = {
                obj = w, id = w:id(),
                app = w:application(),
                space = (hs.spaces.windowSpaces(w) or {})[1],
                cache = nil -- Lazy load in drawPreview
            }
        end
    end
    state.allWindows = clean; log("cached " .. #clean)
end
local function updateWorkspaceWindows(target)
    local t = {}
    for _, w in ipairs(state.allWindows) do
        if (not target) or (w.space == target) then t[#t + 1] = w end
    end
    state.windows = t
    if state.memoryAnchor then
        local found = false
        for _, w in ipairs(state.allWindows) do
            if w.id == state.memoryAnchor.id then found = true; break end
        end
        if not found then state.memoryAnchor = nil; state.lastWindowBeforeAnchor = nil end
    end
end
-- ---- switch -----------------------------------------------------------
local function performSwitch()
    local list = (state.index == 2 and state.active) and state.allWindows or state.windows
    local target = list[state.index]
    if target and target.obj then
        pcall(function()
            target.obj:focus()
            hs.timer.doAfter(CACHE_REFRESH, function() target.cache = target.obj:snapshot() end)
        end)
    end
end
-- ---- preview canvas (icon footer back, NIL-SAFE) ----------------------
local function drawPreview()
    if state.ui then state.ui:delete() end
    local win = state.windows[state.index]
    if not win then return end
    local scr = win.obj:screen() or hs.screen.mainScreen()
    local f = scr:fullFrame()
    state.ui = hs.canvas.new(f)
    state.ui:appendElements({ type = "rectangle", fillColor = {0, 0, 0, 0.55},
                              frame = {x = 0, y = 0, w = f.w, h = f.h} })
    -- Lazy cache: Only snapshot if missing
    if not win.cache then
        local ok, snap = pcall(function() return win.obj:snapshot() end)
        if ok then win.cache = snap end
    end
    local img = win.cache

    if img then
        local iw, ih = img:size().w, img:size().h
        local scale = math.min(f.w / iw, f.h / ih) * 0.88
        local dw, dh = iw * scale, ih * scale
        local dx, dy = (f.w - dw) / 2, (f.h - dh) / 2
        state.ui:appendElements({ type = "image", image = img, imageScaling = "scaleToFit",
                                  frame = {x = dx, y = dy, w = dw, h = dh} })
    end
    -- footer icon + space label (NIL-SAFE)
    local app = win.app
    if app then
        local icon = app:icon() and (function()
            local ok, ic = pcall(function() return app:icon({size = 64}) end)
            return ok and ic or nil
        end)()
        if icon then
            state.ui:appendElements({ type = "image", image = icon,
                                      frame = {x = f.w / 2 - 32, y = f.h - 90, w = 64, h = 64} })
        end
    end
    state.ui:appendElements({ type = "text", text = (app and app:name() or "?") .. "  –  Space #" .. (win.space or 1),
                              textSize = 18, textColor = {math.random(), math.random(), math.random()},
                              textAlignment = "center",
                              frame = {x = 0, y = f.h - 25, w = f.w, h = 25} })
    state.ui:show()
end
-- ---- session  (KILL OVERLAY BEFORE FOCUS) ----------------------------
local function stopSession()
    state.active = false
    -- 1. kill overlay BEFORE we focus = no thumbnail illusion
    if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
    if state.janitor then state.janitor:stop(); state.janitor = nil end
    local ui = state.ui; state.ui = nil; if ui then ui:delete() end
    -- 2. now switch window
    if state.firstUse then
        state.firstUse = false; performSwitch()
        hs.timer.doAfter(0.5, function() updateAllWindows() end)
        return
    end
    performSwitch()
end
local function activate()
    state.active = true; state.space = hs.spaces.focusedSpace()
    updateAllWindows(); updateWorkspaceWindows(state.space)
    state.index = (#state.allWindows >= 2) and 2 or 1
    state.janitor = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
        if state.active and not e:getFlags().cmd then stopSession(); return true end
    end):start()
    state.uiTimer = hs.timer.doAfter(SHOW_UI_DELAY, function() if state.active then drawPreview() end end)
end
-- ---- input router  (FAST = phantom, no UI) ----------------------------
local function handleTick(fast)
    -- phantom: fast tap = no canvas, instant bounce
    if fast and state.active then
        if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
        if state.ui then state.ui:delete(); state.ui = nil end
    end
    if not state.active then
        activate()                 -- first tap = velocity-agnostic bounce
        return
    end
    local mods = hs.eventtap.checkKeyboardModifiers()
    if mods.alt then
        local cur = state.allWindows[state.index]
        if not cur then return end
        if not state.memoryAnchor or cur.id ~= state.memoryAnchor.id then
            state.lastWindowBeforeAnchor = cur
            if state.memoryAnchor then
                for i, w in ipairs(state.allWindows) do if w.id == state.memoryAnchor.id then state.index = i; break end end
            else 
                state.memoryAnchor = cur
                hs.alert.show("Anchor Set") 
                state.index = 1 -- Stay on current window when setting anchor
            end
        else
            if state.lastWindowBeforeAnchor then
                for i, w in ipairs(state.allWindows) do if w.id == state.lastWindowBeforeAnchor.id then state.index = i; break end end
                state.memoryAnchor = state.lastWindowBeforeAnchor; state.lastWindowBeforeAnchor = nil
            end
        end
        if state.ui then drawPreview() end; return
    end
    if mods.shift and not mods.ctrl then
        state.index = state.index - 1; if state.index < 1 then state.index = #state.windows end
        if state.ui then drawPreview() end; return
    end
    if mods.ctrl then
        local curr = hs.spaces.focusedSpace()
        local all = hs.spaces.allSpaces()[hs.screen.mainScreen():getUUID()] or {}
        local idx = 0; for i, sp in ipairs(all) do if sp == curr then idx = i; break end end
        local nextIdx = mods.shift and ((idx - 2) % #all + 1) or ((idx % #all) + 1)
        hs.spaces.gotoSpace(all[nextIdx])
        hs.timer.doAfter(0.3, function()
            state.space = hs.spaces.focusedSpace(); state.index = 1
            updateWorkspaceWindows(state.space); if state.ui then drawPreview() end
        end)
        return
    end
    -- velocity branch
    if fast then state.index = 2
    else state.index = state.index + 1; if state.index > #state.windows then state.index = 1 end
    end
    if state.ui then drawPreview() end
end
-- ---- bindings ---------------------------------------------------------
local KEYCODE_BACKTICK = 50

local function setupEventtap()
    state.eventtap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
        if event:getKeyCode() == KEYCODE_BACKTICK and event:getFlags().cmd then
            -- Ignore auto-repeat to prevent "machine gun" cycling
            if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then
                return true -- Consume repeat, do nothing
            end

            -- Velocity logic (inlined from velAware)
            local now = hs.timer.secondsSinceEpoch()
            local fast = (now - lastRelease) < VEL_THRESHOLD
            lastRelease = now
            
            handleTick(fast)
            return true -- Consume the event
        end
        return false -- Propagate other events
    end)
    state.eventtap:start()
end

setupEventtap()
-- ---- finish -----------------------------------------------------------
hs.alert.show("Velocity-Vector v25.8.3 – Eventtap + Lazy Cache + NoRepeat + AnchorFix")