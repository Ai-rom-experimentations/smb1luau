--!nonstrict
-- A local, frame-stepped SMB1 runtime. The level/object tables remain source-driven;
-- this module supplies the first playable single-player rules layer.
local World = require(script.Parent:WaitForChild("SMBWorld"))
local Data = require(script.Parent:WaitForChild("SMBData"))

local Game = {}
Game.__index = Game

local STEP = 1 / 60
local PLAYER_WIDTH = 12
local START_TIME = 400
local TIMER_INTERVAL_FRAMES = 24
local TIMER_BY_SETTING = { 400, 300, 200 }
local ENTRANCE_Y = { [0] = 0, [1] = 32, [2] = 176, [3] = 80, [4] = 0, [5] = 0, [6] = 176, [7] = 176 }
local HALFWAY_PAGES = {
	{ 5, 6, 4, 0 }, { 6, 5, 7, 0 }, { 6, 6, 4, 0 }, { 6, 6, 4, 0 },
	{ 6, 6, 4, 0 }, { 6, 6, 6, 0 }, { 6, 5, 7, 0 }, { 0, 0, 0, 0 },
}
local MAX_SCORE = 999999

local function clampScore(score)
	return math.clamp(score, 0, MAX_SCORE)
end

local function tileIsSolid(level, column, row)
	if column < 0 or column >= level.width then
		return true
	end
	if row < 0 or row >= 13 then
		return false
	end
	local columnData = level.map[column + 1]
	local tileId = columnData and columnData[row + 1] or 0
	if tileId == 0 then
		return false
	end
	local definition = Data.Metatiles[tileId + 1]
	return definition ~= nil and bit32.band(definition[6] or 0, 0x01) ~= 0
end

local function solidAt(level, x, y)
	if y < 0 then
		return false
	end
	return tileIsSolid(level, math.floor(x / 16), math.floor(y / 16))
end

local function playerHeight(player)
	if player.crouching then
		return 16
	end
	return if (player.power or 0) > 0 then 32 else 16
end

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
	return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

local function surfaceAt(level, worldX)
	local column = math.clamp(math.floor(worldX / 16), 0, level.width - 1)
	local row = 12
	while row >= 0 and not tileIsSolid(level, column, row) do
		row -= 1
	end
	if row < 0 then
		return 160
	end
	while row > 0 and tileIsSolid(level, column, row - 1) do
		row -= 1
	end
	return row * 16
end

function Game.new()
	local self = setmetatable({}, Game)
	self.state = {
		mode = "title",
		frame = 0,
		menuIndex = 1,
		world = 1,
		stage = 1,
		lives = 3,
		score = 0,
		topScore = 0,
		coins = 0,
		time = START_TIME,
		cameraX = 0,
		currentPlayer = 1,
		numberOfPlayers = 1,
		players = nil,
		checkpointPage = 0,
		items = {},
		fireballs = {},
		vines = {},
		effects = {},
	}
	self.buttons = {}
	self.pressed = {}
	self.accumulator = 0
	self.flagpoleFrames = 0
	self.transitionFrames = 0
	self.timerFrames = 0
	self.fireCooldown = 0
	self.bridgeCollapseTimer = 0
	self.bridgeCollapseStep = 0
	return self
end

function Game:setButton(name, isDown)
	local wasDown = self.buttons[name] == true
	self.buttons[name] = isDown == true
	if isDown and not wasDown then
		self.pressed[name] = true
	end
end

function Game:getState()
	return self.state
end

function Game:_syncActiveProfile()
	local profiles = self.state.players
	local profile = profiles and profiles[self.state.currentPlayer]
	if not profile then
		return
	end
	profile.lives = self.state.lives
	profile.score = self.state.score
	profile.coins = self.state.coins
	if self.state.player then
		profile.power = self.state.player.power or 0
	end
end

function Game:_award(points)
	self.state.score = clampScore(self.state.score + points)
	self.state.topScore = math.max(self.state.topScore, self.state.score)
	self:_syncActiveProfile()
end

function Game:_addCoin()
	self.state.coins += 1
	self:_award(200)
	if self.state.coins >= 100 then
		self.state.coins = 0
		self.state.lives += 1
		self:_syncActiveProfile()
	end
end

function Game:_addEffect(x, y, text, points)
	table.insert(self.state.effects, {
		x = x,
		y = y,
		text = text or tostring(points or ""),
		timer = 42,
		vy = -0.5,
	})
end

function Game:_loadStage(world, stage, pointer, entrancePage, preservePower, powerOverride, preserveTimer)
	self:_syncActiveProfile()
	local previousTime = self.state.time or START_TIME
	local retainedPower = 0
	if preservePower then
		if powerOverride ~= nil then
			retainedPower = powerOverride
		elseif self.state.player then
			retainedPower = self.state.player.power or 0
		else
			local profile = self.state.players and self.state.players[self.state.currentPlayer]
			retainedPower = profile and profile.power or 0
		end
	end

	world = math.clamp(math.floor(world), 1, 8)
	stage = math.clamp(math.floor(stage), 1, 4)
	pointer = pointer or World.getStagePointer(world, stage)
	local areaIndex = World.findAreaIndex(world, pointer) or stage
	local level = World.build(pointer, world, stage, {
		areaIndex = areaIndex,
		entrancePage = entrancePage or 0,
		hardMode = world >= 5 and (world > 5 or stage >= 3),
		primaryHardMode = self.state.primaryHardMode == true,
	})
	self.state.world = world
	self.state.stage = stage
	self.state.level = level
	self.state.enemies = level.enemies
	self.state.items = {}
	self.state.fireballs = {}
	self.state.vines = {}
	self.state.effects = {}
	local timerSetting = level.gameTimerSetting or 0
	self.state.time = if preserveTimer then previousTime
		elseif timerSetting > 0 then (TIMER_BY_SETTING[timerSetting] or START_TIME)
		else previousTime
	self.state.hurryUp = self.state.time <= 100
	self.timerFrames = 0
	self.fireCooldown = 0
	local maxCamera = math.max(0, level.width * 16 - 256)
	self.state.cameraX = math.clamp((entrancePage or 0) * 256, 0, maxCamera)
	self.state.checkpointPage = entrancePage or 0
	self.state.halfwayPage = HALFWAY_PAGES[world][stage]
	self.bridgeCollapseTimer = 0
	self.bridgeCollapseStep = 0

	local startX = math.clamp((entrancePage or 0) * 256 + 40, 16, math.max(16, level.width * 16 - 32))
	local floorY = surfaceAt(level, startX + PLAYER_WIDTH / 2)
	local spawnHeight = if retainedPower > 0 then 32 else 16
	local spawnY = ENTRANCE_Y[level.entrance] or 0
	if level.entrance == 2 or level.entrance >= 6 then
		spawnY = floorY - spawnHeight
	end
	local onGround = math.abs((spawnY + spawnHeight) - floorY) <= 2
	self.state.player = {
		x = startX,
		y = spawnY,
		vx = 0,
		vy = 0,
		facing = 1,
		power = retainedPower,
		currentPlayer = self.state.currentPlayer,
		onGround = onGround,
		crouching = false,
		climbing = false,
		vineIndex = nil,
		swimCooldown = 0,
		starFrames = 0,
		invulnFrames = 0,
	}
	self:_syncActiveProfile()
	self.state.introFrames = 100
	self.state.mode = "intro"
end

function Game:_startNewGame()
	self.state.numberOfPlayers = if self.state.menuIndex == 2 then 2 else 1
	self.state.currentPlayer = 1
	self.state.players = {
		{ lives = 3, score = 0, coins = 0, power = 0 },
		{ lives = 3, score = 0, coins = 0, power = 0 },
	}
	self.state.score = 0
	self.state.coins = 0
	self.state.lives = 3
	self.state.time = START_TIME
	self.state.hurryUp = false
	self.state.primaryHardMode = false
	self.state.topScore = math.max(self.state.topScore or 0, 0)
	self.state.player = nil
	self.state.level = nil
	self.state.enemies = {}
	self.state.checkpointPage = 0
	self:_loadStage(1, 1)
end

function Game:_continueWithPlayer(playerNumber)
	local profile = self.state.players and self.state.players[playerNumber]
	if not profile or profile.lives <= 0 then
		return false
	end
	local world = self.state.world
	local stage = self.state.stage
	local pointer = self.state.level and self.state.level.pointer or World.getStagePointer(world, stage)
	local checkpoint = self.state.checkpointPage or 0
	self.state.currentPlayer = playerNumber
	self.state.lives = profile.lives
	self.state.score = profile.score
	self.state.coins = profile.coins
	self:_loadStage(world, stage, pointer, checkpoint, true, profile.power)
	return true
end

function Game:_loseLife()
	self:_syncActiveProfile()
	self.state.lives -= 1
	local profile = self.state.players and self.state.players[self.state.currentPlayer]
	if profile then
		profile.lives = self.state.lives
		profile.power = 0
	end

	if self.state.lives <= 0 then
		local otherPlayer = if self.state.currentPlayer == 1 then 2 else 1
		local otherProfile = self.state.players and self.state.players[otherPlayer]
		if self.state.numberOfPlayers == 2 and otherProfile and otherProfile.lives > 0 then
			self:_continueWithPlayer(otherPlayer)
			return
		end
		self.state.mode = "gameOver"
		self.state.level = nil
		self.state.player = nil
		self.state.enemies = {}
		self.state.items = {}
		self.state.fireballs = {}
		self.state.vines = {}
		return
	end
	local pointer = self.state.level and self.state.level.pointer or World.getStagePointer(self.state.world, self.state.stage)
	self:_loadStage(self.state.world, self.state.stage, pointer, self.state.checkpointPage or 0, false)
end

function Game:_startStageClear()
	if self.state.mode == "stageClear" or self.state.mode == "victory" then
		return
	end
	local timeBonus = math.max(0, self.state.time or 0) * 50
	if timeBonus > 0 then
		self:_award(timeBonus)
		self.state.time = 0
	end
	self:_syncActiveProfile()
	self.state.mode = "stageClear"
	self.transitionFrames = 110
end

function Game:_startFlagpole()
	if self.state.mode ~= "playing" then
		return
	end
	self.state.mode = "flagpole"
	self.flagpoleFrames = 60
	local player = self.state.player
	local bonus
	local collisionY = player.y + 32
	if collisionY >= 0x90 then
		bonus = 100
	elseif collisionY >= 0x68 then
		bonus = 400
	elseif collisionY >= 0x50 then
		bonus = 800
	elseif collisionY >= 0x22 then
		bonus = 2000
	else
		bonus = 5000
	end
	self:_award(bonus)
	self:_addEffect(player.x, player.y, tostring(bonus), bonus)
end

function Game:_activateAxe()
	local level = self.state.level
	local player = self.state.player
	if level.axeUsed then
		return
	end
	level.axeUsed = true
	local axeColumn = math.floor(level.axeX / 16) + 1
	if level.map[axeColumn] then
		level.map[axeColumn][7] = 0
	end
	if player then
		player.vx = 0
		player.vy = 0
		player.autoControl = "collapse"
	end
	self.bridgeCollapseTimer = 0
	self.bridgeCollapseStep = 0
end

function Game:_collapseBridgeTick()
	local level = self.state.level
	if not level or not level.axeUsed then
		return
	end
	self.bridgeCollapseTimer += 1
	if self.bridgeCollapseTimer < 4 then
		return
	end
	self.bridgeCollapseTimer = 0

	local step = self.bridgeCollapseStep
	if step == 1 and level.chainX then
		local column = math.floor(level.chainX / 16) + 1
		if level.map[column] then
			for row = 8, 13 do
				level.map[column][row] = 0
			end
		end
	elseif step >= 2 and step <= 14 then
		local offset = 14 - step
		for _, bridge in ipairs(level.bridges or {}) do
			local column = bridge.x + offset + 1
			if level.map[column] then
				level.map[column][bridge.row + 1] = 0
			end
		end
	elseif step == 15 then
		for _, enemy in ipairs(level.enemies) do
			if enemy.alive and enemy.type == 45 then
				enemy.state = "falling"
				enemy.vy = 0
			end
		end
	end
	self.bridgeCollapseStep += 1
end

function Game:_updateAxeVictory(player, level)
	if player.autoControl == "collapse" then
		-- The NES enters a dedicated victory mode after the axe is touched:
		-- Mario stays put while the bridge collapses, rather than falling with it.
		player.vx = 0
		player.vy = 0
		player.onGround = true
		self:_collapseBridgeTick()

		local bowserPending = false
		for _, enemy in ipairs(self.state.enemies or {}) do
			if enemy.type == 45 and enemy.alive then
				if enemy.state == "falling" then
					enemy.vy = math.min((enemy.vy or 0) + 0.24, 5)
					enemy.y += enemy.vy
					if enemy.y > 224 then
						enemy.alive = false
					else
						bowserPending = true
					end
				else
					enemy.vx = 0
					enemy.vy = 0
					bowserPending = true
				end
			end
		end

		if self.bridgeCollapseStep >= 16 and not bowserPending then
			for _, enemy in ipairs(self.state.enemies or {}) do
				enemy.alive = false
			end
			player.autoControl = "walk"
		end
	elseif player.autoControl == "walk" then
		player.facing = 1
		player.vx = 1
		player.vy = 0
		player.x = math.min(player.x + 1, level.width * 16 - PLAYER_WIDTH)
		local maxCamera = math.max(0, level.width * 16 - 256)
		self.state.cameraX = math.clamp(player.x - 112, 0, maxCamera)
		local targetX = if level.exitPipeX then level.exitPipeX + 24 else level.endX
		if player.x >= targetX then
			self:_startStageClear()
		end
	end

	self:_syncActiveProfile()
	return true
end

function Game:_advanceStage()
	local level = self.state.level
	local world = self.state.world
	local stage = self.state.stage + 1
	if stage > 4 then
		stage = 1
		world += 1
	end
	if level and level.axeUsed and world > self.state.world then
		if self.state.world == 8 then
			self.state.mode = "victory"
			self.state.level = nil
			return
		end
		world = self.state.world + 1
		stage = 1
	end
	if world > 8 then
		self.state.mode = "victory"
		self.state.level = nil
		return
	end
	self:_loadStage(world, stage, nil, nil, true)
end

function Game:_spawnBlockReward(reward, column, row)
	if reward == "coin" or reward == "hiddenCoin" or reward == "multiCoin" then
		self:_addCoin()
		self:_addEffect(column * 16, row * 16, "200")
	elseif reward == "oneUp" then
		table.insert(self.state.items, {
			kind = "oneUp",
			x = column * 16,
			y = row * 16 - 16,
			vx = 1.1,
			vy = -1,
			alive = true,
			emergeFrames = 16,
		})
	elseif reward ~= nil then
		local kind = reward
		if kind == "power" then
			kind = if (self.state.player.power or 0) == 0 then "mushroom" else "flower"
		elseif kind == "vine" then
			local columnData = self.state.vines
			local height = 48 * math.clamp(#columnData + 1, 1, 2)
			table.insert(columnData, {
				x = column * 16 + 8,
				bottomY = row * 16,
				height = 0,
				maxHeight = height,
				growthFrames = 0,
				active = true,
			})
			return
		end
		if kind == "mushroom" or kind == "star" or kind == "flower" then
			table.insert(self.state.items, {
				kind = kind,
				x = column * 16,
				y = row * 16 - 16,
				vx = if kind == "star" then 1.8 else 1.1,
				vy = -1,
				alive = true,
				emergeFrames = 16,
			})
		end
	end
end

function Game:_hitBlock(column, row)
	local level = self.state.level
	local blockColumn = level.blocks[column + 1]
	local block = blockColumn and blockColumn[row + 1]
	if not block or not block.active then
		return
	end
	local player = self.state.player
	if block.kind == "breakableBrick" then
		if (player.power or 0) > 0 then
			level.map[column + 1][row + 1] = 0
			block.active = false
			self:_award(50)
			self:_addEffect(column * 16, row * 16, "50")
		end
		return
	end

	if block.kind == "brick" and block.reward == "multiCoin" then
		if block.multiCoinUntil == nil then
			block.multiCoinUntil = self.state.frame + 11
		elseif self.state.frame > block.multiCoinUntil then
			block.active = false
			level.map[column + 1][row + 1] = 0xC4
			return
		end
		self:_spawnBlockReward(block.reward, column, row)
		return
	end

	block.active = false
	if block.kind ~= "usedBlock" then
		level.map[column + 1][row + 1] = 0xC4
		self:_spawnBlockReward(block.reward, column, row)
	end
end

function Game:_resolvePlayerMotion(player, dx, dy)
	local level = self.state.level
	local oldX = player.x
	local oldY = player.y
	local height = playerHeight(player)
	local newX = oldX + dx
	if dx > 0 then
		local edge = newX + PLAYER_WIDTH - 1
		for y = player.y + 2, player.y + height - 2, 7 do
			if solidAt(level, edge, y) then
				newX = math.floor(edge / 16) * 16 - PLAYER_WIDTH
				player.vx = 0
				break
			end
		end
	elseif dx < 0 then
		local edge = newX
		for y = player.y + 2, player.y + height - 2, 7 do
			if solidAt(level, edge, y) then
				newX = (math.floor(edge / 16) + 1) * 16
				player.vx = 0
				break
			end
		end
	end
	player.x = math.clamp(newX, 0, level.width * 16 - PLAYER_WIDTH)

	local newY = oldY + dy
	player.onGround = false
	if dy < 0 then
		if newY < 0 then
			newY = 0
			player.vy = 0
		end
		local row = math.floor(newY / 16)
		local leftColumn = math.floor((player.x + 2) / 16)
		local rightColumn = math.floor((player.x + PLAYER_WIDTH - 2) / 16)
		for column = leftColumn, rightColumn do
			if tileIsSolid(level, column, row) then
				newY = (row + 1) * 16
				player.vy = 0
				self:_hitBlock(column, row)
			end
		end
	elseif dy >= 0 then
		local bottom = newY + height
		local row = math.floor((bottom - 0.001) / 16)
		local leftColumn = math.floor((player.x + 2) / 16)
		local rightColumn = math.floor((player.x + PLAYER_WIDTH - 2) / 16)
		for column = leftColumn, rightColumn do
			if tileIsSolid(level, column, row) then
				newY = row * 16 - height
				player.vy = 0
				player.onGround = true
			end
		end
	end
	player.y = newY
	return oldX, oldY
end

function Game:_spawnFireball()
	local player = self.state.player
	if not player or player.power < 2 or self.fireCooldown > 0 then
		return
	end
	local height = playerHeight(player)
	table.insert(self.state.fireballs, {
		x = player.x + (player.facing > 0 and PLAYER_WIDTH or -8),
		y = player.y + math.floor(height / 2),
		vx = player.facing * 3.6,
		vy = -1.5,
		bounces = 0,
		alive = true,
	})
	self.fireCooldown = 18
end

function Game:_damagePlayer()
	local player = self.state.player
	if player.starFrames > 0 or player.invulnFrames > 0 then
		return
	end
	if player.power > 0 then
		local height = playerHeight(player)
		player.power = 0
		player.crouching = false
		player.y += height - 16
		player.invulnFrames = 100
		self:_syncActiveProfile()
		return
	end
	self.state.mode = "dying"
	self.transitionFrames = 75
	player.vx = 0
	player.vy = -3
end

function Game:_updatePipePlant(enemy)
	if enemy.moveTimer > 0 then
		enemy.moveTimer -= 1
		return
	end
	if not enemy.moving then
		local player = self.state.player
		if enemy.vy > 0 and player
			and math.abs((player.x + PLAYER_WIDTH / 2) - enemy.x) < 0x21 then
			return
		end
		enemy.vy = -enemy.vy
		enemy.moving = true
		enemy.hidden = false
	end
	if self.state.frame % 2 == 0 then
		return
	end

	enemy.y += enemy.vy
	local targetY = if enemy.vy < 0 then enemy.upY else enemy.downY
	if (enemy.vy < 0 and enemy.y <= targetY) or (enemy.vy > 0 and enemy.y >= targetY) then
		enemy.y = targetY
		enemy.moving = false
		enemy.moveTimer = 64
		enemy.hidden = enemy.vy > 0
	end
end

function Game:_updateEnemies()
	local level = self.state.level
	for _, enemy in ipairs(self.state.enemies or {}) do
		if enemy.alive then
			if enemy.state == "pipePlant" then
				self:_updatePipePlant(enemy)
			elseif enemy.state == "squashed" then
				enemy.timer = (enemy.timer or 24) - 1
				if enemy.timer <= 0 then
					enemy.alive = false
				end
			elseif enemy.state == "shell" then
				enemy.timer = (enemy.timer or 600) - 1
				if enemy.timer <= 0 then
					enemy.state = "walk"
				enemy.vx = if enemy.x > self.state.player.x then -0.55 else 0.55
					enemy.vy = 0
				end
			elseif not enemy.static then
				if enemy.state ~= "movingShell" and enemy.state ~= "shell" then
					enemy.vy = math.min((enemy.vy or 0) + 0.24, 5)
				end
				local oldX = enemy.x
				local nextX = enemy.x + (enemy.vx or 0)
				local enemyHeight = if enemy.type == 45 then 32 else 16
				local checkY = enemy.y + enemyHeight - 2
				if solidAt(level, nextX + (enemy.vx > 0 and 14 or 1), checkY) then
					enemy.vx = -(enemy.vx or 0)
					nextX = oldX
				end
				enemy.x = math.clamp(nextX, 0, level.width * 16 - 16)
				if enemy.vy and enemy.vy ~= 0 then
					local nextY = enemy.y + enemy.vy
					if enemy.vy > 0 and (solidAt(level, enemy.x + 3, nextY + enemyHeight - 1) or solidAt(level, enemy.x + 13, nextY + enemyHeight - 1)) then
						local row = math.floor((nextY + enemyHeight - 1) / 16)
						enemy.y = row * 16 - enemyHeight
						enemy.vy = 0
					elseif enemy.vy < 0 and solidAt(level, enemy.x + 8, nextY) then
						enemy.vy = 0
					else
						enemy.y = nextY
					end
				end
				if enemy.y > 224 then
					enemy.alive = false
				end
			end
		end
	end
end

function Game:_killEnemy(enemy, points, stomp, forceKill)
	if enemy.type == 45 then
		if not forceKill then
			return
		end
		enemy.health = math.max(0, (enemy.health or 5) - 1)
		if enemy.health == 0 then
			enemy.state = "defeated"
			enemy.vx = 0
			enemy.vy = -2
			self:_award(5000)
			self:_addEffect(enemy.x, enemy.y, "5000")
		end
		return
	end

	if stomp and (enemy.state == "shell" or enemy.state == "movingShell") then
		enemy.state = "shell"
		enemy.vx = 0
		enemy.vy = 0
		enemy.timer = 600
		self:_award(points or 1000)
		self:_addEffect(enemy.x, enemy.y, tostring(points or 1000))
		return
	end
	if not forceKill and (enemy.type == 0 or enemy.type == 2 or enemy.type == 3) then
		if enemy.state ~= "movingShell" then
			enemy.state = "shell"
			enemy.vx = 0
			enemy.vy = 0
			enemy.timer = 600
			self:_award(points or 100)
			self:_addEffect(enemy.x, enemy.y, tostring(points or 100))
			return
		end
	end
	if stomp then
		enemy.state = "squashed"
		enemy.timer = 24
		enemy.vy = 0
	else
		enemy.alive = false
	end
	self:_award(points or 100)
	self:_addEffect(enemy.x, enemy.y, tostring(points or 100))
end

function Game:_checkPlayerEnemyCollisions(previousBottom)
	local player = self.state.player
	local pHeight = playerHeight(player)
	for _, enemy in ipairs(self.state.enemies or {}) do
		local isPlant = enemy.type == 13 or enemy.state == "pipePlant"
		if enemy.alive and enemy.state ~= "dead" and enemy.state ~= "squashed"
			and not (enemy.type == 45 and (enemy.state == "falling" or enemy.state == "defeated"))
			and not enemy.static and not (isPlant and enemy.hidden) then
			local enemyX = if isPlant then enemy.x - 8 else enemy.x
			local enemyY = if isPlant then enemy.y - 8 else enemy.y
			local enemyWidth = if isPlant then 16 else 14
			local enemyHeight = if isPlant or enemy.type == 45 then 32 else 16
			if overlaps(player.x + 1, player.y + 1, PLAYER_WIDTH - 2, pHeight - 2,
				enemyX + 1, enemyY + 1, enemyWidth, enemyHeight - 2) then
				if isPlant or enemy.type == 45 then
					if player.starFrames == 0 then
						self:_damagePlayer()
					end
				elseif player.starFrames > 0 then
					self:_killEnemy(enemy, 200, false, true)
				elseif player.vy > 0 and previousBottom <= enemyY + 8 then
					self:_killEnemy(enemy, 100, true)
					player.vy = -3.4
					player.onGround = false
				elseif enemy.state == "shell" then
					enemy.state = "movingShell"
					enemy.vx = if player.x < enemy.x then 4 else -4
					self:_award(100)
				else
					self:_damagePlayer()
				end
				if self.state.mode == "dying" then
					return
				end
			end
		end
	end
end

function Game:_updateItems()
	local level = self.state.level
	local player = self.state.player
	for _, item in ipairs(self.state.items) do
		if item.alive then
			if (item.emergeFrames or 0) > 0 then
				item.emergeFrames -= 1
				item.y -= 0.5
			else
				if not item.static then
					item.vy = math.min((item.vy or 0) + 0.22, 5)
					local nextX = item.x + (item.vx or 0)
					if solidAt(level, nextX + (item.vx > 0 and 14 or 1), item.y + 8) then
						item.vx = -(item.vx or 0)
					else
						item.x = nextX
					end
					local nextY = item.y + item.vy
					if item.vy > 0 and (solidAt(level, item.x + 2, nextY + 15) or solidAt(level, item.x + 14, nextY + 15)) then
						local row = math.floor((nextY + 15) / 16)
						item.y = row * 16 - 16
						if item.kind == "star" and (item.bounces or 0) < 4 then
						item.vy = -4.2
						item.bounces = (item.bounces or 0) + 1
					else
						item.vy = 0
					end
				else
					item.y = nextY
				end
			end
			end
			if overlaps(player.x, player.y, PLAYER_WIDTH, playerHeight(player), item.x, item.y, 16, 16) then
				item.alive = false
				local effectText = "1000"
				if item.kind == "mushroom" then
					if player.power == 0 then
						player.power = 1
						player.y -= 16
					end
					self:_award(1000)
				elseif item.kind == "flower" then
					if player.power == 0 then
						player.y -= 16
					end
					player.power = 2
					self:_award(1000)
				elseif item.kind == "star" then
					player.starFrames = 600
					self:_award(1000)
				elseif item.kind == "oneUp" then
					self.state.lives += 1
					effectText = "1UP"
				else
					self:_award(1000)
				end
				self:_syncActiveProfile()
				self:_addEffect(item.x, item.y, effectText)
			end
		end
	end
end

function Game:_updateCoins()
	local level = self.state.level
	local player = self.state.player
	local height = playerHeight(player)
	for _, coin in ipairs(level.coins or {}) do
		if coin.alive ~= false and overlaps(player.x, player.y, PLAYER_WIDTH, height, coin.x, coin.y, 16, 16) then
			coin.alive = false
			local column = math.floor(coin.x / 16) + 1
			local row = math.floor(coin.y / 16) + 1
			if level.map[column] and level.map[column][row] then
				level.map[column][row] = 0
			end
			self:_addCoin()
			self:_addEffect(coin.x, coin.y, "200")
		end
	end
end

function Game:_updateFireballs()
	local level = self.state.level
	for _, fireball in ipairs(self.state.fireballs) do
		if fireball.alive then
			fireball.vy = math.min((fireball.vy or 0) + 0.18, 4)
			local nextX = fireball.x + fireball.vx
			if solidAt(level, nextX + (fireball.vx > 0 and 5 or 1), fireball.y + 5) then
				fireball.alive = false
			else
				fireball.x = nextX
			end
			local nextY = fireball.y + fireball.vy
			if fireball.vy > 0 and solidAt(level, fireball.x + 4, nextY + 8) then
				local row = math.floor((nextY + 8) / 16)
				fireball.y = row * 16 - 8
				fireball.vy = -3.2
				fireball.bounces += 1
				if fireball.bounces > 3 then
					fireball.alive = false
				end
			else
				fireball.y = nextY
			end
			for _, enemy in ipairs(self.state.enemies) do
				if fireball.alive and enemy.alive and enemy.state ~= "pipePlant"
					and enemy.state ~= "falling" and enemy.state ~= "defeated"
					and overlaps(fireball.x, fireball.y, 8, 8, enemy.x, enemy.y, 16, 24) then
					self:_killEnemy(enemy, 200, false, true)
					fireball.alive = false
				end
			end
			if fireball.x < 0 or fireball.x > level.width * 16 then
				fireball.alive = false
			end
		end
	end
end

function Game:_tryWarp()
	local player = self.state.player
	local level = self.state.level
	if not self.buttons.down or not player.onGround then
		return false
	end
	for _, pipe in ipairs(level.pipes or {}) do
		local centered = math.abs((player.x + PLAYER_WIDTH / 2) - (pipe.x + pipe.width / 2)) <= 8
		local standingOnTop = math.abs((player.y + playerHeight(player)) - pipe.y) <= 2
		if pipe.warp and pipe.targetPointer ~= nil and centered and standingOnTop then
			local targetWorld = math.clamp(pipe.targetWorld or self.state.world, 1, 8)
			local targetStage = self.state.stage
			for candidate = 1, 4 do
				if World.getStagePointer(targetWorld, candidate) == pipe.targetPointer then
					targetStage = candidate
					break
				end
			end
			self:_loadStage(targetWorld, targetStage, pipe.targetPointer, pipe.entrancePage or 0, true, nil, true)
			return true
		end
	end
	return false
end

function Game:_updateVines()
	for _, vine in ipairs(self.state.vines or {}) do
		if vine.active and vine.height < vine.maxHeight then
			vine.growthFrames += 1
			if vine.growthFrames >= 2 then
				vine.growthFrames = 0
				vine.height = math.min(vine.height + 1, vine.maxHeight)
			end
		end
	end
end

function Game:_findVineAtPlayer(player)
	local height = playerHeight(player)
	local centerX = player.x + PLAYER_WIDTH / 2
	for index, vine in ipairs(self.state.vines or {}) do
		if vine.active and vine.height >= 8 then
			local topY = vine.bottomY - vine.height
			if math.abs(centerX - vine.x) <= 10 and player.y + height >= topY - 8 and player.y <= vine.bottomY then
				return index, vine
			end
		end
	end
	return nil, nil
end

function Game:_updatePlayer()
	local player = self.state.player
	local level = self.state.level
	local pressed = self.pressed
	if player.autoControl then
		self:_updateAxeVictory(player, level)
		return
	end
	if pressed.pause or pressed.start then
		self.state.mode = "paused"
		return
	end

	self:_updateVines()
	local oldHeight = playerHeight(player)
	local wantsCrouch = self.buttons.down == true and player.power > 0 and player.onGround
		and not player.climbing and not player.autoControl
	if wantsCrouch ~= player.crouching then
		if wantsCrouch then
			player.crouching = true
		elseif not solidAt(level, player.x + 4, player.y - 8) and not solidAt(level, player.x + 9, player.y - 8) then
			player.crouching = false
		end
	end
	local height = playerHeight(player)
	if oldHeight > height then
		player.y += oldHeight - height
	elseif oldHeight < height then
		player.y -= height - oldHeight
	end

	if not player.climbing and not player.autoControl and self.buttons.up then
		local vineIndex, vine = self:_findVineAtPlayer(player)
		if vine then
			player.climbing = true
			player.vineIndex = vineIndex
			player.vx = 0
			player.vy = 0
			player.onGround = false
			player.x = vine.x - PLAYER_WIDTH / 2
		end
	end
	if not player.climbing and not player.autoControl and self:_tryWarp() then
		return
	end
	if self.fireCooldown > 0 then
		self.fireCooldown -= 1
	end
	if not player.climbing and not player.autoControl and self.buttons.run and player.power >= 2 and self.fireCooldown <= 0 then
		self:_spawnFireball()
	end

	local previousBottom = player.y + height
	if player.climbing then
		local vine = self.state.vines[player.vineIndex]
		if not vine or not vine.active then
			player.climbing = false
			player.vineIndex = nil
		else
			local topY = math.max(0, vine.bottomY - vine.height)
			local bottomY = math.max(topY, vine.bottomY - height)
			local climbDirection = (if self.buttons.down then 1 else 0) - (if self.buttons.up then 1 else 0)
			player.x = vine.x - PLAYER_WIDTH / 2
			player.vx = 0
			player.vy = 0
			if pressed.jump then
				player.climbing = false
				player.vineIndex = nil
				player.vy = -3.5
			elseif climbDirection ~= 0 then
				player.y = math.clamp(player.y + climbDirection * 1.25, topY, bottomY)
			end
			if player.climbing and player.y <= topY then
				player.climbing = false
				player.vineIndex = nil
				player.onGround = false
				player.vy = -0.5
			elseif player.climbing and player.y >= bottomY then
				player.climbing = false
				player.vineIndex = nil
			end
		end
	else
		local direction = if player.autoControl then 1
			else (if self.buttons.right then 1 else 0) - (if self.buttons.left then 1 else 0)
		if player.autoControl then
			player.facing = 1
			player.vx = 1.5
		elseif direction ~= 0 then
			player.facing = direction
			local running = self.buttons.run == true
			local maxSpeed = if running then 2.5 else 1.5
			if player.vx * direction < 0 then
				if math.abs(player.vx) <= 11 / 16 then
					player.vx = 0
				else
					player.vx += direction * (if running then 0.11 else 0.075)
				end
			else
				local acceleration = if running then 0.07 else 0.04
				player.vx = math.clamp(player.vx + direction * acceleration, -maxSpeed, maxSpeed)
			end
		elseif player.onGround then
			local friction = 0.056
			if math.abs(player.vx) <= friction then
				player.vx = 0
			else
				player.vx -= if player.vx > 0 then friction else -friction
			end
		end

		if not player.autoControl then
			if player.swimCooldown > 0 then
				player.swimCooldown -= 1
			end
			if pressed.jump and player.onGround then
				player.vy = if level.water then -2 else -4
				player.onGround = false
			elseif pressed.jump and level.water and player.swimCooldown <= 0 then
				player.vy = -2
				player.onGround = false
				player.swimCooldown = 20
			end
		end

		local gravity
		if level.water then
			gravity = if player.vy < 0 and self.buttons.jump then 0.05 else 0.04
		else
			gravity = if player.vy < 0 and self.buttons.jump then 0.125 else 0.4375
		end
		player.vy = math.min(player.vy + gravity, if level.water then 3.5 else 5)
		self:_resolvePlayerMotion(player, player.vx, player.vy)
	end

	if player.starFrames > 0 then
		player.starFrames -= 1
	end
	if player.invulnFrames > 0 then
		player.invulnFrames -= 1
	end
	self:_updateEnemies()
	self:_checkPlayerEnemyCollisions(previousBottom)
	if self.state.mode ~= "playing" then
		return
	end
	self:_updateItems()
	self:_updateCoins()
	self:_updateFireballs()

	for i = #self.state.effects, 1, -1 do
		local effect = self.state.effects[i]
		effect.timer -= 1
		effect.y += effect.vy or 0
		if effect.timer <= 0 then
			table.remove(self.state.effects, i)
		end
	end

	if player.y > 224 then
		self.state.mode = "dying"
		self.transitionFrames = 75
		return
	end
	if level.axeX and not level.axeUsed
		and overlaps(player.x, player.y, PLAYER_WIDTH, playerHeight(player), level.axeX, 6 * 16, 16, 16) then
		self:_activateAxe()
		return
	end
	if level.flagX and player.x + PLAYER_WIDTH >= level.flagX then
		self:_startFlagpole()
		return
	elseif level.castleX and not level.axeX and player.x >= level.castleX + 80 then
		self:_startStageClear()
		return
	elseif not level.axeX and player.x >= level.endX then
		self:_startStageClear()
		return
	end

	local maxCamera = math.max(0, level.width * 16 - 256)
	self.state.cameraX = math.clamp(player.x - 112, 0, maxCamera)
	local halfwayPage = self.state.halfwayPage or 0
	if halfwayPage > 0 and math.floor(self.state.cameraX / 256) >= halfwayPage then
		self.state.checkpointPage = math.max(self.state.checkpointPage or 0, halfwayPage)
	end

	self.timerFrames += 1
	if self.timerFrames >= TIMER_INTERVAL_FRAMES then
		self.timerFrames = 0
		self.state.time = math.max(0, self.state.time - 1)
		if self.state.time == 100 and not self.state.hurryUp then
			self.state.hurryUp = true
		end
		if self.state.time == 0 then
			self.state.mode = "dying"
			self.transitionFrames = 75
		end
	end
	self:_syncActiveProfile()
end

function Game:_tick()
	local state = self.state
	state.frame += 1
	local mode = state.mode

	if mode == "title" then
		if self.pressed.up or self.pressed.down then
			state.menuIndex = if state.menuIndex == 1 then 2 else 1
		end
		if self.pressed.start or self.pressed.jump then
			self:_startNewGame()
		end
	elseif mode == "intro" then
		state.introFrames = (state.introFrames or 0) - 1
		if state.introFrames <= 0 then
			state.mode = "playing"
		end
	elseif mode == "playing" then
		self:_updatePlayer()
	elseif mode == "paused" then
		if self.pressed.pause or self.pressed.start then
			state.mode = "playing"
		end
	elseif mode == "dying" then
		self.transitionFrames -= 1
		if state.player then
			state.player.y += state.player.vy or 0
			state.player.vy = (state.player.vy or 0) + 0.2
		end
		if self.transitionFrames <= 0 then
			self:_loseLife()
		end
	elseif mode == "flagpole" then
		self.flagpoleFrames -= 1
		if state.player then
			state.player.y = math.min(state.player.y + 1.8, 160)
		end
		if self.flagpoleFrames <= 0 then
			self:_startStageClear()
		end
	elseif mode == "stageClear" then
		self.transitionFrames -= 1
		if self.transitionFrames <= 0 then
			self:_advanceStage()
		end
	elseif mode == "gameOver" or mode == "victory" then
		if self.pressed.start then
			self:_startNewGame()
		end
	end

	self.pressed = {}
end

function Game:step(deltaTime)
	self.accumulator = math.min(self.accumulator + math.clamp(deltaTime, 0, 0.25), 0.25)
	local ticks = 0
	while self.accumulator >= STEP and ticks < 8 do
		self:_tick()
		self.accumulator -= STEP
		ticks += 1
	end
end

return Game
