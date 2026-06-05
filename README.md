# Pulse Arena

A fast, low-poly **first-person multiplayer shooter** for mobile browsers, built
with **Godot 4.6.3** (Compatibility / WebGL2, single-threaded web export) and
**serverless multiplayer** over **Supabase Realtime broadcast**. Two players join
the same room, spawn in a small neon arena with cover blocks, and duel live —
first to **10 hits wins**.

## Play

Open the game, **tap to start**, and share the link (it contains `?room=XXXXX`)
with a friend — or just open the **same link in a second tab** to play both
sides. The two clients broadcast their position, aim and shots to each other in
real time.

- **Two players, one room.** The room code lives in the URL (`?room=RT23U`). Same
  room ⇒ same arena ⇒ you see and shoot each other.
- **Goal.** Each tag is 1 hit. **First to 10 hits wins.** 3 HP per life; when
  downed you respawn after 2 seconds at a random spawn point.

## Controls

| | Move | Look / Aim | Fire |
|---|---|---|---|
| **Mobile** | left-side virtual joystick | drag the right side of the screen | **FIRE** button (bottom-right) |
| **Desktop** | `WASD` / arrows | move the mouse (click once to lock the pointer) | click or `Space` |

The energy blaster has a bright muzzle flash, a glowing tracer bolt, and a
hit-marker + screen-shake when you tag your opponent.

## How the multiplayer works (serverless)

There is **no game server**. Both browsers are peers on a public **Supabase
Realtime broadcast** channel named `game:<room>` (client-authoritative,
friends-play). Each peer sends:

- `st` — its transform (position + yaw + pitch + HP + downed) ~12×/sec,
- `sh` — a shot event so the other side draws your muzzle flash + tracer,
- `hit` — when its local raycast tags the opponent.

Scores stay in sync because every `hit` message is counted once on the shooter
and once on the target. No database tables are used — broadcast messages are
ephemeral, so the game needs **no schema and no persistence**.

The browser talks to Supabase through a tiny JS bridge (`web/bridge.js`); GDScript
calls it via `JavaScriptBridge` (see `net.gd`). The Supabase JS SDK is loaded by
the export's HTML shell from the official CDN.

## Project layout

| File | Role |
|---|---|
| `project.godot` | Compatibility renderer, input map, `Net` autoload, mobile display settings |
| `main.gd` | Arena, first-person player (move/look/shoot), FX, game loop, networking glue |
| `hud.gd` | Crosshair, joystick, FIRE button, health bar, score, hit-marker, tap-to-start / downed / win overlays |
| `remote_player.gd` | Networked opponent avatar (interpolation, aim, hittable area, death hide) |
| `net.gd` | Serverless multiplayer autoload (Supabase Realtime broadcast) |
| `web/bridge.js` | JS ↔ GDScript Supabase bridge |
| `export_presets.cfg` | `Web` preset (nothreads) + HTML head that loads the SDK + bridge |

## Build it yourself

Requires **Godot 4.6.3** with the **web (nothreads)** export templates.

```bash
godot --headless --path . --import
godot --headless --path . --export-release "Web" out/index.html
cp web/bridge.js out/                          # served next to index.html
```

Then serve `out/` over HTTP (any static server) and open it in a browser. The
arena renders with the **Compatibility (WebGL2)** renderer and the export is
single-threaded (`nothreads`) so it runs in Safari, Chrome and Firefox on phones
without COOP/COEP headers.

## Backend configuration

The Supabase **project URL** and **publishable key** are set in `web/bridge.js`
(see `.env.example`). The publishable key is safe to ship in the browser. No
tables, auth or RLS are required — only the Realtime broadcast service.
