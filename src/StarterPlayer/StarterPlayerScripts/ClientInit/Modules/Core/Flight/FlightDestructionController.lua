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
	local result = workspace:Spherecast(
		root.Position,
		destruction.ProbeRadius,
		direction * leadDistance,
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

	-- Don't re-request a hole we just punched: consecutive frames inside the same
	-- wall would otherwise spam identical carves.
	if lastCarvePosition and (result.Position - lastCarvePosition).Magnitude < radius * 0.5 then
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

	Camera:ShakeCarve(radius, speed)

	-- No speed cost. Plowing through a building must not slow the craft: the
	-- carve is the reward, and bleeding momentum on every wall made boosting
	-- through a city feel like wading.
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

	self._trove:Connect(RunService.PostSimulation, function(dt)
		self:_update(dt)
	end)
end

return FlightDestructionController
