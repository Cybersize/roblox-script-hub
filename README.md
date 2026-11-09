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
| `129852792970565` | [Egg Collector · Streaming & Recovery](games/129852792970565.luau) | Main / Egg / Shop / Settings; rarity priority, collection, idle training, selective placement, ready hatch, equip best and opt-in cash upgrades |
| `104432981439032` | [Restaurant Remote Auto Play](games/104432981439032.luau) | Remote-only seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing; no character movement |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

### Egg helper (1.9.0)

The menu is now split into **Main**, **Egg**, **Shop** and **Settings**. Collection is no longer mixed with owned-egg actions or purchases. Streaming and settings-preserving recovery still run automatically without extra configuration pages.

**Quick start:** choose collection rarities on Main, choose owned-egg actions on Egg, then enable **Auto run** on Main. Auto run is the shared master and always starts **OFF**. Purchase switches also start **OFF**, separately. **Stop** cancels all automation and movement. Close the window to unload; **RightShift** hides/shows it without stopping it.

#### Main — collection and movement

- **Rarities:** multi-select, highest rarity first. Priority reads the spawning/non-paid rarity config; the fallback includes Celestial above Divine. Paid-only Exclusive is excluded from world collection.
- **Movement:** Tween, Tween → teleport, Tween close → teleport, or Teleport.
- **Finish:** Bank eggs (default), Saved drop point, or Pickup only.
- **Tween speed:** **0 = Auto** (90% of current carry WalkSpeed); **10–1000** selects custom studs/second. Faster settings may be rejected by the server.
- **Drop at saved point:** OFF stops holding the egg; ON sends the normal one-shot drop request after arrival. Enabled only for that finish.
- **Main tasks:** only Collect eggs and Train when idle. Changing these never resets the Egg or Shop selections.
- **Get egg:** one pickup/return, including returning an already-held world egg. **Stop:** stops the shared master.

#### Egg — owned eggs and equip best

- **Egg to place:** searchable dropdown offering **Best available**, a **rarity**, or an **individual owned egg ID**. Rarity choices remain available even if none are currently owned. Owned item choices refresh automatically and via **Refresh eggs**.
- **Auto place selected eggs:** applies the dropdown filter before native geometry validation. A missing/already-placed selected item does **not** silently fall back to another egg. Rarity selection can keep placing future matching eggs; a specific ID places only that item.
- **Auto hatch ready eggs:** only owned, placed eggs whose replicated anchor says Ready. Stale inventory countdowns cannot skip growth.
- **Auto equip best:** normal Equip Best request when the owned catboy inventory changes; no selling.

The three owned-item tasks are selected initially but cannot run until the Main master is enabled. Placing uses native free-floor geometry, spacing validation and capacity on your own plot. If necessary, the script visits the plot empty-handed before submitting one validated nearby request and waiting for confirmation. It never sells or overwrites an item. Manual placement pauses owned-item tasks and purchases.

#### Shop — opt-in normal-cash upgrades and buying

**Auto upgrade** and **Auto buy trails** both default **OFF**, and also require the Main master. The **Buy / upgrade** multi-select chooses among:

- Cafe/base expansion, via the normal UpgradePen cash action.
- Treadmill tiers, respecting the native initial unlock condition.
- Bag capacity.
- Egg/incubator capacity.
- Unowned trails, using their cash prices and snapshot ownership.

When enabled, this can **spend all available normal in-game cash** on selected affordable upgrades. It chooses the cheapest affordable next request, allows only one pending purchase at a time, waits for a replicated level/ownership change, and backs off unconfirmed requests. Maxed upgrades, owned trails, unavailable ownership data and invalid/unknown prices are skipped. Prices come from the live native Econ/UpgradeConfig/SpeedConfig interfaces, not hardcoded estimates.

No Robux/gamepass/product purchases, Marketplace prompts, hatch skips, selling or resets/rebirths are dispatched. These are the five normal-cash categories established by the inspected v629 clients; unsupported purchase systems are not guessed.

#### Settings and return behavior

Only **Safe return (no held-egg TP)** and timed/near-return sliders remain. Safety defaults **ON**: timed/near/instant choices finish by direct tween while carrying a world egg, not by teleport. Turning it OFF restores experimental carried-egg teleport attempts. A short tween before teleport does not guarantee acceptance.

Bank finish: `(-208.12997436523438, 4.237678050994873, 399.94561767578125)`.
Saved drop finish: `(-184.1337127685547, 4.237677097320557, 397.77520751953125)`.
All returns use a direct path without left/right waypoints. Bank success requires the local EggBanked acknowledgement and empty hands; drop confirmation is separate from banking.

Background streaming rechecks recent egg hints and does not block already-loaded eggs. It does not guarantee permanent whole-map residency. Idle training uses your own treadmill and gives selected world eggs priority. It does not interrupt a held egg, chase, hit recovery, sitting, manual placement or a saved-point pause. Stopping makes a best-effort step off only the treadmill this script moved onto.

Empty-handed owned-item maintenance and idle training may move the character. The saved-point finish pauses further collection/movement until **Get egg** or Auto is restarted. Catch, slip, rejection and respawn recovery retain your selections and Auto intent, including the Egg choice and Shop opt-ins. Collection retry has no 60-second timer and waits for a living, non-ragdolled, empty-handed character. The script checks both Character.Ragdolled and the player attribute. Optional task failures back off without resetting controls.

No speed-stat edits, physics flags or anti-caught blocker are included. Safe return avoids held-egg teleport attempts; it is not guard immunity or a guarantee against server movement rejection.

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

The current three Luau entry files compile with the official portable Luau CLI. Egg 1.9.0 passes 71 full-source mocked split-UI/selection/purchase-scheduler checks, 39 owned-inventory/selection policy checks, 48 cash-only purchase allowlist checks and 41 idle-training policy checks. Existing suites also cover loader HTTP/fallback behavior (40), selection/recovery (69), streaming/recovery (50), direct return/drop (95), and rarity/config compatibility (16). The old two/five-page UI expectations are superseded, not counted as current coverage.

A live v629 UI-only load confirmed the four-tab layout, native Egg/Shop controls, Auto OFF, both cash switches OFF, readable inventory/native upgrade quotes and no new console errors. The read-only preview sent no gameplay requests. The game window was not focused, so native UI clicks were not performed; mounted controls were verified read-only instead. No cash was spent for testing. Automated purchases, hatch/place/equip requests, treadmill travel, full-region residency, high-speed acceptance and end-to-end protected returns remain unverified live. Client interfaces and offline mocks do not establish server acceptance. Real's checker still reports unresolved game-specific requires and one pre-existing return-state narrowing diagnostic; this is not a claim of a clean type-check.

The restaurant's earlier isolated planner/remote-transport checks and read-only task selection remain unchanged; they do not establish acceptance of distant jobs.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
