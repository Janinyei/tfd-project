--!strict
--[[
	FlightController  (client)

	Classic hover-flight, NOT omnidirectional:
	  * mouse yaws freely and pitches within a hard clamp (MinPitch/MaxPitch);
	  * no roll axis — the craft stays level on Z;
	  * Q / E apply vertical hover thrust, independent of forward throttle;
	  * A / D strafe laterally without rotating;
	  * W / S throttle forward speed, Shift boosts, Ctrl air-brakes.

	NO GIMBAL LOCK BY CONSTRUCTION: pitch is clamped well clear of +-90 and roll
	is always zero, so orientation is just two scalars fed to
	CFrame.fromEulerAnglesYXZ. The singularity that motivates quaternions only
	exists when pitch can reach straight up/down; clamping removes it rather than
	papering over it.

	Movement is client-authoritative (network ownership of the HumanoidRootPart).
	Anything else feels unusable at 400+ studs/s.

	Public API (read by CameraController and FlightDestructionController):
		:IsFlying()       -> boolean
		:GetOrientation() -> CFrame  (rotation only, no roll)
		:GetSpeed()       -> number  (forward speed only)
		:GetVelocity()    -> Vector3 (forward + strafe + hover, world space)
		:GetRoot()        -> BasePart?
		:ApplySpeedLoss(amount)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local FlightController = {}

local Core
local Config
local Camera

-- Live state
local flying = false
local yaw = 0 -- radians, unbounded (wraps naturally)
local pitch = 0 -- radians, clamped to [MinPitch, MaxPitch]
local orientation = CFrame.identity -- rebuilt from yaw/pitch each frame

local forwardSpeed = 0
local strafeSpeed = 0 -- signed, +right
local hoverSpeed = 0 -- signed, +up
local velocity = Vector3.zero -- last applied world velocity

-- Smoothed angular rates (rad/s)
local pitchRate, yawRate = 0, 0
-- Mouse delta accumulated since last frame
local mouseDeltaX, mouseDeltaY = 0, 0

-- Mouse capture. Unlocking frees the cursor for the debug panel; while unlocked
-- the craft ignores mouse motion entirely, otherwise reaching for a slider
-- would spin the nose.
local mouseLocked = true

-- Impact detection: measured speed last frame, and the loss that tripped the
-- most recent hard impact (for the debug panel).
local lastMeasuredSpeed = 0
local lastImpactLoss = 0

-- Rig
local character: Model? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local linearVelocity: LinearVelocity? = nil
local alignOrientation: AlignOrientation? = nil
local rigTrove = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

-- Exponential smoothing factor, framerate independent.
local function ease(response: number, dt: number): number
	return 1 - math.exp(-response * dt)
end

local function axis(negative: Enum.KeyCode, positive: Enum.KeyCode): number
	local value = 0
	if UserInputService:IsKeyDown(negative) then
		value -= 1
	end
	if UserInputService:IsKeyDown(positive) then
		value += 1
	end
	return value
end

--[[
	Drive a thrust axis toward `input * maxSpeed`: accelerate while held, decay
	toward zero when released. Keeps hover/strafe from snapping on and off.
]]
local function approachThrust(
	current: number,
	input: number,
	maxSpeed: number,
	accel: number,
	decel: number,
	dt: number
): number
	local target = input * maxSpeed
	local rate = (input == 0) and decel or accel
	local step = rate * dt

	if current < target then
		return math.min(current + step, target)
	elseif current > target then
		return math.max(current - step, target)
	end
	return current
end

--------------------------------------------------------------------------------
-- RIG
--------------------------------------------------------------------------------

function FlightController:_buildRig(): boolean
	if not character or not root or not humanoid then
		return false
	end

	rigTrove = Trove.new()

	local attachment = Instance.new("Attachment")
	attachment.Name = "FlightAttachment"
	attachment.Parent = root
	rigTrove:Add(attachment)

	-- Velocity is SET, not integrated from forces: no fighting gravity, no
	-- accumulated error, and the physics engine still owns collisions.
	--
	-- Force IS limited, so slamming indestructible geometry is a fight the
	-- collision wins instead of the constraint — unlimited force reads as the
	-- body convulsing against the surface.
	--
	-- The limit MUST be the scalar MaxForce with ForceLimitMode.Magnitude.
	-- MaxAxesForce is ignored unless ForceLimitMode is PerAxis, so setting only
	-- MaxAxesForce leaves the effective cap at MaxForce's default and the
	-- constraint cannot even hold altitude against gravity. Magnitude is also
	-- the right model here: thrust should cap isotropically, not per world axis.
	local lv = Instance.new("LinearVelocity")
	lv.Name = "FlightVelocity"
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.ForceLimitsEnabled = true
	lv.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	lv.MaxForce = Config.Flight.MaxThrustForce
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	rigTrove:Add(lv)

	local ao = Instance.new("AlignOrientation")
	ao.Name = "FlightOrientation"
	ao.Attachment0 = attachment
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.RigidityEnabled = false
	ao.ReactionTorqueEnabled = false
	ao.Responsiveness = Config.Flight.AlignResponsiveness
	ao.MaxTorque = Config.Flight.AlignMaxTorque
	ao.CFrame = orientation
	ao.Parent = root
	rigTrove:Add(ao)

	linearVelocity = lv
	alignOrientation = ao
	return true
end

function FlightController:_teardownRig()
	if rigTrove then
		rigTrove:Destroy()
		rigTrove = nil
	end
	linearVelocity = nil
	alignOrientation = nil
end

--------------------------------------------------------------------------------
-- FLIGHT STATE
--------------------------------------------------------------------------------

function FlightController:StartFlight()
	if flying or not root or not humanoid then
		return
	end

	local flight = Config.Flight

	-- Inherit heading, drop any roll, clamp inherited pitch into the legal band.
	local rx, ry = root.CFrame:ToEulerAnglesYXZ()
	yaw = ry
	pitch = math.clamp(rx, math.rad(flight.MinPitch), math.rad(flight.MaxPitch))
	orientation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)

	forwardSpeed = math.max(flight.BaseSpeed, root.AssemblyLinearVelocity.Magnitude)
	strafeSpeed, hoverSpeed = 0, 0
	velocity = Vector3.zero
	pitchRate, yawRate = 0, 0
	mouseDeltaX, mouseDeltaY = 0, 0
	mouseLocked = true

	-- Seeded from the real assembly, or a stale value from a previous flight
	-- would register as a huge impact on the first frame.
	lastMeasuredSpeed = root.AssemblyLinearVelocity.Magnitude
	lastImpactLoss = 0

	if not self:_buildRig() then
		return
	end

	humanoid.PlatformStand = true
	flying = true
end

function FlightController:StopFlight()
	if not flying then
		return
	end
	flying = false
	self:_teardownRig()

	-- _update no longer runs, so nothing would restore these: the cursor would
	-- stay captured and invisible on the ground.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	if humanoid then
		humanoid.PlatformStand = false
	end
end

function FlightController:Toggle()
	if flying then
		self:StopFlight()
	else
		self:StartFlight()
	end
end

--------------------------------------------------------------------------------
-- CHARACTER BINDING
--------------------------------------------------------------------------------

function FlightController:_bindCharacter(newCharacter: Model)
	self:StopFlight()

	character = newCharacter
	root = newCharacter:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	humanoid = newCharacter:WaitForChild("Humanoid", 10) :: Humanoid?
end

--------------------------------------------------------------------------------
-- PER-FRAME
--------------------------------------------------------------------------------

function FlightController:_steer(dt: number)
	local flight = Config.Flight

	-- Pixel delta normalized against MouseFullDeflection = the delta that counts
	-- as full stick, so the result is a clean [-1, 1] stick value regardless of DPI.
	-- Mouse right (+X) yaws right, which is NEGATIVE rotation about +Y.
	-- Mouse up (-Y) pitches up, which is POSITIVE rotation about +X.
	local gain = flight.MouseGain * UserInputService.MouseDeltaSensitivity / flight.MouseFullDeflection

	local yawInput = math.clamp(-mouseDeltaX * gain, -1, 1)
	local pitchInput = math.clamp(-mouseDeltaY * gain, -1, 1)
	mouseDeltaX, mouseDeltaY = 0, 0

	local alpha = ease(flight.RateResponse, dt)
	yawRate += (yawInput * flight.YawRate - yawRate) * alpha
	pitchRate += (pitchInput * flight.PitchRate - pitchRate) * alpha

	yaw += yawRate * dt
	pitch = math.clamp(
		pitch + pitchRate * dt,
		math.rad(flight.MinPitch),
		math.rad(flight.MaxPitch)
	)

	-- Kill the rate once clamped, otherwise the stick "charges up" against the
	-- limit and the nose snaps when you steer back.
	if pitch <= math.rad(flight.MinPitch) and pitchRate < 0 then
		pitchRate = 0
	elseif pitch >= math.rad(flight.MaxPitch) and pitchRate > 0 then
		pitchRate = 0
	end

	-- Roll is always 0: with pitch clamped inside +-90 this is singularity-free.
	orientation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

function FlightController:_integrateThrust(dt: number)
	local flight = Config.Flight

	local boosting = UserInputService:IsKeyDown(flight.BoostKey)
	local braking = UserInputService:IsKeyDown(flight.BrakeKey)
	local throttle = axis(flight.ThrottleDownKey, flight.ThrottleUpKey)

	local maxSpeed = boosting and flight.BoostMaxSpeed or flight.MaxSpeed

	if throttle > 0 then
		local accel = flight.ThrottleAccel * (boosting and flight.BoostAccelMultiplier or 1)
		forwardSpeed += accel * dt
	elseif throttle < 0 then
		forwardSpeed -= flight.ThrottleDecel * dt
	end

	-- Air-brake pulls toward zero from EITHER direction. If it just subtracted, it
	-- would accelerate you backwards once past zero, which is not a brake.
	if braking then
		local step = flight.BrakeDecel * dt
		if forwardSpeed > 0 then
			forwardSpeed = math.max(0, forwardSpeed - step)
		elseif forwardSpeed < 0 then
			forwardSpeed = math.min(0, forwardSpeed + step)
		end
	end

	-- Passive drag, proportional to speed — signed, so it decays reverse too.
	forwardSpeed -= forwardSpeed * flight.Drag * dt

	-- S past zero reverses. Reverse has its own, much lower ceiling and is never
	-- boosted: backing up at 700 studs/s is not a control scheme.
	forwardSpeed = math.clamp(forwardSpeed, -flight.ReverseMaxSpeed, maxSpeed)

	-- Q climbs, E descends. Independent of throttle so you can hover-climb.
	hoverSpeed = approachThrust(
		hoverSpeed,
		axis(flight.HoverDownKey, flight.HoverUpKey),
		flight.HoverSpeed,
		flight.HoverAccel,
		flight.HoverDecel,
		dt
	)

	strafeSpeed = approachThrust(
		strafeSpeed,
		axis(flight.StrafeLeftKey, flight.StrafeRightKey),
		flight.StrafeSpeed,
		flight.StrafeAccel,
		flight.StrafeDecel,
		dt
	)
end

--[[
	Detect slamming something that does NOT break.

	The constraint drives the assembly toward `velocity` every frame, so measured
	speed tracks commanded speed closely — EXCEPT when a collision steals it.
	A per-frame drop in measured speed above ImpactMinSpeedLoss therefore means
	geometry stopped us, not the throttle. The threshold has to clear anything
	brake/drag/carve-bleed could account for in one frame, which is why it sits
	at 80 rather than something small.

	Also bleeds the commanded speed down to what was actually achieved; without
	that, the constraint would keep shoving the craft into the wall at full
	throttle while the camera shook.
]]
function FlightController:_detectImpact()
	if not root then
		return
	end

	local measured = root.AssemblyLinearVelocity.Magnitude
	local lost = lastMeasuredSpeed - measured
	lastMeasuredSpeed = measured

	lastImpactLoss = 0
	if lost < Config.Shake.ImpactMinSpeedLoss then
		return
	end

	lastImpactLoss = lost
	forwardSpeed = math.clamp(forwardSpeed, -Config.Flight.ReverseMaxSpeed, measured)

	if Camera then
		Camera:ShakeImpact(lost)
	end
end

function FlightController:_update(dt: number)
	if not flying then
		return
	end
	if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then
		self:StopFlight()
		return
	end

	self:_steer(dt)
	self:_integrateThrust(dt)
	self:_detectImpact()

	-- Re-asserted every frame: the PlayerModule resets MouseBehavior on respawn
	-- and on input-mode changes. Skipped while unlocked so the cursor stays free
	-- for the debug panel.
	UserInputService.MouseBehavior = if mouseLocked
		then Enum.MouseBehavior.LockCenter
		else Enum.MouseBehavior.Default

	-- Hover thrust is world-vertical, not craft-relative: pitching the nose up
	-- must not turn "climb" into "climb and drift backwards".
	velocity = orientation.LookVector * forwardSpeed
		+ orientation.RightVector * strafeSpeed
		+ Vector3.yAxis * hoverSpeed

	-- Constraint strengths are re-pushed every frame, not just at rig build, so
	-- the debug panel's sliders take effect without re-toggling flight. Three
	-- property writes; irrelevant next to the physics step.
	if linearVelocity then
		linearVelocity.MaxForce = Config.Flight.MaxThrustForce
		linearVelocity.VectorVelocity = velocity
	end
	if alignOrientation then
		alignOrientation.Responsiveness = Config.Flight.AlignResponsiveness
		alignOrientation.MaxTorque = Config.Flight.AlignMaxTorque
		alignOrientation.CFrame = orientation
	end
end

--------------------------------------------------------------------------------
-- PUBLIC
--------------------------------------------------------------------------------

function FlightController:IsFlying(): boolean
	return flying
end

function FlightController:GetOrientation(): CFrame
	return orientation
end

function FlightController:GetSpeed(): number
	return forwardSpeed
end

-- Full world velocity including strafe and hover. Impact detection casts along
-- THIS, not LookVector: strafing or climbing into a wall must still carve.
function FlightController:GetVelocity(): Vector3
	return velocity
end

-- Speed stolen by the most recent hard impact, 0 on any frame without one.
function FlightController:GetLastImpactLoss(): number
	return lastImpactLoss
end

function FlightController:GetRoot(): BasePart?
	return root
end

function FlightController:IsMouseLocked(): boolean
	return mouseLocked
end

--[[
	Free or recapture the cursor. Pending mouse delta is dropped on every
	transition: deltas accumulated while the cursor was travelling to a slider
	must not be applied to the craft when capture resumes.
]]
function FlightController:SetMouseLocked(locked: boolean)
	mouseLocked = locked
	mouseDeltaX, mouseDeltaY = 0, 0
end

function FlightController:ToggleMouseLock()
	self:SetMouseLocked(not mouseLocked)
end

--[[
	Bleed speed off — called by FlightDestructionController when the craft
	punches through geometry. Client-authoritative movement means the client
	applies its own impact cost; the server only owns the destruction.
]]
function FlightController:ApplySpeedLoss(amount: number)
	local flight = Config.Flight
	forwardSpeed = math.max(flight.MinSpeed, forwardSpeed - amount)

	-- Lateral/vertical thrust bleeds too, or a sideways crash costs nothing.
	local scale = math.max(0, 1 - amount / math.max(flight.MaxSpeed, 1))
	strafeSpeed *= scale
	hoverSpeed *= scale
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function FlightController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function FlightController:Start()
	Config = Core:Get("FlightConfig")
	Camera = Core:Get("CameraController")

	if player.Character then
		self:_bindCharacter(player.Character)
	end
	self._trove:Connect(player.CharacterAdded, function(newCharacter)
		self:_bindCharacter(newCharacter)
	end)

	self._trove:Connect(UserInputService.InputBegan, function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Config.Flight.ToggleKey then
			self:Toggle()
		elseif input.KeyCode == Config.Flight.MouseUnlockKey then
			self:ToggleMouseLock()
		end
	end)

	self._trove:Connect(UserInputService.InputChanged, function(input, processed)
		if processed or not flying or not mouseLocked then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			mouseDeltaX += input.Delta.X
			mouseDeltaY += input.Delta.Y
		end
	end)

	-- Runs before the camera's own RenderStepped work so the camera reads a
	-- fresh orientation in the same frame.
	RunService:BindToRenderStep("FlightController", Enum.RenderPriority.Camera.Value - 1, function(dt)
		self:_update(dt)
	end)
	self._trove:Add(function()
		RunService:UnbindFromRenderStep("FlightController")
	end)
end

return FlightController
