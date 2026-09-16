--!strict
--[[
	CameraController  (client)

	Chase camera for clamped-pitch hover flight. Structure ported from the
	snowboard project's CameraController: Scriptable + LockCenter re-asserted
	every frame, exp-eased chase distance, raycast pull-in, every constant in
	config.

	The camera simply follows the craft's orientation (yaw + clamped pitch, zero
	roll), smoothed so it lags the nose slightly. No roll blending and no
	near-vertical special case are needed: pitch can never reach +-90, so the
	world-up reference never degenerates.

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

	-- Craft rotation has zero roll and clamped pitch, so it is used directly.
	local targetRotation = Flight:GetOrientation()

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
