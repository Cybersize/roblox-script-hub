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
| `129852792970565` | [Egg Collector · Streaming & Recovery](games/129852792970565.luau) | Multi-select rarity priority, eight return modes including stop-and-hold/drop, region requests, reset recovery and guard-aware routing |
| `104432981439032` | [Restaurant Remote Auto Play](games/104432981439032.luau) | Remote-only seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing; no character movement |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

### Egg collector (1.4.0)

- Select multiple rarities. **Highest rarity first** is the default; eggs of equal rarity are ordered by distance. Empty selection targets nothing. **Nearest selected** is also available.
- An egg pickup is acknowledged through the player's `CarryingEgg` attribute before returning. Ordinary travel and previous-position buttons remain empty-handed only. Experimental return modes explicitly allow one carried-egg teleport and may reset the egg.
- Choose **Return mode** on the Eggs tab:
  1. **Tween only** — default; no return teleport.
  2. **Tween until bank confirmed, then teleport** — teleport only after your own `EggBanked` event and cleared carry state.
  3. **Timed tween → teleport (may reset)** — tween for a chosen delay, then teleport once.
  4. **Tween near target → teleport (may reset)** — tween until within a chosen remaining distance, then teleport once.
  5. **Instant return (may reset)** — one immediate return teleport.
  6. **Manual / no automatic return** — pick up, but leave the return to you.
  7. **Tween to stop point (hold egg)** — tween to the screenshot's exact position `Vector3.new(-184.1337127685547, 4.237677097320557, 397.77520751953125)` and stop while holding the egg. No drop or bank request.
  8. **Tween to stop point → drop egg** — tween to the same point, stop, and send the game's native `Remotes.RequestDropEgg:FireServer()` once with no arguments. Like the game's normal drop action, this waits for `Chased` to clear (up to 8 seconds); if still chased, it keeps the egg without sending a request. A successful drop requires cleared carry state and the matching egg replicated in `Runtime.DroppedEggs` nearby, without a bank/reset/rejection. This is not reported as a bank; placement is controlled by the server.
- Both stop-point modes leave Auto ON but waiting at the point, even after a drop, so it does not immediately pick the dropped egg up again. Change mode, **Resume auto now**, or toggle Auto off/on to resume. To bank an egg still held, select a bank mode and press **Return current egg to selected destination**. A missing/rejected/unconfirmed drop is never spam-retried.
- **Return options** provides the timed delay (0.25–10 seconds, default 1) and near-target distance (1–200 studs, default 12), plus Return current egg and Stop controls. Mode/timing/distance changes apply to the next return. To switch an active return, Stop it, choose a mode, then press Return current egg.
- All bank-return modes use the fixed endpoint `Vector3.new(-208.12997436523438, 4.237678050994873, 399.94561767578125)`; stop-point modes use their separate screenshot coordinate above. A successful bank return requires the local player's `EggBanked` event, cleared carry state and arrival at the bank endpoint. A teleport or cleared carry state alone is not reported as a bank. Cancellation, corrections and rejections can still stop a return. Teleports are never spammed/retried inside an action.
- **Speed & selection → Match carry speed** defaults to 90% of the current Humanoid.WalkSpeed. Choose **Custom speed (may reset)** to use the 10–250 studs/second slider for a faster tween. The script does not change WalkSpeed, collision, anchoring or network settings. Server checks may reject fast tweens or carried-egg teleports; none of these modes is a guaranteed reset bypass.
- **Recovery → Keep auto ON** is enabled by default. An egg slipping back, a guard catch, a rejection-counter increase, a blocked return, an unconfirmed bank or a respawn cancels the current action but keeps the master toggle ON. Retries start with a 5-second cooldown, doubling after separate failed actions up to 60 seconds. Successful banking clears the backoff. **Resume auto now** clears the cooldown; **Stop current action** and **Unload** cancel the action and stop auto.
- **After reset: use tween-only + carry-speed cap** is enabled by default. A reset or unconfirmed bank changes the next attempt to **Tween only** and **Match carry speed**, with the dropdowns updated to match. Turn this option off to retain an experimental mode. A held egg must clear or be returned before another pickup; recovery never blindly teleports it again. Runtime errors still stop auto, and disabling **Keep auto ON** restores stop-on-failure behavior.
- **Streaming** requests regions through Roblox's native `Player:RequestStreamAroundAsync` without moving the character. Auto waits for an initial zone sweep, then periodically requests one region at a time while idle and empty-handed. Choose **All zones** (default) or **Unlocked zones**, set a 1–5 second request timeout, or press **Scan zones now (no teleport)**. Loaded egg positions are cached briefly as region hints and revalidated against a real replicated egg and prompt before travel. Priority is among loaded or recently cached eggs, not an omniscient server list. Requests do not disable streaming or guarantee the entire map remains rendered; distant regions can unload again. If native requests fail, already-loaded eggs remain usable.
- **Guard avoidance: wide corridor route** is enabled by default: returns favor a corridor edge away from the nearest loaded guard, then finish at the same fixed bank endpoint. It is avoidance, not anti-hit/godmode: server-side boss hits still apply. **Skip zones whose base guard speed exceeds return speed** is an optional filter (off by default); it compares configured base speeds, not every possible guard acceleration or attack.

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

All three Luau files compiled successfully. Loader 1.1.0 passed 40 isolated HTTP/fallback checks using the official portable Luau CLI, without executing live game scripts. Egg collector 1.4.0 passed 57 policy/selection/return-mode regression checks, 40 mocked streaming/recovery/guard-route checks, 24 stop-point hold/drop checks and 14 full-script mocked UI/event-wiring checks. These include exact stop coordinates, no hold-mode drop, one-shot native drops, chase/cancel/rejection handling, distinct drop-vs-bank confirmation and keeping the actual Auto worker waiting at the stop point. Native streaming, server hits and the real drop remote were not exercised. The restaurant planner's prior 31 isolated checks also passed, and it previously selected a valid task from live state in read-only mode. No Roblox client was injected during this update, so end-to-end live gameplay, full-region loading and server acceptance of return/drop modes remain unverified.

The 1.1.0 restaurant update additionally passed 10 mocked remote-transport checks covering all eight job methods and rejection/error propagation. Static checks confirm that the restaurant script contains no character-movement or simulated-signal calls. These checks do not establish whether a server accepts a distant task.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
