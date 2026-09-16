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
local TweenService = game:GetService("TweenService")

local PartCache = require(ReplicatedStorage.Modules.Packages.PartCache)

local Core
local Network
local NetworkKeys

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local PHYSICS_SNAPSHOT_INTERVAL = 1 / 20
local DEBRIS_FADE_DURATION = 1
local DEBRIS_RENDER_DISTANCE = 220

local VOXEL_CAPACITY = 4000

local VISUAL_COLLISION_GROUP = "Default"

--------------------------------------------------------------------------------
-- BUFFER LAYOUT
--------------------------------------------------------------------------------

local FLAG_DYNAMIC = 1
local STATIC_CREATE_BYTES = 39
local DYNAMIC_CREATE_BYTES = 51
local PHYSICS_UPDATE_BYTES = 21

--------------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------------

VoxelDestructionController.InterpolationEnabled = true
-- OFF: client voxels are cosmetic only. The server's sim parts own collision,
-- and they sit in the "Voxels" group which cannot collide with players — a
-- locally-collidable copy would reintroduce exactly the body-blocking this
-- avoids, and only for the local player.
VoxelDestructionController.ClientCollisionEnabled = false

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
	template.CollisionGroup = VISUAL_COLLISION_GROUP
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

	if entry.FadeTween then
		entry.FadeTween:Cancel()
	end

	local part = entry.Part
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CastShadow = true
	part.CollisionGroup = VISUAL_COLLISION_GROUP

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

function VoxelDestructionController:_onCleanupBuffer(buf: buffer)
	local count = buffer.len(buf) / 2

	for i = 1, count do
		local id = buffer.readu16(buf, (i - 1) * 2)
		local entry = voxels[id]
		if not entry then
			continue
		end

		if entry.Dynamic then
			if entry.Fading then
				continue
			end

			entry.Fading = true
			dynamicVisuals[id] = nil

			if entry.FadeTween then
				entry.FadeTween:Cancel()
			end

			entry.FadeTween = TweenService:Create(
				entry.Part,
				TweenInfo.new(DEBRIS_FADE_DURATION, Enum.EasingStyle.Linear),
				{ Transparency = 1 }
			)

			local thisEntry = entry
			entry.FadeTween.Completed:Once(function()
				if voxels[id] == thisEntry then
					self:_evictVoxel(id)
				end
			end)

			entry.FadeTween:Play()
		else
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
			part.CanCollide = collisionEnabled
			part.CanQuery = true
			part.CanTouch = false
			part.CastShadow = false
			part.CollisionGroup = VISUAL_COLLISION_GROUP

			voxels[id] = {
				Id = id,
				Part = part,
				Dynamic = true,
				StartCFrame = cf,
				TargetCFrame = cf,
				LastSnapshotTime = os.clock(),
				FadeTween = nil,
				Fading = false,
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
			part.CollisionGroup = VISUAL_COLLISION_GROUP

			voxels[id] = {
				Id = id,
				Part = part,
				Dynamic = false,
				StartCFrame = cf,
				TargetCFrame = cf,
				LastSnapshotTime = 0,
				FadeTween = nil,
				Fading = false,
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
		if not entry or not entry.Dynamic or entry.Fading then
			continue
		end

		local target = readPhysicsCFrame(buf, baseOffset)

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
		if entry.Fading then
			continue
		end

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

function VoxelDestructionController:SetClientCollision(enabled: boolean)
	self.ClientCollisionEnabled = enabled

	for _, entry in voxels do
		entry.Part.CanCollide = enabled
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
function VoxelDestructionController:GetVisualContainer(): Instance?
	return voxelContainer
end

return VoxelDestructionController