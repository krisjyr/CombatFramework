# Combat Framework — Character Controller Guide (v5)

## 1. Real directional momentum (Assassin's Creed / Tom Clancy feel)

### 1.1 Why the old inertia couldn't do this
The previous inertia system ramped a single **scalar** `CurrentSpeed` toward a target and
wrote it to `Humanoid.WalkSpeed`. That gives you speed-up/slow-down inertia, but it can
never give you *directional* inertia — Roblox's Humanoid always moves the character
instantly in whatever `Humanoid.MoveDirection` currently is. You cannot make a
Humanoid-driven character "carve" through a turn (travel in a direction that lags behind
new input) by only setting `WalkSpeed`; the character always immediately reorients to face
and move in the current input direction, at whatever speed WalkSpeed says. There's no way
to fake "can't juke instantly at a sprint" on top of that model.

### 1.2 The fix: hand planar movement to a real velocity vector
New module: `Movement/MomentumController.lua`. It:
1. Pins `Humanoid.WalkSpeed` to `0.01` once, so Humanoid's own walk controller stops trying
   to move the character (it would otherwise fight us every physics step).
2. Drives X/Z motion itself via a **`LinearVelocity` constraint** (`ForceLimitMode =
   PerAxis`, `MaxAxesForce = (huge, 0, huge)` — zero force on Y, so it can never fight
   gravity or jumping).
3. Simulates a real `CurrentVelocity: Vector3` that must be **steered**, not snapped:
   - **Magnitude** (speed) ramps via Acceleration/Deceleration — same idea as before.
   - **Direction** is separately steered at a turn rate (degrees/sec) that shrinks the
     faster you're already going:
     ```lua
     local speedFraction = clamp(currentSpeed / FULL_SPEED_REFERENCE, 0, 1)
     local turnRateFraction = 1 - (1 - MIN_TURN_RATE_FRACTION_AT_FULL_SPEED) * speedFraction
     ```
     Near a stop you can spin to face any direction almost instantly (`turnRateFraction ≈
     1`); at a sprint you only get ~28% of the base turn rate, so redirecting sharply takes
     real time and the character visibly carves a curve instead of snapping. That's the
     actual mechanic behind "can't juke instantly at full speed" in Assassin's Creed /
     Tom Clancy-style controllers.
   - Releasing input doesn't erase the direction — the character keeps sliding along its
     **last heading** while speed bleeds off via Deceleration, then stops naturally. No
     snap-to-zero.

Tuning knobs, top of `MomentumController.lua`:
```lua
local BASE_TURN_RATE_DEG_PER_SEC = 260       -- turn rate available at (near) zero speed
local MIN_TURN_RATE_FRACTION_AT_FULL_SPEED = 0.28
local FULL_SPEED_REFERENCE = 20              -- studs/s; speed at which turn rate bottoms out
```

### 1.3 Also fixes character-local gravity (closes an old TODO)
`MomentumController` also owns a `VectorForce` that cancels/replaces engine gravity **on
the Y axis only**, computed from `MovementProfile.Gravity`:
```lua
Force.Y = (desiredGravity.Y - (-workspace.Gravity)) * RootPart.AssemblyMass
```
This is what makes Low/High/Zero-G Movement Profiles (Ch 2.3) physically real instead of
just a config value nothing reads — previously this was a commented-out line waiting for
exactly this kind of constraint to exist.

### 1.4 Ownership model (renamed `isServer` → `ownsPhysics`)
Constraints only mean anything on the side that actually **owns physics simulation** for
that character:

| Who | `ownsPhysics` | Why |
|---|---|---|
| Controlling client, for a player's own character | `true` | Default Roblox networking — the client simulates its own character's physics |
| Server, for a player's character | `false` | Server never owns a player's physics; only sets ownership-independent Humanoid properties (`JumpPower`, `HipHeight`) for validation |
| Server, for a future AI/NPC entity (Ch 13) | `true` | Server DOES own physics for server-controlled entities |

`MovementClient.client.lua` now constructs with `true`; `MovementServer.server.lua`
constructs with `false` (both were effectively backwards under the old `isServer` naming,
which was never actually branched on for anything before this pass).

When `ownsPhysics = false`, `CharacterController.Update()` deliberately **never touches
`WalkSpeed`** — the owning client's `MomentumController` pins that once and this side must
never fight it (setting it from both sides every tick would cause visible flicker).

### 1.5 `IsMoving()` upgraded
Now that releasing input slides to a stop instead of snapping, "is moving" needs to mean
"has real velocity," not "is a key held." On the owning side it reads
`MomentumController.CurrentVelocity.Magnitude`; on the non-owning (server, for a player)
side it falls back to the character's actual replicated `RootPart.AssemblyLinearVelocity`
— true regardless of who owns physics, so `AnimationController`'s Idle/Move swap stays
correct through the whole slide-to-a-stop.

### 1.6 Necessary related fix: gravity zones now sync to the client
Because gravity is now a *real force* applied client-side, a server-detected gravity zone
(QuickZone) is meaningless unless the client is told about it — the client's independent
`CharacterController`/`ModifierStack` has no other way to learn a zone was entered. New
`GravitySync` RemoteEvent: `GravityZoneHandler.lua` mirrors every
`SetGravityOverride`/`ClearGravityOverride` it makes for a player down to that player's
client, which replays the same call locally. Without this, gravity zones would silently do
nothing now that force application moved off the server.

---

## 2. Slope/stair/bump detection — multi-point median sampling

### 2.1 The gap in the previous version
The prior dual-raycast version (one ray at the feet, one a few studs ahead) correctly
caught continuous ramps, but a single 2-point reading can't distinguish "one real
staircase" from "one random pebble/curb that happens to sit under the far sample point" —
both just look like one height delta over one distance to a 2-point sample.

### 2.2 The fix
`SlopeController._sampleHeights` now casts **6 evenly spaced rays** (5 one-stud segments)
along the movement direction. `_estimateSignedSlopeAngle` computes the angle of **each
segment** individually, then takes the **median** of those 5 segment angles rather than
the raw endpoint-to-endpoint delta:

```lua
local SAMPLE_COUNT = 6              -- 5 segments
local TOTAL_SAMPLE_DISTANCE = 5      -- studs; ~1 stud per segment, matching typical stair tread depth
```

This single change gives both requested behaviors for free:
- **A small isolated bump/part/curb** only disturbs one (or two) of the 5 segments; the
  median naturally discards the top-and-bottom outliers, so an isolated bump barely moves
  the result — it doesn't slow you down at all in practice, exactly as asked.
- **A real staircase — even one physically built from a bunch of small individual
  part-risers** — produces a *similar* height delta across every segment, so the median
  correctly reflects that consistent incline and the penalty applies, exactly as it would
  for a continuous ramp of the same overall angle. Bump detection and stair detection are
  the same mechanism now, tuned by the same two constants.

If a raycast in the chain misses entirely (e.g. right at the edge of a platform), the whole
sample is discarded for that frame (returns no penalty) rather than computing a
partial/unreliable median.

### 2.3 Unchanged from last pass
- Symmetric penalty: both uphill and downhill slow you down by the same `|angle|`-driven
  curve (no more downhill speed bonus).
- `SlopeController.Update(dt)` still returns two values — `speedMultiplier` (caps top
  speed via the `ModifierStack`, same source `"Slope"`) and `momentumMultiplier` (now
  applied to the `Acceleration`/`Deceleration` values handed to `MomentumController`,
  instead of the old scalar system) — so an incline or staircase affects both top speed
  *and* how nimble the character feels accelerating/braking, not just a lower ceiling you
  still snap to instantly.

Tuning knobs, `Movement/SlopeController.lua`:
```lua
local SAMPLE_COUNT = 6
local TOTAL_SAMPLE_DISTANCE = 5
local FLAT_ANGLE_DEADZONE = 2        -- degrees; only filters real floating-point noise
local MAX_WALKABLE_ANGLE = 50         -- degrees; full penalty reached here
local MIN_SPEED_MULTIPLIER = 0.55
local MIN_MOMENTUM_MULTIPLIER = 0.6
local SMOOTHING_RATE = 6
```
If your actual stair geometry has a different tread depth than ~1 stud, adjust
`TOTAL_SAMPLE_DISTANCE` / `SAMPLE_COUNT` together to keep segment length matched to it —
segments much shorter than a single tread will re-introduce the old "reads individual
treads as noise" problem, and segments much longer than the whole staircase will smear the
transition into/out of it.

---

## 3. Updated file list (new/changed this pass)

```
src/ReplicatedStorage/CombatFramework/Movement/
├── MomentumController.lua       -- NEW: LinearVelocity-driven directional momentum + Y-gravity VectorForce
├── SlopeController.lua          -- REWRITTEN: 6-point median sampling (bumps vs stairs/ramps)
└── CharacterController.lua      -- REWRITTEN: ownsPhysics model, Momentum integration, IsMoving() upgrade

src/StarterPlayer/StarterPlayerScripts/CombatFramework/MovementClient.client.lua
    -- constructs with ownsPhysics = true, new GravitySync listener

src/ServerScriptService/CombatFramework/
├── MovementServer.server.lua    -- constructs with ownsPhysics = false
└── GravityZoneHandler.lua       -- mirrors gravity changes to the client via GravitySync

default.project.json             -- + GravitySync RemoteEvent
```

---

## 4. Things worth testing in Studio before shipping this

This pass makes real physics-level changes (constraints, force application) that are much
more sensitive to in-engine testing than pure data/config changes:

- **Jump feel with `WalkSpeed` pinned near zero.** Jumping is still entirely Humanoid-owned
  (`JumpPower`, gravity, state machine) and untouched by the planar `LinearVelocity`
  constraint, but confirm jump arcs still feel right combined with the new momentum system
  carrying horizontal velocity through a jump.
- **`LinearVelocity`'s `MaxAxesForce` axes are local to the Attachment**, not world space,
  regardless of the constraint's `RelativeTo` setting for velocity. This only stays
  equivalent to world axes if the character never pitches/rolls (only yaws) — true for a
  normal upright Humanoid, but worth double-checking if you ever add ragdoll or non-upright
  states later.
- **AI/NPC entities (Ch 13):** once implemented, construct their `CharacterController` with
  `ownsPhysics = true` **on the server**, exactly like a player's client — the server does
  own physics for server-controlled entities, so this is the one place `ownsPhysics = true`
  legitimately happens outside the owning client.
- **Performance:** `SlopeController` now casts 6 rays per `Update(dt)` per moving character
  (previously 2). At high player counts this adds up; a reasonable future optimization is
  throttling the slope sample to every Nth frame and interpolating, rather than every
  Heartbeat.

## 5. Suggested next passes (unchanged)

1. Status Effect Framework (Ch 8).
2. Weapon Framework + Ballistics (Ch 3-4) on `fastcast2`.
3. More Zones on `quickzone`.
4. Medical Framework (Ch 7) — replace `FallService`'s placeholder damage call.
5. Bring `cmdr` online — see the command list documented in
   `FallServiceBootstrap.server.lua`.
