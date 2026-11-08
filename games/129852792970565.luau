-- Egg collector / instant retry / Celestial + zone 9 / preserved settings (1.6.1).
-- Based on the supplied .rbxl: Runtime.WorldEggs / DroppedEggs,
-- Rarity / EggId / CarriedBy attributes, and StealPrompt / PickUpPrompt.
-- Requires a client executor with game:HttpGet and loadstring.
-- No purchase/admin remotes are used. Pickup must be accepted by the server.
-- Normal teleport buttons require empty hands. Explicit experimental return
-- modes may teleport a held egg and can cause a server reset; they are not bypasses.
-- Direct stop-point tween with drop OFF is the default. No speed stats/physics flags are changed.

local PLACE_ID = 129852792970565
if game.PlaceId ~= PLACE_ID then
    warn("[Egg Teleport] This script is for place " .. tostring(PLACE_ID))
    return
end

local hubContext = ...
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Pin the UI API to the version inspected for this script.
local LIB_URL = "https://raw.githubusercontent.com/Cybersize/MattLib/81feb71431f2e8ce6aba74c9a8d179c9c74cbf7f/dist/MattLib.lua"
local downloaded, source = pcall(function()
    if type(hubContext) == "table" and type(hubContext.httpGet) == "function" then
        return hubContext.httpGet(LIB_URL)
    end
    return game:HttpGet(LIB_URL)
end)
assert(downloaded, "[Egg Teleport] MattLib download failed: " .. tostring(source))
local loader, compileError = loadstring(source, "MattLib")
assert(loader, compileError)
local MattLib = loader()

-- RARITY_POLICY_BEGIN
local RarityPolicy = {}
function RarityPolicy.build(config)
    if type(config) ~= "table" or type(config.List) ~= "table" then return nil end
    local rows, seen = {}, {}
    for _, item in ipairs(config.List) do
        if type(item) == "table" and type(item.Key) == "string" and item.Key ~= ""
            and item.Spawns == true and item.PaidOnly ~= true and not seen[item.Key] then
            seen[item.Key] = true
            rows[#rows+1] = {key=item.Key,label=type(item.DisplayName)=="string" and item.DisplayName or item.Key,
                rank=tonumber(item.SortOrder) or tonumber(item.Rank) or 0}
        end
    end
    if #rows == 0 then return nil end
    table.sort(rows,function(a,b) return a.rank < b.rank or a.rank == b.rank and a.key < b.key end)
    local keys, ranks, options = {}, {}, {}
    for _, row in ipairs(rows) do
        keys[#keys+1],ranks[row.key] = row.key,row.rank
        options[#options+1] = {value=row.key,label=row.label}
    end
    return keys,ranks,options
end
-- RARITY_POLICY_END

local RARITIES = {"Common", "Rare", "Epic", "Legendary", "Mythic", "Relic", "Exotic", "Ascendant", "Secret", "SuperSecret", "Divine", "Celestial"}
local RARITY_RANK = {}
local RARITY_OPTIONS = {}
for rank, name in ipairs(RARITIES) do
    RARITY_RANK[name] = rank
    RARITY_OPTIONS[#RARITY_OPTIONS+1] = {value=name,label=name=="SuperSecret" and "Super Secret" or name}
end
pcall(function()
    local config = require(ReplicatedStorage.Shared.Config.RarityConfig)
    local keys,ranks,options = RarityPolicy.build(config)
    if keys then RARITIES,RARITY_RANK,RARITY_OPTIONS = keys,ranks,options end
end)

-- An instance-backed cleanup handle also works across separate executor chunks.
local LIFETIME_NAME = "MattEggTeleport_Lifecycle"
local old = playerGui:FindFirstChild(LIFETIME_NAME)
if old and old:IsA("BindableFunction") and old:GetAttribute("MattEggOwned") then
    local ok, reason = pcall(function() old:Invoke() end)
    assert(ok, "[Egg Teleport] Previous copy could not stop: " .. tostring(reason))
end

local state = {
    alive = true, busy = false, auto = false, epoch = 0, carryLock = false,
    rarities = table.clone(RARITIES), priority = "Highest rarity first", returnMode = "stop", saved = nil,
    stopTravel = "tween", dropAtPoint = false,
    snapAfter = 1, snapDistance = 12,
    speedMode = "Match carry speed", customSpeed = 100,
    banks = 0, slips = 0, fault = nil,
    autoRecover = true, retryDelay = 0, resumeAt = 0,
    failures = 0, actionSerial = 0, recoveredAction = -1,
    streamOn = true, streamScope = "All zones", streamTimeout = 2,
    streamBusy = false, streamCursor = 1, streamVisited = {}, streamReady = false,
    nextStreamAt = 0, scanRequested = false, eggCache = {}, cacheTTL = 90,
    skipFastGuards = false, pointPaused = false,
}
local app, statusLabel, countLabel, activePrompt, activeTween, autoToggle, speedSlider, returnDelaySlider, returnDistanceSlider
local returnModeControl, speedModeControl, streamLabel, streamToggle, stopTravelControl, dropAtPointToggle
local cacheLoadedEggs, resolveEgg, zoneAllowed, streamStep
local connections = {}
local lifetime = Instance.new("BindableFunction")
lifetime.Name = LIFETIME_NAME
lifetime:SetAttribute("MattEggOwned", true)

local function endHold()
    if activePrompt then
        pcall(function() activePrompt:InputHoldEnd() end)
        activePrompt = nil
    end
end

local function cancelTween()
    local tween = activeTween
    activeTween = nil
    if tween then pcall(function() tween:Cancel(); tween:Destroy() end) end
end

local function cleanup()
    if not state.alive then return end
    state.alive, state.auto = false, false
    state.epoch = state.epoch + 1
    cancelTween()
    endHold()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    if app then app:Destroy() end
    lifetime:Destroy()
end
lifetime.OnInvoke = cleanup
connections[#connections+1] = lifetime.Destroying:Connect(cleanup)
lifetime.Parent = playerGui

app = MattLib.new({ id = "matt-egg-teleport", theme = "Dark", reducedMotion = true })

local lastStatusMessage
local function status(message)
    if state.alive and statusLabel and message ~= lastStatusMessage then
        lastStatusMessage = message
        statusLabel:Update({ Text = "Status: " .. message })
    end
end

local function characterParts()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if root and humanoid and humanoid.Health > 0 then
        return character, root, humanoid
    end
end

local function carrying()
    local id = player:GetAttribute("CarryingEgg")
    return type(id) == "string" and id ~= ""
end

-- RETURN_POLICY_BEGIN
local ReturnPolicy = {}
function ReturnPolicy.canTeleport(id, locked)
    return not locked and not (type(id) == "string" and id ~= "")
end
function ReturnPolicy.speed(requested, walkSpeed, capped)
    if type(walkSpeed) ~= "number" or walkSpeed <= 0 then return nil end
    if capped then return walkSpeed * 0.9 end
    return math.clamp(tonumber(requested) or 100, 10, 250)
end
function ReturnPolicy.result(expected, currentId, banks, bankBaseline, slips, slipBaseline, rejects, rejectBaseline)
    if slips > slipBaseline or rejects > rejectBaseline then return "rejected" end
    if banks > bankBaseline and (currentId == nil or currentId == "") then return "banked" end
    if currentId == expected then return "carrying" end
    return "unconfirmed"
end
function ReturnPolicy.shouldSnap(mode, elapsed, remaining, bankConfirmed, delay, distance)
    if mode == "banked" then return bankConfirmed end
    if mode == "timed" then return elapsed >= delay end
    if mode == "near" then return remaining <= distance end
    return mode == "instant"
end
function ReturnPolicy.allowSnap(mode, expectedId, currentId, bankConfirmed)
    local hasEgg = type(currentId) == "string" and currentId ~= ""
    if hasEgg and currentId ~= expectedId then return false end
    if mode == "banked" then return bankConfirmed and not hasEgg end
    local experimental = mode == "timed" or mode == "near" or mode == "instant"
    return experimental and (currentId == expectedId or bankConfirmed and not hasEgg)
end
-- RETURN_POLICY_END

-- SUPPORT_POLICY_BEGIN
local SupportPolicy = {}
function SupportPolicy.retryDelay(base, _failures)
    -- No escalating backoff. Zero means ready as soon as the action clears.
    return math.clamp(tonumber(base) or 0, 0, 30)
end
function SupportPolicy.recoverable(kind)
    return kind == "reset" or kind == "guard" or kind == "respawn" or kind == "unconfirmed" or kind == "blocked" or kind == "timeout"
end
function SupportPolicy.offsets(zones, gap)
    local out, cursor = {}, 0
    for _, zone in ipairs(zones) do
        out[#out+1] = {index=zone.Index, zone=zone, start=cursor,
            center=cursor+zone.LengthStuds*0.5, nest=cursor+(zone.NestOffsetStuds or zone.LengthStuds*0.5)}
        cursor = cursor + zone.LengthStuds + gap
    end
    return out
end
-- SUPPORT_POLICY_END

local function failureStatus()
    if state.auto and state.resumeAt > os.clock() then
        status(string.format("Auto ON; retry in %.0fs. %s", state.resumeAt-os.clock(), state.fault or "Recovering."))
    elseif state.auto and state.fault then status("Auto ON; retry ready. " .. state.fault)
    elseif state.fault then status(state.fault) end
end

local function pauseAuto(message, kind)
    state.fault = message
    state.epoch = state.epoch + 1
    cancelTween()
    endHold()
    if state.auto and state.autoRecover and SupportPolicy.recoverable(kind) then
        if state.recoveredAction ~= state.actionSerial then
            state.recoveredAction = state.actionSerial
            state.failures = state.failures + 1
            state.resumeAt = os.clock() + SupportPolicy.retryDelay(state.retryDelay, state.failures)
        end
        -- Recovery never rewrites user-selected movement, speed, drop or rarity
        -- settings. GuardCatch / RejectCount / Notify can overlap in any order.
        failureStatus()
    else
        state.auto = false
        if autoToggle then autoToggle:SetValue(false) end
        status(message .. " Auto OFF.")
    end
end

local function pickupPrompt(egg)
    for _, name in ipairs({ "StealPrompt", "PickUpPrompt" }) do
        local prompt = egg:FindFirstChild(name, true)
        if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled
            and prompt.MaxActivationDistance > 0
            and prompt:GetAttribute("PromptBlocked") ~= true then
            return prompt
        end
    end
end

local function promptPosition(prompt, egg)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    if parent and parent:IsA("BasePart") then return parent.Position end
    if egg:IsA("Model") then return egg:GetPivot().Position end
    if egg:IsA("BasePart") then return egg.Position end
end

local function available(egg)
    local holder = egg:GetAttribute("CarriedBy")
    return egg:IsDescendantOf(workspace)
        and (holder == nil or holder == 0)
        and table.find(state.rarities, egg:GetAttribute("Rarity")) ~= nil
end

local function findEgg()
    if cacheLoadedEggs then cacheLoadedEggs() end
    local _, root = characterParts()
    local runtime = workspace:FindFirstChild("Runtime")
    local best, bestPrompt, bestDistance, bestRank, count = nil, nil, math.huge, -1, 0
    if not runtime then return nil, nil, 0 end
    for _, name in ipairs({ "WorldEggs", "DroppedEggs" }) do
        local folder = runtime:FindFirstChild(name)
        if folder then
            for _, egg in ipairs(folder:GetChildren()) do
                if available(egg) and (not zoneAllowed or zoneAllowed(egg:GetAttribute("ZoneIndex"))) then
                    local prompt = pickupPrompt(egg)
                    local position = prompt and promptPosition(prompt, egg)
                    if position then
                        count = count + 1
                        local distance = root and (root.Position - position).Magnitude or math.huge
                        local rank = RARITY_RANK[egg:GetAttribute("Rarity")] or 0
                        local better = state.priority == "Highest rarity first"
                            and (rank > bestRank or rank == bestRank and distance < bestDistance)
                            or state.priority ~= "Highest rarity first" and distance < bestDistance
                        if better then
                            best, bestPrompt, bestDistance = egg, prompt, distance
                            bestRank = rank
                        end
                    end
                end
            end
        end
    end
    return best, bestPrompt, count
end

local function refreshCount()
    local _, _, count = findEgg()
    if state.alive and countLabel then
        local cached = 0
        for _ in pairs(state.eggCache) do cached = cached+1 end
        countLabel:Update({ Text = "Loaded eligible eggs: " .. tostring(count) .. " | Cached region hints: " .. cached })
    end
end

local function moveRoot(root, destination)
    if not ReturnPolicy.canTeleport(player:GetAttribute("CarryingEgg"), state.carryLock) then
        return false, "This teleport button requires empty hands. Use the selected return mode instead."
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = destination
    return true
end

local function bankDestination()
    -- Fixed endpoint requested by the user; shared by automatic/manual returns.
    return Vector3.new(-208.12997436523438, 4.237678050994873, 399.94561767578125)
end

local function stopDestination()
    return Vector3.new(-184.1337127685547, 4.237677097320557, 397.77520751953125)
end

local function stopPointMode(mode)
    return mode == "stop" or mode == "stop_hold" or mode == "stop_drop"
end

local function refreshReturnControls()
    local movement = stopPointMode(state.returnMode) and (state.stopTravel or "tween") or state.returnMode
    if returnDelaySlider then returnDelaySlider:Update({Disabled = movement ~= "timed"}) end
    if returnDistanceSlider then returnDistanceSlider:Update({Disabled = movement ~= "near"}) end
    if dropAtPointToggle then dropAtPointToggle:Update({Disabled = not stopPointMode(state.returnMode)}) end
end

local function dropAtStop(id, root, current)
    local banks, slips = state.banks, state.slips
    local rejects = tonumber(player:GetAttribute("RejectCount")) or 0
    local function valid()
        return current() and (root.Position-stopDestination()).Magnitude < 0.75
            and state.banks == banks and state.slips == slips
            and (tonumber(player:GetAttribute("RejectCount")) or 0) <= rejects
    end
    local untilTime = os.clock()+8
    while valid() and player:GetAttribute("CarryingEgg") == id and player:GetAttribute("Chased") == true do
        status("Stopped at point; waiting for chase to end before the normal drop request.")
        if os.clock() >= untilTime then return false,"Still chased; egg kept. No drop request sent.","stopped" end
        task.wait(0.1)
    end
    if not valid() or player:GetAttribute("CarryingEgg") ~= id then
        return false,"Stop-point drop cancelled: position/carry state changed.","stopped"
    end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local remote = remotes and remotes:FindFirstChild("RequestDropEgg")
    if not remote or not remote:IsA("RemoteEvent") then return false,"Native drop remote is unavailable; egg kept.","stopped" end
    local ok, reason = pcall(function() remote:FireServer() end) -- Native action: no arguments, one request only.
    if not ok then return false,"Drop request failed: "..tostring(reason),"stopped" end
    untilTime = os.clock()+3
    repeat
        if not valid() then return false,"Drop not confirmed: action/position changed. No repeat request.","stopped" end
        local runtime = workspace:FindFirstChild("Runtime")
        local dropped = runtime and runtime:FindFirstChild("DroppedEggs")
        if not carrying() and dropped then
            for _, egg in ipairs(dropped:GetChildren()) do
                local holder = egg:GetAttribute("CarriedBy")
                if (egg:GetAttribute("EggId") or egg.Name) == id and (holder == nil or holder == 0) then
                    local prompt = pickupPrompt(egg)
                    local position = prompt and promptPosition(prompt,egg)
                    if position and (position-stopDestination()).Magnitude < 8 then
                        return true,"Stopped at point; dropped egg confirmed nearby (not banked).","stopped"
                    end
                end
            end
        end
        task.wait(0.1)
    until os.clock() >= untilTime
    return false,"Drop request sent once, but a nearby dropped egg was not confirmed. Auto waits here.","stopped"
end

-- Streaming requests are hints, not a way to disable Roblox's streaming budget.
local zoneConfig
pcall(function() zoneConfig = require(ReplicatedStorage.Shared.Config.ZoneConfig) end)
local zoneDefinitions = zoneConfig and zoneConfig.Zones or {
    {Index=1,LengthStuds=55,NestOffsetStuds=40,RequiredSpeed=10,GuardSpeed=14},
    {Index=2,LengthStuds=130,NestOffsetStuds=90,RequiredSpeed=900,GuardSpeed=28.5},
    {Index=3,LengthStuds=300,NestOffsetStuds=210,RequiredSpeed=10000,GuardSpeed=54},
    {Index=4,LengthStuds=520,NestOffsetStuds=365,RequiredSpeed=170000,GuardSpeed=78},
    {Index=5,LengthStuds=730,NestOffsetStuds=510,RequiredSpeed=2500000,GuardSpeed=110.5},
    {Index=6,LengthStuds=870,NestOffsetStuds=610,RequiredSpeed=18000000,GuardSpeed=136},
    {Index=7,LengthStuds=676,NestOffsetStuds=470,RequiredSpeed=150000000,GuardSpeed=163},
    {Index=8,LengthStuds=900,NestOffsetStuds=630,RequiredSpeed=1000000000,GuardSpeed=180},
    {Index=9,LengthStuds=900,NestOffsetStuds=630,RequiredSpeed=5000000000,GuardSpeed=200},
}
local zoneByIndex = {}
for _, zone in ipairs(zoneDefinitions) do zoneByIndex[zone.Index] = zone end

local function streamPoints()
    local offsets = SupportPolicy.offsets(zoneDefinitions, 6)
    local axis, origin = Vector3.new(1,0,0), Vector3.new(-190,bankDestination().Y,400)
    -- Prefer a currently replicated zone strip as the map anchor. The fallback
    -- origin/gap comes from the inspected place, not a teleport destination.
    for _, strip in ipairs(CollectionService:GetTagged("ZoneStrip")) do
        local index = strip:GetAttribute("ZoneIndex")
        if strip:IsA("BasePart") and offsets[index] then
            axis = strip.CFrame.RightVector
            if (strip.Position-bankDestination()):Dot(axis) < 0 then axis = -axis end
            origin = strip.Position-axis*offsets[index].center
            break
        end
    end
    local points = {}
    local speed = tonumber(player:GetAttribute("Speed")) or 0
    for _, item in ipairs(offsets) do
        if state.streamScope == "All zones" or speed >= (item.zone.RequiredSpeed or 0) or item.index == 1 then
            local p = origin+axis*item.nest
            points[#points+1] = {index=item.index,position=Vector3.new(p.X,bankDestination().Y,p.Z)}
        end
    end
    return points
end

zoneAllowed = function(index)
    if not state.skipFastGuards then return true end
    local zone = zoneByIndex[index]
    local _, _, humanoid = characterParts()
    if not zone or not humanoid then return true end
    local speed = humanoid.WalkSpeed * (carrying() and 1 or 0.9)
    local configured = ReturnPolicy.speed(state.customSpeed,speed,state.speedMode == "Match carry speed") or 0
    return configured >= (zone.GuardSpeed or 0)
end

cacheLoadedEggs = function()
    local runtime = workspace:FindFirstChild("Runtime")
    if not runtime then return end
    local now = os.clock()
    for id, entry in pairs(state.eggCache) do
        if now-entry.seen > state.cacheTTL then state.eggCache[id] = nil end
    end
    for _, name in ipairs({"WorldEggs","DroppedEggs"}) do
        local folder = runtime:FindFirstChild(name)
        if folder then for _, egg in ipairs(folder:GetChildren()) do
            local id = egg:GetAttribute("EggId") or egg.Name
            local holder = egg:GetAttribute("CarriedBy")
            if holder ~= nil and holder ~= 0 then state.eggCache[id] = nil
            else
                local prompt = pickupPrompt(egg)
                local p = prompt and promptPosition(prompt,egg)
                if p then state.eggCache[id] = {id=id,position=p,rarity=egg:GetAttribute("Rarity"),
                    zone=egg:GetAttribute("ZoneIndex"),seen=now} end
            end
        end end
    end
end

local function requestRegion(position, current)
    local untilTime = os.clock()+state.streamTimeout+1
    while state.streamBusy and current() and os.clock()<untilTime do task.wait(0.05) end
    if state.streamBusy or not current() then return false end
    local enabled = true
    pcall(function() enabled = workspace.StreamingEnabled end)
    if enabled == false then cacheLoadedEggs(); return true end
    state.streamBusy = true
    local ok, reason = pcall(function() player:RequestStreamAroundAsync(position,state.streamTimeout) end)
    state.streamBusy = false
    if state.alive then cacheLoadedEggs() end
    if state.alive then state.streamError = not ok and tostring(reason) or nil end
    return ok and current()
end

streamStep = function()
    if not state.alive or state.busy or carrying() or state.streamBusy then return end
    local points = streamPoints()
    if #points == 0 then state.streamReady = true; return end
    if state.streamCursor > #points then state.streamCursor = 1 end
    local slot = state.streamCursor
    local point = points[slot]
    if streamLabel then streamLabel:Update({Text="Requesting zone "..point.index.." ("..slot.."/"..#points.."). Distant regions may stream out again."}) end
    requestRegion(point.position,function() return state.alive and not state.busy and not carrying() end)
    if not state.alive then return end
    state.streamVisited[slot] = true
    state.streamCursor = slot+1
    if slot == #points then
        state.streamReady, state.scanRequested = true, false
        if streamLabel then streamLabel:Update({Text=state.streamError and ("Streaming request failed: "..state.streamError)
            or "Zone scan complete. Cached hints are revalidated before pickup."}) end
    end
    state.nextStreamAt = os.clock()+2
end

resolveEgg = function(current)
    if not state.streamOn then return findEgg() end
    cacheLoadedEggs()
    local _, root = characterParts()
    local best, bestRank, bestDistance = nil, -1, math.huge
    for _, entry in pairs(state.eggCache) do
        if table.find(state.rarities,entry.rarity) and zoneAllowed(entry.zone) and os.clock()-entry.seen <= state.cacheTTL then
            local rank = RARITY_RANK[entry.rarity] or 0
            local distance = root and (root.Position-entry.position).Magnitude or math.huge
            local better = state.priority == "Highest rarity first" and (rank>bestRank or rank==bestRank and distance<bestDistance)
                or state.priority ~= "Highest rarity first" and distance<bestDistance
            if better then best,bestRank,bestDistance = entry,rank,distance end
        end
    end
    if not best then return findEgg() end
    requestRegion(best.position,current)
    if not current() then return nil end
    -- A cached coordinate is only a streaming hint, never a blind teleport.
    local deadline = os.clock()+1
    repeat
        local runtime = workspace:FindFirstChild("Runtime")
        if runtime then for _, name in ipairs({"WorldEggs","DroppedEggs"}) do
            local folder = runtime:FindFirstChild(name)
            if folder then for _, egg in ipairs(folder:GetChildren()) do
                if (egg:GetAttribute("EggId") or egg.Name) == best.id and available(egg) and zoneAllowed(egg:GetAttribute("ZoneIndex")) then
                    local prompt = pickupPrompt(egg)
                    if prompt and promptPosition(prompt,egg) then return egg,prompt end
                end
            end end
        end end
        if not current() then return nil end
        task.wait(0.1)
    until os.clock()>=deadline
    state.eggCache[best.id] = nil
    return findEgg()
end

local function teleportReturn(id, root, current, mode, bankConfirmed, destination)
    if not current() then return false, "Return cancelled." end
    if not ReturnPolicy.allowSnap(mode, id, player:GetAttribute("CarryingEgg"), bankConfirmed) then
        return false, "Teleport not authorized by this return mode/carry state."
    end
    cancelTween()
    local rotation = root.CFrame - root.Position
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = CFrame.new(destination or bankDestination()) * rotation
    return true
end

local function tweenToBank(id, root, humanoid, current)
    local mode = state.returnMode or "tween"
    if mode == "manual" then return false, "Manual return selected; choose another mode to use this button." end
    local stopping = stopPointMode(mode)
    local movement = stopping and (state.stopTravel or "tween") or mode
    -- Capture both controls for this action; changes apply to the next return.
    local dropRequested = mode == "stop_drop" or mode ~= "stop_hold" and state.dropAtPoint == true
    local goal = stopping and stopDestination() or bankDestination()
    -- Every mode heads straight to its chosen finish point. No edge waypoints.
    local bankBaseline, slipBaseline = state.banks, state.slips
    local rejectBaseline = tonumber(player:GetAttribute("RejectCount")) or 0
    local started = os.clock()
    local snapAfter, snapDistance = state.snapAfter or 1, state.snapDistance or 12
    local deadline, clearedAt, bankConfirmed = started + 180, nil, false
    local snapped, snappedAt = false, nil
    while current() and os.clock() < deadline do
        local currentId = player:GetAttribute("CarryingEgg")
        local result = ReturnPolicy.result(id, currentId, state.banks, bankBaseline, state.slips,
            slipBaseline, tonumber(player:GetAttribute("RejectCount")) or 0, rejectBaseline)
        if result == "banked" then bankConfirmed = true end
        if result == "rejected" then
            cancelTween()
            return false, "Server rejected the return; change return mode/speed or return manually.", "reset"
        end
        local remaining = (goal - root.Position).Magnitude
        if stopping and result ~= "carrying" then
            cancelTween(); return false,"Stop-point return ended: the expected egg is no longer held.","unconfirmed"
        end
        if stopping and remaining < 0.15 then
            cancelTween()
            -- Let server corrections/carry changes arrive before a post-teleport drop.
            if snapped and os.clock()-snappedAt < 0.5 then task.wait(0.05); continue end
            root.AssemblyLinearVelocity,root.AssemblyAngularVelocity = Vector3.zero,Vector3.zero
            if dropRequested then return dropAtStop(id,root,current) end
            return true,"Stopped at point; still holding the egg. No drop or bank requested.","stopped"
        end
        if bankConfirmed and remaining < 0.15 then
            cancelTween(); return true, "Bank confirmed; fixed return destination reached."
        end
        if snapped then
            -- Never repeatedly snap or tween after an unconfirmed teleport.
            if os.clock() - snappedAt > 3 then
                return false, "Teleport return was not confirmed at the destination.", "unconfirmed"
            end
            task.wait(0.05)
        elseif not bankConfirmed and (result == "unconfirmed" or state.banks > bankBaseline) then
            cancelTween()
            clearedAt = clearedAt or os.clock()
            if os.clock() - clearedAt > 3 then
                return false, "Carry state changed without a complete bank confirmation.", "unconfirmed"
            end
            task.wait(0.05)
        elseif ReturnPolicy.shouldSnap(movement, os.clock() - started, remaining, bankConfirmed, snapAfter, snapDistance) then
            local ok, message = teleportReturn(id, root, current, movement, bankConfirmed, goal)
            if not ok then return false, message end
            snapped, snappedAt = true, os.clock()
            status(stopping and "Teleported once to stop point; verifying position and held egg before hold/drop."
                or "Return teleported once; waiting for bank acknowledgement and destination confirmation.")
            task.wait(0.05)
        elseif remaining < 0.15 then
            cancelTween()
            local untilTime = os.clock() + 3
            repeat
                if not current() then return false, "Return cancelled." end
                if state.banks > bankBaseline and not carrying() then
                    return true, "Bank confirmed; fixed return destination reached."
                end
                if state.slips > slipBaseline then return false, "Egg slipped back.", "reset" end
                task.wait(0.05)
            until os.clock() >= untilTime
            return false, "Reached the destination, but the server did not confirm a bank.", "unconfirmed"
        else
            clearedAt = nil
            local speed = ReturnPolicy.speed(state.customSpeed, humanoid.WalkSpeed, state.speedMode == "Match carry speed")
            if not speed then return false, "Carry speed is zero; tween stopped.", "blocked" end
            local origin = root.Position
            local waypoint = goal
            local legDistance = (waypoint-origin).Magnitude
            local nextPoint = origin:Lerp(waypoint, math.min(1, 24 / math.max(legDistance,0.01)))
            local direction = Vector3.new(waypoint.X - nextPoint.X, 0, waypoint.Z - nextPoint.Z)
            if direction.Magnitude < 0.01 then direction = Vector3.new(-1, 0, 0) end
            local duration = (nextPoint - origin).Magnitude / speed
            local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear),
                {CFrame = CFrame.lookAt(nextPoint, nextPoint + direction)})
            activeTween = tween
            status(string.format("Return mode %s: tween %.1f studs/s", mode, speed))
            tween:Play()
            local expires, switchToSnap = os.clock() + duration + 1, false
            while current() and os.clock() < expires and tween.PlaybackState ~= Enum.PlaybackState.Completed do
                local bankCleared = state.banks > bankBaseline and not carrying()
                if (not bankCleared and (player:GetAttribute("CarryingEgg") ~= id or state.banks > bankBaseline))
                    or state.slips > slipBaseline
                    or (tonumber(player:GetAttribute("RejectCount")) or 0) > rejectBaseline then break end
                if ReturnPolicy.shouldSnap(movement, os.clock() - started, (goal - root.Position).Magnitude,
                    bankCleared, snapAfter, snapDistance) then
                    switchToSnap = true
                    break
                end
                task.wait(0.05)
            end
            cancelTween()
            if not current() then return false, "Return cancelled." end
            if not switchToSnap and (bankConfirmed or player:GetAttribute("CarryingEgg") == id)
                and state.slips == slipBaseline
                and (tonumber(player:GetAttribute("RejectCount")) or 0) <= rejectBaseline
                and (root.Position - nextPoint).Magnitude > 6 then
                return false, "Tween was blocked or corrected; no automatic snap retry was attempted.", "blocked"
            end
        end
    end
    cancelTween()
    return false, current() and "Return timed out." or "Return cancelled.", current() and "timeout" or "cancelled"
end

local function runAction(collect)
    if not state.alive or state.busy then return end
    if carrying() or state.carryLock then
        status("Holding an egg: use Return current egg with your selected destination/mode.")
        return
    end
    local character, root, humanoid = characterParts()
    if not root then status("Waiting for a living character."); return end
    if collect and state.returnMode ~= "manual" and not stopPointMode(state.returnMode) and not state.bankSensor then
        status("Bank feedback remote is not ready. Retry after the game loads."); return
    end
    state.busy = true
    state.actionSerial = state.actionSerial + 1
    state.fault = nil
    state.saved = root.CFrame
    local epoch = state.epoch
    local function current()
        return state.alive and state.epoch == epoch and player.Character == character
            and root.Parent == character and humanoid.Health > 0
            and player:GetAttribute("Ragdolled") ~= true
    end
    task.spawn(function()
        local ok, reason = xpcall(function()
            local egg, prompt
            if resolveEgg then egg,prompt = resolveEgg(current) else egg,prompt = findEgg() end
            if not egg then status("No eligible egg is loaded yet; scanning/guard filters may be active."); return end
            if not current() or not available(egg) or not prompt.Parent then return end
            local position = promptPosition(prompt, egg)
            if not position then return end
            humanoid.Sit = false
            -- Stay within the actual prompt range; do not change its properties.
            local distance = math.min(3, prompt.MaxActivationDistance * 0.4)
            local destination = position + Vector3.new(0, distance * 0.5, distance)
            local moved, message = moveRoot(root, CFrame.lookAt(destination, position))
            if not moved then status(message); return end
            local rarity = tostring(egg:GetAttribute("Rarity") or "Unknown")
            status("Teleported to " .. rarity .. " egg.")
            if not collect then return end

            task.wait(1) -- Wait empty-handed before asking the server to pick up.
            if not current() or carrying() or not available(egg) then return end
            if not prompt.Parent or not prompt.Enabled then return end
            local livePosition = promptPosition(prompt, egg)
            if not livePosition or (root.Position - livePosition).Magnitude > prompt.MaxActivationDistance then
                status("Teleport did not stick, or the egg moved. Try again.")
                return
            end

            local id = egg:GetAttribute("EggId") or egg.Name
            status("Picking up " .. rarity .. " egg...")
            if type(fireproximityprompt) == "function" then
                fireproximityprompt(prompt)
            else
                activePrompt = prompt
                prompt:InputHoldBegin()
                local holdUntil = os.clock() + prompt.HoldDuration + 0.15
                while current() and prompt.Parent and os.clock() < holdUntil do task.wait(0.05) end
                endHold()
            end

            local deadline, received = os.clock() + 3, false
            repeat
                if not current() then return end
                received = player:GetAttribute("CarryingEgg") == id
                if received then break end
                task.wait(0.05)
            until os.clock() >= deadline
            if not received then status("Pickup not confirmed by server; check eligibility or try again."); return end
            state.carryLock = true
            status("Picked up " .. rarity .. " egg. Return mode: " .. state.returnMode .. ".")
            if state.returnMode ~= "manual" and current() then
                local completed, result, kind = tweenToBank(id, root, humanoid, current)
                if kind == "stopped" then
                    state.pointPaused,state.fault = true,nil
                    status(result .. " Auto waits; change mode or Resume auto to continue.")
                elseif completed then
                    state.failures,state.resumeAt,state.fault = 0,0,nil
                    status(result)
                elseif current() then pauseAuto(state.fault or result,kind) end
            end
        end, debug.traceback)
        endHold()
        cancelTween()
        state.carryLock = carrying()
        state.busy = false
        if not ok then
            warn("[Egg Teleport] " .. tostring(reason))
            pauseAuto("Action failed; see executor console.","runtime")
        elseif state.fault then
            failureStatus()
        end
    end)
end

local function tweenHeldEgg()
    if not state.alive or state.busy then return end
    if state.returnMode == "manual" then status("Manual return selected. Choose another return mode first."); return end
    local id = player:GetAttribute("CarryingEgg")
    local character, root, humanoid = characterParts()
    if not carrying() or not root then status("No held egg / living character."); return end
    if not stopPointMode(state.returnMode) and not state.bankSensor then status("Bank feedback remote is not ready."); return end
    state.pointPaused = false
    state.busy, state.carryLock, state.fault = true, true, nil
    state.actionSerial = state.actionSerial + 1
    local epoch = state.epoch
    local function current()
        return state.alive and state.epoch == epoch and player.Character == character
            and root.Parent == character and humanoid.Health > 0
            and player:GetAttribute("Ragdolled") ~= true
    end
    task.spawn(function()
        local ok, completed, message, kind = pcall(tweenToBank, id, root, humanoid, current)
        cancelTween()
        state.busy, state.carryLock = false, carrying()
        if not ok then pauseAuto("Tween error: " .. tostring(completed),"runtime")
        elseif current() then
            if kind == "stopped" then
                state.pointPaused,state.fault = true,nil
                status(message .. " Auto waits; change mode or Resume auto to continue.")
            elseif completed then
                state.failures,state.resumeAt,state.fault = 0,0,nil
                status(message)
            else pauseAuto(state.fault or message,kind) end
        elseif state.fault then failureStatus() end
    end)
end

local window = app:CreateWindow({
    Id = "eggs", Title = "Egg Collector · Instant Retry · v1.6.1", Design = "MintGlass",
    Size = { 720, 650 }, OpenKey = "RightShift", Wallpaper = false,
    OnClose = cleanup,
})
local tab = window:AddTab({ Title = "Eggs" })
local section = tab:AddSection({ Title = "Select eggs & collect" })

stopTravelControl = section:AddDropdown({
    Id = "stopTravel", Title = "Movement to stop point", Default = "tween",
    Options = {
        {value="tween", label="Tween directly (default)"},
        {value="instant", label="Teleport instantly (may reset egg)"},
        {value="timed", label="Tween then teleport (may reset egg)"},
        {value="near", label="Tween near point then teleport (may reset egg)"},
    },
    Callback = function(value)
        state.stopTravel = value
        state.pointPaused = false
        refreshReturnControls()
        status("Stop-point movement for the next return: "..value..". Stop an active action before switching it.")
    end,
})
dropAtPointToggle = section:AddToggle({Id="dropAtPoint", Title="Drop egg at stop point", Default=false,
    Callback=function(value)
        state.dropAtPoint = value
        status(value and "Drop ON for the next stop-point return. Native chase/drop checks still apply."
            or "Drop OFF for the next stop-point return: keep holding the egg.")
    end})

returnModeControl = section:AddDropdown({
    Id = "returnMode", Title = "Destination / bank mode", Default = "stop",
    Options = {
        {value = "stop", label = "Saved stop point — use movement + drop controls"},
        {value = "tween", label = "Bank: tween only"},
        {value = "banked", label = "Bank: tween until bank confirmed, then teleport"},
        {value = "timed", label = "Bank: timed tween → teleport (may reset)"},
        {value = "near", label = "Bank: tween near target → teleport (may reset)"},
        {value = "instant", label = "Bank: instant return (may reset)"},
        {value = "manual", label = "Manual / no automatic return"},
    },
    Callback = function(value)
        state.returnMode = value
        state.pointPaused = false
        refreshReturnControls()
        status("Return mode for the next return: " .. value .. ". Stop + Return current egg to switch an active action.")
    end,
})
local raritySelect = section:AddMultiSelect({
    Id = "rarities", Title = "Rarities (multi-select)", Default = table.clone(RARITIES),
    Options = RARITY_OPTIONS,
    Callback = function(values)
        state.rarities = table.clone(values)
        refreshCount()
        status(tostring(#values) .. " rarities selected. Highest rarity first by default.")
    end,
})
section:AddDropdown({Id = "priority", Title = "Priority", Default = "Highest rarity first",
    Options = {"Highest rarity first", "Nearest selected"}, Callback = function(value) state.priority = value end})
countLabel = section:AddText({ Text = "Available matching eggs: 0" })
statusLabel = section:AddParagraph({ Text = "Status: Ready." })
section:AddButton({ Title = "Teleport to best selected egg (empty hands)", Callback = function() runAction(false) end })
section:AddButton({ Title = "Get egg + selected return", Variant = "primary", Callback = function() runAction(true) end })
autoToggle = section:AddToggle({
    Id = "auto", Title = "Auto collect selected rarities", Default = false,
    Callback = function(value)
        state.auto = value
        state.epoch = state.epoch + 1
        if value then
            state.fault,state.resumeAt,state.failures,state.recoveredAction,state.pointPaused = nil,0,0,-1,false
            if state.streamOn then state.streamReady,state.streamCursor,state.streamVisited = false,1,{} end
        else state.resumeAt = 0; cancelTween(); endHold() end
        status(value and ("Auto enabled; priority: " .. state.priority .. ".") or "Auto stopped; active return cancelled.")
    end,
})
section:AddParagraph({Text = "First choose stop-point movement, then Drop ON/OFF. Saved stop point is (-184.134, 4.238, 397.775); Drop OFF keeps the egg, ON requests one native drop there. No left/right detour. Bank modes are separate and ignore the drop toggle. Auto waits after reaching the stop point. RightShift toggles this menu."})
section:AddButton({Title = "Unload", Callback = cleanup})

local returnSettings = window:AddTab({Title = "Return options"}):AddSection({Title = "Hybrid timing & distance"})
returnDelaySlider = returnSettings:AddSlider({Id = "snapAfter", Title = "Timed mode: tween seconds before teleport",
    Min = 0.25, Max = 10, Step = 0.25, Default = 1, Disabled = true,
    Callback = function(value) state.snapAfter = value end})
returnDistanceSlider = returnSettings:AddSlider({Id = "snapDistance", Title = "Near-target mode: teleport within studs",
    Min = 1, Max = 200, Step = 1, Default = 12, Disabled = true,
    Callback = function(value) state.snapDistance = value end})
refreshReturnControls()
returnSettings:AddParagraph({Text = "Timed mode tweens for the chosen delay, then teleports once. Near-target mode tweens until close enough, then teleports once. Both can teleport a held egg and trigger resets. Bank-confirmed mode never teleports until your own bank event and cleared carry state are observed. Mode/timing changes apply to the next return."})
returnSettings:AddButton({Title = "Return current egg to selected destination", Callback = tweenHeldEgg})
returnSettings:AddParagraph({Text = "Stop point: X=-184.1337127685547, Y=4.237677097320557, Z=397.77520751953125. Movement and Drop are separate controls on Eggs. Tween travels directly without a guard-edge detour. Teleport/hybrids can reset a held egg. Drop ON waits up to 8s for Chased to clear, sends one normal RequestDropEgg, and checks for the dropped egg nearby; OFF keeps holding. Stop-point completion is not a bank. Controls are captured at action start; Stop + Return current egg applies changes to a held egg. Auto waits here until you change mode, Resume auto or toggle Auto off/on."})
returnSettings:AddButton({Title = "Stop current action", Callback = function()
    state.epoch = state.epoch + 1
    autoToggle:SetValue(false)
    cancelTween(); endHold()
    status("Action stopped. No further tween/teleport requests will run for this action.")
end})
returnSettings:AddParagraph({Text = "Bank target: X=-208.12997436523438, Y=4.237678050994873, Z=399.94561767578125. A teleport is not counted as a bank unless the server confirms it. No repeated teleport is attempted within a return; recovery waits before a separate pickup attempt."})

local settings = window:AddTab({Title = "Speed & selection"}):AddSection({Title = "Tween speed"})
speedModeControl = settings:AddDropdown({Id = "speedMode", Title = "Tween speed mode", Default = "Match carry speed",
    Options = {"Match carry speed", "Custom speed (may reset)"}, Callback = function(value)
        state.speedMode = value
        if speedSlider then speedSlider:Update({Disabled = value == "Match carry speed"}) end
    end})
speedSlider = settings:AddSlider({Id = "customSpeed", Title = "Custom tween speed (studs/sec)",
    Min = 10, Max = 250, Step = 5, Default = 100, Disabled = true,
    Callback = function(value) state.customSpeed = value end})
settings:AddParagraph({Text = "Match carry speed uses 90% of the current Humanoid.WalkSpeed. Custom mode can be faster, but the server may still reset the egg. No carry speed, collision, anchoring or network settings are changed. Recovery keeps Auto ON with a cooldown after a reset or unconfirmed bank."})
settings:AddButton({ Title = "Return previous position (empty hands only)", Callback = function()
    if state.busy then return end
    local _, root = characterParts()
    if root and state.saved then
        local ok, reason = moveRoot(root, state.saved)
        if not ok then status(reason) end
    end
end })
settings:AddButton({Title = "Select all rarities", Callback = function() raritySelect:SetValue(table.clone(RARITIES)) end})
settings:AddButton({Title = "Clear rarity selection", Callback = function() raritySelect:SetValue({}) end})

local streaming = window:AddTab({Title = "Streaming"}):AddSection({Title = "Progressive region loading"})
streamLabel = streaming:AddParagraph({Text = "Region requests do not guarantee the whole map stays rendered."})
streamToggle = streaming:AddToggle({Id = "streamOn", Title = "Request zones before auto collection", Default = true, Callback = function(value)
    state.streamOn = value
    state.streamReady,state.streamCursor,state.streamVisited = not value,1,{}
    if not value then state.scanRequested = false end
end})
streaming:AddDropdown({Id = "streamScope", Title = "Zones to scan", Default = "All zones", Options = {"All zones","Unlocked zones"},
    Callback = function(value) state.streamScope = value; state.streamReady,state.streamCursor,state.streamVisited = false,1,{} end})
streaming:AddSlider({Id = "streamTimeout", Title = "Region request timeout (seconds)", Min = 1, Max = 5, Step = 1, Default = 2,
    Callback = function(value) state.streamTimeout = value end})
streaming:AddButton({Title = "Scan zones now (no teleport)", Callback = function()
    if carrying() then status("Finish the held egg first; region scanning waits while carrying."); return end
    streamToggle:SetValue(true)
    state.streamOn,state.scanRequested,state.streamReady,state.streamCursor,state.streamVisited = true,true,false,1,{}
    status("Zone scan queued. No character movement is used to request regions.")
end})
streaming:AddParagraph({Text = "Uses Player:RequestStreamAroundAsync, scans one region at a time and caches egg hints. A cached egg is streamed/revalidated before teleporting to its real prompt. Roblox can stream distant regions out again; this cannot force a permanent all-map render."})

local recovery = window:AddTab({Title = "Recovery"}):AddSection({Title = "Reset handling & guard-speed filtering"})
recovery:AddToggle({Id = "autoRecover", Title = "Keep auto ON: retry after resets", Default = true,
    Callback = function(value) state.autoRecover = value end})
recovery:AddSlider({Id = "retryDelay", Title = "Retry delay (0 = instantly)", Min = 0, Max = 30, Step = 0.1, Default = 0,
    Callback = function(value)
        state.retryDelay = value
        state.resumeAt = math.min(state.resumeAt,os.clock()+value)
        if state.auto then failureStatus() end
    end})
recovery:AddToggle({Id = "skipFastGuards", Title = "Skip zones whose base guard speed exceeds return speed", Default = false,
    Callback = function(value) state.skipFastGuards = value end})
recovery:AddButton({Title = "Resume auto now", Callback = function()
    state.resumeAt,state.failures,state.fault,state.pointPaused = 0,0,nil,false
    autoToggle:SetValue(true)
    status("Auto ON; waiting for a living, empty-handed character and any initial zone scan.")
end})
recovery:AddParagraph({Text = "Default retry delay is 0s: no increasing backoff or 60-second timer. Auto checks every 0.05s and starts the next attempt once the old action ends, the character is alive/not ragdolled and no egg is held. An optional fixed delay can be selected above. Recovery preserves your settings. Runtime errors or disabling recovery still stop Auto. Returns go straight to the finish point; filtering does not cancel boss hits or grant invulnerability."})

local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local effects = remotes and remotes:WaitForChild("PlayEffect", 10)
if effects and effects:IsA("RemoteEvent") then
    state.bankSensor = true
    connections[#connections+1] = effects.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" or payload.userId ~= player.UserId then return end
        if payload.key == "EggBanked" then state.banks = state.banks + 1
        elseif payload.key == "GuardCatch" and state.busy then
            state.slips = state.slips + 1
            pauseAuto("Guard caught you; active return cancelled.","guard")
        end
    end)
end
local notifications = remotes and remotes:FindFirstChild("Notify")
if notifications and notifications:IsA("RemoteEvent") then
    connections[#connections+1] = notifications.OnClientEvent:Connect(function(payload)
        local text = type(payload) == "table" and payload.text
        if type(text) == "string" and text:lower():find("slipped back", 1, true) then
            state.slips = state.slips + 1
            if state.busy or state.auto then pauseAuto("Egg slipped back; lower return speed or change return mode.","reset") end
        end
    end)
end
local lastReject = tonumber(player:GetAttribute("RejectCount")) or 0
connections[#connections+1] = player:GetAttributeChangedSignal("RejectCount"):Connect(function()
    local value = tonumber(player:GetAttribute("RejectCount")) or 0
    if value > lastReject and state.busy then pauseAuto("Server rejection counter increased; return was not confirmed.","reset") end
    lastReject = value
end)
connections[#connections+1] = player:GetAttributeChangedSignal("CarryingEgg"):Connect(function()
    if not state.busy and not carrying() then state.carryLock = false end
end)
connections[#connections+1] = player.CharacterAdded:Connect(function()
    state.epoch = state.epoch + 1
    cancelTween(); endHold()
    pauseAuto("Respawned; waiting for character recovery.","respawn")
end)

refreshCount()
task.spawn(function()
    local nextCountRefresh = 0
    while state.alive do
        if not state.busy then
            state.carryLock = carrying()
            if os.clock() >= nextCountRefresh then
                refreshCount()
                nextCountRefresh = os.clock()+1
            end
            if state.auto then
                if state.pointPaused then status("Auto ON; stopped at point. Change return mode or Resume auto to continue.")
                elseif state.resumeAt > os.clock() then failureStatus()
                elseif player:GetAttribute("Ragdolled") == true then status("Auto ON; waiting for ragdoll recovery.")
                elseif carrying() then status("Auto ON; waiting for held egg to clear. Use Return current egg if needed.")
                elseif state.streamOn and not state.streamReady then status("Auto ON; initial zone streaming scan in progress.")
                else runAction(true) end
            end
        end
        task.wait(state.auto and 0.05 or 0.5)
    end
end)

task.spawn(function()
    while state.alive do
        local enabled = true
        pcall(function() enabled = workspace.StreamingEnabled end)
        if enabled == false then
            state.streamReady,state.scanRequested = true,false
        elseif state.streamOn and (state.auto or state.scanRequested) and state.resumeAt <= os.clock()
            and not state.busy and not carrying() and not state.streamBusy and os.clock() >= state.nextStreamAt then
            local ok, reason = pcall(streamStep)
            if not ok then
                state.streamError,state.streamReady = tostring(reason),true
                state.nextStreamAt = os.clock()+5
                if streamLabel then streamLabel:Update({Text="Region scan unavailable: "..tostring(reason)}) end
            end
        end
        task.wait(0.25)
    end
end)
