# Status

| Phase | State |
|---|---|
| 0 Repo + ported Core/voxel infrastructure | **done** |
| 1 `FlightConfig`, `Net`, `FlightController` (clamped-pitch hover flight) | **done** |
| 2 `CameraController` (center-lock, chase, speed FOV) | **done** |
| 3 `FlightDestructionController` (client spherecast) + `FlightDestructionService` (server validate + carve) | **done** |
| 4 Impact feel (shake, crash/tumble, SFX) | not started |
| 5 Debug/tuning UI | not started |

Decisions locked (2026-09-16): pure character movement (no craft model); client-owned
spherecast detection → `Net.RequestCarve` → server carve; destructible geometry =
descendants of `workspace.Map`; client-authoritative movement.

**Flight model revised: omnidirectional 6DOF dropped.** Yaw is free, pitch is hard
clamped to `MinPitch`/`MaxPitch` (default ±55°), roll axis removed entirely. Vertical
movement is `Q`/`E` hover thrust in world space; `A`/`D` are lateral strafe.

Consequence: **the gimbal-lock problem no longer exists.** It only appears when pitch
can reach ±90°. With pitch clamped and roll pinned to 0, orientation is two scalars fed
to `CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)`. The CFrame-delta integration and the
vendored `Utils/Quaternion.luau` were both deleted — dead weight, not insurance.

All modules syntax-checked with `luau-compile` 0.738. Not playtested — that's yours.

Controls: `F` toggle flight, mouse yaw/pitch, `W`/`S` throttle, `Q`/`E` hover up/down,
`A`/`D` strafe, `Shift` boost, `Ctrl` air-brake.

---

# Total Flight Destruction — Implementation Plan (rough draft)

Scope of this draft: **flight + destruction only**. No progression, economy, UI polish, data saving, matchmaking.

---

## 0. Repo state (done)

```
tfd-project/
├── default.project.json      Rojo map (name: "total flight destruction")
├── aftman.toml               rojo 7.6.0
├── selene.toml .gitignore .gitattributes .vscode/settings.json
├── docs/IMPLEMENTATION_PLAN.md
└── src/
    ├── ReplicatedStorage/Modules/
    │   ├── Core/init.lua                    ← copied verbatim from bachi-battlegrounds
    │   │   └── SharedModules/               ← FlightConfig, Net go here (Phase 1)
    │   ├── Utils/  Trove, Signal, Spring, Timer, CameraShaker/, Quaternion.luau
    │   ├── Libs/Packet/                     ← Suphi Kader buffer networking
    │   └── Packages/PartCache.rbxm          ← required by voxel system
    ├── ServerScriptService/ServerInit/
    │   ├── init.server.lua                  Core:Init(script.Modules.Core); Core:Start()
    │   └── Modules/Core/
    │       ├── Systems/VoxelDestructionService.lua   ← ported, containers made lazy
    │       └── Flight/                      ← Phase 3
    └── StarterPlayer/StarterPlayerScripts/ClientInit/
        ├── init.client.lua
        └── Modules/Core/
            ├── Visuals/VoxelDestructionController.lua  ← ported verbatim
            └── Flight/                      ← Phase 1/2
```

Port change already applied to `VoxelDestructionService`: `DESTRUCTIBLE_CONTAINERS = {workspace.Map, workspace.VoxelTest}` (indexed at module load, hard-errors in a fresh place) replaced with `DESTRUCTIBLE_CONTAINER_NAMES` + `getDestructibleContainers()` resolved per query via `FindFirstChild`.

---

## 1. Gimbal lock — resolved by constraining the model, not by a library

Gimbal lock is a property of **Euler-angle state whose pitch can reach ±90°**, not of 3D
rotation in general. At ±90° pitch, yaw and roll become the same axis and one degree of
freedom is lost.

The flight model clamps pitch to ±55° and has no roll axis at all. Inside that band the
Euler representation is well-conditioned and unambiguous, so orientation is simply:

```lua
yaw += yawRate * dt
pitch = math.clamp(pitch + pitchRate * dt, math.rad(MinPitch), math.rad(MaxPitch))
orientation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
```

No quaternions, no CFrame-delta accumulation, no `:Orthonormalize()` drift maintenance.
The vendored `Utils/Quaternion.luau` (Sleitnick's `RbxUtil` module — the library you were
thinking of) was **deleted**: keeping an unused rotation library "in case" is how a repo
grows weight. Re-vendor it only if a genuine slerp/blend requirement appears.

One non-obvious detail that matters for feel: when pitch hits the clamp, the smoothed
`pitchRate` is zeroed. Otherwise the rate keeps "charging" against the limit while you
hold the mouse up, and the nose snaps the instant you pull back down.

---

## 2. Phase 1 — flight core (client)

`ClientInit/Modules/Core/Flight/FlightController.lua`.

**Rig:** character `HumanoidRootPart`, Humanoid `PlatformStand = true` while flying.
Movement via constraints on the HRP so the physics engine (and network ownership) stays intact:

| Constraint | Role |
|---|---|
| `LinearVelocity` (`RelativeTo = World`, `VectorVelocity`) | thrust — velocity set directly, no force integration, matches snowboard `MoveMotor` pattern |
| `AlignOrientation` (`Mode = OneAttachment`, `RigidityEnabled = false`, high `Responsiveness`) | steers the body toward `orientation` |

**State:** `yaw`, `pitch` (clamped), `forwardSpeed`, `strafeSpeed`, `hoverSpeed`, `velocity`.

**Input map (keyboard/mouse first, gamepad later):**

| Input | Effect |
|---|---|
| Mouse X | yaw rate (free, wraps) |
| Mouse Y | pitch rate, clamped to `MinPitch`/`MaxPitch` |
| `W` / `S` | forward throttle up / down |
| `Q` / `E` | hover thrust up / down — **world-vertical**, so pitching the nose up does not turn "climb" into "climb and drift backwards" |
| `A` / `D` | lateral strafe, no rotation |
| `Shift` | boost (higher top speed + accel, FOV punch, camera pull-back) |
| `Ctrl` | air-brake |

Hover and strafe ramp through `approachThrust` (accel while held, decay when released)
so they don't snap on and off.

**Per-frame loop (`BindToRenderStep`, just before camera priority):**
1. read mouse → target angular rates, smoothed with `1 - exp(-k*dt)` so turns have inertia;
2. integrate `yaw`, clamp `pitch`, zero the rate at the clamp, rebuild `orientation`;
3. integrate `forwardSpeed` (throttle accel, linear drag, boost/brake, clamp) and ramp `strafeSpeed`/`hoverSpeed`;
4. `velocity = look * forward + right * strafe + Vector3.yAxis * hover`;
5. write `LinearVelocity.VectorVelocity = velocity`, `AlignOrientation.CFrame = orientation`.

**Tunables** live in `ReplicatedStorage/Modules/Core/SharedModules/FlightConfig.lua` —
mirrors the snowboard repo's `SnowboardConfig.Camera` pattern. Nothing tunable hardcoded
in the controller.

---

## 3. Phase 2 — camera (client)

`ClientInit/Modules/Core/Flight/CameraController.lua` — Priority 50. Port the structure from `snowboard-comm/.../Controllers/CameraController.lua`:

Keep from snowboard:
- `CameraType = Scriptable`, re-asserted **every frame** (PlayerModule resets it on respawn/input-mode change);
- `MouseBehavior = LockCenter` + `MouseIconEnabled = false`, re-asserted every frame — this is the "central lock";
- speed-scaled chase distance, eased with `1 - exp(-k*dt)`;
- raycast pull-in with `CollisionPadding`;
- all constants in a `Config.Camera` table.

Changed from the snowboard version:
- the craft's rotation is used **directly** (`camCF = CFrame.new(focus + offset) * smoothedRotation`), exp-smoothed so the camera lags the nose. No roll blending and no near-vertical guard: pitch is clamped to ±55°, so the world-up reference never degenerates and there is no inverted-flight case to handle;
- mouse delta steers the **craft**, not the camera;
- FOV as a speed function (`BaseFov → MaxFov`), eased;
- camera is handed back to `CameraType.Custom` when flight is toggled off.

---

## 4. Phase 3 — flight → destruction bridge

Detection is **client-side** (`ClientInit/.../Flight/FlightDestructionController.lua`);
carving is **server-side** (`ServerInit/.../Flight/FlightDestructionService.lua`).

Client owns detection because it owns movement: a server-side cast at 400+ studs/s is a
frame or two stale, which is 10+ studs of error.

Client, each `PostSimulation`:
1. `travel = FlightController:GetVelocity()` — full velocity, so strafing or hover-climbing into a wall carves too; skip if `travel.Magnitude < MinCarveSpeed`;
2. `workspace:Spherecast(root.Position, ProbeRadius, travel.Unit * lead, params)` with `lead = max(speed * dt * LeadFactor, MinLeadDistance)`, Include-filtered to the destructible containers (rebuilt on `workspace.ChildAdded/Removed`);
3. on hit → `Net.RequestCarve:Fire(position, radius, direction, speed)`, rate-limited by `MinCarveInterval` and deduped against the previous carve position within `radius * 0.5`;
4. apply its own speed loss immediately (client owns movement, server owns destruction).

Server, on `Net.RequestCarve.OnServerEvent`:
1. rate limit per player (`ServerMinCarveInterval`);
2. reject if the point is farther than `MaxCarveDistanceFromPlayer` from that player's own root;
3. clamp reported speed to `BoostMaxSpeed + StrafeSpeed + HoverSpeed` (travel speed legitimately exceeds forward top speed when thrusters stack);
4. clamp radius to `min(GetCarveRadius(speed), MaxRequestRadius)`;
5. **derive** force and `MinVoxelSize` from the clamped speed instead of trusting client-sent values — otherwise a client asks for 0.1-stud voxels and detonates the subdivision budget;
6. `VoxelDestructionService:DestroyArea(position, radius, direction.Unit, force, { MinVoxelSize, ResetTime })`.

Tuning lives in `FlightConfig.Destruction` (one shared table, read by both sides) with
`GetCarveRadius` / `GetMinVoxelSize` / `GetDebrisForce` **as functions of impact speed**
(fast = bigger hole, coarser voxels, more force). Mirrors bachi's `CombatData` per-move
constants. `workspace.Map` already exists in the place; `FlightConfig.DestructibleContainers`
and `DESTRUCTIBLE_CONTAINER_NAMES` in `VoxelDestructionService` must stay in sync.

Key inherited limits to respect while tuning: `MAX_SUBDIVISIONS = 2000` per call, `SIM_PART_CAPACITY = 4000`, `MAX_VOXEL_ID = 65535`, 20 Hz physics snapshots. High-speed flight will hit these far harder than melee combat did — expect to raise `MinVoxelSize` (coarser voxels) rather than the caps.

---

## 5. Phase 4 — impact feel

Cheap, high-payoff, after 1–3 work:
- `CameraShaker` (already vendored) on carve, magnitude from carved volume;
- FOV/speed-line/motion-blur on boost;
- crash state: above `HardImpactSpeed` into non-destructible geometry → tumble (drop `AlignOrientation`, let physics spin), 1–2 s recovery;
- impact SFX + debris burst hook.

---

## 6. Phase 5 — debug + tuning

- `DEBUG_MODE` already in `VoxelDestructionService` (draws every volume) — expose a client toggle;
- Iris (bachi has `Iris.rbxm`; copy if wanted) live-tuning panel for `FlightConfig` / `DestructionConfig`;
- readout: speed, orientation, active voxel count, sim-part pool usage.

---

## 7. Decisions — resolved

1. **Player body** — plain character, no craft model.
2. **Authority** — client-authoritative movement; server validates carve requests only. Exploit surface accepted for now.
3. **Destruction trigger** — client spherecast → `Net.RequestCarve` → server carves and re-validates.
4. **Flight model** — clamped pitch (±55°), no roll, `Q`/`E` world-vertical hover, `A`/`D` strafe.
5. **Map source** — `workspace.Map` folder, all descendants destructible (hand-built for now).

---

## 8. Build order

| # | Deliverable | Depends on |
|---|---|---|
| 1 | `FlightConfig` + `FlightController` (thrust, 6DOF orientation, throttle) | — |
| 2 | `CameraController` (center-lock, chase, roll-follow, speed FOV) | 1 |
| 3 | Test map folder + `VoxelDestructionService` smoke test in Studio | — |
| 4 | `FlightImpactService` (lead shapecast → `DestroyArea`) + `DestructionConfig` | 1, 3 |
| 5 | Speed-loss feedback loop client↔server (Packet) | 4 |
| 6 | Impact feel: shake, FOV, crash/tumble | 2, 4 |
