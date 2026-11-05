-- Egg teleport / pickup / tween-to-bank for Place 129852792970565 (1.1.1).
-- Based on the supplied .rbxl: Runtime.WorldEggs / DroppedEggs,
-- Rarity / EggId / CarriedBy attributes, and StealPrompt / PickUpPrompt.
-- Requires a client executor with game:HttpGet and loadstring.
-- No purchase/admin remotes are used. Pickup must be accepted by the server.
-- Empty-handed teleports only. Carry return is an adjustable linear tween,
-- not a guaranteed server-check bypass. No speed stats/physics flags are changed.

local PLACE_ID = 129852792970565
if game.PlaceId ~= PLACE_ID then
    warn("[Egg Teleport] This script is for place " .. tostring(PLACE_ID))
    return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Pin the UI API to the version inspected for this script.
local LIB_URL = "https://raw.githubusercontent.com/Cybersize/MattLib/81feb71431f2e8ce6aba74c9a8d179c9c74cbf7f/dist/MattLib.lua"
local downloaded, source = pcall(function() return game:HttpGet(LIB_URL) end)
assert(downloaded, "[Egg Teleport] MattLib download failed: " .. tostring(source))
local loader, compileError = loadstring(source, "MattLib")
assert(loader, compileError)
local MattLib = loader()

local RARITIES = {"Common", "Rare", "Epic", "Legendary", "Mythic", "Relic", "Exotic", "Ascendant", "Secret", "SuperSecret", "Divine"}
local RARITY_RANK = {}
for rank, name in ipairs(RARITIES) do RARITY_RANK[name] = rank end

-- An instance-backed cleanup handle also works across separate executor chunks.
local LIFETIME_NAME = "MattEggTeleport_Lifecycle"
local old = playerGui:FindFirstChild(LIFETIME_NAME)
if old and old:IsA("BindableFunction") and old:GetAttribute("MattEggOwned") then
    local ok, reason = pcall(function() old:Invoke() end)
    assert(ok, "[Egg Teleport] Previous copy could not stop: " .. tostring(reason))
end

local state = {
    alive = true, busy = false, auto = false, epoch = 0, carryLock = false,
    rarities = table.clone(RARITIES), priority = "Highest rarity first", tweenAfter = true, saved = nil,
    speedMode = "Match carry speed", customSpeed = 100,
    banks = 0, slips = 0, fault = nil,
}
local app, statusLabel, countLabel, activePrompt, activeTween, autoToggle, speedSlider
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

local function status(message)
    if state.alive and statusLabel then
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
-- RETURN_POLICY_END

local function pauseAuto(message)
    state.fault = message
    state.auto = false
    if autoToggle then autoToggle:SetValue(false) end
    cancelTween()
    status(message)
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
    local _, root = characterParts()
    local runtime = workspace:FindFirstChild("Runtime")
    local best, bestPrompt, bestDistance, bestRank, count = nil, nil, math.huge, -1, 0
    if not runtime then return nil, nil, 0 end
    for _, name in ipairs({ "WorldEggs", "DroppedEggs" }) do
        local folder = runtime:FindFirstChild(name)
        if folder then
            for _, egg in ipairs(folder:GetChildren()) do
                if available(egg) then
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
        countLabel:Update({ Text = "Available matching eggs: " .. tostring(count) })
    end
end

local function moveRoot(root, destination)
    if not ReturnPolicy.canTeleport(player:GetAttribute("CarryingEgg"), state.carryLock) then
        return false, "Instant teleport blocked while holding an egg. Use tween-to-bank."
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

local function tweenToBank(id, root, humanoid, current)
    local goal = bankDestination()
    local bankBaseline, slipBaseline = state.banks, state.slips
    local rejectBaseline = tonumber(player:GetAttribute("RejectCount")) or 0
    local deadline, clearedAt, bankConfirmed = os.clock() + 180, nil, false
    while current() and os.clock() < deadline do
        local currentId = player:GetAttribute("CarryingEgg")
        local result = ReturnPolicy.result(id, currentId, state.banks, bankBaseline, state.slips,
            slipBaseline, tonumber(player:GetAttribute("RejectCount")) or 0, rejectBaseline)
        if result == "banked" then bankConfirmed = true end
        if result == "rejected" then cancelTween(); return false, "Server rejected the return. Auto paused; reduce tween speed or return manually." end
        if not bankConfirmed and (result == "unconfirmed" or state.banks > bankBaseline) then
            cancelTween()
            clearedAt = clearedAt or os.clock()
            if os.clock() - clearedAt > 3 then
                return false, "Carry state changed without a complete bank confirmation. Auto paused."
            end
            task.wait(0.05)
        else
            clearedAt = nil
            local speed = ReturnPolicy.speed(state.customSpeed, humanoid.WalkSpeed, state.speedMode == "Match carry speed")
            if not speed then return false, "Carry speed is zero; tween stopped." end
            local remaining = (goal - root.Position).Magnitude
            if remaining < 0.15 then
                cancelTween()
                if bankConfirmed then return true, "Bank confirmed; fixed tween destination reached." end
                local untilTime = os.clock() + 3
                repeat
                    if not current() then return false, "Return cancelled." end
                    if state.banks > bankBaseline and not carrying() then return true, "Bank confirmed; fixed tween destination reached." end
                    if state.slips > slipBaseline then return false, "Egg slipped back; auto paused." end
                    task.wait(0.05)
                until os.clock() >= untilTime
                return false, "Reached the bank area, but the server did not confirm a bank. Auto paused."
            end
            local origin = root.Position
            local nextPoint = origin:Lerp(goal, math.min(1, 24 / remaining))
            local direction = Vector3.new(goal.X - nextPoint.X, 0, goal.Z - nextPoint.Z)
            if direction.Magnitude < 0.01 then direction = Vector3.new(-1, 0, 0) end
            local duration = (nextPoint - origin).Magnitude / speed
            local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear),
                {CFrame = CFrame.lookAt(nextPoint, nextPoint + direction)})
            activeTween = tween
            status(string.format("Tweening to bank: %.1f studs/s%s", speed,
                state.speedMode == "Match carry speed" and " (carry-speed cap)" or " (custom; may reset)"))
            tween:Play()
            local expires = os.clock() + duration + 1
            while current() and os.clock() < expires and tween.PlaybackState ~= Enum.PlaybackState.Completed do
                local bankCleared = state.banks > bankBaseline and not carrying()
                if (not bankCleared and (player:GetAttribute("CarryingEgg") ~= id or state.banks > bankBaseline))
                    or state.slips > slipBaseline
                    or (tonumber(player:GetAttribute("RejectCount")) or 0) > rejectBaseline then break end
                task.wait(0.05)
            end
            cancelTween()
            if not current() then return false, "Return cancelled." end
            if (bankConfirmed or player:GetAttribute("CarryingEgg") == id)
                and state.slips == slipBaseline
                and (tonumber(player:GetAttribute("RejectCount")) or 0) <= rejectBaseline
                and (root.Position - nextPoint).Magnitude > 6 then
                return false, "Tween was blocked or corrected. Auto paused; no snap-back retry was attempted."
            end
        end
    end
    cancelTween()
    return false, current() and "Return timed out; auto paused." or "Return cancelled."
end

local function runAction(collect)
    if not state.alive or state.busy then return end
    if carrying() or state.carryLock then
        status("Holding an egg: instant teleports are blocked. Use Tween current egg to bank.")
        return
    end
    local character, root, humanoid = characterParts()
    if not root then status("Waiting for a living character."); return end
    if collect and state.tweenAfter and not state.bankSensor then
        status("Bank feedback remote is not ready. Retry after the game loads."); return
    end
    local egg, prompt = findEgg()
    if not egg then status("No available eggs match the selected rarities."); return end

    state.busy = true
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
            status("Picked up " .. rarity .. " egg. No instant return will run.")
            if state.tweenAfter and current() then
                local banked, result = tweenToBank(id, root, humanoid, current)
                if banked then status(result) elseif current() then pauseAuto(state.fault or result) end
            end
        end, debug.traceback)
        endHold()
        cancelTween()
        state.carryLock = carrying()
        state.busy = false
        if not ok then
            warn("[Egg Teleport] " .. tostring(reason))
            pauseAuto("Action failed. See executor console. No instant carry return was attempted.")
        elseif state.fault then
            status(state.fault)
        end
    end)
end

local function tweenHeldEgg()
    if not state.alive or state.busy then return end
    local id = player:GetAttribute("CarryingEgg")
    local character, root, humanoid = characterParts()
    if not carrying() or not root then status("No held egg / living character."); return end
    if not state.bankSensor then status("Bank feedback remote is not ready."); return end
    state.busy, state.carryLock, state.fault = true, true, nil
    local epoch = state.epoch
    local function current()
        return state.alive and state.epoch == epoch and player.Character == character
            and root.Parent == character and humanoid.Health > 0
            and player:GetAttribute("Ragdolled") ~= true
    end
    task.spawn(function()
        local ok, banked, message = pcall(tweenToBank, id, root, humanoid, current)
        cancelTween()
        state.busy, state.carryLock = false, carrying()
        if not ok then pauseAuto("Tween error: " .. tostring(banked))
        elseif current() then
            if banked then status(message) else pauseAuto(state.fault or message) end
        elseif state.fault then status(state.fault) end
    end)
end

local window = app:CreateWindow({
    Id = "eggs", Title = "Egg Collector · Tween Return", Design = "MintGlass",
    Size = { 640, 620 }, OpenKey = "RightShift", Wallpaper = false,
    OnClose = cleanup,
})
local tab = window:AddTab({ Title = "Eggs" })
local section = tab:AddSection({ Title = "Select eggs & collect" })

local raritySelect = section:AddMultiSelect({
    Id = "rarities", Title = "Rarities (multi-select)", Default = table.clone(RARITIES),
    Options = {
        "Common", "Rare", "Epic", "Legendary", "Mythic", "Relic",
        "Exotic", "Ascendant", "Secret", { value = "SuperSecret", label = "Super Secret" }, "Divine",
    },
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
section:AddButton({ Title = "Get egg + tween to bank", Variant = "primary", Callback = function() runAction(true) end })
section:AddToggle({
    Id = "tweenReturn", Title = "Tween to bank after pickup", Default = true,
    Callback = function(value) state.tweenAfter = value end,
})
autoToggle = section:AddToggle({
    Id = "auto", Title = "Auto collect selected rarities", Default = false,
    Callback = function(value)
        state.auto = value
        state.epoch = state.epoch + 1
        if value then state.fault = nil else cancelTween(); endHold() end
        status(value and ("Auto enabled; priority: " .. state.priority .. ".") or "Auto stopped. No instant return will run.")
    end,
})
section:AddParagraph({Text = "Teleport is only used while empty-handed. Both return controls target the fixed position (-208.130, 4.238, 399.946), never your saved origin. RightShift toggles this menu."})
section:AddButton({Title = "Unload", Callback = cleanup})

local settings = window:AddTab({Title = "Tween & selection"}):AddSection({Title = "Return speed"})
settings:AddDropdown({Id = "speedMode", Title = "Tween speed mode", Default = "Match carry speed",
    Options = {"Match carry speed", "Custom speed (may reset)"}, Callback = function(value)
        state.speedMode = value
        if speedSlider then speedSlider:Update({Disabled = value == "Match carry speed"}) end
    end})
speedSlider = settings:AddSlider({Id = "customSpeed", Title = "Custom tween speed (studs/sec)",
    Min = 10, Max = 250, Step = 5, Default = 100, Disabled = true,
    Callback = function(value) state.customSpeed = value end})
settings:AddParagraph({Text = "Match carry speed uses 90% of the current Humanoid.WalkSpeed. Custom mode can be faster, but the server may still reset the egg. No carry speed, collision, anchoring or network settings are changed. Auto pauses on a reset or an unconfirmed bank."})
settings:AddButton({Title = "Tween current egg to bank", Callback = tweenHeldEgg})
settings:AddButton({ Title = "Return previous position (empty hands only)", Callback = function()
    if state.busy then return end
    local _, root = characterParts()
    if root and state.saved then
        local ok, reason = moveRoot(root, state.saved)
        if not ok then status(reason) end
    end
end })
settings:AddButton({Title = "Stop current action", Callback = function()
    state.epoch = state.epoch + 1
    autoToggle:SetValue(false)
    cancelTween(); endHold()
    status("Action stopped. Held eggs are not teleported or dropped.")
end})
settings:AddButton({Title = "Select all rarities", Callback = function() raritySelect:SetValue(table.clone(RARITIES)) end})
settings:AddButton({Title = "Clear rarity selection", Callback = function() raritySelect:SetValue({}) end})

local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local effects = remotes and remotes:WaitForChild("PlayEffect", 10)
if effects and effects:IsA("RemoteEvent") then
    state.bankSensor = true
    connections[#connections+1] = effects.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" or payload.userId ~= player.UserId then return end
        if payload.key == "EggBanked" then state.banks = state.banks + 1
        elseif payload.key == "GuardCatch" and state.busy then
            state.slips = state.slips + 1
            pauseAuto("Guard caught you. Auto paused; no instant return will run.")
        end
    end)
end
local notifications = remotes and remotes:FindFirstChild("Notify")
if notifications and notifications:IsA("RemoteEvent") then
    connections[#connections+1] = notifications.OnClientEvent:Connect(function(payload)
        local text = type(payload) == "table" and payload.text
        if type(text) == "string" and text:lower():find("slipped back", 1, true) then
            state.slips = state.slips + 1
            if state.busy or state.auto then pauseAuto("Egg slipped back. Auto paused; lower the custom tween speed or return manually.") end
        end
    end)
end
local lastReject = tonumber(player:GetAttribute("RejectCount")) or 0
connections[#connections+1] = player:GetAttributeChangedSignal("RejectCount"):Connect(function()
    local value = tonumber(player:GetAttribute("RejectCount")) or 0
    if value > lastReject and state.busy then pauseAuto("Server rejection counter increased. Auto paused; return was not confirmed.") end
    lastReject = value
end)
connections[#connections+1] = player:GetAttributeChangedSignal("CarryingEgg"):Connect(function()
    if not state.busy and not carrying() then state.carryLock = false end
end)
connections[#connections+1] = player.CharacterAdded:Connect(function()
    state.epoch = state.epoch + 1
    cancelTween(); endHold()
    pauseAuto("Respawned. Auto paused; restart after your character loads.")
end)

refreshCount()
task.spawn(function()
    while state.alive do
        if not state.busy then
            state.carryLock = carrying()
            refreshCount()
            if state.auto then
                if carrying() then status("Carrying an egg; waiting for you to bank it.")
                else runAction(true) end
            end
        end
        task.wait(2)
    end
end)
