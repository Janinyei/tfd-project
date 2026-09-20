--[[
    VoxelDestructionController
    --------------------------
    Client visual layer for server-authoritative voxel destruction.

    - Single shared PartCache for all voxel visuals (static + dynamic).
    - PartCache uses synchronous CFrame assignment — no deferred BulkMoveTo races.
    - Static visuals: anchored, collideable local parts.
    - Dynamic visuals: anchored collideable local puppet parts that interpolate server snapshots.
]]

local VoxelDestructionController = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PartCache = require(ReplicatedStorage.Modules.Packages.PartCache)

local Core
local Network
local NetworkKeys

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local PHYSICS_SNAPSHOT_INTERVAL = 1 / 20
local DEBRIS_RENDER_DISTANCE = 500

local VOXEL_CAPACITY = 30000

--[[
	Collision groups, registered server-side by CollisionGroupManager and
	replicated to clients.

	  VoxelShell  — intact remainder of a damaged part. Solid to players.
	  VoxelDebris — loose rubble. Collides with the map and other voxels so it
	                piles and settles, but NOT with players: chunks pass straight
	                through characters instead of body-blocking them.

	Both stay CanCollide = true. The pass-through is done with the GROUP, not by
	clearing CanCollide, because clearing it would also stop rubble colliding
	with the ground and voxels it is supposed to rest on.

	Assignment is pcall-guarded because group registration replicates to the
	client asynchronously, so a voxel created before the registry arrives would
	error. The fallback differs by intent: shell falls back to Default (still
	solid, correct), debris falls back to CanCollide = false — passing through
	everything is a far smaller visual error than briefly body-blocking the
	player.
]]
local SHELL_COLLISION_GROUP = "VoxelShell"
local DEBRIS_COLLISION_GROUP = "VoxelDebris"

local function setCollisionGroup(part: BasePart, group: string)
	local ok = pcall(function()
		part.CollisionGroup = group
	end)
	if ok then
		return
	end

	part.CollisionGroup = "Default"
	if group == DEBRIS_COLLISION_GROUP then
		part.CanCollide = false
	end
end

--------------------------------------------------------------------------------
-- BUFFER LAYOUT
--------------------------------------------------------------------------------

local FLAG_DYNAMIC = 1
-- Physics-record flag (offset 20): this is the voxel's final transform. Anchor
-- it, drop it from interpolation, keep it forever. Server-side counterpart is
-- VoxelDestructionService._freezeVoxel.
local FLAG_FREEZE = 1
--[[
	Physics-record flag: this chunk is live again (its support was destroyed).
	Resume interpolating it from the transform in the same record.
]]
local FLAG_UNFREEZE = 2
local STATIC_CREATE_BYTES = 39
local DYNAMIC_CREATE_BYTES = 51
local PHYSICS_UPDATE_BYTES = 21

--------------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------------

VoxelDestructionController.InterpolationEnabled = true
--[[
	ON, and it MUST be on for static voxels to be solid.

	The local character is client-owned, so ITS collisions are resolved against
	the CLIENT's parts. The server's sim shell cannot stop a client-authoritative
	character — with this off, every static voxel was a ghost locally no matter
	how solid the server copy was. That was the fly-through-walls bug.

	Debris ignores this flag: it is always CanCollide = true and relies on the
	VoxelDebris collision group to pass through characters.
]]
VoxelDestructionController.ClientCollisionEnabled = true

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local voxelCache
local voxelContainer

local voxels = {}
local dynamicVisuals = {}

local materialLookup = {}
for _, material in Enum.Material:GetEnumItems() do
	materialLookup[material.Value] = material
end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function transparencyFromByte(b: number): number
	return b / 255
end

local function readCreateCFrame(buf: buffer, baseOffset: number): CFrame
	local px = buffer.readf32(buf, baseOffset + 3)
	local py = buffer.readf32(buf, baseOffset + 7)
	local pz = buffer.readf32(buf, baseOffset + 11)
	local rx = buffer.readi16(buf, baseOffset + 15) / 100
	local ry = buffer.readi16(buf, baseOffset + 17) / 100
	local rz = buffer.readi16(buf, baseOffset + 19) / 100
	return CFrame.new(px, py, pz) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
end

local function readPhysicsCFrame(buf: buffer, baseOffset: number): CFrame
	local px = buffer.readf32(buf, baseOffset + 2)
	local py = buffer.readf32(buf, baseOffset + 6)
	local pz = buffer.readf32(buf, baseOffset + 10)
	local rx = buffer.readi16(buf, baseOffset + 14) / 100
	local ry = buffer.readi16(buf, baseOffset + 16) / 100
	local rz = buffer.readi16(buf, baseOffset + 18) / 100
	return CFrame.new(px, py, pz) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
end

--------------------------------------------------------------------------------
-- INIT / START
--------------------------------------------------------------------------------

function VoxelDestructionController:Init(core)
	Core = core
	-- Network replaced by plain RemoteEvents (see VoxelDestructionService)

	voxelContainer = Instance.new("Folder")
	voxelContainer.Name = "VoxelVisuals"
	voxelContainer.Parent = workspace

	local template = Instance.new("Part")
	template.Name = "VisualVoxel"
	template.Size = Vector3.one
	template.Anchored = true
	template.CanCollide = true
	template.CanQuery = true
	template.CanTouch = false
	template.CastShadow = true
	template.TopSurface = Enum.SurfaceType.Smooth
	template.BottomSurface = Enum.SurfaceType.Smooth
	template.CollisionGroup = "Default"
	template.Archivable = true

	voxelCache = PartCache.new(template, VOXEL_CAPACITY, voxelContainer)
	voxelCache.ExpansionSize = 50
end

function VoxelDestructionController:Start()
	local voxelRemotes = ReplicatedStorage:WaitForChild("VoxelRemotes", 10)
	if not voxelRemotes then
		warn("[VoxelDestructionController] VoxelRemotes folder not found")
		return
	end
	local voxelSyncEvent = voxelRemotes:WaitForChild("VoxelSync", 5)
	local voxelPhysicsEvent = voxelRemotes:WaitForChild("VoxelPhysics", 5)

	voxelSyncEvent.OnClientEvent:Connect(function(cleanupBuffer, createBuffer)
		self:_onSync(cleanupBuffer, createBuffer)
	end)

	voxelPhysicsEvent.OnClientEvent:Connect(function(physicsBuffer)
		self:_onPhysics(physicsBuffer)
	end)

	-- Map reset: drop every visual. The server has already restored the
	-- original parts, which replicate on their own.
	Core:Get("Net").VoxelsReset.OnClientEvent:Connect(function()
		self:ClearAll()
	end)

	self._renderConnection = RunService.RenderStepped:Connect(function()
		self:_renderDynamicVisuals()
	end)
end

--------------------------------------------------------------------------------
-- EVICT
--------------------------------------------------------------------------------

function VoxelDestructionController:_evictVoxel(id: number)
	local entry = voxels[id]
	if not entry then
		return
	end

	voxels[id] = nil
	if entry.Dynamic then
		dynamicVisuals[id] = nil
	end

	local part = entry.Part
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = true
	-- Restored for reuse: the pool hands parts out for shell as well as debris,
	-- and debris leaves with CanQuery = false.
	part.CanQuery = true
	part.CastShadow = true
	setCollisionGroup(part, SHELL_COLLISION_GROUP)

	voxelCache:ReturnPart(part)
end

--------------------------------------------------------------------------------
-- SYNC
--------------------------------------------------------------------------------

function VoxelDestructionController:_onSync(cleanupBuffer: buffer?, createBuffer: buffer?)
	if cleanupBuffer then
		self:_onCleanupBuffer(cleanupBuffer)
	end
	if createBuffer then
		self:_onCreateBuffer(createBuffer)
	end
end

--[[
	Cleanup is ALWAYS immediate, for debris and shell alike.

	There used to be a 1s TweenService transparency fade for dynamic voxels. It
	is gone for three reasons:
	  * destruction is permanent (ResetTime = 0), so debris is never removed on a
	    schedule — the only cleanups left are orphan collection and pool-pressure
	    eviction, neither of which should be advertised with an animation;
	  * a fading part stayed in `voxels[id]` for a full second, so if the server
	    reused that id the create overwrote the entry, the tween's
	    `voxels[id] == thisEntry` guard failed, and the part was never returned to
	    the cache — a pooled-part leak;
	  * it rendered a second, ghostly copy of a chunk that had already been
	    superseded, which is confusing to look at.
]]
function VoxelDestructionController:_onCleanupBuffer(buf: buffer)
	local count = buffer.len(buf) / 2

	for i = 1, count do
		local id = buffer.readu16(buf, (i - 1) * 2)
		if voxels[id] then
			self:_evictVoxel(id)
		end
	end
end

function VoxelDestructionController:_onCreateBuffer(buf: buffer)
	local camera = workspace.CurrentCamera
	local cameraPos = camera and camera.CFrame.Position or Vector3.zero
	local collisionEnabled = self.ClientCollisionEnabled

	local bulkParts = {}
	local bulkCFrames = {}

	local offset = 0
	local totalLength = buffer.len(buf)

	while offset < totalLength do
		local flags = buffer.readu8(buf, offset + 0)
		local dynamic = bit32.band(flags, FLAG_DYNAMIC) ~= 0

		local id = buffer.readu16(buf, offset + 1)
		local cf = readCreateCFrame(buf, offset)

		local size = Vector3.new(
			buffer.readf32(buf, offset + 21),
			buffer.readf32(buf, offset + 25),
			buffer.readf32(buf, offset + 29)
		)

		local color = Color3.fromRGB(
			buffer.readu8(buf, offset + 33),
			buffer.readu8(buf, offset + 34),
			buffer.readu8(buf, offset + 35)
		)

		local materialValue = buffer.readu16(buf, offset + 36)
		local material = materialLookup[materialValue] or Enum.Material.Plastic
		local transparency = transparencyFromByte(buffer.readu8(buf, offset + 38))

		-- Safe to evict immediately — PartCache ReturnPart is synchronous
		if voxels[id] then
			self:_evictVoxel(id)
		end

		if dynamic then
			offset += DYNAMIC_CREATE_BYTES

			if (cf.Position - cameraPos).Magnitude > DEBRIS_RENDER_DISTANCE then
				continue
			end

			local part = voxelCache:GetPart()

			part.Size = size
			part.Color = color
			part.Material = material
			part.Transparency = transparency
			part.Anchored = true
			-- Always true: rubble must collide with the map and other voxels so it
			-- piles and settles. Passing through the PLAYER is the group's job.
			part.CanCollide = true
			--[[
				NOT probe-able. The impact spherecast includes this whole folder so
				it can see the static shell; debris sharing it meant loose chunks
				flying ahead of the craft were hit FIRST, so the carve centred on
				rubble in mid-air, destroyed nothing, and left the wall behind it
				intact. Debris never blocks the player, so it never needs carving.
			]]
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			setCollisionGroup(part, DEBRIS_COLLISION_GROUP)

			voxels[id] = {
				Id = id,
				Part = part,
				Dynamic = true,
				StartCFrame = cf,
				TargetCFrame = cf,
				LastSnapshotTime = os.clock(),
			}
			dynamicVisuals[id] = voxels[id]

			table.insert(bulkParts, part)
			table.insert(bulkCFrames, cf)
		else
			offset += STATIC_CREATE_BYTES

			local part = voxelCache:GetPart()

			part.Size = size
			part.Color = color
			part.Material = material
			part.Transparency = transparency
			part.Anchored = true
			part.CanCollide = collisionEnabled
			part.CanQuery = true
			part.CanTouch = false
			part.CastShadow = true
			setCollisionGroup(part, SHELL_COLLISION_GROUP)

			voxels[id] = {
				Id = id,
				Part = part,
				Dynamic = false,
				StartCFrame = cf,
				TargetCFrame = cf,
				LastSnapshotTime = 0,
			}

			table.insert(bulkParts, part)
			table.insert(bulkCFrames, cf)
		end
	end

	if #bulkParts > 0 then
		workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

--------------------------------------------------------------------------------
-- PHYSICS
--------------------------------------------------------------------------------

function VoxelDestructionController:_onPhysics(buf: buffer?)
	if not buf then
		return
	end

	local now = os.clock()
	local total = buffer.len(buf) / PHYSICS_UPDATE_BYTES
	local interpolation = self.InterpolationEnabled

	local snapParts
	local snapCFrames
	if not interpolation then
		snapParts = {}
		snapCFrames = {}
	end

	for i = 1, total do
		local baseOffset = (i - 1) * PHYSICS_UPDATE_BYTES
		local id = buffer.readu16(buf, baseOffset + 0)

		local entry = voxels[id]
		if not entry or not entry.Dynamic then
			continue
		end

		local target = readPhysicsCFrame(buf, baseOffset)
		local flags = buffer.readu8(buf, baseOffset + 20)

		--[[
			Unfreeze: the server destroyed whatever this chunk was resting on, so
			it is simulated again. Put it back in the interpolation set and seed
			both ends of the lerp from the authoritative transform, otherwise the
			first frame would interpolate from a stale pose.
		]]
		if bit32.band(flags, FLAG_UNFREEZE) ~= 0 then
			entry.Dynamic = true
			entry.Part.CFrame = target
			entry.StartCFrame = target
			entry.TargetCFrame = target
			entry.LastSnapshotTime = now
			dynamicVisuals[id] = entry
			continue
		end

		--[[
			Freeze: the server has anchored this chunk and will never send another
			transform for it. Snap to the authoritative final pose, take it out of
			the interpolation set, and leave it as permanent wreckage.

			Must snap rather than lerp: no further snapshots arrive, so an
			interpolated entry would stall partway to its final pose.
		]]
		if bit32.band(flags, FLAG_FREEZE) ~= 0 then
			entry.Dynamic = false
			dynamicVisuals[id] = nil
			entry.Part.CFrame = target
			entry.Part.Anchored = true
			-- Stays in the debris group. Settled rubble is still rubble: promoting
			-- it to the shell group would make wreckage piles body-block the
			-- craft, which is exactly what the group split avoids.
			entry.StartCFrame = target
			entry.TargetCFrame = target
			continue
		end

		if not entry.Dynamic then
			-- Frozen chunks receive no further transforms; ignore stragglers that
			-- were already in flight when it froze.
			continue
		end

		if interpolation then
			if (entry.Part.Position - target.Position).Magnitude > 25 then
				entry.Part.CFrame = target
				entry.StartCFrame = target
				entry.TargetCFrame = target
				entry.LastSnapshotTime = now
			else
				entry.StartCFrame = entry.Part.CFrame
				entry.TargetCFrame = target
				entry.LastSnapshotTime = now
			end
		else
			entry.StartCFrame = target
			entry.TargetCFrame = target
			entry.LastSnapshotTime = now
			table.insert(snapParts, entry.Part)
			table.insert(snapCFrames, target)
		end
	end

	if not interpolation and snapParts and #snapParts > 0 then
		workspace:BulkMoveTo(snapParts, snapCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function VoxelDestructionController:_renderDynamicVisuals()
	if not self.InterpolationEnabled then
		return
	end

	local now = os.clock()

	for _, entry in dynamicVisuals do
		local alpha = math.clamp((now - entry.LastSnapshotTime) / PHYSICS_SNAPSHOT_INTERVAL, 0, 1)
		entry.Part.CFrame = entry.StartCFrame:Lerp(entry.TargetCFrame, alpha)
	end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

function VoxelDestructionController:SetInterpolation(enabled: boolean)
	self.InterpolationEnabled = enabled
end

--[[
	Toggles collision for STATIC voxels only. Debris is unconditionally
	CanCollide = true and passes through characters via its collision group, so
	flipping it here would break rubble resting on the ground.
]]
function VoxelDestructionController:SetClientCollision(enabled: boolean)
	self.ClientCollisionEnabled = enabled

	for _, entry in voxels do
		if not entry.Dynamic then
			entry.Part.CanCollide = enabled
		end
	end
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

function VoxelDestructionController:Cleanup()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end

	for id in voxels do
		self:_evictVoxel(id)
	end

	if voxelCache then
		voxelCache:Dispose()
		voxelCache = nil
	end

	if voxelContainer then
		voxelContainer:Destroy()
		voxelContainer = nil
	end
end

--[[
	Container holding the client's visual voxels.

	Needed by FlightDestructionController's probe: once a part has been hit, the
	server sets the ORIGINAL part's CanQuery = false, and the geometry standing in
	for the remainder is the voxel shell — which lives here on the client and in a
	non-replicating folder on the server. A probe filtered to workspace.Map alone
	therefore sees nothing after the first hit, which is why a part could only
	ever be destroyed once.

	These parts keep CanQuery = true even with ClientCollisionEnabled off
	precisely so they remain probe-able.
]]
--[[
	Census of voxels this CLIENT is rendering, by type.

	Deliberately separate from the server's numbers: the client skips distant
	debris (DEBRIS_RENDER_DISTANCE) and frozen chunks arrive as plain static
	entries, so a mismatch between the two columns is information, not a bug —
	it shows how much the client is culling.
]]
--[[
	Drop every voxel visual at once (map reset).

	Iterates a snapshot of the ids because _evictVoxel mutates the table it
	would otherwise be iterating.
]]
function VoxelDestructionController:ClearAll()
	local ids = {}
	for id in voxels do
		table.insert(ids, id)
	end
	for _, id in ids do
		self:_evictVoxel(id)
	end
	table.clear(dynamicVisuals)
end

function VoxelDestructionController:GetCensus(): (number, number)
	local dynamic, static = 0, 0

	for _, entry in voxels do
		if entry.Dynamic then
			dynamic += 1
		else
			static += 1
		end
	end

	return dynamic, static
end

function VoxelDestructionController:GetVisualContainer(): Instance?
	return voxelContainer
end

return VoxelDestructionController