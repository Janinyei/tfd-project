--!strict
--[[
	Net

	All client<->server traffic goes through Packet (Suphi Kader buffer networking).
	No raw RemoteEvent/RemoteFunction outside the voxel replication layer, which
	owns its own buffer remotes because a voxel payload can exceed Packet's
	65535-byte per-field cap.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packet = require(ReplicatedStorage.Modules.Libs.Packet)

local Net = {}

--------------------------------------------------------------------------------
-- Client -> Server
--------------------------------------------------------------------------------

--[[
	Client's spherecast hit a destructible part and is asking the server to carve.

	position   : contact point (world)
	radius     : requested sphere radius
	direction  : travel direction, used to launch debris
	speed      : client's current speed — server derives force/voxel size from it
	             rather than trusting separate client-supplied numbers.

	Server clamps every field against FlightConfig.Destruction before carving.
]]
Net.RequestCarve = Packet(
	"RequestCarve",
	Packet.Vector3F32,
	Packet.NumberF32,
	Packet.Vector3F32,
	Packet.NumberF32
)

-- Server -> Client: nothing yet. Voxel create/cleanup/physics replication is
-- handled by VoxelDestructionService's own buffer RemoteEvents (a voxel payload
-- can exceed Packet's 65535-byte per-field cap), so a carve needs no echo.

function Net:Init(_core) end
function Net:Start() end

return Net
