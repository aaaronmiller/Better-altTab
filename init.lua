-- ======================================================================
--  VELOCITY-VECTOR v25.9.3 PLATINUM (Enhanced)
--  "The Omniscient Gearshift"
--  CHANGELOG v25.9.3:
--  - Space Change Watcher (Auto-refresh on native space switch)
--  - Coroutine-Based Cache (Non-blocking rebuild)
--  - Thumbnail Pre-Caching (Next 5 windows)
--  - Reverse Browse (Cmd+Shift+`)
--  - Escape to Cancel
--  - App Icon Overlay
-- ======================================================================
local CONFIG = {
    velocityThreshold = 0.30,  -- Seconds: Fast vs Slow tap threshold
    livePreview = false,
    cacheDelay = 0.5,
    preCacheCount = 5,         -- NEW: How many windows to pre-cache thumbnails
    cacheBatchSize = 10,       -- NEW: Windows per batch during async rebuild
    logLevel = "info"
}
local state = {
    active = false,
    isColdStart = true,
    isCaching = false,         -- NEW: Lock for async cache
    originalWindowId = nil,    -- NEW: For Escape revert
    
    -- Global State
    globalWindows = {},
    globalFocusOrder = {},
    
    -- Session State
    sessionList = {},
    stateIndex = 1,
    
    -- Velocity
    lastTapTime = 0,
    isFirstTap = true,
    
    -- Anchors
    memoryAnchor = nil,
    lastWindowBeforeAnchor = nil,
    
    -- UI
    ui = nil,
    uiTimer = nil,
    
    -- Watchers
    janitor = nil,
    shadowWatcher = nil,
    spaceWatcher = nil,        -- NEW: Space change watcher
    inputWatcher = nil,
    keyTrap = nil              -- Renamed from arrowTrap (now handles arrows + escape + shift)
}
local log = hs.logger.new('Titanium', CONFIG.logLevel)
-- ======================================================================
--  HELPER FUNCTIONS
-- ======================================================================
local function safeFocus(winObj)
    if not winObj then return end
    pcall(function() winObj:focus() end)
end
-- ======================================================================
--  COROUTINE-BASED CACHE (Non-Blocking)
-- ======================================================================
local function rebuildCacheAsync()
    if state.isCaching then return end
    state.isCaching = true
    
    local start = hs.timer.secondsSinceEpoch()
    local raw = hs.window.orderedWindows()
    local idx = 1
    local newWindows = {}
    local newOrder = {}
    
    local function processBatch()
        local batch = CONFIG.cacheBatchSize
        for i = idx, math.min(idx + batch - 1, #raw) do
            local w = raw[i]
            local id = w:id()
            if id and w:isVisible() then
                newWindows[id] = {
                    obj = w,
                    id = id,
                    app = w:application(),
                    spaces = hs.spaces.windowSpaces(w) or {},
                    cache = (state.globalWindows[id] and state.globalWindows[id].cache) or nil
                }
                table.insert(newOrder, id)
            end
        end
        idx = idx + batch
        
        if idx <= #raw then
            -- More batches needed
            hs.timer.doAfter(0.01, processBatch)
        else
            -- Done
            state.globalWindows = newWindows
            state.globalFocusOrder = newOrder
            state.isColdStart = false
            state.isCaching = false
            local elapsed = hs.timer.secondsSinceEpoch() - start
            log.i(string.format("Async Cache Complete: %d windows in %.3fs", #newOrder, elapsed))
        end
    end
    
    processBatch()
end

-- Synchronous version for Ghost Mode (first use)
local function rebuildCacheSync()
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
                spaces = hs.spaces.windowSpaces(w) or {},
                cache = (state.globalWindows[id] and state.globalWindows[id].cache) or nil
            }
            table.insert(newOrder, id)
        end
    end
    state.globalWindows = newWindows
    state.globalFocusOrder = newOrder
    state.isColdStart = false
    
    local elapsed = hs.timer.secondsSinceEpoch() - start
    log.i(string.format("Sync Cache: %d windows in %.3fs", #newOrder, elapsed))
end

-- ======================================================================
--  THUMBNAIL PRE-CACHING
-- ======================================================================
local function preCacheNextWindows()
    for i = 1, CONFIG.preCacheCount do
        local id = state.sessionList[i]
        if id and state.globalWindows[id] then
            local ws = state.globalWindows[id]
            if not ws.cache and ws.obj then
                local ok, snap = pcall(function() return ws.obj:snapshot() end)
                if ok and snap then
                    ws.cache = snap
                end
            end
        end
    end
    log.d("Pre-cached " .. CONFIG.preCacheCount .. " thumbnails")
end

-- ======================================================================
--  PASSIVE SHADOW WATCHER (Global)
-- ======================================================================
local function initWatcher()
    state.shadowWatcher = hs.window.filter.new(false)
        :setDefaultFilter{}
        :setSortOrder(hs.window.filter.sortByFocusedLast)
    
    state.shadowWatcher:subscribe(hs.window.filter.windowFocused, function(w)
        if state.active then return end
        local id = w:id()
        if not id then return end
        
        if not state.globalWindows[id] then
            state.globalWindows[id] = { obj = w, id = id, app = w:application(), spaces = hs.spaces.windowSpaces(w) or {} }
        end
        
        for i, storedId in ipairs(state.globalFocusOrder) do
            if storedId == id then table.remove(state.globalFocusOrder, i); break end
        end
        table.insert(state.globalFocusOrder, 1, id)
    end)
    
    state.shadowWatcher:subscribe(hs.window.filter.windowCreated, function(w)
        local id = w:id()
        if not id then return end
        state.globalWindows[id] = { obj = w, id = id, app = w:application(), spaces = hs.spaces.windowSpaces(w) or {} }
        table.insert(state.globalFocusOrder, 1, id)
    end)
    
    state.shadowWatcher:subscribe(hs.window.filter.windowDestroyed, function(w)
        local id = w:id()
        if not id then return end
        state.globalWindows[id] = nil
        for i, storedId in ipairs(state.globalFocusOrder) do
            if storedId == id then table.remove(state.globalFocusOrder, i); break end
        end
    end)
end

-- ======================================================================
--  SPACE CHANGE WATCHER (NEW)
-- ======================================================================
local function initSpaceWatcher()
    state.spaceWatcher = hs.spaces.watcher.new(function()
        if state.active then return end -- Don't interrupt active session
        log.d("Space changed, triggering async cache rebuild")
        rebuildCacheAsync()
    end):start()
end

-- ======================================================================
--  UI RENDERING (with App Icon Overlay)
-- ======================================================================
local function drawPreview()
    if #state.sessionList == 0 then return end
    
    if state.stateIndex > #state.sessionList then state.stateIndex = 1 end
    if state.stateIndex < 1 then state.stateIndex = #state.sessionList end
    
    local targetId = state.sessionList[state.stateIndex]
    local winStruct = state.globalWindows[targetId]
    
    if not winStruct then
        log.w("UI: Missing window struct for ID " .. tostring(targetId))
        return
    end
    
    if CONFIG.livePreview then
        safeFocus(winStruct.obj)
        return
    end
    
    local scr = winStruct.obj:screen() or hs.screen.mainScreen()
    local f = scr:fullFrame()
    
    if not state.ui then
        state.ui = hs.canvas.new(f)
    else
        state.ui:frame(f)
    end
    
    local elements = {}
    
    -- Background overlay
    table.insert(elements, {
        type = "rectangle",
        action = "fill",
        fillColor = { white = 0, alpha = 0.55 },
        frame = { x = 0, y = 0, w = f.w, h = f.h }
    })
    
    -- Window snapshot
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
            type = "image",
            image = img,
            imageScaling = "scaleToFit",
            frame = { x = dx, y = dy, w = dw, h = dh }
        })
    else
        -- Fallback: Large centered icon
        local icon = winStruct.app and winStruct.app:bundleID() and hs.image.imageFromAppBundle(winStruct.app:bundleID())
        if icon then
            table.insert(elements, {
                type = "image",
                image = icon,
                imageScaling = "scaleToFit",
                frame = { x = f.w/2 - 64, y = f.h/2 - 64, w = 128, h = 128 }
            })
        else
            table.insert(elements, {
                type = "text",
                text = "NO PREVIEW",
                textSize = 60,
                textColor = { white = 0.3 },
                textAlignment = "center",
                frame = { x = 0, y = f.h/2 - 50, w = f.w, h = 100 }
            })
        end
    end
    
    -- APP ICON OVERLAY (NEW) - Top Left Corner
    local icon = winStruct.app and winStruct.app:bundleID() and hs.image.imageFromAppBundle(winStruct.app:bundleID())
    if icon and img then -- Only show overlay if we have a snapshot
        table.insert(elements, {
            type = "image",
            image = icon,
            imageScaling = "scaleToFit",
            frame = { x = 30, y = 30, w = 64, h = 64 }
        })
    end
    
    -- Title bar
    local appName = (winStruct.app and winStruct.app:name()) or "?"
    local title = winStruct.obj:title() or ""
    
    table.insert(elements, {
        type = "text",
        text = appName .. "  –  " .. title,
        textSize = 24,
        textColor = { white = 1 },
        textAlignment = "center",
        frame = { x = 0, y = f.h - 60, w = f.w, h = 50 }
    })
    
    -- Index indicator (e.g., "2 / 5")
    table.insert(elements, {
        type = "text",
        text = state.stateIndex .. " / " .. #state.sessionList,
        textSize = 18,
        textColor = { white = 0.6 },
        textAlignment = "right",
        frame = { x = f.w - 100, y = 30, w = 70, h = 30 }
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
            hs.timer.doAfter(CONFIG.cacheDelay, function()
                if winStruct.obj then
                    winStruct.cache = winStruct.obj:snapshot()
                end
            end)
        end)
    end
    
    -- Background Cache + Pre-Cache
    hs.timer.doAfter(1.0, function()
        rebuildCacheAsync()
        preCacheNextWindows()
    end)
end

local function cancelSession()
    state.active = false
    if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
    if state.janitor then state.janitor:stop(); state.janitor = nil end
    if state.keyTrap then state.keyTrap:stop(); state.keyTrap = nil end
    if state.ui then state.ui:delete(); state.ui = nil end
    
    -- Revert to original window (Escape behavior)
    if state.originalWindowId then
        local ws = state.globalWindows[state.originalWindowId]
        if ws and ws.obj then
            safeFocus(ws.obj)
        end
    end
    log.i("Session cancelled")
end

local function stopSession()
    state.active = false
    if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
    if state.janitor then state.janitor:stop(); state.janitor = nil end
    if state.keyTrap then state.keyTrap:stop(); state.keyTrap = nil end
    if state.ui then state.ui:delete(); state.ui = nil end
    
    performSwitch()
end

local function activate()
    state.active = true
    
    -- Store original window for Escape revert
    local current = hs.window.focusedWindow()
    state.originalWindowId = current and current:id()
    
    -- GHOST MODE (First Use)
    if state.isColdStart then
        log.i("👻 Ghost Mode Activation")
        local raw = hs.window.orderedWindows()
        state.sessionList = {}
        state.globalWindows = {}
        
        for _, w in ipairs(raw) do
            local id = w:id()
            if id and w:isVisible() then
                state.globalWindows[id] = { obj = w, id = id, app = w:application(), spaces = hs.spaces.windowSpaces(w) or {} }
                table.insert(state.sessionList, id)
            end
        end
        state.isColdStart = false
    else
        -- PRO MODE (Cached)
        local currentSpace = hs.spaces.focusedSpace()
        state.sessionList = {}
        
        for _, id in ipairs(state.globalFocusOrder) do
            local w = state.globalWindows[id]
            if w then
                local onSpace = false
                for _, s in ipairs(w.spaces or {}) do
                    if s == currentSpace then onSpace = true; break end
                end
                if onSpace then
                    table.insert(state.sessionList, id)
                end
            end
        end
        
        if #state.sessionList == 0 then
            log.w("Session list empty, forcing sync rebuild")
            rebuildCacheSync()
        end
    end
    
    state.stateIndex = (#state.sessionList >= 2) and 2 or 1
    state.lastTapTime = hs.timer.secondsSinceEpoch()
    state.isFirstTap = true
    
    -- JANITOR (Cmd release)
    state.janitor = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
        if state.active and not e:getFlags().cmd then
            stopSession()
            return true
        end
    end):start()
    
    -- KEY TRAP (Arrows + Escape + Shift handling)
    state.keyTrap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        local code = e:getKeyCode()
        local flags = e:getFlags()
        
        -- ESCAPE: Cancel and revert
        if code == 53 then
            cancelSession()
            return true
        end
        
        -- LEFT ARROW: Previous space
        if code == 123 then
            local all = hs.spaces.allSpaces()[hs.screen.mainScreen():uuid()]
            local curr = hs.spaces.focusedSpace()
            local prev = nil
            for i, s in ipairs(all) do
                if s == curr then prev = all[i-1] or all[#all]; break end
            end
            if prev then hs.spaces.gotoSpace(prev) end
            return true
        end
        
        -- RIGHT ARROW: Next space
        if code == 124 then
            local all = hs.spaces.allSpaces()[hs.screen.mainScreen():uuid()]
            local curr = hs.spaces.focusedSpace()
            local next = nil
            for i, s in ipairs(all) do
                if s == curr then next = all[i+1] or all[1]; break end
            end
            if next then hs.spaces.gotoSpace(next) end
            return true
        end
        
        return false
    end):start()
    
    -- UI Timer
    state.uiTimer = hs.timer.doAfter(0.2, function()
        if state.active then drawPreview() end
    end)
end

local function handleTick(fast, reverse)
    if not state.active then
        activate()
        return
    end
    
    if #state.sessionList < 2 then
        state.stateIndex = 1
        if state.ui then drawPreview() end
        return
    end
    
    if state.isFirstTap then
        state.stateIndex = 2
        state.isFirstTap = false
    else
        if reverse then
            -- REVERSE BROWSE (NEW)
            state.stateIndex = state.stateIndex - 1
            if state.stateIndex < 1 then state.stateIndex = #state.sessionList end
        else
            state.stateIndex = state.stateIndex + 1
            if state.stateIndex > #state.sessionList then state.stateIndex = 1 end
        end
    end
    
    if fast then
        if state.ui then state.ui:delete(); state.ui = nil end
        if state.uiTimer then state.uiTimer:stop(); state.uiTimer = nil end
    else
        drawPreview()
    end
end

-- ======================================================================
--  INPUT ROUTER
-- ======================================================================
state.inputWatcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local keyCode = e:getKeyCode()
    local flags = e:getFlags()
    
    -- Cmd + ` (Forward)
    if keyCode == 50 and flags.cmd and not flags.alt and not flags.ctrl and not flags.shift then
        local now = hs.timer.secondsSinceEpoch()
        local fast = false
        
        if state.active then
            fast = (now - state.lastTapTime) < CONFIG.velocityThreshold
        end
        
        state.lastTapTime = now
        handleTick(fast, false)
        return true
    end
    
    -- Cmd + Shift + ` (REVERSE BROWSE - NEW)
    if keyCode == 50 and flags.cmd and flags.shift and not flags.alt and not flags.ctrl then
        local now = hs.timer.secondsSinceEpoch()
        local fast = false
        
        if state.active then
            fast = (now - state.lastTapTime) < CONFIG.velocityThreshold
        end
        
        state.lastTapTime = now
        handleTick(fast, true) -- reverse = true
        return true
    end
    
    -- Cmd + Opt + ` (Memory Anchor)
    if keyCode == 50 and flags.cmd and flags.alt then
        if not state.memoryAnchor then
            local win = hs.window.focusedWindow()
            if win then
                state.memoryAnchor = { id = win:id(), obj = win }
                hs.alert.show("⚓ Anchor Set: " .. win:application():name())
            end
        else
            local focused = hs.window.focusedWindow()
            local focusedId = focused and focused:id()
            
            if focusedId == state.memoryAnchor.id then
                if state.lastWindowBeforeAnchor and state.lastWindowBeforeAnchor:isVisible() then
                    safeFocus(state.lastWindowBeforeAnchor)
                else
                    if #state.sessionList >= 2 then
                        local targetId = state.sessionList[2]
                        local target = state.globalWindows[targetId]
                        safeFocus(target and target.obj)
                    end
                end
            else
                if state.memoryAnchor.obj and state.memoryAnchor.obj:isVisible() then
                    state.lastWindowBeforeAnchor = focused
                    safeFocus(state.memoryAnchor.obj)
                else
                    hs.alert.show("⚓ Anchor Lost")
                    state.memoryAnchor = nil
                end
            end
        end
        return true
    end
    
    -- Cmd + Ctrl + ` (Workspace Cycle)
    if keyCode == 50 and flags.cmd and flags.ctrl then
        local spaces = hs.spaces.allSpaces()[hs.screen.mainScreen():uuid()]
        local current = hs.spaces.focusedSpace()
        local nextSpace = nil
        
        for i, s in ipairs(spaces) do
            if s == current then
                nextSpace = spaces[i+1] or spaces[1]
                break
            end
        end
        
        if nextSpace then
            hs.spaces.gotoSpace(nextSpace)
        end
        return true
    end
    
    return false
end):start()

-- ======================================================================
--  INITIALIZATION
-- ======================================================================
initWatcher()
initSpaceWatcher()
hs.alert.show("v25.9.3 Platinum (Enhanced)")