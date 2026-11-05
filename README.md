# Roblox Script Hub

A growing collection of game-specific scripts using [MattLib](https://github.com/Cybersize/MattLib), with one place-aware loader.

## One loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Cybersize/roblox-script-hub/main/loader.luau"))()
```

The loader reads `manifest.json`, detects `game.PlaceId`, and loads only that game's script. Unsupported places produce a console message and run no game script. This loader is for a Roblox client environment that provides `loadstring` and `game:HttpGet`, not an ordinary Studio LocalScript.

## Available scripts

| Place ID | Script | Features |
| --- | --- | --- |
| `129852792970565` | [Egg Teleport](games/129852792970565.luau) | Rarity selection, nearest-egg teleport/pickup, optional auto-collect and return |
| `104432981439032` | [Restaurant Auto Play](games/104432981439032.luau) | Seat assignment, orders, cooking/collecting, serving, table clearing and dishwashing |

**RightShift** hides/shows either menu. The restaurant script starts stopped; press **Start all** to enable its duties. Cooking uses the game's normal timers. Ingredient farming, purchases, spawning customers and staff configuration are not included.

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

3. Run `python tools/validate_manifest.py`.
4. Commit and push to `main`. The same loadstring now supports the new place.

To temporarily disable a game, set its `enabled` field to `false`. To support multiple places with the same script, register each place ID with the appropriate path; that script must also permit those places.

Game scripts should default to stopped, guard their supported place IDs, stop their previous copy on reload, validate server responses, and provide an Unload control. Never commit access tokens, `.rbxl` snapshots, or account credentials.

## Validation status

All three Luau files compiled successfully. The universal loader passed 17 isolated routing/error-handling checks without executing gameplay. Isolated game-logic tests also passed (15 egg checks and 31 restaurant planner checks). The restaurant planner selected a valid task from the live state in read-only mode. End-to-end live gameplay has not been verified.

The game scripts fetch a fixed MattLib revision. MattLib is a separate MIT-licensed dependency; its source and assets are not bundled here. Updating files on `main` changes what the shared loadstring loads.
