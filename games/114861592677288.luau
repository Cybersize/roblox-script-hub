-- Destroy Grandma key collector 1.0.0. Hard target: 3 keys, even with ExtraKeys.
-- Uses the observed native Warp PickupKey payload; never opens chests or buys passes.
local PLACE_ID=114861592677288
if game.PlaceId~=PLACE_ID then warn("[Key Collector] Unsupported place");return end
local hubContext=...
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local TweenService=game:GetService("TweenService")
local player=Players.LocalPlayer
local gui=player:WaitForChild("PlayerGui")
local LIB_URL="https://raw.githubusercontent.com/Cybersize/MattLib/81feb71431f2e8ce6aba74c9a8d179c9c74cbf7f/dist/MattLib.lua"
local librarySource=type(hubContext)=="table" and type(hubContext.httpGet)=="function" and hubContext.httpGet(LIB_URL) or game:HttpGet(LIB_URL)
local compile,compileError=loadstring(librarySource,"MattLib")
assert(compile,compileError)
local MattLib=compile()
local KeyPolicy=(function()
-- Pure normalized key-collector gate. No services, movement or remote dispatch.
-- inRound should be Status.IsInGame, NOT HasJoinedRound or RoundData.IsRound.
-- isGranny=false means CONFIRMED Status.Team=="Toddler"; nil means unknown/other team.
local KeyPolicy={CAP=3}
function KeyPolicy.validCount(value)
    return type(value)=="number" and value==value and value>=0 and value<math.huge and value%1==0
end
function KeyPolicy.decide(context)
    if type(context)~="table" then return "wait","Waiting for player data" end
    if not KeyPolicy.validCount(context.count) then return "wait","Waiting for key count" end
    if context.count>=KeyPolicy.CAP then return "full","Keys full (3/3)" end
    if context.enabled~=true then return "stopped","Stopped" end
    if context.alive~=true then return "wait","Waiting for character" end
    if context.isGranny==true then return "wait","Keys are for toddlers" end
    if context.isGranny~=false then return "wait","Waiting for toddler role" end
    if context.inRound~=true then return "wait","Waiting to join the game" end
    return "collect","Collecting keys"
end
function KeyPolicy.canRequest(context)
    return KeyPolicy.decide(context)=="collect"
end
return KeyPolicy

end)()
local HANDLE="MattKeyCollector114861592677288"
local previous=gui:FindFirstChild(HANDLE)
if previous and previous:IsA("BindableFunction") and previous:GetAttribute("KeyCollectorOwned") then
    local stopped,reason=pcall(function()previous:Invoke("unload")end)
    assert(stopped,"Previous key collector could not stop: "..tostring(reason))
end
local state={alive=true,auto=false,epoch=0,mode="teleport",speed=60,pending=nil}
local app,autoToggle,countLabel,statusLabel,speedSlider,activeTween
local utility,transport,counter,counterConnection,destroyConnection
local blockedUntil=setmetatable({},{__mode="k"})
local lifetime=Instance.new("BindableFunction")
lifetime.Name=HANDLE;lifetime:SetAttribute("KeyCollectorOwned",true)
local lastStatus,lastCount
local function status(message)
    if state.alive and statusLabel and message~=lastStatus then
        lastStatus=message;statusLabel:Update({Text="Status: "..message})
    end
end
local function cancelMove()
    local tween=activeTween;activeTween=nil
    if tween then pcall(function()tween:Cancel();tween:Destroy()end)end
end
local function setAuto(value,message)
    state.auto=value==true and state.alive
    state.epoch+=1;cancelMove()
    if not state.auto and autoToggle then autoToggle:SetValue(false)end
    status(message or (state.auto and "Collecting to 3/3..." or "Stopped."))
end
local function cleanup()
    if not state.alive then return end
    state.auto,state.alive=false,false;state.epoch+=1;cancelMove()
    if counterConnection then counterConnection:Disconnect();counterConnection=nil end
    if destroyConnection then destroyConnection:Disconnect();destroyConnection=nil end
    if app then app:Destroy()end
    lifetime:Destroy()
end
lifetime.OnInvoke=cleanup
destroyConnection=lifetime.Destroying:Connect(cleanup)
lifetime.Parent=gui
local function countValue()
    local folder=player:FindFirstChild("Status")
    local value=folder and folder:FindFirstChild("Keys")
    local count=value and (value:IsA("IntValue") or value:IsA("NumberValue")) and value.Value
    return KeyPolicy.validCount(count) and count or nil,value
end
local function refreshCount()
    local count=countValue()
    local label="Keys: "..(count and tostring(count) or "?").."/3"
    if countLabel and label~=lastCount then lastCount=label;countLabel:Update({Text=label})end
    if count and count>=KeyPolicy.CAP and state.auto then setAuto(false,"Full 3/3 - finished.")end
end
local function bindCounter()
    local _,nextCounter=countValue()
    if counter==nextCounter then return end
    if counterConnection then counterConnection:Disconnect();counterConnection=nil end
    counter=nextCounter
    if counter and counter:IsA("ValueBase") then counterConnection=counter.Changed:Connect(refreshCount)end
    refreshCount()
end
local function characterParts()
    local character=player.Character
    local humanoid=character and character:FindFirstChildOfClass("Humanoid")
    local root=character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
    if humanoid and humanoid.Health>0 and root and root:IsA("BasePart") then return root,humanoid end
    return nil,nil
end
local function context()
    local folder=player:FindFirstChild("Status")
    local team=folder and folder:FindFirstChild("Team")
    local inGame=folder and folder:FindFirstChild("IsInGame")
    local root,humanoid=characterParts()
    local isGranny
    if team and team:IsA("StringValue") then
        if team.Value=="Toddler" then isGranny=false elseif team.Value=="Granny" then isGranny=true end
    end
    return {count=countValue(),enabled=state.auto,alive=root~=nil,
        inRound=inGame and inGame:IsA("BoolValue") and inGame.Value==true,isGranny=isGranny},root,humanoid
end
local function getUtility()
    if utility then return utility end
    local shared=ReplicatedStorage:FindFirstChild("SharedModules")
    local module=shared and shared:FindFirstChild("PlayerUtility")
    if not module or not module:IsA("ModuleScript") then return nil end
    local ok,value=pcall(require,module)
    if ok and type(value)=="table" and type(value.IsMovementDisabled)=="function" then utility=value end
    return utility
end
local function movementAllowed(humanoid)
    if not humanoid or humanoid.Sit then return false end
    local api=getUtility()
    if not api then return false end
    local ok,disabled=pcall(api.IsMovementDisabled,player)
    return ok and disabled==false
end
local function keysFolder()
    local map=workspace:FindFirstChild("Map")
    return map and map:FindFirstChild("Keys")
end
local function promptFor(key,folder)
    if not key or key.Parent~=folder or not key:IsA("BasePart") then return nil end
    local prompt=key:FindFirstChild("KeyPickupPrompt")
    if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled then return prompt end
    return nil
end
local function getTransport()
    if transport then return transport end
    local network=ReplicatedStorage:FindFirstChild("Network")
    local module=network and network:FindFirstChild("Warp")
    if not module or not module:IsA("ModuleScript") then return nil end
    local ok,value=pcall(function()
        local warp=require(module)
        return warp.Client("PickupKey")
    end)
    if ok and type(value)=="table" and type(value.Fire)=="function" then transport=value end
    return transport
end
local function current(key,folder,epoch)
    local gate,_,humanoid=context()
    return state.alive and state.epoch==epoch and KeyPolicy.canRequest(gate)
        and keysFolder()==folder and promptFor(key,folder)~=nil and movementAllowed(humanoid)
end
local function travel(key,folder,root,prompt,epoch)
    local range=math.max(0,math.min(5,prompt.MaxActivationDistance)-0.25)
    if (root.Position-key.Position).Magnitude<=range then return true end
    if state.mode=="nearby" then return false end
    local target=key.Position+Vector3.new(0,2.5,0)
    local goal=CFrame.new(target)*(root.CFrame-root.Position)
    if state.mode=="teleport" then
        if not current(key,folder,epoch) then return false end
        root.CFrame=goal
        task.wait(0.2)
    else
        local duration=math.clamp((root.Position-target).Magnitude/state.speed,0.1,20)
        local tween=TweenService:Create(root,TweenInfo.new(duration,Enum.EasingStyle.Linear),{CFrame=goal})
        activeTween=tween;tween:Play()
        local deadline=os.clock()+duration+1
        while current(key,folder,epoch) and (root.Position-target).Magnitude>0.2 and os.clock()<deadline do task.wait(0.05)end
        cancelMove()
    end
    return current(key,folder,epoch) and (root.Position-key.Position).Magnitude<=range
end
local function step()
    bindCounter();refreshCount()
    local count=countValue()
    if state.pending then
        local pending=state.pending
        if count and count>pending.before then
            state.pending=nil
            if state.auto then status("Key collected.")end
        elseif os.clock()<pending.deadline then
            if state.auto then status("Waiting for pickup confirmation...")end
            return
        else
            blockedUntil[pending.key]=os.clock()+8;state.pending=nil
            if state.auto then status("Pickup not confirmed; trying another key.")end
            return
        end
    end
    local gate,root,humanoid=context()
    local decision,reason=KeyPolicy.decide(gate)
    if decision=="full" then
        if state.auto then setAuto(false,"Full 3/3 - finished.")end
        return
    end
    if not state.auto then return end
    if decision~="collect" then status(reason);return end
    if not movementAllowed(humanoid) then status("Waiting for recovery / movement unlocked...");return end
    local folder=keysFolder()
    if not folder then status("Waiting for map keys...");return end
    local key,prompt,bestDistance
    for _,candidate in ipairs(folder:GetChildren())do
        local candidatePrompt=promptFor(candidate,folder)
        if candidatePrompt and (blockedUntil[candidate] or 0)<=os.clock() then
            local distance=(root.Position-candidate.Position).Magnitude
            local range=math.max(0,math.min(5,candidatePrompt.MaxActivationDistance)-0.25)
            if (state.mode~="nearby" or distance<=range) and (not bestDistance or distance<bestDistance) then
                key,prompt,bestDistance=candidate,candidatePrompt,distance
            end
        end
    end
    if not key then status(state.mode=="nearby" and "No nearby keys. Move closer or choose Teleport." or "Waiting for available keys...");return end
    local api=getTransport()
    if not api then status("Waiting for pickup network...");return end
    local epoch=state.epoch
    status("Going to key...")
    if not travel(key,folder,root,prompt,epoch) then return end
    -- Recheck replicated count/role/map immediately before dispatch. No prompt callback:
    -- the game's callback may show a paid ExtraKeys offer when already full.
    if not current(key,folder,epoch) then return end
    local before=countValue()
    if not KeyPolicy.validCount(before) or before>=KeyPolicy.CAP then refreshCount();return end
    state.pending={key=key,before=before,deadline=os.clock()+3}
    local sent,err=pcall(function()api:Fire(true,key)end)
    if not sent then
        state.pending=nil;blockedUntil[key]=os.clock()+8
        status("Pickup request failed.");warn("[Key Collector] "..tostring(err))
    else
        local after=countValue()
        if after and after>=KeyPolicy.CAP then setAuto(false,"Full 3/3 - finished.")
        elseif state.auto then status("Waiting for pickup confirmation...")end
    end
end
app=MattLib.new({id="matt-grandma-key-collector",theme="Dark",reducedMotion=true})
local window=app:CreateWindow({Id="keys",Title="Destroy Grandma - Keys 1.0.0",Design="MintGlass",Size={520,430},Wallpaper=false,OpenKey="RightShift",OnClose=cleanup})
local main=window:AddTab({Title="Main"}):AddSection({Title="Collect keys to 3/3"})
main:AddDropdown({Id="movement",Title="Movement",Default="teleport",Options={
    {value="teleport",label="Teleport to keys"},{value="tween",label="Tween to keys"},{value="nearby",label="Nearby only (no movement)"},
},Callback=function(value)
    state.mode=value;state.epoch+=1;cancelMove()
    if speedSlider then speedSlider:Update({Disabled=value~="tween"})end
end})
speedSlider=main:AddSlider({Id="speed",Title="Tween speed",Min=10,Max=200,Step=5,Default=60,Disabled=true,Callback=function(value)state.speed=value end})
autoToggle=main:AddToggle({Id="auto",Title="Auto collect (stop at 3/3)",Default=false,Callback=function(value)
    if value then
        local count=countValue()
        if count and count>=KeyPolicy.CAP then setAuto(false,"Full 3/3 - finished.");return end
    end
    setAuto(value)
end})
main:AddButton({Title="Stop",Callback=function()setAuto(false)end})
countLabel=main:AddText({Text="Keys: ?/3"})
statusLabel=main:AddText({Text="Status: Ready."})
lifetime.OnInvoke=function(command)
    if command=="status" then return {auto=state.auto,count=countValue(),cap=3,mode=state.mode,pending=state.pending~=nil}end
    if command=="preview" then
        local gate=context();local decision,reason=KeyPolicy.decide(gate);local folder=keysFolder()
        return {decision=decision,reason=reason,count=gate.count,keysLoaded=folder and #folder:GetChildren() or 0,requestsSent=0}
    end
    cleanup()
    return nil
end
bindCounter();refreshCount()
task.spawn(function()
    while state.alive do
        local ok,err=pcall(step)
        if not ok then setAuto(false,"Error - stopped safely.");warn("[Key Collector] "..tostring(err))end
        task.wait(state.auto and 0.25 or 0.5)
    end
end)
