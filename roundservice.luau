local RS			= game:GetService('ReplicatedStorage')
local SSS			= game:GetService('ServerScriptService')
local Players		= game:GetService("Players")

local DataStore		= require(SSS.Server.Services.DataService)
local PlotService	= require(SSS.Server.Services.PlotService)
local NPC			= require(RS.Modules.NPC)
local Network		= require(RS.Modules.Network)
local Signal		= require(SSS.Server.Modules.Signals)
local Currency		= require(SSS.Server.Services.CurrencyService)
local SwordInfo		= require(RS.Modules.SwordInfo)
local Combat		= require(SSS.Server.Services.CombatService)

local GetPosition	= require(script.GetPosition)
local DeepClone		= require(script.DeepClone)

local cacheTemplate = {
	previousRun = {
		Wave = 0;
		MoneyEarned = 0;
		OfferExpired = false;
		Claimed = false;
	};
	currentRun = {
		CurrentWave = 0;
		AliveZombies = 0;
		TotalZombies = 0;
		KilledZombies = 0;
		CurrentZombiesSpawned = 0;
		TotalMoney = 0;
		IsBossWave = false;
		PlayerDeath = nil :: RBXScriptConnection?;
		npcCache = {};
	};
	baseCache = {};
}

local RoundSystem = {
	Matches = {};
	_cache = {} :: {[Player] : typeof(cacheTemplate)};
}

-- ======================================================
-- CONFIG
-- ======================================================

local config = {

	MinWeaponPower = 1,
	MinZombieSpawnDistance = 7;

	EndlessDifficulty = function(extraWaves)
		return 1 + (extraWaves ^ 1.05) * 0.25
	end,

	ZombieClasses = {
		[1] = { Normal = 3 };
		[2] = { Normal = 5; Fast = 1 };
		[5] = { Normal = 5; Tank = 3 };
		[15] = { Normal = 10; Tank = 3; Fast = 1 };
		[30] = { Normal = 10; Tank = 3; Fast = 3 };
	},

	WaveCheckpoints = {
		25, 50, 75, 100, 125, 150, 175, 200
	};

	BossWaves = {
		25, 50, 75, 100;
	};
	
	NPCScaling = {

		Health = function(base, wave)
			local multiplier

			if wave <= 15 then
				multiplier = 1 + wave * 0.15

			elseif wave <= 60 then
				local w = wave - 15
				multiplier = 3.25 + (w * w * 0.02)

			else
				local w = wave - 60
				multiplier = 35 + (1.12 ^ w)
			end

			return math.floor(base * multiplier)
		end,

		Damage = function(base, wave)
			local multiplier = 1 + math.min(wave * 0.025, 2.5)
			return math.floor(base * multiplier)
		end,

		Speed = function(base, wave)
			return base + math.floor(wave / 20)
		end,
	},

	_events = {
		RoundStarted  = {};
		RoundEnded    = {};
		WaveStarted   = {};
		WaveCleared   = {};
		ZombieKilled  = {};
		BossSpawned   = {};
		ProgressUpdate = {};
		ReviveOfferExpired = {};
		Revived = {};
		Claimed = {};
	},

	_event_names = {
		RoundStarted  = "RoundStarted";
		RoundEnded    = "RoundEnded";
		WaveStarted   = "WaveStarted";
		WaveCleared   = "WaveCleared";
		ZombieKilled  = "ZombieKilled";
		BossSpawned   = "BossSpawned";
		ProgressUpdate = "ProgressUpdate";
		ReviveOfferExpired = "ReviveOfferExpired";
		Revived = "Revived";
		Claimed = "Claimed";
	},
}

RoundSystem.Config = config

function RoundSystem.Toggle2xSpeed(plr)
	plr:SetAttribute('2xSpeed', not plr:GetAttribute('2xSpeed'))
	local match = getMatch(plr)
	for _, npc in match.npcCache do
		npc.Model.Humanoid.WalkSpeed = npc.Info.Speed * GetRoundSpeed(plr)
	end
end

-- ======================================================
-- EVENTS
-- ======================================================

function RoundSystem.Bind(eventName, callback)
	local list = config._events[eventName]
	assert(list, "Invalid event name: " .. tostring(eventName))
	table.insert(list, callback)

	return function()
		for i = #list, 1, -1 do
			if list[i] == callback then
				table.remove(list, i)
			end
		end
	end
end

local function notify(eventName, plr, ...)
	RS.Events.Update.RoundService[eventName]:FireClient(plr, ...)
	for _, callback in config._events[eventName] do
		task.defer(callback, {plr, ...})
	end
end

-- ======================================================
-- UTILITIES
-- ======================================================

local function hasValidWeapon(plr)
	local data = DataStore:GetData(plr)
	
	local equipped = 0
	local robuxEquipped = 0
	
	for _, v in data.Equipped do
		equipped += 1
		local info = SwordInfo[v.ItemId]
		if info.Robux then
			robuxEquipped += 1
		end
	end
	
	if equipped == 0 then
		return Network.Notification:FireClient(plr, 'No weapons equipped', Color3.new(1, 0, 0))
	elseif equipped == robuxEquipped then
		return Network.Notification:FireClient(plr, 'You have to equip at least one regular sword!', Color3.new(1, 0, 0))
	end
	
	return true
end

function GetRoundSpeed(plr)
	return plr:GetAttribute('2xSpeed') and 2 or 1
end

function CreateData(plr)
	if RoundSystem._cache[plr] then return RoundSystem._cache[plr] end
	RoundSystem._cache[plr] = DeepClone(cacheTemplate)
	return RoundSystem._cache[plr]
end

function CreateMatch(plr)
	local cache = RoundSystem._cache[plr] or CreateData(plr)

	local start_wave = 0
	local data = DataStore:GetData(plr)
	for wave = data.BaseData.HighestWave, 1, -1 do
		if not table.find(config.WaveCheckpoints, wave) then continue end
		start_wave = wave
		break
	end

	cache.currentRun = DeepClone(cacheTemplate.currentRun)
	cache.currentRun.CurrentWave = start_wave
	return cache.currentRun
end

function getMatch(plr)
	local cache = RoundSystem._cache[plr] or CreateData(plr)
	return cache.currentRun
end

function getPreviousMatch(plr)
	return RoundSystem._cache[plr] and RoundSystem._cache[plr].previousRun
end

local function getWaveComposition(wave)
	local bestWave = nil

	for definedWave in pairs(RoundSystem.Config.ZombieClasses) do
		if definedWave <= wave then
			if not bestWave or definedWave > bestWave then
				bestWave = definedWave
			end
		end
	end

	if not bestWave then return nil end

	local base = RoundSystem.Config.ZombieClasses[bestWave]
	local extraWaves = wave - bestWave
	local multiplier = RoundSystem.Config.EndlessDifficulty(extraWaves)

	return base, multiplier
end

local function getNextBossWave(currentWave)
	local nextWave = nil
	for _, wave in config.BossWaves do
		if wave <= currentWave then continue end
		if not nextWave or wave < nextWave then
			nextWave = wave
		end
	end
	return nextWave
end

local function RemoveBase(plr)
	if plr:HasTag('RemoveBaseDB') then return end
	plr:AddTag('RemoveBaseDB')

	local plot = PlotService:GetPlot(plr)
	if not plot then return end

	local cache = {}

	local cache = RoundSystem._cache[plr].baseCache
	cache[plot.Buttons] = plot.Buttons.Parent
	cache[plot.Swords] = plot.Swords.Parent
	cache[plot.ItemHolders] = plot.ItemHolders.Parent
	for _, spot in plot.ItemHolders:GetChildren() do
		spot.PressPart.CanQuery = false
	end

	plot.Buttons.Parent = RS.Cache
	plot.ItemHolders.Parent = RS.Cache
	plot.Swords.Parent = RS.Cache

	for _, v in plot.Walls:GetChildren() do
		v.CanCollide = true
	end
	for _, v in plot.Grid.Ramps:GetChildren() do
		v.CanCollide = true
	end

	task.delay(1, function() plr:RemoveTag('RemoveBaseDB') end)
end

local function AddBase(plr, plot, destroySwords)
	if plr:HasTag('AddBaseDB') then return end
	plr:AddTag('AddBaseDB')

	for obj, parent in RoundSystem._cache[plr].baseCache do
		if destroySwords then
			if obj.Name == 'Swords' then
				for _, v in obj:GetChildren() do v:Destroy() end
			elseif obj.Name == 'ItemHolders' then
				for _, v in obj:GetChildren() do
					if not v:FindFirstChildWhichIsA('Model') then continue end
					v:FindFirstChildWhichIsA('Model'):Destroy()
					v.PressPart.CanQuery = false
				end
			end
		end
		obj.Parent = parent
	end

	table.clear(RoundSystem._cache[plr].baseCache)

	plot = plot or PlotService:GetPlot(plr)
	if not plot then return end

	for _, v in plot.Walls:GetChildren() do
		v.CanCollide = false
	end
	for _, v in plot.Grid.Ramps:GetChildren() do
		v.CanCollide = false
	end

	task.delay(1, function() plr:RemoveTag('AddBaseDB') end)
end

-- ======================================================
-- PLAYER DEATH TRACKING
-- ======================================================

local function untrackPlayerDeath(plr)
	local match = getMatch(plr)
	match.PlayerDeath = match.PlayerDeath and match.PlayerDeath:Disconnect()
end

local function setupCharacter(plr)
	untrackPlayerDeath(plr)

	local char = plr.Character
	if not char then return end

	local hum = char:FindFirstChild("Humanoid")
	if not hum then return end

	local plot = PlotService:GetPlot(plr)
	if not plot then return end

	char:PivotTo(plot.SpawnZone.CFrame + Vector3.new(0, 3, 0))

	local match = getMatch(plr)
	match.PlayerDeath = hum.Died:Once(function()
		if not plr:GetAttribute('Playing') then return end
		RoundSystem.EndMatch(plr, 'PlayerDied')
	end)
end

-- ======================================================
-- NPC CACHE MANAGEMENT
-- ======================================================

local function addNPCToCache(plr, npc)
	table.insert(getMatch(plr).npcCache, npc)
end

local function removeNPCFromCache(plr, npc)
	local match = getMatch(plr)

	for i = #match.npcCache, 1, -1 do
		if match.npcCache[i] ~= npc then continue end

		table.remove(match.npcCache, i)
		break
	end
end

local function cleanupAllNPCs(plr)
	local match = getMatch(plr)

	for _, npc in match.npcCache do
		pcall(function()
			npc:Destroy()
		end)
	end

	table.clear(match.npcCache)
end

-- ======================================================
-- REWARDS
-- ======================================================

function RoundSystem.Award(plr, amount)
	local data = DataStore:GetData(plr)
	if not data then return end

	local match = getMatch(plr)
	
	Currency:Increment(plr, "Money", amount)
end

-- ======================================================
-- LAST RUN CACHE & REVIVE SYSTEM
-- ======================================================

local function cacheLastRun(plr)
	local match = getMatch(plr)

	local data = DataStore:GetData(plr)
	if not data then return end
	
	local previousRun = getPreviousMatch(plr)
	previousRun.Wave = match.CurrentWave
	previousRun.MoneyEarned = match.TotalMoney
	previousRun.OfferExpired = false
	previousRun.Claimed = false
end

function RoundSystem.Revive(plr)
	local previousRun = getPreviousMatch(plr)
	local cache = RoundSystem._cache[plr]

	if previousRun.OfferExpired then
		return false, "Offer expired or doesn't exist"
	else
		RoundSystem.ClaimRound(plr)

		previousRun.OfferExpired = true

		notify(RoundSystem.Config._event_names.Revived, plr)

		plr:SetAttribute('Playing', true)
		Combat:StartFight(plr)
		local match = getMatch(plr)
		match.CurrentWave = previousRun.Wave
		match.AliveZombies = 0
		match.TotalZombies = 0
		match.CurrentZombiesSpawned = 0

		setupCharacter(plr)
		RemoveBase(plr)
		notify(config._event_names.RoundStarted, plr)

		task.delay(2, startNextWave, plr)

		return true
	end
end

function RoundSystem.DoubleMoney(plr)
	local previousRun = getPreviousMatch(plr)

	RoundSystem.Award(plr, previousRun.MoneyEarned)
	previousRun.OfferExpired = true

	notify(config._event_names.Claimed, plr)

	return true, previousRun.MoneyEarned
end

-- ======================================================
-- WAVE LOGIC
-- ======================================================

function startNextWave(plr)
	if not plr:GetAttribute('Playing') then return end

	local cache = RoundSystem._cache[plr]
	local match = getMatch(plr)
	local plot = PlotService:GetPlot(plr)

	match.CurrentWave += 1

	local wave = match.CurrentWave
	match.IsBossWave = table.find(config.BossWaves, wave) ~= nil

	local nextBoss = getNextBossWave(wave)
	notify(
		config._event_names.ProgressUpdate,
		plr,
		{
			Progress = match.IsBossWave and 1 or 0;
			BossText = nextBoss and `??? at wave {nextBoss}` or "Endless Mode";
		}
	)
	
	if match.IsBossWave then
		notify(config._event_names.WaveStarted, plr, {Wave = 'BOSS'})
		notify(config._event_names.BossSpawned, plr, wave)

		local boss = NPC.new(`Wave{wave}`, plot.SpawnZone.Position + Vector3.new(0, 20, 0), plr)
		addNPCToCache(plr, boss)

		boss:OnHealthChanged(function(npc)
			local nextBoss = getNextBossWave(wave)
			notify(
				config._event_names.ProgressUpdate,
				plr,
				{
					Progress = (npc.Model.Humanoid.Health / npc.Model.Humanoid.MaxHealth);
					BossText = nextBoss and `??? at wave {nextBoss}` or "";
				}
			)
		end)

		boss:OnDied(function()
			removeNPCFromCache(plr, boss)
			boss:Destroy()
			match.KilledZombies += 1
			notify(config._event_names.WaveCleared, plr, {Wave = wave})
			task.delay(1 / GetRoundSpeed(plr), startNextWave, plr)
		end)
	else
		notify(config._event_names.WaveStarted, plr, {Wave = wave})
		local baseDef, multiplier = getWaveComposition(wave)
		if not baseDef then return end
		
		local start = match.TotalZombies
		for class, baseCount in pairs(baseDef) do
			local finalCount = math.max(1, math.floor(baseCount * multiplier))
			for _ = 1, finalCount do
				match.AliveZombies += 1
				match.TotalZombies += 1
				RoundSystem.SpawnZombie(plr, class)
				task.wait(0.1)
				if not plr:GetAttribute('Playing') then
					cleanupAllNPCs(plr)
					break
				end
			end
		end
		match.CurrentZombiesSpawned = match.TotalZombies - start
	end
end

-- ======================================================
-- NPC LIFECYCLE
-- ======================================================

function RoundSystem.SpawnZombie(plr, class)
	local npc = NPC.new(class, GetPosition(plr, config.MinZombieSpawnDistance), plr)
	addNPCToCache(plr, npc)

	local cache = RoundSystem._cache[plr]
	local match = getMatch(plr)
	local wave = match.CurrentWave
	local info = npc.Info

	info.Health = config.NPCScaling.Health(info.Health, wave)
	info.Damage = config.NPCScaling.Damage(info.Damage, wave)
	info.Speed  = config.NPCScaling.Speed(info.Speed, wave)

	local hum = npc.Model.Humanoid
	hum.MaxHealth = info.Health
	hum.Health = info.Health
	hum.WalkSpeed = info.Speed * GetRoundSpeed(plr)

	npc:OnDied(function()
		if not plr then return end
		RoundSystem.ZombieKilled(plr, npc)
	end)
end

function RoundSystem.ZombieKilled(plr, npc)
	if not plr:GetAttribute('Playing') then return end

	local match = getMatch(plr)
	local cache = RoundSystem._cache[plr]

	local data = DataStore:GetData(plr)
	if data then
		data.BaseData.ZombiesKilled += 1
	end

	match.AliveZombies -= 1
	match.KilledZombies += 1
	match.TotalMoney += npc.Info.Reward

	removeNPCFromCache(plr, npc)
	npc:Destroy()
	
	local progress = (match.AliveZombies / math.max(1, match.CurrentZombiesSpawned))
	local nextBoss = getNextBossWave(match.CurrentWave)

	notify(
		config._event_names.ProgressUpdate,
		plr,
		{
			Progress = 1 - progress;
			BossText = nextBoss and `??? at wave {nextBoss}` or "";
		}
	)

	if match.AliveZombies > 0 then return end
	notify(config._event_names.WaveCleared, plr, {Wave = match.CurrentWave})

	task.delay(1 / GetRoundSpeed(plr), startNextWave, plr)
end

-- ======================================================
-- ROUND FLOW
-- ======================================================

function RoundSystem.ClaimRound(plr)
	local previousRun = getPreviousMatch(plr)
	if previousRun.Claimed then return end
	previousRun.Claimed = true
	
	local Data = DataStore:GetData(plr)
	if Data.BaseData.TutorialStep == 4 then
		Data.BaseData.TutorialStep += 1
		Network.TutorialStep:SetFor(plr, Data.BaseData.TutorialStep)
	end
	
	notify(config._event_names.Claimed, plr)
	
	RoundSystem.Award(plr, previousRun.MoneyEarned)
end

function RoundSystem.CanStart(plr)
	local match = getMatch(plr)
	if plr:GetAttribute('Playing') then return false end

	repeat task.wait() until plr.Character and plr.Character:WaitForChild('Humanoid').Health > 0

	if not hasValidWeapon(plr) then return false end

	return true
end

function RoundSystem.StartMatch(plr)
	if not RoundSystem.CanStart(plr) then return end
	
	local Data = DataStore:GetData(plr)
	if Data.BaseData.TutorialStep == 3 then
		Data.BaseData.TutorialStep = 4
		Network.TutorialStep:SetFor(plr, 4)
	elseif Data.BaseData.TutorialStep == 11 then
		Data.BaseData.TutorialStep = -1
		Network.TutorialStep:SetFor(plr, -1)
	end
	
	local match = CreateMatch(plr)

	setupCharacter(plr)
	RemoveBase(plr)

	notify(config._event_names.RoundStarted, plr)

	plr:SetAttribute('Playing', true)
	Combat:StartFight(plr)
	startNextWave(plr)
end

function RoundSystem.EndMatch(plr, reason)
	if not plr:GetAttribute('Playing') then return end

	local match = getMatch(plr)

	-- Cleanup
	
	Combat:EndFight(plr)
	plr:SetAttribute('Playing', false)
	untrackPlayerDeath(plr)

	local currentWave = match.CurrentWave

	-- Reverse base changes
	cleanupAllNPCs(plr)
	AddBase(plr, nil, reason == 'PlayerLeft')

	if not plr:IsDescendantOf(Players) then return end

	-- Notify round ended

	if reason == 'PlayerDied' or reason == 'PlayerEnded' then
		cacheLastRun(plr)
	end

	local data = DataStore:GetData(plr)
	if data then
		data.BaseData.HighestWave = math.max(data.BaseData.HighestWave, match.CurrentWave)
	end

	if reason == 'PlayerLeft' then return end

	if plr:GetAttribute('AutoPlaying') then
		repeat  task.wait() until plr.Character and plr.Character.Humanoid.Health > 0
		RoundSystem.StartMatch(plr)
	else
		notify(config._event_names.RoundEnded, plr, match.TotalMoney, match.KilledZombies)
	end
end

-- ======================================================
-- CLEANUP
-- ======================================================

Players.PlayerAdded:Connect(CreateData)

Players.PlayerRemoving:Connect(function(plr)
	RoundSystem.EndMatch(plr, "PlayerLeft")
	RoundSystem._cache[plr] = nil
end)

-- ======================================================
-- REMOTE EVENTS
-- ======================================================

RS.Events.Action.ToggleRound.OnServerEvent:Connect(function(plr)
	if plr:HasTag('ToggleRoundDB') then return end
	plr:AddTag('ToggleRoundDB')
	
	if plr:GetAttribute('Playing') then
		plr:SetAttribute('AutoPlaying', false)
		RoundSystem.EndMatch(plr, 'PlayerEnded')
	else
		RoundSystem.StartMatch(plr)
	end
	
	task.delay(0.3, function() plr:RemoveTag('ToggleRoundDB') end)
end)

RS.Events.Action.Claim.OnServerEvent:Connect(function(plr)
	RoundSystem.ClaimRound(plr)
end)

RS.Events.Action.ToggleAuto.OnServerEvent:Connect(function(plr)
	plr:SetAttribute('AutoPlaying', not plr:GetAttribute('AutoPlaying'))
end)

RS.Events.Action.Toggle2xSpeed.OnServerEvent:Connect(RoundSystem.Toggle2xSpeed)

Signal.CleanupPlot:Connect(function(plr, plot)
	AddBase(plr, plot, true)
end)

return RoundSystem
