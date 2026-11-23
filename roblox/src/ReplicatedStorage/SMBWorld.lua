--!nonstrict
-- Source-driven SMB1Base world/area decoder.
-- Area object bytes and enemy bytes are decoded from SMBData, not hand-authored maps.
local Data = require(script.Parent:WaitForChild("SMBData"))

local World = {}
local AREA_BASE = { 0, 3, 25, 28 }
local ENEMY_BASE = { 31, 6, 28, 0 }
local AREA_TYPE_NAMES = { "water", "ground", "underground", "castle" }
local AREA_TERRAIN = { 0x69, 0x54, 0x52, 0x62 }
local AREA_BRICK = { 0x22, 0x51, 0x52, 0x52 }
local AREA_SOLID = { 0x69, 0x61, 0x61, 0x62 }
local AREA_COIN = { 0xC3, 0xC2, 0xC2, 0xC2 }
local BACK_OFFSETS = { 0, 0x30, 0x60 }
local FORE_OFFSETS = { 0, 0x0D, 0x1A }
local PIPE_INTRO_POINTER = 0x29

local QUESTION_TILES = { 0xC1, 0xC0, 0x5F, 0x60 }
local GROUND_BRICKS = { 0x55, 0x56, 0x57, 0x58, 0x59 }
local OTHER_BRICKS = { 0x5A, 0x5B, 0x5C, 0x5D, 0x5E }
local CASTLE = {
	{ 0x00, 0x45, 0x45, 0x45, 0x00 },
	{ 0x00, 0x48, 0x47, 0x46, 0x00 },
	{ 0x45, 0x49, 0x49, 0x49, 0x45 },
	{ 0x47, 0x47, 0x4A, 0x47, 0x47 },
	{ 0x47, 0x47, 0x4B, 0x47, 0x47 },
	{ 0x49, 0x49, 0x49, 0x49, 0x49 },
	{ 0x47, 0x4A, 0x47, 0x4A, 0x47 },
	{ 0x47, 0x4B, 0x47, 0x4B, 0x47 },
	{ 0x47, 0x47, 0x47, 0x47, 0x47 },
	{ 0x4A, 0x47, 0x4A, 0x47, 0x4A },
	{ 0x4B, 0x47, 0x4B, 0x47, 0x4B },
}

local VALID_ENEMIES = {
	[0x00] = true, [0x02] = true, [0x03] = true, [0x05] = true,
	[0x06] = true, [0x07] = true, [0x08] = true, [0x0A] = true,
	[0x0B] = true, [0x0C] = true, [0x0D] = true, [0x0E] = true,
	[0x0F] = true, [0x10] = true, [0x11] = true, [0x12] = true,
	[0x14] = true, [0x15] = true, [0x16] = true, [0x17] = true,
	[0x18] = true, [0x2D] = true,
}

local function areaLabel(pointer)
	local areaType = bit32.band(bit32.rshift(pointer, 5), 0x03)
	local low = bit32.band(pointer, 0x1F)
	local index = AREA_BASE[areaType + 1] + low + 1
	return Data.AreaOrder[index], areaType
end

local function enemyLabel(pointer)
	local areaType = bit32.band(bit32.rshift(pointer, 5), 0x03)
	local low = bit32.band(pointer, 0x1F)
	local index = ENEMY_BASE[areaType + 1] + low + 1
	return Data.EnemyOrder[index]
end

local function blankColumn()
	return table.create(13, 0)
end

local function blankMetadataColumn()
	return table.create(13)
end

local function getCell(map, x, row)
	if x < 0 or x >= #map or row < 0 or row >= 13 then
		return 0
	end
	return map[x + 1][row + 1] or 0
end

local function put(map, width, x, row, tile, overwrite)
	if x < 0 or x >= width or row < 0 or row >= 13 then
		return
	end
	local column = map[x + 1]
	if overwrite or column[row + 1] == 0 or column[row + 1] == nil then
		column[row + 1] = tile
	end
end

local function putHorizontal(map, width, x, row, tile, length, overwrite)
	for offset = 0, length - 1 do
		put(map, width, x + offset, row, tile, overwrite)
	end
end

local function putVertical(map, width, x, row, tile, length, overwrite)
	for offset = 0, length - 1 do
		put(map, width, x, row + offset, tile, overwrite)
	end
end

local function copyEnvironment(environment)
	return {
		terrain = environment.terrain,
		scenery = environment.scenery,
		foreground = environment.foreground,
		backgroundControl = environment.backgroundControl,
		cloudOverride = environment.cloudOverride,
	}
end

local function decodeAreaObjects(bytes)
	local firstHeader = bytes[1] or 0
	local secondHeader = bytes[2] or 0
	local backgroundControl = bit32.band(firstHeader, 0x07)
	local foreground = if backgroundControl >= 4 then 0 else backgroundControl
	if backgroundControl < 4 then
		backgroundControl = 0
	end

	local cloudOverride = if bit32.rshift(secondHeader, 6) == 3 then 3 else 0
	local style = if cloudOverride ~= 0 then 0 else bit32.rshift(secondHeader, 6)
	local environment = {
		terrain = bit32.band(secondHeader, 0x0F),
		scenery = bit32.band(bit32.rshift(secondHeader, 4), 0x03),
		foreground = foreground,
		backgroundControl = backgroundControl,
		cloudOverride = cloudOverride,
	}
	local header = {
		terrain = environment.terrain,
		scenery = environment.scenery,
		foreground = environment.foreground,
		backgroundControl = environment.backgroundControl,
		cloudOverride = environment.cloudOverride,
		style = style,
		entrance = bit32.band(bit32.rshift(firstHeader, 3), 0x07),
		gameTimerSetting = bit32.rshift(firstHeader, 6),
		endColumn = 0,
		attributeEvents = {},
	}

	local commands = {}
	local page = 0
	local ordinal = 0
	local index = 3
	while index + 1 <= #bytes do
		local first = bytes[index]
		local second = bytes[index + 1]
		if first == 0xFD then
			break
		end
		if bit32.band(second, 0x80) ~= 0 then
			page += 1
		end

		local column = bit32.rshift(first, 4)
		local row = bit32.band(first, 0x0F)
		local x = page * 16 + column
		ordinal += 1
		local object

		if row == 0x0D then
			if bit32.band(second, 0x40) == 0 and bit32.band(second, 0x80) == 0 then
				-- Row $0d, D6 clear, and no page increment is an absolute page select.
				page = bit32.band(second, 0x1F)
				x = page * 16 + column
			elseif bit32.band(second, 0x40) ~= 0 then
				object = {
					kind = "special13", id = bit32.band(second, 0x3F),
					x = x, row = row, byte = second, length = 0, ordinal = ordinal,
				}
			end
		elseif row == 0x0E then
			local isBackgroundChange = bit32.band(second, 0x40) == 0
			if isBackgroundChange then
				environment.terrain = bit32.band(second, 0x0F)
				environment.scenery = bit32.band(bit32.rshift(second, 4), 0x03)
			else
				local control = bit32.band(second, 0x07)
				environment.foreground = if control < 4 then control else 0
				environment.backgroundControl = if control >= 4 then control else 0
			end
			local event = {
				x = x,
				ordinal = ordinal,
				terrain = environment.terrain,
				scenery = environment.scenery,
				foreground = environment.foreground,
				backgroundControl = environment.backgroundControl,
				cloudOverride = environment.cloudOverride,
			}
			table.insert(header.attributeEvents, event)
			object = { kind = "attribute", x = x, row = row, byte = second, ordinal = ordinal }
		elseif row == 0x0C then
			object = {
				kind = "special12", id = bit32.band(bit32.rshift(second, 4), 0x07),
				x = x, row = row, byte = second, length = bit32.band(second, 0x0F), ordinal = ordinal,
			}
		elseif row == 0x0F then
			object = {
				kind = "special15", id = bit32.band(bit32.rshift(second, 4), 0x07),
				x = x, row = row, byte = second, length = bit32.band(second, 0x0F), ordinal = ordinal,
			}
		else
			local typeBits = bit32.band(second, 0x70)
			if typeBits ~= 0 then
				local id = bit32.rshift(typeBits, 4)
				if id == 7 and bit32.band(second, 0x08) ~= 0 then
					-- The high-pipe selector is repurposed for real/warp pipes.
					id = 0
				end
				object = {
					kind = "large", id = id, x = x, row = row, byte = second,
					length = bit32.band(second, 0x0F), ordinal = ordinal,
				}
			else
				object = {
					kind = "small", id = bit32.band(second, 0x0F), x = x,
					row = row, byte = second, length = 0, ordinal = ordinal,
				}
			end
		end

		if object then
			table.insert(commands, object)
				header.endColumn = math.max(header.endColumn, x)
		end
		index += 2
	end

	return commands, header
end

local function drawBackdrop(level, initialEnvironment, events)
	local environment = copyEnvironment(initialEnvironment)
	local eventIndex = 1
	table.sort(events, function(a, b)
		if a.x == b.x then
			return a.ordinal < b.ordinal
		end
		return a.x < b.x
	end)

	for x = 0, level.width - 1 do
		while eventIndex <= #events and events[eventIndex].x <= x do
			local event = events[eventIndex]
			environment.terrain = event.terrain
			environment.scenery = event.scenery
			environment.foreground = event.foreground
			environment.backgroundControl = event.backgroundControl
			environment.cloudOverride = event.cloudOverride
			eventIndex += 1
		end

		if environment.scenery > 0 then
			local page = math.floor(x / 16)
			local index = BACK_OFFSETS[environment.scenery] + (page % 3) * 16 + (x % 16)
			local code = Data.BackSceneryData[index + 1] or 0
			if code ~= 0 then
				local row = bit32.rshift(code, 4)
				local tileGroup = (bit32.band(code, 0x0F) - 1) * 3
				for part = 0, 2 do
					local tile = Data.BackSceneryMetatiles[tileGroup + part + 1] or 0
					if tile ~= 0 then
						put(level.map, level.width, x, row + part, tile, false)
					end
				end
			end
		end

		if environment.foreground > 0 and environment.foreground <= 3 then
			local offset = FORE_OFFSETS[environment.foreground]
			for row = 0, 12 do
				local tile = Data.ForeSceneryData[offset + row + 1] or 0
				if tile ~= 0 then
					put(level.map, level.width, x, row, tile, true)
				end
			end
		end

		local terrainTile = AREA_TERRAIN[level.areaType + 1]
		if level.areaType == 0 and level.world == 8 then
			terrainTile = 0x62
		elseif environment.cloudOverride ~= 0 then
			terrainTile = 0x88
		end
		local topMask = Data.TerrainRenderBits[environment.terrain * 2 + 1] or 0
		local bottomMask = Data.TerrainRenderBits[environment.terrain * 2 + 2] or 0
		for row = 0, 12 do
			local mask = if row < 8 then topMask else bottomMask
			if environment.cloudOverride ~= 0 and row > 0 then
				mask = bit32.band(mask, 0x08)
			end
			local bitIndex = if row < 8 then row else row - 8
			if bit32.band(mask, bit32.lshift(1, bitIndex)) ~= 0 then
				local tile = terrainTile
				if level.areaType == 2 and row >= 11 then
					tile = 0x54
				end
				put(level.map, level.width, x, row, tile, true)
			end
		end
	end

	level.backgroundColor = environment.backgroundControl >= 4
		and ({ [4] = 0x0F, [5] = 0x22, [6] = 0x0F, [7] = 0x0F })[environment.backgroundControl]
		or Data.BGColor[level.areaType + 1]
	level.initialBackgroundControl = initialEnvironment.backgroundControl
end

local function drawFlagpole(level, x)
	for row = 0, 9 do
		put(level.map, level.width, x, row, if row == 0 then 0x24 else 0x25, true)
	end
	put(level.map, level.width, x, 10, 0x61, true)
	level.flagX = x * 16
end

local function buildMap(level, commands, header)
	local maxColumn = header.endColumn
	for _, object in ipairs(commands) do
		if object.kind ~= "attribute" then
			local extra = (object.length or 0) + 2
			if object.kind == "special15" and object.id == 2 then
				extra = 6
			elseif object.kind == "special13" and object.id == 4 then
				extra = 13
			elseif object.kind == "large" and (object.id == 0 or object.id == 7) then
				extra = 3
			end
			maxColumn = math.max(maxColumn, object.x + extra)
		end
	end
	local width = math.clamp(math.ceil((maxColumn + 16) / 16) * 16, 32, 640)
	level.width = width
	level.map = table.create(width)
	level.blocks = table.create(width)
	level.itemTypes = table.create(width)
	for x = 1, width do
		level.map[x] = blankColumn()
		level.blocks[x] = blankMetadataColumn()
		level.itemTypes[x] = blankMetadataColumn()
	end
	level.pipes = {}
	level.coins = {}
	level.flagX = nil
	level.axeX = nil
	level.bridgeX = nil
	level.castleX = nil
	level.endX = (width - 3) * 16

	drawBackdrop(level, {
		terrain = header.terrain,
		scenery = header.scenery,
		foreground = header.foreground,
		backgroundControl = header.backgroundControl,
		cloudOverride = header.cloudOverride,
	}, header.attributeEvents)

	local function addBlock(x, row, tile, kind, reward)
		put(level.map, width, x, row, tile, true)
		if x >= 0 and x < width and row >= 0 and row < 13 then
			level.blocks[x + 1][row + 1] = { kind = kind, reward = reward, originalTile = tile, active = true }
			level.itemTypes[x + 1][row + 1] = reward
		end
	end

	local function drawPipe(object, warp)
		local x, row = object.x, math.clamp(object.row, 0, 11)
		local shaftRows = math.clamp(bit32.band(object.length, 0x07), 1, 8)
		local topLeft, topRight = if warp then 0x10 else 0x12, if warp then 0x11 else 0x13
		put(level.map, width, x, row, topLeft, true)
		put(level.map, width, x + 1, row, topRight, true)
		for dy = 1, shaftRows do
			put(level.map, width, x, row + dy, 0x14, true)
			put(level.map, width, x + 1, row + dy, 0x15, true)
		end
		local pipe = {
			x = x * 16,
			y = row * 16,
			width = 32,
			height = (shaftRows + 1) * 16,
			warp = warp,
			targetPointer = nil,
			targetWorld = level.world - 1,
		}
		table.insert(level.pipes, pipe)
		if not warp and (level.world > 1 or level.areaIndex > 1) then
			table.insert(level.enemies, {
				type = 13, x = x * 16 + 8, y = row * 16 - 32,
				vx = 0, vy = 0, alive = true, state = "pipePlant", static = true,
				pipeY = row * 16 - 32,
			})
		end
	end

	local function drawHorizontalStructure(x, row, length, left, middle, right)
		for offset = 0, length - 1 do
			local tile = if offset == 0 then left elseif offset == length - 1 then right else middle
			put(level.map, width, x + offset, row, tile, true)
		end
	end

	local function drawLedge(object)
		local length = object.length + 1
		if level.style == 1 then
			local half = math.floor(object.length / 2)
			for offset = 0, length - 1 do
				local tile = if offset == 0 then 0x19 elseif offset == length - 1 then 0x1B else 0x1A
				put(level.map, width, object.x + offset, object.row, tile, true)
			end
			local stem = object.x + math.clamp(half + 1, 1, math.max(1, length - 1))
			put(level.map, width, stem, object.row + 1, 0x4F, true)
			for row = object.row + 2, 12 do
				put(level.map, width, stem, row, 0x50, true)
			end
		elseif level.style == 2 then
			local x, row = object.x, object.row
			put(level.map, width, x, row, 0x64, true)
			if object.length >= 1 then put(level.map, width, x, row + 1, 0x65, true) end
			if object.length >= 2 then
				putVertical(level.map, width, x, row + 2, 0x66, object.length - 1, true)
			end
		else
			for offset = 0, length - 1 do
				local atStart = offset == 0 and object.x ~= 0
				local atEnd = offset == length - 1
				local tile = if atStart then 0x16 elseif atEnd then 0x18 else 0x17
				put(level.map, width, object.x + offset, object.row, tile, true)
				if not atEnd and not atStart then
					for row = object.row + 1, 12 do
						put(level.map, width, object.x + offset, row, 0x4C, false)
					end
				end
			end
		end
	end

	for _, object in ipairs(commands) do
		local x, row, id, length = object.x, object.row, object.id, object.length or 0
		if object.kind == "small" then
			if id <= 3 then
				local reward = ({ "power", "coin", "hiddenCoin", "oneUp" })[id + 1]
				addBlock(x, row, QUESTION_TILES[id + 1], "question", reward)
			elseif id >= 4 and id <= 8 then
				local bricks = if level.areaType == 1 then GROUND_BRICKS else OTHER_BRICKS
				local reward = ({ "mushroom", "vine", "star", "multiCoin", "oneUp" })[id - 3]
				addBlock(x, row, bricks[id - 3], "brick", reward)
			elseif id == 9 then
				put(level.map, width, x, row, 0x6B, true)
				put(level.map, width, x, row + 1, 0x6C, true)
			elseif id == 10 then
				addBlock(x, row, 0xC4, "usedBlock", nil)
			elseif id == 11 then
				put(level.map, width, x, row, 0x67, true)
				put(level.map, width, x, row + 1, 0x68, true)
			end
		elseif object.kind == "large" then
			if id == 0 or id == 7 then
				drawPipe(object, id == 0)
			elseif id == 1 then
				drawLedge(object)
			elseif id == 2 then
				local tile = if level.cloudOverride then 0x88 else AREA_BRICK[level.areaType + 1]
				putHorizontal(level.map, width, x, row, tile, length + 1, true)
			elseif id == 3 then
				putHorizontal(level.map, width, x, row, AREA_SOLID[level.areaType + 1], length + 1, true)
			elseif id == 4 then
				putHorizontal(level.map, width, x, row, AREA_COIN[level.areaType + 1], length + 1, true)
				for offset = 0, length do
					if x + offset >= 0 and x + offset < width then
						level.itemTypes[x + offset + 1][row + 1] = "coin"
					end
				end
			elseif id == 5 then
				putVertical(level.map, width, x, row, AREA_BRICK[level.areaType + 1], length + 1, true)
			elseif id == 6 then
				putVertical(level.map, width, x, row, AREA_SOLID[level.areaType + 1], length + 1, true)
			end
		elseif object.kind == "special12" then
			if id == 0 then
				for dx = 0, length do
					for y = 8, 12 do
						put(level.map, width, x + dx, y, if level.areaType == 0 then 0x87 else 0, true)
					end
				end
			elseif id == 1 then
				local tile = if length == 0 then 0x42 else 0x41
				putHorizontal(level.map, width, x, 0, tile, length + 1, true)
			elseif id >= 2 and id <= 4 then
				local railRow = if id == 2 then 6 elseif id == 3 then 7 else 9
				putHorizontal(level.map, width, x, railRow, 0x0B, length + 1, true)
				putHorizontal(level.map, width, x, railRow + 1, 0x63, length + 1, true)
			elseif id == 5 then
				for dx = 0, length do
					put(level.map, width, x + dx, 10, 0x86, true)
					put(level.map, width, x + dx, 11, 0x87, true)
					put(level.map, width, x + dx, 12, 0x87, true)
				end
			elseif id == 6 or id == 7 then
				putHorizontal(level.map, width, x, if id == 6 then 3 else 7, 0xC0, length + 1, true)
			end
		elseif object.kind == "special13" then
			if id == 1 then
				drawFlagpole(level, x)
			elseif id == 2 then
				put(level.map, width, x, 6, 0xC5, true)
				level.axeX = x * 16
			elseif id == 3 then
				putVertical(level.map, width, x, 7, 0x0C, 6, true)
			elseif id == 4 then
				putVertical(level.map, width, x, 8, 0x89, 5, true)
				level.bridgeX = x * 16
			end
		elseif object.kind == "special15" then
			if id == 0 then
				putVertical(level.map, width, x, 0, 0x40, 13, true)
			elseif id == 1 then
				putVertical(level.map, width, x, 1, 0x40, math.max(1, length + 1), true)
			elseif id == 2 then
				for y = 0, 10 do
					for dx = 0, 4 do
						put(level.map, width, x + dx, y, CASTLE[y + 1][dx + 1], true)
					end
				end
				level.castleX = x * 16
			elseif id == 3 then
				-- StaircaseObject starts with a one-block step at row 10, then
				-- raises each following column using StaircaseRowData in the source.
				local steps = math.clamp(length + 1, 1, 9)
				for step = 0, steps - 1 do
					local rowStart = math.max(3, 10 - step)
					for y = rowStart, 10 do
						put(level.map, width, x + step, y, 0x61, true)
					end
				end
			elseif id == 4 then
				-- Castle exit pipe: two-wide horizontal pipe with a vertical shaft.
				put(level.map, width, x, row, 0x1D, true)
				put(level.map, width, x + 1, row, 0x1C, true)
				for dx = 2, math.max(2, length + 1) do
					put(level.map, width, x + dx, row, 0x1E, true)
				end
				put(level.map, width, x, row + 1, 0x20, true)
				put(level.map, width, x + 1, row + 1, 0x1F, true)
			end
		end
	end

	for x = 0, width - 1 do
		for row = 0, 12 do
			local tile = getCell(level.map, x, row)
			if tile == 0xC2 or tile == 0xC3 then
				table.insert(level.coins, { x = x * 16, y = row * 16, tile = tile, alive = true })
			end
		end
	end

	level.endX = math.max(level.endX, (header.endColumn + 8) * 16)
	if level.flagX then
		level.endX = math.max(level.endX, level.flagX + 160)
	end
	if level.castleX then
		level.endX = math.max(level.endX, level.castleX + 112)
	end
	level.endX = math.min(level.endX, (width - 2) * 16)
end

local function pushEnemy(level, enemyType, x, y, extra)
	local enemy = {
		type = enemyType,
		x = x,
		y = y,
		vx = if x > 64 then -0.55 else 0.55,
		vy = 0,
		alive = true,
		state = "walk",
		static = false,
	}
	if extra then
		for key, value in pairs(extra) do enemy[key] = value end
	end
	table.insert(level.enemies, enemy)
end

local function decodeEnemies(level, pointer, worldIndex, hardMode, primaryHardMode)
	local name = enemyLabel(pointer)
	local bytes = if name then Data.EnemyAreas[name] else nil
	if not bytes then
		return
	end
	level.enemyAreaName = name
	local page = 0
	local index = 1
	while index + 1 <= #bytes do
		local first = bytes[index]
		local second = bytes[index + 1]
		if first == 0xFF then
			break
		end
		if bit32.band(second, 0x80) ~= 0 then
			page += 1
		end
		local row = bit32.band(first, 0x0F)
		if row == 0x0F then
			page = bit32.band(second, 0x3F)
			index += 2
		elseif row == 0x0E then
			local third = bytes[index + 2] or 0
			local targetWorld = bit32.rshift(third, 5)
			local link = {
				x = page * 256 + bit32.band(first, 0xF0),
					pointer = second,
				targetWorld = targetWorld + 1,
				entrancePage = bit32.band(third, 0x1F),
			}
			if targetWorld == worldIndex then
				table.insert(level.warps, link)
			end
			index += 3
		else
			local x = page * 256 + bit32.band(first, 0xF0)
			local y = bit32.band(first, 0x0F) * 16 - 32
			local enemyType = bit32.band(second, 0x3F)
			local hardModeOnly = bit32.band(second, 0x40) ~= 0
			if not hardModeOnly or hardMode then
				if enemyType >= 0x37 and enemyType <= 0x3E then
					local code = enemyType - 0x37
					local count = if bit32.band(code, 0x01) ~= 0 then 3 else 2
					local yPos = if bit32.band(code, 0x02) ~= 0 then 0x70 - 32 else 0xB0 - 32
					local kind = if code < 4 then (if primaryHardMode then 2 else 6) else 0
					for n = 0, count - 1 do
						pushEnemy(level, kind, x + n * 24, yPos, { group = true })
					end
				elseif VALID_ENEMIES[enemyType] and x < level.width * 16 then
					pushEnemy(level, enemyType, x, y)
				end
			end
			index += 2
		end
	end
end

local function connectWarps(level)
	for _, link in ipairs(level.warps) do
		local closest, closestDistance
		for _, pipe in ipairs(level.pipes) do
			local distance = math.abs(pipe.x - link.x)
			if not closestDistance or distance < closestDistance then
				closest, closestDistance = pipe, distance
			end
		end
		if closest and closestDistance <= 48 then
			closest.targetPointer = link.pointer
			closest.targetWorld = link.targetWorld
			closest.entrancePage = link.entrancePage
			closest.linkX = link.x
		end
		link.targetPointer = link.pointer
	end
end

function World.getWorldAreas(world)
	return Data.WorldAreas[math.clamp(math.floor(world), 1, 8)] or {}
end

function World.getAreaPointer(world, areaIndex)
	local areas = World.getWorldAreas(world)
	return areas[math.floor(areaIndex)]
end

function World.getWorldAreaCount(world)
	return #World.getWorldAreas(world)
end

function World.getStagePointer(world, stage)
	local requested = math.clamp(math.floor(stage), 1, 4)
	local seen = 0
	for _, pointer in ipairs(World.getWorldAreas(world)) do
		if pointer ~= PIPE_INTRO_POINTER then
			seen += 1
			if seen == requested then
				return pointer
			end
		end
	end
	return World.getWorldAreas(world)[1] or 0x25
end

function World.findAreaIndex(world, pointer)
	for index, candidate in ipairs(World.getWorldAreas(world)) do
		if candidate == pointer then
			return index
		end
	end
	return nil
end

function World.isPipeIntro(pointer)
	return pointer == PIPE_INTRO_POINTER
end

function World.getAreaLabel(pointer)
	local label = areaLabel(pointer)
	return label
end

function World.getEnemyLabel(pointer)
	return enemyLabel(pointer)
end

function World.build(pointer, world, stage, options)
	options = options or {}
	local label, areaType = areaLabel(pointer)
	if not label or not Data.Areas[label] then
		warn("SMB1: source area pointer is not in the exported table", pointer, label)
		pointer = 0x25
		label, areaType = areaLabel(pointer)
	end

	local bytes = Data.Areas[label]
	local commands, header = decodeAreaObjects(bytes)
	local level = {
		pointer = pointer,
		areaName = label,
		areaType = areaType,
		areaTypeName = AREA_TYPE_NAMES[areaType + 1],
		world = world,
		stage = stage,
		areaIndex = options.areaIndex or 1,
		entrancePage = options.entrancePage or 0,
		entrance = header.entrance,
		gameTimerSetting = header.gameTimerSetting,
		style = header.style,
		cloudOverride = header.cloudOverride ~= 0,
		water = areaType == 0,
		castle = areaType == 3,
		enemies = {},
		warps = {},
	}
	buildMap(level, commands, header)
	level.areaCommands = commands
	level.initialEnvironment = {
		terrain = header.terrain,
		scenery = header.scenery,
		foreground = header.foreground,
		backgroundControl = header.backgroundControl,
		cloudOverride = header.cloudOverride,
	}

	local sourceWorldIndex = math.clamp(math.floor(world) - 1, 0, 7)
	local hardMode = options.hardMode
	if hardMode == nil then
		hardMode = world >= 5 and (world > 5 or stage >= 3)
	end
	decodeEnemies(level, pointer, sourceWorldIndex, hardMode, options.primaryHardMode == true)
	connectWarps(level)
	level.isPipeIntro = World.isPipeIntro(pointer)
	return level
end

return World
