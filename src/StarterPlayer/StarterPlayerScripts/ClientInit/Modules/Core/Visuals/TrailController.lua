--!strict
--[[
	TrailController  (client)

	One Trail on every player's HumanoidRootPart, enabled while that player is
	boosting.

	Driven by the replicated "Boosting" attribute rather than by local flight
	state, so this single module covers the local player AND everyone else with
	the same code path — no separate "remote players" handling, and a player who
	joins mid-boost immediately sees the trail.

	Built once per character and left in place; boosting only flips Trail.Enabled
	rather than creating and destroying instances, since churn on a per-boost
	basis would be far more expensive than one idle Trail per player.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Modules.Utils.Trove)

local TrailController = {}

local Core
local Config

-- player -> Trove holding that player's current character rig
local rigs: { [Player]: any } = {}

function TrailController:_buildTrail(character: Model, trove)
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root then
		return
	end

	local trailConfig = Config.Trail
	local halfWidth = trailConfig.Width * 0.5

	-- Two attachments define the trail's width; their separation IS the width.
	local top = Instance.new("Attachment")
	top.Name = "BoostTrailTop"
	top.Position = Vector3.new(0, halfWidth, 0)
	top.Parent = root
	trove:Add(top)

	local bottom = Instance.new("Attachment")
	bottom.Name = "BoostTrailBottom"
	bottom.Position = Vector3.new(0, -halfWidth, 0)
	bottom.Parent = root
	trove:Add(bottom)

	local trail = Instance.new("Trail")
	trail.Name = "BoostTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.WidthScale = trailConfig.WidthScale
	trail.Lifetime = trailConfig.Lifetime
	trail.MinLength = trailConfig.MinLength
	trail.Color = trailConfig.Color
	trail.Transparency = trailConfig.Transparency
	trail.LightEmission = trailConfig.LightEmission
	trail.FaceCamera = true
	trail.Enabled = character:GetAttribute(trailConfig.Attribute) == true
	trail.Parent = root
	trove:Add(trail)

	trove:Connect(character:GetAttributeChangedSignal(trailConfig.Attribute), function()
		trail.Enabled = character:GetAttribute(trailConfig.Attribute) == true
	end)
end

function TrailController:_bindCharacter(player: Player, character: Model)
	local existing = rigs[player]
	if existing then
		existing:Destroy()
	end

	local trove = Trove.new()
	rigs[player] = trove
	-- Torn down with the character, so a respawn cannot leave orphan trails.
	trove:AttachToInstance(character)

	self:_buildTrail(character, trove)
end

function TrailController:_bindPlayer(player: Player)
	if player.Character then
		self:_bindCharacter(player, player.Character)
	end

	self._trove:Connect(player.CharacterAdded, function(character)
		self:_bindCharacter(player, character)
	end)
end

function TrailController:Init(core)
	Core = core
	self._trove = Trove.new()
end

function TrailController:Start()
	Config = Core:Get("FlightConfig")

	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end

	self._trove:Connect(Players.PlayerAdded, function(player)
		self:_bindPlayer(player)
	end)

	self._trove:Connect(Players.PlayerRemoving, function(player)
		local trove = rigs[player]
		if trove then
			trove:Destroy()
			rigs[player] = nil
		end
	end)
end

return TrailController
