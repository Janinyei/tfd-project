--Purpose: To make a timer class since I can't find any good ones lol
--janin 10/28/25

local Timer = {}
Timer.__index = Timer

--Stores Timers in Cache
local Timers = {}

--Services--
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
--Utils--
local Utils = game.ReplicatedStorage.Modules.Utils
local Signal = require(Utils.Signal)

RunService.Heartbeat:Connect(function(deltaTime)
 for id, timer in Timers do 
        -- sets up timers
       timer:Update(deltaTime)
 end
end)

function Timer.new(Duration : number)
  local self = setmetatable({}, Timer)

  self.Enabled = false
  self.TimerId = HttpService:GenerateGUID(false)
  self.InitialDuration = Duration
  self.TimeRemaining = Duration

  self.OnTick = Signal.new()
  self.OnComplete = Signal.new()

  Timers[self.TimerId] = self
  return self
end

function Timer:Start()
    self.Enabled = true
end

function Timer:Stop()
    self.Enabled = false
end


function Timer:Update(deltaTime)
    if self.Enabled == false  then return end
    
        if self.TimeRemaining % 1 < deltaTime  then
            self.OnTick:Fire(self.TimeRemaining)
        end
    
        self.TimeRemaining -= deltaTime
    
    
        if self.TimeRemaining <= 0 then
            self.Enabled = false
            self.TimeRemaining = 0
            self.OnComplete:Fire()
        end
end

function Timer:Destroy()
    Timers[self.TimerId] = nil

    --cleanup events
    self.OnTick:Destroy()
    self.OnComplete:Destroy()
end

--extra cool functions

--Sets the remaining time
function Timer:SetTime(Time : number)
    if Time > 0 then 
        self.TimeRemaining = Time
        self.Enabled = true
    end
end

--Adds more to the remaining time
function Timer:AddTime(Amount : number)
    self.TimeRemaining += Amount
end


return Timer