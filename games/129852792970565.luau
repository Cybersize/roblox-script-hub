-- Egg teleport / pickup for Place 129852792970565.
-- Based on the supplied .rbxl: Runtime.WorldEggs / DroppedEggs,
-- Rarity / EggId / CarriedBy attributes, and StealPrompt / PickUpPrompt.
-- Requires a client executor with game:HttpGet and loadstring.
-- No purchase/admin remotes are used. Pickup must be accepted by the server.

local PLACE_ID = 129852792970565
if game.PlaceId ~= PLACE_ID then
    warn("[Egg Teleport] This script is for place " .. tostring(PLACE_ID))
    return
end

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Pin the UI API to the version inspected for this script.
local LIB_URL = "https://raw.githubusercontent.com/Cybersize/MattLib/81feb71431f2e8ce6aba74c9a8d179c9c74cbf7f/dist/MattLib.lua"
local downloaded, source = pcall(function() return game:HttpGet(LIB_URL) end)
assert(downloaded, "[Egg Teleport] MattLib download failed: " .. tostring(source))
local loader, compileError = loadstring(source, "MattLib")
assert(loader, compileError)
local MattLib = loader()

-- An instance-backed cleanup handle also works across separate executor chunks.
local LIFETIME_NAME = "MattEggTeleport_Lifecycle"
local old = playerGui:FindFirstChild(LIFETIME_NAME)
if old and old:IsA("BindableFunction") and old:GetAttribute("MattEggOwned") then
    local ok, reason = pcall(function() old:Invoke() end)
    assert(ok, "[Egg Teleport] Previous copy could not stop: " .. tostring(reason))
end

local state = {
    alive = true, busy = false, auto = false,
    rarity = "All", returnAfter = true, saved = nil,
}
local app, statusLabel, countLabel, activePrompt, destroyConnection
local lifetime = Instance.new("BindableFunction")
lifetime.Name = LIFETIME_NAME
lifetime:SetAttribute("MattEggOwned", true)

local function endHold()
    if activePrompt then
        pcall(function() activePrompt:InputHoldEnd() end)
        activePrompt = nil
    end
end

local function cleanup()
    if not state.alive then return end
    state.alive, state.auto = false, false
    endHold()
    if destroyConnection then destroyConnection:Disconnect() end
    if app then app:Destroy() end
    lifetime:Destroy()
end
lifetime.OnInvoke = cleanup
destroyConnection = lifetime.Destroying:Connect(cleanup)
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
        and (state.rarity == "All" or egg:GetAttribute("Rarity") == state.rarity)
end

local function nearestEgg()
    local _, root = characterParts()
    local runtime = workspace:FindFirstChild("Runtime")
    local best, bestPrompt, bestDistance, count = nil, nil, math.huge, 0
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
                        if distance < bestDistance then
                            best, bestPrompt, bestDistance = egg, prompt, distance
                        end
                    end
                end
            end
        end
    end
    return best, bestPrompt, count
end

local function refreshCount()
    local _, _, count = nearestEgg()
    if state.alive and countLabel then
        countLabel:Update({ Text = "Available matching eggs: " .. tostring(count) })
    end
end

local function moveRoot(root, destination)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    root.CFrame = destination
end

local function runAction(collect)
    if not state.alive or state.busy then return end
    if collect and carrying() then
        status("Already carrying an egg. Bank it before picking up another.")
        return
    end
    local character, root, humanoid = characterParts()
    if not root then status("Waiting for a living character."); return end
    local egg, prompt = nearestEgg()
    if not egg then status("No available " .. state.rarity .. " eggs are replicated."); return end

    state.busy = true
    state.saved = root.CFrame
    local origin, shouldReturn = root.CFrame, collect and state.returnAfter
    local function current()
        return state.alive and player.Character == character
            and root.Parent == character and humanoid.Health > 0
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
            moveRoot(root, CFrame.lookAt(destination, position))
            local rarity = tostring(egg:GetAttribute("Rarity") or "Unknown")
            status("Teleported to " .. rarity .. " egg.")
            if not collect then return end

            task.wait(0.35) -- Let the new character position replicate first.
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
                    or egg:GetAttribute("CarriedBy") == player.UserId
                if received then break end
                task.wait(0.05)
            until os.clock() >= deadline
            status(received and ("Picked up " .. rarity .. " egg.")
                or "Pickup not confirmed by server; check eligibility or try again.")
        end, debug.traceback)
        endHold()
        if shouldReturn and current() then
            local returned, returnError = pcall(moveRoot, root, origin)
            if not returned then warn("[Egg Teleport] Return failed: " .. tostring(returnError)) end
        end
        state.busy = false
        if not ok then
            warn("[Egg Teleport] " .. tostring(reason))
            status("Action failed. See executor console.")
        end
    end)
end

local window = app:CreateWindow({
    Id = "eggs", Title = "Egg Teleport", Design = "MintGlass",
    Size = { 560, 540 }, OpenKey = "RightShift", Wallpaper = false,
    OnClose = cleanup,
})
local tab = window:AddTab({ Title = "Eggs" })
local section = tab:AddSection({ Title = "Teleport & pickup" })

section:AddDropdown({
    Id = "rarity", Title = "Select rarity", Default = "All",
    Options = {
        "All", "Common", "Rare", "Epic", "Legendary", "Mythic", "Relic",
        "Exotic", "Ascendant", "Secret", { value = "SuperSecret", label = "Super Secret" }, "Divine",
    },
    Callback = function(value)
        state.rarity = value
        refreshCount()
        status("Rarity: " .. (value == "SuperSecret" and "Super Secret" or value))
    end,
})
countLabel = section:AddText({ Text = "Available matching eggs: 0" })
statusLabel = section:AddParagraph({ Text = "Status: Ready." })
section:AddButton({ Title = "Teleport to nearest egg", Callback = function() runAction(false) end })
section:AddButton({ Title = "Teleport + get egg", Variant = "primary", Callback = function() runAction(true) end })
section:AddToggle({
    Id = "return", Title = "Return after pickup attempt", Default = true,
    Callback = function(value) state.returnAfter = value end,
})
section:AddToggle({
    Id = "auto", Title = "Auto get selected rarity", Default = false,
    Callback = function(value)
        state.auto = value
        status(value and "Auto enabled. Pauses while carrying an egg." or "Auto disabled; an active attempt may finish.")
    end,
})
section:AddButton({ Title = "Return to previous position", Callback = function()
    if state.busy then return end
    local _, root = characterParts()
    if root and state.saved then moveRoot(root, state.saved) end
end })
section:AddParagraph({ Text = "Start in your safe/banking area if returning after pickup. Auto waits until CarryingEgg clears. Only currently replicated eggs can be found. RightShift hides/shows this menu." })
section:AddButton({ Title = "Unload", Callback = cleanup })

refreshCount()
task.spawn(function()
    while state.alive do
        if not state.busy then
            refreshCount()
            if state.auto then
                if carrying() then status("Carrying an egg; waiting for you to bank it.")
                else runAction(true) end
            end
        end
        task.wait(2)
    end
end)
