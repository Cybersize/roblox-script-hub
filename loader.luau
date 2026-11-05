-- Roblox Script Hub loader 1.1.0: request-first HTTP, retries, mirrors, bundled routes.
local HUB_VERSION = "1.1.0"
local RAW = "https://raw.githubusercontent.com/Cybersize/roblox-script-hub/main/"
local MIRROR = "https://cdn.jsdelivr.net/gh/Cybersize/roblox-script-hub@main/"
local PREFIX = "[Roblox Script Hub] "

-- BUNDLED_REGISTRY_BEGIN
local BUNDLED_GAMES = {
    ["129852792970565"] = {name = "Egg Collector · Streaming & Recovery", path = "games/129852792970565.luau", enabled = true},
    ["104432981439032"] = {name = "Restaurant Remote Auto Play", path = "games/104432981439032.luau", enabled = true},
}
-- BUNDLED_REGISTRY_END

local function fail(message)
    warn(PREFIX .. message)
    return false, message
end
if type(loadstring) ~= "function" then return fail("This client must provide a Luau compiler (loadstring).") end
if not game:IsLoaded() then game.Loaded:Wait() end
local HttpService = game:GetService("HttpService")

local requestFn
if type(request) == "function" then requestFn = request
elseif type(http_request) == "function" then requestFn = http_request
elseif type(http) == "table" and type(http.request) == "function" then requestFn = http.request end

local function short(value)
    return tostring(value):sub(1, 160)
end
local function checkBody(body)
    if type(body) ~= "string" or not body:find("%S") then return nil, "Empty HTTP response" end
    if #body > 2 * 1024 * 1024 then return nil, "Response exceeds 2 MiB" end
    if body:sub(1,3) == "\239\187\191" then body = body:sub(4) end
    if not body:find("%S") then return nil, "Empty HTTP response" end
    local head = body:sub(1,256):lower()
    if head:match("^%s*<!doctype%s+html") or head:match("^%s*<html[%s>]") then
        return nil, "Received HTML instead of source data"
    end
    return body
end
local requestSerial = 0
local function cacheBust(url)
    requestSerial = requestSerial + 1
    return url .. (url:find("?",1,true) and "&" or "?") .. "_hub=" .. HUB_VERSION .. "-" .. tostring(os.time()) .. "-" .. tostring(requestSerial)
end
local function readRequest(url)
    local ok, response = pcall(requestFn, {Url=cacheBust(url), Method="GET",
        Headers={["Cache-Control"]="no-cache", Accept="text/plain, application/json"}})
    if not ok then return nil, "request error: " .. short(response) end
    if type(response) ~= "table" then return nil, "request did not return a response table: " .. short(response) end
    local code = tonumber(response.StatusCode)
    if not code or code < 200 or code >= 300 or response.Success == false then
        return nil, "HTTP " .. tostring(response.StatusCode or "unknown") .. " " .. short(response.StatusMessage or "")
    end
    return checkBody(response.Body)
end
local function readHttpGet(url)
    local ok, body = pcall(function() return game:HttpGet(cacheBust(url), false) end)
    if not ok then return nil, "HttpGet error: " .. short(body) end
    return checkBody(body)
end
local function download(urls, validate)
    local errors = {}
    local function note(message) if #errors < 6 then errors[#errors+1] = message end end
    for attempt = 1, 2 do
        for _, url in ipairs(urls) do
            local host = url:match("^https://([^/]+)") or "host"
            local transports = requestFn and {readRequest, readHttpGet} or {readHttpGet}
            for index, transport in ipairs(transports) do
                local body, reason = transport(url)
                if body then
                    local ok, value, validationError = pcall(validate, body)
                    if ok and value ~= nil then return value end
                    reason = ok and validationError or value
                end
                note(host .. " / " .. tostring(index) .. ": " .. short(reason or "validation failed"))
            end
        end
        if attempt < 2 then task.wait(0.25) end
    end
    return nil, table.concat(errors, "; ")
end
local function parseManifest(body)
    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" or data.schemaVersion ~= 1 or type(data.games) ~= "table" then
        return nil, "Invalid/unsupported manifest"
    end
    return data
end
local function compileSource(body, name)
    local ok, chunk, compileError = pcall(loadstring, body, name)
    if not ok then return nil, "Compiler error: " .. short(chunk) end
    if type(chunk) ~= "function" then return nil, "Syntax error: " .. short(compileError) end
    return chunk
end

local manifest, manifestError = download({RAW .. "manifest.json", MIRROR .. "manifest.json"}, parseManifest)
if not manifest then
    warn(PREFIX .. "Registry download unavailable; using bundled game routes. " .. short(manifestError))
    manifest = {schemaVersion=1, games=BUNDLED_GAMES}
end
local place = tostring(game.PlaceId)
local entry = manifest.games[place]
if type(entry) ~= "table" then return fail("No script registered for place " .. place .. ".") end
if entry.enabled == false then return fail("The script for this place is currently disabled.") end
local path = entry.path
if type(path) ~= "string" or not path:match("^games/[%w_/%-]+%.luau$") or path:find("..",1,true) then
    return fail("Invalid game script path in registry.")
end

local chunk, scriptError = download({RAW .. path, MIRROR .. path}, function(body)
    return compileSource(body, "@ScriptHub/" .. path)
end)
if not chunk then return fail("Script download failed after retries/fallbacks: " .. tostring(scriptError)) end

-- Pass the same resilient transport to game scripts for their MattLib download.
-- No executor globals are overwritten, and no library is executed here.
local context = {hubVersion=HUB_VERSION}
function context.httpGet(url)
    if type(url) ~= "string" or not url:match("^https://raw%.githubusercontent%.com/") then
        error("Unsupported dependency URL", 2)
    end
    local urls = {url}
    local owner, repo, ref, file = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
    if owner then urls[#urls+1] = "https://cdn.jsdelivr.net/gh/" .. owner .. "/" .. repo .. "@" .. ref .. "/" .. file end
    local body, reason = download(urls, function(source)
        local compiled, compileError = compileSource(source, "@ScriptHub/Dependency")
        if not compiled then return nil, compileError end
        return source
    end)
    if not body then error("Dependency download failed: " .. tostring(reason), 2) end
    return body
end
local ran, result = pcall(chunk, context)
if not ran then return fail("Script startup failed: " .. tostring(result)) end
print(PREFIX .. "Loaded " .. tostring(entry.name or place) .. " (loader " .. HUB_VERSION .. ").")
return true, result
