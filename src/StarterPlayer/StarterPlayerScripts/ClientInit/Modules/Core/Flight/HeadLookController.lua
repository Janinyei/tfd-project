--!strict
--[[
	HeadLookController  (client)

	Turns the character's head toward the camera aim. Ported from
	dodgeball-game's MovementController tilt (the Neck half; the R6 torso lean and
	hip counter-rotation are deliberately not carried over).

	ACTIVE ONLY IN Cruising / Stationary. Suppressed while Boosting, because the
	whole body already points down the look vector there and extra neck rotation
	just over-rotates the head. Suppressed while Grounded so the default
	PlayerModule look is untouched.

	Local and cosmetic. Motor6D C0 writes replicate outward automatically from the
	client that owns the character, so other players see the head turn with no
	RemoteEvent plumbing.

	RIG: R6's stock Neck C0 carries a baked axis twist, so its target has to be
	rebuilt from scratch with a correction term. R15's Neck C0 is axis-aligned, so
	the rotation is simply composed onto the default. Both are handled; anything
	else is skipped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local HeadLookController = {}

local Core
local Config
local Flight

local neck: Motor6D? = nil
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

function HeadLookController:_bindCharacter(character: Model)
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
end

function HeadLookController:_update(dt: number)
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
		trySetC0(joint, joint.C0:Lerp(default, ease(Config.Head.Response, dt)))
		return
	end

	local head = Config.Head

	--[[
		Camera aim expressed in body space, then inverse-sine of the local X/Y
		components. Dividing by LookDivisor before asin both keeps the value clear
		of asin's domain edge and makes the head turn subtler than a 1:1 mapping.
	]]
	local rel = root.CFrame:ToObjectSpace(camera.CFrame).LookVector
	local pitch = math.asin(math.clamp(rel.Y / head.LookDivisor, -1, 1))
	local yaw = -math.asin(math.clamp(rel.X / head.LookDivisor, -1, 1))

	pitch = math.clamp(pitch, -math.rad(head.PitchLimit), math.rad(head.PitchLimit))
	yaw = math.clamp(yaw, -math.rad(head.YawLimit), math.rad(head.YawLimit))

	local target
	if isR6 then
		-- Rebuild: translation preserved, rotation replaced, twist re-applied.
		target = CFrame.new(0, neckY, 0) * CFrame.Angles(pitch, yaw, 0) * R6_NECK_CORRECTION
	else
		-- R15: compose onto the default, whose axes already line up with the rig.
		target = default * CFrame.Angles(pitch, yaw, 0)
	end

	trySetC0(joint, joint.C0:Lerp(target, ease(head.Response, dt)))
end

function HeadLookController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function HeadLookController:Start()
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
	end)
end

return HeadLookController
