--!strict
--[[
	TiltController  (client)

	Cosmetic body tilt, two effects, both on Motor6D joints so neither fights the
	AlignOrientation that FlightController uses to steer the body:

	  HEAD LOOK  — the Neck turns toward the camera aim. Ported from
	               dodgeball-game's MovementController tilt.
	  BANK       — the Torso rolls into turns, proportional to how fast the aim
	               is yawing, so hard turns visibly lean.

	Head look is active only while Cruising or Stationary (during a boost the
	whole body already points down the look vector). Banking runs in every flying
	state, because leaning into a turn reads best exactly when you are fastest.

	Local and cosmetic: Motor6D C0 writes replicate automatically from the client
	that owns the character, so other players see both effects with no remotes.

	RIG: R6's Neck C0 carries a baked axis twist and needs a correction term;
	R15's is axis-aligned. Both handled. The BANK is rig-agnostic because it
	LEFT-multiplies the roll onto RootJoint.C0, which applies the rotation in the
	HumanoidRootPart's frame rather than the joint's own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local TiltController = {}

local Core
local Config
local Flight

local neck: Motor6D? = nil
local rootJoint: Motor6D? = nil
local defaultRootC0: CFrame? = nil
local bankAngle = 0
local defaultNeckC0: CFrame? = nil
local neckY = 0
local isR6 = false

-- R6's neck frame is rotated 270 deg about X and 180 about Z relative to the
-- torso, so a rebuilt C0 has to re-apply that or the head points sideways.
local R6_NECK_CORRECTION = CFrame.Angles(math.pi * 1.5, 0, math.pi)

local function ease(response: number, dt: number): number
	return 1 - math.exp(-response * dt)
end

--[[
	Right after a (re)spawn the character's joints are still server-owned, so C0
	is briefly read-only on the client. Swallow that transient write rather than
	spamming the log.
]]
local function trySetC0(joint: Motor6D, cframe: CFrame)
	pcall(function()
		joint.C0 = cframe
	end)
end

function TiltController:_bindCharacter(character: Model)
	neck = nil
	defaultNeckC0 = nil

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	isR6 = humanoid.RigType == Enum.HumanoidRigType.R6

	-- R6 keeps Neck under Torso; R15 keeps it under UpperTorso.
	local neckParent = if isR6
		then character:FindFirstChild("Torso")
		else character:FindFirstChild("UpperTorso")
	if not neckParent then
		return
	end

	local joint = neckParent:FindFirstChild("Neck")
	if not joint or not joint:IsA("Motor6D") then
		return
	end

	neck = joint
	defaultNeckC0 = joint.C0
	neckY = joint.C0.Y

	-- Both rigs put RootJoint on the HumanoidRootPart (HRP -> Torso on R6,
	-- HRP -> LowerTorso on R15).
	local root = character:FindFirstChild("HumanoidRootPart")
	local rj = root and root:FindFirstChild("RootJoint")
	if rj and rj:IsA("Motor6D") then
		rootJoint = rj
		defaultRootC0 = rj.C0
		bankAngle = 0
	end
end

--[[
	Roll the torso into turns.

	Target roll is proportional to the aim's yaw rate: turning left yaws
	positively and rolls positively, which lifts the right side — a lean into
	the turn. Clamped so a flick of the mouse cannot invert the character.

	LEFT-multiplied onto the default C0 so the roll happens about the
	HumanoidRootPart's Z axis. Right-multiplying would apply it in the joint's
	own frame, which on R6 is rotated 90 degrees and would pitch instead of roll.
]]
function TiltController:_updateBank(dt: number)
	local joint = rootJoint
	local default = defaultRootC0
	if not joint or not default or not joint.Parent then
		return
	end

	local tilt = Config.Tilt
	local target = 0

	if Flight:IsFlying() then
		target = math.clamp(
			Flight:GetYawRate() * tilt.BankPerYawRate,
			-math.rad(tilt.BankLimit),
			math.rad(tilt.BankLimit)
		)
	end

	bankAngle += (target - bankAngle) * ease(tilt.BankResponse, dt)
	trySetC0(joint, CFrame.Angles(0, 0, bankAngle) * default)
end

function TiltController:_update(dt: number)
	local joint = neck
	local default = defaultNeckC0
	if not joint or not default or not joint.Parent then
		return
	end

	local camera = workspace.CurrentCamera
	local root = Flight:GetRoot()
	if not camera or not root or not root.Parent then
		return
	end

	local States = Flight.States
	local state = Flight:GetState()
	local active = state == States.Cruising or state == States.Stationary

	-- Inactive: ease back to the rig's default pose rather than snapping, so
	-- entering a boost does not jerk the head straight.
	if not active then
		trySetC0(joint, joint.C0:Lerp(default, ease(Config.Tilt.HeadResponse, dt)))
		return
	end

	local tilt = Config.Tilt

	--[[
		Camera aim expressed in body space, then inverse-sine of the local X/Y
		components. Dividing by LookDivisor before asin both keeps the value clear
		of asin's domain edge and makes the head turn subtler than a 1:1 mapping.
	]]
	local rel = root.CFrame:ToObjectSpace(camera.CFrame).LookVector
	local pitch = math.asin(math.clamp(rel.Y / tilt.LookDivisor, -1, 1))
	local yaw = -math.asin(math.clamp(rel.X / tilt.LookDivisor, -1, 1))

	pitch = math.clamp(pitch, -math.rad(tilt.PitchLimit), math.rad(tilt.PitchLimit))
	yaw = math.clamp(yaw, -math.rad(tilt.YawLimit), math.rad(tilt.YawLimit))

	local target
	if isR6 then
		-- Rebuild: translation preserved, rotation replaced, twist re-applied.
		target = CFrame.new(0, neckY, 0) * CFrame.Angles(pitch, yaw, 0) * R6_NECK_CORRECTION
	else
		-- R15: compose onto the default, whose axes already line up with the rig.
		target = default * CFrame.Angles(pitch, yaw, 0)
	end

	trySetC0(joint, joint.C0:Lerp(target, ease(tilt.HeadResponse, dt)))
end

function TiltController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function TiltController:Start()
	Config = Core:Get("FlightConfig")
	Flight = Core:Get("FlightController")

	if player.Character then
		self:_bindCharacter(player.Character)
	end
	self._trove:Connect(player.CharacterAdded, function(character)
		self:_bindCharacter(character)
	end)

	-- After FlightController's render step, so the aim being followed is this
	-- frame's rather than the previous frame's.
	self._trove:Connect(RunService.RenderStepped, function(dt)
		self:_update(dt)
		self:_updateBank(dt)
	end)
end

return TiltController
