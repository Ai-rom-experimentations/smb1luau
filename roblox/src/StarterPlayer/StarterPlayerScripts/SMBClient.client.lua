--!nonstrict
-- Local-only 2D presentation/input client. All gameplay and rendering stay on
-- the client; this project does not create a Roblox character or server objects.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local modules = ReplicatedStorage
local Game = require(modules:WaitForChild("SMBGame"))
local Renderer = require(modules:WaitForChild("SMBRenderer"))

local smbGame = Game.new()
local ok, rendererOrError = pcall(Renderer.new)
if not ok then
	warn("SMB1 renderer could not start:", rendererOrError)
	return
end
local renderer = rendererOrError

local keyActions = {}
local heldKeys = {}
local heldTouch = {}

local function bind(action, ...)
	for _, keyCode in ipairs({ ... }) do
		keyActions[keyCode] = action
	end
end

bind("left", Enum.KeyCode.Left, Enum.KeyCode.A, Enum.KeyCode.DPadLeft)
bind("right", Enum.KeyCode.Right, Enum.KeyCode.D, Enum.KeyCode.DPadRight)
bind("up", Enum.KeyCode.Up, Enum.KeyCode.W, Enum.KeyCode.DPadUp)
bind("down", Enum.KeyCode.Down, Enum.KeyCode.S, Enum.KeyCode.DPadDown)
bind("jump", Enum.KeyCode.Space, Enum.KeyCode.Z, Enum.KeyCode.ButtonA)
bind("run", Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.X, Enum.KeyCode.ButtonB)
bind("start", Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonStart)
bind("pause", Enum.KeyCode.Escape, Enum.KeyCode.P)

local function refreshAction(action)
	local down = heldTouch[action] == true
	if not down then
		for keyCode, isDown in pairs(heldKeys) do
			if isDown and keyActions[keyCode] == action then
				down = true
				break
			end
		end
	end
	smbGame:setButton(action, down)
end

local function setKey(keyCode, isDown)
	local action = keyActions[keyCode]
	if not action then
		return
	end
	heldKeys[keyCode] = isDown
	refreshAction(action)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	setKey(input.KeyCode, true)
end)

UserInputService.InputEnded:Connect(function(input)
	setKey(input.KeyCode, false)
end)

UserInputService.WindowFocusReleased:Connect(function()
	for keyCode in pairs(heldKeys) do
		heldKeys[keyCode] = false
	end
	table.clear(heldTouch)
	for _, action in pairs(keyActions) do
		refreshAction(action)
	end
end)

renderer:addTouchControls(function(name, isDown)
	local action = ({ Left = "left", Right = "right", Run = "run", Jump = "jump" })[name]
	if action then
		heldTouch[action] = isDown
		refreshAction(action)
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	smbGame:step(deltaTime)
end)

local rendering = true
RunService.RenderStepped:Connect(function()
	if not rendering then
		return
	end
	local drawOk, drawError = pcall(function()
		renderer:draw(smbGame:getState())
	end)
	if not drawOk then
		rendering = false
		warn("SMB1 framebuffer drawing stopped:", drawError)
	end
end)

script.Destroying:Connect(function()
	if renderer then
		renderer:destroy()
	end
end)
