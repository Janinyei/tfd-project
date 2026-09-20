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
	Client's spherecast hit destructible geometry and is asking the server to
	carve.

	position : contact point (world)
	velocity : the craft's travel vector at impact

	Velocity carries BOTH direction and speed, so neither is sent separately.
	Radius is not sent either: the server derives it from speed with the same
	shared helper the client used, and was already clamping any client-sent
	radius to exactly that value — so transmitting it was pure redundancy that
	also widened the cheat surface.

	Server re-validates everything against FlightConfig.Destruction.
]]
Net.RequestCarve = Packet(
	"RequestCarve",
	Packet.Vector3F32,
	Packet.Vector3F32
)

--[[
	Client reports whether it is boosting.

	The server mirrors this onto a character Attribute rather than relaying an
	event, because Attributes replicate automatically to everyone INCLUDING late
	joiners. A relayed event would leave a player who joined mid-boost with no
	trail, and would need its own teardown on respawn.
]]
Net.SetBoosting = Packet("SetBoosting", Packet.Boolean8)

--[[
	Client asks the server to reset the map to its untouched state.

	Debug/utility action: the server owns all destruction state, so a reset has
	to originate there or clients would disagree about what exists.
]]
Net.RequestMapReset = Packet("RequestMapReset")

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
--[[
	Server -> Client: drop every voxel visual immediately.

	No payload on purpose. The alternative — a cleanup list — would be tens of
	thousands of u16 ids at a full pool, to say something a single flag says.
]]
Net.VoxelsReset = Packet("VoxelsReset")

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
