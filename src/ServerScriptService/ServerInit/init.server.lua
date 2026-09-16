local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Core"))

Core:Init(script.Modules.Core)
Core:Start()
