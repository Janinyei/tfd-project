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
	-- Forward speed (studs/s)
	BaseSpeed = 60, -- speed the moment you enter flight
	-- S past zero flies backwards (reverse hover). Kept well below MaxSpeed:
	-- reversing into a building you cannot see should not be a top-speed option.
	ReverseMaxSpeed = 120,
	MaxSpeed = 400,
	BoostMaxSpeed = 700,

	ThrottleAccel = 180, -- studs/s^2 while holding throttle up
	ThrottleDecel = 220, -- studs/s^2 while holding throttle down
	BrakeDecel = 500, -- studs/s^2 while air-braking
	-- No passive drag: throttle is a setpoint, so releasing W holds your speed.
	-- This only bleeds boost OVERSPEED back down to MaxSpeed after Shift is
	-- released, as an exponential rate (higher = snappier decay).
	OverspeedBleed = 1.1,

	BoostAccelMultiplier = 2.2,

	-- Vertical hover thrust (Q up / E down). Independent of forward throttle, so
	-- you can climb while stationary.
	HoverSpeed = 90, -- studs/s at full hold
	HoverAccel = 320, -- studs/s^2 ramp toward HoverSpeed
	HoverDecel = 260, -- studs/s^2 decay back to 0 when released

	-- Lateral strafe thrust (A / D). Does not rotate the craft.
	StrafeSpeed = 70,
	StrafeAccel = 300,
	StrafeDecel = 260,

	-- Pitch is HARD CLAMPED, in degrees. Staying well clear of +-90 is what
	-- removes the gimbal/singularity problem entirely: yaw and pitch can be
	-- plain scalars, no quaternions or CFrame-delta integration needed.
	MinPitch = -55, -- nose down
	MaxPitch = 55, -- nose up

	-- Aim-style steering: RADIANS PER PIXEL of mouse delta, multiplied by the
	-- user's MouseDeltaSensitivity. There is intentionally no speed term and no
	-- rate smoothing anywhere, so the turn rate is identical at every speed and
	-- the nose is wherever you aimed it the same frame.
	MouseSensitivity = 0.006,
	-- Cap on the thrust force LinearVelocity may apply to hold target velocity.
	MaxThrustForce = 500000,

	ToggleKey = Enum.KeyCode.F,
	BoostKey = Enum.KeyCode.LeftShift,
	BrakeKey = Enum.KeyCode.LeftControl,
	ThrottleUpKey = Enum.KeyCode.W,
	ThrottleDownKey = Enum.KeyCode.S,
	StrafeLeftKey = Enum.KeyCode.A,
	StrafeRightKey = Enum.KeyCode.D,
	HoverUpKey = Enum.KeyCode.Q,
	HoverDownKey = Enum.KeyCode.E,
	-- Frees the cursor so the debug panel (key 9) is clickable while flying.
	MouseUnlockKey = Enum.KeyCode.Eight,
}

FlightConfig.Camera = {
	-- Chase offset in craft-local space (behind + above).
	Distance = 18,
	Height = 4,
	DistanceSpeedScale = 0.03, -- extra studs of pullback per stud/s of speed
	MaxDistance = 44,
	DistanceResponse = 3,

	FocusForward = 2, -- look-ahead offset applied to the focus point

	-- Exponential smoothing of the camera's orientation toward the craft's, so the
	-- camera lags slightly instead of being welded to the nose.
	-- Kept high now that the craft snaps to aim: a slow camera would reintroduce
	-- exactly the steering lag the rigid align removed. Lower it only for a
	-- deliberately loose, heavy-camera feel.
	OrientationResponse = 30,

	BaseFov = 70,
	MaxFov = 105,
	FovSpeedReference = 400, -- speed at which MaxFov is reached
	FovResponse = 4,

	CollisionPadding = 1.5,
}

--[[
	Camera shake (CameraShaker, vendored at Utils/CameraShaker).

	Magnitudes are in the same units CameraShakeInstance uses: roughly studs of
	positional offset / degrees of rotational offset before influence scaling.
	Roughness is oscillations per second — high = sharp rattle, low = heavy sway.

	One-shot shakes MUST have a non-zero fade-out. ShakeOnce with fadeOut = 0
	never terminates.
]]
FlightConfig.Shake = {
	--[[
		Carving through geometry. Scales with BOTH the hole punched and the speed
		it was punched at:
			magnitude = CarveBase + radius * CarvePerRadius + speed * CarvePerSpeed
		Radius alone is not enough — carve radius saturates at CarveRadiusMax, so
		without the speed term a 700 stud/s hit through a wall shakes exactly as
		hard as a 200 stud/s one.
	]]
	CarveBase = 0.2,
	CarvePerRadius = 0.045,
	CarvePerSpeed = 0.0022,
	CarveMax = 2.4,
	CarveRoughness = 11,
	CarveFadeIn = 0.03,
	CarveFadeOut = 0.35,

	-- Slamming something that does NOT break. Detected as unexplained velocity
	-- loss in a single frame (see FlightController._detectImpact), so the
	-- threshold must sit above anything throttle/brake/drag/carve can produce.
	ImpactMinSpeedLoss = 80,
	ImpactPerSpeedLoss = 0.006,
	ImpactMax = 3,
	ImpactRoughness = 16,
	ImpactFadeIn = 0.02,
	ImpactFadeOut = 0.6,

	-- Sustained high-speed rumble. Magnitude is re-driven every frame from
	-- travel speed, so one sustained instance covers the whole range.
	RumbleMinSpeed = 260,
	RumbleMaxSpeed = 700,
	RumbleMaxMagnitude = 0.22,
	RumbleRoughness = 7,
	-- MUST stay > 0. CameraShakeInstance sets `sustain = fadeInTime > 0`, so a
	-- zero fade-in makes the rumble a fading one-shot instead of a sustained
	-- shake, and its fade math then divides by a zero fade-out duration.
	RumbleFadeIn = 0.4,
}

FlightConfig.Destruction = {
	--[[
		Hard speed gate. Below this, flying into geometry does not carve at all —
		you bounce. Enforced in THREE places, deliberately:
		  1. client skips the probe entirely;
		  2. server rejects any request reporting less than this;
		  3. server independently checks the player's own replicated root
		     velocity, so a client cannot just lie about its speed.
	]]
	MinCarveSpeed = 130,
	-- Fraction of MinCarveSpeed the server requires from its OWN measurement of
	-- the player's velocity. Below 1 to tolerate replication lag and the speed
	-- already bled off by the impact before the packet lands.
	ServerSpeedTolerance = 0.6,

	--[[
		PREDICTIVE PROBE. Server destruction is not instant: the request has to
		fly to the server, carve, and the result replicate back. At 400 studs/s
		that round trip is tens of studs of travel, so the probe looks AHEAD by
		  lead = speed * (dt * LeadFactor + ping * PingLeadFactor)
		floored at MinLeadDistance and capped at MaxLeadDistance. The ping term
		is what actually "makes up for lag" — it scales with the real measured
		round trip instead of a guess.
	]]
	ProbeRadius = 5,
	LeadFactor = 10,
	-- Multiplier on measured round-trip time. GetNetworkPing() reports one-way
	-- seconds, so 2.0 covers the full round trip.
	PingLeadFactor = 2.0,
	MinLeadDistance = 6,
	-- Cap: without it, a 700 stud/s boost on a bad connection would probe far
	-- enough ahead to carve buildings you never actually reach.
	MaxLeadDistance = 90,

	--[[
		Push the carve centre INTO the surface along travel, as a fraction of the
		carve radius. A sphere centred exactly on the contact point only removes
		the near half of the wall, so a thick wall still blocks you; biasing
		inward means the hole is already deep enough when you arrive.
	]]
	CarveDepthBias = 0.6,

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
	DebrisForceMax = 5000,

	--[[
		0 == PERMANENT. Carved geometry never regenerates; the hole and the shell
		around it persist for the lifetime of the server. Set a positive number of
		seconds to bring healing back.
	]]
	ResetTime = 0,
	-- Loose rubble is still collected after this many seconds. The structural
	-- damage stays; only the flying chunks are recycled, so debris cannot pile up
	-- against the sim-part pool (4000) or keep costing 20Hz physics snapshots.
	DebrisLifetime = 12,

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
	MinRequestVoxelSize = 15,
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
