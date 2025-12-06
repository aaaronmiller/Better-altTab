-- ======================================================================
--  HYBRID MRU SWITCHER (Pre-Velocity Baseline)
--  "The Windows Emulator"
--  Features:
--  - Linear Cycling (Cmd+` -> 1->2->3...)
--  - Toggle (Cmd+` Tap -> 1<->2)
--  - Ghost Mode (Zero Latency First Use)
--  - Background Caching
-- ======================================================================

local CONFIG = {
    cacheDelay = 0.5,
    logLevel = "info"
}

local state = {
    active = false,
    
    -- Global State
    globalWindows = {},
    globalFocusOrder = {},
    
    -- Session State
    sessionList = {},
    stateIndex = 1,
    
    -- UI
    ui = nil,
    uiTimer = nil,
    
    -- Watchers
    janitor = nil,
    shadowWatcher = nil,
    inputWatcher = nil,
    
    -- Flags
    isColdStart = true
}

local log = hs.logger.new('Baseline', CONFIG.logLevel)

-- ======================================================================
--  HELPER FUNCTIONS
-- ======================================================================
local function safeFocus(winObj)
    if not winObj then return end
    pcall(function() winObj:focus() end)
end

-- ======================================================================
--  CACHE MANAGEMENT
-- ======================================================================
local function rebuildFullCache()
    local start = hs.timer.secondsSinceEpoch()
    local raw = hs.window.orderedWindows()
    local newWindows = {}
    local newOrder = {}
    
    for _, w in ipairs(raw) do
        local id = w:id()
        if id and w:isVisible() then
            newWindows[id] = {
                obj = w,
                id = id,
                app = w:application(),
                cache = (state.globalWindows[id] and state.globalWindows[id].cache) or nil
            }
            table.insert(newOrder, id)
        end
    end
    state.globalWindows = newWindows
    state.globalFocusOrder = newOrder
    state.isColdStart = false
    
    local elapsed = hs.timer.secondsSinceEpoch() - start
    log.i(string.format("Cache Rebuilt: %d windows in %.3fs", #newOrder, elapsed))
end

local function initWatcher()
    state.shadowWatcher = hs.window.filter.new(false)
        :setDefaultFilter{}
        :setSortOrder(hs.window.filter.sortByFocusedLast)
    
    state.shadowWatcher:subscribe(hs.window.filter.windowFocused, function(w)
        if state.active then return end
        local id = w:id()
        if not id then return end
        
        if not state.globalWindows[id] then
            state.globalWindows[id] = { obj = w, id = id, app = w:application() }
        end
        
        -- Update MRU
        for i, storedId in ipairs(state.globalFocusOrder) do
            if storedId == id then table.remove(state.globalFocusOrder, i); break end
        end
        table.insert(state.globalFocusOrder, 1, id)
    end)
    
    -- Note: We do NOT call rebuildFullCache() here to avoid startup lag.
    -- It will be called after the first interaction.
end

-- ======================================================================
--  UI RENDERING
-- ======================================================================
local function drawPreview()
    if #state.sessionList == 0 then return end
    if state.stateIndex > #state.sessionList then state.stateIndex = 1 end
    
    local targetId = state.sessionList[state.stateIndex]
    local winStruct = state.globalWindows[targetId]
    
    if not winStruct then return end
    
    local scr = winStruct.obj:screen() or hs.screen.mainScreen()
    local f = scr:fullFrame()
    
    if not state.ui then state.ui = hs.canvas.new(f) else state.ui:frame(f) end
    
    local elements = {}
    
    -- Background
    table.insert(elements, {
        type = "rectangle", action = "fill",
        fillColor = { white = 0, alpha = 0.55 },
        frame = { x = 0, y = 0, w = f.w, h = f.h }
    })
    
    -- Image
    local img = winStruct.cache
    if not img then
        local ok, snap = pcall(function() return winStruct.obj:snapshot() end)
        if ok and snap then img = snap end
    end
    
    if img then
        local iw, ih = img:size().w, img:size().h
        local scale = math.min(f.w / iw, f.h / ih) * 0.90
        local dw, dh = iw * scale, ih * scale
        local dx, dy = (f.w - dw) / 2, (f.h - dh) / 2
        
        table.insert(elements, {
            type = "image", image = img, imageScaling = "scaleToFit",
            frame = { x = dx, y = dy, w = dw, h = dh }
        })
    else
        -- Text Fallback
        table.insert(elements, {
            type = "text", text = "NO PREVIEW", textSize = 60,
            textColor = { white = 0.3 }, textAlignment = "center",
            frame = { x = 0, y = f.h/2 - 50, w = f.w, h = 100 }
        })
    end
    
    -- Title
    local appName = (winStruct.app and winStruct.app:name()) or "?"
    local title = winStruct.obj:title() or ""
    
    table.insert(elements, {
        type = "text", text = appName .. "  –  " .. title,
        textSize = 24, textColor = { white = 1 }, textAlignment = "center",
        frame = { x = 0, y = f.h - 60, w = f.w, h = 50 }
    })
    
    state.ui:replaceElements(elements)
    state.ui:show()
end

-- ======================================================================
--  CORE LOGIC
-- ======================================================================
local function performSwitch()
    if #state.sessionList == 0 then return end
    if state.stateIndex > #state.sessionList then state.stateIndex = 1 end
    
    local targetId = state.sessionList[state.stateIndex]
    local winStruct = state.globalWindows[targetId]
    
    if winStruct and winStruct.obj then
        pcall(function()
            winStruct.obj:focus()
            -- Lazy Cache Update
            hs.timer.doAfter(CONFIG.cacheDelay, function()
                if winStruct.obj then winStruct.cache = winStruct.obj:snapshot() end
            end)
        end)
    end
    
    -- If this was the first run, now we build the full cache
    if state.isColdStart then
        hs.timer.doAfter(0.5, rebuildFullCache)
    else
        hs.timer.doAfter(1.0, rebuildFullCache)
    end
end

local function stopSession()
    state.active = false
    if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
    if state.janitor then state.janitor:stop(); state.janitor = nil end
    if state.ui then state.ui:delete(); state.ui = nil end
    
    performSwitch()
end

local function activate()
    state.active = true
    
    -- GHOST MODE (First Use)
    if state.isColdStart then
        log.i("Ghost Mode Activation")
        local raw = hs.window.orderedWindows()
        state.sessionList = {}
        state.globalWindows = {} -- Reset
        
        for _, w in ipairs(raw) do
            local id = w:id()
            if id and w:isVisible() then
                state.globalWindows[id] = { obj = w, id = id, app = w:application() }
                table.insert(state.sessionList, id)
            end
        end
    else
        -- PRO MODE (Cached)
        state.sessionList = {}
        -- Filter for current space (Basic visibility check)
        for _, id in ipairs(state.globalFocusOrder) do
            local w = state.globalWindows[id]
            if w and w.obj:isVisible() then -- Simple visibility check for baseline
                table.insert(state.sessionList, id)
            end
        end
    end
    
    -- Initial Index: Always 2 (Previous)
    state.stateIndex = (#state.sessionList >= 2) and 2 or 1
    
    -- Janitor
    state.janitor = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
        if state.active and not e:getFlags().cmd then
            stopSession()
            return true
        end
    end):start()
    
    -- UI Timer (Delayed)
    state.uiTimer = hs.timer.doAfter(0.2, function()
        if state.active then drawPreview() end
    end)
end

local function handleTick()
    if not state.active then
        activate()
        return
    end
    
    -- Linear Cycle
    state.stateIndex = state.stateIndex + 1
    if state.stateIndex > #state.sessionList then state.stateIndex = 1 end
    
    drawPreview()
end

-- ======================================================================
--  INPUT ROUTER
-- ======================================================================
hs.hotkey.bind({"cmd"}, "`", function()
    handleTick()
end)

hs.hotkey.bind({"cmd", "shift"}, "`", function()
    if not state.active then activate() return end
    state.stateIndex = state.stateIndex - 1
    if state.stateIndex < 1 then state.stateIndex = #state.sessionList end
    drawPreview()
end)

initWatcher()
hs.alert.show("Baseline Loaded")
