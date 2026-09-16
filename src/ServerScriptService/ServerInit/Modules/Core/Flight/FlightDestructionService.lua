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
	  * speed clamped to FlightConfig.Flight.BoostMaxSpeed, then force and voxel
	    size are DERIVED from it rather than sent by the client — a client cannot
	    ask for 0.1-stud voxels and blow the subdivision budget.
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

	speed = math.clamp(speed, destruction.MinCarveSpeed, Config.Flight.BoostMaxSpeed)

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
