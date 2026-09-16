


























export type Connection={
Disconnect:(self:Connection)->(),
Destroy:(self:Connection)->(),
Connected:boolean,
}

export type Signal<T...> ={
Fire:(self:Signal<T...>,T...)->(),
FireDeferred:(self:Signal<T...>,T...)->(),
Connect:(self:Signal<T...>,fn:(T...)->())->Connection,
Once:(self:Signal<T...>,fn:(T...)->())->Connection,
DisconnectAll:(self:Signal<T...>)->(),
GetConnections:(self:Signal<T...>)->{Connection},
Destroy:(self:Signal<T...>)->(),
Wait:(self:Signal<T...>)->T...,
}


local a






local function acquireRunnerThreadAndCallEventHandler(b,...)
local c=a
a=nil
b(...)

a=c
end




local function runEventHandlerInFreeThread(...)
acquireRunnerThreadAndCallEventHandler(...)
while true do
acquireRunnerThreadAndCallEventHandler(coroutine.yield())
end
end

















local b={}
b.__index=b

function b.new(c,d)
return setmetatable({
Connected=true,
_signal=c,
_fn=d,
_next=false,
},b)
end

function b.Disconnect(c)
if not c.Connected then
return
end
c.Connected=false





if c._signal._handlerListHead==c then
c._signal._handlerListHead=c._next
else
local d=c._signal._handlerListHead
while d and d._next~=c do
d=d._next
end
if d then
d._next=c._next
end
end
end

b.Destroy=b.Disconnect


setmetatable(b,{
__index=function(c,d)
error(("Attempt to get Connection::%s (not a valid member)"):format(tostring(d)),2)
end,
__newindex=function(c,d,e)
error(("Attempt to set Connection::%s (not a valid member)"):format(tostring(d)),2)
end,
})
























local c={}
c.__index=c






function c.new<T...>():Signal<T...>
local d=setmetatable({
_handlerListHead=false,
_proxyHandler=nil,
},c)
return d
end














function c.Wrap<T...>(d:RBXScriptSignal):Signal<T...>
assert(
typeof(d)=="RBXScriptSignal",
"Argument #1 to Signal.Wrap must be a RBXScriptSignal; got "..typeof(d)
)
local e=c.new()
e._proxyHandler=d:Connect(function(...)
e:Fire(...)
end)
return e
end







function c.Is(d:any):boolean
return type(d)=="table"and getmetatable(d)==c
end














function c.Connect(d,e)
local f=b.new(d,e)
if d._handlerListHead then
f._next=d._handlerListHead
d._handlerListHead=f
else
d._handlerListHead=f
end
return f
end






function c.ConnectOnce(d,e)
return d:Once(e)
end
















function c.Once(d,e)
local f
local g=false
f=d:Connect(function(...)
if g then
return
end
g=true
f:Disconnect()
e(...)
end)
return f
end

function c.GetConnections(d)
local e={}
local f=d._handlerListHead
while f do
table.insert(e,f)
f=f._next
end
return e
end









function c.DisconnectAll(d)
local e=d._handlerListHead
while e do
e.Connected=false
e=e._next
end
d._handlerListHead=false
end
















function c.Fire(d,...)
local e=d._handlerListHead
while e do
if e.Connected then
if not a then
a=coroutine.create(runEventHandlerInFreeThread)
end
task.spawn(a,e._fn,...)
end
e=e._next
end
end









function c.FireDeferred(d,...)
local e=d._handlerListHead
while e do
task.defer(e._fn,...)
e=e._next
end
end
















function c.Wait(d)
local e=coroutine.running()
local f
local g=false
f=d:Connect(function(...)
if g then
return
end
g=true
f:Disconnect()
task.spawn(e,...)
end)
return coroutine.yield()
end













function c.Destroy(d)
d:DisconnectAll()
local e=rawget(d,"_proxyHandler")
if e then
e:Disconnect()
end
end


setmetatable(c,{
__index=function(d,e)
error(("Attempt to get Signal::%s (not a valid member)"):format(tostring(e)),2)
end,
__newindex=function(d,e,f)
error(("Attempt to set Signal::%s (not a valid member)"):format(tostring(e)),2)
end,
})

return{
new=c.new,
Wrap=c.Wrap,
Is=c.Is,
}