--!strict
--[[
	FlightController  (client)

	Camera-relative arcade flight, two modes:

	CRUISE (no Shift)
		WASD moves along the camera's heading projected onto the horizontal plane,
		Q/E moves world-vertical. Velocity is SET at full CruiseSpeed on the first
		frame and set to EXACTLY ZERO the frame all keys are released. No
		acceleration, no inertia, no coasting — press to go, release to stop dead.

	BOOST (hold Shift)
		Direction comes from where the camera is LOOKING, pitch included, so you
		fly into the screen. Speed accelerates from CruiseSpeed toward
		BoostMaxSpeed while held. Releasing Shift returns to cruise immediately.

	AIM vs BODY: the mouse aims the CAMERA (yaw + clamped pitch). The craft body
	does not steer — it turns to face whatever direction it is travelling, purely
	cosmetically. This is the inverse of a plane: movement follows the camera
	rather than the camera following the nose.

	NO GIMBAL LOCK: pitch is clamped well clear of +-90 and roll is always zero,
	so aim is two scalars fed to CFrame.fromEulerAnglesYXZ.

	Movement is client-authoritative (network ownership of the HumanoidRootPart).
	Anything else feels unusable at 700 studs/s.

	Public API:
		:IsFlying()          -> boolean
		:GetAimOrientation() -> CFrame   (camera aim; what CameraController uses)
		:GetOrientation()    -> CFrame   (body facing; cosmetic)
		:GetVelocity()       -> Vector3  (world velocity actually applied)
		:GetSpeed()          -> number   (travel speed)
		:IsBoosting()        -> boolean
		:GetRoot()           -> BasePart?
		:IsMouseLocked()     -> boolean
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

-- Aim (camera). Yaw is unbounded, pitch clamped.
local yaw = 0
local pitch = 0
local aimOrientation = CFrame.identity

-- Body facing. Eased toward travel direction; cosmetic only.
local bodyOrientation = CFrame.identity

local velocity = Vector3.zero
local boostSpeed = 0
local boosting = false

-- Mouse delta accumulated since last frame
local mouseDeltaX, mouseDeltaY = 0, 0

-- Mouse capture. Unlocking frees the cursor for the debug panel; while unlocked
-- the craft ignores mouse motion entirely, otherwise reaching for a slider
-- would swing the camera.
local mouseLocked = true

-- Impact detection: the velocity we commanded last frame, and the shortfall that
-- tripped the most recent hard impact (for the debug panel).
local lastCommandedSpeed = 0
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

	--[[
		Velocity is SET, not integrated from forces: no fighting gravity and no
		accumulated error, while the physics engine still owns collisions.

		The force limit MUST be the scalar MaxForce with ForceLimitMode.Magnitude.
		MaxAxesForce is ignored unless ForceLimitMode is PerAxis, so setting only
		MaxAxesForce leaves the effective cap at MaxForce's default and the
		constraint cannot even hold altitude against gravity.
	]]
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

	-- Rigid: the body matches the commanded facing the same frame. Body facing is
	-- cosmetic here, so there is nothing to gain from letting it lag.
	local ao = Instance.new("AlignOrientation")
	ao.Name = "FlightOrientation"
	ao.Attachment0 = attachment
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.RigidityEnabled = true
	ao.ReactionTorqueEnabled = false
	ao.CFrame = bodyOrientation
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

	-- Inherit heading, drop roll, clamp inherited pitch into the legal band.
	local rx, ry = root.CFrame:ToEulerAnglesYXZ()
	yaw = ry
	pitch = math.clamp(rx, math.rad(flight.MinPitch), math.rad(flight.MaxPitch))
	aimOrientation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	bodyOrientation = CFrame.fromEulerAnglesYXZ(0, yaw, 0)

	velocity = Vector3.zero
	boostSpeed = 0
	boosting = false
	mouseDeltaX, mouseDeltaY = 0, 0
	mouseLocked = true

	lastCommandedSpeed = 0
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

-- Mouse aims the camera. Pixel delta maps directly to a yaw/pitch delta in
-- radians: no smoothing, no speed term.
function FlightController:_aim()
	local flight = Config.Flight
	local gain = flight.MouseSensitivity * UserInputService.MouseDeltaSensitivity

	yaw -= mouseDeltaX * gain
	pitch = math.clamp(
		pitch - mouseDeltaY * gain,
		math.rad(flight.MinPitch),
		math.rad(flight.MaxPitch)
	)
	mouseDeltaX, mouseDeltaY = 0, 0

	aimOrientation = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

--[[
	Build this frame's velocity outright. Nothing is integrated except boost
	speed, so there is no state to unwind when input stops.
]]
function FlightController:_move(dt: number): Vector3
	local flight = Config.Flight

	boosting = UserInputService:IsKeyDown(flight.BoostKey)

	if boosting then
		-- Boost: fly where the camera looks, building speed while held.
		boostSpeed = math.min(
			math.max(boostSpeed, flight.CruiseSpeed) + flight.BoostAccel * dt,
			flight.BoostMaxSpeed
		)
		return aimOrientation.LookVector * boostSpeed
	end

	boostSpeed = 0

	--[[
		Cruise: WASD on the camera's horizontal heading, Q/E world-vertical.
		Yaw-only basis, so looking up or down does not tilt ground movement —
		and it keeps W usable when staring at the sky.
	]]
	local heading = CFrame.fromEulerAnglesYXZ(0, yaw, 0)
	local move = heading.LookVector * axis(flight.BackKey, flight.ForwardKey)
		+ heading.RightVector * axis(flight.LeftKey, flight.RightKey)

	local vertical = axis(flight.DownKey, flight.UpKey)

	-- Horizontal and vertical are normalized separately so holding W+Q is not
	-- faster than W alone on the horizontal plane.
	local result = Vector3.zero
	if move.Magnitude > 1e-3 then
		result += move.Unit * flight.CruiseSpeed
	end
	if vertical ~= 0 then
		result += Vector3.yAxis * (vertical * flight.VerticalSpeed)
	end

	-- No input == hard stop. Exactly zero, same frame.
	return result
end

--[[
	Detect slamming something that does NOT break.

	With velocity set directly, measured speed tracks commanded speed closely
	except when a collision steals it. So the test is a SHORTFALL against what we
	asked for, not a frame-over-frame drop: releasing the keys legitimately zeroes
	velocity in one frame and must never read as a crash.
]]
function FlightController:_detectImpact(commandedSpeed: number)
	lastImpactLoss = 0

	if not root then
		return
	end

	local shake = Config.Shake

	-- Only meaningful while we are actually asking to move fast.
	if commandedSpeed < shake.ImpactMinSpeed or lastCommandedSpeed < shake.ImpactMinSpeed then
		lastCommandedSpeed = commandedSpeed
		return
	end

	local measured = root.AssemblyLinearVelocity.Magnitude
	local shortfall = commandedSpeed - measured
	lastCommandedSpeed = commandedSpeed

	if measured >= commandedSpeed * shake.ImpactStallRatio then
		return
	end

	lastImpactLoss = shortfall
	boostSpeed = math.min(boostSpeed, measured)

	if Camera then
		Camera:ShakeImpact(shortfall)
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

	self:_aim()
	velocity = self:_move(dt)
	self:_detectImpact(velocity.Magnitude)

	-- Re-asserted every frame: the PlayerModule resets MouseBehavior on respawn
	-- and on input-mode changes. Skipped while unlocked so the cursor stays free
	-- for the debug panel.
	UserInputService.MouseBehavior = if mouseLocked
		then Enum.MouseBehavior.LockCenter
		else Enum.MouseBehavior.Default

	--[[
		BODY FACING — shift-lock while moving, free look while still.

		Moving in cruise: face the camera's YAW only, like shift lock. Not the
		travel direction: strafing with A/D would otherwise swing the body
		sideways while the camera kept looking forward, which reads as the
		character walking sideways rather than strafing.

		Boosting: face the full aim including pitch, since travel IS the look
		vector and the nose should point down/up into the dive or climb.

		Stationary: do not touch it at all. The camera keeps turning and the body
		stays where it was — free look. Also avoids the craft whipping around to
		a default facing the instant you stop.

		Purely visual either way: body facing never feeds back into movement.
	]]
	local moving = velocity.Magnitude > 1e-3
	if moving then
		local target = if boosting
			then aimOrientation
			else CFrame.fromEulerAnglesYXZ(0, yaw, 0)

		bodyOrientation = bodyOrientation
			:Lerp(target, ease(Config.Flight.BodyTurnResponse, dt))
			:Orthonormalize()
	end

	if linearVelocity then
		-- Re-pushed every frame so the debug panel's slider applies live.
		linearVelocity.MaxForce = Config.Flight.MaxThrustForce
		linearVelocity.VectorVelocity = velocity
	end
	if alignOrientation then
		alignOrientation.CFrame = bodyOrientation
	end
end

--------------------------------------------------------------------------------
-- PUBLIC
--------------------------------------------------------------------------------

function FlightController:IsFlying(): boolean
	return flying
end

-- Camera aim. CameraController builds its CFrame from this, NOT from the body.
function FlightController:GetAimOrientation(): CFrame
	return aimOrientation
end

-- Cosmetic body facing.
function FlightController:GetOrientation(): CFrame
	return bodyOrientation
end

function FlightController:GetVelocity(): Vector3
	return velocity
end

function FlightController:GetSpeed(): number
	return velocity.Magnitude
end

function FlightController:IsBoosting(): boolean
	return boosting
end

function FlightController:GetBoostSpeed(): number
	return boostSpeed
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
	must not be applied to the camera when capture resumes.
]]
function FlightController:SetMouseLocked(locked: boolean)
	mouseLocked = locked
	mouseDeltaX, mouseDeltaY = 0, 0
end

function FlightController:ToggleMouseLock()
	self:SetMouseLocked(not mouseLocked)
end

--[[
	Bleed speed off — called by FlightDestructionController when the craft punches
	through geometry. Only boost speed can be bled: cruise is a fixed set-speed
	with no momentum to lose, so an impact cost there would just fight the input.
]]
function FlightController:ApplySpeedLoss(amount: number)
	boostSpeed = math.max(0, boostSpeed - amount)
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

	-- Runs before the camera's own render step so the camera reads this frame's
	-- aim rather than the previous frame's.
	RunService:BindToRenderStep("FlightController", Enum.RenderPriority.Camera.Value - 1, function(dt)
		self:_update(dt)
	end)
	self._trove:Add(function()
		RunService:UnbindFromRenderStep("FlightController")
	end)
end

return FlightController
