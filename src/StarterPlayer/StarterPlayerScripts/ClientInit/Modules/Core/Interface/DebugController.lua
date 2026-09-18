--!strict
--[[
	DebugController  (client)

	Iris panel + runtime gizmos for flight and destruction. Toggle with `9`,
	matching the convention in bachi-battlegrounds' DebugUI and snowboard-comm's
	DebugController.

	LIVE KNOBS (write straight into FlightConfig, which every other module reads
	each frame — no copies, so a slider change is live immediately):
		MaxSpeed        — forward top speed
		MaxThrustForce  — LinearVelocity force cap; the wall-collision feel lever

	Both are client-only state: movement is client-authoritative, so nothing has
	to be told about the change. Destruction tunables are NOT exposed here yet —
	those are re-derived server-side in FlightDestructionService, so exposing them
	needs a Studio-gated packet to mirror the values across. That lands with the
	Tier-3 knobs, not before; a slider that silently does nothing is worse than
	no slider.

	GIZMOS (CeiveImGizmo, vendored at Utils/Gizmo). Immediate-mode: a shape that
	is not redrawn every frame disappears, because the library clears both
	adornments one tick after any draw. So every draw happens in a per-frame loop,
	not on events.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Iris = require(ReplicatedStorage.Modules.Packages.Iris)
local Gizmo = require(ReplicatedStorage.Modules.Utils.Gizmo)
local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local player = Players.LocalPlayer

local DebugController = {}

local Core
local Config
local Flight
local Destruction
local Voxels

-- Latest server voxel census (Net.VoxelCensus). Server-owned truth; the client
-- only knows what it was told to render.
local census = { Shell = 0, Live = 0, Frozen = 0, Capacity = 0 }

DebugController.Enabled = false
DebugController.GizmosEnabled = true

-- Smoothed frame stats. Raw 1/dt jitters far too much to read, so both are
-- exponentially smoothed; FrameSmoothing is the response in Hz.
local FRAME_SMOOTHING = 6
local fps = 0
local frameMs = 0

local TOGGLE_KEY = Enum.KeyCode.Nine

-- Iris.Init() is a one-shot per client. Guarded the same way both other repos
-- guard it, so a second :Start() (hot reload) cannot double-init.
local IRIS_INITIALIZED = false

local COLOR_VELOCITY = Color3.fromRGB(0, 225, 255)
local COLOR_PROBE = Color3.fromRGB(255, 255, 255)
local COLOR_PROBE_SPHERE = Color3.fromRGB(255, 210, 0)
local COLOR_HIT_NORMAL = Color3.fromRGB(60, 255, 90)
local COLOR_CARVE = Color3.fromRGB(255, 60, 60)

-- How long a carve sphere lingers after the request, in seconds.
local CARVE_GIZMO_LINGER = 0.5

local SPHERE_SUBDIVISIONS = 12
local ARROW_RADIUS = 1.2
local ARROW_LENGTH = 3

--------------------------------------------------------------------------------
-- FORMATTING
--------------------------------------------------------------------------------

local function fmt(value: any): string
	local valueType = typeof(value)
	if valueType == "number" then
		return string.format("%.2f", value)
	elseif valueType == "Vector3" then
		return string.format("%.1f, %.1f, %.1f", value.X, value.Y, value.Z)
	elseif valueType == "boolean" then
		return value and "true" or "false"
	elseif value == nil then
		return "nil"
	end
	return tostring(value)
end

local function line(label: string, value: any)
	Iris.Text({ label .. ": " .. fmt(value) })
end

--------------------------------------------------------------------------------
-- GIZMOS
--------------------------------------------------------------------------------

function DebugController:_drawGizmos()
	local root = Flight:GetRoot()
	if not root or not root.Parent or not Flight:IsFlying() then
		return
	end

	local origin = root.Position

	-- Velocity arrow: the TRAVEL vector, not the nose. Divergence between this
	-- and the craft's facing is exactly what strafe/hover thrust produces.
	local velocity = Flight:GetVelocity()
	if velocity.Magnitude > 1 then
		Gizmo.PushProperty("Color3", COLOR_VELOCITY)
		Gizmo.Arrow:Draw(
			origin,
			origin + velocity * 0.15,
			ARROW_RADIUS,
			ARROW_LENGTH,
			SPHERE_SUBDIVISIONS
		)
	end

	local probe = Destruction:GetProbeDebug()

	if probe.Active then
		-- The spherecast segment. If holes keep arriving late, this line is too
		-- short relative to travel — raise LeadFactor.
		local probeEnd = probe.Origin + probe.Direction * probe.Lead
		Gizmo.PushProperty("Color3", COLOR_PROBE)
		Gizmo.Ray:Draw(probe.Origin, probeEnd)

		Gizmo.PushProperty("Color3", COLOR_PROBE_SPHERE)
		Gizmo.Sphere:Draw(CFrame.new(probeEnd), probe.ProbeRadius, SPHERE_SUBDIVISIONS, 360)

		if probe.HitPosition and probe.HitNormal then
			Gizmo.PushProperty("Color3", COLOR_HIT_NORMAL)
			Gizmo.Ray:Draw(probe.HitPosition, probe.HitPosition + probe.HitNormal * 6)
		end
	end

	-- Carve footprint, lingering briefly so a single hit is actually visible.
	if probe.CarvePosition and (os.clock() - probe.CarveClock) <= CARVE_GIZMO_LINGER then
		Gizmo.PushProperty("Color3", COLOR_CARVE)
		Gizmo.Sphere:Draw(
			CFrame.new(probe.CarvePosition),
			probe.CarveRadius,
			SPHERE_SUBDIVISIONS,
			360
		)
	end
end

--------------------------------------------------------------------------------
-- PANEL
--------------------------------------------------------------------------------

function DebugController:_render()
	local flight = Config.Flight

	Iris.SetNextWidgetID("TFDDebugWindow")
	Iris.Window({ "Total Flight Destruction  [9]", [Iris.Args.Window.NoClose] = true }, {
		size = Iris.State(Vector2.new(380, 520)),
		position = Iris.State(Vector2.new(20, 20)),
	})

	Iris.SeparatorText({ "Performance" })
	line("FPS", fps)
	line("Frame (ms)", frameMs)
	line("Ping (ms)", player:GetNetworkPing() * 1000)

	Iris.SeparatorText({ "Knobs" })

	-- Iris states persist per widget across frames, so the slider keeps the value
	-- the user set; the config is then written from it every frame.
	local boostSpeedState = Iris.State(flight.BoostMaxSpeed)
	Iris.SliderNum({ "BoostMaxSpeed", 10, 100, 1600 }, { number = boostSpeedState })
	flight.BoostMaxSpeed = boostSpeedState:get()

	local cruiseSpeedState = Iris.State(flight.CruiseSpeed)
	Iris.SliderNum({ "CruiseSpeed", 5, 20, 600 }, { number = cruiseSpeedState })
	flight.CruiseSpeed = cruiseSpeedState:get()

	local thrustState = Iris.State(flight.MaxThrustForce)
	Iris.SliderNum({ "MaxThrustForce", 1000, 5000, 300000 }, { number = thrustState })
	flight.MaxThrustForce = thrustState:get()

	local gizmoState = Iris.State(self.GizmosEnabled)
	Iris.Checkbox({ "Gizmos" }, { isChecked = gizmoState })
	self.GizmosEnabled = gizmoState:get()

	local shakeState = Iris.State(Config.Shake.Enabled)
	Iris.Checkbox({ "Camera shake" }, { isChecked = shakeState })
	Config.Shake.Enabled = shakeState:get()

	Iris.SeparatorText({ "Flight" })
	line("State", Flight:GetState())
	line("Flying", Flight:IsFlying())
	line("Mouse captured [8]", Flight:IsMouseLocked())
	line("Boosting [Shift]", Flight:IsBoosting())
	local velocity = Flight:GetVelocity()
	line("Travel speed", velocity.Magnitude)
	line("Boost speed", Flight:GetBoostSpeed())
	line("Velocity", velocity)
	line("Impact loss (this frame)", Flight:GetLastImpactLoss())

	local aimPitch, aimYaw = Flight:GetAimOrientation():ToEulerAnglesYXZ()
	line("Aim pitch (deg)", math.deg(aimPitch))
	line("Aim yaw (deg)", math.deg(aimYaw))
	line("Pitch limit (deg)", flight.MaxPitch)

	Iris.SeparatorText({ "Destruction" })
	local probe = Destruction:GetProbeDebug()
	line("Probing", probe.Active)
	line("Over speed gate", velocity.Magnitude >= Config.Destruction.MinCarveSpeed)
	line("Speed gate", Config.Destruction.MinCarveSpeed)
	line("Lead distance", probe.Lead)
	line("Probe radius", probe.ProbeRadius)
	line("Hit", probe.HitPosition)
	line("Carves requested", probe.CarveCount)
	line("Voxels destroyed (last)", probe.LastDestroyed)
	line("Voxels destroyed (total)", probe.TotalDestroyed)
	line("Carves rejected/empty", probe.RejectedCount)
	line("Last carve radius", probe.CarveRadius)
	line("Carve radius @ travel", Config.GetCarveRadius(velocity.Magnitude))
	line("Voxel size @ travel", Config.GetMinVoxelSize(velocity.Magnitude))

	Iris.SeparatorText({ "Voxels (server)" })
	local serverTotal = census.Shell + census.Live + census.Frozen
	line("Static shell", census.Shell)
	line("Debris (live)", census.Live)
	line("Debris (frozen)", census.Frozen)
	line("Total", serverTotal)
	line("Pool capacity", census.Capacity)
	line(
		"Pool used",
		census.Capacity > 0
			and string.format("%.1f%%", serverTotal / census.Capacity * 100)
			or "n/a"
	)

	Iris.SeparatorText({ "Voxels (this client)" })
	local clientDynamic, clientStatic = Voxels:GetCensus()
	line("Dynamic", clientDynamic)
	line("Static", clientStatic)
	line("Total", clientDynamic + clientStatic)

	Iris.End()
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function DebugController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function DebugController:Start()
	Config = Core:Get("FlightConfig")
	Flight = Core:Get("FlightController")
	Destruction = Core:Get("FlightDestructionController")
	Voxels = Core:Get("VoxelDestructionController")

	local Net = Core:Get("Net")
	self._trove:Add(Net.VoxelCensus.OnClientEvent:Connect(function(shell, live, frozen, capacity)
		census.Shell = shell
		census.Live = live
		census.Frozen = frozen
		census.Capacity = capacity
	end))

	if not IRIS_INITIALIZED then
		Iris.Init()
		IRIS_INITIALIZED = true
	end

	Iris.UpdateGlobalConfig({
		WindowBgTransparency = 0.25,
		TitleBgActiveTransparency = 0,
	})

	local disconnectIris = Iris:Connect(function()
		if self.Enabled then
			self:_render()
		end
	end)
	self._trove:Add(disconnectIris)

	-- Gizmo owns its own RenderStepped upkeep loop; Init starts it.
	Gizmo.Init()
	Gizmo.SetEnabled(false)

	self._trove:Connect(UserInputService.InputBegan, function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			self.Enabled = not self.Enabled
		end
	end)

	-- Drawn on RenderStepped, i.e. after the PostSimulation pass that ran the
	-- probe, so the gizmos are at most one frame behind the cast. Hooking
	-- PostSimulation here instead would be worse, not better: connection order
	-- within one signal follows Core's module load order (DebugController sorts
	-- before FlightDestructionController), so this handler would run BEFORE the
	-- probe updated and always show stale data.
	self._trove:Connect(RunService.RenderStepped, function(dt)
		-- Sampled unconditionally: the numbers must already be settled when the
		-- panel is opened, and measuring only while it is open would also hide
		-- the cost of the panel itself.
		if dt > 0 then
			local alpha = 1 - math.exp(-FRAME_SMOOTHING * dt)
			fps += (1 / dt - fps) * alpha
			frameMs += (dt * 1000 - frameMs) * alpha
		end

		local drawing = self.Enabled and self.GizmosEnabled
		if Gizmo.Enabled ~= drawing then
			Gizmo.SetEnabled(drawing)
		end
		if drawing then
			self:_drawGizmos()
		end
	end)
end

return DebugController
