--!strict
--[[
	CollisionGroupManager  (server)

	Two groups only:
	  Players — every BasePart of every character
	  Voxels  — every voxel sim part spawned by VoxelDestructionService

	Players <-> Voxels is DISABLED: neither the static shell that replaces a
	damaged part nor the flying debris can body-block a player. Voxels still
	collide with Default (map geometry) and with each other, so rubble piles and
	settles normally.

	Consequence worth knowing: once a part has been hit, the original is made
	non-collidable and its shell takes over — so a damaged wall stops blocking
	players entirely, while UNTOUCHED geometry (plain Default parts) still blocks
	them. Intact = solid, damaged = fly-through.

	Runs in Init, not Start: VoxelDestructionService builds its sim-part template
	at require time and assigns CollisionGroup = "Voxels", so the group must exist
	first. Core requires modules sorted by Priority then name, and
	CollisionGroupManager sorts before VoxelDestructionService — but Init is the
	safe place regardless, since every module is required before any Init runs.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local CollisionGroupManager = {}

local GROUP_DEFAULT = "Default"
local GROUP_PLAYERS = "Players"
local GROUP_VOXELS = "Voxels"

local function ensureGroup(name: string)
	for _, group in PhysicsService:GetRegisteredCollisionGroups() do
		if group.name == name then
			return
		end
	end
	PhysicsService:RegisterCollisionGroup(name)
end

function CollisionGroupManager:_setupGroups()
	ensureGroup(GROUP_PLAYERS)
	ensureGroup(GROUP_VOXELS)

	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_DEFAULT, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_PLAYERS, true)

	-- The whole point of this module.
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_VOXELS, false)

	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXELS, GROUP_DEFAULT, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXELS, GROUP_VOXELS, true)
end

function CollisionGroupManager:SetCharacterGroup(character: Model)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = GROUP_PLAYERS
		end
	end
end

function CollisionGroupManager:_bindCharacter(character: Model)
	self:SetCharacterGroup(character)

	-- Accessories, tools and R15 limb swaps arrive after the character does.
	character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = GROUP_PLAYERS
		end
	end)
end

function CollisionGroupManager:_bindPlayer(player: Player)
	if player.Character then
		self:_bindCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
end

function CollisionGroupManager:Init(_core)
	self:_setupGroups()
end

function CollisionGroupManager:Start()
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
end

return CollisionGroupManager
