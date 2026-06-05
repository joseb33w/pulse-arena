# Goal

Build **Pulse Arena**: a fast, low-poly, first-person multiplayer shooter for
mobile browsers using Godot 4.6.3 (Compatibility/WebGL2, nothreads web export)
and serverless multiplayer over **Supabase Realtime broadcast**. Two players
join the same room (`?room=...`), spawn in a small neon arena with cover blocks,
and shoot each other live. First to 10 hits wins.

# Files to touch

- `project.godot` — Compatibility renderer, input map (move/look/fire actions),
  `Net` autoload, mobile stretch/touch settings.
- `main.gd` — orchestrator: builds the neon arena + cover, first-person local
  player (move/look/shoot), HUD (joystick, fire button, health bar, score,
  crosshair, hit-marker), tap-to-start, screen-shake, networking glue, win flow.
- `remote_player.gd` — networked opponent avatar (interpolated transform, head/
  gun aim, hittable Area3D, muzzle flash + tracer on remote shots, death hide).
- `net.gd` — serverless multiplayer autoload (Supabase Realtime broadcast).
- `web/bridge.js` — JS bridge; Supabase URL + anon key filled in at build.
- `export_presets.cfg` — Web preset head_include loads Supabase SDK + bridge.js.
- `README.md`, `.env.example` — docs + non-secret config reference.

# Verification approach

- `godot --headless --export-release "Web"` then run the vetted smoke verifier
  (engine boots, canvas present, console clean, frames captured) + eyeball the
  saved screenshots for the neon arena.
- Node integration test using `@supabase/supabase-js`: two clients join the same
  `game:<room>` broadcast channel with the session's real URL + publishable key
  and confirm a `state`/`shot` payload sent by one peer is delivered to the other
  (proves the live multiplayer transport works tab-to-tab).
- Two-context Playwright load of the exported game in the same `?room=` to
  confirm both clients boot and the bridge connects.
- Deploy `out/` to R2 for a clickable preview play link.

# Out of scope

- No persistence / database tables (pure ephemeral Realtime broadcast).
- No accounts/auth (anon publishable key, friends-play, client-authoritative).
- No server-authoritative anti-cheat (serverless casual multiplayer).
- More than 2 players, matchmaking, ranked play, audio music beds.
