local Trove = {}
Trove.__index = Trove

function Trove.new()
	local self = setmetatable({}, Trove)
	self._objects = {}
	return self
end

function Trove:Add(object, cleanupMethod)
	if not object then
		return object
	end

	local method = cleanupMethod
	if method == nil then
		method = self:_getCleanupMethod(object)
	end

	self._objects[object] = method
	return object
end

function Trove:Clone(instance)
	if not instance or not instance.Clone then
		return instance
	end

	local clone = instance:Clone()
	self:Add(clone)
	return clone
end

function Trove:Construct(class, ...)
	local object
	if type(class) == "table" and class.new then
		object = class.new(...)
	elseif type(class) == "function" then
		object = class(...)
	else
		error("Invalid class for construction")
	end

	self:Add(object)
	return object
end

function Trove:Connect(signal, callback)
	local connection = signal:Connect(callback)
	self:Add(connection)
	return connection
end

function Trove:Once(signal, callback)
	local connection
	connection = signal:Connect(function(...)
		connection:Disconnect()
		callback(...)
	end)
	self:Add(connection)
	return connection
end

function Trove:BindToRenderStep(name, priority, callback)
	local RunService = game:GetService("RunService")
	RunService:BindToRenderStep(name, priority, callback)
	self:Add({ name = name }, "__unbindRenderStep")
	return name
end

function Trove:AddPromise(promise)
	if promise and promise.cancel then
		self:Add(promise, "cancel")
	end
	return promise
end

function Trove:Remove(object)
	local cleanupMethod = self._objects[object]
	if cleanupMethod ~= nil then
		self:_cleanup(object, cleanupMethod)
		self._objects[object] = nil
	end
end

function Trove:Pop(object)
	self._objects[object] = nil
end

function Trove:Extend()
	return self:Construct(Trove)
end

function Trove:Clean()
	for object, cleanupMethod in pairs(self._objects) do
		self:_cleanup(object, cleanupMethod)
	end
	table.clear(self._objects)
end

function Trove:WrapClean()
	return function()
		self:Clean()
	end
end

function Trove:AttachToInstance(instance)
	local connection = instance.Destroying:Connect(function()
		self:Clean()
	end)
	self:Add(connection)
	return connection
end

function Trove:Destroy()
	self:Clean()
end

function Trove:_getCleanupMethod(object)
	local objectType = typeof(object)

	if objectType == "Instance" then
		return "Destroy"
	elseif objectType == "RBXScriptConnection" then
		return "Disconnect"
	elseif objectType == "function" then
		return "__function"
	elseif objectType == "thread" then
		return "cancel"
	elseif objectType == "table" then
		if object.Destroy then
			return "Destroy"
		elseif object.Disconnect then
			return "Disconnect"
		elseif object.destroy then
			return "destroy"
		elseif object.disconnect then
			return "disconnect"
		end
	end

	return "__noop"
end

function Trove:_cleanup(object, cleanupMethod)
	local objectType = typeof(object)

	if cleanupMethod == "__function" then
		object()
	elseif cleanupMethod == "__unbindRenderStep" then
		local RunService = game:GetService("RunService")
		RunService:UnbindFromRenderStep(object.name)
	elseif cleanupMethod == "__noop" then
		return
	elseif objectType == "Instance" then
		object:Destroy()
	elseif objectType == "RBXScriptConnection" then
		object:Disconnect()
	elseif objectType == "thread" then
		task.cancel(object)
	elseif type(object) == "table" then
		if cleanupMethod and object[cleanupMethod] then
			object[cleanupMethod](object)
		elseif object.Destroy then
			object:Destroy()
		elseif object.Disconnect then
			object:Disconnect()
		elseif object.destroy then
			object:destroy()
		elseif object.disconnect then
			object:disconnect()
		end
	end
end

return Trove