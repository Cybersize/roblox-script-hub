-- Egg helper / Main / Egg / Shop / Settings / optional owned-item tasks (1.9.1).
-- Based on the supplied .rbxl: Runtime.WorldEggs / DroppedEggs,
-- Rarity / EggId / CarriedBy attributes, and StealPrompt / PickUpPrompt.
-- Requires a client executor with game:HttpGet and loadstring.
-- Cash purchases require explicit Shop toggles; no premium/admin requests.
-- Pickup and cash requests must be accepted by the server.
-- Normal teleport buttons require empty hands. Explicit experimental return
-- modes can teleport a held egg only with protection OFF and may reset it.
-- Direct bank tween is the default; the saved drop point remains available.
-- No Robux purchases, paid skips, selling, resets, speed stats or physics flags.

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
    alive = true, busy = false, auto = false, antiAfk = true, epoch = 0, carryLock = false,
    automationBusy=false, automationRetryAt=0,
    rarities = table.clone(RARITIES), priority = "Highest rarity first", returnMode = "tween", saved = nil,
    placeChoice="best", autoUpgrade=false,autoBuy=false,purchaseTargets={"cafe","treadmill","bag","eggs","trails"},
    destination = "bank", autoTasks = {"collect","train","hatch","place","equip"},
    stopTravel = "tween", dropAtPoint = false,
    protectHeldEgg = true,
    snapAfter = 1, snapDistance = 12,
    speedMode = "Match carry speed", customSpeed = 250,
    banks = 0, slips = 0, fault = nil,
    autoRecover = true, retryDelay = 0, resumeAt = 0,
    failures = 0, actionSerial = 0, recoveredAction = -1,
    streamOn = true, streamScope = "All zones", streamTimeout = 2,
    streamError=false,bankSensor=false,
    streamBusy = false, streamCursor = 1, streamVisited = {}, streamReady = false,
    nextStreamAt = 0, scanRequested = false, eggCache = {}, cacheTTL = 90,
    skipFastGuards = false, pointPaused = false,
}
local app, statusLabel, eggStatusLabel, countLabel, activePrompt, activeTween, autoToggle, speedSlider, returnDelaySlider, returnDistanceSlider
local antiAfk, antiAfkLabel
local destinationControl, streamLabel, stopTravelControl, dropAtPointToggle, placeEggControl, purchaseStatusLabel
local cacheLoadedEggs, resolveEgg, zoneAllowed, streamStep
local automationStep, automationCleanup, stopIdleTraining, refreshOwnedEggChoices, purchaseStep
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
    if automationCleanup then pcall(automationCleanup) end
    if antiAfk then antiAfk:Cleanup() end
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
        if eggStatusLabel then eggStatusLabel:Update({Text="Status: "..message}) end
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

local function isRagdolled()
    local character=player.Character
    return player:GetAttribute("Ragdolled")==true
        or character~=nil and character:GetAttribute("Ragdolled")==true
end

local function taskSelected(key)
    return table.find(state.autoTasks,key)~=nil
end

-- UI_POLICY_BEGIN
local UiPolicy = {}
function UiPolicy.returnMode(destination, movement)
    if destination=="manual" then return "manual" end
    if destination=="bank" then return movement end
    return "stop"
end
function UiPolicy.speed(value)
    local speed=tonumber(value) or 0
    if speed<=0 then return "Match carry speed",250 end
    return "Custom speed (may reset)",math.clamp(speed,10,1000)
end
-- UI_POLICY_END

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
    return math.clamp(tonumber(requested) or 250, 10, 1000)
end
function ReturnPolicy.result(expected, currentId, banks, bankBaseline, slips, slipBaseline, rejects, rejectBaseline)
    if slips > slipBaseline or rejects > rejectBaseline then return "rejected" end
    if banks > bankBaseline and (currentId == nil or currentId == "") then return "banked" end
    if currentId == expected then return "carrying" end
    return "unconfirmed"
end
function ReturnPolicy.shouldSnap(mode, elapsed, remaining, bankConfirmed, delay, distance, protectHeldEgg, currentId)
    if protectHeldEgg and type(currentId) == "string" and currentId ~= "" then return false end
    if mode == "banked" then return bankConfirmed end
    if mode == "timed" then return elapsed >= delay end
    if mode == "near" then return remaining <= distance end
    return mode == "instant"
end
function ReturnPolicy.allowSnap(mode, expectedId, currentId, bankConfirmed, protectHeldEgg)
    local hasEgg = type(currentId) == "string" and currentId ~= ""
    if protectHeldEgg and hasEgg then return false end
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
        countLabel:Update({ Text = "Eggs: " .. tostring(count) })
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
    {Index=5,LengthStuds=730,NestOffsetStuds=510,RequiredSpeed=1300000,GuardSpeed=110.5},
    {Index=6,LengthStuds=870,NestOffsetStuds=610,RequiredSpeed=10000000,GuardSpeed=136},
    {Index=7,LengthStuds=676,NestOffsetStuds=470,RequiredSpeed=80000000,GuardSpeed=163},
    {Index=8,LengthStuds=900,NestOffsetStuds=630,RequiredSpeed=650000000,GuardSpeed=180},
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

local function teleportReturn(id, root, current, mode, bankConfirmed, destination, protectHeldEgg)
    if not current() then return false, "Return cancelled." end
    if not ReturnPolicy.allowSnap(mode, id, player:GetAttribute("CarryingEgg"), bankConfirmed, protectHeldEgg) then
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
    local protectHeldEgg = state.protectHeldEgg ~= false
    -- Capture movement, protection and drop choices for this action.
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
        elseif ReturnPolicy.shouldSnap(movement, os.clock() - started, remaining, bankConfirmed, snapAfter, snapDistance,
            protectHeldEgg,currentId) then
            local ok, message = teleportReturn(id, root, current, movement, bankConfirmed, goal,protectHeldEgg)
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
            status(string.format(protectHeldEgg and carrying() and "Protected return %s: tween %.1f studs/s; held-egg TP blocked."
                or "Return mode %s: tween %.1f studs/s", mode, speed))
            tween:Play()
            local expires, switchToSnap = os.clock() + duration + 1, false
            while current() and os.clock() < expires and tween.PlaybackState ~= Enum.PlaybackState.Completed do
                local bankCleared = state.banks > bankBaseline and not carrying()
                if (not bankCleared and (player:GetAttribute("CarryingEgg") ~= id or state.banks > bankBaseline))
                    or state.slips > slipBaseline
                    or (tonumber(player:GetAttribute("RejectCount")) or 0) > rejectBaseline then break end
                if ReturnPolicy.shouldSnap(movement, os.clock() - started, (goal - root.Position).Magnitude,
                    bankCleared, snapAfter, snapDistance,protectHeldEgg,player:GetAttribute("CarryingEgg")) then
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
    if state.automationBusy then status("Finishing an auto task…");return end
    if carrying() or state.carryLock then
        status("Holding an egg. Press Get egg to return it.")
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
            and not isRagdolled()
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
                    status(result .. " Auto paused at finish.")
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
    if state.automationBusy then status("Finishing an auto task…");return end
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
            and not isRagdolled()
    end
    task.spawn(function()
        local ok, completed, message, kind = pcall(tweenToBank, id, root, humanoid, current)
        cancelTween()
        state.busy, state.carryLock = false, carrying()
        if not ok then pauseAuto("Tween error: " .. tostring(completed),"runtime")
        elseif current() then
            if kind == "stopped" then
                state.pointPaused,state.fault = true,nil
                status(message .. " Auto paused at finish.")
            elseif completed then
                state.failures,state.resumeAt,state.fault = 0,0,nil
                status(message)
            else pauseAuto(state.fault or message,kind) end
        elseif state.fault then failureStatus() end
    end)
end

local InventoryPolicy = (function()
-- PURE planner only. Does not require game services or fire any remotes.
-- snapshot: raw SnapshotController:Get() table with .items array/map.
-- flags: {hatch,place,equip} booleans.
-- context: now, remainingById?, pendingUntilById?, ranks?, eggCap,
-- lastEquipAt?, lastEquipSignature?, manualPlacementActive?,
-- candidate?={ownPlot=true,validated=true,x,z,yaw?,distance,itemId?}.
-- Candidate geometry/range must be obtained from the native Placement API.
-- All returned actions are unconfirmed requests, not reported game successes.
-- INVENTORY_POLICY_BEGIN
local InventoryPolicy = {}
local function finite(n)
    return type(n)=="number" and n==n and n>-math.huge and n<math.huge
end
local function items(snapshot)
    return type(snapshot)=="table" and type(snapshot.items)=="table" and snapshot.items or {}
end
local function usable(item,context)
    if type(item)~="table" or type(item.id)~="string" or item.id=="" then return false end
    local untilAt=context.pendingUntilById and context.pendingUntilById[item.id]
    return not finite(untilAt) or untilAt<=(context.now or 0)
end
local function bestEgg(snapshot,context,predicate)
    local best,bestRank=nil,-math.huge
    for _,item in pairs(items(snapshot)) do
        if usable(item,context) and item.kind=="Egg" and predicate(item) then
            local rank=context.ranks and tonumber(context.ranks[item.rarity]) or 0
            rank=finite(rank) and rank or 0
            if not best or rank>bestRank or rank==bestRank and item.id<best.id then
                best,bestRank=item,rank
            end
        end
    end
    return best
end
function InventoryPolicy.placedEggCount(snapshot)
    local count=0
    for _,item in pairs(items(snapshot)) do
        if type(item)=="table" and item.kind=="Egg" and item.placed=="floor" then count+=1 end
    end
    return count
end
function InventoryPolicy.hatch(snapshot,context)
    local egg=bestEgg(snapshot,context,function(item)
        local remaining=context.remainingById and context.remainingById[item.id]
        if remaining==nil then remaining=item.growRemaining end
        return item.placed=="floor" and finite(remaining) and remaining<=0
    end)
    if not egg then return nil,"No ready placed egg" end
    return {kind="hatch",remote="RequestHatchEgg",itemId=egg.id,payload={itemId=egg.id}}
end
function InventoryPolicy.matchesPlace(item,choice)
    if choice==nil or choice=="best" then return true end
    if type(choice)~="string" then return false end
    if choice:sub(1,7)=="rarity:" then return item.rarity==choice:sub(8) end
    if choice:sub(1,5)=="item:" then return item.id==choice:sub(6) end
    return false
end
function InventoryPolicy.placementOptions(snapshot,ranks,choice)
    local rows,counts={},{}
    for _,item in pairs(items(snapshot)) do
        if type(item)=="table" and item.kind=="Egg" and type(item.id)=="string" and item.id~=""
            and (item.placed==nil or item.placed=="") then
            rows[#rows+1]=item
            local rarity=type(item.rarity)=="string" and item.rarity or "Unknown"
            counts[rarity]=(counts[rarity] or 0)+1
        end
    end
    local function rank(item)return tonumber(ranks and ranks[item.rarity]) or 0 end
    table.sort(rows,function(a,b)return rank(a)>rank(b) or rank(a)==rank(b) and a.id<b.id end)
    local options={{value="best",label="Best available"}}
    -- Keep configured rarities selectable even before the next matching egg is owned.
    for rarity in pairs(ranks or {}) do
        if type(rarity)=="string" and rarity~="" and counts[rarity]==nil then counts[rarity]=0 end
    end
    local rarities={}
    for rarity in pairs(counts) do rarities[#rarities+1]=rarity end
    table.sort(rarities,function(a,b)
        local ar,br=tonumber(ranks and ranks[a]) or 0,tonumber(ranks and ranks[b]) or 0
        return ar>br or ar==br and a<b
    end)
    for _,rarity in ipairs(rarities) do
        options[#options+1]={value="rarity:"..rarity,label=rarity.." eggs ("..counts[rarity]..")"}
    end
    for _,item in ipairs(rows) do
        local mutation=type(item.mutation)=="string" and item.mutation~="" and item.mutation~="Normal" and " / "..item.mutation or ""
        options[#options+1]={value="item:"..item.id,label=tostring(item.rarity or "Unknown")..mutation.." - "..item.id:sub(-8)}
    end
    local found=choice==nil
    for _,option in ipairs(options) do if option.value==choice then found=true end end
    if not found and type(choice)=="string" then
        options[#options+1]={value=choice,label=choice:sub(1,7)=="rarity:" and choice:sub(8).." eggs (none owned)" or "Selected egg unavailable"}
    end
    local signature={}
    for _,option in ipairs(options) do signature[#signature+1]=option.value.."="..option.label end
    return options,table.concat(signature,"|")
end
function InventoryPolicy.place(snapshot,context)
    if context.manualPlacementActive then return nil,"Manual placement active" end
    local cap=context.eggCap
    if not finite(cap) or cap<0 then return nil,"Egg capacity unknown" end
    if InventoryPolicy.placedEggCount(snapshot)>=cap then return nil,"Egg spaces full" end
    local egg=bestEgg(snapshot,context,function(item)
        return (item.placed==nil or item.placed=="") and item.id~=context.heldItemId and InventoryPolicy.matchesPlace(item,context.placeChoice)
    end)
    if not egg then return nil,"No unplaced owned egg" end
    local spot=context.candidate
    if type(spot)~="table" or spot.ownPlot~=true or spot.validated~=true
        or not finite(spot.x) or not finite(spot.z) or not finite(spot.distance)
        or spot.distance<0 or spot.distance>60 or (spot.itemId and spot.itemId~=egg.id)
        or (spot.yaw~=nil and not finite(spot.yaw)) then
        return nil,"Need validated nearby own-plot space",egg
    end
    return {kind="place",remote="RequestPlaceAt",itemId=egg.id,
        payload={itemId=egg.id,x=spot.x,z=spot.z,yaw=spot.yaw or 0}}
end
function InventoryPolicy.equipSignature(snapshot)
    local rows={}
    for _,item in pairs(items(snapshot)) do
        if type(item)=="table" and item.kind=="Catboy" and type(item.id)=="string" and item.id~="" then
            rows[#rows+1]=item.id..":"..tostring(item.catboyId or "")..":"..tostring(item.mutation or "")
        end
    end
    table.sort(rows)
    return #rows>0 and table.concat(rows,"|") or nil
end
function InventoryPolicy.equip(snapshot,context)
    if context.manualPlacementActive then return nil,"Manual placement active" end
    local signature=InventoryPolicy.equipSignature(snapshot)
    if not signature then return nil,"No owned catboys" end
    if signature==context.lastEquipSignature then return nil,"Best already requested for this inventory" end
    if (context.now or 0)-(context.lastEquipAt or -math.huge)<2.1 then return nil,"Equip debounce" end
    return {kind="equip",remote="RequestEquipBest",payload={},signature=signature}
end
function InventoryPolicy.plan(snapshot,flags,context)
    if type(snapshot)~="table" or type(snapshot.items)~="table" then return nil,"Inventory not ready" end
    if context.manualPlacementActive then return nil,"Manual placement active" end
    if flags.hatch then local action=InventoryPolicy.hatch(snapshot,context);if action then return action end end
    if flags.equip then local action=InventoryPolicy.equip(snapshot,context);if action then return action end end
    if flags.place then return InventoryPolicy.place(snapshot,context) end
    return nil,"No inventory task ready"
end
-- INVENTORY_POLICY_END
return InventoryPolicy

end)()

local TrainingPolicy = (function()
-- Pure scheduling/geometry policy. No Roblox calls or actions.
-- Context: enabled, trainEnabled, busy, alive, holdingEgg, chased, ragdolled,
-- sitting, finishPaused, collectEnabled, eligibleEgg, pendingEggHint, onTreadmill.
local TrainingPolicy = {}

function TrainingPolicy.ready(context)
    if not context.enabled or not context.trainEnabled then return false,"disabled" end
    if context.busy then return false,"busy" end
    if not context.alive then return false,"character-unavailable" end
    if context.holdingEgg then return false,"holding-egg" end
    if context.chased then return false,"chased" end
    if context.ragdolled then return false,"ragdolled" end
    if context.sitting then return false,"sitting" end
    if context.finishPaused then return false,"finish-paused" end
    if context.collectEnabled and (context.eligibleEgg or context.pendingEggHint) then return false,"egg-priority" end
    if context.onTreadmill then return false,"already-training" end
    return true,"idle"
end

function TrainingPolicy.ownTarget(baseIndex, plotSlot, ownerUserId, localUserId)
    return type(baseIndex)=="number" and type(plotSlot)=="number"
        and plotSlot>0 and plotSlot%1==0 and baseIndex==plotSlot
        and type(ownerUserId)=="number" and ownerUserId>0 and ownerUserId==localUserId
end

function TrainingPolicy.standingOffset(partHeight, hipHeight, rootHeight)
    if type(partHeight)~="number" or partHeight<=0 or partHeight~=partHeight then return nil end
    if type(hipHeight)~="number" or hipHeight<0 or hipHeight~=hipHeight then return nil end
    if type(rootHeight)~="number" or rootHeight<=0 or rootHeight~=rootHeight then return nil end
    if partHeight==math.huge or hipHeight==math.huge or rootHeight==math.huge then return nil end
    -- R15 uses hip height + half root. Floor of 3 also accommodates ordinary R6.
    return partHeight*0.5+math.max(3,hipHeight+rootHeight*0.5)+0.1
end

function TrainingPolicy.insideBelt(x,y,z,sizeX,sizeY,sizeZ)
    return math.abs(x)<=sizeX*0.5+0.5 and math.abs(z)<=sizeZ*0.5+0.5
        and y>=0 and y<=sizeY*0.5+6
end

function TrainingPolicy.canLeave(context)
    return context.alive==true and context.ownTargetValid==true and context.atTrainingPosition==true
        and not context.busy and not context.holdingEgg and not context.chased
        and not context.ragdolled and not context.sitting and not context.moving
end

function TrainingPolicy.offBeltOffsets(sizeX,sizeZ)
    if type(sizeX)~="number" or type(sizeZ)~="number" or sizeX<=0 or sizeZ<=0
        or sizeX~=sizeX or sizeZ~=sizeZ or sizeX==math.huge or sizeZ==math.huge then return nil end
    -- Offsets are in belt-local X/Z. Caller must transform them into world space,
    -- reject points outside the OWN floor, and check a safe floor/landing exists.
    return {{x=sizeX*0.5+2,z=0},{x=-sizeX*0.5-2,z=0},
        {x=0,z=sizeZ*0.5+2},{x=0,z=-sizeZ*0.5-2}}
end

function TrainingPolicy.withinOwnFloor(localX,localZ,sizeX,sizeZ,margin)
    local gap=math.max(1,tonumber(margin) or 2)
    return math.abs(localX)<=sizeX*0.5-gap and math.abs(localZ)<=sizeZ*0.5-gap
end

return TrainingPolicy

end)()

local InventoryRuntime = (function()
-- READ-ONLY runtime adapter for the inspected v629 client.
-- Requires InventoryPolicy from egg_inventory_policy.luau to be in scope.
-- No FireServer/InvokeServer, input, movement, purchases or item mutation.
-- memory fields updated by the caller AFTER dispatch: pendingUntilById,
-- lastEquipAt, lastEquipSignature. This adapter only caches module references.
local InventoryRuntime = {}

local function module(parent,name)
    local found=parent and parent:FindFirstChild(name)
    if not found or not found:IsA("ModuleScript") then return nil end
    local ok,result=pcall(require,found)
    return ok and type(result)=="table" and result or nil
end

function InventoryRuntime.read(player,memory,ranks,flags)
    local rs=game:GetService("ReplicatedStorage")
    local cs=game:GetService("CollectionService")
    local shared=rs:FindFirstChild("Shared")
    local config=shared and shared:FindFirstChild("Config")
    local util=shared and shared:FindFirstChild("Util")
    local scripts=player:FindFirstChild("PlayerScripts")
    local client=scripts and scripts:FindFirstChild("Client")
    local controllers=client and client:FindFirstChild("Controllers")
    local modules=memory.modules
    if not modules then
        modules={snapshot=module(controllers,"SnapshotController"),
            placement=module(controllers,"PlacementController"),
            geometry=module(util,"Placement"),config=module(config,"PlacementConfig"),
            constants=module(shared,"Constants")}
        if not modules.snapshot or not modules.placement or not modules.geometry
            or not modules.config or not modules.constants then return nil,nil,{reason="Client inventory not ready"} end
        memory.modules=modules
    end
    local ok,snapshot=pcall(modules.snapshot.Get,modules.snapshot)
    if not ok or type(snapshot)~="table" or type(snapshot.items)~="table" then
        return nil,nil,{reason="Inventory snapshot not ready"}
    end
    local context={now=os.clock(),ranks=ranks,placeChoice=memory.placeChoice,eggCap=tonumber(player:GetAttribute("EggCap")),
        remainingById={},pendingUntilById=memory.pendingUntilById or {},
        lastEquipAt=memory.lastEquipAt,lastEquipSignature=memory.lastEquipSignature}
    local meta={snapshot=snapshot,readyAnchorCount=0}
    local api,geom,cfg,constants=modules.placement,modules.geometry,modules.config,modules.constants
    local activeOK,active=pcall(api.IsActive,api)
    context.manualPlacementActive=activeOK and active==true
    local heldOK,held=pcall(api.GetItemId,api)
    context.heldItemId=heldOK and held or nil
    if memory.ownedPlacementId and context.heldItemId==memory.ownedPlacementId then
        context.manualPlacementActive,context.heldItemId=false,nil
    end

    -- Raw snapshot timers can be stale for many minutes. Replicated owned
    -- placed anchors carry State and ReadyAt; use server-confirmed Ready state.
    for _,item in pairs(snapshot.items) do
        if type(item)=="table" and item.kind=="Egg" and item.placed=="floor" and type(item.id)=="string" then
            context.remainingById[item.id]=math.huge
        end
    end
    local ownedAnchors={}
    for _,part in ipairs(cs:GetTagged(constants.Tag.Placed or "Placed")) do
        if part:IsA("BasePart") and part:IsDescendantOf(workspace)
            and part:GetAttribute(constants.Attr.OwnerUserId or "OwnerUserId")==player.UserId then
            ownedAnchors[#ownedAnchors+1]=part
            if part:GetAttribute(constants.Attr.ItemKind or "ItemKind")=="Egg" then
                local id=part:GetAttribute(constants.Attr.ItemId or "ItemId")
                if type(id)=="string" and part:GetAttribute(constants.Attr.State or "State")=="Ready" then
                    context.remainingById[id]=0
                    meta.readyAnchorCount+=1
                end
            end
        end
    end
    if not flags.place then return snapshot,context,meta end
    local baseOK,base=pcall(api.GetBase,api)
    if not baseOK or not base or not base:IsA("Model") or not base:IsDescendantOf(workspace)
        or base:GetAttribute(constants.Attr.OwnerUserId or "OwnerUserId")~=player.UserId then
        meta.reason="Own plot is not ready";return snapshot,context,meta
    end
    local floor=base:FindFirstChild(constants.BasePart.Floor or "Floor")
    local encoded=base:GetAttribute(constants.Attr.PlacementArea or "PlacementArea")
    if not floor or not floor:IsA("BasePart") or type(encoded)~="string" then
        meta.reason="Own floor is not ready";return snapshot,context,meta
    end
    local decoded,area=pcall(geom.Decode,encoded)
    if not decoded or type(area)~="table" then
        meta.reason="Own placement geometry is not ready";return snapshot,context,meta
    end
    meta.floor=floor
    local frame=geom.BaseFrame(floor)
    local character=player.Character
    local root=character and character:FindFirstChild("HumanoidRootPart")
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    local spawn=base:FindFirstChild(constants.BasePart.Spawn or "Spawn",true)
    if root and root:IsA("BasePart") and humanoid then
        local x,z=0,0
        if spawn and spawn:IsA("BasePart") then x,z=geom.ToLocal(frame,spawn.Position) end
        meta.maintenancePosition=geom.ToWorld(frame,x,z,0).Position
            +Vector3.new(0,humanoid.HipHeight+root.Size.Y*0.5,0)
    end
    local _,reason,pending=InventoryPolicy.place(snapshot,context)
    if not pending then meta.reason=reason;return snapshot,context,meta end
    local anchors={}
    for _,part in ipairs(ownedAnchors) do
        local x,z=geom.ToLocal(frame,part.Position)
        anchors[#anchors+1]={X=x,Z=z,R=part:GetAttribute(constants.Attr.Radius or "Radius") or cfg.Spacing.EggRadius,
            Id=part:GetAttribute(constants.Attr.ItemId or "ItemId")}
    end
    local radius=geom.EggRadius()
    local found,x,z=pcall(geom.FindFree,area,0,0,radius,anchors,pending.id)
    if not found or type(x)~="number" or type(z)~="number" then
        meta.reason="No empty placement space";return snapshot,context,meta
    end
    local validOK,valid=pcall(geom.Validate,area,x,z,radius,anchors,pending.id)
    if not validOK or valid~=true then meta.reason="No validated placement space";return snapshot,context,meta end
    local worldPoint=geom.ToWorld(frame,x,z,0).Position
    context.candidate={ownPlot=true,validated=true,itemId=pending.id,x=x,z=z,yaw=0,
        distance=root and root:IsA("BasePart") and (root.Position-worldPoint).Magnitude or math.huge}
    meta.needsMaintenanceTrip=context.candidate.distance>(cfg.ClickRangeStuds or 60)
    meta.base=base
    return snapshot,context,meta
end
return InventoryRuntime

end)()

local PurchasePolicy = (function()
-- Pure normal-cash purchase planner. No services, movement or remote dispatch.
-- rows: {category,key?,label?,cost,remote,payload,stamp,currency?="Money"}.
-- categories: cafe,treadmill,bag,eggs,trails. Use actual next-step native prices.
-- flags: upgradeEnabled,buyEnabled,targets? (array or category=true map).
-- Missing targets means all categories; an explicit empty table means none.
-- context: money,now?,pending?,blockedUntilByStamp? (per PurchasePolicy.key).
-- Any pending request blocks ALL further purchases until caller confirms/times out.
-- A returned action is only an unconfirmed request, never proof of a purchase.
-- PURCHASE_POLICY_BEGIN
local PurchasePolicy = {}
local ORDER={cafe=1,treadmill=2,bag=3,eggs=4,trails=5}
local function finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
local function validStamp(value)
    if type(value)=="string" then return value~="" end
    return type(value)=="number" and finite(value) and value>=0 and value%1==0
end
local function exactKeys(payload,allowed)
    for key in pairs(payload) do if not allowed[key] then return false end end
    return true
end
local function selected(flags,category)
    if category=="trails" then
        if flags.buyEnabled~=true then return false end
    elseif flags.upgradeEnabled~=true then return false end
    local targets=flags.targets
    if targets==nil then return true end
    if type(targets)~="table" then return false end
    if targets[category]==true then return true end
    return table.find(targets,category)~=nil
end

function PurchasePolicy.actionOf(row)
    if type(row)~="table" or not ORDER[row.category] or not finite(row.cost) or row.cost<0
        or not validStamp(row.stamp) or (row.currency~=nil and row.currency~="Money")
        or row.paidOnly==true or row.robux==true or type(row.payload)~="table" then return nil end
    local category,payload=row.category,row.payload
    local normalized
    if category=="cafe" or category=="treadmill" then
        local action=category=="cafe" and "UpgradePen" or "BuyTreadmill"
        if row.remote~="RequestShop" or payload.action~=action or not exactKeys(payload,{action=true}) then return nil end
        normalized={action=action}
    elseif category=="bag" or category=="eggs" then
        local kind=category=="bag" and "Bag" or "Eggs"
        if row.remote~="RequestUpgrade" or payload.kind~=kind or not exactKeys(payload,{kind=true}) then return nil end
        normalized={kind=kind}
    else
        if row.remote~="RequestShop" or payload.action~="BuyTrail" or type(row.key)~="string"
            or row.key=="" or payload.key~=row.key or not exactKeys(payload,{action=true,key=true}) then return nil end
        normalized={action="BuyTrail",key=row.key}
    end
    return {category=category,key=category=="trails" and row.key or nil,label=type(row.label)=="string" and row.label or category,
        cost=row.cost,remote=row.remote,payload=normalized,stamp=row.stamp,currency="Money"}
end

function PurchasePolicy.key(action)
    return action.category..":"..tostring(action.key or "")..":"..tostring(action.stamp)
end

function PurchasePolicy.confirmed(pending,currentStamp)
    if type(pending)~="table" or not validStamp(pending.stamp) or not validStamp(currentStamp) then return false end
    if type(pending.stamp)=="number" and type(currentStamp)=="number" then return currentStamp>pending.stamp end
    return type(pending.stamp)==type(currentStamp) and pending.stamp~=currentStamp
end

function PurchasePolicy.plan(rows,flags,context)
    if type(flags)~="table" or type(context)~="table" then return nil,"Purchase state unavailable" end
    if context.pending~=nil and context.pending~=false then return nil,"Purchase pending" end
    if not finite(context.money) or context.money<0 then return nil,"Cash balance unavailable" end
    if type(rows)~="table" then return nil,"Cash upgrades unavailable" end
    local best,bestKey
    for _,row in pairs(rows) do
        local action=PurchasePolicy.actionOf(row)
        if action and selected(flags,action.category) and action.cost<=context.money then
            local key=PurchasePolicy.key(action)
            local blocked=type(context.blockedUntilByStamp)=="table" and context.blockedUntilByStamp[key]
            local allowed=not finite(blocked) or finite(context.now) and context.now>=blocked
            if allowed and (not best or action.cost<best.cost
                or action.cost==best.cost and (ORDER[action.category]<ORDER[best.category]
                    or ORDER[action.category]==ORDER[best.category] and key<bestKey)) then
                best,bestKey=action,key
            end
        end
    end
    return best,best and "Affordable cash request" or "No selected affordable cash upgrade"
end
-- PURCHASE_POLICY_END
return PurchasePolicy

end)()

local PurchaseRuntime = (function()
-- Read-only adapter for confirmed native cash-upgrade interfaces.
local PurchaseRuntime={}
local function finite(n)return type(n)=="number" and n==n and n>=0 and n<math.huge end
local function level(n)return finite(n) and n%1==0 end
local function module(parent,name)
    local target=parent and parent:FindFirstChild(name)
    if not target or not target:IsA("ModuleScript") then return nil end
    local ok,result=pcall(require,target)
    return ok and type(result)=="table" and result or nil
end
function PurchaseRuntime.read(player,memory)
    local rs=game:GetService("ReplicatedStorage")
    local shared=rs:FindFirstChild("Shared")
    local config=shared and shared:FindFirstChild("Config")
    local kit=shared and shared:FindFirstChild("Kit")
    local scripts=player:FindFirstChild("PlayerScripts")
    local client=scripts and scripts:FindFirstChild("Client")
    local controllers=client and client:FindFirstChild("Controllers")
    local modules=memory.modules
    if not modules then
        modules={econ=module(kit,"Econ"),upgrade=module(config,"UpgradeConfig"),speed=module(config,"SpeedConfig"),
            snapshot=module(controllers,"SnapshotController"),constants=module(shared,"Constants")}
        if not modules.econ or not modules.upgrade or not modules.speed or not modules.snapshot or not modules.constants then
            return nil,nil,nil,"Shop data not ready"
        end
        memory.modules=modules
    end
    local attr=modules.constants.Attr
    local money=player:GetAttribute(attr.Money or "Money")
    local rows,stamps={},{}
    local pen=player:GetAttribute(attr.PenLevel or "PenLevel")
    local tier=player:GetAttribute(attr.TreadmillTier or "TreadmillTier")
    stamps.cafe,stamps.treadmill=pen,tier
    local function add(category,label,cost,remote,payload,stamp,key)
        if finite(cost) then rows[#rows+1]={category=category,label=label,cost=cost,remote=remote,payload=payload,stamp=stamp,key=key,currency="Money"} end
    end
    if level(pen) then
        local ok,cost=pcall(modules.econ.UpgradeCost,"Cafe",pen)
        if ok then add("cafe","Cafe / base",cost,"RequestShop",{action="UpgradePen"},pen) end
    end
    if level(tier) then
        local unlocked,yes=pcall(modules.econ.TreadmillUnlocked,pen)
        if tier>=1 or unlocked and yes==true then
            local ok,cost=pcall(modules.econ.UpgradeCost,"Treadmill",tier)
            if ok then add("treadmill","Treadmill",cost,"RequestShop",{action="BuyTreadmill"},tier) end
        end
    end
    for _,info in ipairs({{category="bag",kind="Bag",label="Bag capacity"},{category="eggs",kind="Eggs",label="Egg capacity"}}) do
        local cfg=modules.upgrade[info.kind]
        local current=cfg and cfg.Attr and player:GetAttribute(cfg.Attr.Level)
        stamps[info.category]=current
        if level(current) then
            local ok,step=pcall(modules.upgrade.Step,info.kind,current)
            if ok and type(step)=="table" and step.Level==current+1 then
                add(info.category,info.label,step.Cost,"RequestUpgrade",{kind=info.kind},current)
            end
        end
    end
    local ok,snapshot=pcall(modules.snapshot.Get,modules.snapshot)
    if ok and type(snapshot)=="table" and type(snapshot.trailsOwned)=="table" then
        for _,trail in ipairs(modules.speed.Trails or {}) do
            if type(trail.Key)=="string" and trail.Key~="" then
                local owned=snapshot.trailsOwned[trail.Key]==true
                stamps["trails:"..trail.Key]=owned and 1 or 0
                if not owned then add("trails",trail.Name or trail.Key,trail.Cost,"RequestShop",{action="BuyTrail",key=trail.Key},0,trail.Key) end
            end
        end
    end
    return rows,money,stamps
end
return PurchaseRuntime

end)()

-- Owned-item/idle-training adapter. All requests are opt-in through Auto tasks.
local serviceMemory: {[string]:any}={pendingUntilById={},autoHatchUntil={},nextAt=0}
local servicePhase=nil
local trainingBelt=nil
local nextTrainAt=0

local function ownedBase(part)
    local node=part
    while node and node~=workspace do
        if node:IsA("Model") and node:GetAttribute("OwnerUserId")==player.UserId then return node end
        node=node.Parent
    end
end

local function canService()
    local character,root,humanoid=characterParts()
    return state.alive and state.auto and not state.busy and root~=nil and not carrying()
        and not isRagdolled() and player:GetAttribute("Chased")~=true
        and not humanoid.Sit,character,root,humanoid
end

local function findOwnBelt()
    local slot=tonumber(player:GetAttribute("PlotSlot"))
    for _,part in ipairs(CollectionService:GetTagged("Treadmill")) do
        local base=part:IsA("BasePart") and part:IsDescendantOf(workspace) and ownedBase(part)
        if base and TrainingPolicy.ownTarget(part:GetAttribute("BaseIndex"),slot,base:GetAttribute("OwnerUserId"),player.UserId) then
            return part,base
        end
    end
end

stopIdleTraining=function()
    local belt=trainingBelt
    trainingBelt=nil
    if not belt or not belt.Parent then return end
    local _,root,humanoid=characterParts()
    local base=ownedBase(belt)
    local localPoint=root and belt.CFrame:PointToObjectSpace(root.Position)
    local atBelt=localPoint and TrainingPolicy.insideBelt(localPoint.X,localPoint.Y,localPoint.Z,belt.Size.X,belt.Size.Y,belt.Size.Z)
    if not TrainingPolicy.canLeave({alive=root~=nil,ownTargetValid=base~=nil,atTrainingPosition=atBelt==true,
        busy=state.busy,holdingEgg=carrying(),chased=player:GetAttribute("Chased")==true,
        ragdolled=isRagdolled(),sitting=humanoid and humanoid.Sit,moving=humanoid and humanoid.MoveDirection.Magnitude>0.1}) then return end
    local floor=base and base:FindFirstChild("Floor")
    if not floor or not floor:IsA("BasePart") then return end
    local offsets=TrainingPolicy.offBeltOffsets(belt.Size.X,belt.Size.Z)
    for _,offset in ipairs(offsets or {}) do
        local point=belt.CFrame:PointToWorldSpace(Vector3.new(offset.x,0,offset.z))
        local onFloor=floor.CFrame:PointToObjectSpace(point)
        if TrainingPolicy.withinOwnFloor(onFloor.X,onFloor.Z,floor.Size.X,floor.Size.Z,2) then
            local surface=floor.CFrame:PointToWorldSpace(Vector3.new(onFloor.X,floor.Size.Y*0.5,onFloor.Z))
            local height=math.max(3,humanoid.HipHeight+root.Size.Y*0.5)
            moveRoot(root,CFrame.new(surface+Vector3.new(0,height+0.1,0))*(root.CFrame-root.Position))
            return
        end
    end
end

local function trainWhenIdle(eggReady)
    local allowed,_,root,humanoid=canService()
    local ready=TrainingPolicy.ready({enabled=state.auto,trainEnabled=taskSelected("train"),busy=state.busy or state.automationBusy,
        alive=root~=nil,holdingEgg=carrying(),chased=player:GetAttribute("Chased")==true,ragdolled=isRagdolled(),
        sitting=humanoid and humanoid.Sit,finishPaused=state.pointPaused,collectEnabled=taskSelected("collect"),
        eligibleEgg=eggReady,pendingEggHint=false,onTreadmill=player:GetAttribute("OnTreadmill")==true})
    if allowed and not state.pointPaused and player:GetAttribute("OnTreadmill")==true and taskSelected("train") and not eggReady then
        status("Training speed…");return
    end
    if not allowed or not ready or os.clock()<nextTrainAt then return end
    nextTrainAt=os.clock()+5
    local belt=findOwnBelt()
    if not belt then status("Waiting for your treadmill…");return end
    local offset=TrainingPolicy.standingOffset(belt.Size.Y,humanoid.HipHeight,root.Size.Y)
    if not offset then return end
    local position=belt.CFrame:PointToWorldSpace(Vector3.new(0,offset,0))
    local moved=moveRoot(root,CFrame.new(position)*(root.CFrame-root.Position))
    if moved then trainingBelt=belt;status("Going to treadmill…") end
end

local function cancelOurTool(id)
    local modules=serviceMemory.modules
    local api=modules and modules.placement
    if not api or type(id)~="string" then return end
    local ok,held=pcall(api.GetItemId,api)
    if ok and held==id then pcall(api.Cancel,api) end
end

automationCleanup=function()
    if servicePhase then cancelOurTool(servicePhase.itemId) end
    servicePhase=nil
    serviceMemory.ownedPlacementId=nil
    state.automationBusy=false
    stopIdleTraining()
end

local function placeRemote(action)
    local folder=ReplicatedStorage:FindFirstChild("Remotes")
    local remote=folder and folder:FindFirstChild(action.remote)
    if not remote or not remote:IsA("RemoteEvent") then return false end
    local ok,err=pcall(function()remote:FireServer(action.payload)end)
    if not ok then warn("[Egg Helper] "..tostring(err)) end
    return ok
end

local function readInventory(flags)
    serviceMemory.placeChoice=state.placeChoice
    local snapshot,context,meta=InventoryRuntime.read(player,serviceMemory,RARITY_RANK,flags)
    if context and context.manualPlacementActive then
        local held=context.heldItemId
        if servicePhase and servicePhase.itemId==held then
            context.manualPlacementActive,context.heldItemId=false,nil
        elseif held and (serviceMemory.autoHatchUntil[held] or 0)>os.clock() then
            cancelOurTool(held)
            serviceMemory.autoHatchUntil[held]=nil
            context.manualPlacementActive,context.heldItemId=false,nil
        end
    end
    return snapshot,context,meta
end

local function equipPlaceTool(id,humanoid)
    local backpack=player:FindFirstChildOfClass("Backpack")
    local character=player.Character
    for _,container in ipairs({character,backpack}) do
        if container then for _,tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("ItemId")==id then
                if container~=character then humanoid:EquipTool(tool) end
                return true
            end
        end end
    end
    return false
end

local function maintenancePosition(meta,root,humanoid)
    local point=meta.maintenancePosition
    local floor=meta.floor
    if not point or not floor then return nil end
    local localPoint=floor.CFrame:PointToObjectSpace(point)
    if not TrainingPolicy.withinOwnFloor(localPoint.X,localPoint.Z,floor.Size.X,floor.Size.Z,2) then
        point=floor.CFrame:PointToWorldSpace(Vector3.new(0,floor.Size.Y*0.5,0))
            +Vector3.new(0,math.max(3,humanoid.HipHeight+root.Size.Y*0.5)+0.1,0)
    end
    return point
end

automationStep=function(eggReady)
    local allowed,_,root,humanoid=canService()
    if not allowed then return state.automationBusy==true end
    local now=os.clock()
    if now<(serviceMemory.nextReadAt or 0) then return state.automationBusy==true end
    serviceMemory.nextReadAt=now+0.25
    local flags={hatch=taskSelected("hatch"),place=taskSelected("place"),equip=taskSelected("equip")}
    local snapshot,context,meta=readInventory(flags)
    if not snapshot or not context then
        if not eggReady then trainWhenIdle(eggReady) end
        return false
    end
    if context.manualPlacementActive then status("Finish manual placement first.");return true end

    if servicePhase then
        local phase=servicePhase
        if not flags.place then automationCleanup();return false end
        if phase.kind=="await" then
            local placed=false
            for _,item in pairs(snapshot.items) do
                if item.id==phase.itemId and item.placed=="floor" then placed=true;break end
            end
            if placed or now>phase.deadline then
                if not placed then cancelOurTool(phase.itemId);status("Place request not confirmed.") end
                serviceMemory.pendingUntilById[phase.itemId]=now+(placed and 2 or 10)
                servicePhase=nil;serviceMemory.ownedPlacementId=nil;state.automationBusy=false;serviceMemory.nextAt=now+0.7
                return false
            end
            return true
        end
        if now<phase.at then return true end
        local action=InventoryPolicy.place(snapshot,context)
        if not action then
            cancelOurTool(phase.itemId)
            servicePhase=nil;serviceMemory.ownedPlacementId=nil;state.automationBusy=false;serviceMemory.nextAt=now+2
            return false
        end
        if phase.kind=="visit" then
            phase.itemId=action.itemId
            serviceMemory.ownedPlacementId=action.itemId
            equipPlaceTool(action.itemId,humanoid)
            phase.kind,phase.at="place",now+0.2
            return true
        end
        if placeRemote(action) then
            serviceMemory.pendingUntilById[action.itemId]=now+5
            servicePhase={kind="await",itemId=action.itemId,deadline=now+3}
            status("Placing egg…")
        else
            automationCleanup();serviceMemory.nextAt=now+3;status("Place unavailable.")
        end
        return state.automationBusy==true
    end

    if now>=serviceMemory.nextAt then
        local action,reason,pending=InventoryPolicy.plan(snapshot,flags,context)
        if action and action.kind=="place" then
            state.automationBusy=true
            servicePhase={kind="visit",itemId=action.itemId,at=now}
            serviceMemory.ownedPlacementId=action.itemId
            return true
        elseif action then
            if placeRemote(action) then
                if action.kind=="hatch" then
                    serviceMemory.pendingUntilById[action.itemId]=now+5
                    serviceMemory.autoHatchUntil[action.itemId]=now+30
                    serviceMemory.nextAt=now+3.2
                    status("Hatching ready egg…")
                else
                    serviceMemory.lastEquipAt,serviceMemory.lastEquipSignature=now,action.signature
                    serviceMemory.nextAt=now+0.7
                    status("Equipping best…")
                end
            else serviceMemory.nextAt=now+3;status("Auto task unavailable.") end
        elseif pending and meta and meta.needsMaintenanceTrip and not state.pointPaused then
            local position=maintenancePosition(meta,root,humanoid)
            if position then
                trainingBelt=nil
                local moved=moveRoot(root,CFrame.new(position)*(root.CFrame-root.Position))
                if moved then
                    state.automationBusy=true
                    servicePhase={kind="visit",itemId=pending.id,at=now+0.75}
                    serviceMemory.ownedPlacementId=pending.id
                    status("Visiting your plot…")
                    return true
                end
            end
        end
    end
    if not eggReady then trainWhenIdle(eggReady) end
    return false
end

local purchaseMemory: {[string]:any}={blockedUntilByStamp={},nextAt=0}
local lastPurchaseStatus
local function purchaseStatus(message)
    if purchaseStatusLabel and message~=lastPurchaseStatus then
        lastPurchaseStatus=message;purchaseStatusLabel:Update({Text="Purchases: "..message})
    end
end
local function purchaseToggleStatus()
    if not state.autoUpgrade and not state.autoBuy then purchaseStatus("OFF")
    else purchaseStatus(state.auto and "ON" or "Paused - Auto run is OFF") end
end
purchaseStep=function()
    local now=os.clock()
    if not state.autoUpgrade and not state.autoBuy then purchaseStatus("OFF");return end
    if now<purchaseMemory.nextAt then return end
    purchaseMemory.nextAt=now+1
    local rows,money,stamps,reason=PurchaseRuntime.read(player,purchaseMemory)
    if not rows then purchaseStatus(reason or "Waiting for shop data");return end
    local pending=purchaseMemory.pending
    if pending then
        local stamp=stamps[pending.category=="trails" and "trails:"..pending.key or pending.category]
        if PurchasePolicy.confirmed(pending,stamp) then
            purchaseStatus("Bought "..pending.label)
            purchaseMemory.pending=nil
            return
        elseif now<pending.deadline then purchaseStatus("Waiting for "..pending.label);return
        else
            purchaseMemory.blockedUntilByStamp[PurchasePolicy.key(pending)]=now+15
            purchaseMemory.pending=nil
            purchaseStatus("Not confirmed; backing off")
            return
        end
    end
    local action=PurchasePolicy.plan(rows,{upgradeEnabled=state.autoUpgrade,buyEnabled=state.autoBuy,targets=state.purchaseTargets},
        {money=money,now=now,blockedUntilByStamp=purchaseMemory.blockedUntilByStamp})
    if not action then purchaseStatus("Waiting for affordable upgrades");return end
    -- Exact allowlist is checked by the pure policy again at the dispatch boundary.
    action=PurchasePolicy.actionOf(action)
    if not action then return end
    local folder=ReplicatedStorage:FindFirstChild("Remotes")
    local remote=folder and folder:FindFirstChild(action.remote)
    if not remote or not remote:IsA("RemoteEvent") then purchaseStatus("Cash request unavailable");return end
    action.deadline=now+8
    purchaseMemory.pending=action
    local sent,err=pcall(function()remote:FireServer(action.payload)end)
    if sent then purchaseStatus("Buying "..action.label)
    else
        purchaseMemory.pending=nil
        purchaseMemory.blockedUntilByStamp[PurchasePolicy.key(action)]=now+15
        warn("[Egg Helper] Cash request: "..tostring(err));purchaseStatus("Request failed")
    end
end

local function automationPreview()
    serviceMemory.placeChoice=state.placeChoice
    local flags={hatch=taskSelected("hatch"),place=taskSelected("place"),equip=taskSelected("equip")}
    local snapshot,context,meta=InventoryRuntime.read(player,serviceMemory,RARITY_RANK,flags)
    local action,reason
    if snapshot and context then action,reason=InventoryPolicy.plan(snapshot,flags,context) end
    local belt=findOwnBelt()
    local cashRows,money=PurchaseRuntime.read(player,purchaseMemory)
    local cashAction=PurchasePolicy.plan(cashRows,{upgradeEnabled=state.autoUpgrade,buyEnabled=state.autoBuy,targets=state.purchaseTargets},{money=money})
    return {cashCandidates=cashRows and #cashRows,cashPlanned=cashAction and cashAction.label,snapshotReady=snapshot~=nil,planned=action and action.kind,reason=reason or (meta and meta.reason),
        readyEggAnchors=meta and meta.readyAnchorCount,needsPlotVisit=meta and meta.needsMaintenanceTrip,
        ownTreadmill=belt and belt:GetFullName(),requestsSent=0}
end


lifetime.OnInvoke=function(command)
    if command=="status" then return {auto=state.auto,busy=state.busy,automationBusy=state.automationBusy==true,
        antiAfk=state.antiAfk,antiAfkStatus=antiAfk and antiAfk:GetStatus(),
        placeChoice=state.placeChoice,autoUpgrade=state.autoUpgrade,autoBuy=state.autoBuy,
        tasks=table.clone(state.autoTasks),destination=state.destination,movement=state.stopTravel,
        speedMode=state.speedMode,customSpeed=state.customSpeed,drop=state.dropAtPoint,protected=state.protectHeldEgg} end
    if command=="preview" then return automationPreview() end
    cleanup()
end

local AntiAfk = (function()
-- Owns only its scoped local idle-method wrapper; never disables other listeners.
-- deps: clock(), getController(), pulse(), notify(message)?
local AntiAfk={}
function AntiAfk.new(deps)
    local self={alive=true,enabled=false,controller=nil,original=nil,wrapper=nil,lastPulse=-math.huge,pulses=0,lastError=nil}
    local function notify(message)
        if deps.notify then pcall(deps.notify,message) end
    end
    local function restore()
        if self.controller and self.controller.GetIdleSeconds==self.wrapper then
            pcall(function()self.controller.GetIdleSeconds=self.original end)
        end
        self.controller,self.original,self.wrapper=nil,nil,nil
    end
    local function install()
        if self.controller and self.controller.GetIdleSeconds==self.wrapper then return true end
        restore()
        local ok,controller=pcall(deps.getController)
        if not ok or type(controller)~="table" or type(controller.GetIdleSeconds)~="function" then return false end
        local original=controller.GetIdleSeconds
        local wrapper=function(...)
            if self.alive and self.enabled then return 0 end
            return original(...)
        end
        local written=pcall(function()controller.GetIdleSeconds=wrapper end)
        if not written then return false end
        self.controller,self.original,self.wrapper=controller,original,wrapper
        return true
    end
    function self:SetEnabled(value)
        self.enabled=self.alive and value==true
        if self.enabled then
            local guarded=install()
            notify(guarded and "ON" or "ON - game idle guard unavailable")
        else restore();notify("OFF") end
    end
    function self:OnIdle()
        if not self.alive or not self.enabled then return false end
        local now=deps.clock()
        if now-self.lastPulse<60 then return false end
        self.lastPulse=now
        local guarded=install()
        local ok,err=pcall(deps.pulse)
        self.lastError=not ok and tostring(err) or nil
        if ok then self.pulses+=1 end
        notify(not ok and "Virtual input unavailable" or guarded and "ON" or "ON - game idle guard unavailable")
        return ok
    end
    function self:GetStatus()
        return {enabled=self.enabled,gameIdleGuard=self.controller~=nil and self.controller.GetIdleSeconds==self.wrapper,
            pulses=self.pulses,lastError=self.lastError}
    end
    function self:Cleanup()
        self.enabled,self.alive=false,false
        restore()
    end
    return self
end
return AntiAfk

end)()

local window = app:CreateWindow({
    Id="eggs", Title="Egg Helper · v1.9.1", Design="MintGlass",
    Size={640,700}, OpenKey="RightShift", Wallpaper=false, OnClose=cleanup,
})
local main=window:AddTab({Title="Main"}):AddSection({Title="Eggs"})
local eggs=window:AddTab({Title="Egg"}):AddSection({Title="Owned eggs"})
local shop=window:AddTab({Title="Shop"}):AddSection({Title="Cash purchases"})
local settings=window:AddTab({Title="Settings"}):AddSection({Title="Return settings"})

local function updateReturnChoice()
    state.returnMode=UiPolicy.returnMode(state.destination,state.stopTravel)
    state.pointPaused=false
    refreshReturnControls()
end

main:AddMultiSelect({Id="rarities",Title="Rarities",Default=table.clone(RARITIES),Options=RARITY_OPTIONS,
    Callback=function(values)state.rarities=table.clone(values);refreshCount()end})
stopTravelControl=main:AddDropdown({Id="movement",Title="Movement",Default="tween",Options={
    {value="tween",label="Tween"},
    {value="timed",label="Tween → teleport"},
    {value="near",label="Tween close → teleport"},
    {value="instant",label="Teleport"},
},Callback=function(value)
    state.stopTravel=value
    updateReturnChoice()
    status(state.protectHeldEgg and value~="tween" and "Safe return ON: held eggs use tween." or "Ready.")
end})
destinationControl=main:AddDropdown({Id="destination",Title="Finish",Default="bank",Options={
    {value="bank",label="Bank eggs"},
    {value="stop",label="Saved drop point"},
    {value="manual",label="Pickup only"},
},Callback=function(value)state.destination=value;updateReturnChoice();status("Ready.")end})
speedSlider=main:AddSlider({Id="speed",Title="Tween speed",Min=0,Max=1000,Step=10,Default=0,
    Format=function(value)return value==0 and "Auto" or tostring(value)end,
    Callback=function(value)state.speedMode,state.customSpeed=UiPolicy.speed(value)end})
dropAtPointToggle=main:AddToggle({Id="dropAtPoint",Title="Drop at saved point",Default=false,Disabled=true,
    Callback=function(value)state.dropAtPoint=value end})
local function setAutoTask(key,enabled)
    local index=table.find(state.autoTasks,key)
    if enabled and not index then state.autoTasks[#state.autoTasks+1]=key
    elseif not enabled and index then table.remove(state.autoTasks,index) end
end
main:AddMultiSelect({Id="autoTasks",Title="Main tasks",Default={"collect","train"},Options={
    {value="collect",label="Collect eggs"},
    {value="train",label="Train when idle"},
},Callback=function(values)
    setAutoTask("collect",table.find(values,"collect")~=nil)
    setAutoTask("train",table.find(values,"train")~=nil)
    if not taskSelected("train") and stopIdleTraining then stopIdleTraining() end
end})
autoToggle=main:AddToggle({Id="auto",Title="Auto run",Default=false,Callback=function(value)
    state.auto=value
    state.epoch+=1
    if value then
        state.fault,state.resumeAt,state.failures,state.recoveredAction,state.pointPaused=nil,0,0,-1,false
    else
        state.resumeAt=0
        if automationCleanup then automationCleanup() end
        cancelTween();endHold()
        if stopIdleTraining then stopIdleTraining() end
    end
    purchaseToggleStatus()
    status(value and "Auto ON." or "Stopped.")
end})
main:AddButton({Title="Get egg",Variant="primary",Callback=function()
    if isRagdolled() then status("Recovering from hit…");return end
    state.pointPaused=false
    if carrying() then tweenHeldEgg() else runAction(true) end
end})
main:AddButton({Title="Stop",Callback=function()
    autoToggle:SetValue(false)
    state.epoch+=1
    cancelTween();endHold()
    if stopIdleTraining then stopIdleTraining() end
    status("Stopped.")
end})
countLabel=main:AddText({Text="Eggs: 0"})
statusLabel=main:AddText({Text="Status: Ready."})

local lastPlaceOptions
refreshOwnedEggChoices=function()
    serviceMemory.placeChoice=state.placeChoice
    local snapshot=InventoryRuntime.read(player,serviceMemory,RARITY_RANK,{place=false})
    if not snapshot then return end
    local options,signature=InventoryPolicy.placementOptions(snapshot,RARITY_RANK,state.placeChoice)
    if signature~=lastPlaceOptions then
        placeEggControl:Update({Options=options})
        lastPlaceOptions=signature
    end
end
eggs:AddText({Text="Runs with Auto run on Main."})
placeEggControl=eggs:AddDropdown({Id="placeEgg",Title="Egg to place",Default="best",Searchable=true,
    Options={{value="best",label="Best available"}},Callback=function(value)
        if state.automationBusy and automationCleanup then automationCleanup() end
        state.placeChoice=value
        serviceMemory.placeChoice=value
        status("Egg selection updated.")
    end})
eggs:AddToggle({Id="autoPlace",Title="Auto place selected eggs",Default=taskSelected("place"),Callback=function(value)
    setAutoTask("place",value)
    if not value and state.automationBusy and automationCleanup then automationCleanup() end
end})
eggs:AddToggle({Id="autoHatch",Title="Auto hatch ready eggs",Default=taskSelected("hatch"),Callback=function(value)setAutoTask("hatch",value)end})
eggs:AddToggle({Id="autoEquip",Title="Auto equip best",Default=taskSelected("equip"),Callback=function(value)setAutoTask("equip",value)end})
eggs:AddButton({Title="Refresh eggs",Callback=function()pcall(refreshOwnedEggChoices)end})
eggStatusLabel=eggs:AddText({Text="Status: Ready."})
pcall(refreshOwnedEggChoices)

shop:AddText({Text="Cash only. Uses available cash. Requires Auto run."})
shop:AddMultiSelect({Id="purchaseTargets",Title="Buy / upgrade",Default=table.clone(state.purchaseTargets),Options={
    {value="cafe",label="Cafe / base"},{value="treadmill",label="Treadmill"},
    {value="bag",label="Bag capacity"},{value="eggs",label="Egg capacity"},{value="trails",label="Trails"},
},Callback=function(values)state.purchaseTargets=table.clone(values)end})
shop:AddToggle({Id="autoUpgrade",Title="Auto upgrade",Default=false,Callback=function(value)state.autoUpgrade=value;purchaseToggleStatus()end})
shop:AddToggle({Id="autoBuy",Title="Auto buy trails",Default=false,Callback=function(value)state.autoBuy=value;purchaseToggleStatus()end})
purchaseStatusLabel=shop:AddText({Text="Purchases: OFF"})

antiAfk=AntiAfk.new({clock=os.clock,getController=function()
    local scripts=player:FindFirstChild("PlayerScripts")
    local client=scripts and scripts:FindFirstChild("Client")
    local controllers=client and client:FindFirstChild("Controllers")
    local target=controllers and controllers:FindFirstChild("AfkController")
    return target and require(target)
end,pulse=function()
    local camera=workspace.CurrentCamera
    assert(camera,"Camera not ready")
    local virtualUser=game:GetService("VirtualUser")
    virtualUser:CaptureController()
    virtualUser:ClickButton2(Vector2.new(0,0),camera.CFrame)
end,notify=function(message)
    if antiAfkLabel then antiAfkLabel:Update({Text="Anti AFK: "..message}) end
end})
settings:AddToggle({Id="antiAfk",Title="Anti AFK",Default=state.antiAfk,Callback=function(value)
    state.antiAfk=value
    antiAfk:SetEnabled(value)
end})
antiAfkLabel=settings:AddText({Text="Anti AFK: ON"})
connections[#connections+1]=player.Idled:Connect(function()antiAfk:OnIdle()end)
antiAfk:SetEnabled(state.antiAfk)

settings:AddToggle({Id="protectHeldEgg",Title="Safe return (no held-egg TP)",Default=true,
    Callback=function(value)state.protectHeldEgg=value end})
returnDelaySlider=settings:AddSlider({Id="snapAfter",Title="Tween → TP delay (seconds)",Min=0.25,Max=10,Step=0.25,Default=1,
    Callback=function(value)state.snapAfter=value end})
returnDistanceSlider=settings:AddSlider({Id="snapDistance",Title="Near → TP distance (studs)",Min=1,Max=200,Step=1,Default=12,
    Callback=function(value)state.snapDistance=value end})
refreshReturnControls()


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
    local nextCountRefresh,nextOwnedRefresh=0,0
    while state.alive do
        if not state.busy then
            state.carryLock=carrying()
            if os.clock()>=nextCountRefresh then refreshCount();nextCountRefresh=os.clock()+1 end
            if refreshOwnedEggChoices and os.clock()>=nextOwnedRefresh then
                pcall(refreshOwnedEggChoices);nextOwnedRefresh=os.clock()+2
            end
            if state.auto then
                if state.resumeAt>os.clock() then failureStatus()
                elseif isRagdolled() then status("Recovering from hit…")
                elseif carrying() then
                    if state.automationBusy and automationCleanup then automationCleanup() end
                    status("Holding an egg. Press Get egg to return.")
                else
                    local eggReady=false
                    if taskSelected("collect") and not state.pointPaused then
                        local egg=findEgg()
                        eggReady=egg~=nil
                        if not eggReady then for _,hint in pairs(state.eggCache) do
                            if table.find(state.rarities,hint.rarity) and os.clock()-hint.seen<=state.cacheTTL and zoneAllowed(hint.zone) then eggReady=true;break end
                        end end
                    end
                    local ownedBusy=false
                    if automationStep and os.clock()>=(state.automationRetryAt or 0) then
                        local ok,result=pcall(automationStep,eggReady)
                        ownedBusy=ok and result==true
                        if not ok then
                            warn("[Egg Helper] Auto task: "..tostring(result))
                            state.automationRetryAt=os.clock()+5
                            if automationCleanup then pcall(automationCleanup) end
                        end
                    end
                    if purchaseStep and not ownedBusy and not state.automationBusy then
                        local ok,err=pcall(purchaseStep)
                        if not ok then
                            warn("[Egg Helper] Cash automation: "..tostring(err))
                            purchaseMemory.nextAt=os.clock()+5
                            purchaseStatus("Waiting for shop recovery")
                        end
                    end
                    if not ownedBusy then
                        if state.pointPaused then status("At finish. Press Get egg or restart Auto.")
                        elseif taskSelected("collect") and eggReady then runAction(true)
                        elseif #state.autoTasks==0 and not state.autoUpgrade and not state.autoBuy then status("Choose an auto task.")
                        elseif taskSelected("collect") and not taskSelected("train") then status("Waiting for selected eggs…")
                        elseif not taskSelected("train") then status("Auto ON.") end
                    end
                end
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
        elseif state.streamOn and ((state.auto and taskSelected("collect")) or state.scanRequested) and state.resumeAt <= os.clock()
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
