--!strict
--[[
	BoostStateService  (server)

	Mirrors each player's boost state onto their character as an Attribute, so
	every client can react to it — the boost trail being the first consumer.

	An Attribute rather than a relayed event, deliberately:
	  * it replicates to late joiners, who would otherwise never see a trail on
	    someone already boosting;
	  * it dies with the character, so respawning cannot strand a stuck "on"
	    state;
	  * no per-client fan-out to maintain.

	Purely cosmetic state. It is not trusted for anything — a client claiming to
	boost gains nothing but a trail.
]]

local Players = game:GetService("Players")

local BoostStateService = {}

local Core
local Config
local Net

function BoostStateService:_setBoosting(player: Player, boosting: boolean)
	local character = player.Character
	if not character then
		return
	end
	character:SetAttribute(Config.Trail.Attribute, boosting)
end

function BoostStateService:Init(core)
	Core = core
end

function BoostStateService:Start()
	Config = Core:Get("FlightConfig")
	Net = Core:Get("Net")

	Net.SetBoosting.OnServerEvent:Connect(function(player, boosting)
		self:_setBoosting(player, boosting)
	end)

	-- A fresh character starts un-boosted; the owning client re-asserts the true
	-- state on its next state change.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			character:SetAttribute(Config.Trail.Attribute, false)
		end)
	end)
end

return BoostStateService
