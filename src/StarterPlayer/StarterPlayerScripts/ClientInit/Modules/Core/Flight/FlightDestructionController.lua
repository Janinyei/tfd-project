--!strict
--[[
	FlightDestructionController  (client)

	Owns impact DETECTION. The client spherecasts ahead of the craft each frame,
	and when the probe hits destructible geometry it asks the server to carve
	(Net.RequestCarve) and immediately applies its own speed loss.

	Detection is client-side because:
	  * movement is client-authoritative, so the client is the only place that
	    knows the true sub-frame trajectory;
	  * a server-side cast at 400+ studs/s is a frame or two stale, which at that
	    speed is 10+ studs of error.

	The server still owns the destruction itself and re-validates the request
	against FlightConfig.Destruction (see FlightDestructionService).

	Lead distance is speed-scaled: server destruction is not instant, so the hole
	must be requested before the body reaches the wall.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local FlightDestructionController = {}

local Core
local Config
local Net
local Flight
local Camera
local Voxels

local lastCarveTime = 0
local lastCarvePosition: Vector3? = nil

local castParams: RaycastParams
local overlapParams: OverlapParams

--[[
	PREDICTIVE NOCLIP.

	A carve is server-authoritative, so the client's geometry does not open until
	the sync comes back — one full round trip during which the wall is still
	solid locally and rams the craft to a stop. That is the wall-blocking hiccup.

	Instead of voxelizing on the client (expensive, and then reconciling two
	independent subdivisions), the client just drops COLLISION on whole parts
	inside the sphere it asked the server to carve. No subdivision math, no
	second source of truth: the server's real geometry replaces these parts when
	it arrives, and collision is what actually blocks the player.

	Each prediction is reverted if the server reports the carve destroyed nothing
	(rejected / already hollow), and otherwise expires on a timer so a part can
	never be left permanently pass-through by a dropped packet.
]]
local predictions: { { Part: BasePart, Clock: number } } = {}
--[[
	Last probe + carve, for the debug gizmos. Written every frame the probe runs
	so DebugController can draw exactly what the detector saw, rather than
	recomputing (and possibly disagreeing with) it.
]]
local probeDebug = {
	Active = false,
	Origin = Vector3.zero,
	Direction = Vector3.zAxis,
	Lead = 0,
	ProbeRadius = 0,
	HitPosition = nil :: Vector3?,
	HitNormal = nil :: Vector3?,
	CarvePosition = nil :: Vector3?,
	CarveRadius = 0,
	CarveClock = 0,
	CarveCount = 0,
	-- Server-confirmed results, for telling apart the two failure modes:
	-- rejected outright vs carved-but-nothing-removed.
	LastDestroyed = 0,
	TotalDestroyed = 0,
	RejectedCount = 0,
	PredictedParts = 0,
}

local function resolveContainers(names: { string }): { Instance }
	local containers = {}
	for _, name in names do
		local container = workspace:FindFirstChild(name)
		if container then
			table.insert(containers, container)
		end
	end
	return containers
end

--[[
	Probe include list = destructible map folders PLUS the client's visual voxel
	container.

	The voxel container is not optional. On the first hit the server sets the
	original part's CanQuery = false and the remaining solid geometry becomes the
	voxel shell, so a probe filtered to workspace.Map alone stops finding anything
	there — which is exactly why a part could only be broken once and then let you
	through. The shell voxels answer queries, so including them keeps a damaged
	part destructible until it is actually gone.
]]
function FlightDestructionController:_refreshCastParams()
	local containers = resolveContainers(Config.DestructibleContainers)

	local visualContainer = Voxels and Voxels:GetVisualContainer()
	if visualContainer then
		table.insert(containers, visualContainer)
	end

	castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Include
	castParams.FilterDescendantsInstances = containers
	castParams.RespectCanCollide = false

	-- Same include set, reused for the predictive-noclip overlap query.
	overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = containers
	overlapParams.RespectCanCollide = false
end

function FlightDestructionController:_update(dt: number)
	probeDebug.Active = false

	if not Flight:IsFlying() then
		return
	end

	local root = Flight:GetRoot()
	if not root or not root.Parent then
		return
	end

	local destruction = Config.Destruction

	-- Speed here is the TRAVEL speed, not the forward throttle: strafing or
	-- hover-climbing into a wall must carve too, and the probe must point where
	-- the craft is actually going.
	local travel = Flight:GetVelocity()
	local speed = travel.Magnitude
	if speed < destruction.MinCarveSpeed then
		return
	end

	local direction = travel / speed

	-- Predictive lead: how far ahead the probe looks. The dt term covers this
	-- frame's travel; the ping term covers the request's round trip, which is
	-- the part that actually matters at speed — the hole has to exist before the
	-- body arrives, and the server is the only thing that can make it.
	local ping = player:GetNetworkPing()
	local leadDistance = math.clamp(
		speed * (dt * destruction.LeadFactor + ping * destruction.PingLeadFactor),
		destruction.MinLeadDistance,
		destruction.MaxLeadDistance
	)

	-- Probe geometry is recorded BEFORE the rate-limit/dedupe bails, so the
	-- gizmos show the cast that is actually happening every frame, not only the
	-- frames that produced a carve.
	probeDebug.Active = true
	probeDebug.Origin = root.Position
	probeDebug.Direction = direction
	probeDebug.Lead = leadDistance
	probeDebug.ProbeRadius = destruction.ProbeRadius
	probeDebug.HitPosition = nil
	probeDebug.HitNormal = nil

	-- Voxel shells replace the original part with sim parts that live in a
	-- non-replicating folder on the server, so the client's probe only ever sees
	-- the map containers — no double-hitting our own debris.
	--[[
		Origin is pulled BACK along travel before casting. Once the craft is
		partly inside a wall, a spherecast starting inside that geometry reports
		nothing, so the probe went blind exactly when it was needed most — that
		is how you end up embedded in a wall that never breaks. Starting behind
		the hull guarantees the surface is ahead of the cast.
	]]
	local castOrigin = root.Position - direction * destruction.ProbeBackoff

	local result = workspace:Spherecast(
		castOrigin,
		destruction.ProbeRadius,
		direction * (leadDistance + destruction.ProbeBackoff),
		castParams
	)

	if not result then
		return
	end

	probeDebug.HitPosition = result.Position
	probeDebug.HitNormal = result.Normal

	local now = os.clock()
	if now - lastCarveTime < destruction.MinCarveInterval then
		return
	end

	local radius = Config.GetCarveRadius(speed)

	--[[
		Don't re-request a hole we just punched — but only for a short window.

		A pure position-based dedupe deadlocks: pressed against a wall the craft
		stops, so the hit position stops changing, so the carve is suppressed
		forever and the wall never opens. StallCarveInterval is the escape hatch:
		if nothing has been carved for that long, carve again regardless of how
		little the contact point moved.
	]]
	local sameSpot = lastCarvePosition
		and (result.Position - lastCarvePosition).Magnitude < radius * 0.5
	if sameSpot and (now - lastCarveTime) < destruction.StallCarveInterval then
		return
	end

	-- Bias the carve centre into the surface along travel. A sphere centred on
	-- the contact point only takes the near half of the wall out.
	local carvePosition = result.Position + direction * (radius * destruction.CarveDepthBias)

	lastCarveTime = now
	lastCarvePosition = result.Position

	probeDebug.CarvePosition = carvePosition
	probeDebug.CarveRadius = radius
	probeDebug.CarveClock = now
	probeDebug.CarveCount += 1

	Net.RequestCarve:Fire(carvePosition, radius, direction, speed)
	self:_predictNoclip(carvePosition, radius)

	Camera:ShakeCarve(radius, speed)

	-- No speed cost. Plowing through a building must not slow the craft: the
	-- carve is the reward, and bleeding momentum on every wall made boosting
	-- through a city feel like wading.
end

--[[
	Drop collision on every part overlapping the requested carve sphere.

	Queried with the same include list as the probe, so it only ever touches
	destructible map geometry and static shell voxels — never debris (which is
	non-probe-able and already passes through the player) and never the
	character.
]]
function FlightDestructionController:_predictNoclip(position: Vector3, radius: number)
	if not Config.Destruction.PredictiveNoclip then
		return
	end

	overlapParams.FilterDescendantsInstances = castParams.FilterDescendantsInstances

	local now = os.clock()
	for _, part in workspace:GetPartBoundsInRadius(position, radius, overlapParams) do
		if part:IsA("BasePart") and part.CanCollide then
			part.CanCollide = false
			table.insert(predictions, { Part = part, Clock = now })
			probeDebug.PredictedParts += 1
		end
	end
end

--[[
	Expire predictions, restoring collision ONLY on parts the server never took
	over.

	This guard is the whole correctness of the system. When a carve lands, the
	server makes the original part invisible + non-queryable and hands collision
	to the voxel shell. Blindly re-enabling CanCollide here resurrected that part
	on this client alone: a solid, invisible wall sitting exactly in the hole you
	can see through.

	Detection uses the marks the server itself applies when it takes a part over
	(Transparency = 1, CanQuery = false). A part still opaque and queryable was
	never carved, so restoring it is correct — that is the rejected-carve case.
]]
function FlightDestructionController:_expirePredictions(force: boolean)
	local lifetime = Config.Destruction.PredictionLifetime
	local now = os.clock()

	for i = #predictions, 1, -1 do
		local prediction = predictions[i]
		if force or now - prediction.Clock >= lifetime then
			local part = prediction.Part
			local serverTookOver = not part.CanQuery or part.Transparency >= 1

			if part.Parent and not serverTookOver then
				part.CanCollide = true
			end

			table.remove(predictions, i)
		end
	end
end

-- Live snapshot for DebugController's gizmos and readouts.
function FlightDestructionController:GetProbeDebug()
	return probeDebug
end

function FlightDestructionController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function FlightDestructionController:Start()
	Config = Core:Get("FlightConfig")
	Net = Core:Get("Net")
	Flight = Core:Get("FlightController")
	Camera = Core:Get("CameraController")
	Voxels = Core:Get("VoxelDestructionController")

	self:_refreshCastParams()

	-- Rebuilt on change because the include list has two late-arriving members:
	-- map folders (streaming, or the map being built in Studio mid-session) and
	-- the VoxelVisuals container, which VoxelDestructionController creates in its
	-- own Start — that sorts AFTER this module's Start, so the first
	-- _refreshCastParams above cannot see it. Parenting it to workspace fires
	-- ChildAdded, which picks it up.
	self._trove:Connect(workspace.ChildAdded, function()
		self:_refreshCastParams()
	end)
	self._trove:Connect(workspace.ChildRemoved, function()
		self:_refreshCastParams()
	end)

	self._trove:Add(Net.CarveResult.OnClientEvent:Connect(function(destroyed)
		probeDebug.LastDestroyed = destroyed
		probeDebug.TotalDestroyed += destroyed
		if destroyed == 0 then
			probeDebug.RejectedCount += 1
			-- Nothing was carved, so the prediction was wrong: put the geometry
			-- back before the player flies through an intact wall.
			self:_expirePredictions(true)
		end
	end))

	self._trove:Connect(RunService.PostSimulation, function(dt)
		self:_update(dt)
		self:_expirePredictions(false)
	end)
end

return FlightDestructionController
