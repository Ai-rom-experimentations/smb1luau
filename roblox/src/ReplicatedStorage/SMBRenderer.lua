--!strict
-- 256x240 NES-resolution renderer. The original CHR bitplanes and metatile
-- definitions are rasterized into an EditableImage, so no uploaded texture IDs
-- are needed in the Roblox place.
local AssetService = game:GetService("AssetService")
local Data = require(script.Parent:WaitForChild("SMBData"))

local Renderer = {}
Renderer.__index = Renderer

local W, H = 256, 240
local STRIDE = W * 4
local IMAGE_BYTES = W * H * 4
local AREA_NAMES = { "water", "ground", "underground", "castle" }
local MARIO_PALETTES = {
	{ 0x22, 0x16, 0x27, 0x18 },
	{ 0x22, 0x30, 0x27, 0x19 },
	{ 0x22, 0x37, 0x27, 0x16 },
}
local STAR_PALETTES = {
	{ 0x22, 0x16, 0x27, 0x18 },
	{ 0x22, 0x30, 0x27, 0x19 },
	{ 0x22, 0x37, 0x27, 0x16 },
}

-- Standard NTSC 2C02 color table, indexed by the six-bit palette values used
-- by the original PPU palette tables.
local NES_RGB = {
	{ 124, 124, 124 }, { 0, 0, 252 }, { 0, 0, 188 }, { 68, 40, 188 },
	{ 148, 0, 132 }, { 168, 0, 32 }, { 168, 16, 0 }, { 136, 20, 0 },
	{ 80, 48, 0 }, { 0, 120, 0 }, { 0, 104, 0 }, { 0, 88, 0 },
	{ 0, 64, 88 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ 188, 188, 192 }, { 0, 120, 248 }, { 0, 88, 248 }, { 104, 68, 252 },
	{ 216, 0, 204 }, { 228, 0, 88 }, { 248, 56, 0 }, { 228, 92, 16 },
	{ 172, 124, 0 }, { 0, 184, 0 }, { 0, 168, 0 }, { 0, 168, 68 },
	{ 0, 136, 136 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ 248, 248, 248 }, { 60, 188, 252 }, { 104, 136, 252 }, { 152, 120, 248 },
	{ 248, 120, 248 }, { 248, 88, 152 }, { 248, 120, 88 }, { 252, 160, 68 },
	{ 248, 184, 0 }, { 184, 248, 24 }, { 88, 216, 84 }, { 88, 248, 152 },
	{ 0, 232, 216 }, { 120, 120, 120 }, { 0, 0, 0 }, { 0, 0, 0 },
	{ 252, 252, 252 }, { 164, 228, 252 }, { 184, 184, 248 }, { 216, 184, 248 },
	{ 248, 184, 248 }, { 248, 164, 192 }, { 240, 208, 176 }, { 252, 224, 168 },
	{ 248, 216, 120 }, { 216, 248, 120 }, { 184, 248, 184 }, { 184, 248, 216 },
	{ 0, 252, 252 }, { 248, 216, 248 }, { 0, 0, 0 }, { 0, 0, 0 },
}

local FONT = {
	["A"] = { 14, 17, 17, 31, 17, 17, 17 }, ["B"] = { 30, 17, 17, 30, 17, 17, 30 },
	["C"] = { 14, 17, 16, 16, 16, 17, 14 }, ["D"] = { 30, 17, 17, 17, 17, 17, 30 },
	["E"] = { 31, 16, 16, 30, 16, 16, 31 }, ["F"] = { 31, 16, 16, 30, 16, 16, 16 },
	["G"] = { 14, 17, 16, 23, 17, 17, 15 }, ["H"] = { 17, 17, 17, 31, 17, 17, 17 },
	["I"] = { 14, 4, 4, 4, 4, 4, 14 }, ["J"] = { 7, 2, 2, 2, 18, 18, 12 },
	["K"] = { 17, 18, 20, 24, 20, 18, 17 }, ["L"] = { 16, 16, 16, 16, 16, 16, 31 },
	["M"] = { 17, 27, 21, 21, 17, 17, 17 }, ["N"] = { 17, 25, 21, 19, 17, 17, 17 },
	["O"] = { 14, 17, 17, 17, 17, 17, 14 }, ["P"] = { 30, 17, 17, 30, 16, 16, 16 },
	["Q"] = { 14, 17, 17, 17, 21, 18, 13 }, ["R"] = { 30, 17, 17, 30, 20, 18, 17 },
	["S"] = { 15, 16, 16, 14, 1, 1, 30 }, ["T"] = { 31, 4, 4, 4, 4, 4, 4 },
	["U"] = { 17, 17, 17, 17, 17, 17, 14 }, ["V"] = { 17, 17, 17, 17, 17, 10, 4 },
	["W"] = { 17, 17, 17, 21, 21, 21, 10 }, ["X"] = { 17, 17, 10, 4, 10, 17, 17 },
	["Y"] = { 17, 17, 10, 4, 4, 4, 4 }, ["Z"] = { 31, 1, 2, 4, 8, 16, 31 },
	["0"] = { 14, 17, 19, 21, 25, 17, 14 }, ["1"] = { 4, 12, 4, 4, 4, 4, 14 },
	["2"] = { 14, 17, 1, 2, 4, 8, 31 }, ["3"] = { 30, 1, 1, 14, 1, 1, 30 },
	["4"] = { 2, 6, 10, 18, 31, 2, 2 }, ["5"] = { 31, 16, 16, 30, 1, 1, 30 },
	["6"] = { 14, 16, 16, 30, 17, 17, 14 }, ["7"] = { 31, 1, 2, 4, 8, 8, 8 },
	["8"] = { 14, 17, 17, 14, 17, 17, 14 }, ["9"] = { 14, 17, 17, 15, 1, 1, 14 },
	["-"] = { 0, 0, 0, 31, 0, 0, 0 }, ["."] = { 0, 0, 0, 0, 0, 12, 12 },
	["!"] = { 4, 4, 4, 4, 4, 0, 4 }, ["'"] = { 12, 12, 4, 0, 0, 0, 0 },
	["/"] = { 1, 2, 2, 4, 8, 8, 16 }, ["<"] = { 2, 4, 8, 16, 8, 4, 2 },
	[">"] = { 8, 4, 2, 1, 2, 4, 8 }, [" "] = { 0, 0, 0, 0, 0, 0, 0 },
}

local function hexToBuffer(hex: string)
	local out = buffer.create(math.floor(#hex / 2))
	for i = 1, #hex, 2 do
		local value = tonumber(string.sub(hex, i, i + 1), 16) or 0
		buffer.writeu8(out, math.floor((i - 1) / 2), value)
	end
	return out
end

local function paletteRGB(code: number)
	return NES_RGB[bit32.band(code, 0x3F) + 1] or NES_RGB[1]
end

local function ppuPixel(chr, tile: number, x: number, y: number, bankOffset: number?): number
	local tileOffset = (bankOffset or 0) + tile * 16
	local bit = 7 - x
	local low = buffer.readu8(chr, tileOffset + y)
	local high = buffer.readu8(chr, tileOffset + y + 8)
	return bit32.band(bit32.rshift(low, bit), 1) + bit32.lshift(bit32.band(bit32.rshift(high, bit), 1), 1)
end

local function writeColor(target, offset: number, color)
	buffer.writeu8(target, offset, color[1])
	buffer.writeu8(target, offset + 1, color[2])
	buffer.writeu8(target, offset + 2, color[3])
	buffer.writeu8(target, offset + 3, 255)
end

function Renderer.new()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SMB1Screen"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Parent = screenGui

	local canvas = Instance.new("Frame")
	canvas.Name = "NESCanvas"
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(W, H)
	canvas.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true
	canvas.Parent = screenGui

	local uiScale = Instance.new("UIScale")
	uiScale.Name = "ViewportScale"
	uiScale.Parent = canvas

	local imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "Framebuffer"
	imageLabel.BackgroundTransparency = 1
	imageLabel.BorderSizePixel = 0
	imageLabel.Size = UDim2.fromOffset(W, H)
	imageLabel.Position = UDim2.fromOffset(0, 0)
	imageLabel.ImageColor3 = Color3.new(1, 1, 1)
	imageLabel.ScaleType = Enum.ScaleType.Stretch
	imageLabel.Parent = canvas
	pcall(function()
		imageLabel.ResampleMode = Enum.ResamplerMode.Pixelated
	end)

	local self = setmetatable({}, Renderer)
	self.screenGui = screenGui
	self.canvas = canvas
	self.uiScale = uiScale
	self.imageLabel = imageLabel
	self.image = nil
	self.pixels = buffer.create(IMAGE_BYTES)
	self.errorLabel = nil
	self.touchButtons = {}
	self.metaCache = { {}, {}, {}, {} }
	self.clearCache = {}
	self.blackRow = buffer.create(STRIDE)
	self.spriteData = {
		mario = hexToBuffer(Data.CHR.mario),
		misc = hexToBuffer(Data.CHR.misc),
		enemies = hexToBuffer(Data.CHR.enemies),
	}
	self.bgData = {
		hexToBuffer(Data.CHR.bgWater),
		hexToBuffer(Data.CHR.bgGround),
		hexToBuffer(Data.CHR.bgUnderground),
		hexToBuffer(Data.CHR.bgCastle),
	}
	local rgbBlack = paletteRGB(0x0F)
	for x = 0, W - 1 do
		writeColor(self.blackRow, x * 4, rgbBlack)
	end

	local ok, editableImage = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
	end)
	if ok and editableImage then
		local bound = pcall(function()
			imageLabel.ImageContent = Content.fromObject(editableImage)
		end)
		if bound then
			self.image = editableImage
		else
			editableImage:Destroy()
		end
	end

	if not self.image then
		local message = Instance.new("TextLabel")
		message.Name = "SetupMessage"
		message.AnchorPoint = Vector2.new(0.5, 0.5)
		message.Position = UDim2.fromScale(0.5, 0.5)
		message.Size = UDim2.new(0.8, 0, 0, 110)
		message.BackgroundColor3 = Color3.fromRGB(14, 18, 31)
		message.BackgroundTransparency = 0.05
		message.BorderSizePixel = 0
		message.TextColor3 = Color3.fromRGB(255, 255, 255)
		message.TextWrapped = true
		message.TextSize = 20
		message.Font = Enum.Font.Code
		message.Text = "SMB1's pixel renderer needs Roblox EditableImage enabled. In Studio open Game Settings > Security and turn on Allow Mesh & Image APIs, then Play again."
		message.Parent = screenGui
		self.errorLabel = message
		warn("SMB1: EditableImage is unavailable; enable Allow Mesh & Image APIs in Studio's Security settings.")
	end

	local camera = workspace.CurrentCamera
	local function resize()
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		local scale = math.min(viewport.X / W, viewport.Y / H)
		uiScale.Scale = math.max(scale, 0.5)
	end
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize)
	end
	resize()

	return self
end

function Renderer:destroy()
	if self.image then
		self.image:Destroy()
	end
	if self.screenGui then
		self.screenGui:Destroy()
	end
end

function Renderer:ensureClear(code: number)
	local key = bit32.band(code, 0x3F)
	if self.clearCache[key] then
		return self.clearCache[key]
	end
	local color = paletteRGB(key)
	local pixels = buffer.create(IMAGE_BYTES)
	for i = 0, IMAGE_BYTES - 4, 4 do
		writeColor(pixels, i, color)
	end
	self.clearCache[key] = pixels
	return pixels
end

function Renderer:clear(code: number)
	buffer.copy(self.pixels, 0, self:ensureClear(code), 0, IMAGE_BYTES)
end

function Renderer:drawPixel(x: number, y: number, colorCode: number)
	if x < 0 or x >= W or y < 0 or y >= H then
		return
	end
	writeColor(self.pixels, (math.floor(y) * W + math.floor(x)) * 4, paletteRGB(colorCode))
end

function Renderer:drawRect(x: number, y: number, width: number, height: number, colorCode: number)
	local left = math.max(0, math.floor(x))
	local top = math.max(0, math.floor(y))
	local right = math.min(W, math.floor(x + width))
	local bottom = math.min(H, math.floor(y + height))
	if right <= left or bottom <= top then
		return
	end
	local color = paletteRGB(colorCode)
	for py = top, bottom - 1 do
		local offset = (py * W + left) * 4
		for _ = left, right - 1 do
			writeColor(self.pixels, offset, color)
			offset += 4
		end
	end
end

function Renderer:drawText(x: number, y: number, text: string, colorCode: number, scale: number?)
	local size = scale or 1
	local cursor = math.floor(x)
	local color = paletteRGB(colorCode)
	for i = 1, #text do
		local character = string.upper(string.sub(text, i, i))
		local glyph = FONT[character] or FONT[" "]
		for gy = 1, 7 do
			local mask = glyph[gy]
			for gx = 0, 4 do
				if bit32.band(mask, bit32.lshift(1, 4 - gx)) ~= 0 then
					for sy = 0, size - 1 do
						for sx = 0, size - 1 do
							local px = cursor + gx * size + sx
							local py = y + (gy - 1) * size + sy
							if px >= 0 and px < W and py >= 0 and py < H then
								writeColor(self.pixels, (py * W + px) * 4, color)
							end
						end
					end
				end
			end
		end
		cursor += 6 * size
	end
end

function Renderer:metaPixels(areaType: number, tileId: number, bgCode: number?, areaStyle: number?)
	local background = bit32.band(bgCode or Data.BGColor[areaType + 1] or 0x0F, 0x3F)
	local style = areaStyle or 0
	local cacheKey = tileId + 1 + background * 256 + style * 16384
	local cache = self.metaCache[areaType + 1]
	local cached = cache[cacheKey]
	if cached then
		return cached
	end
	local definition = Data.Metatiles[tileId + 1] or Data.Metatiles[1]
	local paletteSet = Data.Palettes[AREA_NAMES[areaType + 1]].background
	local colors = paletteSet[definition[5] + 1]
	if style == 1 and areaType == 1 and definition[5] == 0 then
		colors = { 0x22, 0x27, 0x16, 0x0F }
	end
	local chr = self.bgData[areaType + 1]
	local out = buffer.create(16 * 16 * 4)
	for y = 0, 15 do
		for x = 0, 15 do
			local patternIndex
			if y < 8 then
				patternIndex = if x < 8 then definition[1] else definition[3]
			else
				patternIndex = if x < 8 then definition[2] else definition[4]
			end
			local px = ppuPixel(chr, patternIndex, x % 8, y % 8)
			local paletteCode = if px == 0 then background else colors[px + 1]
			writeColor(out, (y * 16 + x) * 4, paletteRGB(paletteCode))
		end
	end
	cache[cacheKey] = out
	return out
end

function Renderer:drawMeta(areaType: number, tileId: number, x: number, y: number, cameraX: number?, bgCode: number?, areaStyle: number?)
	if tileId == 0 then
		return
	end
	local destX = math.floor(x - (cameraX or 0))
	local destY = math.floor(y)
	local left = math.max(0, destX)
	local top = math.max(0, destY)
	local right = math.min(W, destX + 16)
	local bottom = math.min(H, destY + 16)
	if right <= left or bottom <= top then
		return
	end
	local source = self:metaPixels(areaType, tileId, bgCode, areaStyle)
	local widthBytes = (right - left) * 4
	local sourceX = (left - destX) * 4
	for py = top, bottom - 1 do
		local sourceY = (py - destY) * 16 * 4 + sourceX
		local destination = (py * W + left) * 4
		buffer.copy(self.pixels, destination, source, sourceY, widthBytes)
	end
end

function Renderer:drawSpriteTile(chr, tileId: number, x: number, y: number, areaType: number, paletteIndex: number, flipX: boolean?, flipY: boolean?, bankOffset: number?, paletteOverride)
	local left = math.floor(x)
	local top = math.floor(y)
	local paletteSet = Data.Palettes[AREA_NAMES[areaType + 1]].sprites
	local colors = paletteOverride or paletteSet[(paletteIndex or 0) + 1]
	for py = 0, 15 do
		local sourceY = if flipY then 15 - py else py
		local tile = bit32.band(tileId, 0x3E) + math.floor(sourceY / 8)
		for px = 0, 7 do
			local sx = if flipX then 7 - px else px
			local value = ppuPixel(chr, tile, sx, sourceY % 8, bankOffset)
			if value ~= 0 then
				self:drawPixel(left + px, top + py, colors[value + 1])
			end
		end
	end
end

function Renderer:drawVine(vine, cameraX: number, areaType: number)
	if not vine.active or vine.height < 8 then
		return
	end
	local topY = vine.bottomY - vine.height
	local baseX = vine.x - 8 - cameraX
	local groups = math.clamp(math.floor((vine.maxHeight or 48) / 48), 1, 2)
	for group = 0, groups - 1 do
		for segment = 0, 5 do
			local tile = if group == 0 and segment == 0 then 0x28 else 0x2A
			local x = baseX + (segment % 2) * 6
			local y = 32 + topY + group * 48 + segment * 8
			self:drawSpriteTile(
				self.spriteData.enemies,
				tile,
				x,
				y,
				areaType,
				1,
				segment % 2 == 1,
				false,
				3072
			)
		end
	end
end

function Renderer:drawMario(player, cameraX: number, areaType: number, frame: number)
	local x = math.floor(player.x - cameraX)
	local y = 32 + math.floor(player.y)
	local power = player.power or 0
	local small = power == 0
	if not small and not player.crouching then
		y -= 8
	end
	local facingLeft = player.facing < 0
	local moving = math.abs(player.vx or 0) > 0.15
	local which = if player.crouching then 7 elseif not player.onGround then 6 elseif moving then 2 + (math.floor(frame / 6) % 3) else 1
	local bankOffset
	local frames
	local rows
	if small then
		bankOffset = 2048
		frames = {
			{ 0x00, 0x02 }, { 0x04, 0x06 }, { 0x08, 0x0A }, { 0x0C, 0x0E },
			{ 0x10, 0x12 }, { 0x14, 0x16 },
		}
		which = math.clamp(which, 1, 6)
		rows = { frames[which] }
	elseif power >= 2 then
		bankOffset = if player.crouching then 3072 else 1024
		frames = {
			{ 0x00, 0x02, 0x2C, 0x2E },
			{ 0x00, 0x02, 0x2C, 0x2E },
			{ 0x00, 0x02, 0x30, 0x32 },
			{ 0x00, 0x02, 0x14, 0x16 },
			{ 0x00, 0x02, 0x34, 0x36 },
			{ 0x00, 0x02, 0x10, 0x12 },
			{ 0x00, 0x02, 0x18, 0x1A },
		}
		rows = { { frames[which][1], frames[which][2] }, { frames[which][3], frames[which][4] } }
	else
		bankOffset = 0
		frames = {
			{ 0x00, 0x02, 0x20, 0x22 },
			{ 0x04, 0x06, 0x24, 0x26 },
			{ 0x08, 0x0A, 0x28, 0x2A },
			{ 0x0C, 0x0E, 0x2C, 0x2E },
			{ 0x10, 0x12, 0x30, 0x32 },
			{ 0x14, 0x16, 0x34, 0x36 },
			{ 0x18, 0x1A, 0x38, 0x3A },
		}
		rows = { { frames[which][1], frames[which][2] }, { frames[which][3], frames[which][4] } }
	end

	local palette = if power >= 2 then MARIO_PALETTES[3]
		elseif player.currentPlayer == 2 then MARIO_PALETTES[2]
		else MARIO_PALETTES[1]
	if player.starFrames and player.starFrames > 0 then
		palette = STAR_PALETTES[math.floor(frame / 4) % #STAR_PALETTES + 1]
	end
	local chr = self.spriteData.mario
	for rowIndex, parts in ipairs(rows) do
		local leftTile, rightTile = parts[1], parts[2]
		if facingLeft then
			leftTile, rightTile = rightTile, leftTile
		end
		self:drawSpriteTile(chr, leftTile, x, y + (rowIndex - 1) * 16, areaType, 0, facingLeft, false, bankOffset, palette)
		self:drawSpriteTile(chr, rightTile, x + 8, y + (rowIndex - 1) * 16, areaType, 0, facingLeft, false, bankOffset, palette)
	end
end

function Renderer:drawEnemy(enemy, cameraX: number, areaType: number, frame: number)
	if enemy.type == 13 and enemy.hidden then
		return
	end
	if not enemy.alive or enemy.state == "dead" or enemy.state == "squashed" then
		if enemy.state == "squashed" and enemy.alive then
			local chr = self.spriteData.enemies
			local x = math.floor(enemy.x - cameraX)
			local y = 32 + math.floor(enemy.y) + 8
			self:drawSpriteTile(chr, 0x26, x, y, areaType, 3, false, false, 0)
			self:drawSpriteTile(chr, 0x26, x + 8, y, areaType, 3, true, false, 0)
		end
		return
	end

	local chr = self.spriteData.enemies
	local worldX = if enemy.type == 13 then enemy.x - 8 else enemy.x
	local x = math.floor(worldX - cameraX)
	local y = 32 + math.floor(enemy.y)
	local tick = math.floor(frame / 8) % 2
	local facingLeft = enemy.vx < 0
	local bankOffset = if enemy.type == 12 or enemy.type == 45 then 2048
		elseif enemy.type == 0x15 then 3072
		elseif enemy.type == 5 or enemy.type == 7 or enemy.type == 13 or enemy.type == 17 then 1024
		else 0
	local function sprite(tile, dx, dy, palette, flipX, flipY)
		self:drawSpriteTile(chr, tile, x + dx, y + dy, areaType, palette, flipX, flipY, bankOffset)
	end
	local function pair(a, b, dx, dy, palette, mirror)
		if facingLeft and mirror ~= false then
			a, b = b, a
		end
		sprite(a, dx, dy, palette, facingLeft and mirror ~= false, false)
		sprite(b, dx + 8, dy, palette, facingLeft and mirror ~= false, false)
	end

	if enemy.type == 6 then -- Goomba
		local a, b = if tick == 0 then 0x22 else 0x24, if tick == 0 then 0x24 else 0x22
		pair(a, b, 0, 0, 3, true)
	elseif enemy.type == 0 or enemy.type == 3 or enemy.type == 2 then -- Koopas and Buzzy Beetles
		if enemy.state == "shell" or enemy.state == "movingShell" then
			local tile = if enemy.type == 2 then 0x20 else 0x1A
			local palette = if enemy.type == 2 then 3 else 0
			sprite(tile, 0, 8, palette, false, false)
			sprite(tile, 8, 8, palette, true, false)
		else
			local palette = if enemy.type == 2 then 3 else 0
			local rows
			if enemy.type == 2 then
				rows = { { 0x00, 0x02 } }
			else
				rows = if tick == 0 then { { 0x38, 0x12 }, { 0x30, 0x32 } } else { { 0x18, 0x16 }, { 0x34, 0x36 } }
			end
			for rowIndex, parts in ipairs(rows) do
				pair(parts[1], parts[2], 0, -4 + (rowIndex - 1) * 16, palette, true)
			end
		end
	elseif enemy.type == 5 then -- Hammer Bro
		local parts = if tick == 0 then { 0x00, 0x02, 0x20, 0x22 } else { 0x08, 0x0A, 0x24, 0x26 }
		for i, tile in ipairs(parts) do
			local row, col = math.floor((i - 1) / 2), (i - 1) % 2
			local px = if facingLeft then 8 - col * 8 else col * 8
			sprite(tile, px, -8 + row * 16, 1, facingLeft, false)
		end
	elseif enemy.type == 13 then -- Piranha plant
		local top = if tick == 0 then 0x1C else 0x1E
		sprite(top, 0, -8, 1, false, false)
		sprite(top, 8, -8, 1, true, false)
		sprite(top + 0x20, 0, 8, 1, false, false)
		sprite(top + 0x20, 8, 8, 1, true, false)
	elseif enemy.type == 8 then -- Bullet Bill
		pair(0x1C, 0x1E, 0, 0, 3, false)
	elseif enemy.type == 7 then -- Bloober
		sprite(0x1A, 0, -4, 3, false, false)
		sprite(0x1A, 8, -4, 3, true, false)
		sprite(0x3A, 0, 12, 3, false, false)
		sprite(0x3A, 8, 12, 3, true, false)
	elseif enemy.type == 10 or enemy.type == 11 or enemy.type == 14 or enemy.type == 15 or enemy.type == 16 or enemy.type == 20 then
		local a, b = if tick == 0 then 0x2C else 0x2A, 0x2E
		local palette = if enemy.type == 11 or enemy.type == 15 then 1 else 0
		pair(a, b, 0, 0, palette, true)
		if enemy.type == 14 or enemy.type == 15 or enemy.type == 16 then
			-- Paratroopa wings are small; the body remains the authentic Koopa CHR.
			sprite(0x30, 2, -4, palette, false, true)
			sprite(0x30, 10, -4, palette, true, true)
		end
	elseif enemy.type == 12 then -- Podoboo
		sprite(0x18, 0, 0, 2, false, enemy.vy >= 0)
		sprite(0x18, 8, 0, 2, true, enemy.vy >= 0)
	elseif enemy.type == 17 then -- Lakitu
		local head = if tick == 0 then 0x0C else 0x30
		sprite(head, 0, -8, 1, facingLeft, false)
		sprite(head + 2, 8, -8, 1, facingLeft, false)
		sprite(0x2C, 0, 8, 1, facingLeft, false)
		sprite(0x2E, 8, 8, 1, facingLeft, false)
	elseif enemy.type == 18 then -- Spiny
		pair(if tick == 0 then 0x08 else 0x0C, if tick == 0 then 0x0A else 0x0E, 0, 0, 2, true)
	elseif enemy.type == 45 then -- Bowser
		local parts = if tick == 0 then { 0x08, 0x0A, 0x28, 0x04, 0x06, 0x20, 0x22 } else { 0x0C, 0x0E, 0x28, 0x04, 0x06, 0x24, 0x26 }
		for i, tile in ipairs(parts) do
			local col = if i <= 3 then (i - 1) % 2 else (i - 4) % 2
			local row = if i <= 3 then math.floor((i - 1) / 2) else 2 + math.floor((i - 4) / 2)
			local px = if facingLeft then 8 - col * 8 else col * 8
			sprite(tile, px, -8 + row * 16, 1, facingLeft, false)
		end
	else
		pair(0x22, 0x24, 0, 0, 3, false)
	end
end

function Renderer:drawPowerup(item, cameraX: number, areaType: number, frame: number)
	local x = math.floor(item.x - cameraX)
	local y = 32 + math.floor(item.y)
	local chr = self.spriteData.misc
	if item.kind == "star" then
		self:drawSpriteTile(chr, 0x34, x, y, areaType, 0, false, false)
		self:drawSpriteTile(chr, 0x36, x + 8, y, areaType, 0, false, false)
	elseif item.kind == "flower" then
		local phase = math.floor(frame / 8) % 2
		local topA, topB = if phase == 0 then 0x38 else 0x38, if phase == 0 then 0x38 else 0x3A
		self:drawSpriteTile(chr, topA, x, y, areaType, 0, false, false)
		self:drawSpriteTile(chr, topB, x + 8, y, areaType, 1, true, false)
		self:drawSpriteTile(chr, 0x3A, x, y + 16, areaType, 1, false, false)
		self:drawSpriteTile(chr, 0x3A, x + 8, y + 16, areaType, 1, true, false)
	elseif item.kind == "oneUp" then
		self:drawSpriteTile(chr, 0x3C, x, y, areaType, 1, false, false)
		self:drawSpriteTile(chr, 0x3E, x + 8, y, areaType, 1, false, false)
	else
		self:drawSpriteTile(chr, 0x3C, x, y, areaType, 2, false, false)
		self:drawSpriteTile(chr, 0x3E, x + 8, y, areaType, 2, false, false)
	end
end

function Renderer:drawFireball(fireball, cameraX: number, areaType: number, frame: number)
	local x = math.floor(fireball.x - cameraX)
	local y = 32 + math.floor(fireball.y)
	local chr = self.spriteData.mario
	local tile = if math.floor(frame / 4) % 2 == 0 then 0x3C else 0x3E
	self:drawSpriteTile(chr, tile, x, y, areaType, 2, false, false, 1024)
end

function Renderer:drawHud(state)
	for row = 0, 31 do
		buffer.copy(self.pixels, row * STRIDE, self.blackRow, 0, STRIDE)
	end
	local bright = 0x30
	self:drawText(16, 5, if state.currentPlayer == 2 then "LUIGI" else "MARIO", bright)
	self:drawText(86, 5, "TOP", bright)
	self:drawText(137, 5, "X", bright)
	self:drawText(158, 5, "WORLD", bright)
	self:drawText(218, 5, "TIME", bright)
	self:drawText(16, 20, string.format("%06d", math.min(state.score or 0, 999999)), bright)
	self:drawText(79, 20, string.format("%06d", math.min(state.topScore or 0, 999999)), bright)
	self:drawText(137, 20, string.format("%02d", (state.coins or 0) % 100), bright)
	self:drawText(160, 20, string.format("%d-%d", state.world or 1, state.stage or 1), bright)
	self:drawText(218, 20, string.format("%03d", math.max(0, state.time or 0)), bright)
end

function Renderer:drawTitle(state, frame: number)
	self:clear(0x22)
	-- A small title vignette built from the original ground CHR/metatile tables.
	for x = 0, 15 do
		self:drawMeta(1, 0x69, x * 16, 208)
		self:drawMeta(1, 0x69, x * 16, 224)
	end
	for x = 0, 5 do
		self:drawMeta(1, if x == 0 then 0x05 elseif x == 5 then 0x08 else 0x06, 5 * 16 + x * 16, 160)
	end
	for x = 0, 2 do
		self:drawMeta(1, if x == 0 then 0x80 elseif x == 2 then 0x82 else 0x81, 28 + x * 16, 54)
	end
	for y = 0, 2 do
		self:drawMeta(1, if y == 0 then 0x10 elseif y == 1 then 0x14 else 0x14, 218, 160 + y * 16)
	end
	self:drawRect(0, 0, W, 32, 0x0F)
	self:drawText(40, 39, "SUPER", 0x30, 2)
	self:drawText(22, 58, "MARIO BROS.", 0x28, 2)
	self:drawText(62, 105, "WORLD 1-1", 0x30)
	local selector = if state.menuIndex == 1 then ">" else " "
	self:drawText(40, 137, selector .. "1 PLAYER GAME", 0x30)
	selector = if state.menuIndex == 2 then ">" else " "
	self:drawText(40, 152, selector .. "2 PLAYER GAME", 0x30)
	self:drawText(52, 191, "1985 NINTENDO", 0x30)
	-- Logo-side Mario, using the authentic sprite CHR.
	local tile = if math.floor(frame / 10) % 2 == 0 then 0x00 else 0x04
	self:drawSpriteTile(self.spriteData.mario, tile, 190, 116, 1, 0, false, false, 2048)
	self:drawSpriteTile(self.spriteData.mario, tile + 2, 198, 116, 1, 0, false, false, 2048)
end

function Renderer:drawStageCard(state)
	self:drawRect(0, 0, W, H, 0x0F)
	self:drawText(84, 91, "WORLD", 0x30)
	self:drawText(95, 108, string.format("%d-%d", state.world or 1, state.stage or 1), 0x30)
	self:drawText(85, 130, string.format("X %02d", state.lives or 3), 0x30)
end

function Renderer:drawOverlay(text: string, y: number)
	self:drawRect(32, y - 7, 192, 22, 0x0F)
	local x = math.floor((W - #text * 6) / 2)
	self:drawText(x, y, text, 0x30)
end

function Renderer:draw(state)
	if not self.image then
		return
	end
	local frame = state.frame or 0
	if state.mode == "title" then
		self:drawTitle(state, frame)
	elseif state.mode == "intro" then
		self:drawStageCard(state)
	elseif state.mode == "gameOver" then
		self:clear(0x0F)
		self:drawText(94, 99, "GAME OVER", 0x30)
		self:drawText(52, 130, "PRESS START", 0x30)
	elseif state.mode == "victory" then
		self:clear(0x0F)
		self:drawText(76, 68, "THANK YOU", 0x30)
		self:drawText(66, 84, "MARIO!", 0x30)
		self:drawText(34, 120, "YOUR QUEST IS OVER", 0x30)
		self:drawText(52, 149, "THE END", 0x30)
	elseif state.level then
		local level = state.level
		local areaType = level.areaType
		local bg = level.backgroundColor or Data.BGColor[areaType + 1] or 0x0F
		self:clear(bg)
		local cameraX = math.floor(state.cameraX or 0)
		for _, vine in ipairs(state.vines or {}) do
			if vine.active and vine.x + 16 >= cameraX and vine.x <= cameraX + W then
				self:drawVine(vine, cameraX, areaType)
			end
		end
		local startCol = math.max(0, math.floor(cameraX / 16))
		local endCol = math.min(level.width - 1, startCol + 17)
		for worldCol = startCol, endCol do
			local col = level.map[worldCol + 1]
			if col then
				local screenX = worldCol * 16 - cameraX
				for row = 0, 12 do
					local tile = col[row + 1] or 0
					if tile ~= 0 then
						self:drawMeta(areaType, tile, screenX, 32 + row * 16, nil, bg, level.style)
					end
				end
			end
		end
		for _, coin in ipairs(level.coins or {}) do
			if coin.alive ~= false and coin.x + 16 >= cameraX and coin.x <= cameraX + W then
				local tile = coin.tile or 0xC2
				local col = math.floor(coin.x / 16) + 1
				local row = math.floor(coin.y / 16) + 1
				if level.map[col] and level.map[col][row] == tile then
					self:drawMeta(areaType, tile, coin.x, 32 + coin.y, cameraX, bg, level.style)
				end
			end
		end
		for _, enemy in ipairs(state.enemies or {}) do
			if enemy.x + 32 >= cameraX and enemy.x <= cameraX + W then
				self:drawEnemy(enemy, cameraX, areaType, frame)
			end
		end
		for _, item in ipairs(state.items or {}) do
			if item.alive ~= false and item.x + 24 >= cameraX and item.x <= cameraX + W then
				self:drawPowerup(item, cameraX, areaType, frame)
			end
		end
		for _, fireball in ipairs(state.fireballs or {}) do
			if fireball.alive and fireball.x + 16 >= cameraX and fireball.x <= cameraX + W then
				self:drawFireball(fireball, cameraX, areaType, frame)
			end
		end
		for _, effect in ipairs(state.effects or {}) do
			if effect.timer > 0 then
				self:drawText(math.floor(effect.x - cameraX), math.floor(32 + effect.y), effect.text, 0x30)
			end
		end
		if state.player and state.mode ~= "dying" then
			self:drawMario(state.player, cameraX, areaType, frame)
		end
		self:drawHud(state)
		if state.mode == "paused" then
			self:drawOverlay("PAUSE", 112)
		elseif state.mode == "flagpole" then
			self:drawOverlay("", 112)
		elseif state.mode == "stageClear" then
			self:drawOverlay("COURSE CLEAR", 105)
		elseif state.mode == "dying" then
			self:drawOverlay("", 112)
		end
		if state.introFrames and state.introFrames > 0 then
			self:drawRect(0, 32, W, H - 32, bg)
			self:drawText(84, 93, "WORLD", 0x30)
			self:drawText(96, 110, string.format("%d-%d", state.world, state.stage), 0x30)
		end
	end
	self.image:WritePixelsBuffer(Vector2.new(0, 0), Vector2.new(W, H), self.pixels)
end

function Renderer:addTouchControls(onChange)
	if not game:GetService("UserInputService").TouchEnabled then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "TouchControls"
	folder.Parent = self.canvas
	local map = {
		{ "Left", 12, 190, "<" }, { "Right", 46, 190, ">" },
		{ "Run", 171, 190, "B" }, { "Jump", 211, 190, "A" },
	}
	for _, spec in ipairs(map) do
		local name, x, y, text = spec[1], spec[2], spec[3], spec[4]
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.fromOffset(32, 32)
		button.Position = UDim2.fromOffset(x, y)
		button.BackgroundColor3 = Color3.fromRGB(24, 26, 36)
		button.BackgroundTransparency = 0.25
		button.BorderSizePixel = 0
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 18
		button.Font = Enum.Font.Code
		button.AutoButtonColor = true
		button.Parent = folder
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				onChange(name, true)
			end
		end)
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				onChange(name, false)
			end
		end)
		button.MouseLeave:Connect(function()
			onChange(name, false)
		end)
	end
	self.touchButtons = folder
	return folder
end

return Renderer
