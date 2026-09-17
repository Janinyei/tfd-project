--!strict
--[[
	CollisionGroupManager  (server)

	Three groups:
	  Players     — every BasePart of every character
	  VoxelShell  — anchored voxels standing in for the intact remainder of a
	                damaged part. SOLID to players.
	  VoxelDebris — unanchored launched rubble. ALSO solid to players: any
	                non-collidable voxel group is a noclip hole, since the
	                original part stops colliding on first hit.

	The shell/debris split matters because VoxelDestructionService makes the
	original part non-collidable on first hit and hands collision to the shell.
	A single "Voxels" group that players ignored therefore turned every damaged
	wall into a ghost — you would punch one hole and then fly through the whole
	structure. Every voxel therefore collides.

	Both voxel groups collide with Default and each other, so debris piles and
	settles against the map normally.

	Runs in Init, not Start: VoxelDestructionService builds its sim-part template
	at require time and assigns CollisionGroup = "VoxelShell", so the group must
	exist first. Core requires modules sorted by Priority then name, and
	CollisionGroupManager sorts before VoxelDestructionService — but Init is the
	safe place regardless, since every module is required before any Init runs.
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local CollisionGroupManager = {}

local GROUP_DEFAULT = "Default"
local GROUP_PLAYERS = "Players"
-- Anchored voxels standing in for the intact remainder of a damaged part.
local GROUP_VOXEL_SHELL = "VoxelShell"
-- Unanchored launched rubble.
local GROUP_VOXEL_DEBRIS = "VoxelDebris"

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
	ensureGroup(GROUP_VOXEL_SHELL)
	ensureGroup(GROUP_VOXEL_DEBRIS)

	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_DEFAULT, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_PLAYERS, true)

	-- EVERY voxel is solid to players, shell and debris alike. The original part
	-- goes non-collidable on first hit and voxels take over collision, so any
	-- non-collidable voxel group is a hole you can noclip through.
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_VOXEL_SHELL, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_VOXEL_DEBRIS, true)

	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXEL_SHELL, GROUP_DEFAULT, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXEL_SHELL, GROUP_VOXEL_SHELL, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXEL_SHELL, GROUP_VOXEL_DEBRIS, true)

	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXEL_DEBRIS, GROUP_DEFAULT, true)
	PhysicsService:CollisionGroupSetCollidable(GROUP_VOXEL_DEBRIS, GROUP_VOXEL_DEBRIS, true)
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
