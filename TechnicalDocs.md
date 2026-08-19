# Combat Framework — Technical Design Document
 
**Version 2.0 (Unified)**
**Platform:** Roblox
**Genre Target:** PvP Tactical Combat Sandbox with Sci-Fi / Anomalous Expansion Support
 
---
 
## Guiding Principle
 
> **There is no weapon system. There is no medical system. There is no movement system. There is no magic system.**
> **There is only the Combat Framework — a set of Entities driven by Components, and a set of Effects driven by Statuses.**
 
Every mechanic in this document — a rifle, a broken leg, a gravity anomaly, a vampire's regeneration, a railgun slug — is built from the same two primitives:
 
- **Components** — attached to entities, they define *what an object is and what it can do* (identity, fire control, ammo, movement, health, sensors, animation, network state).
- **Statuses** — applied to entities, they define *what is currently happening to it* (bleeding, burning, suppressed, gravity-shifted, hallucinating).
Nothing in the framework hardcodes "a rifle does X" or "fire damages Y." Instead, a rifle *is* a bundle of components, and firing it *applies* a status (or several) to whatever it hits. This is what allows the same core engine to run a grounded Tarkov-style firefight and a supernatural anomaly sandbox without forking the codebase.
 
---
 
## Table of Contents
 
1. Architecture
2. Character Controller
3. Weapon Framework
4. Ballistics
5. Attachment Framework
6. Ammunition Framework
7. Medical Framework
8. Status Effect Framework
9. Animation Framework
10. Audio Framework
11. Visual Effects Framework
12. Interaction Framework
13. AI Compatibility
14. Developer API
15. Configuration System
16. Future Expansion
17. Recommended Implementation Stack (Community Modules)
---
 
# 1. Architecture
 
## 1.1 Framework Philosophy
 
The Combat Framework is a modular, data-driven combat architecture built to support realistic tactical combat (in the spirit of *Escape from Tarkov*, *Squad*, *Insurgency: Sandstorm*, *Arma*, *Bodycam*, and *Ready or Not*) while remaining fully expandable into supernatural abilities, anomalous environments, sci-fi weapons, experimental technology, and non-standard movement — all without ever touching core code.
 
**Core rule: zero hardcoded gameplay logic.** Every mechanic — damage, fire rate, magazine size, reload time, projectile behavior, movement speed, medical effect, status duration, armor value, attachment modifier, power cost — lives in configuration data, not in scripts.
 
A developer adding a new weapon, ability, armor piece, or status should only ever need to:
 
1. Author a configuration asset.
2. Assign the relevant components.
3. Attach animations and audio.
4. Declare which statuses it applies and which equipment/ammo it's compatible with.
No new core scripts, no new subsystem, no forked logic path. If a mechanic requires a new script, that is a sign the framework is missing a component or status hook — not a reason to special-case the weapon.
 
> **Implementation note:** every cross-system communication described in this document (`WeaponFired`, `DamageReceived`, `StatusApplied`, `StanceChanged`, `GravityChanged`, etc. — see Chapter 8.6 and Chapter 17.5) is intended to be implemented as a **NamedSignal** (Chapter 17.5) rather than a raw `BindableEvent`/`RemoteEvent`, so that event payloads are self-documenting and type-checked at the call site instead of relying on positional argument order.
 
## 1.2 ECS / Component Architecture
 
The framework follows an **Entity-Component** model built on Roblox primitives: Models, Attributes, CollectionService tags, and ModuleScripts standing in for a formal ECS.
 
**Everything is an entity.** Players, weapons, projectiles, grenades, shields, medical items, deployables, zones, abilities, vehicles, turrets, and AI are all entities. What differentiates them is which components are attached.
 
**Player Entity** — composed of: Character, Health, Movement, Gravity, Stamina, Equipment, Inventory, Weapon Handler, Camera, Animation, Audio, Interaction, Status Container, Network, and Sensor Suite components.
 
**Weapon Entity** — composed of: Weapon Identity, Fire Control, Ammo, Projectile, Recoil, Handling, Attachment, Durability, Heat, Malfunction, Animation, Audio, VFX, Interaction, and Network components.
 
The same compositional pattern extends to projectiles, grenades, shields, medical items, deployables, zones, abilities, drones, and AI entities. A supernatural gravity anomaly and a rifle magazine are structurally the same kind of object to the engine: a bag of components driven by data.
 
**Why this matters:** because behavior lives in components rather than in per-object scripts, adding a flamethrower, a railgun, or a "reality cutter" sword does not require new simulation code — it requires assigning existing components (Projectile, Heat, Ammo, Status Application) with new configuration values.
 
## 1.3 Client / Server Responsibilities
 
**Server authority** covers everything that must not be trusted to the client:
 
- Damage calculation and hit validation
- Projectile results and penetration/ricochet outcomes
- Inventory and equipment changes
- Status application and removal
- Medical effects
- Weapon state (ammo, heat, durability, malfunction)
- Movement validation
- Threat classification outcomes (friendly/hostile/unknown)
**Client responsibility** covers everything that is felt, not adjudicated:
 
- Input collection
- Visual prediction (firing, recoil, movement, camera)
- Animation playback
- Local cosmetic effects
- HUD rendering
The dividing line is simple: **the client renders what probably happened; the server decides what actually happened.**
 
## 1.4 Networking
 
All network traffic is batched and prioritized to respect Roblox's bandwidth and replication limits. Replication is tiered:
 
| Priority | Examples |
|---|---|
| High | position, weapon fire, damage, critical statuses, downed/death |
| Medium | reloads, equipment changes, medical actions, movement states |
| Low | cosmetics, distant effects, inspect animations |
 
Unreliable events are used wherever an occasional dropped packet is acceptable (cosmetic effects, distant impacts); reliable events are reserved for state-changing actions (damage, status application, inventory changes).
 
**Anti-cheat / validation** rejects impossible fire rates, invalid teleportation, unauthorized equipment, modified damage values, illegal movement profiles, and impossible status applications. Every important action — shooting, moving, reloading, healing, equipping — is re-validated server-side regardless of what the client claims happened.
 
## 1.5 Prediction & Lag Compensation
 
**Client prediction** covers weapon firing, recoil, animation, movement, camera effects, and equipment switching. The server confirms or corrects; a mispredicted shot (e.g. the client fired with no ammo) is rejected and the animation/state is rolled back.
 
**Lag compensation** requires the server to maintain a short rolling history of player positions, rotations, and states. When a shot arrives, the server rewinds to the relevant timestamp, reconstructs the historical hitbox positions, and validates the hit against that snapshot rather than the player's current position. This is the only way to keep hit registration fair across real-world latency, since Roblox provides no built-in rewind or snapshot history — the framework must implement it.
 
## 1.6 Performance
 
Roblox imposes hard constraints the framework must design around:
 
- No true multi-threading (main thread + limited parallel Luau actors)
- Strict bandwidth/replication limits
- Approximate physics; simulating hundreds of continuous projectiles is expensive
- Instance-count and memory ceilings
- No native rewind/snapshot system (must be built manually, see 1.5)
- Script execution time budgets
- Streaming/occlusion affecting visibility and replication unpredictably at range
Design responses:
 
- **Pooling** for projectiles, effects, status entities, and temporary zones — never instantiate-and-destroy in hot paths.
- **Distance-based simulation and replication prioritization** — distant combat gets simplified simulation and lower-priority replication.
- **Server-authoritative critical logic, lightweight client prediction** — keep the expensive validation server-side, keep the client feeling responsive.
- **Attributes and CollectionService tags over deep class hierarchies** — favor flat, data-tagged composition over inheritance.
- **Batched, prioritized, and unreliable-where-safe networking.**
- **Aggressive cleanup** of expired statuses, spent projectiles, and finished effects.
---
 
# 2. Character Controller
 
The Character Controller is the component bundle that governs how a player entity occupies and moves through the world, and it is deliberately built so that **movement is combat**, not a layer bolted on beside it — weapon handling, accuracy, and stamina all read directly from movement state.
 
## 2.1 Movement
 
Movement is driven by **Movement Profiles** — swappable physics definitions rather than a single hardcoded controller. Each profile defines gravity direction, acceleration, top speed, jump strength, friction, and surface interaction rules.
 
Example profiles: Standard Human, Low Gravity, High Gravity, Zero Gravity, Wall Walking, Ceiling Walking, Flying, Swimming, Magnetic Adhesion, Anomaly Movement, Heavy Armor, Powered Exo.
 
Switching profiles is how the same character controller supports a grounded soldier, a zero-G astronaut, and a wall-crawling anomaly victim without three separate movement scripts — the profile is data, applied like any other component configuration, and can itself be granted or changed by a Status (see Chapter 8).
 
## 2.2 Stances
 
Stances modify speed, visibility, stability, recoil, noise, and weapon mobility simultaneously — a stance is really just a bundled set of modifiers applied through the same Modifier system statuses use.
 
| Stance | Notable effects |
|---|---|
| Standing | full speed, max visibility, max weapon mobility |
| Walking / Tactical Walk | reduced noise, better stability, higher weapon readiness |
| Crouching | reduced profile/speed, reduced recoil, increased stability |
| Prone | max stability, min profile, restricted/slow transitions |
| Sprinting / Tactical Sprint | increased speed, weapon lowered, increased noise/exhaustion |
| Jumping / Falling | supports fall damage, landing impact, equipment reaction |
| Mounted | tied to mounted-weapon and vehicle interaction |
| Climbing / Swimming | tied to traversal and water systems |
| Wall Walking / Ceiling Walking / Zero Gravity | tied to Movement Profiles and gravity systems |
 
Stance transitions can be restricted by equipped weapon size, injuries, or carried weight — e.g. a mounted machine gun disallows sprinting or a fast crouch-to-prone transition.
 
## 2.3 Gravity Profiles
 
Gravity is a **configurable vector**, not an engine constant. Default gravity is `Vector3(0, -196.2, 0)`; a wall-adhesion zone might apply `Vector3(196.2, 0, 0)`, a ceiling zone `Vector3(0, 196.2, 0)`.
 
Critically, **character gravity and projectile gravity are independent systems.** A player walking on a ceiling has their orientation, camera, and animation reoriented to the local "down" — but a bullet they fire keeps falling toward world-down, using its own configured ballistic gravity. This separation is what allows physically consistent gunplay inside physically inconsistent environments.
 
## 2.4 Wall Walking / Ceiling Walking / Surface Adhesion
 
Surface Adhesion lets a Movement Profile attach a character to floors, walls, ceilings, or arbitrary custom geometry. The system calculates:
 
- Surface normal
- Player orientation relative to that normal
- Camera rotation to match
- Animation alignment (foot placement, body lean)
Combat must remain fully functional while attached: aiming, recoil, reloading, throwing, and equipment usage all need to work whether "down" is the floor or a wall six feet to the player's left.
 
## 2.5 Swimming
 
Water is treated as an environmental state affecting movement, weapon handling, visibility, audio, and temperature. Supported states: standing in shallow water, swimming, diving, underwater movement. Weapons may define a waterproof rating, reduced underwater accuracy, a failure chance, or require special underwater ammunition.
 
## 2.6 Vaulting
 
Traversal — vaulting, mantling, climbing, jumping obstacles, sliding under objects — lets players navigate combat spaces beyond simple flat-ground movement. Traversal actions are gated by weight, injury state, and stamina, using the same modifier pipeline as everything else, so a broken leg or an overloaded backpack naturally disables or slows a vault rather than requiring special-cased checks.
 
## 2.7 Weight
 
Weight comes from equipped weapons, armor, and inventory contents, and feeds directly into the movement modifier stack: it affects movement speed, stamina drain, weapon sway, handling speed, and ADS speed. Load-Bearing / Strength Assistance equipment (e.g. powered exo-suits) applies a modifier that nullifies or reduces these penalties — it does not bypass the weight system, it counteracts it within the same pipeline.
 
## 2.8 Stamina
 
Stamina tracks current/max value, recovery rate, and exhaustion level. It is consumed by sprinting, jumping, climbing, swimming, carrying downed players, and heavy-equipment use. When exhausted, a character experiences increased weapon sway, slower movement, audible heavy breathing, and reduced available actions — all expressed as an Exhausted status rather than special-cased logic.
 
**Breathing** is a related sub-state (Normal, Heavy Breathing, Exhausted, Pain Breathing, Chemical Difficulty, Low Oxygen) that layers into aim stability. Holding one's breath reduces weapon sway at a stamina cost and for a limited duration — implemented as a temporary status with a resource cost, exactly like any ability. You can hold breath until you go unconcious from lack of oxygen. The amount of breath you can hold and stamina you can use also depends on your stats/skills and how much oxygen there is in the enviroment (If you are super high then there isn't much oxygen to work with)
 
## 2.9 Camera
 
Two camera modes are supported:
 
- **First person** — forced whenever a weapon is equipped; supports view-model rendering, body awareness, weapon sway, recoil, and environmental effects.
- **Third person** — available when unarmed or in defined non-combat states (vehicles, social areas).
**Camera effects** layer on top of the base view: recoil kick, explosion shake, sprint bob, injury reaction, suppression instability, vision impairment, thermal/night-vision overlays, and general information overlays (threat markers, ammo readouts). Every one of these is implemented as a camera modifier a status or equipment component can push onto the stack, not a bespoke camera state machine per effect.
 
---
 
# 3. Weapon Framework
 
## 3.1 Overview
 
A weapon is not defined by its category — it is a **collection of components plus configuration data**. A bolt-action rifle, a flamethrower, a railgun, and a fictional anomaly weapon all run through the identical Weapon Entity structure:
 
```
Weapon
├── Weapon Identity
├── Fire Control
├── Ammo
├── Projectile
├── Recoil
├── Handling
├── Attachment
├── Durability
├── Heat
├── Malfunction
├── Animation
├── Audio
├── VFX
├── Interaction
└── Network
```
 
**Weapon Identity** carries name, category, manufacturer (optional), weight, size, and starting durability — pure metadata that other components read.
 
**Fire Control** exposes the configurable fire modes: Safe, Semi, Burst (2/3/5-round, etc.), Automatic, Charge (railguns, energy weapons — configurable charge duration and damage scaling), Continuous (flamethrowers, lasers, particle weapons), and Programmable (smart ammo, delayed shots, multi-projectile firing, alternating barrels).
 
## 3.2 Firearms
 
Conventional firearms are the baseline expression of the Weapon Entity: Fire Control set to Semi/Burst/Automatic, Projectile set to Physical, Ammo referencing conventional ammunition types (Section 6), Recoil and Handling tuned by weight/caliber, and Malfunction/Heat active per Chapter 3.7–3.8 concepts inherited from durability and use.
 
## 3.3 Melee
 
Melee weapons use the same entity shell with a lighter component set: range, damage, attack speed, stamina cost, hit zones, and animation replace the projectile/ammo stack. Supported interactions include blocking, parrying, weapon collision, staggering, and disarming. Melee damage is still processed through the standard damage pipeline (armor → body region → trauma → status), so a knife and a rifle round resolve identically once they've dealt their raw damage.
 
## 3.4 Throwables
 
Throwables (fragmentation grenades, flashbangs, smoke, incendiaries, gas, EMP, throwing knives, custom devices) are independent entities with their own component set:
 
```
Throwable
├── Physics
├── Fuse (Timed / Impact / Remote / Proximity / Pressure)
├── Explosion
├── Damage
├── Status
├── Audio
└── VFX
```
 
Throw mechanics (strength, arc, bounce, roll, spin, wind interaction, collision) are configurable per-item. Path prediction can be surfaced via equipped armor sensors as a HUD overlay rather than being intrinsic to the throwable itself.
 
## 3.5 Mounted Weapons
 
Mounted weapons (machine guns, grenade launchers, turrets, autocannons, mounted railguns) add Mount properties on top of the standard weapon shell: rotation limits, elevation limits, operator position, and reload requirements. Players can enter, exit, reload, repair, and operate a mount as a defined Interaction (Chapter 12).
 
## 3.6 Shields
 
Shields are defensive equipment entities defining coverage area, durability, material, weight, movement penalty, and visibility. They interact with ballistics, explosions, melee, fire, and energy weapons through the same material-interaction rules as any other cover object (Chapter 4.7), and support blocking, bashing, deployment, damage, and destruction.
 
## 3.7 Akimbo
 
Dual-wielding maintains **fully independent** state per weapon: ammunition, fire state, recoil, durability, heat, and attachments are tracked separately for each hand. Fire control supports simultaneous fire, alternating fire, independent firing, or manual weapon selection. Akimbo carries built-in restrictions — reduced accuracy, increased recoil, slower reloads, reduced ADS capability — expressed as standing modifiers on the dual-wield state rather than special-cased weapon math.
 
## 3.8 Deployables
 
Deployables (turrets, mines, cameras, sensors, barricades, medical/ammo stations) share a Placement + Interaction + Health + Network + Effect component structure. They are simulated identically whether player-placed or pre-authored on a map, since both paths produce the same entity shape.
 
## 3.9 Heavy Weapons
 
Heavy weapons (machine guns, launchers, railguns, flamethrowers) are simply firearms/energy weapons at the high end of the weight, heat, and recoil axes — see Chapters 3.1, and the dedicated Energy Weapon, Flamethrower, and Railgun frameworks (Chapter 16.4) for their special-case component tuning, all still built from the same Weapon Entity.
 
## 3.10 Weapon State Machine
 
Weapon state prevents conflicting actions: `Holstered → Equipping → Ready → Firing → Reloading → Inspecting → Jammed → Overheated → Disabled`. Each state defines allowed/blocked actions (e.g. Reloading allows movement and cancellation, blocks shooting and sprinting).
 
## 3.11 Malfunctions
 
Malfunctions are tactical consequences, not random frustration — they scale with weapon durability, ammunition quality, environmental conditions, heat, maintenance, and player actions.
 
| Malfunction | Typical cause | Resolution |
|---|---|---|
| Failure to Feed | magazine issue, damaged ammo, dirty weapon | clear malfunction |
| Failure to Extract | damaged extractor, poor ammo | manual clearing |
| Double Feed | feeding failure cascade | longer clearing procedure |
| Failure to Fire | bad ammo, damaged firing pin | — |
| Overheating | sustained fire | increased spread, weapon damage, risk of cook-off |
| Cook-Off | extreme overheating | weapon fires without trigger input |
 
## 3.12 Heat
 
Weapons track thermal state through discrete steps: `Cold → Normal → Warm → Hot → Critical → Overheated → Damaged`, driven by firing, charging, energy usage, or ambient temperature, and reduced by barrel type, material, weather, time, or dedicated cooling systems. Heat feeds into accuracy, barrel condition, damage consistency, and suppressor durability.
 
## 3.13 Weapon Resting, Bipods, Ready Positions
 
Weapons can rest against compatible surfaces (walls, windows, cover, barricades, vehicles, deployables) for reduced recoil/sway and improved accuracy, at the cost of reduced movement and rotation. Bipod-compatible weapons (machine guns, sniper/heavy rifles) get a stronger version of the same benefit when deployed, with stronger movement restrictions (no sprinting while deployed, limited turning).
 
Ready positions (`Lowered / Low Ready / High Ready / Aimed / Sprint Position`) trade reaction speed against movement speed and fatigue, and weapon inspection/maintenance lets players check condition, clean, repair, and replace parts to slow the malfunction curve.
 
---
 
# 4. Ballistics
 
> **Implementation note:** the Physical and Beam projectile paths in this chapter are designed to sit directly on top of **FastCast2** (see Chapter 17.2). FastCast2 already solves parallel-scripted projectile casting, statically-typed projectile definitions, and extension hooks for piercing/ricochet-style behavior — the Ballistics chapter below should be read as "the ruleset FastCast2's `CanPierceCallback`, `OnRayHit`, and velocity/gravity settings are configured to enforce," not as a from-scratch physics engine to build.
 
## 4.1 Projectile Types
 
| Type | Description | Typical use |
|---|---|---|
| **Hitscan** | instant raycast, no physical travel time, supports ray penetration | lasers, extremely fast weapons |
| **Physical** | fully simulated (velocity, gravity, drag, mass, spin, energy loss) | bullets, rockets, grenades |
| **Continuous** | streaming volume with duration, range, spread, pressure, density | flamethrowers, chemical sprays, energy streams |
| **Beam** | sustained line with width, damage rate, heat, energy consumption | lasers, energy weapons |
 
## 4.2 Ballistic Calculation
 
Every physical projectile can define starting velocity, acceleration, gravity influence, drag, mass, diameter, shape, energy, penetration, and fragmentation behavior. Impact energy is computed as:
 
```
Energy = 0.5 × Mass × Velocity²
```
 
which drives damage, penetration, and armor interaction. Bullet drop is calculated independently of player movement, using the projectile's own gravity vector (see 2.3) — this is the mechanism that keeps ballistics predictable even inside gravity-anomaly zones. Wind is an optional modifier defined by direction, strength, and per-projectile sensitivity.
 
## 4.3 Penetration
 
Penetration depends on projectile energy, projectile type, target material resistance, impact angle, and remaining velocity after any prior penetration. This is what allows a round to pass through drywall and still injure a target behind it, at reduced lethality.
 
## 4.4 Ricochet
 
Ricochet chance is computed from impact angle, material hardness, projectile shape, and velocity — shallow-angle hits against hard materials (steel, concrete) are the primary ricochet case.
 
## 4.5 Materials
 
Every physical material in the world (flesh, bone, wood, glass, concrete, steel, aluminum, armor plate, water, dirt, sand, ice) defines density, hardness, penetration resistance, ricochet chance, damage absorption, and impact effects (sparks, dust, debris, blood). This is a shared material table consumed by ballistics, melee, explosions, and fire — one material definition drives every system that needs to know "what happens when something hits concrete."
 
## 4.6 Armor
 
Armor sits in the damage pipeline between the projectile and the body:
 
```
Projectile → Outer Equipment → Armor → Body Region → Trauma Calculation → Status Application
```
 
Supported armor layers: helmet, face protection, plate carrier, soft armor, clothing, shields. Armor may stop a projectile outright, reduce its damage, deflect it, break under the impact, or transfer blunt force through to the body even when it stops penetration. Armor itself has durability and degrades with repeated hits.
 
## 4.7 Fragmentation & Explosions
 
Explosive and high-energy impacts generate fragments with configurable count, velocity, damage, penetration, and spread. Explosions are themselves modular entities:
 
```
Explosion
├── Blast
├── Fragment
├── Heat
├── Sound
├── Physics
└── Status
```
 
producing damage, knockback, hearing damage, fire, smoke, debris, and structural damage across blast, fragmentation, thermal, chemical, and pressure damage types.
 
---
 
# 5. Attachment Framework
 
Attachments are modular components layered onto weapons, covering optics, barrels, suppressors, muzzle brakes, compensators, stocks, grips, handguards, lasers, flashlights, bipods, underbarrel systems, and magazines.
 
**Effects** — an attachment can modify recoil, accuracy, weight, heat, sound, velocity, handling, and ergonomics, all as additive/multiplicative modifiers on the base weapon stats, following the same Modifier types used by Statuses (Chapter 8.6): numeric, boolean, state override.
 
**Compatibility** is explicit: attachments declare a required mounting system and weapon compatibility list. Example:
 
```
M4A1
├── NATO Rail
├── 5.56 Barrel
├── AR Stock System
└── STANAG Magazine
```
 
**Conflicts** are supported natively — two attachments competing for the same rail, incompatible ammunition, wrong caliber, or an incorrect mounting system are all rejected at equip time rather than silently allowed.
 
Attachments also replicate visually in third person (suppressor, optic, laser, magazine, stock all appear on the model) so other players get accurate tactical information from a glance.
 
---
 
# 6. Ammunition Framework
 
Ammunition is **fully independent from weapons** — a weapon only declares which ammunition types it accepts; the ammunition itself defines what happens on hit. This decoupling is what lets the same rifle fire FMJ, hollow point, armor-piercing, incendiary, tracer, or subsonic rounds without any weapon-side logic branching.
 
**Ammunition Data**
 
```
Ammunition
├── Caliber
├── Projectile Type
├── Mass
├── Velocity
├── Damage Profile
├── Penetration Profile
├── Effects (statuses it applies)
├── Special Properties
└── Visual Properties
```
 
**Conventional types**
 
| Type | Behavior |
|---|---|
| FMJ | standard penetration, reliable damage |
| Hollow Point | increased soft-target damage, reduced armor penetration |
| Armor Piercing | increased penetration, reduced soft-tissue damage |
| Incendiary | creates fire effects, applies Burning status |
| Tracer | visible projectile, increased visibility |
| Subsonic | reduced velocity, reduced sound signature |
 
**Fictional / sci-fi types** — railgun slugs (extreme velocity, penetration, low drop, high energy transfer), plasma projectiles (heat/energy damage, possible armor melting), energy beams (hitscan, continuous damage, thermal), and fully custom experimental ammunition defined by developers.
 
**Debuff application** — any ammunition (or weapon in continuous/beam mode) can request a status effect on hit or on continuous exposure: slowness, confusion, vision distortion, neural disruption, and so on. Resistance checks — including armor-based immunity — are handled entirely by the Status System (Chapter 8), not by the ammunition itself. The ammunition just requests; the target's resistances decide the outcome.
 
**Magazines & reload** — capacity, weight, compatibility, and condition are tracked per magazine; supported reload types are Tactical (magazine retained), Emergency (magazine discarded), and Partial (topping off without full replacement). Optional detailed tracking stores per-magazine ammo count, type, and condition, so mixed-loaded magazines are possible.
 
---
 
# 7. Medical Framework
 
## 7.1 Overview
 
The medical framework is a tactical injury system, not a full medical simulator: its job is to create immediate combat decisions, encourage team cooperation, and let solo players survive common injuries while punishing neglect of severe ones.
 
## 7.2 Health Architecture
 
Health is multi-layered rather than a single HP value:
 
```
Character
├── Body Health (regional)
├── Blood
├── Consciousness
├── Pain
├── Trauma
└── Status Effects
```
 
## 7.3 Body Regions
 
Damage is localized to: Head, Neck, Chest, Abdomen, Pelvis, Left/Right Arm, Left/Right Hand, Left/Right Leg, Left/Right Foot. Each region independently tracks current/max health, damage received, bleeding state, fracture state, functional impairment, and applied statuses.
 
Damage flows through a consistent pipeline:
 
```
Projectile → Armor → Body Region → Trauma Calculation → Status Application
```
 
## 7.4 Injury Types
 
| Injury | Cause | Effect | Treatment |
|---|---|---|---|
| Minor | cuts, light bruising, minor burns | small pain increase, minor impairment | optional |
| Bleeding | bullets, knives, explosions, shrapnel | blood loss, reduced stamina, weakness | bandage, compression dressing |
| Heavy Bleeding | severe wounds | rapid deterioration, reduced consciousness, possible death | tourniquet, hemostatic gear, assistance recommended |
| Fracture | high-caliber impact, explosions, falls, crushing | arms: recoil/reload/control penalties; legs: reduced movement, no sprint, limp | splint, medical assistance |
| Internal Trauma | high-energy/blunt impacts, explosions | slow deterioration, reduced stamina, collapse risk | advanced medical equipment |
| Burns | fire, explosions, energy weapons, chemicals | continuous damage, pain, reduced movement | burn treatment items |
| Concussion | explosions, blunt impacts, falls | vision/audio distortion, reduced awareness, aim instability | — |
 
## 7.5 Blood System
 
Blood is a distinct resource that decreases through bleeding and internal trauma. Low blood causes reduced stamina, reduced vision, an elevated heartbeat cue, and weakness; critical blood loss leads to unconsciousness and death. Recovery happens through time, transfusion, or medical equipment.
 
## 7.6 Pain System
 
Pain is tracked separately from health and directly affects weapon stability, movement, vision, and available actions. Sources include injuries, burns, fractures, and explosions; painkillers, morphine, and stimulants manage — but do not heal — it.
 
## 7.7 Consciousness System
 
States: `Normal → Dazed → Unconscious → Critical → Dead`.
 
- **Dazed** — reduced awareness, slow reactions, vision impairment.
- **Unconscious** — cannot move or fight, may optionally still communicate.
- **Critical** — incapacitated but recoverable; cannot fight, limited movement, requires assistance.
## 7.8 Medical Equipment
 
Medical items are entities in their own right:
 
```
Medical Item
├── Treatment
├── Animation
├── Usage
├── Inventory
└── Status Interaction
```
 
Bandages stop light bleeding; tourniquets stop severe *limb* bleeding at the cost of limb function; splints stabilize fractures and restore partial movement; painkillers reduce pain without healing the underlying injury; blood transfusion restores blood volume (optionally requiring a matching type); advanced tools (surgical kits, defibrillators, burn treatment, antidotes) round out the higher tier.
 
## 7.9 Assisted / Team Medical Play
 
Some treatments are self-administrable (bandaging, painkillers, basic bleeding control, simple splinting); others are merely *recommended* to be assisted (severe bleeding, chest injuries, complex fractures, transfusion); and some are **required** to involve a second player — reviving an unconscious teammate, stabilizing severe trauma, or treating a player stacked with multiple simultaneous injuries (e.g. broken arm + heavy bleeding + unconscious cannot realistically self-treat).
 
## 7.10 Rescue
 
Players can drag, carry, stabilize, revive, and transport incapacitated teammates. Dragging and carrying both apply movement penalties scaled by the carried player's weight and reduce the carrier's combat ability while active.
 
---
 
# 8. Status Effect Framework
 
## 8.1 Overview — The Unifying Layer
 
**No system is ever allowed to modify player behavior directly.** Weapons, medical items, environments, and abilities all communicate through the exact same mechanism: they apply a **Status**. A flamethrower does not "deal fire damage to the player" — it applies a `Burning` status, and the Burning status itself owns damage-over-time, visuals, pain, movement effects, and its own removal conditions.
 
This is the single most important structural decision in the framework: it means a supernatural corruption effect, a broken arm, and weapon suppression are implemented with the *same* status entity shape, the *same* stacking rules, and the *same* modifier types — only the configuration data differs.
 
## 8.2 Status Entity Structure
 
```
Status Effect
├── Identity
├── Duration
├── Stack
├── Modifier
├── Visual
├── Audio
├── Interaction
└── Removal
```
 
**Duration types:** Instant, Timed (e.g. Flashbang Blindness: 5s), Permanent-until-treated (e.g. Fracture), Conditional/escalating (e.g. Radiation increasing over time).
 
**Stack behaviors:**
 
| Behavior | Meaning | Example |
|---|---|---|
| Replace | new application overrides old | weak poison → strong poison |
| Stack | multiple instances accumulate | multiple bleeding wounds |
| Refresh | new application resets the timer | burning refreshed by continued flame contact |
| Ignore | additional applications have no effect | — |
 
## 8.3 Modifier Types
 
| Type | Description | Example |
|---|---|---|
| Numeric | changes a value | Damage +20%, Speed −15% |
| Boolean | enables/disables a feature | Cannot Sprint, Cannot Aim |
| State Override | forces a different behavior state | force wall-walking, force third person, disable weapon use |
| Visual | changes what the player perceives | blur, color distortion, screen effects |
| Audio | changes what the player hears | ringing ears, muffled audio, echo |
 
## 8.4 Status Interactions
 
Statuses can react to each other, not just to the world:
 
- **Wet + Burning** → reduced fire damage, flames extinguish faster
- **Burning + Fuel Exposure** → increased burn intensity
- **Radiation + Corruption** → increased mutation buildup
- **Painkillers + Injury** → pain effects reduced, underlying injury remains
- **High Gravity + Broken Legs** → increased movement penalty
## 8.5 Status Catalogue
 
The catalogue below is organized by category. Every entry follows the same entity shape from 8.2 — only Identity, Duration, Modifiers, and Removal conditions differ.
 
### Medical
 
- **Bleeding** — health drain over time, stamina recovery reduced, minor screen effect; stacks; removed by bandage/time.
- **Heavy Bleeding** — faster health drain, reduced consciousness trend; requires tourniquet/hemostatic treatment; assistance strongly recommended.
- **Fracture** — region-specific: arms reduce recoil control/reload speed/weapon stability; legs remove sprint and reduce speed; removed by splint + medical assistance.
- **Burns** — continuous damage, pain, reduced movement; caused by fire, explosions, energy weapons, chemicals; removed by burn treatment items or time.
- **Infection** — escalating condition from untreated wounds; degrades stamina/health recovery over time until treated.
- **Poisoning** — damage and impairment from toxins (chemical zones, gas weapons, contaminated environments); countered by antidotes or protective equipment.
- **Radiation Sickness** — escalating exposure-based status; long-term health and stat degradation; mitigated by shielding/protective gear, treated with advanced medical tools.
- **Frostbite** — from prolonged cold exposure or Hypothermia progression; reduces hand function (grip, reload speed) and movement; treated by warmth sources and medical care.
### Combat
 
- **Suppressed** — from nearby gunfire; reduced accuracy, increased sway, audio distortion; removed by leaving the line of fire or over time.
- **Stunned** — from blunt trauma, melee, or explosive concussion; brief loss of control/action capability.
- **Electrical Shock** — from EMP/electrical hazards; temporary loss of fine motor control, possible equipment disruption, brief stun.
- **Weapon Jammed / Overheated Weapon** — equipment-facing statuses attached to the weapon entity rather than the player, blocking fire until cleared/cooled.
- **Adrenaline** — pain resistance up, movement speed up, accuracy slightly down; typically self- or team-triggered via medical item.
- **Fatigue / Exhausted** — from stamina depletion; increased sway, slower movement, heavier breathing, reduced available actions.
### Environmental
 
- **Wetness** — from water/rain exposure; interacts with Burning (extinguishes faster) and Temperature (accelerates heat loss); can affect electrical equipment.
- **Temperature (Cold/Hypothermia/Hot/Hyperthermia/Critical)** — body-temperature track; cold reduces movement/action speed, heat increases fatigue and stamina drain.
- **Oxygen Deprivation** — from underwater submersion, low-oxygen zones, or gas exposure; escalating stamina and consciousness penalty if not resolved.
- **Smoke Inhalation** — from smoke zones/fire; coughing interrupts actions, reduces vision and stamina recovery.
- **Acid Exposure** — from chemical hazards or specialized weapons; continuous damage plus accelerated equipment/armor degradation.
- **Blindness** — from flashbangs, bright light, or injury; removes or severely degrades vision temporarily.
- **Deafness** — from explosions or sustained gunfire near the ear; audio muffling/ringing, removed over time or via hearing protection.
### Supernatural / Sci-Fi
 
- **Gravity Distortion** — changes movement profile and player orientation; explicitly does *not* touch projectile gravity (Chapter 2.3), keeping ballistics predictable inside the effect.
- **Temporal Distortion** — locally alters the speed of actions, animations, or specific systems within a defined radius/duration; must declare exactly which systems it affects so it doesn't silently break networking timing.
- **Hallucination** — false sounds, false visuals, UI distortion; sourced from anomalies, chemical exposure, or abilities; purely perceptual, never touches server-authoritative state.
- **Corruption** — escalating anomalous status, often interacting with Radiation (see 8.4) to build toward a mutation/transformation state.
- **Fear** — psychological status affecting aim stability, movement choices (forced retreat impulses expressed as modifiers, not hard control-removal unless explicitly designed that way), and audio/visual perception.
- **Spatial Instability / Energy Exposure** — anomaly-sourced statuses for exotic zones; freely composed from the same Modifier types as everything above.
### Custom Statuses
 
Because every status shares one entity shape, **adding a new status never requires new code** — a designer defines Identity, Duration, Stack behavior, Modifiers, Visual/Audio cues, Interaction rules with existing statuses, and Removal conditions, then registers it. See Chapter 14 (Developer API) and Chapter 15.3 (Status Creation Pipeline).
 
## 8.6 Status Integration With Combat
 
Every major system communicates *only* through statuses:
 
- Weapon Heat → applies `Weapon Overheated`
- Medical Injury → applies `Broken Arm`, `Pain`, `Bleeding`
- Environmental Hazard → applies `Radiation Exposure`, `Poison`, `Temperature Change`
- Ability → applies `Gravity Shift`, `Enhanced Vision`, `Speed Increase`
If a new system is ever tempted to reach in and directly set a player stat, that is the signal the design has broken the abstraction — the correct fix is always "apply a status."
 
---
 
# 9. Animation Framework
 
The animation system supports first- and third-person playback, procedural adjustment, and per-weapon animation sets.
 
**Animation states** include: Idle, Walk, Run, Sprint, Crouch, Prone, ADS, Reload, Equip, Unequip, Melee, Throw, Heal, Interact, Climb, Vault, Swim, Fall.
 
**Procedural animation** layers on top of authored clips for weapon alignment, hand/foot placement, surface adaptation, recoil response, and gravity-change reorientation — this is what lets a single reload animation still look correct whether the character is standing on the floor or hanging off a wall.
 
**Weapon animation sets** are declared per weapon: equip, idle, fire, reload, malfunction, inspection, and melee clips. **Equipment animation** covers shield movement, medical actions, throwing, deploying, and mounting.
 
Body Awareness (visible first-person arms/torso/legs/equipment) is optional per project but recommended for immersion, and it reacts to gravity changes, injuries, and equipment weight the same way third-person animation does.
 
> **Implementation note:** the underlying character rig is intended to be the **DOGU15** R15 rig (Chapter 17.6), which removes the neck/wrist seams that normally show up on a stock R15 avatar during close-up first-person body awareness and third-person animation — this matters specifically for this framework because weapon-sway, surface-adhesion reorientation, and injury-driven procedural animation (Chapter 9) all put the rig through non-default poses where seams are most visible.
 
---
 
# 10. Audio Framework
 
Weapon audio covers fire sound, suppressed fire sound, mechanical sounds, reload sounds, empty-magazine clicks, and malfunction sounds — all defined per weapon/attachment combination.
 
Environmental audio supports indoor reverb, outdoor acoustics, underground environments, and room-size variation. Distance audio applies volume falloff, frequency shift, echo, and delay; occlusion accounts for walls, doors, materials, and terrain blocking or muffling sound.
 
Combat audio effects include bullet cracks, bullet impacts, explosions, suppression audio, and hearing damage (ringing ears) — the last of which is implemented as the `Deafness` status (8.5) rather than a standalone audio hack, so it interacts correctly with medical/protective equipment.
 
---
 
# 11. Visual Effects Framework
 
Weapon effects: muzzle flash, smoke, shell casings, tracers, heat glow, barrel effects. Impact effects are driven by the shared material table (Chapter 4.5): sparks, dust, debris, blood, fire, scaled appropriately per surface. Environmental effects cover smoke, fog, fire, rain, snow, radiation effects, and anomaly effects.
 
Body damage visuals (blood, armor damage, visible injuries) should be client-optimized, distance-scaled, and toggleable — they're feedback, not simulation, and should never be allowed to affect server-authoritative outcomes.
 
---
 
# 12. Interaction Framework
 
## 12.1 Overview
 
A single unified system handles doors, pickups, healing, mounting, deploying, searching, and anomaly interaction — there is no separate "door script" versus "revive script."
 
**Interactable Object structure:**
 
```
Interactable Object
├── Detection
├── Interaction Rules
├── Animation
├── Requirement
├── Progress
└── Result
```
 
## 12.2 Interaction Types
 
- **Instant** — completed immediately (pick up ammo, press a button, switch equipment).
- **Hold** — requires sustained input for a duration, with defined interrupt conditions and progress feedback (opening a locked door, reviving a player, defusing an explosive).
- **Assisted** — requires multiple players (carrying heavy objects, operating machinery, advanced medical procedures).
## 12.3 Requirements & Interruptions
 
Interactions may require specific equipment, a player status, skill level, a minimum number of players, team permission, time, or power availability. Example: repairing a turret requires a Repair Tool, 10 seconds, and no active-combat interruption.
 
Interactions can be interrupted by taking damage, moving away, losing required equipment, an applied status, or player cancellation.
 
## 12.4 Doors & Breaching
 
Door types: normal, locked, reinforced, blast, sliding. Supported actions: open, close, lock, unlock, breach, destroy, peek, hold open, lockpick, kick. Breaching methods: kicking, explosives, cutting tools, shotgun breaching, heavy weapons, lockpicking, slamming, blowtorch — each producing appropriate destruction, noise, debris, and suppression side-effects through the standard Explosion/Status pipelines rather than bespoke breach code.
 
---
 
# 13. AI Compatibility
 
## 13.1 Overview
 
AI-controlled entities are designed in from the start to run on the **exact same systems as players** — there is no separate AI damage, weapon, medical, or movement system. This guarantees AI and players are balanced against identical rules and lets every future combat feature (a new status, a new weapon, a new movement profile) apply to AI for free.
 
## 13.2 AI Entity Structure
 
```
AI Entity
├── Character
├── Health
├── Movement
├── Equipment
├── Weapon
├── Status Container
├── Perception
├── Decision
├── Navigation
└── Network
```
 
Everything up through Status Container is identical to the Player Entity (Chapter 1.2); Perception, Decision, and Navigation are the AI-specific additions.
 
## 13.3 Perception
 
AI perception supports vision, hearing, thermal detection, movement detection, electronic sensors, and general environmental awareness.
 
- **Vision** factors in distance, lighting, cover, smoke, target movement, camouflage, and stance — a prone player in darkness is much harder to detect than a sprinting player with a flashlight on.
- **Hearing** detects gunshots, footsteps, explosions, reloading, and equipment use, modified by distance, walls, environment, suppressors, and movement speed.
## 13.4 Combat Behavior & Tactics
 
AI can aim, fire, reload, switch weapons, heal, retreat, suppress, flank, use cover, and throw grenades. Decisions weigh enemy position, squad position, health, ammunition, equipment, environment, and objectives, producing tactical actions like advance, hold, retreat, suppress, flank, defend objective, rescue teammate, or reposition. Squads may share enemy positions, target data, tactical plans, and medical status among members.
 
AI weapon use draws on the same weapon data players do — reload requirements, ammo availability, range, recoil, and heat all apply identically, so a poorly-maintained AI-held weapon can jam exactly like a player's.
 
---
 
# 14. Developer API
 
The framework exposes a small, consistent surface — because almost everything is configuration, the API is really just "declare data, attach components, register."
 
**Creating a weapon**
 
```
CreateWeapon()
AssignComponent()
SetAmmoType()
AddAttachmentSlot()
RegisterAnimations()
RegisterEffects()
```
 
**Creating a status**
 
```
CreateStatus()
AddModifier()
SetDuration()
SetInteractionRules()
RegisterEffects()
```
 
**Creating a zone**
 
```
CreateZone()
AssignMovementProfile()
AssignStatuses()
SetPriority()
```
 
**Debug commands** available to developers include `GiveWeapon`, `ApplyStatus`, `SetGravity`, `SpawnProjectile`, `DamagePlayer`, and `RepairWeapon`, backed by broader debug tooling: hitbox visualization, projectile tracing, damage logs, status inspection, network statistics, and performance monitoring.
 
**Editor tools** should include a weapon creator, attachment creator, status creator, zone creator, projectile tester, and ballistic simulator, so non-programmers can author new content entirely through data.
 
> **Implementation note:** the debug-command layer above (`GiveWeapon`, `ApplyStatus`, `SetGravity`, `SpawnProjectile`, `DamagePlayer`, `RepairWeapon`) is intended to be exposed through **CMDR** (Chapter 17.3) rather than a bespoke chat-command parser — CMDR's type registry is a natural place to register custom types like `weapon`, `status`, and `player` so commands get autocomplete and argument validation for free.
 
---
 
# 15. Configuration System
 
## 15.1 Requirements
 
All systems draw values from external configuration — ModuleScripts, JSON-like data tables, or custom editor tools — supporting inheritance, overrides, presets, and variants. Example:
 
```
AK Platform
├── AK-47
├── AKM
├── AK-74
└── Experimental AK Variant
```
 
where each variant only overrides the specific fields that differ from the base platform, rather than duplicating the entire definition.
 
## 15.2 Weapon Creation Pipeline
 
1. Create weapon definition.
2. Add components.
3. Assign ammunition.
4. Configure attachments.
5. Add animations.
6. Add sounds.
7. Test.
8. Publish.
## 15.3 Status Creation Pipeline
 
1. Create status definition.
2. Define modifiers.
3. Define visuals.
4. Define interactions with existing statuses.
5. Define removal conditions.
## 15.4 Zone Creation Pipeline
 
1. Create zone object.
2. Define detection.
3. Assign effects (movement profile, statuses).
4. Configure priority (for overlapping zones).
5. Test interactions.
> **Implementation note:** step 1–2 (constructing a zone volume and detecting players/parts inside its boundary) is intended to be handled by **ZonePlus** (Chapter 17.1) rather than custom region-detection code — the Zone entity's Detection Component (Chapter 8, Future Expansion 16.6, and the `CreateZone()` API in Chapter 14) should wrap a ZonePlus `Zone` object and subscribe to its enter/exit events, feeding them into the Status/Movement-Profile assignment described in steps 3–4.
 
## 15.5 Zone Priority & Blending
 
Multiple zones may overlap — e.g. a Low Gravity zone inside a Radiation zone inside a Corruption zone. The system must support priority values, blending, overrides, and stacking so all applicable effects coexist coherently rather than the last-applied zone silently overwriting the others.
 
## 15.6 Testing & Balancing
 
Automated tests should cover weapon behavior (fire rate, damage, penetration, recoil, attachments), medical behavior (damage states, treatment, status interactions), and movement behavior (gravity changes, stances, traversal, physics). Balancing tools should surface metrics like damage per shot, time-to-kill, accuracy, weapon usage rates, win rates, and equipment effectiveness so designers can tune configuration data with real numbers rather than guesswork.
 
---
 
# 16. Future Expansion
 
The entire point of the Component + Status architecture is that "future expansion" is mostly a configuration and content problem, not an engineering one. Planned/optional expansion areas include:
 
## 16.1 Tactical Equipment & Sensors
 
Sensors (motion, thermal, sound, electronic), rangefinders, radios, electronic warfare (signal disruption, EMP), and drones (recon, attack, delivery, anomalous) all reuse the Tactical Equipment entity shell (`Identity / Usage / Interaction / Battery / Status / Network / Animation / Effect`) — a sensor suite that grants "wallhack"-style awareness is implemented as layered sensor + AI-fusion detection with configurable range, accuracy, power cost, and counters, not as a special vision hack.
 
## 16.2 Power Armor / Exo-Suits
 
High-tier equipment that bundles multiple Behavior Components at once: HUD/interface modifiers, sensor suite, threat detection, ammo/equipment readouts, automatic medical systems (auto-injectors, coagulants, stimulants with configurable triggers), load-bearing assistance, interaction buffs (faster breaching/vaulting/carrying), recoil stabilizers, throwable path prediction, active camouflage, movement augmentations, and debuff resistance — all gated by power state, battery, damage level, or player input, with the server remaining authoritative for outcomes.
 
## 16.3 Movement Augmentations
 
Scriptable via equipment or ability: short-range movement burst, Silent Movement, and Neural Overclock (large temporary gains to speed/reload/accuracy/recoil control, with a mandatory inverse-penalty status once it ends) — each is just a status with a resource cost and an after-effect.
 
## 16.4 Energy Weapons, Flamethrowers, Railguns
 
- **Energy weapons** — laser, plasma, particle beam, electromagnetic, anomalous energy; properties: heat, power consumption, range, penetration, damage type.
- **Flamethrowers** — fuel amount, pressure, consumption rate, heat; fire stream properties: range, spread, velocity, ignition chance, environmental interaction (fire spread, Chapter 8.4 Wet interaction).
- **Railguns** — charge time, energy consumption, projectile speed, penetration, heat generation; can cause extreme penetration, structural damage, armor destruction, and high recoil.
- **Exotic weapons** (reality cutters, gravity weapons, time weapons, biological weapons, dimensional weapons) — implemented purely through custom components, statuses, zones, and events, with no bespoke "exotic weapon system."
## 16.5 Smart Ammunition
 
Programmable rounds, airburst ammunition, guided/tracking projectiles — built from `Guidance / Sensor / Detonation / Targeting` components layered onto the standard Projectile entity.
 
## 16.6 Reality Modification / Physics Override
 
For anomalous environments: configurable gravity direction, time speed, movement rules, projectile rules, visibility, and damage rules, resolved through an explicit rule-priority chain:
 
```
Global Rules → Map Rules → Zone Rules → Ability Rules → Temporary Status Rules
```
 
so a temporary ability effect can locally override a zone rule without permanently corrupting global state, and conflicts always resolve toward the most specific, most temporary rule.
 
## 16.7 Character Skills & Progression
 
Optional skill modifiers for weapon handling (recoil control, reload speed, sway), medical skill (treatment speed/effectiveness), and movement skill (stamina efficiency, traversal speed) — implemented as standing modifiers, not new mechanics.
 
## 16.8 Equipment Condition, Repair, Crafting
 
Condition states (`New → Good → Used → Damaged → Critical → Broken`) apply to weapons, armor, electronics, and medical tools alike, feeding into accuracy/reliability/heat (weapons), protection/durability (armor), and functionality/failure chance (equipment generally). Repair supports field repair, full repair, and component replacement, with repeated repairs optionally reducing maximum durability over time to keep maintenance meaningful. Crafting/modification (player-driven equipment customization and experimental device creation) is a natural extension once condition and repair exist.
 
## 16.9 Weather, Wind, Destructible Environment
 
Weather (rain, snow, fog, wind, storms) affects visibility, sound, movement, ballistics, and temperature; wind specifically affects projectiles, smoke, fire, and sound propagation. Destructible objects (doors, barricades, glass, lights, cover) define health, material, break behavior, and fragments, and are processed through the same material-interaction table used everywhere else (Chapter 4.5).
 
## 16.10 Replay, Logging, Loot Persistence
 
Optional systems for tracking player actions, weapon usage, damage events, and position history — primarily to support anti-cheat and debugging — alongside optional item/weapon persistence for longer-session or persistent-world game modes.
 
---
 
## Final Architecture Summary
 
```
CombatFramework
├── WeaponSystem
├── ProjectileSystem
├── DamageSystem
├── MedicalSystem
├── MovementSystem
├── EquipmentSystem / InventorySystem
├── StatusSystem
├── AbilitySystem
├── ZoneSystem
├── InteractionSystem
├── AudioSystem / VisualSystem
├── Sensor & HUD System
├── NetworkingSystem
└── DebugSystem
```
 
Every mechanic in the game — a conventional rifle, a power-armor HUD suite with threat detection and auto-heal, a Neural Overclock ability, a confusion-round energy weapon, and a gravity anomaly — is built from the same five primitives: **Entities + Components + Events + Statuses + Configuration**, simulated through the same set of Simulation Systems.
 
The framework is designed to deliver a high-fidelity tactical shooter on Roblox today, while remaining expandable into a full sci-fi / anomalous combat sandbox tomorrow — always respecting the platform's limitations, and always leveraging its strengths, by keeping gameplay logic out of code and inside data.
 
---
 
# 17. Recommended Implementation Stack (Community Modules)
 
## 17.1 Overview
 
This framework is written to be architecture-first and library-agnostic — every chapter above describes *behavior*, not a specific dependency. In practice, several mature community modules already solve pieces of this framework at the engineering level, and building on top of them (rather than re-solving the same low-level problems) is the fastest path to a working implementation. This chapter maps each planned dependency to the framework chapters it supports, and states plainly what it should — and should not — be trusted to own.
 
| Module | Framework role | Chapters it supports |
|---|---|---|
| ZonePlus | Zone volume construction & detection | 8.4 (Zone-driven statuses), 15.4–15.5 (Zone Creation Pipeline / Priority), 16.6 (Reality Modification) |
| FastCast2 | Projectile casting & hit detection | 4 (Ballistics), 3.2 (Firearms), 16.4–16.5 (Energy Weapons, Smart Ammunition) |
| CMDR | Developer/debug console | 14 (Developer API), 15.6 (Testing & Balancing) |
| NamedSignal | Typed event signals | 1 (Architecture — Networking/Events), 8.6 (Status Integration With Combat) |
| "Writing an FPS Framework" (2020 DevForum writeup) | General FPS engineering reference | 2 (Character Controller), 3 (Weapon Framework), 9 (Animation) |
| DOGU15 rig | Seamless R15 character rig | 9 (Animation), 2.9 (Camera / first-person body) |
 
The sections below go module-by-module. None of these are prescriptive about *game feel* — they are load-bearing infrastructure the framework's data-driven design sits on top of.
 
## 17.2 FastCast2 — Ballistics Backbone
 
**What it is:** a statically-typed, parallel-scripting-capable successor to the original FastCast projectile-casting library, purpose-built for high-volume raycast-based projectile simulation on Roblox.
 
**Where it plugs in:**
 
- The **Projectile component** (Chapter 1.2, Chapter 4) should wrap a FastCast2 caster per weapon/ammo-type combination rather than each weapon owning its own raycasting loop. This directly satisfies the pooling and distance-simulation requirements from Chapter 1.6 — FastCast2 already reuses its cast objects instead of instantiating new parts per shot.
- **Hitscan vs. Physical vs. Beam** (Chapter 4.1): FastCast2's per-cast velocity/acceleration configuration maps directly onto the Physical projectile type; a near-instant, near-zero-drop cast configuration approximates Hitscan for very fast rounds; Beam/Continuous types (flamethrowers, lasers) are the one case where FastCast2 is *not* the right tool — those should stay on a tick-based volume/spread simulation as described in Chapter 4.1, since FastCast2 is fundamentally a discrete-cast library, not a continuous-stream one.
- **Penetration & Ricochet** (Chapters 4.3–4.4): implement as FastCast2 pierce/ricochet callback hooks that consult the shared Material table (Chapter 4.5) to decide whether a cast continues, deflects, or terminates — this keeps the "what happens when a bullet hits concrete vs. glass" logic in one place instead of duplicating it per weapon.
- **Server authority** (Chapter 1.3): FastCast2 casts should run wherever the framework's authority model says validation must happen — client-side for visual prediction, server-side for the authoritative hit result — consistent with the client-prediction/lag-compensation split in Chapters 1.3 and 1.5.
**What it should not own:** damage calculation, status application, or armor resolution. FastCast2 should only be trusted to answer "what did the ray/cast hit, and with what remaining energy" — everything downstream (Chapter 4.6 Armor, Chapter 8 Statuses) stays framework logic.
 
## 17.3 CMDR — Developer Console & Debug Layer
 
**What it is:** a fully extensible, type-safe command console for Roblox, supporting custom argument types, autocomplete, and permission gating.
 
**Where it plugs in:**
 
- Backs the entire **Debug Framework** (Chapter 14, referenced from 15.6 Testing & Balancing): `GiveWeapon`, `ApplyStatus`, `SetGravity`, `SpawnProjectile`, `DamagePlayer`, `RepairWeapon` should all be registered as CMDR commands rather than parsed from raw chat text.
- The framework should register **custom CMDR types** for its own entities — a `weapon` type that autocompletes registered Weapon Identities (Chapter 3.1), a `status` type that autocompletes the Status catalogue (Chapter 8.5), and a `zone` type for named zones (Chapter 15.4) — so debug commands get the same data-driven validation the rest of the framework does, instead of relying on developers typing exact string IDs from memory.
- CMDR's built-in permission system is the natural place to gate destructive commands (`DamagePlayer`, `SetGravity`) behind rank/admin checks, satisfying the Anti-Abuse Validation intent (Chapter 1.4) even for developer-facing tools.
**What it should not own:** in-game player-facing commands or gameplay logic — CMDR is strictly a development/QA tool, not a runtime gameplay feature.
 
## 17.4 ZonePlus — Environmental Zones
 
**What it is:** a module for constructing dynamic zone volumes and efficiently determining which players/parts are inside their boundaries, without per-frame manual geometry checks.
 
**Where it plugs in:**
 
- The **Zone entity's Detection Component** should be a thin wrapper around a ZonePlus `Zone` object. ZonePlus's `playerEntered` / `playerExited` (and part-level equivalents) events become the trigger points for the Zone Creation Pipeline's "assign effects" step (Chapter 15.4): entering a zone applies the configured Movement Profile and Status set (Chapter 8), exiting removes them.
- **Zone Priority & Blending** (Chapter 15.5) — for overlapping ZonePlus zones, the framework layer (not ZonePlus itself) is responsible for resolving priority/blending/stacking, since ZonePlus only reports membership, not precedence. This keeps the "Global → Map → Zone → Ability → Temporary Status" rule-priority chain (Chapter 16.6) as framework-owned logic sitting on top of ZonePlus's membership events.
- Works for every zone use case in the document: Gravity Zones (Chapter 2.3, 16.6), Toxic/Radiation Zones (Chapter 8.5), Thermal Zones, and Anomaly Zones (Chapter 16.6) — all are the same ZonePlus volume type with different Status/Movement-Profile payloads attached.
**What it should not own:** the actual gameplay effect of being inside a zone — ZonePlus tells you *who is where*; the Status Framework (Chapter 8) still owns *what happens to them*.
 
## 17.5 NamedSignal — Typed Event Signals
 
**What it is:** a signal/event library that lets you name and type-check signal parameters, rather than relying on positional, untyped arguments.
 
**Where it plugs in:**
 
- Backs the **Combat Event System** referenced throughout Chapter 8.6 and implied by the Architecture's Networking section (Chapter 1.4): `WeaponFired`, `WeaponReloaded`, `DamageReceived`, `ArmorHit`, `BleedingStarted`, `TreatmentCompleted`, `StanceChanged`, `GravityChanged`, `SurfaceAttached`, etc. should all be declared as NamedSignals with explicit, named payload fields (source entity, target entity, timestamp, position, instigator, action type, relevant values) rather than raw positional tuples.
- This directly supports the framework's "systems communicate through events instead of direct dependencies" principle: a new system (say, a future Corruption mechanic) can subscribe to `DamageReceived` or `StatusApplied` without needing to know anything about the weapon or medical code that originally fired the event, because the signal's parameters are self-describing.
- Recommended convention: one NamedSignal per event type declared in a central `CombatEvents` module, imported by any system that needs to fire or listen — this keeps the event catalogue itself data-inspectable, similar in spirit to the Status catalogue (Chapter 8.5).
**What it should not own:** business logic. NamedSignal is purely a communication primitive — validation, damage math, and status resolution still live in the systems that listen to the signals, not in the signal definitions themselves.
 
## 17.6 DOGU15 Rig — Character Base
 
**What it is:** a seamless R15 character rig build (no visible neck/wrist seams), used as the base avatar rig instead of the stock Roblox R15.
 
**Where it plugs in:**
 
- Serves as the base rig for the **Animation Framework** (Chapter 9) and **Body Awareness** (Chapter 2.9, 9): since this framework relies heavily on procedural adjustment (weapon alignment, surface-adhesion reorientation, injury-driven posture, gravity-direction reorientation), the character is frequently posed in non-default, close-up configurations where seam artifacts on a stock rig would be most visible — first-person body awareness in particular.
- No gameplay-system dependency: the rig choice does not affect Health, Movement, or any Component/Status logic — it is purely a visual/animation-quality decision that should be made once at the character-model level and left alone.
**What it should not own:** any gameplay logic whatsoever — treat it as a modeling/rigging asset choice, fully decoupled from the Component/Status architecture.
 
## 17.7 "Writing an FPS Framework" (2020) — Engineering Reference
 
**What it is:** a DevForum writeup on general FPS engineering considerations on Roblox (viewmodels, camera, mobile support, general architecture pitfalls).
 
**Where it plugs in:** treat this as background reading rather than a dependency — it informs the practical implementation of Chapter 2 (Character Controller, especially 2.9 Camera and first-person view-model handling) and Chapter 9 (Animation), and is useful for avoiding known Roblox-specific FPS pitfalls (camera/viewmodel desync, mobile input parity, network smoothing) that aren't unique to this framework but will surface once implementation starts.
 
## 17.8 Integration Order
 
For teams implementing this framework from scratch, the recommended bring-up order is:
 
1. **NamedSignal** — establish the event catalogue first; every other system will hook into it.
2. **ZonePlus** — stand up basic zone detection early, since Movement Profiles and several Status categories (Environmental, Supernatural) depend on it.
3. **FastCast2** — build the Projectile/Ballistics layer once the event catalogue exists to publish `ProjectileFired` / `ProjectileHit` into.
4. **CMDR** — bring the debug console online as soon as there's anything worth spawning/inspecting; this pays for itself immediately during the rest of implementation.
5. **DOGU15 rig** — swap in at any point; purely cosmetic and has no ordering dependency on the systems above.
This ordering front-loads the two modules (NamedSignal, ZonePlus) that other systems depend on structurally, and back-loads the one module (DOGU15) that has no dependencies at all.
