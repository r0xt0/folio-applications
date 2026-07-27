local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Types"))
local Network = require(ReplicatedStorage.Modules.Network)
local ItemConfigurations = require(ReplicatedStorage.Modules.ItemConfigurations)

local DataService = require(script.Parent.DataService)
local TurretService = require(script.Parent.TurretService)

local PlacementService = {}
local PlacementDebounce = {} :: {[Player] : boolean} -- will be used to make sure players dont spam the remote

local TurretModels = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("TurretModels")

-- helper function for getting templates when spawning items
-- just makes it easier and makes more sense when you read it IMO
local function GetModelTemplate(ItemId : string) 
	return TurretModels:FindFirstChild(ItemId)
end

-- used for data store when player leaves
local function CFrameToPositionTable(CFrame: CFrame)
	local _, RotY, _ = CFrame:ToOrientation()
	return {CFrame.X, CFrame.Y, CFrame.Z, math.deg(RotY)}
end

-- used for loading player items
local function PositionTableToCFrame(PosTable: {number})
	return CFrame.new(PosTable[1], PosTable[2], PosTable[3]) * CFrame.Angles(0, math.rad(PosTable[4]), 0)
end

-- main chunk of the code, placement is validated on both client + server
local function PlaceItem(Player : Player, ItemId : string, TargetCFrame : CFrame)
	if PlacementDebounce[Player] then return end -- just to check if player is spamming remotes
	PlacementDebounce[Player] = true
	
	local Data = DataService:GetData(Player)
	local Config = ItemConfigurations[ItemId]
	local Plot = Network.Plot:GetFor(Player)
	
	if not (Data and Config and Plot) then
		-- why continue if there is something or everything missing
		PlacementDebounce[Player] = nil -- set the debounce back to nil so the player can still place
		return
	end
	
	local OwnedCount = Data.Inventory[ItemId] or 0
	if OwnedCount <= 0 then
		-- cant place if the player doesnt own any
		PlacementDebounce[Player] = nil 
		return
	end
	
	local Template = GetModelTemplate(ItemId)
	if not (Template and Template.PrimaryPart) then
		-- same thing just check if we can find the model
		-- if not then dont continue
		PlacementDebounce[Player] = nil
		return
	end
	
	local PlacementBoxTemplate = Template:FindFirstChild("PlacementBox")
	if not PlacementBoxTemplate then
		-- a hitbox part of the model, mostly to check overlapping and verify client was right that we can place
		warn(`{ItemId} has no placement box!`)
		PlacementDebounce[Player] = nil
		return
	end
	
	local TempServerBox = PlacementBoxTemplate:Clone()
	TempServerBox.CFrame = TargetCFrame * Template.PrimaryPart.CFrame:ToObjectSpace(PlacementBoxTemplate.CFrame)
	TempServerBox.Parent = workspace
	-- position the temporary box to where the turret would be to actually verify now
	task.wait()
	local IsOverlapping = false
	local Params = OverlapParams.new()
	Params.FilterDescendantsInstances = {TempServerBox} -- make sure that we dont detect the temporary box
	
	for _, Part in ipairs(workspace:GetPartsInPart(TempServerBox, Params)) do
		local Model = Part:FindFirstAncestorWhichIsA("Model")
		if Model and Model.Parent == Plot and CollectionService:HasTag(Model, "PlacedItem") then
			-- all turrets will get "PlacedItem" tag
			-- if this new turret will touch something that does, cant place there
			-- basically just check every part that temp box is touching to make sure it isnt another turret
			IsOverlapping = true
			break
		end
	end
	TempServerBox:Destroy()
	-- destroy the temp box to prevent unlimited spawning, and just to overall cleanup since its job is done
	if IsOverlapping then
		PlacementDebounce[Player] = nil
		return -- cant place if overlapping
	end
	
	-- mostly just checking the player tutorial step and increasing
	if Data.TutorialStep == 3 then
		Data.TutorialStep = 4
		Network.TutorialStep:SetFor(Player, Data.TutorialStep)
	elseif Data.TutorialStep == 13 then
		Data.TutorialStep = 14
		Network.TutorialStep:SetFor(Player, Data.TutorialStep)
	end
	
	-- remove an item in their inventory
	Data.Inventory[ItemId] -= 1
	local GUID = HttpService:GenerateGUID(false) -- make a unique id for each turret so that they can be easy to find in data
	
	local PlotBase = Plot:FindFirstChild("Base") :: BasePart
	if not PlotBase then
		PlacementDebounce[Player] = nil
		return
	end
	
	local RelativeCFrame = PlotBase.CFrame:ToObjectSpace(TargetCFrame)
	-- client gives the CFrame in a world space, so we gotta change it to something relative to the plot base
	
	table.insert(Data.PlacedItems, {
		UniqueId = GUID,
		ItemId = ItemId,
		Position = CFrameToPositionTable(RelativeCFrame),
	}) -- just to put it into the data
	
	local NewItem = Template:Clone()
	NewItem:SetAttribute("UniqueId", GUID)
	NewItem:SetAttribute("IsPlacedItem", true)
	
	NewItem:SetPrimaryPartCFrame(TargetCFrame) -- position new turret to where its supposed to go
	NewItem.Parent = Plot
	CollectionService:AddTag(NewItem, "PlacedItem")
	
	TurretService:AddTurret(NewItem, Plot)
	Network.Inventory:SetFor(Player, Data.Inventory)
	Network.UpdateInventory:FireClient(Player, Data.Inventory)

	Network.ItemPlacedFX:FireClient(Player)
	
	task.delay(0.2, function()
		PlacementDebounce[Player] = nil
		-- let client place again
	end)
end

local function RemoveItem(Player : Player, Model : Model)
	-- removes a placed item from the plot and gives the item back to the player

	local Data = DataService:GetData(Player)
	if not Data then return end
	-- no reason to continue if we cant find the players data

	local UniqueId = Model:GetAttribute("UniqueId")
	if not UniqueId then return end
	-- need this unique id we set earlier to find it in their data

	local ItemId = Model.Name
	local Config = ItemConfigurations[ItemId]
	if not Config then return end
	-- just to make sure config actually exists

	for i, ItemData in ipairs(Data.PlacedItems) do
		if ItemData.UniqueId == UniqueId then
			print(Data.PlacedItems)
			table.remove(Data.PlacedItems, i)
			break
		end
	end
	-- loop through table and make sure that we can remove the item so it doesnt duplicate

	Data.Inventory[ItemId] = (Data.Inventory[ItemId] or 0) + 1
	-- give item back

	TurretService:RemoveTurret(Model)
	-- turret system removes it to cleanup and prevent memory leak

	Model:Destroy()
	-- now destroy the real model

	Network.Inventory:SetFor(Player, Data.Inventory)
	Network.UpdateInventory:FireClient(Player, Data.Inventory)
	-- just tell the client their invenntory is new

	Network.ItemRemovedFX:FireClient(Player)
	-- play vfx on client to prevent server load
end

local function MergeItem(Player : Player, ItemOne : Model, ItemTwo : Model)
	-- merges two of the same items into their upgraded version

	if ItemOne == ItemTwo then
		return
	end
	-- cant merge an item with itself

	local Data = DataService:GetData(Player)
	if not Data then
		return
	end
	-- no reason to continue without player data

	if ItemOne.Parent ~= ItemTwo.Parent then
		return
	end
	-- both items need to be inside the same plot to merge

	local ItemId = ItemOne.Name
	if ItemTwo.Name ~= ItemId then
		return
	end
	-- make sure both items are the same type before merging, cant merge two different types of tower

	local Config = ItemConfigurations[ItemId]
	if not Config then
		return
	end
	-- make sure this item exists in our configurations

	local MergeTarget = Config.MergeTarget
	if not MergeTarget then
		return
	end
	-- check if this item actually has an upgrade and not max level

	local MergeTemplate = GetModelTemplate(MergeTarget)
	if not (MergeTemplate and MergeTemplate.PrimaryPart) then
		return
	end
	-- make sure the upgraded item exists and can be placed

	local UniqueIdOne = ItemOne:GetAttribute("UniqueId")
	local UniqueIdTwo = ItemTwo:GetAttribute("UniqueId")
	-- get both ids so we can remove the old items from saved data

	if not (UniqueIdOne and UniqueIdTwo) then
		return
	end
	-- cant continue if either item doesnt have an id

	local Plot = ItemOne.Parent
	if not Plot then
		return
	end
	-- get the plot these items belong to

	local TargetCFrame = ItemOne:GetPrimaryPartCFrame()
	-- new item will replace the old item to "upgrade"

	for Index = #Data.PlacedItems, 1, -1 do
		local ItemData = Data.PlacedItems[Index]

		if ItemData.UniqueId == UniqueIdOne or ItemData.UniqueId == UniqueIdTwo then
			table.remove(Data.PlacedItems, Index)
		end
	end
	-- remove both old items from saved data since they are being deleted

	TurretService:RemoveTurret(ItemOne)
	TurretService:RemoveTurret(ItemTwo)
	-- cleanup both old turret systems before removing them to again prevent mem leaks

	ItemOne:Destroy()
	ItemTwo:Destroy()
	-- destroy both old item models because theyre not needed

	local NewGuid = HttpService:GenerateGUID(false)
	-- create a new unique id for the upgraded item

	local PlotBase = Plot:FindFirstChild("Base") :: BasePart
	if not PlotBase then
		return
	end

	local RelativeCFrame = PlotBase.CFrame:ToObjectSpace(TargetCFrame)
	-- convert the world position into a plot relative position so we can save it

	table.insert(Data.PlacedItems, {
		UniqueId = NewGuid,
		ItemId = MergeTarget,
		Position = CFrameToPositionTable(RelativeCFrame),
	})
	-- add new item into the data

	local NewTurret = MergeTemplate:Clone()
	NewTurret:SetAttribute("UniqueId", NewGuid)
	NewTurret:SetAttribute("IsPlacedItem", true)
	-- give the unique id

	NewTurret:SetPrimaryPartCFrame(TargetCFrame)
	NewTurret.Parent = Plot

	CollectionService:AddTag(NewTurret, "PlacedItem")
	-- tag the item so everything knows this is a placed item

	TurretService:AddTurret(NewTurret, Plot)
	-- start the turret system for the upgraded item

	Network.ItemUpgradeFX:FireClient(Player, NewTurret)
	-- again vfx on the client 

	if Data.TutorialStep == 16 then
		Data.TutorialStep = -1
		Network.TutorialStep:SetFor(Player, Data.TutorialStep)
	end
	-- set tutorial to -1 bc/ on client it "ends" it
end

function PlacementService:Init()
	-- just hook remotes and stuff
	-- like to do it as local functions because it just makes the code cleaner imo
	Network.PlaceItem.OnServerEvent:Connect(PlaceItem)
	Network.RemoveItem.OnServerEvent:Connect(RemoveItem)
	Network.MergeItem.OnServerEvent:Connect(MergeItem)
end

function PlacementService:LoadPlacedItems(Player : Player, Plot : Model)
	-- for when a player joins
	local Data = DataService:GetData(Player)
	if not Data then return end
	-- again cant do it without data
	
	local PlotBase = Plot:FindFirstChild("Base")
	if not PlotBase then return end
	-- or without plot
	
	for _ , ItemData in ipairs(Data.PlacedItems) do
		-- go through every saved item and recreate it back into the players plot

		local Template = GetModelTemplate(ItemData.ItemId)
		if not Template then continue end
		-- skip this item if we cant find its model

		local NewItem = Template:Clone()
		local Config = ItemConfigurations[NewItem.Name]
		-- clone the saved item template so we can place it back into the world

		NewItem:SetAttribute("UniqueId", ItemData.UniqueId)
		NewItem:SetAttribute("IsPlacedItem", true)
		-- give the item its saved id and mark it as a placed item basically how it was before player left

		local RelativeCFrame = PositionTableToCFrame(ItemData.Position)
		local WorldCFrame = PlotBase.CFrame * RelativeCFrame
		-- convert the saved plot relative position back into a world position

		NewItem:SetPrimaryPartCFrame(WorldCFrame)
		NewItem.Parent = Plot
		-- place the item where it was saved and put it inside the players plot

		CollectionService:AddTag(NewItem, "PlacedItem")
		-- tag the item so other systems can find placed items
		
		task.spawn(TurretService.AddTurret, TurretService, NewItem, Plot)
		-- i like to use task.spawn here because maybe add turret will yield? want it to be instant but
		-- start up the turret system for the loaded item
	end
end

function PlacementService:Start()
	
end

return PlacementService
