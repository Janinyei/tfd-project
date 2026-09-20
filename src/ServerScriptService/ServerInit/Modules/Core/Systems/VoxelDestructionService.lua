--[[
    VoxelDestructionService
    -----------------------
    Server-authoritative voxel destruction.

    Model:
    - One shared sim-part cache for all voxels (static + dynamic).
    - Static shell is owned per-original-part, not per-session.
    - Sessions only own dynamic debris + destruction volume timers.
    - Rebuild is two-phase: new shell is built before old shell is torn down.

    Networking:
    - Server sim parts live under workspace.Camera so they do NOT replicate.
    - Clients receive:
        * VoxelSync    -> create / cleanup
        * VoxelPhysics -> dynamic debris transforms
]]

local VoxelDestructionService = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PartCache = require(ReplicatedStorage.Modules.Packages.PartCache)

local Core
local Net
local Config
local _voxelSyncEvent: RemoteEvent
local _voxelPhysicsEvent: RemoteEvent

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

-- Names of Workspace folders whose descendants are destructible.
-- Resolved lazily: a fresh place may not have these yet, and indexing
-- workspace.<Name> at module load would hard-error.
-- Keep in sync with FlightConfig.DestructibleContainers.
local DESTRUCTIBLE_CONTAINER_NAMES = {
	"Map",
}

local DEFAULT_MIN_VOXEL_SIZE = 30
-- 0 == never regenerate. Destruction in this game is permanent.
local DEFAULT_RESET_TIME = 0
local DEFAULT_DEBRIS_FORCE = 30

--[[
	FREEZE-AND-FORGET.

	Debris is not deleted on a timer — wreckage is permanent. Instead a chunk that
	has come to rest is ANCHORED, which removes it from the physics solver
	entirely (only non-anchored assemblies are stepped, at up to 240Hz), and is
	dropped from the 20Hz snapshot stream. It stays visible forever at no
	simulation or bandwidth cost.

	A chunk is considered at rest once it stays under both thresholds for
	SETTLE_TIME. FORCE_FREEZE_TIME is the backstop for chunks that jitter or
	balance forever and never satisfy that.
]]
local SETTLE_LINEAR_SPEED = 3.5
local SETTLE_ANGULAR_SPEED = 3.5
local SETTLE_TIME = 0.3
-- Backstop for chunks that jitter or balance forever. Still requires ground
-- support: on its own this would anchor a chunk in mid-flight.
local FORCE_FREEZE_TIME = 8
-- Absolute cap. An airborne chunk this old is never going to settle (knocked
-- off the map, or oscillating), so it is recycled rather than frozen in the sky.
local MAX_DEBRIS_AGE = 30
-- Extra distance below a chunk that still counts as resting on something.
local SUPPORT_MARGIN = 1.5
--[[
	Extra radius searched for frozen rubble to wake when a carve lands nearby.
	Frozen chunks are anchored, so rubble resting on a wall that later gets
	destroyed would hang in the air; waking it lets it fall.
]]
local WAKE_MARGIN = 6

--[[
	The sim-part pool is finite (SIM_PART_CAPACITY) and wreckage never expires, so
	frozen rubble is recycled oldest-first ONLY under pool pressure — not on a
	lifetime. Below the threshold nothing is ever reclaimed.
]]
local FROZEN_EVICTION_THRESHOLD = 0.85

local MAX_SUBDIVISIONS = 2000

--[[
	Ratio of a cube's bounding-sphere radius to its edge length: sqrt(3)/2.
	This is exactly what the fully-inside test costs at a sphere's boundary.
]]
local PIECE_BOUNDING_FACTOR = math.sqrt(3) * 0.5

-- Voxels are never allowed to exceed the carve radius divided by this, so a
-- Granularity now lives in FlightConfig.Destruction.VoxelRadiusRatio so it is
-- tunable in one place; this fallback only applies before Init resolves it.
local FALLBACK_VOXEL_RADIUS_RATIO = 2

--[[
	Draw every destruction volume. Flip to true and EVERY DestroyBox/DestroyArea call
	renders its own region — no per-call opt-in, no manual calls.

	Shows the box's exact CFrame/Size plus one rod per local axis, so a mis-oriented
	hitbox is visible immediately: the shortest rod is the thin axis.

	Volume outlines only. Per-piece classification is deliberately not drawn — with this
	on globally, one slash would spawn hundreds of markers per hit.
]]
local DEBUG_MODE = false
local DEBUG_DURATION = 10

local PHYSICS_SNAPSHOT_RATE = 20
local PHYSICS_SNAPSHOT_INTERVAL = 1 / PHYSICS_SNAPSHOT_RATE

--[[
	Grace period before a removed debris part is recycled and its id reused. The
	client no longer fades anything, so this only has to outlast in-flight
	replication of the cleanup — not an animation.
]]
local DEBRIS_RECYCLE_DELAY = 0.1
local ID_REUSE_DELAY = 1.25

--[[
	HARD cap on live voxels, enforced in acquireVoxel.

	PartCache's ExpansionSize is left in place only as a backstop: this counter
	is what actually bounds the system, so the number is a real ceiling rather
	than a suggestion. Must stay under MAX_VOXEL_ID, since every live voxel needs
	a distinct u16 id.
]]
local SIM_PART_CAPACITY = 30000

-- Seconds between debug census broadcasts.
local CENSUS_INTERVAL = 0.5

local MAX_VOXEL_ID = 65535

--[[
	Two groups, registered by CollisionGroupManager:
	  VoxelShell  — the anchored voxels standing in for the intact remainder of a
	                damaged part. These MUST collide with players, or a wall stops
	                blocking you entirely the moment it is hit once.
	  VoxelDebris — unanchored launched rubble. Does NOT collide with players, so
	                flying chunks never body-block or shove the craft.
	Every sim part starts as shell and is switched when it becomes debris.
]]
local SHELL_COLLISION_GROUP = "VoxelShell"
local DEBRIS_COLLISION_GROUP = "VoxelDebris"

--------------------------------------------------------------------------------
-- BUFFERS
--------------------------------------------------------------------------------

local FLAG_DYNAMIC = 1
-- Physics-record flag (offset 20): final transform, client should anchor and
-- stop interpolating this voxel. See _freezeVoxel.
local FLAG_FREEZE = 1
-- Physics-record flag: this chunk is live again, resume interpolating it.
local FLAG_UNFREEZE = 2
local STATIC_CREATE_BYTES = 39
local DYNAMIC_CREATE_BYTES = 51
local PHYSICS_UPDATE_BYTES = 21

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local managedParts = {}

local activeVoxels = {}
local activeDynamicVoxels = {}

--[[
	Frozen rubble, oldest first. Anchored, unsimulated, unreplicated after the
	one-off freeze sync — only consuming a pooled part. Drained from the front
	when the pool comes under pressure.
]]
--[[
	Reverse lookup for spatial queries: a query returns parts, and waking frozen
	rubble needs the voxel id that owns each one.
]]
local partToVoxelId: { [BasePart]: number } = {}

local frozenOrder = {}
local frozenHead = 1
local frozenCount = 0

--[[
	HARD CAP accounting.

	PartCache recycles parts but does NOT bound them: with ExpansionSize set it
	silently allocates more whenever it runs dry, so "pool capacity" was never a
	ceiling — it was just the input to the eviction threshold. Permanent
	destruction means static shell grows forever, so without a real cap the
	server accumulates parts until it degrades.

	activeVoxelCount is the authoritative live count and SIM_PART_CAPACITY is now
	a genuine limit: past it, allocation fails and a carve simply does less. That
	is a visible, graceful degradation instead of invisible bloat.
]]
local activeVoxelCount = 0
local deniedAllocations = 0

local nextSessionKey = 0

local allocatedVoxelIds = {}
local freeVoxelIdPool = {}
local nextVoxelId = 0

local simCache
local simFolder

local physicsConnection
local physicsAccumulator = 0
local censusAccumulator = 0

--------------------------------------------------------------------------------
-- TEMPLATE
--------------------------------------------------------------------------------

local function createSimTemplate()
	local part = Instance.new("Part")
	part.Name = "SimPart"
	part.Size = Vector3.one
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CollisionGroup = SHELL_COLLISION_GROUP
	part.Archivable = true
	return part
end

local SIM_TEMPLATE = createSimTemplate()

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function clampI16Scaled(value: number, scale: number): number
	local scaled = math.round(value * scale)
	if scaled < -32768 then
		return -32768
	elseif scaled > 32767 then
		return 32767
	end
	return scaled
end

local function quantizeTransparency(transparency: number): number
	return math.clamp(math.floor(transparency * 255 + 0.5), 0, 255)
end

local function colorToBytes(color: Color3)
	return
		math.clamp(math.floor(color.R * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.G * 255 + 0.5), 0, 255),
		math.clamp(math.floor(color.B * 255 + 0.5), 0, 255)
end

local function safeUnit(v: Vector3?): Vector3?
	if not v then
		return nil
	end
	if v.Magnitude < 0.001 then
		return nil
	end
	return v.Unit
end

--[[
	VOLUME SHAPES

	A destruction volume is either a sphere or an oriented box. Both carry a bounding
	sphere (Center + Radius) used for cheap broad-phase rejection; boxes additionally carry
	CFrame + HalfSize for the exact test.

	Two different precisions on purpose:
	  - overlap test runs up to MAX_SUBDIVISIONS times per part, so it uses the piece's
	    bounding sphere. Over-reporting overlap only causes extra subdivision, never a
	    wrong result.
	  - "fully inside" decides whether a piece is actually destroyed, and runs once per
	    final piece, so it is exact.
]]

local PIECE_CORNERS = {
	Vector3.new(1, 1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, -1, -1),
}

local function pieceFullyInsideSphere(
	piecePos: Vector3,
	pieceSize: Vector3,
	sphereCenter: Vector3,
	sphereRadius: number
): boolean
	local pieceRadius = pieceSize.Magnitude * 0.5
	if pieceRadius >= sphereRadius then
		return false
	end

	local maxCenterDistance = sphereRadius - pieceRadius
	local delta = piecePos - sphereCenter
	return delta:Dot(delta) <= maxCenterDistance * maxCenterDistance
end

-- Closest-point test in box space. Cheap: one transform plus three clamps.
local function sphereOverlapsBox(
	center: Vector3,
	radius: number,
	boxCFrame: CFrame,
	halfSize: Vector3
): boolean
	local lp = boxCFrame:PointToObjectSpace(center)

	local dx = math.max(0, math.abs(lp.X) - halfSize.X)
	local dy = math.max(0, math.abs(lp.Y) - halfSize.Y)
	local dz = math.max(0, math.abs(lp.Z) - halfSize.Z)

	return dx * dx + dy * dy + dz * dz <= radius * radius
end

--[[
	Exact piece-OBB inside-box test via all 8 corners.

	Deliberately NOT the bounding-sphere shortcut used for spheres: a thin slash box can be
	1-2 studs thick, which is smaller than a min-size piece's bounding radius. The sphere
	approximation would report "never inside" and the box would subdivide geometry without
	ever destroying any of it.
]]
local function pieceFullyInsideBox(
	pieceCF: CFrame,
	pieceSize: Vector3,
	boxCFrame: CFrame,
	halfSize: Vector3
): boolean
	local pieceHalf = pieceSize * 0.5
	local pieceInBoxSpace = boxCFrame:Inverse() * pieceCF

	for _, corner in PIECE_CORNERS do
		local localCorner = pieceInBoxSpace
			* Vector3.new(corner.X * pieceHalf.X, corner.Y * pieceHalf.Y, corner.Z * pieceHalf.Z)

		if math.abs(localCorner.X) > halfSize.X
			or math.abs(localCorner.Y) > halfSize.Y
			or math.abs(localCorner.Z) > halfSize.Z
		then
			return false
		end
	end

	return true
end

-- Broad phase, per subdivision iteration. Conservative by design.
local function volumeOverlapsPiece(volume, piecePos: Vector3, pieceRadius: number): boolean
	local combined = volume.Radius + pieceRadius
	local delta = piecePos - volume.Center
	if delta:Dot(delta) > combined * combined then
		return false
	end

	if volume.Shape == "Box" then
		return sphereOverlapsBox(piecePos, pieceRadius, volume.CFrame, volume.HalfSize)
	end

	return true
end

-- Narrow phase, once per final piece. Exact.
local function pieceFullyInsideVolume(volume, pieceCF: CFrame, pieceSize: Vector3): boolean
	if volume.Shape == "Box" then
		return pieceFullyInsideBox(pieceCF, pieceSize, volume.CFrame, volume.HalfSize)
	end

	return pieceFullyInsideSphere(pieceCF.Position, pieceSize, volume.Center, volume.Radius)
end

--------------------------------------------------------------------------------
-- ID POOL
--------------------------------------------------------------------------------

local function allocVoxelId(): number?
	if #freeVoxelIdPool > 0 then
		local id = table.remove(freeVoxelIdPool)
		allocatedVoxelIds[id] = true
		return id
	end

	if nextVoxelId < MAX_VOXEL_ID then
		nextVoxelId += 1
		allocatedVoxelIds[nextVoxelId] = true
		return nextVoxelId
	end

	warn("[VoxelDestructionService] Voxel ID pool exhausted")
	return nil
end

local function freeVoxelId(id: number)
	if allocatedVoxelIds[id] then
		allocatedVoxelIds[id] = nil
		table.insert(freeVoxelIdPool, id)
	end
end

function VoxelDestructionService:_queueFreeVoxelId(id: number, delayTime: number?)
	task.delay(delayTime or ID_REUSE_DELAY, function()
		freeVoxelId(id)
	end)
end

--------------------------------------------------------------------------------
-- SIM PART HELPERS
--------------------------------------------------------------------------------

local function acquireSimPart(): BasePart
	return simCache:GetPart()
end

--[[
	The one place a voxel comes into existence. Enforces the cap, allocates the
	id, takes a pooled part and registers the reverse lookup, so no call site can
	bypass the ceiling or forget the bookkeeping.

	Returns nil when the pool is full; callers skip that piece and the carve
	simply removes less.
]]
local function acquireVoxel(): (number?, BasePart?)
	if activeVoxelCount >= SIM_PART_CAPACITY then
		deniedAllocations += 1
		return nil, nil
	end

	local id = allocVoxelId()
	if not id then
		deniedAllocations += 1
		return nil, nil
	end

	local part = acquireSimPart()
	activeVoxelCount += 1
	partToVoxelId[part] = id
	return id, part
end

local function configureSimPart(part: BasePart, size: Vector3)
	part.Size = size
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.CollisionGroup = SHELL_COLLISION_GROUP
end

local function resetAndReturnSimPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.CollisionGroup = SHELL_COLLISION_GROUP
	simCache:ReturnPart(part)
end

--------------------------------------------------------------------------------
-- ACTIVE VOXEL HELPERS
--------------------------------------------------------------------------------

function VoxelDestructionService:_extractActiveVoxel(id: number)
	local entry = activeVoxels[id]
	if not entry then
		return nil
	end

	activeVoxels[id] = nil
	activeDynamicVoxels[id] = nil
	activeVoxelCount -= 1
	if entry.Part then
		partToVoxelId[entry.Part] = nil
	end

	return entry
end

function VoxelDestructionService:_returnVoxelEntry(entry)
	local part = entry.Part
	if not part then
		return
	end
	resetAndReturnSimPart(part)
end

--------------------------------------------------------------------------------
-- INIT / START
--------------------------------------------------------------------------------

function VoxelDestructionService:Init(core)
	Core = core
	-- Only used for the debug census broadcast. Voxel geometry itself stays on
	-- the dedicated buffer remotes below, since a payload can exceed Packet's
	-- 65535-byte per-field cap.
	Net = core:Get("Net")
	Config = core:Get("FlightConfig")
end

function VoxelDestructionService:Start()
	local simCamera = workspace:WaitForChild("Camera", 10)
	if not simCamera then
		warn("[VoxelDestructionService] Could not find server Camera, disabled")
		return
	end

	simFolder = Instance.new("Folder")
	simFolder.Name = "_VoxelSim"
	simFolder.Parent = simCamera

	simCache = PartCache.new(SIM_TEMPLATE, SIM_PART_CAPACITY, simFolder)
	simCache.ExpansionSize = 50

	-- VoxelSync/VoxelPhysics bypass Packet — raw buffer payloads can exceed
	-- Packet's 65535-byte per-field limit. Plain RemoteEvents are used instead.
	local RS = game:GetService("ReplicatedStorage")
	local voxelRemotes = Instance.new("Folder")
	voxelRemotes.Name = "VoxelRemotes"
	voxelRemotes.Parent = RS

	_voxelSyncEvent = Instance.new("RemoteEvent")
	_voxelSyncEvent.Name = "VoxelSync"
	_voxelSyncEvent.Parent = voxelRemotes

	_voxelPhysicsEvent = Instance.new("RemoteEvent")
	_voxelPhysicsEvent.Name = "VoxelPhysics"
	_voxelPhysicsEvent.Parent = voxelRemotes

	physicsConnection = RunService.Heartbeat:Connect(function(dt)
		physicsAccumulator += dt
		if physicsAccumulator < PHYSICS_SNAPSHOT_INTERVAL then
			return
		end
		physicsAccumulator -= PHYSICS_SNAPSHOT_INTERVAL
		self:_tickPhysics()

		-- Debug census, broadcast far slower than the physics snapshots.
		censusAccumulator += PHYSICS_SNAPSHOT_INTERVAL
		if censusAccumulator >= CENSUS_INTERVAL and Net then
			censusAccumulator = 0
			local shell, live, frozen = self:GetCensus()
			Net.VoxelCensus:Fire(
				shell,
				live,
				frozen,
				math.min(SIM_PART_CAPACITY, 65535),
				math.min(deniedAllocations, 65535)
			)
		end
	end)
end

--------------------------------------------------------------------------------
-- BUFFER ENCODING
--------------------------------------------------------------------------------

function VoxelDestructionService:_encodeIdBuffer(ids: { number }?): buffer?
	if not ids or #ids == 0 then
		return nil
	end

	local buf = buffer.create(#ids * 2)
	for i, id in ids do
		buffer.writeu16(buf, (i - 1) * 2, id)
	end
	return buf
end

function VoxelDestructionService:_encodeCreateBuffer(createEntries: { any }?): buffer?
	if not createEntries or #createEntries == 0 then
		return nil
	end

	local totalBytes = 0
	for _, entry in createEntries do
		totalBytes += if entry.Dynamic then DYNAMIC_CREATE_BYTES else STATIC_CREATE_BYTES
	end

	local buf = buffer.create(totalBytes)
	local offset = 0

	for _, entry in createEntries do
		local flags = if entry.Dynamic then FLAG_DYNAMIC else 0
		local cf = entry.CFrame
		local pos = cf.Position
		local rx, ry, rz = cf:ToOrientation()
		local r, g, b = colorToBytes(entry.Color)

		buffer.writeu8(buf, offset + 0, flags)
		buffer.writeu16(buf, offset + 1, entry.Id)

		buffer.writef32(buf, offset + 3, pos.X)
		buffer.writef32(buf, offset + 7, pos.Y)
		buffer.writef32(buf, offset + 11, pos.Z)

		buffer.writei16(buf, offset + 15, clampI16Scaled(math.deg(rx), 100))
		buffer.writei16(buf, offset + 17, clampI16Scaled(math.deg(ry), 100))
		buffer.writei16(buf, offset + 19, clampI16Scaled(math.deg(rz), 100))

		buffer.writef32(buf, offset + 21, entry.Size.X)
		buffer.writef32(buf, offset + 25, entry.Size.Y)
		buffer.writef32(buf, offset + 29, entry.Size.Z)

		buffer.writeu8(buf, offset + 33, r)
		buffer.writeu8(buf, offset + 34, g)
		buffer.writeu8(buf, offset + 35, b)

		buffer.writeu16(buf, offset + 36, entry.Material.Value)
		buffer.writeu8(buf, offset + 38, quantizeTransparency(entry.Transparency))

		if entry.Dynamic then
			local linear = entry.LinearVelocity
			local angular = entry.AngularVelocity

			buffer.writei16(buf, offset + 39, clampI16Scaled(linear.X, 100))
			buffer.writei16(buf, offset + 41, clampI16Scaled(linear.Y, 100))
			buffer.writei16(buf, offset + 43, clampI16Scaled(linear.Z, 100))

			buffer.writei16(buf, offset + 45, clampI16Scaled(angular.X, 100))
			buffer.writei16(buf, offset + 47, clampI16Scaled(angular.Y, 100))
			buffer.writei16(buf, offset + 49, clampI16Scaled(angular.Z, 100))

			offset += DYNAMIC_CREATE_BYTES
		else
			offset += STATIC_CREATE_BYTES
		end
	end

	return buf
end

function VoxelDestructionService:_fireSync(cleanupIds: { number }?, createEntries: { any }?)
	local cleanupBuffer = self:_encodeIdBuffer(cleanupIds)
	local createBuffer = self:_encodeCreateBuffer(createEntries)

	if not cleanupBuffer and not createBuffer then
		return
	end

	_voxelSyncEvent:FireAllClients(cleanupBuffer, createBuffer)
end

--------------------------------------------------------------------------------
-- PHYSICS SNAPSHOTS
--------------------------------------------------------------------------------



--[[
	Is anything holding this chunk up?

	A short downward ray from the chunk's centre, reaching just past its own
	half-height. Hits map geometry, static shell and other debris — all valid
	things to rest on. A carved-out original part is already CanQuery = false, so
	a hollow wall cannot masquerade as support.

	Only evaluated for chunks that are already candidates to freeze, so this runs
	a handful of times per second, not per chunk per frame.
]]
local supportParams = RaycastParams.new()
supportParams.FilterType = Enum.RaycastFilterType.Exclude
supportParams.RespectCanCollide = false

local function isSupported(part: BasePart): boolean
	local reach = part.Size.Y * 0.5 + SUPPORT_MARGIN
	local hit = workspace:Raycast(part.Position, Vector3.new(0, -reach, 0), supportParams)
	return hit ~= nil and hit.Instance ~= part
end

--[[
	Anchor a settled chunk: out of the solver, out of the snapshot stream, still
	visible forever.

	Clients are told through the PHYSICS record, using the flag byte at offset 20
	that the format already carries and never used (always written 0). Flag 1
	means "this is the final transform, stop interpolating, anchor it".

	Deliberately NOT done as cleanup + static create on the sync channel: a
	cleanup of a dynamic id starts a 1s fade on the client and LEAVES voxels[id]
	populated, so a create reusing the same id overwrites the entry and the fading
	part is never returned to the cache. That path leaks pooled parts and
	double-draws the chunk while it fades. The flag costs 0 extra bytes.
]]
function VoxelDestructionService:_freezeVoxel(id: number, entry)
	local part = entry.Part
	if not part or not part.Parent then
		return
	end

	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Anchored = true

	entry.Dynamic = false
	entry.Frozen = true
	activeDynamicVoxels[id] = nil

	frozenOrder[frozenHead + frozenCount] = id
	frozenCount += 1

	return {
		Id = id,
		CFrame = part.CFrame,
	}
end

--[[
	Wake frozen rubble near a carve.

	Frozen chunks are ANCHORED, so rubble that settled on a wall keeps hanging
	there after that wall is destroyed — visibly floating. Any carve therefore
	re-wakes frozen chunks in its neighbourhood and lets physics decide whether
	they still have support.

	Spatial query, not a scan: with thousands of frozen chunks a linear pass per
	carve (up to ~16 carves/s) would become the most expensive thing in the
	system, while this only touches what is actually nearby.
]]
function VoxelDestructionService:_wakeFrozenNear(center: Vector3, radius: number): { any }?
	if not simFolder then
		return nil
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { simFolder }
	params.RespectCanCollide = false

	local woken = nil
	local now = os.clock()

	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		local id = partToVoxelId[part]
		local entry = id and activeVoxels[id]
		if not entry or not entry.Frozen then
			continue
		end

		entry.Frozen = false
		entry.Dynamic = true
		entry.RestClock = 0
		-- Fresh age clock: a chunk that just lost its support deserves a full
		-- settle window, not an instant re-freeze from FORCE_FREEZE_TIME.
		entry.SpawnClock = now
		activeDynamicVoxels[id] = entry

		part.Anchored = false
		frozenCount -= 1

		woken = woken or {}
		table.insert(woken, { Id = id, CFrame = part.CFrame })
	end

	return woken
end

-- One buffer carrying every freeze this tick, in the physics record format with
-- FLAG_FREEZE set.
function VoxelDestructionService:_fireFreeze(frozen: { any }, flag: number?)
	local buf = buffer.create(#frozen * PHYSICS_UPDATE_BYTES)
	local offset = 0

	for _, item in frozen do
		local cf = item.CFrame
		local pos = cf.Position
		local rx, ry, rz = cf:ToOrientation()

		buffer.writeu16(buf, offset + 0, item.Id)
		buffer.writef32(buf, offset + 2, pos.X)
		buffer.writef32(buf, offset + 6, pos.Y)
		buffer.writef32(buf, offset + 10, pos.Z)
		buffer.writei16(buf, offset + 14, clampI16Scaled(math.deg(rx), 100))
		buffer.writei16(buf, offset + 16, clampI16Scaled(math.deg(ry), 100))
		buffer.writei16(buf, offset + 18, clampI16Scaled(math.deg(rz), 100))
		buffer.writeu8(buf, offset + 20, flag or FLAG_FREEZE)

		offset += PHYSICS_UPDATE_BYTES
	end

	_voxelPhysicsEvent:FireAllClients(buf)
end

--[[
	Recycle the oldest frozen rubble, but ONLY when the pool is nearly exhausted.
	Wreckage is permanent by design; a lifetime timer would delete holes and
	rubble the player is still looking at. Pressure-driven eviction instead means
	nothing disappears until the alternative is failing to carve at all.
]]
function VoxelDestructionService:_evictFrozenUnderPressure()
	local limit = math.floor(SIM_PART_CAPACITY * FROZEN_EVICTION_THRESHOLD)
	-- activeVoxelCount is maintained at the acquire/release chokepoints, so the
	-- old O(n) scan over activeVoxels is unnecessary here.
	local used = activeVoxelCount

	local evictedIds = nil

	while used > limit and frozenCount > 0 do
		local id = frozenOrder[frozenHead]
		frozenOrder[frozenHead] = nil
		frozenHead += 1
		frozenCount -= 1

		--[[
			The queue can contain ids that have been woken since freezing (see
			_wakeFrozenNear). Those are live debris again and must not be
			recycled — drop them from the queue instead.
		]]
		local queued = activeVoxels[id]
		if queued and queued.Frozen then
			local entry = self:_extractActiveVoxel(id)
			if entry then
				self:_returnVoxelEntry(entry)
				self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
				evictedIds = evictedIds or {}
				table.insert(evictedIds, id)
				used -= 1
			end
		end
	end

	if evictedIds then
		self:_fireSync(evictedIds, nil)
	end
end

--[[
	Live voxel census. Walks activeVoxels rather than maintaining counters,
	because counters drift the moment any path forgets to decrement and a wrong
	number is worse than no number. Bounded by SIM_PART_CAPACITY and only run at
	CENSUS_INTERVAL, so the cost is irrelevant.
]]
function VoxelDestructionService:GetCensus(): (number, number, number)
	local shell, live, frozen = 0, 0, 0

	for _, entry in activeVoxels do
		if entry.Frozen then
			frozen += 1
		elseif entry.Dynamic then
			live += 1
		else
			shell += 1
		end
	end

	return shell, live, frozen
end

function VoxelDestructionService:_tickPhysics()
	-- Ids to include in this tick's transform snapshot, collected as they are
	-- classified so the encode pass cannot disagree with the buffer size.
	local snapshotIds = {}
	local orphanIds = {}
	local freezeIds = nil
	local frozenRecords = nil
	local now = os.clock()

	--[[
		Live chunks MUST be poked every tick.

		Sim parts live under workspace.Camera (which is what keeps the server from
		rendering them — the server simulates, clients render). Parts parented
		there behave oddly with the physics engine: it auto-sleeps them and they
		then refuse to simulate properly. The alternating nudge is what keeps
		them awake; without it debris simply stops moving. Alternating sign so the
		nudge cannot integrate into a drift.

		This is exactly why explicit freezing is needed: engine sleep is not
		usable here, so resting chunks would otherwise be poked awake forever.
		Anchoring a settled chunk is our substitute for the sleep we cannot get —
		and it is strictly better, since an anchored part leaves the solver
		entirely rather than idling in it.
	]]
	for id, entry in activeDynamicVoxels do
		local part = entry.Part
		if not part or not part.Parent then
			table.insert(orphanIds, id)
			continue
		end

		local atRest = part.AssemblyLinearVelocity.Magnitude < SETTLE_LINEAR_SPEED
			and part.AssemblyAngularVelocity.Magnitude < SETTLE_ANGULAR_SPEED

		if atRest then
			entry.RestClock = (entry.RestClock or 0) + PHYSICS_SNAPSHOT_INTERVAL
		else
			entry.RestClock = 0
		end

		local age = entry.SpawnClock and (now - entry.SpawnClock) or 0
		local settled = (entry.RestClock or 0) >= SETTLE_TIME
		local expired = age >= FORCE_FREEZE_TIME

		--[[
			GROUND SUPPORT IS MANDATORY BEFORE FREEZING.

			Freezing anchors a chunk exactly where it is, so freezing an airborne
			one leaves it hanging in the sky. Slow-but-airborne is common: a chunk
			near the apex of its arc, one scraping a wall, or one wedged against
			another briefly reads as "at rest". The force-freeze backstop was
			worse — it fired on age ALONE and would anchor a chunk mid-flight.

			So both paths now require something underneath.
		]]
		if (settled or expired) and not isSupported(part) then
			--[[
				Airborne past the absolute cap is a chunk that will never settle:
				knocked off the map, or stuck oscillating. Recycle it rather than
				anchor it in the air or simulate it forever.
			]]
			if age >= MAX_DEBRIS_AGE then
				table.insert(orphanIds, id)
				continue
			end

			settled = false
			expired = false
		end

		if settled or expired then
			freezeIds = freezeIds or {}
			table.insert(freezeIds, id)
		else
			--[[
				Recorded explicitly rather than counted. A count and a second pass
				over activeDynamicVoxels can disagree — orphaned-but-still-parented
				chunks (MAX_DEBRIS_AGE strays) are skipped here yet remain in the
				table, so the second pass wrote more records than the buffer was
				sized for: "buffer access out of bounds".
			]]
			table.insert(snapshotIds, id)
			-- Keep it awake (see above). Only live chunks are poked; frozen ones
			-- are anchored and must stay asleep.
			local poke = (id % 2 == 0) and 0.001 or -0.001
			part.AssemblyAngularVelocity = part.AssemblyAngularVelocity
				+ Vector3.new(poke, 0, 0)
		end
	end

	if freezeIds then
		for _, id in freezeIds do
			local entry = activeDynamicVoxels[id]
			if entry then
				local record = self:_freezeVoxel(id, entry)
				if record then
					frozenRecords = frozenRecords or {}
					table.insert(frozenRecords, record)
				end
			end
		end

		if frozenRecords then
			self:_fireFreeze(frozenRecords)
		end

		self:_evictFrozenUnderPressure()
	end


	if #snapshotIds > 0 then
		local buf = buffer.create(#snapshotIds * PHYSICS_UPDATE_BYTES)
		local offset = 0

		for _, id in snapshotIds do
			local entry = activeDynamicVoxels[id]
			local part = entry and entry.Part
			-- Freezing/eviction can have removed an id since it was listed.
			if not part or not part.Parent then
				continue
			end

			local cf = part.CFrame
			local pos = cf.Position
			local rx, ry, rz = cf:ToOrientation()

			buffer.writeu16(buf, offset + 0, id)
			buffer.writef32(buf, offset + 2, pos.X)
			buffer.writef32(buf, offset + 6, pos.Y)
			buffer.writef32(buf, offset + 10, pos.Z)
			buffer.writei16(buf, offset + 14, clampI16Scaled(math.deg(rx), 100))
			buffer.writei16(buf, offset + 16, clampI16Scaled(math.deg(ry), 100))
			buffer.writei16(buf, offset + 18, clampI16Scaled(math.deg(rz), 100))
			buffer.writeu8(buf, offset + 20, 0)

			offset += PHYSICS_UPDATE_BYTES
		end

		-- Trim if any listed id dropped out, so the client never decodes padding.
		if offset > 0 then
			if offset < buffer.len(buf) then
				local trimmed = buffer.create(offset)
				buffer.copy(trimmed, 0, buf, 0, offset)
				buf = trimmed
			end
			_voxelPhysicsEvent:FireAllClients(buf)
		end
	end

	if #orphanIds > 0 then
		for _, id in orphanIds do
			local entry = self:_extractActiveVoxel(id)
			if entry then
				self:_returnVoxelEntry(entry)
				self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
			end
		end
		self:_fireSync(orphanIds, nil)
	end
end

--------------------------------------------------------------------------------
-- STATIC SHELL MANAGEMENT
--------------------------------------------------------------------------------

function VoxelDestructionService:_teardownStaticShell(managed): ({ number }, { any })
	local tornIds = {}
	local tornEntries = {}

	for _, id in managed.staticIds do
		local entry = self:_extractActiveVoxel(id)
		if entry then
			table.insert(tornIds, id)
			table.insert(tornEntries, entry)
		end
	end

	managed.staticIds = {}
	return tornIds, tornEntries
end

function VoxelDestructionService:_buildStaticShell(
	part: BasePart,
	managed,
	bulkParts: { BasePart },
	bulkCFrames: { CFrame }
): ({ number }, { any })
	local newStaticIds = {}
	local createEntries = {}

	local pieces = self:_subdivideMath(
		part.CFrame,
		part.Size,
		managed.volumes,
		managed.minVoxelSize or DEFAULT_MIN_VOXEL_SIZE
	)

	if not pieces then
		managed.staticIds = newStaticIds
		return newStaticIds, createEntries
	end

	local partColor = part.Color
	local partMaterial = part.Material
	local partTransparency = managed.origTransparency

	for _, piece in pieces do
		local piecePos = piece.Position
		local pieceSize = piece.Size

		local insideAnyVolume = false
		for _, volume in managed.volumes do
			if pieceFullyInsideVolume(volume, piece.CF, pieceSize) then
				insideAnyVolume = true
				break
			end
		end

		if insideAnyVolume then
			continue
		end

		local id, simPart = acquireVoxel()
		if not id or not simPart then
			continue
		end

		configureSimPart(simPart, pieceSize)

		activeVoxels[id] = {
			Id = id,
			Part = simPart,
			Dynamic = false,
			OriginalPart = part,
		}

		table.insert(newStaticIds, id)
		table.insert(bulkParts, simPart)
		table.insert(bulkCFrames, piece.CF)

		table.insert(createEntries, {
			Id = id,
			Dynamic = false,
			CFrame = piece.CF,
			Size = pieceSize,
			Color = partColor,
			Material = partMaterial,
			Transparency = partTransparency,
		})
	end

	managed.staticIds = newStaticIds
	return newStaticIds, createEntries
end

--------------------------------------------------------------------------------
-- DEBUG DRAW
--------------------------------------------------------------------------------

--[[
	Only reached when DEBUG_MODE is true. Everything is cosmetic and self-deleting.

	CanQuery=false is load-bearing, not hygiene: a debug part that answered spatial
	queries would be picked up by the very broad phase it is drawing and change the
	result being inspected.
]]

local function debugFolder(): Folder
	local existing = workspace:FindFirstChild("VoxelDebug")
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "VoxelDebug"
	folder.Parent = workspace

	return folder
end

local function debugPart(cframe: CFrame, size: Vector3, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency

	return part
end

local function drawDebugVolume(volume)
	local group = Instance.new("Folder")
	group.Name = volume.Shape
	group.Parent = debugFolder()

	if volume.Shape == "Box" then
		local size = volume.HalfSize * 2
		local cframe = volume.CFrame

		local shell = debugPart(cframe, size, Color3.fromRGB(0, 170, 255), 0.75)
		shell.Name = "Volume"
		shell.Parent = group

		-- SelectionBox inherits the adornee's rotation, so the edges read correctly on an
		-- oriented slab where a translucent fill alone is ambiguous.
		local outline = Instance.new("SelectionBox")
		outline.Adornee = shell
		outline.LineThickness = 0.05
		outline.SurfaceTransparency = 1
		outline.Color3 = Color3.fromRGB(0, 170, 255)
		outline.Parent = shell

		--[[
			One rod per local axis, each drawn at half-extent length. Roblox convention so
			the reading is unambiguous: X/Right red, Y/Up green, Z/Look blue. If the axis
			you meant to be thin is not the shortest rod, the CFrame is rotated wrong.
		]]
		local half = size * 0.5
		local axes = {
			{ Dir = cframe.RightVector, Len = half.X, Color = Color3.fromRGB(255, 60, 60), Name = "AxisX_Right" },
			{ Dir = cframe.UpVector, Len = half.Y, Color = Color3.fromRGB(60, 255, 60), Name = "AxisY_Up" },
			{ Dir = cframe.LookVector, Len = half.Z, Color = Color3.fromRGB(60, 120, 255), Name = "AxisZ_Look" },
		}

		for _, axis in axes do
			local rod = debugPart(
				CFrame.lookAt(
					cframe.Position + axis.Dir * (axis.Len * 0.5),
					cframe.Position + axis.Dir
				),
				Vector3.new(0.15, 0.15, math.max(axis.Len, 0.1)),
				axis.Color,
				0
			)
			rod.Name = axis.Name
			rod.Parent = group
		end
	else
		-- No axis rods: a sphere has no meaningful orientation to check.
		local ball = debugPart(
			CFrame.new(volume.Center),
			Vector3.one * (volume.Radius * 2),
			Color3.fromRGB(255, 170, 0),
			0.75
		)
		ball.Name = "Volume"
		ball.Shape = Enum.PartType.Ball
		ball.Parent = group
	end

	task.delay(DEBUG_DURATION, function()
		group:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
	Spherical destruction. Position + radius.
]]
function VoxelDestructionService:DestroyArea(
	position: Vector3,
	radius: number,
	direction: Vector3?,
	force: number?,
	options: { [string]: any }?
)
	return self:_destroyVolume({
		Shape = "Sphere",
		Center = position,
		Radius = radius,
	}, direction, force, options)
end

--[[
	Oriented-box destruction. Takes a hitbox CFrame + Size, so the carved region matches an
	arbitrary trajectory or orientation — a slash cuts a thin oriented slab rather than
	biting a sphere out of the wall.

	`cframe` positions AND orients the region; `size` is full extents, not half.

	Thin boxes are supported: the inside-box test is an exact 8-corner check rather than a
	bounding-sphere approximation, which would never register a piece as inside a slab
	thinner than the min voxel size.
]]
function VoxelDestructionService:DestroyBox(
	cframe: CFrame,
	size: Vector3,
	direction: Vector3?,
	force: number?,
	options: { [string]: any }?
)
	return self:_destroyVolume({
		Shape = "Box",
		CFrame = cframe,
		HalfSize = size * 0.5,
		-- Bounding sphere for broad-phase rejection.
		Center = cframe.Position,
		Radius = size.Magnitude * 0.5,
	}, direction, force, options)
end

function VoxelDestructionService:_destroyVolume(
	volumeSpec,
	direction: Vector3?,
	force: number?,
	options: { [string]: any }?
)
	options = options or {}

	local minVoxelSize = options.MinVoxelSize or DEFAULT_MIN_VOXEL_SIZE

	--[[
		ResetTime semantics:
		  nil          -> DEFAULT_RESET_TIME
		  <= 0 / inf   -> PERMANENT. resetTime stays nil and no regen is ever
		                  scheduled, so the hole and its shell persist for the
		                  lifetime of the server.
		Debris is never deleted on a timer: settled chunks freeze in place
		(anchored, unsimulated, unreplicated) and stay as permanent wreckage.
	]]
	local requestedReset = options.ResetTime or DEFAULT_RESET_TIME
	local resetTime: number? = requestedReset
	if requestedReset <= 0 or requestedReset == math.huge then
		resetTime = nil
	end

	--[[
		BOUNDARY COMPENSATION.

		A piece is destroyed only if it is FULLY inside the volume, and that test
		uses the piece's bounding sphere (size.Magnitude * 0.5 = 0.87 * voxel).
		So the usable hole is always ~0.87 voxels narrower than the requested
		radius on every side — with 5-stud voxels that is over 4 studs lost, which
		is enough to hollow a wall's interior while leaving its surface skin
		intact and impassable.

		Expanding the sphere by that margin makes the region actually removed
		match the radius the caller asked for. Spheres only: the box test is an
		exact 8-corner check and loses nothing.
	]]
	if volumeSpec.Shape ~= "Box" then
		-- Guard against a degenerate request where voxels are large relative to
		-- Re-applied here because DestroyArea/DestroyBox are public: a caller may
		-- pass any MinVoxelSize, and a voxel large relative to its carve leaves
		-- nothing "fully inside", hollowing a wall without breaching it.
		local ratio = (Config and Config.Destruction.VoxelRadiusRatio)
			or FALLBACK_VOXEL_RADIUS_RATIO
		minVoxelSize = math.min(minVoxelSize, volumeSpec.Radius / ratio)
		volumeSpec.Radius += minVoxelSize * PIECE_BOUNDING_FACTOR
	end

	local launchDir = safeUnit(direction)
	local launchForce = force or DEFAULT_DEBRIS_FORCE

	local volumeCenter = volumeSpec.Center
	local volumeRadius = volumeSpec.Radius

	-- Single chokepoint: both DestroyArea and DestroyBox funnel through here, so this one
	-- check covers every destruction volume in the game.
	if DEBUG_MODE then
		drawDebugVolume(volumeSpec)
	end

	local parts = self:_getPartsInVolume(volumeSpec)
	local partsToProcess = {}
	local seen = {}

	for _, part in parts do
		if part:IsA("BasePart") then
			seen[part] = true
			table.insert(partsToProcess, part)
		end
	end

	-- Already-managed parts are re-checked against the volume's bounding sphere. Coarse for
	-- boxes, but only decides whether a part is reconsidered — the exact tests run later.
	for part in managedParts do
		if seen[part] then
			continue
		end
		local partRadius = part.Size.Magnitude * 0.5
		if (part.Position - volumeCenter).Magnitude - partRadius <= volumeRadius then
			table.insert(partsToProcess, part)
		end
	end

	if #partsToProcess == 0 then
		return 0
	end

	local allCreateEntries = {}
	local allCleanupIds = {}
	local sessionsCreated = {}

	local bulkMoveParts = {}
	local bulkMoveCFrames = {}
	local dynamicActivations = {}

	local totalVoxels = 0

	for _, part in partsToProcess do
		if totalVoxels >= MAX_SUBDIVISIONS then
			break
		end

		local managed = managedParts[part]
		local partColor = part.Color
		local partMaterial = part.Material
		local partTransparency = managed and managed.origTransparency or part.Transparency

		nextSessionKey += 1
		local sessionKey = nextSessionKey

		local session = {
			Key = sessionKey,
			OriginalPart = part,
			-- nil ResetTime == permanent (see _destroyVolume).
			ResetTime = resetTime,
			DynamicIds = {},
		}

		if not managed then
			managed = {
				origTransparency = part.Transparency,
				origCanCollide = part.CanCollide,
				origCanQuery = part.CanQuery,
				origCanTouch = part.CanTouch,
				sessions = {},
				volumes = {},
				minVoxelSize = minVoxelSize,
				staticIds = {},
			}
			managedParts[part] = managed

			part.Transparency = 1
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end

		managed.sessions[sessionKey] = session
		managed.minVoxelSize = math.min(managed.minVoxelSize, minVoxelSize)

		-- Tear down old static shell
		local oldShellIds, oldShellEntries = self:_teardownStaticShell(managed)
		for _, id in oldShellIds do
			table.insert(allCleanupIds, id)
			self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
		end
		-- Return old shell parts immediately — PartCache is synchronous, no race
		for _, entry in oldShellEntries do
			self:_returnVoxelEntry(entry)
		end

		-- Add new destruction volume. Copies the shape spec and tags it with this session so
		-- regen can remove exactly this volume later.
		table.insert(managed.volumes, {
			Shape = volumeSpec.Shape,
			Center = volumeCenter,
			Radius = volumeRadius,
			CFrame = volumeSpec.CFrame,
			HalfSize = volumeSpec.HalfSize,
			SessionKey = sessionKey,
		})

		-- Subdivide and classify
		local pieces = self:_subdivideMath(
			part.CFrame,
			part.Size,
			managed.volumes,
			managed.minVoxelSize
		)

		if not pieces then
			managed.staticIds = {}
			table.insert(sessionsCreated, session)
			continue
		end

		local newStaticIds = {}

		for _, piece in pieces do
			if totalVoxels >= MAX_SUBDIVISIONS then
				break
			end

			local piecePos = piece.Position
			local pieceSize = piece.Size

			local fullyInsideCurrent = false
			local insideOlderVolume = false

			for _, volume in managed.volumes do
				if pieceFullyInsideVolume(volume, piece.CF, pieceSize) then
					if volume.SessionKey == sessionKey then
						fullyInsideCurrent = true
					else
						insideOlderVolume = true
					end
				end
			end

			if fullyInsideCurrent then
				local dir = piecePos - volumeCenter
				if dir.Magnitude > 0.01 then
					dir = dir.Unit
				else
					dir = Vector3.yAxis
				end

				if launchDir then
					dir = (dir + launchDir).Unit
				end

				local scatter = Vector3.zero
				if launchForce > 0 then
					scatter = Vector3.new(
						math.random(-10, 10),
						math.random(15, 35),
						math.random(-10, 10)
					)
				end

				local linearVelocity = dir * launchForce + scatter
				local angularVelocity = Vector3.new(
					math.random(-200, 200),
					math.random(-200, 200),
					math.random(-200, 200)
				) / 100

				local id, simPart = acquireVoxel()
				if not id or not simPart then
					continue
				end
				totalVoxels += 1

				configureSimPart(simPart, pieceSize)

				activeVoxels[id] = {
					Id = id,
					Part = simPart,
					Dynamic = true,
					OriginalPart = part,
					-- Kept so _freezeVoxel can re-emit this chunk as a static
					-- create entry without re-reading the (possibly recycled)
					-- source part.
					Size = pieceSize,
					Color = partColor,
					Material = partMaterial,
					Transparency = partTransparency,
					SpawnClock = os.clock(),
					RestClock = 0,
				}
				activeDynamicVoxels[id] = activeVoxels[id]

				table.insert(session.DynamicIds, id)
				table.insert(bulkMoveParts, simPart)
				table.insert(bulkMoveCFrames, piece.CF)
				table.insert(dynamicActivations, {
					Part = simPart,
					LinearVelocity = linearVelocity,
					AngularVelocity = angularVelocity,
				})

				table.insert(allCreateEntries, {
					Id = id,
					Dynamic = true,
					CFrame = piece.CF,
					Size = pieceSize,
					Color = partColor,
					Material = partMaterial,
					Transparency = partTransparency,
					LinearVelocity = linearVelocity,
					AngularVelocity = angularVelocity,
				})

			elseif insideOlderVolume then
				continue

			else
				local id, simPart = acquireVoxel()
				if not id or not simPart then
					continue
				end
				totalVoxels += 1

				configureSimPart(simPart, pieceSize)

				activeVoxels[id] = {
					Id = id,
					Part = simPart,
					Dynamic = false,
					OriginalPart = part,
				}

				table.insert(newStaticIds, id)
				table.insert(bulkMoveParts, simPart)
				table.insert(bulkMoveCFrames, piece.CF)

				table.insert(allCreateEntries, {
					Id = id,
					Dynamic = false,
					CFrame = piece.CF,
					Size = pieceSize,
					Color = partColor,
					Material = partMaterial,
					Transparency = partTransparency,
				})
			end
		end

		managed.staticIds = newStaticIds
		table.insert(sessionsCreated, session)
	end

	if #bulkMoveParts > 0 then
		workspace:BulkMoveTo(bulkMoveParts, bulkMoveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	for _, activation in dynamicActivations do
		local p = activation.Part
		p.Anchored = false
		-- Now rubble, not structure: stops colliding with players. Reset back to
		-- the shell group in resetAndReturnSimPart when the part is recycled.
		p.CollisionGroup = DEBRIS_COLLISION_GROUP
		p.AssemblyLinearVelocity = activation.LinearVelocity
		p.AssemblyAngularVelocity = activation.AngularVelocity
	end

	self:_fireSync(allCleanupIds, allCreateEntries)

	--[[
		Whatever this carve removed may have been holding frozen rubble up, so
		wake frozen chunks around the volume and let physics re-decide. Without
		it, rubble that settled on a destroyed wall stays anchored in mid-air.
	]]
	local woken = self:_wakeFrozenNear(volumeCenter, volumeRadius + WAKE_MARGIN)
	if woken then
		self:_fireFreeze(woken, FLAG_UNFREEZE)
	end

	for _, session in sessionsCreated do
		if session.ResetTime then
			task.delay(session.ResetTime, function()
				self:_regenSession(session)
			end)
		else
			--[[
				Permanent carve: nothing is scheduled at all. The hole never
				heals, and the rubble is not deleted on a timer either — each
				chunk freezes itself once it settles (see _tickPhysics), which
				takes it out of the solver and off the wire while leaving it
				visible. Pool pressure, not time, is what eventually recycles it.
			]]
		end
	end

	--[[
		Number of voxels actually knocked out of the structure this call, i.e.
		pieces that became debris. Static shell voxels are excluded: they are the
		part that SURVIVED, so counting them would inflate the stat every time a
		shell is rebuilt around an existing hole.
	]]
	return #dynamicActivations
end

--------------------------------------------------------------------------------
-- REGEN
--------------------------------------------------------------------------------

--[[
	Remove a session's dynamic debris and recycle its sim parts.

	Split out of _regenSession because permanent destruction still has to clean up
	rubble: with regeneration disabled, debris would otherwise hold sim parts
	forever against SIM_PART_CAPACITY and keep costing a 20Hz physics snapshot
	each. Structure stays gone; only the loose chunks are collected.
]]
function VoxelDestructionService:_clearSessionDebris(session)
	if #session.DynamicIds == 0 then
		return
	end

	local dynamicCleanupIds = {}
	local delayedReturns = {}

	for _, id in session.DynamicIds do
		local entry = self:_extractActiveVoxel(id)
		if not entry then
			continue
		end

		local partRef = entry.Part
		partRef.Anchored = true
		partRef.CanCollide = false
		partRef.CanQuery = false
		partRef.CanTouch = false
		partRef.AssemblyLinearVelocity = Vector3.zero
		partRef.AssemblyAngularVelocity = Vector3.zero

		table.insert(delayedReturns, entry)
		table.insert(dynamicCleanupIds, id)
		self:_queueFreeVoxelId(id, DEBRIS_RECYCLE_DELAY + ID_REUSE_DELAY)
	end

	table.clear(session.DynamicIds)

	if #dynamicCleanupIds > 0 then
		self:_fireSync(dynamicCleanupIds, nil)
	end

	if #delayedReturns > 0 then
		task.delay(DEBRIS_RECYCLE_DELAY, function()
			for _, entry in delayedReturns do
				self:_returnVoxelEntry(entry)
			end
		end)
	end
end

--[[
	Restore the whole map to its untouched state.

	Every voxel is recycled and every damaged part gets its original properties
	back, so the world returns to exactly how it started rather than to "healed
	but still voxelised". Clients are told to drop their visuals wholesale with
	one empty packet instead of a cleanup list, because at full pool that list
	would be tens of thousands of ids for no benefit.

	Returns how many voxels were reclaimed, for the caller to log.
]]
function VoxelDestructionService:ResetAll(): number
	local reclaimed = 0

	-- Recycle every voxel, whatever its state: shell, live debris or frozen.
	for id in activeVoxels do
		local entry = self:_extractActiveVoxel(id)
		if entry then
			local part = entry.Part
			if part then
				part.Anchored = true
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
			end
			self:_returnVoxelEntry(entry)
			self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
			reclaimed += 1
		end
	end

	-- Restore every part we ever touched.
	for part, managed in managedParts do
		if part and part.Parent then
			part.Transparency = managed.origTransparency
			part.CanCollide = managed.origCanCollide
			part.CanQuery = managed.origCanQuery
			part.CanTouch = managed.origCanTouch
		end
		managedParts[part] = nil
	end

	-- Pending regen timers hold stale session references; clearing the tables
	-- they mutate is enough, since _regenSession bails when the part is no
	-- longer managed.
	table.clear(activeDynamicVoxels)
	table.clear(frozenOrder)
	frozenHead = 1
	frozenCount = 0
	activeVoxelCount = 0
	deniedAllocations = 0

	if Net then
		Net.VoxelsReset:Fire()
	end

	return reclaimed
end

function VoxelDestructionService:_regenSession(session)
	local part = session.OriginalPart
	local managed = managedParts[part]
	if not managed then
		return
	end

	for i = #managed.volumes, 1, -1 do
		if managed.volumes[i].SessionKey == session.Key then
			table.remove(managed.volumes, i)
		end
	end

	self:_clearSessionDebris(session)

	managed.sessions[session.Key] = nil

	if not next(managed.sessions) then
		local shellCleanupIds = {}

		for _, id in managed.staticIds do
			local entry = self:_extractActiveVoxel(id)
			if entry then
				self:_returnVoxelEntry(entry)
				table.insert(shellCleanupIds, id)
				self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
			end
		end
		managed.staticIds = {}

		self:_fireSync(shellCleanupIds, nil)

		if part and part.Parent then
			part.Transparency = managed.origTransparency
			part.CanCollide = managed.origCanCollide
			part.CanQuery = managed.origCanQuery
			part.CanTouch = managed.origCanTouch
		end

		managedParts[part] = nil
	else
		self:_rebuildStaticShell(part, managed)
	end
end

function VoxelDestructionService:_rebuildStaticShell(part: BasePart, managed)
	local oldShellIds, oldShellEntries = self:_teardownStaticShell(managed)

	for _, id in oldShellIds do
		self:_queueFreeVoxelId(id, ID_REUSE_DELAY)
	end

	-- Return old parts immediately — PartCache is synchronous
	for _, entry in oldShellEntries do
		self:_returnVoxelEntry(entry)
	end

	local bulkParts = {}
	local bulkCFrames = {}
	local _, newCreateEntries = self:_buildStaticShell(part, managed, bulkParts, bulkCFrames)

	if #bulkParts > 0 then
		workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	self:_fireSync(oldShellIds, newCreateEntries)
end

--------------------------------------------------------------------------------
-- SPATIAL QUERY
--------------------------------------------------------------------------------

local function getDestructibleContainers(): { Instance }
	local containers = {}
	for _, name in DESTRUCTIBLE_CONTAINER_NAMES do
		local container = workspace:FindFirstChild(name)
		if container then
			table.insert(containers, container)
		end
	end
	return containers
end

function VoxelDestructionService:_getPartsInArea(position: Vector3, radius: number)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = getDestructibleContainers()
	return workspace:GetPartBoundsInRadius(position, radius, overlapParams)
end

function VoxelDestructionService:_getPartsInBox(cframe: CFrame, size: Vector3)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = getDestructibleContainers()
	return workspace:GetPartBoundsInBox(cframe, size, overlapParams)
end

-- Broad phase for either shape.
function VoxelDestructionService:_getPartsInVolume(volume)
	if volume.Shape == "Box" then
		return self:_getPartsInBox(volume.CFrame, volume.HalfSize * 2)
	end
	return self:_getPartsInArea(volume.Center, volume.Radius)
end

--------------------------------------------------------------------------------
-- SUBDIVISION
--------------------------------------------------------------------------------

function VoxelDestructionService:_subdivideMath(partCF: CFrame, partSize: Vector3, volumes, minSize: number)
	local queue = table.create(256)
	local head = 1
	local tail = 1

	queue[1] = {
		CF = partCF,
		Size = partSize,
		Position = partCF.Position,
	}

	local finalPieces = {}
	local iterations = 0

	while head <= tail and iterations < MAX_SUBDIVISIONS do
		local piece = queue[head]
		queue[head] = nil
		head += 1
		iterations += 1

		local size = piece.Size
		local needsSplit = size.X > minSize or size.Y > minSize or size.Z > minSize

		if not needsSplit then
			table.insert(finalPieces, piece)
			continue
		end

		local overlaps = false
		local pieceRadius = size.Magnitude * 0.5

		for _, volume in volumes do
			if volumeOverlapsPiece(volume, piece.Position, pieceRadius) then
				overlaps = true
				break
			end
		end

		if not overlaps then
			table.insert(finalPieces, piece)
			continue
		end

		local halves = self:_splitMath(piece.CF, size)
		if halves then
			tail += 1
			queue[tail] = halves[1]
			tail += 1
			queue[tail] = halves[2]
		else
			table.insert(finalPieces, piece)
		end
	end

	for i = head, tail do
		local piece = queue[i]
		if piece then
			table.insert(finalPieces, piece)
		end
	end

	return finalPieces
end

function VoxelDestructionService:_splitMath(cf: CFrame, size: Vector3)
	local halfSize
	local offset

	if size.X >= size.Y and size.X >= size.Z then
		halfSize = Vector3.new(size.X / 2, size.Y, size.Z)
		offset = cf.RightVector * (size.X / 4)
	elseif size.Y >= size.X and size.Y >= size.Z then
		halfSize = Vector3.new(size.X, size.Y / 2, size.Z)
		offset = cf.UpVector * (size.Y / 4)
	else
		halfSize = Vector3.new(size.X, size.Y, size.Z / 2)
		offset = -cf.LookVector * (size.Z / 4)
	end

	if halfSize.X < 0.5 or halfSize.Y < 0.5 or halfSize.Z < 0.5 then
		return nil
	end

	local cf1 = cf + offset
	local cf2 = cf - offset

	return {
		{ CF = cf1, Size = halfSize, Position = cf1.Position },
		{ CF = cf2, Size = halfSize, Position = cf2.Position },
	}
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

function VoxelDestructionService:Cleanup()
	if physicsConnection then
		physicsConnection:Disconnect()
		physicsConnection = nil
	end

	for _, entry in activeVoxels do
		self:_returnVoxelEntry(entry)
	end

	table.clear(activeVoxels)
	table.clear(activeDynamicVoxels)
	table.clear(managedParts)

	if simCache then
		simCache:Dispose()
		simCache = nil
	end

	if simFolder then
		simFolder:Destroy()
		simFolder = nil
	end
end

return VoxelDestructionService