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
| `129852792970565` | [Egg Collector · Return Modes](games/129852792970565.luau) | Multi-select rarities, highest-rarity priority, six return modes and adjustable tween speed/timing/distance |
| `104432981439032` | [Restaurant Remote Auto Play](games/104432981439032.luau) | Remote-only seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing; no character movement |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

### Egg collector (1.2.1)

- Select multiple rarities. **Highest rarity first** is the default; eggs of equal rarity are ordered by distance. Empty selection targets nothing. **Nearest selected** is also available.
- An egg pickup is acknowledged through the player's `CarryingEgg` attribute before returning. Ordinary travel and previous-position buttons remain empty-handed only. Experimental return modes explicitly allow one carried-egg teleport and may reset the egg.
- Choose **Return mode** on the Eggs tab:
  1. **Tween only** — default; no return teleport.
  2. **Tween until bank confirmed, then teleport** — teleport only after your own `EggBanked` event and cleared carry state.
  3. **Timed tween → teleport (may reset)** — tween for a chosen delay, then teleport once.
  4. **Tween near target → teleport (may reset)** — tween until within a chosen remaining distance, then teleport once.
  5. **Instant return (may reset)** — one immediate return teleport.
  6. **Manual / no automatic return** — pick up, but leave the return to you.
- **Return options** provides the timed delay (0.25–10 seconds, default 1) and near-target distance (1–200 studs, default 12), plus Return current egg and Stop controls. Mode/timing/distance changes apply to the next return. To switch an active return, Stop it, choose a mode, then press Return current egg.
- Every automatic return mode and the Return current egg button share the fixed endpoint `Vector3.new(-208.12997436523438, 4.237678050994873, 399.94561767578125)`. A successful return requires the local player's `EggBanked` event, cleared carry state and arrival at the endpoint. A teleport or cleared carry state alone is not reported as success. Cancellation, corrections and rejections can still stop a return. Teleports are never spammed/retried inside an action.
- **Speed & selection → Match carry speed** defaults to 90% of the current Humanoid.WalkSpeed. Choose **Custom speed (may reset)** to use the 10–250 studs/second slider for a faster tween. The script does not change WalkSpeed, collision, anchoring or network settings. Server checks may reject fast tweens or carried-egg teleports; none of these modes is a guaranteed reset bypass.
- Slips, guard catches, rejection-counter increases, blocked movement and unconfirmed banks pause auto-collect. **Stop current action** and **Unload** cancel an active tween.

Default rarity order: Divine → Super Secret → Secret → Ascendant → Exotic → Relic → Mythic → Legendary → Epic → Rare → Common. Exclusive is paid-only and is not included among world-spawn eggs.

### Restaurant remote-only mode (1.1.1)

Restaurant jobs are sent through the game's `Network.Invoke("Entity_Invoke", entityId, method, ...)` transport, which uses a RemoteFunction (`InvokeServer`), not a GUI signal. The script never teleports, walks, changes character physics, or fires proximity prompts. Server validation still applies: if a task requires proximity, its rejection is displayed and backed off; this update does not claim to bypass a server distance check. The egg script is unchanged.

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

All three Luau files compiled successfully. Loader 1.1.0 passed 40 isolated HTTP/fallback checks using the official portable Luau CLI, without executing live game scripts. Prior isolated game-logic checks also passed (57 egg policy/selection/return-mode checks and 31 restaurant planner checks). The restaurant planner previously selected a valid task from live state in read-only mode. The new executor HTTP path could not be tested live because no Roblox client was injected during the fix. End-to-end live gameplay and server acceptance of the return modes remain unverified.

The 1.1.0 restaurant update additionally passed 10 mocked remote-transport checks covering all eight job methods and rejection/error propagation. Static checks confirm that the restaurant script contains no character-movement or simulated-signal calls. These checks do not establish whether a server accepts a distant task.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
