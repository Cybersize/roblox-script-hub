-- Restaurant Remote Auto Play / MattLib (1.1.0)
-- For Place 104432981439032. Written from the supplied place snapshot.
-- Uses the same entity actions as the game's interaction controllers.
-- Remote-only: never teleports, walks, changes physics, or fakes GUI signals.
-- Does not buy items, change staff settings, spawn customers, or skip cooking timers.
-- All automation starts OFF. Use Start all after the restaurant finishes loading.

if game.PlaceId ~= 104432981439032 then
    warn("[Restaurant Auto Play] Wrong game; expected place 104432981439032.")
    return
end
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedFolder = assert(ReplicatedStorage:WaitForChild("Shared",20), "Game modules not loaded.")
local client = assert(sharedFolder:WaitForChild("Client",20), "Game client modules not loaded.")
local ClientRestaurant = require(client:WaitForChild("ClientRestaurant",20))
local Network = require(client:WaitForChild("Network",20))
local CustomerTypes = require(sharedFolder.Domain.Directory.Entity.CustomerTypes)

local URL = "https://raw.githubusercontent.com/Cybersize/MattLib/81feb71431f2e8ce6aba74c9a8d179c9c74cbf7f/dist/MattLib.lua"
local downloaded, source = pcall(function() return game:HttpGet(URL) end)
assert(downloaded, "MattLib download failed: " .. tostring(source))
local loader, compileError = loadstring(source,"MattLib")
assert(loader,compileError)
local MattLib = loader()

-- Instance-backed lifetime ownership avoids getgenv identity quirks on Real.
local LIFETIME = "MattRestaurantAutoplay_Lifecycle"
local previous = playerGui:FindFirstChild(LIFETIME)
if previous and previous:IsA("BindableFunction") and previous:GetAttribute("MattRestaurantOwned") then
    local ok, stopped = pcall(function() return previous:Invoke() end)
    assert(ok and stopped == true, "Previous copy stopped locally but has a server call pending. Wait for it to settle before rerunning.")
end

local Core = (function()
-- CORE_BEGIN
-- Pure task planner. Reads the game's entity API; never moves or invokes anything.
local Core = {}
local function present(value) return value ~= nil and value ~= false and value ~= "" end
local function attr(ctx, key) return ctx.player:GetAttribute(key) end
local function owned(ctx, entity)
    return entity ~= nil and not entity:IsDestroyed()
        and entity:GetRestId() == ctx.rest.Id
        and entity:GetOwnerUserId() == ctx.player.UserId
end
local function listHas(entity, key, id)
    for _, row in ipairs(entity:GetSession(key) or {}) do
        if type(row) == "table" and row[1] == id then return true end
    end
    return false
end

function Core.valid(ctx, plan)
    return ctx.rest:GetOwnerUserId() == ctx.player.UserId
        and ctx.rest:GetEntity(plan.entity:GetId()) == plan.entity
        and owned(ctx, plan.entity) and plan.check()
end

function Core.next(ctx)
    if not ctx.rest or ctx.rest:GetOwnerUserId() ~= ctx.player.UserId then
        return nil, "Waiting for your own restaurant."
    end
    local tasks = {}
    local function add(entity, method, args, label, feature, priority, check, phase, age, slot)
        if not ctx.features[feature] or not owned(ctx, entity) then return end
        local key = table.concat({tostring(entity:GetId()), method, tostring(args[1] or ""), phase or ""}, "|")
        if (ctx.cooldowns[key] or 0) > ctx.now then return end
        local task = {entity=entity, method=method, args=args, label=label, feature=feature,
            priority=priority, check=check, key=key, phase=phase, age=tonumber(age) or 0, slot=slot}
        if check() then tasks[#tasks+1] = task end
    end
    local function choose(note)
        table.sort(tasks, function(a,b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            if a.age ~= b.age then return a.age < b.age end
            return a.key < b.key
        end)
        return tasks[1], note or "Waiting for eligible tasks."
    end

    if attr(ctx, "HoldingDirtyDish") == true then
        local entity = ctx.rest:GetEntity(attr(ctx, "TargetDishwasherId"))
        if entity then add(entity, "DepositDishPlayer", {}, "Wash dirty dish", "wash", 1, function()
            return attr(ctx,"HoldingDirtyDish") == true and attr(ctx,"TargetDishwasherId") == entity:GetId()
        end) end
        return choose("Holding a dirty dish; waiting for its dishwasher target or Auto wash.")
    end

    local customerId, recipeId = attr(ctx,"TargetCustomerId"), attr(ctx,"TargetCustomerRecipeId")
    if present(recipeId) then
        local entity = present(customerId) and ctx.rest:GetEntity(customerId)
        if entity then add(entity, "PlaceDeliveryPlayer", {}, "Serve carried food", "serve", 1, function()
            return attr(ctx,"TargetCustomerId") == entity:GetId() and present(attr(ctx,"TargetCustomerRecipeId"))
        end) end
        return choose("Carrying food; waiting for its customer target or Auto serve.")
    end
    if present(customerId) then return nil, "Waiting for carried-food state to finish replicating." end

    local stoveId = attr(ctx, "TargetStoveId")
    local stovePending = present(stoveId)
    local note
    if stovePending then
        local stove = ctx.rest:GetEntity(stoveId)
        if stove then
            local slot = math.max(1, math.floor(tonumber(attr(ctx,"TargetStoveIndex")) or 1))
            local ready = attr(ctx,"TargetStoveReady") == true
            local cooking = stove:GetSession("Cooking" .. slot) == true
            if ready or not cooking then
                local phase = ready and "collect" or "start"
                add(stove, "ActivateStovePlayer", {}, ready and "Collect cooked food" or "Start cooking", "cook", 2, function()
                    if attr(ctx,"TargetStoveId") ~= stoveId then return false end
                    if (tonumber(attr(ctx,"TargetStoveIndex")) or 1) ~= slot then return false end
                    if phase == "collect" then return attr(ctx,"TargetStoveReady") == true end
                    return attr(ctx,"TargetStoveReady") ~= true and stove:GetSession("Cooking" .. slot) ~= true
                end, phase, 0, slot)
            end
        end
        note = "Cooking/assigned ticket pending; waiting for the server's ready signal."
    end

    for _, customer in ipairs(ctx.rest:CollectSubclass("Customer")) do
        local entity = customer
        local status = entity:GetSession("Status")
        if status == ctx.status.ReadyToOrder then
            add(entity,"TakeOrder",{},"Take customer order","orders",30,function()
                return entity:GetSession("Status") == ctx.status.ReadyToOrder
            end,nil,entity.CreateTime)
        elseif status == ctx.status.Queue then
            add(entity,"AssignSeat",{},"Assign customer seat","assign",40,function()
                return entity:GetSession("Status") == ctx.status.Queue
            end,nil,entity.CreateTime)
        end
    end

    -- Never claim a second carried task while a stove/ticket is already assigned.
    if not stovePending then
        for _, stand in ipairs(ctx.rest:CollectSubclass("OrderStand")) do
            local entity = stand
            for _, specification in ipairs({
                {"ReadyList","TakeDeliveryPlayer","Pick up ready food","serve",20},
                {"OrderList","TakeTicketPlayer","Claim cooking ticket","cook",25},
            }) do
                local spec = specification
                for _, value in ipairs(entity:GetSession(spec[1]) or {}) do
                    local row = value
                    if type(row) == "table" and present(row[1]) then
                        local id = row[1]
                        add(entity,spec[2],{id},spec[3],spec[4],spec[5],function()
                            return not present(attr(ctx,"TargetStoveId"))
                                and not present(attr(ctx,"TargetCustomerRecipeId"))
                                and attr(ctx,"HoldingDirtyDish") ~= true and listHas(entity,spec[1],id)
                        end,nil,row[3])
                    end
                end
            end
        end
        for _, seat in ipairs(ctx.rest:CollectSubclass("Seat")) do
            local entity = seat
            if entity:GetSession("DirtyDish") == true and present(entity:GetSession("LinkedTableId")) then
                add(entity,"TakeDirtyDishPlayer",{},"Clear dirty table","clean",35,function()
                    return entity:GetSession("DirtyDish") == true
                        and not present(attr(ctx,"TargetStoveId"))
                        and not present(attr(ctx,"TargetCustomerRecipeId"))
                        and attr(ctx,"HoldingDirtyDish") ~= true
                end,nil,entity:GetSession("DirtyDishTime"))
            end
        end
    end
    return choose(note)
end

function Core.confirmed(ctx, task)
    local entity, method = task.entity, task.method
    if method == "AssignSeat" then
        return entity:GetSession("Status") ~= ctx.status.Queue and present(entity:GetSession("SeatId"))
    elseif method == "TakeOrder" then
        return entity:GetSession("Status") == ctx.status.WaitingForFood or entity:GetSession("Status") == ctx.status.Eating
    elseif method == "TakeTicketPlayer" then
        return present(attr(ctx,"TargetStoveId"))
    elseif method == "TakeDeliveryPlayer" then
        return attr(ctx,"TargetCustomerId") == task.args[1] and present(attr(ctx,"TargetCustomerRecipeId"))
    elseif method == "PlaceDeliveryPlayer" then
        return not present(attr(ctx,"TargetCustomerRecipeId"))
    elseif method == "TakeDirtyDishPlayer" then
        return attr(ctx,"HoldingDirtyDish") == true
    elseif method == "DepositDishPlayer" then
        return attr(ctx,"HoldingDirtyDish") ~= true
    elseif method == "ActivateStovePlayer" then
        if task.phase == "collect" then return attr(ctx,"TargetStoveId") ~= entity:GetId() end
        return entity:GetSession("Cooking" .. tostring(task.slot)) == true or attr(ctx,"TargetStoveReady") == true
    end
    return false
end
return Core

-- CORE_END
end)()

local state = {
    alive=true, enabled=false, busy=false, inFlight=false, epoch=0,
    interval=0.75, nextAction=0, cooldowns={}, accepted=0, confirmed=0, rejected=0,
    features={assign=true,orders=true,cook=true,serve=true,clean=true,wash=true},
}
local app, statusLabel, totalsLabel, summaryLabel
local connections, controls = {}, {}
local lifetime = Instance.new("BindableFunction")
lifetime.Name=LIFETIME
lifetime:SetAttribute("MattRestaurantOwned",true)

local function status(message)
    if state.alive and statusLabel then statusLabel:Update({Text="Status: " .. message}) end
end
local function setEnabled(value)
    state.enabled=value
    state.epoch=state.epoch+1
    status(value and "Running — remote calls only." or (state.inFlight and "Stopped. An already-sent server call is still pending." or "Stopped."))
end
local function cleanup()
    if state.alive then
        state.alive=false
        state.enabled=false
        state.epoch=state.epoch+1
        for _, connection in ipairs(connections) do connection:Disconnect() end
        if app then app:Destroy() end
    end
    -- Keep the marker while a pending InvokeServer could still complete.
    if not state.inFlight then lifetime:Destroy() end
    return not state.inFlight
end
lifetime.OnInvoke=cleanup
connections[#connections+1]=lifetime.Destroying:Connect(cleanup)
lifetime.Parent=playerGui

app=MattLib.new({id="matt-restaurant-autoplay",theme="Dark",reducedMotion=true})

local function context()
    local rest=ClientRestaurant.GetLocal()
    if not rest or rest:WasDestroyed() or rest:GetOwnerUserId() ~= player.UserId then return nil end
    return {rest=rest,player=player,status=CustomerTypes.Status,features=state.features,
        cooldowns=state.cooldowns,now=os.clock()}
end
local function livingCharacter()
    local character=player.Character
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health>0 then return character,humanoid end
end
local function refreshTotals()
    if not state.alive then return end
    totalsLabel:Update({Text=string.format("Accepted: %d | State-confirmed: %d | Rejected/errors: %d",state.accepted,state.confirmed,state.rejected)})
    local ctx=context()
    if not ctx then summaryLabel:Update({Text="Waiting for your own restaurant."}); return end
    local queued,orders,dirty,tickets,ready=0,0,0,0,0
    for _, customer in ipairs(ctx.rest:CollectSubclass("Customer")) do
        if customer:GetSession("Status")==ctx.status.Queue then queued=queued+1 end
        if customer:GetSession("Status")==ctx.status.ReadyToOrder then orders=orders+1 end
    end
    for _, seat in ipairs(ctx.rest:CollectSubclass("Seat")) do
        if seat:GetSession("DirtyDish")==true then dirty=dirty+1 end
    end
    for _, stand in ipairs(ctx.rest:CollectSubclass("OrderStand")) do
        tickets=tickets+#(stand:GetSession("OrderList") or {})
        ready=ready+#(stand:GetSession("ReadyList") or {})
    end
    summaryLabel:Update({Text=string.format("Queue: %d | Need orders: %d | Tickets: %d | Ready food: %d | Dirty seats: %d",queued,orders,tickets,ready,dirty)})
end

local function invokeJob(plan)
    -- The game resolves/caches and may rename its remotes. Reuse its transport.
    -- Network.Invoke routes this RemoteFunction to InvokeServer with these args.
    return Network.Invoke("Entity_Invoke",plan.entity:GetId(),plan.method,table.unpack(plan.args))
end

local function runNext()
    if not state.alive or state.busy then return end
    local ctx=context()
    if not ctx then status("Waiting for your own restaurant."); return end
    local character,humanoid=livingCharacter()
    if not character then status("Waiting for a living character."); return end
    local plan,note=Core.next(ctx)
    if not plan then status(note); return end
    state.busy=true
    local epoch=state.epoch
    local function isCurrent()
        return state.alive and state.epoch==epoch and player.Character==character
            and humanoid.Parent==character and humanoid.Health>0
            and ClientRestaurant.GetLocal()==ctx.rest and not ctx.rest:WasDestroyed()
            and ctx.rest:GetOwnerUserId()==player.UserId
    end
    task.spawn(function()
        local ok,reason=xpcall(function()
            if not isCurrent() then return end
            status("Remote: " .. plan.label .. "...")
            if not isCurrent() or not state.features[plan.feature] or not Core.valid(ctx,plan) then return end
            state.cooldowns[plan.key]=os.clock()+2
            state.inFlight=true
            local settled=false
            task.delay(10,function()
                if state.alive and state.enabled and not settled then
                    status("Server call pending: " .. plan.label .. ". No duplicate request will be sent.")
                end
            end)
            local invoked,accepted,response=pcall(invokeJob,plan)
            settled=true
            state.inFlight=false
            if invoked and accepted==true then
                state.accepted=state.accepted+1
                local deadline=os.clock()+1.5
                local confirmed=false
                repeat
                    if not isCurrent() then break end
                    confirmed=Core.confirmed(ctx,plan)
                    if confirmed then break end
                    task.wait(0.1)
                until os.clock()>=deadline
                if confirmed then state.confirmed=state.confirmed+1 end
                if isCurrent() then status(plan.label .. (confirmed and " — confirmed." or " — server accepted; awaiting replication.")) end
            else
                state.rejected=state.rejected+1
                state.cooldowns[plan.key]=os.clock()+4
                local explanation=invoked and response or accepted
                if isCurrent() then status(plan.label .. " rejected: " .. tostring(explanation or "request_failed")) end
            end
        end,debug.traceback)
        state.inFlight=false
        state.busy=false
        state.nextAction=os.clock()+state.interval
        if not ok then
            state.rejected=state.rejected+1
            state.cooldowns[plan.key]=os.clock()+4
            warn("[Restaurant Auto Play] " .. tostring(reason))
            if isCurrent() then status("Task error; see executor console. Retrying other eligible tasks.") end
        end
        if state.alive then pcall(refreshTotals) else lifetime:Destroy() end
    end)
end

local window=app:CreateWindow({Id="restaurant",Title="Restaurant Remote Auto Play",Design="MintGlass",
    Size={680,550},OpenKey="RightShift",Wallpaper=false,OnClose=cleanup})
local main=window:AddTab({Title="Auto play"}):AddSection({Title="Control"})
statusLabel=main:AddParagraph({Text="Status: Stopped. Load your restaurant, then press Start all."})
summaryLabel=main:AddParagraph({Text="Loading restaurant state..."})
totalsLabel=main:AddParagraph({Text="Accepted: 0 | State-confirmed: 0 | Rejected/errors: 0"})
controls.master=main:AddToggle({Id="enabled",Title="Auto play",Default=false,Callback=setEnabled})
main:AddButton({Title="Start all",Variant="primary",Callback=function()
    for _,control in pairs(controls.features) do control:SetValue(true) end
    controls.master:SetValue(true)
end})
main:AddButton({Title="Stop",Callback=function()
    if state.enabled then controls.master:SetValue(false) else setEnabled(false) end
end})
main:AddButton({Title="Run next task once",Callback=function()
    if state.enabled then status("Stop Auto play before running a single task.") else runNext() end
end})
main:AddParagraph({Text="Remote-only: your character is never moved. Only your own restaurant is handled. Cooking uses the normal server timer. Stop cancels future actions; already-sent requests may still finish. RightShift hides/shows this menu."})

local tasks=window:AddTab({Title="Tasks"}):AddSection({Title="Choose duties"})
controls.features={}
for _,spec in ipairs({
    {"assign","Auto assign customer seats"},{"orders","Auto take customer orders"},
    {"cook","Auto claim tickets, cook and collect"},{"serve","Auto pick up and serve food"},
    {"clean","Auto clear dirty tables"},{"wash","Auto deposit dirty dishes / wash"},
}) do
    local key,title=spec[1],spec[2]
    controls.features[key]=tasks:AddToggle({Id=key,Title=title,Default=true,Callback=function(value) state.features[key]=value end})
end
tasks:AddParagraph({Text="Carried food and dirty dishes are finished before starting another task. While your stove cooks, seat assignment and order taking may continue. To complete a full cycle, leave Cook, Serve, Clear and Wash enabled."})
local settings=window:AddTab({Title="Settings"}):AddSection({Title="Remote-only & pace"})
settings:AddParagraph({Text="Transport: Entity_Invoke RemoteFunction. No teleporting, walking, physics changes, proximity-prompt firing or GUI signal simulation."})
settings:AddSlider({Id="interval",Title="Pause between actions (seconds)",Min=0.5,Max=3,Step=0.25,Default=0.75,
    Callback=function(value) state.interval=value end})
settings:AddParagraph({Text="Server validation still applies, including any distance checks. Rejections such as out-of-range tasks, staff-claimed orders, occupied seats, missing ingredients or full sinks are shown in Status and backed off rather than spammed. No ingredient farming or staff configuration is included."})
settings:AddButton({Title="Unload",Callback=cleanup})
connections[#connections+1]=player.CharacterAdded:Connect(function()
    state.epoch=state.epoch+1
    if state.enabled then status("Respawned; waiting for character and restaurant.") end
end)
pcall(refreshTotals)
task.spawn(function()
    local nextSummary,nextPrune=0,0
    while state.alive do
        local now=os.clock()
        if now>=nextPrune then
            for key,expires in pairs(state.cooldowns) do if expires<=now then state.cooldowns[key]=nil end end
            nextPrune=now+15
        end
        if now>=nextSummary then pcall(refreshTotals); nextSummary=now+2 end
        if state.enabled and not state.busy and now>=state.nextAction then
            state.nextAction=now+state.interval
            local ok,reason=pcall(runNext)
            if not ok then status("Planner error: " .. tostring(reason)) end
        end
        task.wait(0.15)
    end
end)
