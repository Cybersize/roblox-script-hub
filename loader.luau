-- Roblox Script Hub: one loader, game-specific scripts.
-- Add games through manifest.json; the user's loadstring does not change.
local BASE = "https://raw.githubusercontent.com/Cybersize/roblox-script-hub/main/"
local PREFIX = "[Roblox Script Hub] "

local function fail(message)
    warn(PREFIX .. message)
    return false, message
end

if type(loadstring) ~= "function" then
    return fail("This client must provide loadstring and game:HttpGet.")
end
if not game:IsLoaded() then game.Loaded:Wait() end

local function fetch(path)
    local ok, body = pcall(function() return game:HttpGet(BASE .. path, false) end)
    if not ok then return nil, tostring(body) end
    if type(body) ~= "string" or body == "" then return nil, "Empty HTTP response." end
    if #body > 2 * 1024 * 1024 then return nil, "Response exceeds 2 MiB." end
    return body
end

local manifestSource, downloadError = fetch("manifest.json")
if not manifestSource then return fail("Manifest download failed: " .. downloadError) end
local decoded, manifest = pcall(function()
    return game:GetService("HttpService"):JSONDecode(manifestSource)
end)
if not decoded or type(manifest) ~= "table" or manifest.schemaVersion ~= 1
    or type(manifest.games) ~= "table" then
    return fail("Invalid or unsupported manifest.")
end

local place = tostring(game.PlaceId)
local entry = manifest.games[place]
if type(entry) ~= "table" then return fail("No script registered for place " .. place .. ".") end
if entry.enabled == false then return fail("The script for this place is currently disabled.") end
local path = entry.path
if type(path) ~= "string" or not path:match("^games/[%w_/%-]+%.luau$")
    or path:find("..", 1, true) then
    return fail("Invalid game script path in manifest.")
end

local source, scriptDownloadError = fetch(path)
if not source then return fail("Script download failed: " .. scriptDownloadError) end
local compiled, chunk, compileError = pcall(loadstring, source, "@ScriptHub/" .. path)
if not compiled then return fail("Script compiler failed: " .. tostring(chunk)) end
if type(chunk) ~= "function" then return fail("Script syntax error: " .. tostring(compileError)) end
local ran, result = pcall(chunk)
if not ran then return fail("Script startup failed: " .. tostring(result)) end
print(PREFIX .. "Loaded " .. tostring(entry.name or place) .. ".")
return true, result
