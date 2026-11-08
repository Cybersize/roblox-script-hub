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
| `129852792970565` | [Egg Collector · Streaming & Recovery](games/129852792970565.luau) | Simple Main + Settings menu; rarity priority, collect, idle training, ready hatch, owned-egg placement and equip best |
| `104432981439032` | [Restaurant Remote Auto Play](games/104432981439032.luau) | Remote-only seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing; no character movement |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

### Egg helper (1.8.0)

Updated against the supplied Nov 9 snapshot and the live v629 client interfaces. The old Streaming, Recovery and Speed & Selection pages have been replaced by just **Main** and **Settings**. Streaming/recovery still run automatically; no song/music controls are included.

**Quick start:** choose rarities, leave **Finish = Bank eggs**, choose tasks in **Auto tasks**, then turn **Auto run ON**. All five tasks are selected initially, but the master switch always starts **OFF**. **Get egg** performs one pickup/return, including returning an already-held world egg. **Stop** cancels automation and movement. Close the window to unload; **RightShift** hides/shows it without stopping it.

#### Main

- **Rarities:** multi-select, always highest rarity first. Priority reads the game's spawning/non-paid rarity config; the fallback includes Celestial above Divine. Paid-only Exclusive is excluded.
- **Movement:** Tween, Tween → teleport, Tween close → teleport, or Teleport.
- **Finish:** Bank eggs (default), Saved drop point, or Pickup only.
- **Tween speed:** **0 = Auto** (90% of current carry WalkSpeed); **10–1000** selects a custom studs/second speed. Faster settings may be rejected by the server.
- **Drop at saved point:** independent toggle, enabled only for that finish. OFF stops holding the egg; ON sends the normal one-shot drop request after arrival.
- **Auto tasks:** Collect eggs, Train when idle, Hatch ready eggs, Place owned eggs, Equip best. Deselect anything you do not want.

#### Settings

Only **Safe return (no held-egg TP)** and the timed/near-return sliders remain. Safety defaults **ON**: timed/near/instant choices finish by direct tween while carrying a world egg, not by teleport. Turning it OFF explicitly restores experimental carried-egg teleport attempts. A short tween before teleport does not guarantee server acceptance.

Bank finish: `(-208.12997436523438, 4.237678050994873, 399.94561767578125)`.
Saved drop finish: `(-184.1337127685547, 4.237677097320557, 397.77520751953125)`.
All returns use a direct path without left/right waypoints. Bank success requires the local EggBanked acknowledgement and empty hands; an empty carry flag alone is not treated as success. Drop confirmation is separate from banking.

#### Automatic tasks

- **Collect:** chooses a loaded eligible egg, with recent region hints re-streamed and validated before use. Background streaming requests do not walk the character and do not block already-loaded eggs. This is not permanent whole-map residency.
- **Train when idle:** stands on your own tagged treadmill when there is no selected egg target, without buying upgrades. World-egg collection takes priority. It does not interrupt a held world egg, hit recovery, chase, sitting, manual placement or a saved-point pause. Stopping makes a best-effort step off only the treadmill this script moved onto.
- **Hatch ready eggs:** requests hatching only for owned, placed eggs whose replicated anchor says Ready. Stale inventory countdowns are not used to skip growth. No paid skip requests.
- **Place owned eggs:** uses the native free-floor placement geometry, spacing validation and egg capacity on your own plot. If necessary it visits the plot empty-handed first, then submits one validated nearby request and waits for confirmation. It never sells or overwrites an item. Manual placement pauses these tasks.
- **Equip best:** uses the game's normal Equip Best request after the owned catboy inventory changes. Its normal rearrangement of your own catboys is expected; nothing is sold.

Idle training and owned-item maintenance can move the character while empty-handed. The saved-point hold/drop finish pauses further collection/movement until **Get egg** or Auto is restarted. Catch, slip, rejection and respawn recovery keep your selections and Auto intent; retries have no 60-second timer and wait for a living, non-ragdolled, empty-handed character. The script now checks Character.Ragdolled as well as the player attribute. Runtime failures in an optional task back off that task without resetting the UI.

No purchases, paid hatch skips, selling, speed-stat edits or anti-caught blocker are included. Safe return avoids held-egg teleport attempts; it does not guarantee immunity to guards or server movement checks.

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

Game scripts should default to stopped, guard their supported place IDs, stop their previous copy on reload, validate server responses, and support closing/unloading the menu. Never commit access tokens, `.rbxl` snapshots, or account credentials.

## Validation status

The current three Luau entry files compile with the official portable Luau CLI. Egg 1.8.0 passes 41 full-source mocked Main/Settings and scheduler checks, 27 owned-inventory policy checks and 41 idle-training policy checks. Existing suites also cover loader HTTP/fallback behavior (40), selection/recovery (69), streaming/recovery (50), direct return/drop (95), and rarity/config compatibility (16). The previous five-page UI suite has been superseded, not counted as current UI coverage.

A live v629 UI-only load confirmed Main + Settings, Auto OFF, no new console errors, a readable owned inventory snapshot and the correct owned treadmill. Its read-only preview sent no gameplay requests. Automated hatch/place/equip requests, treadmill travel, full-region residency, high-speed acceptance and end-to-end protected returns were not live-tested for this release. Client interfaces and offline mocks do not establish server acceptance.

The restaurant's earlier isolated planner/remote-transport checks and read-only task selection remain unchanged; they do not establish acceptance of distant jobs.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
