--!strict
--[[
	FlightController  (client)

	Omnidirectional 6DOF character flight.

	GIMBAL LOCK: orientation is stored as a CFrame rotation and integrated with
	body-relative deltas — never as (pitch, yaw, roll) rebuilt through
	CFrame.Angles. Euler STORAGE is what produces gimbal lock; rotation
	composition has no singularity. :Orthonormalize() each frame kills float drift.

	Movement is client-authoritative (network ownership of the HumanoidRootPart).
	Anything else feels unusable at 400+ studs/s.

	Public API (read by CameraController and FlightDestructionController):
		:IsFlying()      -> boolean
		:GetOrientation()-> CFrame   (rotation only)
		:GetSpeed()      -> number
		:GetRoot()       -> BasePart?
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

-- Live state
local flying = false
local orientation = CFrame.identity -- rotation only
local speed = 0

-- Smoothed angular rates (rad/s)
local pitchRate, yawRate, rollRate = 0, 0, 0
-- Mouse delta accumulated since last frame
local mouseDeltaX, mouseDeltaY = 0, 0

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

	-- Velocity is SET, not integrated from forces: no fighting gravity, no
	-- accumulated error, and the physics engine still owns collisions.
	local lv = Instance.new("LinearVelocity")
	lv.Name = "FlightVelocity"
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitsEnabled = false
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
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

	orientation = root.CFrame.Rotation
	speed = math.max(Config.Flight.BaseSpeed, root.AssemblyLinearVelocity.Magnitude)
	pitchRate, yawRate, rollRate = 0, 0, 0
	mouseDeltaX, mouseDeltaY = 0, 0

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

function FlightController:_readSteering(dt: number)
	local flight = Config.Flight

	-- Mouse steers the craft (the camera only follows). Pixel delta is normalized
	-- against MouseFullDeflection = the delta that counts as full stick, so the
	-- result is a clean [-1, 1] stick value regardless of DPI.
	-- Mouse right (+X) yaws right, which is NEGATIVE rotation about +Y.
	-- Mouse up (-Y) pitches up, which is POSITIVE rotation about +X.
	local gain = flight.MouseGain * UserInputService.MouseDeltaSensitivity / flight.MouseFullDeflection

	local yawInput = math.clamp(-mouseDeltaX * gain, -1, 1)
	local pitchInput = math.clamp(-mouseDeltaY * gain, -1, 1)
	mouseDeltaX, mouseDeltaY = 0, 0

	-- A rolls left, D rolls right.
	local rollInput = axis(flight.RollRightKey, flight.RollLeftKey)

	local targetPitch = pitchInput * flight.PitchRate
	local targetYaw = yawInput * flight.YawRate
	local targetRoll = rollInput * flight.RollRate

	local alpha = ease(flight.RateResponse, dt)
	pitchRate += (targetPitch - pitchRate) * alpha
	yawRate += (targetYaw - yawRate) * alpha
	rollRate += (targetRoll - rollRate) * alpha
end

function FlightController:_integrateOrientation(dt: number)
	-- Body-relative composition: no Euler state, therefore no gimbal lock.
	local delta = CFrame.fromAxisAngle(Vector3.xAxis, pitchRate * dt)
		* CFrame.fromAxisAngle(Vector3.yAxis, yawRate * dt)
		* CFrame.fromAxisAngle(Vector3.zAxis, rollRate * dt)

	orientation = (orientation * delta):Orthonormalize()

	-- Auto-level: slerp toward the current heading flattened to the horizon.
	-- CFrame:Lerp slerps the rotation component, so this is singularity-free too.
	if UserInputService:IsKeyDown(Config.Flight.AutoLevelKey) then
		local look = orientation.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 1e-3 then
			local level = CFrame.lookAt(Vector3.zero, flat.Unit).Rotation
			orientation = orientation:Lerp(level, ease(Config.Flight.AutoLevelRate, dt)):Orthonormalize()
		end
	end
end

function FlightController:_integrateSpeed(dt: number)
	local flight = Config.Flight

	local boosting = UserInputService:IsKeyDown(flight.BoostKey)
	local braking = UserInputService:IsKeyDown(flight.BrakeKey)
	local throttle = axis(flight.ThrottleDownKey, flight.ThrottleUpKey)

	local maxSpeed = boosting and flight.BoostMaxSpeed or flight.MaxSpeed

	if throttle > 0 then
		local accel = flight.ThrottleAccel * (boosting and flight.BoostAccelMultiplier or 1)
		speed += accel * dt
	elseif throttle < 0 then
		speed -= flight.ThrottleDecel * dt
	end

	if braking then
		speed -= flight.BrakeDecel * dt
	end

	-- Passive drag, proportional to speed.
	speed -= speed * flight.Drag * dt

	speed = math.clamp(speed, flight.MinSpeed, maxSpeed)
end

function FlightController:_update(dt: number)
	if not flying then
		return
	end
	if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then
		self:StopFlight()
		return
	end

	self:_readSteering(dt)
	self:_integrateOrientation(dt)
	self:_integrateSpeed(dt)

	-- Mouse stays locked to screen centre while flying. Re-asserted every frame:
	-- the PlayerModule resets MouseBehavior on respawn and on input-mode changes.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	if linearVelocity then
		linearVelocity.VectorVelocity = orientation.LookVector * speed
	end
	if alignOrientation then
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
	return speed
end

function FlightController:GetRoot(): BasePart?
	return root
end

--[[
	Bleed speed off — called by FlightDestructionController when the craft
	punches through geometry. Client-authoritative movement means the client
	applies its own impact cost; the server only owns the destruction.
]]
function FlightController:ApplySpeedLoss(amount: number)
	speed = math.max(Config.Flight.MinSpeed, speed - amount)
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
		end
	end)

	self._trove:Connect(UserInputService.InputChanged, function(input, processed)
		if processed or not flying then
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
