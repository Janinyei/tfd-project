--!strict
--[[
	FlightConfig

	Every tunable for flight, camera and impact destruction. Nothing tunable is
	hardcoded in a controller or service.

	The Destruction table is SHARED on purpose: the client decides where to carve,
	the server validates that request against these same clamps. Both sides reading
	one table is what keeps validation honest.
]]

local FlightConfig = {}

FlightConfig.Flight = {
	-- Speed (studs/s)
	BaseSpeed = 60, -- speed the moment you enter flight
	MinSpeed = 0, -- full stop allowed (hover)
	MaxSpeed = 400,
	BoostMaxSpeed = 700,

	ThrottleAccel = 180, -- studs/s^2 while holding throttle up
	ThrottleDecel = 220, -- studs/s^2 while holding throttle down
	BrakeDecel = 500, -- studs/s^2 while air-braking
	Drag = 0.35, -- passive loss: drag * speed  (studs/s per second)

	BoostAccelMultiplier = 2.2,

	-- Angular rates (radians/s) at full input
	PitchRate = 2.6,
	YawRate = 2.2,
	RollRate = 3.4,

	-- Mouse steering. Pixel delta is divided by MouseFullDeflection to get a
	-- [-1, 1] stick value, then scaled by MouseGain and the user's
	-- MouseDeltaSensitivity setting.
	MouseGain = 1.0,
	-- Pixel delta per frame that counts as "full stick". Larger = less twitchy.
	MouseFullDeflection = 14,

	-- Exponential smoothing on angular rates: 1 - exp(-Response * dt).
	-- Low = heavy craft with rotational inertia, high = instant snap.
	RateResponse = 9,

	-- Auto-level (hold key): slerp orientation toward level heading.
	AutoLevelRate = 4,

	-- Constraint strengths
	AlignResponsiveness = 60,
	AlignMaxTorque = 1e6,

	ToggleKey = Enum.KeyCode.F,
	BoostKey = Enum.KeyCode.LeftShift,
	BrakeKey = Enum.KeyCode.LeftControl,
	AutoLevelKey = Enum.KeyCode.Space,
	ThrottleUpKey = Enum.KeyCode.W,
	ThrottleDownKey = Enum.KeyCode.S,
	RollLeftKey = Enum.KeyCode.A,
	RollRightKey = Enum.KeyCode.D,
}

FlightConfig.Camera = {
	-- Chase offset in craft-local space (behind + above).
	Distance = 18,
	Height = 4,
	DistanceSpeedScale = 0.03, -- extra studs of pullback per stud/s of speed
	MaxDistance = 44,
	DistanceResponse = 3,

	FocusForward = 2, -- look-ahead offset applied to the focus point

	-- 1 = camera rolls with the craft (cockpit-true, readable when inverted).
	-- 0 = camera stays world-up-stabilized (readable, but lies about orientation).
	RollFollow = 0.75,
	-- Exponential smoothing of the camera's orientation toward the craft's.
	OrientationResponse = 12,

	BaseFov = 70,
	MaxFov = 105,
	FovSpeedReference = 400, -- speed at which MaxFov is reached
	FovResponse = 4,

	CollisionPadding = 1.5,
}

FlightConfig.Destruction = {
	-- Below this speed, flying into geometry does not carve at all.
	MinCarveSpeed = 45,

	-- Spherecast probe. Radius covers the character; lead distance is speed-scaled
	-- because server destruction is not instant and the carve must exist before
	-- the body arrives.
	ProbeRadius = 2.5,
	LeadFactor = 2.0, -- lead = speed * dt * LeadFactor
	MinLeadDistance = 6,

	-- Carve radius as a function of impact speed.
	CarveRadiusBase = 6,
	CarveRadiusPerSpeed = 0.035, -- + this * speed
	CarveRadiusMax = 22,

	-- Voxel granularity. Raised with speed: a big fast hole must not blow the
	-- MAX_SUBDIVISIONS (2000) / SIM_PART_CAPACITY (4000) budget in
	-- VoxelDestructionService.
	MinVoxelSizeBase = 3,
	MinVoxelSizePerSpeed = 0.012,
	MinVoxelSizeMax = 9,

	DebrisForceBase = 40,
	DebrisForcePerSpeed = 0.35,
	DebrisForceMax = 260,

	ResetTime = 8,

	-- Speed cost of punching through, scaled by carved volume.
	SpeedLossPerCarve = 0.9, -- speedLoss = SpeedLossPerCarve * carveRadius
	SpeedLossSpeedScale = 0.10, -- + this fraction of current speed

	-- Client-side carve rate limit. Also enforced server-side.
	MinCarveInterval = 0.06,

	--------------------------------------------------------------------------------
	-- SERVER VALIDATION CLAMPS (client requests outside these are rejected)
	--------------------------------------------------------------------------------

	-- A carve must happen near the requesting player's own root.
	MaxCarveDistanceFromPlayer = 120,
	-- Hard clamp on the radius a client may ask for.
	MaxRequestRadius = 24,
	-- Hard floor on voxel size a client may ask for (small = expensive).
	MinRequestVoxelSize = 2,
	-- Server-side rate limit per player, slightly looser than the client's to
	-- tolerate jitter.
	ServerMinCarveInterval = 0.05,
}

-- Names of Workspace folders whose descendants are destructible.
-- Must match DESTRUCTIBLE_CONTAINER_NAMES in VoxelDestructionService.
FlightConfig.DestructibleContainers = {
	"Map",
}

--------------------------------------------------------------------------------
-- DERIVED HELPERS (shared so client request and server validation agree)
--------------------------------------------------------------------------------

function FlightConfig.GetCarveRadius(speed: number): number
	local d = FlightConfig.Destruction
	return math.min(d.CarveRadiusBase + d.CarveRadiusPerSpeed * speed, d.CarveRadiusMax)
end

function FlightConfig.GetMinVoxelSize(speed: number): number
	local d = FlightConfig.Destruction
	return math.min(d.MinVoxelSizeBase + d.MinVoxelSizePerSpeed * speed, d.MinVoxelSizeMax)
end

function FlightConfig.GetDebrisForce(speed: number): number
	local d = FlightConfig.Destruction
	return math.min(d.DebrisForceBase + d.DebrisForcePerSpeed * speed, d.DebrisForceMax)
end

function FlightConfig:Init(_core) end
function FlightConfig:Start() end

return FlightConfig
