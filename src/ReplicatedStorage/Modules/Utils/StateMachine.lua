--librium 
--7/15/25

--simple state machine module


local Signal = require(script.Parent.Signal)
local StateMachine = {}

StateMachine.__index = StateMachine


function StateMachine.new()
	local self =  setmetatable({}, StateMachine)
	self.State = "None"
	self.StateChanged  = Signal.new()
	return self
end

function StateMachine:SetState(stateName : string, duration : number?)

	if self.State ~= stateName then
	
	self.StateChanged:Fire(self.State, stateName) --old state, new state
		
	end
		
	self.State = stateName

	if duration then
		task.delay(duration, function()
			self:ClearState()
		end)
	end
end

function StateMachine:ClearState()
	self:SetState("None")
end

function StateMachine:GetState()
	return self.State
end

function StateMachine:IsState(StateName: string) --checks if the state is the one in the argument
	return self.State == StateName
end


function StateMachine:Destroy()
	self:ClearState()
	self.StateChanged:Destroy()
	self = nil --idk
end
	
return StateMachine
