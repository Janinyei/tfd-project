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

## 1. Gimbal lock — the actual answer

Gimbal lock is a property of **Euler-angle state**, not of 3D rotation. It appears when orientation is *stored* as `(pitch, yaw, roll)` and rebuilt with `CFrame.Angles`/`fromOrientation` each frame.

Fix without any library: store orientation as a **CFrame rotation** and integrate body-relative deltas.

```lua
-- _orientation: CFrame (rotation only)
local delta = CFrame.fromAxisAngle(Vector3.xAxis, pitchRate * dt)
	* CFrame.fromAxisAngle(Vector3.yAxis, yawRate * dt)
	* CFrame.fromAxisAngle(Vector3.zAxis, rollRate * dt)
_orientation = (_orientation * delta):Orthonormalize()
```

Full 6DOF, no singularity, no library. `:Orthonormalize()` each frame kills float drift.

Quaternions earn their place only for:
- **slerp** — smoothing craft orientation toward a target (aim assist, auto-level, camera follow);
- **compact replication** — 4 × i16 quantized quat < a full CFrame;
- **averaging / blending** rotations.

Vendored at `src/ReplicatedStorage/Modules/Utils/Quaternion.luau` — Sleitnick's `RbxUtil` Quaternion (this is the library you were thinking of; EgoMoose wrote the canonical article, Sleitnick shipped the module). Use it where slerp is wanted, not as a default.

---

## 2. Phase 1 — flight core (client)

`ClientInit/Modules/Core/Flight/FlightController.lua` — Priority 60.

**Rig:** character `HumanoidRootPart`, Humanoid `PlatformStand = true` while flying. Movement via constraints on the HRP so the physics engine (and network ownership) stays intact:

| Constraint | Role |
|---|---|
| `LinearVelocity` (`RelativeTo = World`, `VectorVelocity`) | thrust — velocity set directly, no force integration, matches snowboard `MoveMotor` pattern |
| `AlignOrientation` (`Mode = OneAttachment`, `RigidityEnabled = false`, high `Responsiveness`) | steers the body toward `_orientation` |

**State:** `_orientation: CFrame`, `_speed: number`, `_throttle`, `_boost`.

**Input map (keyboard/mouse first, gamepad later):**

| Input | Effect |
|---|---|
| Mouse X/Y delta | yaw / pitch rate (relative, not absolute — feeds `pitchRate`/`yawRate`) |
| `A` / `D` | roll |
| `W` / `S` | throttle up / down |
| `Shift` | boost (speed multiplier + FOV punch + camera pull-back) |
| `Ctrl` | air-brake |
| `Space` | (reserved) auto-level: slerp `_orientation` toward level heading |

**Per-frame loop (`RenderStepped`):**
1. read input → target angular rates, apply **rate smoothing** (exponential lerp, `1 - exp(-k*dt)` — same easing form as snowboard camera) so turns have inertia;
2. integrate `_orientation` (section 1);
3. integrate speed: `throttle` accel, quadratic drag, boost multiplier, clamp to `MaxSpeed`;
4. write `LinearVelocity.VectorVelocity = _orientation.LookVector * _speed`;
5. write `AlignOrientation.CFrame = _orientation`.

**Tunables** live in `ReplicatedStorage/Modules/Core/SharedModules/FlightConfig.lua` (Priority 100) — mirrors the snowboard repo's `SnowboardConfig.Camera` pattern. Nothing tunable hardcoded in the controller.

---

## 3. Phase 2 — camera (client)

`ClientInit/Modules/Core/Flight/CameraController.lua` — Priority 50. Port the structure from `snowboard-comm/.../Controllers/CameraController.lua`:

Keep from snowboard:
- `CameraType = Scriptable`, re-asserted **every frame** (PlayerModule resets it on respawn/input-mode change);
- `MouseBehavior = LockCenter` + `MouseIconEnabled = false`, re-asserted every frame — this is the "central lock";
- speed-scaled chase distance, eased with `1 - exp(-k*dt)`;
- raycast pull-in with `CollisionPadding`;
- all constants in a `Config.Camera` table.

Change for 6DOF — this is where a snowboard camera breaks:
- the snowboard camera builds its CFrame from `fromEulerAnglesYXZ(pitch, yaw, 0)` with an implicit world-up. Inverted or vertical flight makes that flip/lock. Instead **derive the camera from the craft orientation**: `camCF = craftOrientation * offsetCF`, then blend the roll component by `RollFollow ∈ [0,1]` (1 = cockpit-true, 0 = world-up-stabilized). Expose `RollFollow` as a tunable; it's a feel decision.
- mouse delta steers the **craft**, not the camera. Camera gets a small free-look decoupling (lag/lead) only.
- FOV as a speed function (`BaseFov → MaxFov`), eased; boost adds a punch.

---

## 4. Phase 3 — flight → destruction bridge (server)

`ServerInit/Modules/Core/Flight/FlightImpactService.lua` — Priority 60. Copy the *approach* of `RagdollDestructionService` (bachi): server-authoritative destruction cannot be instant, so it must **lead** the body.

Per `Heartbeat`, for each flying player:
1. `v = hrp.AssemblyLinearVelocity`; skip if `v.Magnitude < MinCarveSpeed`;
2. shapecast/raycast from `hrp.Position` along `v.Unit`, length `= v.Magnitude * dt * LeadFactor + Radius`, filtered to the destructible containers;
3. on hit → `VoxelDestructionService:DestroyArea(hitPos, radius, v.Unit, force, { MinVoxelSize = …, ResetTime = … })`;
4. apply **impact cost**: subtract speed proportional to carved volume — `speedLoss = k * radius^3 / mass`; replicate the new speed back to the owning client (Packet) so the client-side `_speed` stays authoritative-consistent.

Tuning table `SharedModules/DestructionConfig.lua`: carve radius / min-voxel-size / debris force / reset time **as functions of impact speed** (fast = bigger hole, coarser voxels, more force). Mirrors bachi's `CombatData` per-move constants.

Setup needed in Studio (MCP, on request): a `workspace.Map` folder holding destructible geometry, or rename `DESTRUCTIBLE_CONTAINER_NAMES`.

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

## 7. Open decisions (need your call)

1. **Player body** — R6/R15 character flying directly, or an invisible craft model the character is welded into? Affects mass, collision shape, and how much the voxel carve radius must cover.
2. **Authority** — client-authoritative movement (network ownership of HRP, server just validates speed/position sanity) is the only thing that feels good at these speeds. Server-authoritative flight will feel awful. Confirm we accept exploit surface for now.
3. **Destruction trigger** — server-led shapecast (section 4) vs. client reports its own impact and server verifies. Server-led is safer and simpler; it lags a frame or two at 300+ studs/s.
4. **Map source** — hand-built destructible blocks, or generated city blocks? Voxel budget tuning depends on it.

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
