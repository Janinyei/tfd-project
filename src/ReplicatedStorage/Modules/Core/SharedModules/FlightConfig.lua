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

--[[
	FLIGHT MODEL: camera-relative arcade movement, two modes.

	CRUISE (no Shift) — WASD moves along the camera's heading on the horizontal
	plane, E\/Q moves world-vertical (E up, Q down). Velocity is SET, not accelerated: full speed
	on the first frame, and exactly zero the frame you release the keys. No
	inertia, no drag, no coasting.

	BOOST (hold Shift) — direction comes from where the camera is LOOKING,
	including pitch, and speed accelerates from CruiseSpeed up to BoostMaxSpeed.
	Releasing Shift drops straight back to cruise behaviour.

	The craft body faces its travel direction; the camera is the aim, not a
	follower of the nose.
]]
FlightConfig.Flight = {
	-- Instant cruise speed (studs/s). Reached and lost in one frame.
	CruiseSpeed = 30,
	-- Vertical (Q/E) speed while cruising. Also instant.
	VerticalSpeed = 50,

	-- Boost accelerates along the camera look vector.
	BoostMaxSpeed = 700,
	BoostAccel = 200, -- studs/s^2 while Shift is held

	-- Pitch is HARD CLAMPED, in degrees. Staying well clear of +-90 is what
	-- removes the gimbal/singularity problem entirely: yaw and pitch can be
	-- plain scalars, no quaternions or CFrame-delta integration needed.
	MinPitch = -75, -- look down
	MaxPitch = 75, -- look up

	-- Aim sensitivity: RADIANS PER PIXEL of mouse delta, multiplied by the user's
	-- MouseDeltaSensitivity. No speed term and no smoothing, so look speed is
	-- identical at every travel speed.
	MouseSensitivity = 0.006,
	-- Smoothing applied to the aim's yaw angular velocity before anything reads
	-- it (TiltController's bank). Mouse input arrives in bursts, so the raw
	-- delta/dt is far too noisy to drive a visible lean.
	YawRateResponse = 10,

	-- How fast the BODY turns to face its travel direction, as an exponential
	-- rate. Purely cosmetic: it never affects where you actually move.
	BodyTurnResponse = 14,

	-- Cap on the force LinearVelocity may apply to hold the target velocity.
	MaxThrustForce = 500000,

	ToggleKey = Enum.KeyCode.F,
	BoostKey = Enum.KeyCode.LeftShift,
	ForwardKey = Enum.KeyCode.W,
	BackKey = Enum.KeyCode.S,
	LeftKey = Enum.KeyCode.A,
	RightKey = Enum.KeyCode.D,
	UpKey = Enum.KeyCode.E,
	DownKey = Enum.KeyCode.Q,
	-- Frees the cursor so the debug panel (key 9) is clickable while flying.
	MouseUnlockKey = Enum.KeyCode.T,
}

--[[
	Cosmetic tilt (see TiltController).

	HEAD LOOK turns the neck toward the camera aim while CRUISING or STATIONARY
	only — during a boost the whole body already points down the look vector, so
	extra neck rotation just over-rotates the head.

	BANK rolls the torso into turns, driven by how fast the aim is yawing.
]]
FlightConfig.Tilt = {
	-- Head look
	PitchLimit = 40, -- degrees up/down
	YawLimit = 65, -- degrees left/right
	-- Divides the aim components before asin: larger = subtler head turn.
	LookDivisor = 1.2,
	-- Exponential rate toward the target neck C0. Framerate-independent, unlike
	-- the fixed per-frame 0.1 lerp in the dodgeball original.
	HeadResponse = 12,

	-- Bank: degrees of roll per radian/sec of yaw. Higher = leans harder into
	-- the same turn. This is the knob for how dramatic turns feel.
	BankPerYawRate = 0.1,
	-- Hard clamp in degrees, so a mouse flick cannot put the body sideways.
	BankLimit = 35,
	-- How fast the lean follows the turn. Low = lazy, heavy roll; high = snappy
	-- and twitchy, since yaw rate itself is already smoothed upstream.
	BankResponse = 7,
}

--[[
	Boost trail: one Trail on the HumanoidRootPart, shown for every player that
	is boosting (driven by the replicated "Boosting" attribute, so other players
	see it too).
]]
FlightConfig.Trail = {
	-- Vertical separation of the two attachments == trail width.
	Width = 3,
	Lifetime = 0.45,
	-- Studs the root must move before a new segment is emitted; stops a hovering
	-- player from smearing a blob.
	MinLength = 0.6,
	Color = ColorSequence.new(Color3.fromRGB(120, 200, 255), Color3.fromRGB(255, 120, 60)),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	}),
	LightEmission = 0.8,
	-- Attribute the server sets; every client's trail mirrors it.
	Attribute = "Boosting",
}

FlightConfig.Camera = {
	-- Chase offset in craft-local space (behind + above).
	Distance = 18,
	Height = 4,
	-- Extra studs of pullback per stud/s of speed. Applied ONLY while boosting,
	-- so the stretch reads as speed rather than becoming the default framing.
	DistanceSpeedScale = 0.03,
	MaxDistance = 25,
	DistanceResponse = 3,

	--[[
		Dragging follow: how fast the camera's focus point chases the character.
		Lower = more trail/lag, the camera visibly drags behind while cruising.
		Boost is deliberately much stiffer — at 700 studs/s a lagging focus lets
		the craft slide to the edge of frame or out of it.
	]]
	FollowResponse = 7,
	BoostFollowResponse = 28,

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
		Master switch. OFF: temporarily disabled while tuning destruction, since
		shake on every carve makes it hard to judge whether a hole actually
		opened. Flip to true (or use the Shake checkbox in the debug panel) to
		bring carve/impact/rumble back — nothing else has to change.
	]]
	Enabled = false,

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

	--[[
		Slamming something that does NOT break. Detected as a SHORTFALL: velocity
		is set directly, so measured speed tracks the commanded speed unless
		geometry steals it.

		Not a frame-over-frame drop — releasing the keys zeroes velocity in one
		frame by design and must never read as a crash.

		ImpactMinSpeed   = only test while asking to move at least this fast.
		ImpactStallRatio = measured/commanded below this counts as a hit; 0.5
		                   means we lost over half the speed we asked for.
	]]
	ImpactMinSpeed = 150,
	ImpactStallRatio = 0.5,
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
	MinCarveSpeed = 100,
	-- Fraction of MinCarveSpeed the server requires from its OWN measurement of
	-- the player's velocity. Below 1 to tolerate replication lag and the speed
	-- already bled off by the impact before the packet lands.
	ServerSpeedTolerance = 0.3,
	--[[
		Seconds of history the server keeps for that measurement. It validates
		against the PEAK speed in this window, not the instantaneous value:
		hitting a wall zeroes the instantaneous speed, which would otherwise make
		the server refuse the carve that opens the wall and leave the player
		embedded in it.
	]]
	ServerSpeedWindow = 0.75,

	--[[
		Distance the probe's cast origin is pulled BACK along travel. A spherecast
		that starts inside geometry reports nothing, so once the craft is partly
		embedded the probe would go blind exactly when it must fire. Must exceed
		how far the hull can sink into a wall in one frame.
	]]
	ProbeBackoff = 8,

	--[[
		Escape hatch for the position dedupe. Pressed against a wall the craft
		stops, the contact point stops moving, and a pure position check would
		suppress every further carve — a deadlock. After this long with no carve,
		carve again regardless of how little the contact point moved.
	]]
	StallCarveInterval = 0.05,

	--[[
		PREDICTIVE NOCLIP. On firing a carve request the client immediately drops
		collision on parts inside the requested sphere, instead of waiting a full
		round trip for the server's geometry. Without it the wall is still solid
		locally while the request is in flight, which is what rams the craft to a
		stop at high speed.

		No client-side voxelization is involved: whole parts lose collision, and
		the server's authoritative geometry replaces them when it arrives.
	]]
	PredictiveNoclip = true,
	--[[
		How long a prediction survives unconfirmed. Must comfortably exceed a bad
		round trip, but stay short enough that a dropped packet cannot leave
		geometry pass-through for long. Predictions are also reverted immediately
		if the server reports the carve destroyed nothing.
	]]
	PredictionLifetime = 1.5,

	--[[
		PREDICTIVE PROBE. Server destruction is not instant: the request has to
		fly to the server, carve, and the result replicate back. At 400 studs/s
		that round trip is tens of studs of travel, so the probe looks AHEAD by
		  lead = speed * (dt * LeadFactor + ping * PingLeadFactor)
		floored at MinLeadDistance and capped at MaxLeadDistance. The ping term
		is what actually "makes up for lag" — it scales with the real measured
		round trip instead of a guess.
	]]
	ProbeRadius = 3,
	--[[
		Clearance cast radius: roughly the craft's half-width.

		ProbeRadius detects geometry EARLY (it is deliberately wider than the
		craft); this decides whether that geometry is actually in the way. Too
		small and you clip walls you thought you passed through; too large and
		you re-carve holes you already fit through.
	]]
	HullRadius = 2.2,
	LeadFactor = 10,
	-- Multiplier on measured round-trip time. GetNetworkPing() reports one-way
	-- seconds, so 2.0 covers the full round trip.
	PingLeadFactor = 6.0,
	MinLeadDistance = 6,
	-- Cap: without it, a 700 stud/s boost on a bad connection would probe far
	-- enough ahead to carve buildings you never actually reach.
	MaxLeadDistance = 120,

	--[[
		Push the carve centre INTO the surface along travel, as a fraction of the
		carve radius. Keep this SMALL: the sphere already reaches inward by its own
		radius, so biasing deep moves the removable region past the surface and
		leaves an intact skin over a hollow interior — a wall you cannot burst
		through. 0 centres it exactly on the contact point.
	]]
	CarveDepthBias = 0.15,

	-- Carve radius as a function of impact speed.
	CarveRadiusBase = 6,
	CarveRadiusPerSpeed = 0.035, -- + this * speed
	CarveRadiusMax = 25,

	-- Voxel granularity. Raised with speed: a big fast hole must not blow the
	-- MAX_SUBDIVISIONS (2000) / SIM_PART_CAPACITY (4000) budget in
	-- VoxelDestructionService.
	MinVoxelSizeBase = 90,
	MinVoxelSizePerSpeed = 0.03,
	MinVoxelSizeMax = 100,

	DebrisForceBase = 100,
	DebrisForcePerSpeed = 0.1,
	DebrisForceMax = 500,

	--[[
		0 == PERMANENT. Carved geometry never regenerates; the hole and the shell
		around it persist for the lifetime of the server. Set a positive number of
		seconds to bring healing back.
	]]
	ResetTime = 0,
	-- Settled rubble is frozen in place, not deleted: it is anchored (out of the
	-- physics solver) and dropped from the snapshot stream, so permanent wreckage
	-- costs nothing to keep. See the FREEZE-AND-FORGET block in
	-- VoxelDestructionService for the settle thresholds.

	-- No structural resistance: carving costs no speed. Flying through a building
	-- is meant to feel like the building loses.

	-- Client-side carve rate limit. Also enforced server-side.
	MinCarveInterval = 1,

	--------------------------------------------------------------------------------
	-- SERVER VALIDATION CLAMPS (client requests outside these are rejected)
	--------------------------------------------------------------------------------

	-- A carve must happen near the requesting player's own root.
	MaxCarveDistanceFromPlayer = 250,
	-- Hard clamp on the radius a client may ask for.
	MaxRequestRadius = 100,
	-- Hard floor on voxel size a client may ask for (small = expensive).
	MinRequestVoxelSize = 15,
	-- Server-side rate limit per player, slightly looser than the client's to
	-- tolerate jitter.
	ServerMinCarveInterval = 0.01,
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
