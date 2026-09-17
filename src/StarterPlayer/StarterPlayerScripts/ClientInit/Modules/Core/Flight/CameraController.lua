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
local CameraShaker = require(ReplicatedStorage.Modules.Utils.CameraShaker)

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
--[[
	The point the camera frames. Chases the character rather than being pinned to
	it, which is what produces the dragging/trailing feel while cruising.
]]
local smoothedFocus = Vector3.zero
local initialized = false

-- Shake is accumulated by CameraShaker on its own render step (Camera + 1) and
-- multiplied into the camera CFrame here, exactly as in bachi-battlegrounds.
local shakeCFrame = CFrame.identity
-- Single sustained instance whose Magnitude is re-driven from speed each frame.
local rumble = nil

local function ease(response: number, dt: number): number
	return 1 - math.exp(-response * dt)
end

--[[
	Sustained rumble tracking travel speed. One instance lives forever with its
	Magnitude re-driven each frame — cheaper and smoother than starting/stopping
	shakes as you cross the speed threshold, which would audibly re-attack.
]]
function CameraController:_updateRumble(travelSpeed: number)
	if not rumble then
		return
	end
	local shake = Config.Shake
	local span = math.max(shake.RumbleMaxSpeed - shake.RumbleMinSpeed, 1)
	local alpha = math.clamp((travelSpeed - shake.RumbleMinSpeed) / span, 0, 1)
	rumble.Magnitude = shake.RumbleMaxMagnitude * alpha
	rumble.Roughness = shake.RumbleRoughness
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
		if rumble then
			rumble.Magnitude = 0
		end
		return
	end

	local cam = Config.Camera

	-- Re-asserted every frame: the PlayerModule resets CameraType on respawn and
	-- on input-mode changes, and silently steals the camera back if we don't.
	camera.CameraType = Enum.CameraType.Scriptable
	-- Cursor is hidden only while the mouse is captured; with capture released
	-- (key 8) it must be visible to aim at the debug panel.
	UserInputService.MouseIconEnabled = not Flight:IsMouseLocked()

	-- The camera IS the aim: mouse drives this directly, and movement follows it.
	-- Deliberately not the body facing, which only chases travel direction.
	local targetRotation = Flight:GetAimOrientation()

	if not initialized then
		initialized = true
		smoothedRotation = targetRotation
		smoothedFocus = root.Position
		currentDistance = cam.Distance
		currentFov = cam.BaseFov
	end

	smoothedRotation = smoothedRotation
		:Lerp(targetRotation, ease(cam.OrientationResponse, dt))
		:Orthonormalize()

	local speed = Flight:GetSpeed()
	local boosting = Flight:IsBoosting()
	self:_updateRumble(Flight:GetVelocity().Magnitude)

	--[[
		Chase distance only stretches while BOOSTING. Cruise speed is a fixed
		set-speed, so scaling distance with it just parked the camera at a
		constant wider distance and wasted the effect; reserving it for boost
		makes the pull-back read as "this is fast" instead of being the default
		framing.
	]]
	local targetDistance = if boosting
		then math.min(cam.Distance + speed * cam.DistanceSpeedScale, cam.MaxDistance)
		else cam.Distance
	currentDistance += (targetDistance - currentDistance) * ease(cam.DistanceResponse, dt)

	-- FOV opens with speed for a sense of velocity.
	local fovAlpha = math.clamp(speed / cam.FovSpeedReference, 0, 1)
	local targetFov = cam.BaseFov + (cam.MaxFov - cam.BaseFov) * fovAlpha
	currentFov += (targetFov - currentFov) * ease(cam.FovResponse, dt)
	camera.FieldOfView = currentFov

	--[[
		DRAGGING FOLLOW. The focus point eases toward the character instead of
		being locked to it, so the camera trails during cruise and catches up when
		you settle — the craft leads, the camera follows.

		Boost uses a much stiffer response: at 700 studs/s a lagging focus would
		leave the craft drifting toward the edge of frame, or off it entirely.
	]]
	local followResponse = if boosting then cam.BoostFollowResponse else cam.FollowResponse
	smoothedFocus = smoothedFocus:Lerp(root.Position, ease(followResponse, dt))

	-- Focus slightly ahead of the craft so the crosshair area stays centered.
	local focus = smoothedFocus + smoothedRotation.LookVector * cam.FocusForward

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

	-- Shake is the LAST factor, applied in camera-local space so a rattle never
	-- moves the focus point or fights the collision pull-in above.
	camera.CFrame = CFrame.new(focus + offset) * smoothedRotation * shakeCFrame
end

--------------------------------------------------------------------------------
-- PUBLIC
--------------------------------------------------------------------------------

--[[
	One-shot shake. fadeOut must be > 0: ShakeOnce with a zero fade-out never
	reaches the Inactive state and the instance is never collected.
]]
function CameraController:Shake(magnitude: number, roughness: number, fadeIn: number, fadeOut: number)
	if not self.Shaker then
		return
	end
	self.Shaker:ShakeOnce(magnitude, roughness, fadeIn, math.max(fadeOut, 0.01))
end

-- Carving through geometry: magnitude scales with the hole punched AND the speed
-- it was punched at. Carve radius saturates at CarveRadiusMax, so radius alone
-- would make every high-speed hit feel identical.
function CameraController:ShakeCarve(carveRadius: number, impactSpeed: number)
	local shake = Config.Shake
	local magnitude = math.min(
		shake.CarveBase + carveRadius * shake.CarvePerRadius + impactSpeed * shake.CarvePerSpeed,
		shake.CarveMax
	)
	self:Shake(magnitude, shake.CarveRoughness, shake.CarveFadeIn, shake.CarveFadeOut)
end

-- Hitting something that does not break: magnitude scales with speed lost.
function CameraController:ShakeImpact(speedLost: number)
	local shake = Config.Shake
	local magnitude = math.min(speedLost * shake.ImpactPerSpeedLoss, shake.ImpactMax)
	self:Shake(magnitude, shake.ImpactRoughness, shake.ImpactFadeIn, shake.ImpactFadeOut)
end

function CameraController:Init(core)
	Core = core
	self._trove = Trove.new()

	-- Camera + 1: the shaker's own render step runs AFTER this module writes the
	-- base CFrame, so the offset it produces is consumed on the next frame.
	-- Storing it rather than writing camera.CFrame from the callback keeps a
	-- single owner of the final CFrame.
	self.Shaker = CameraShaker.new(Enum.RenderPriority.Camera.Value + 1, function(offset)
		shakeCFrame = offset
	end)
end

function CameraController:Start()
	Config = Core:Get("FlightConfig")
	Flight = Core:Get("FlightController")

	self.Shaker:Start()
	self._trove:Add(function()
		self.Shaker:Stop()
	end)

	-- Sustained, never removed: DeleteOnInactive would collect it the moment
	-- magnitude reached zero at low speed, and it would have to be recreated.
	rumble = self.Shaker:StartShake(0, Config.Shake.RumbleRoughness, Config.Shake.RumbleFadeIn)
	rumble.DeleteOnInactive = false

	RunService:BindToRenderStep("FlightCamera", Enum.RenderPriority.Camera.Value, function(dt)
		self:_update(dt)
	end)
	self._trove:Add(function()
		RunService:UnbindFromRenderStep("FlightCamera")
	end)
end

return CameraController
