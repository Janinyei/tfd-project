local Core = {}
Core._modules = {}
Core._initialized = false
Core._started = false

function Core:Get(moduleName: string)
	local module = self._modules[moduleName]
	if not module then
		warn(("Module '%s' not found."):format(moduleName))
	end
	return module
end

function Core:Init(folder: Folder)
	if not self._initializedFolders then
		self._initializedFolders = {}
	end

	if self._initializedFolders[folder] then
		return
	end
	self._initializedFolders[folder] = true

	self.SortedModules = {}

	local function collectModules(container)
		if not container then
			return
		end
		for _, child in container:GetDescendants() do
			if child:IsA("ModuleScript") then
				table.insert(self.SortedModules, {
					module = child,
					priority = child:GetAttribute("Priority") or 0,
					name = child.Name,
				})
			end
		end
	end

	collectModules(script:FindFirstChild("SharedModules"))
	collectModules(folder)

	table.sort(self.SortedModules, function(a, b)
		return a.priority > b.priority or (a.priority == b.priority and a.name < b.name)
	end)

	for _, moduleInfo in ipairs(self.SortedModules) do
		local ok, result = pcall(require, moduleInfo.module)
		if ok then
			self._modules[moduleInfo.name] = result
		else
			warn(string.format("[Core] Failed to load '%s': %s", moduleInfo.name, result))
		end
	end

	for _, moduleInfo in ipairs(self.SortedModules) do
		local moduleInstance = self._modules[moduleInfo.name]
		if moduleInstance then
			if typeof(moduleInstance) == "table" and moduleInstance.Init then
				local ok, err = pcall(moduleInstance.Init, moduleInstance, self)
				if not ok then
					warn(string.format("[Core] Init error in '%s': %s", moduleInfo.name, err))
				end
			end
		end
	end

	if not self._initialized then
		self._initialized = true
	end
end

function Core:Start()
	if not self._initialized then
		warn("[Core] Must call Init() before Start()")
		return
	end

	if self._started then
		return
	end

	for _, moduleInfo in ipairs(self.SortedModules) do
		local moduleInstance = self._modules[moduleInfo.name]
		if moduleInstance then
			if typeof(moduleInstance) == "table" and moduleInstance.Start then
				local ok, err = pcall(moduleInstance.Start, moduleInstance, self)
				if not ok then
					warn(string.format("[Core] Start error in '%s': %s", moduleInfo.name, err))
				end
			end
		end
	end

	self._started = true
end

return Core