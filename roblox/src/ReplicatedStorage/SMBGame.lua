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
		items = {},
		fireballs = {},
		effects = {},
	}
	self.buttons = {}
	self.pressed = {}
	self.accumulator = 0
	self.flagpoleFrames = 0
	self.transitionFrames = 0
	self.timerFrames = 0
	self.fireCooldown = 0
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

function Game:_award(points)
	self.state.score = clampScore(self.state.score + points)
	self.state.topScore = math.max(self.state.topScore, self.state.score)
end

function Game:_addCoin()
	self.state.coins += 1
	self:_award(200)
	if self.state.coins >= 100 then
		self.state.coins = 0
		self.state.lives += 1
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

function Game:_loadStage(world, stage, pointer, entrancePage, preservePower)
	local retainedPower = if preservePower and self.state.player then self.state.player.power or 0 else 0
	world = math.clamp(math.floor(world), 1, 8)
	stage = math.clamp(math.floor(stage), 1, 4)
	pointer = pointer or World.getStagePointer(world, stage)
	local areaIndex = World.findAreaIndex(world, pointer) or stage
	local level = World.build(pointer, world, stage, {
		areaIndex = areaIndex,
		entrancePage = entrancePage or 0,
		hardMode = world >= 5 and (world > 5 or stage >= 3),
		primaryHardMode = world >= 5,
	})
	self.state.world = world
	self.state.stage = stage
	self.state.level = level
	self.state.enemies = level.enemies
	self.state.items = {}
	self.state.fireballs = {}
	self.state.effects = {}
	self.state.time = START_TIME
	self.timerFrames = 0
	self.fireCooldown = 0
	self.state.cameraX = 0

	local startX = math.clamp((entrancePage or 0) * 256 + 32, 16, math.max(16, level.width * 16 - 32))
	local floorY = surfaceAt(level, startX + PLAYER_WIDTH / 2)
	if level.entrance == 2 then
		startX = math.max(startX, 48)
	end
	local spawnHeight = if retainedPower > 0 then 32 else 16
	self.state.player = {
		x = startX,
		y = floorY - spawnHeight,
		vx = 0,
		vy = 0,
		facing = 1,
		power = retainedPower,
		onGround = true,
		crouching = false,
		starFrames = 0,
		invulnFrames = 0,
	}
	self.state.introFrames = 100
	self.state.mode = "intro"
end

function Game:_startNewGame()
	self.state.score = 0
	self.state.coins = 0
	self.state.lives = 3
	self.state.topScore = math.max(self.state.topScore or 0, 0)
	self:_loadStage(1, 1)
end

function Game:_loseLife()
	self.state.lives -= 1
	if self.state.lives <= 0 then
		self.state.mode = "gameOver"
		self.state.level = nil
		self.state.player = nil
		self.state.enemies = {}
		self.state.items = {}
		self.state.fireballs = {}
		return
	end
	self:_loadStage(self.state.world, self.state.stage, self.state.level.pointer, nil, false)
end

function Game:_startStageClear()
	if self.state.mode == "stageClear" or self.state.mode == "victory" then
		return
	end
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

function Game:_advanceStage()
	local world = self.state.world
	local stage = self.state.stage + 1
	if stage > 4 then
		stage = 1
		world += 1
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
			-- Vines are not yet climbable in this runtime; retain a useful
			-- power-up reward rather than leaving the block inert.
			kind = "mushroom"
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
	if block.kind == "brick" and (player.power or 0) > 0 then
		level.map[column + 1][row + 1] = 0
		block.active = false
		self:_award(50)
		self:_addEffect(column * 16, row * 16, "50")
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
		return
	end
	self.state.mode = "dying"
	self.transitionFrames = 75
	player.vx = 0
	player.vy = -3
end

function Game:_updateEnemies()
	local level = self.state.level
	for _, enemy in ipairs(self.state.enemies or {}) do
		if enemy.alive then
			if enemy.state == "squashed" then
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
			elseif enemy.static or enemy.state == "pipePlant" then
				-- Pipe plants are drawn in place; they currently do not damage
				-- the player while hidden in their pipe.
			else
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
	if not forceKill and enemy.state == "shell" and stomp then
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
		if enemy.alive and enemy.state ~= "dead" and enemy.state ~= "squashed" and enemy.state ~= "pipePlant" and not enemy.static then
			local eHeight = if enemy.type == 45 then 32 else 16
			if overlaps(player.x + 1, player.y + 1, PLAYER_WIDTH - 2, pHeight - 2, enemy.x + 1, enemy.y + 1, 14, eHeight - 2) then
				if player.starFrames > 0 then
					self:_killEnemy(enemy, 200, false, true)
				elseif player.vy > 0 and previousBottom <= enemy.y + 8 then
					self:_killEnemy(enemy, 100, true)
					player.vy = -3.4
					player.onGround = false
				elseif enemy.state == "shell" then
					enemy.state = "movingShell"
					enemy.vx = if player.x < enemy.x then 4 else -4
					self:_award(100)
				else
					self:_damagePlayer()
					if self.state.mode == "dying" then
					return
				end
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
					self:_addEffect(item.x, item.y, "1UP")
				else
					self:_award(1000)
				end
				self:_addEffect(item.x, item.y, "1000")
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
				if fireball.alive and enemy.alive and enemy.state ~= "pipePlant" and overlaps(fireball.x, fireball.y, 8, 8, enemy.x, enemy.y, 16, 24) then
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
			self:_loadStage(targetWorld, targetStage, pipe.targetPointer, pipe.entrancePage or 0, true)
			return true
		end
	end
	return false
end

function Game:_updatePlayer()
	local player = self.state.player
	local level = self.state.level
	local pressed = self.pressed
	if pressed.pause or pressed.start then
		self.state.mode = "paused"
		return
	end

	local oldHeight = playerHeight(player)
	local wantsCrouch = self.buttons.down == true and player.power > 0 and player.onGround
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

	if self:_tryWarp() then
		return
	end
	if self.fireCooldown > 0 then
		self.fireCooldown -= 1
	end
	if self.buttons.run and player.power >= 2 and self.fireCooldown <= 0 then
		self:_spawnFireball()
	end

	local direction = (if self.buttons.right then 1 else 0) - (if self.buttons.left then 1 else 0)
	if direction ~= 0 then
		player.facing = direction
		local maxSpeed = if self.buttons.run then 3.15 else 2.35
		local acceleration = if self.buttons.run then 0.18 else 0.14
		player.vx = math.clamp(player.vx + direction * acceleration, -maxSpeed, maxSpeed)
	else
		local friction = if player.onGround then 0.18 else 0.06
		if math.abs(player.vx) <= friction then
			player.vx = 0
		else
			player.vx -= if player.vx > 0 then friction else -friction
		end
	end

	if (pressed.jump or (self.buttons.jump and player.onGround)) and player.onGround then
		player.vy = -5.5
		player.onGround = false
	end
	local previousBottom = player.y + height
	local gravity = if level.water then 0.16 else 0.28
	if player.vy < 0 and self.buttons.jump then
		gravity *= 0.68
	end
	player.vy = math.min(player.vy + gravity, 7)
	self:_resolvePlayerMotion(player, player.vx, player.vy)

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
	if level.flagX and player.x + PLAYER_WIDTH >= level.flagX then
		self:_startFlagpole()
		return
	elseif level.castleX and player.x >= level.castleX + 80 then
		self:_startStageClear()
		return
	elseif player.x >= level.endX then
		self:_startStageClear()
		return
	end

	local maxCamera = math.max(0, level.width * 16 - 256)
	self.state.cameraX = math.clamp(player.x - 112, 0, maxCamera)
	self.timerFrames += 1
	if self.timerFrames >= 60 then
		self.timerFrames = 0
		self.state.time = math.max(0, self.state.time - 1)
		if self.state.time == 0 then
			self.state.mode = "dying"
			self.transitionFrames = 75
		end
	end
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
