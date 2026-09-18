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

--[[
	Server -> Client: result of that player's carve request.

	Payload: voxels actually knocked loose (0 = the request was rejected, or it
	landed somewhere already hollow). Without this the client cannot tell
	"server refused" from "server carved but the hole did not open", which are
	very different bugs with the same symptom.

	Voxel geometry itself is NOT sent here — VoxelDestructionService owns that on
	its own buffer remotes, because a voxel payload can exceed Packet's
	65535-byte per-field cap.
]]
Net.CarveResult = Packet("CarveResult", Packet.NumberU16)

--[[
	Live voxel census, broadcast at a low rate for the debug panel.

	Payload: shell, live debris, frozen debris, pool capacity, denied allocations.
	All u16, which is also the ceiling on voxel ids, so no field can overflow.

	"Denied" counts voxels a carve wanted but could not have because the pool was
	full. Non-zero means destruction is being silently reduced, which is exactly
	the failure that used to hide behind PartCache quietly expanding.

	Sent from the server because these are server-owned truths: the client only
	knows about voxels it was told to render, and skips distant debris entirely.
]]
Net.VoxelCensus = Packet(
	"VoxelCensus",
	Packet.NumberU16,
	Packet.NumberU16,
	Packet.NumberU16,
	Packet.NumberU16,
	Packet.NumberU16
)

function Net:Init(_core) end
function Net:Start() end

return Net
