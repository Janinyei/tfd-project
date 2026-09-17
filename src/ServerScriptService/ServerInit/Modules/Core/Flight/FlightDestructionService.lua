--!strict
--[[
	FlightDestructionService  (server)

	Receives Net.RequestCarve from a flying client and performs the carve through
	VoxelDestructionService. The client owns detection (it owns movement); the
	server owns the destruction and validates every request.

	Validation, all against FlightConfig.Destruction so client and server read one
	table:
	  * rate limit per player;
	  * the carve must be near the requesting player's own root;
	  * radius clamped to MaxRequestRadius;
	  * requests below MinCarveSpeed rejected outright, and cross-checked against
	    the server's own measurement of the player's velocity;
	  * speed capped at BoostMaxSpeed + StrafeSpeed + HoverSpeed, then force and
	    voxel size are DERIVED from it rather than sent by the client — a client
	    cannot ask for 0.1-stud voxels and blow the subdivision budget.
]]

local Players = game:GetService("Players")

local FlightDestructionService = {}

local Core
local Config
local Net
local Voxel

-- player -> os.clock() of last accepted carve
local lastCarve: { [Player]: number } = {}

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function FlightDestructionService:_onRequestCarve(
	player: Player,
	position: Vector3,
	radius: number,
	direction: Vector3,
	speed: number
)
	local destruction = Config.Destruction

	local now = os.clock()
	local previous = lastCarve[player]
	if previous and now - previous < destruction.ServerMinCarveInterval then
		return
	end

	local root = getRoot(player)
	if not root then
		return
	end

	-- A player may only carve near their own body.
	if (position - root.Position).Magnitude > destruction.MaxCarveDistanceFromPlayer then
		return
	end

	if direction.Magnitude < 1e-3 then
		return
	end

	-- SPEED GATE. A request reporting less than MinCarveSpeed is rejected, not
	-- clamped up: clamping would have let a client claim speed 0 and still carve,
	-- which defeats the whole "you must be moving fast" rule.
	if speed < destruction.MinCarveSpeed then
		return
	end

	-- Independent check against the server's OWN view of the player's velocity,
	-- so the reported number cannot simply be fabricated. Tolerance is below 1
	-- because replication lags and the impact has usually already bled speed off
	-- by the time this packet lands.
	local measured = root.AssemblyLinearVelocity.Magnitude
	if measured < destruction.MinCarveSpeed * destruction.ServerSpeedTolerance then
		return
	end

	-- The client reports TRAVEL speed, which can exceed forward top speed because
	-- strafe and hover thrust add on top of it. Ceiling is the sum, so a legitimate
	-- diagonal boost is not silently penalised while a fabricated number still is.
	local flight = Config.Flight
	local maxTravelSpeed = flight.BoostMaxSpeed + flight.StrafeSpeed + flight.HoverSpeed
	speed = math.min(speed, maxTravelSpeed)

	-- The client's requested radius is honoured only up to the clamp, and never
	-- beyond what its claimed speed justifies.
	local allowedRadius = math.min(Config.GetCarveRadius(speed), destruction.MaxRequestRadius)
	radius = math.clamp(radius, 1, allowedRadius)

	local minVoxelSize = math.max(Config.GetMinVoxelSize(speed), destruction.MinRequestVoxelSize)

	lastCarve[player] = now

	Voxel:DestroyArea(position, radius, direction.Unit, Config.GetDebrisForce(speed), {
		MinVoxelSize = minVoxelSize,
		ResetTime = destruction.ResetTime,
	})
end

function FlightDestructionService:Init(core)
	Core = core
end

function FlightDestructionService:Start()
	Config = Core:Get("FlightConfig")
	Net = Core:Get("Net")
	Voxel = Core:Get("VoxelDestructionService")

	Net.RequestCarve.OnServerEvent:Connect(function(player, position, radius, direction, speed)
		self:_onRequestCarve(player, position, radius, direction, speed)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastCarve[player] = nil
	end)
end

return FlightDestructionService
