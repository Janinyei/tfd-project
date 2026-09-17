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
local Stats

-- player -> os.clock() of last accepted carve
local lastCarve: { [Player]: number } = {}

--[[
	player -> { Speed, Clock }: highest server-measured speed seen inside the
	current window. Lets a carve be validated by how fast the player was a moment
	ago, which is what makes wall contact survivable (see _onRequestCarve).
]]
local peakSpeed: { [Player]: { Speed: number, Clock: number } } = {}

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

	--[[
		Independent check against the server's OWN view of the player's velocity,
		so the reported number cannot simply be fabricated.

		Compared against the player's PEAK speed over a short window, not the
		instantaneous value. The instantaneous check deadlocked: flying into a
		wall stops the craft, measured speed collapses toward zero, and the server
		then refuses the very carve that would open the wall — so the player sits
		embedded in intact geometry forever.

		The window still bounds cheating to "was legitimately fast very recently".
	]]
	local measured = root.AssemblyLinearVelocity.Magnitude
	local peak = peakSpeed[player]
	if not peak or now - peak.Clock > destruction.ServerSpeedWindow or measured > peak.Speed then
		peak = { Speed = measured, Clock = now }
		peakSpeed[player] = peak
	end

	if math.max(measured, peak.Speed) < destruction.MinCarveSpeed * destruction.ServerSpeedTolerance then
		return
	end

	--[[
		Ceiling on the reported TRAVEL speed. Boost replaces cruise rather than
		stacking with it, so the fastest legitimate case is either a full boost or
		cruise plus vertical thrust — whichever is larger.
	]]
	local flight = Config.Flight
	local maxTravelSpeed = math.max(
		flight.BoostMaxSpeed,
		flight.CruiseSpeed + flight.VerticalSpeed
	)
	speed = math.min(speed, maxTravelSpeed)

	-- The client's requested radius is honoured only up to the clamp, and never
	-- beyond what its claimed speed justifies.
	local allowedRadius = math.min(Config.GetCarveRadius(speed), destruction.MaxRequestRadius)
	radius = math.clamp(radius, 1, allowedRadius)

	local minVoxelSize = math.max(Config.GetMinVoxelSize(speed), destruction.MinRequestVoxelSize)

	lastCarve[player] = now

	-- Returns how many voxels were knocked loose, so the stat counts real
	-- destruction rather than carve requests: a carve that hit nothing, or hit a
	-- region already hollowed out, credits zero.
	local destroyed = Voxel:DestroyArea(position, radius, direction.Unit, Config.GetDebrisForce(speed), {
		MinVoxelSize = minVoxelSize,
		ResetTime = destruction.ResetTime,
	})

	destroyed = destroyed or 0
	if destroyed > 0 then
		Stats:AddVoxelsDestroyed(player, destroyed)
	end

	-- Echo the real count back so the client can distinguish "rejected" from
	-- "carved but the hole did not open".
	Net.CarveResult:FireClient(player, math.min(destroyed, 65535))
end

function FlightDestructionService:Init(core)
	Core = core
end

function FlightDestructionService:Start()
	Config = Core:Get("FlightConfig")
	Net = Core:Get("Net")
	Voxel = Core:Get("VoxelDestructionService")
	Stats = Core:Get("StatsService")

	Net.RequestCarve.OnServerEvent:Connect(function(player, position, radius, direction, speed)
		self:_onRequestCarve(player, position, radius, direction, speed)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastCarve[player] = nil
		peakSpeed[player] = nil
	end)
end

return FlightDestructionService
