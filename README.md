# Roblox Script Hub

A growing collection of game-specific scripts using [MattLib](https://github.com/Cybersize/MattLib), with one place-aware loader.

## One loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Cybersize/roblox-script-hub/main/loader.luau?v=1.1.0", false))()
```

The loader reads `manifest.json`, detects `game.PlaceId`, and loads only that game's script. If the registry cannot be downloaded, known bundled routes are available instead. Unsupported places produce a console message and run no game script. This loader is for a Roblox client executor that provides `loadstring` and HTTP support, not an ordinary Studio LocalScript.

### Empty HTTP response / loader 1.1.0

The loader now prefers `request`, `http_request` or `http.request`, falls back to `game:HttpGet`, retries with distinct cache-busting URLs, and can use jsDelivr if GitHub Raw fails. It rejects empty/whitespace, HTML, oversized data and invalid sources rather than executing an empty chunk. Both game scripts receive the same transport for their pinned MattLib dependency.

An empty manifest no longer blocks the two bundled games, but their script and library files still need a working download. Valid remote disabled/removed entries are respected; the bundled registry is only used when the manifest itself is unavailable/invalid.

If the initial `game:HttpGet` call also fails, Real supports this request-based bootstrap:

```lua
local r = request({Url="https://raw.githubusercontent.com/Cybersize/roblox-script-hub/main/loader.luau?v=1.1.0", Method="GET"})
assert(type(r)=="table" and r.StatusCode==200 and type(r.Body)=="string" and #r.Body>0, "Loader download failed")
assert(loadstring(r.Body))()
```

The executor must be injected in the current Roblox client. If all HTTP transports/hosts are blocked, the loader reports failure; bundled routes are not an offline copy of the scripts or MattLib.

## Available scripts

| Place ID | Script | Features |
| --- | --- | --- |
| `129852792970565` | [Egg Collector · Streaming & Recovery](games/129852792970565.luau) | Multi-select rarity priority, independent tween/teleport movement and drop controls, region requests, reset recovery and guard-aware routing |
| `104432981439032` | [Restaurant Remote Auto Play](games/104432981439032.luau) | Remote-only seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing; no character movement |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

### Egg collector (1.5.0)

The Eggs tab starts with independent movement and drop controls:

1. **Movement to stop point**: **Tween directly** (default), **Teleport instantly**, **Tween then teleport**, or **Tween near point then teleport**. Tween returns follow a direct path with no guard-edge detour. Teleport/hybrid modes move a held egg and may trigger a server reset; they are not guaranteed bypasses.
2. **Drop egg at stop point**: OFF by default keeps holding the egg; ON requests a native drop after arrival at `Vector3.new(-184.1337127685547, 4.237677097320557, 397.77520751953125)`. Movement and Drop are captured at action start, so changing them does not mutate an active return. Use Stop, select settings, then **Return current egg to selected destination** to apply changes to a held egg.
3. **Destination / bank mode** defaults to **Saved stop point**, using the two controls above. Separate bank options retain tween-only, bank-confirmed tween-then-teleport, timed/near hybrids, instant return and manual return. Bank modes ignore the stop-point movement/drop controls; the drop toggle is disabled while a bank/manual mode is selected.

- Select multiple rarities. **Highest rarity first** is the default, with distance breaking ties; **Nearest selected** is also available. Empty selection targets nothing.
- Pickup is acknowledged through `CarryingEgg` before returning. Ordinary teleport/previous-position buttons remain empty-handed only. No speed stats, collision, anchoring or network settings are modified.
- Stop-point returns leave Auto ON but waiting there, even after a drop, so they do not immediately pick up the dropped egg again. Change movement/destination, **Resume auto now**, or toggle Auto off/on to continue. Stop-point completion is not reported as a bank.
- Drop ON uses the game's normal `Remotes.RequestDropEgg:FireServer()` once with no arguments. It waits up to 8 seconds for `Chased` to clear, keeping the egg without requesting a drop if still chased. Confirmation requires cleared carry state and the matching egg replicated nearby in `Runtime.DroppedEggs`, without a bank/reset/rejection. Teleport returns settle briefly before dropping so corrections/carry changes can cancel the request. Placement and acceptance are controlled by the server; missing/rejected/unconfirmed drops are never spam-retried.
- **Return options** sets timed delay (0.25–10 seconds, default 1) and near-target distance (1–200 studs, default 12). Sliders work with the selected stop-point movement or bank mode. **Stop current action** and **Unload** cancel movement and stop Auto.
- Bank modes keep the endpoint `Vector3.new(-208.12997436523438, 4.237678050994873, 399.94561767578125)`. Banking requires the local player's `EggBanked` event, empty carry state and arrival. Bank-confirmed hybrid never teleports before the bank event and empty carry state. Experimental hybrids/instant modes allow one carried-egg teleport; they never spam repeat teleports inside an action.
- **Speed & selection → Match carry speed** uses 90% of current Humanoid.WalkSpeed. **Custom speed (may reset)** allows 10–250 studs/second. Server checks can reject both fast tweens and teleports.
- **Recovery → Keep auto ON** defaults on. Slips, catches, rejections, blocked/unconfirmed returns and respawns cancel the action but retain Auto with a cooldown starting at 5 seconds and doubling after separate failed actions up to 60 seconds. Runtime errors still stop Auto. **After reset: use tween-only + carry-speed cap** changes stop-point movement back to Tween without changing the stop destination or Drop choice; bank returns fall back to bank tween-only. Controls reflect the fallback. Recovery can be disabled, and **Resume auto now** clears the cooldown.
- **Streaming** uses native `Player:RequestStreamAroundAsync` without moving the character. Choose all/unlocked zones, a 1–5 second timeout or **Scan zones now (no teleport)**. Auto waits for an initial sweep. Recent egg hints are re-streamed and checked against real eggs/prompts before travel. Distant regions can unload again; this does not guarantee permanent whole-map rendering. Already-loaded eggs remain usable if region requests fail.
- **Bank modes only: guard-avoidance corridor route** defaults on; stop-point movement never uses that detour. It is avoidance, not anti-hit/godmode: server boss hits still apply. The optional faster-base-guard filter is off by default and does not model all possible guard acceleration/attacks.

Default rarity order: Divine → Super Secret → Secret → Ascendant → Exotic → Relic → Mythic → Legendary → Epic → Rare → Common. Exclusive is paid-only and is not included among world-spawn eggs.

### Restaurant remote-only mode (1.1.1)

Restaurant jobs are sent through the game's `Network.Invoke("Entity_Invoke", entityId, method, ...)` transport, which uses a RemoteFunction (`InvokeServer`), not a GUI signal. The script never teleports, walks, changes character physics, or fires proximity prompts. Server validation still applies: if a task requires proximity, its rejection is displayed and backed off; this does not claim to bypass a server distance check.

## Add another game

1. Add its self-contained script as `games/PLACE_ID.luau`.
2. Add a matching entry to `manifest.json`:

```json
"123456789": {
  "name": "Another Game",
  "path": "games/123456789.luau",
  "version": "1.0.0",
  "enabled": true
}
```

3. Run `python tools/build_loader.py` to refresh the bundled fallback routes.
4. Run `python tools/validate_manifest.py` (also checks that fallback routes match).
5. Commit and push to `main`. The same loadstring now supports the new place.

To temporarily disable a game, set its `enabled` field to `false`. To support multiple places with the same script, register each place ID with the appropriate path; that script must also permit those places.

Game scripts should default to stopped, guard their supported place IDs, stop their previous copy on reload, validate server responses, and provide an Unload control. Never commit access tokens, `.rbxl` snapshots, or account credentials.

## Validation status

All three Luau files compiled successfully. Loader 1.1.0 passed 40 isolated HTTP/fallback checks using the official portable Luau CLI, without executing live game scripts. Egg collector 1.5.0 passed 57 policy/selection/return-mode regression checks, 40 mocked streaming/recovery/guard-route checks, 50 stop-point movement/drop checks and 22 full-script mocked UI/event-wiring checks. These cover all four stop-point movement choices with Drop ON/OFF, direct tween paths, exact coordinates, one-shot native drops, capture of choices at action start, chase/cancel/rejection handling, distinct drop-vs-bank confirmation, actual dropdown/toggle wiring and Auto waiting after a drop. Native streaming, server hits and the real drop remote were not exercised. The restaurant planner's prior 31 isolated checks also passed, and it previously selected a valid task from live state in read-only mode. No Roblox client was injected during this update, so end-to-end live gameplay, full-region loading and server acceptance of return/drop modes remain unverified.

The 1.1.0 restaurant update additionally passed 10 mocked remote-transport checks covering all eight job methods and rejection/error propagation. Static checks confirm that the restaurant script contains no character-movement or simulated-signal calls. These checks do not establish whether a server accepts a distant task.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
