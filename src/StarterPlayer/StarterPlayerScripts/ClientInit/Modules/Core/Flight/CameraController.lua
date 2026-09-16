--!strict
--[[
	CameraController  (client)

	Chase camera for 6DOF flight. Structure ported from the snowboard project's
	CameraController: Scriptable + LockCenter re-asserted every frame,
	exp-eased chase distance, raycast pull-in, every constant in config.

	What CHANGED for omnidirectional flight: the snowboard camera built its CFrame
	from fromEulerAnglesYXZ(pitch, yaw, 0) against an implicit world-up. That
	flips and degenerates the moment you fly vertically or inverted. Here the
	camera is derived from the craft's own orientation CFrame, with the roll
	component blended by Config.Camera.RollFollow:

		1 = cockpit-true (horizon rolls with you — honest, more disorienting)
		0 = world-up stabilized (horizon stays level — readable, lies about roll)

	Mouse input belongs to FlightController (it steers the craft). This module
	only reads state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local CameraController = {}

local Core
local Config
local Flight

local currentDistance = 0
local currentFov = 0
-- Smoothed camera rotation, so the camera lags the craft slightly instead of
-- being welded to it.
local smoothedRotation = CFrame.identity
local initialized = false

local function ease(response: number, dt: number): number
	return 1 - math.exp(-response * dt)
end

--[[
	Blend the craft's roll out of its orientation.

	weight = 1 -> craft rotation untouched.
	weight < 1 -> rebuild the rotation from the craft's LookVector with an up
	vector slerped between the craft's own up and world up. Falls back to the
	craft's up when looking straight up/down, where world up gives no usable
	right vector.
]]
local function applyRollFollow(rotation: CFrame, weight: number): CFrame
	if weight >= 0.999 then
		return rotation
	end

	local look = rotation.LookVector
	local craftUp = rotation.UpVector

	-- Degenerate when flying near-vertically: world up is parallel to look.
	local worldUp = Vector3.yAxis
	if math.abs(look:Dot(worldUp)) > 0.985 then
		return rotation
	end

	local blendedUp = craftUp:Lerp(worldUp, 1 - weight)
	if blendedUp.Magnitude < 1e-3 then
		return rotation
	end

	return CFrame.lookAt(Vector3.zero, look, blendedUp.Unit).Rotation
end

function CameraController:_update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local root = Flight:GetRoot()
	if not root or not root.Parent then
		return
	end

	if not Flight:IsFlying() then
		-- Hand the camera back to the default PlayerModule when not flying.
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
			camera.FieldOfView = Config.Camera.BaseFov
			UserInputService.MouseIconEnabled = true
			initialized = false
		end
		return
	end

	local cam = Config.Camera

	-- Re-asserted every frame: the PlayerModule resets CameraType on respawn and
	-- on input-mode changes, and silently steals the camera back if we don't.
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseIconEnabled = false

	local craftRotation = Flight:GetOrientation()
	local targetRotation = applyRollFollow(craftRotation, cam.RollFollow)

	if not initialized then
		initialized = true
		smoothedRotation = targetRotation
		currentDistance = cam.Distance
		currentFov = cam.BaseFov
	end

	smoothedRotation = smoothedRotation
		:Lerp(targetRotation, ease(cam.OrientationResponse, dt))
		:Orthonormalize()

	local speed = Flight:GetSpeed()

	-- Chase distance grows with speed, eased.
	local targetDistance = math.min(cam.Distance + speed * cam.DistanceSpeedScale, cam.MaxDistance)
	currentDistance += (targetDistance - currentDistance) * ease(cam.DistanceResponse, dt)

	-- FOV opens with speed for a sense of velocity.
	local fovAlpha = math.clamp(speed / cam.FovSpeedReference, 0, 1)
	local targetFov = cam.BaseFov + (cam.MaxFov - cam.BaseFov) * fovAlpha
	currentFov += (targetFov - currentFov) * ease(cam.FovResponse, dt)
	camera.FieldOfView = currentFov

	-- Focus slightly ahead of the craft so the crosshair area stays centered.
	local focus = root.Position + smoothedRotation.LookVector * cam.FocusForward

	local offset = smoothedRotation:VectorToWorldSpace(Vector3.new(0, cam.Height, currentDistance))

	-- Pull in when geometry is between camera and craft.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { player.Character :: any }
	rayParams.RespectCanCollide = true

	local hit = workspace:Raycast(focus, offset, rayParams)
	if hit then
		local distanceToHit = (hit.Position - focus).Magnitude
		local shortened = math.max(distanceToHit - cam.CollisionPadding, 0)
		if offset.Magnitude > 1e-3 then
			offset = offset.Unit * shortened
		end
	end

	camera.CFrame = CFrame.new(focus + offset) * smoothedRotation
end

function CameraController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function CameraController:Start()
	Config = Core:Get("FlightConfig")
	Flight = Core:Get("FlightController")

	RunService:BindToRenderStep("FlightCamera", Enum.RenderPriority.Camera.Value, function(dt)
		self:_update(dt)
	end)
	self._trove:Add(function()
		RunService:UnbindFromRenderStep("FlightCamera")
	end)
end

return CameraController
