--!strict
--[[
	StatsService  (server)

	Player leaderstats. Currently one stat: how many voxels the player has
	knocked out of the world.

	Leaderstats are a Roblox convention rather than an API: a Folder named
	exactly "leaderstats" parented to the Player, holding ValueBase children whose
	Name is the column header and whose Value is the displayed number. Anything
	else is ignored by the player list.

	Session-only. Nothing is persisted yet — a DataStore/ProfileStore layer would
	hook :Add and the PlayerAdded path, and until that exists a counter that
	silently reset would be worse than one that is honestly per-session.
]]

local Players = game:GetService("Players")

local StatsService = {}

local Core

local LEADERSTATS_FOLDER = "leaderstats"
local VOXELS_DESTROYED = "Voxels Destroyed"

-- player -> { [statName]: IntValue }
local stats: { [Player]: { [string]: IntValue } } = {}

function StatsService:_buildStats(player: Player)
	if stats[player] then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = LEADERSTATS_FOLDER

	local voxels = Instance.new("IntValue")
	voxels.Name = VOXELS_DESTROYED
	voxels.Value = 0
	voxels.Parent = folder

	folder.Parent = player

	stats[player] = { [VOXELS_DESTROYED] = voxels }
end

--[[
	Add to a stat. Returns the new total, or nil if the player has no stats (they
	left mid-flight, which is normal and not an error).

	IntValue caps at 2^31-1; a carve is a few hundred voxels at most, so the only
	way to approach that is a session running for weeks. Clamped anyway, because
	an overflow would wrap negative and look like a bug in the destruction system
	rather than in the counter.
]]
function StatsService:Add(player: Player, statName: string, amount: number): number?
	if amount <= 0 then
		return nil
	end

	local playerStats = stats[player]
	if not playerStats then
		return nil
	end

	local value = playerStats[statName]
	if not value then
		warn(("[StatsService] Unknown stat '%s'"):format(statName))
		return nil
	end

	value.Value = math.min(value.Value + math.floor(amount), 2 ^ 31 - 1)
	return value.Value
end

function StatsService:AddVoxelsDestroyed(player: Player, amount: number): number?
	return self:Add(player, VOXELS_DESTROYED, amount)
end

function StatsService:Get(player: Player, statName: string): number?
	local playerStats = stats[player]
	local value = playerStats and playerStats[statName]
	return value and value.Value or nil
end

function StatsService:GetVoxelsDestroyed(player: Player): number?
	return self:Get(player, VOXELS_DESTROYED)
end

function StatsService:Init(core)
	Core = core
end

function StatsService:Start()
	for _, player in Players:GetPlayers() do
		self:_buildStats(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:_buildStats(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		stats[player] = nil
	end)
end

return StatsService
