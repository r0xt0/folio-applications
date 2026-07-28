local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- animations and remotes that are used throughout the movement system
local Animations = ReplicatedStorage:WaitForChild("Resources"):WaitForChild("Animations"):GetChildren()
local Remotes = ReplicatedStorage:WaitForChild("Resources"):WaitForChild("Events")
local Ledges = workspace:WaitForChild("Assets"):WaitForChild("Ledges")

local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Humanoid : Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character.PrimaryPart

-- attachments used for the dash trail effects
local Trail1 = script:WaitForChild("trail1")
local Trail2 = script:WaitForChild("trail2")

-- movement settings
local DashCooldown = 1.5
local SlideCooldown = 1
local WPressTiming = 0.5
local LastWPress = 0
local CurrentMultiplier = 1
local FallStuds = 6
local MaxClimbHeight = 23
local ClimbVelocityDelay = 0.6
local WallClimbRange = 5
local LedgeGrabCooldownTimer = 0.4

-- keeps track of the current movement states
local LedgeGrabCooldown = false
local IsGrabbingLedge = false
local DashDebounce = false
local Sprinting = false
local Sliding = false
local CanSlide = true
local CanClimb = false
local IsInAir = false
local Grounded = true
local IsClimbing = false
local JustStopped = false

-- used to keep track of keys that are currently being held
local KeysHeld = {}

-- variables that need to be accessed by multiple movement functions
local LastClimableState
local PosCheck
local CurrentDash
local CurrentAnim 
local SlideVelocity
local AlignGyro
local FallStartY

local SprintStartTime = nil
local SprintEffectActive = false
local OriginalCameraDistance = nil
local Camera = workspace.CurrentCamera

local MovementModule = {}
local CachedAnimations :{string : AnimationTrack} = {}

-- used for movement raycasts so we dont detect our own character
local Params = RaycastParams.new()
Params.FilterDescendantsInstances = {Character}
Params.FilterType = Enum.RaycastFilterType.Exclude


local function CancelDash()
	-- stops the current dash and resets everything related to it
	
	if CurrentDash then
		CurrentDash:Destroy()
		CurrentDash = nil
	end
	
	if CurrentAnim then
		CurrentAnim:Stop()
		CurrentAnim = nil
	end
	
	if CachedAnimations["CancelDash"] then
		CachedAnimations["CancelDash"]:Play()
	end
	
	DashDebounce = false
	
	task.delay(DashCooldown, function()
		DashDebounce = false
	end)
end


local function CancelSprinting()
	-- stops sprinting and puts the player back to their normal movement speed
	
	Humanoid.WalkSpeed = 16
	Sprinting = false
	CachedAnimations["Run"]:Stop()
	
	if SprintEffectActive then
		SprintEffectActive = false
		
		-- reset the camera back to its normal FOV
		TweenService:Create(Camera, TweenInfo.new(0.07, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {FieldOfView = 70}):Play()
		
		-- remove all of the sprint effects from the character
		for i, v in pairs(RootPart:GetChildren()) do
			if v.Name == "Copy" or v.Name == "Wind19" or v.Name == "legs" or v.Name == "smoke" or v.Name == "swirls" then
				v:Destroy()
			end
		end
	end
end


local function ActivateSprintEffects()
	-- activates the faster sprint effects after the player has been sprinting for long enough
	
	if SprintEffectActive then return end
	SprintEffectActive = true
	
	-- increase the FOV and walkspeed to make the sprint feel faster
	TweenService:Create(Camera, TweenInfo.new(0.07, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {FieldOfView = 100}):Play()
	Humanoid.WalkSpeed = 40
	
	-- clone all of the sprint particles onto the player
	for _, ParticleEmitter in pairs(script.SuperSprint:GetChildren()) do
		ParticleEmitter:Clone().Parent = RootPart
		
		if ParticleEmitter:IsA("ParticleEmitter") then
			ParticleEmitter.Enabled = true
			
		elseif ParticleEmitter:IsA("Attachment") then
			-- attachments can have particle emitters inside them, so enable those too
			for i, v in pairs(ParticleEmitter:GetDescendants()) do
				if v:IsA("ParticleEmitter") then
					v.Enabled = true
				end
			end
		end
	end
end


local function StopSlide()
	-- stops the slide and cleans up everything that was created for it
	
	Sliding = false
	PosCheck:Disconnect()
	SlideVelocity:Destroy()
	AlignGyro:Destroy()
	CachedAnimations["Slide"]:Stop(0.15)
	Humanoid.HipHeight = 0
	
	-- wait before allowing the player to slide again
	task.delay(DashCooldown,function()
		CanSlide = true
	end)
end


local function Landed()
	-- plays the landing animation when the player falls far enough
	
	CachedAnimations["Landed"]:Play()
	
	--[[Humanoid.WalkSpeed = 2
	Humanoid.JumpPower = 0]]
end


local function TriggerWallClimb()
	-- starts the wall climb and pushes the player upwards
	
	Grounded = false
	IsClimbing = true
	
	CachedAnimations["Climb"]:Play()
	
	local Velocity = Instance.new("BodyVelocity")
	Velocity.Velocity = Vector3.new(0,MaxClimbHeight,0) --RootPart.CFrame.LookVector + Vector3.new(0,MaxClimbHeight,0)
	Velocity.MaxForce = Vector3.new(30000,30000,30000)
	Velocity.Parent = RootPart
	
	-- automatically remove the velocity after the climb starts
	Debris:AddItem(Velocity, 0.5)
	
	task.delay(0.5, function()
		print("destroyed")
	end)
	
	-- stop the climbing state after the player has been pushed up
	task.delay(ClimbVelocityDelay, function()
		IsClimbing = false
	end)
end


function MovementModule:Init()
	-- preload all animations before we try to use them
	ContentProvider:PreloadAsync(Animations)
	
	-- load all animations into a cache so we dont have to load them every time
	for _, Anim in ipairs(Animations) do
		local Track = Humanoid.Animator:LoadAnimation(Anim)
		CachedAnimations[Anim.Name] = Track
	end
	
	-- reset the players movement settings after the landing animation finishes
	CachedAnimations["Landed"].Ended:Connect(function()
		if Sprinting then
			Humanoid.WalkSpeed = 32
		else
			Humanoid.WalkSpeed = 16
		end
		
		Humanoid.JumpPower = 50
	end)
	
	-- keep track of when the player leaves the ground or lands
	Humanoid.StateChanged:Connect(function(NewState, OldState)
		if NewState == Enum.HumanoidStateType.Freefall or NewState == Enum.HumanoidStateType.Jumping then
			IsInAir = true
			
			-- only save the starting height once so we can calculate the total fall distance
			if FallStartY then return end
			FallStartY = RootPart.Position.Y
			
		elseif NewState == Enum.HumanoidStateType.Landed then 
			IsInAir = false
			Grounded = true
			
			-- check how far the player fell before landing
			if FallStartY then
				local FallDistance = FallStartY - RootPart.Position.Y
				
				if FallDistance >= FallStuds then
					Landed()
				end
			end
			
			FallStartY = nil
		end
	end)
	
	
	UserInputService.InputBegan:Connect(function(Input, GPE)
		if GPE then return end
		
		-- right click cancels the current dash
		if Input.UserInputType == Enum.UserInputType.MouseButton2 and DashDebounce then
			CancelDash()
			return
		end
		
		-- Q starts the dash as long as we arent already dashing or sliding
		if Input.KeyCode == Enum.KeyCode.Q and not DashDebounce and not Sliding then
			DashDebounce = true
			
			-- reset the dash after the cooldown unless something else stopped it
			task.delay(DashCooldown, function()
				if JustStopped then return end
				DashDebounce = false
			end)
			
			-- use the direction the player is moving in for the dash
			local DashDirection = Humanoid.MoveDirection
			
			-- if the player isnt moving, dash in the direction they are facing
			if DashDirection.Magnitude == 0 then
				DashDirection = Character.PrimaryPart.CFrame.LookVector 
			end
			
			local Forward = RootPart.CFrame.LookVector
			local Right = RootPart.CFrame.RightVector

			-- figure out whether the player is moving forward/backward or left/right
			local FDot = Forward:Dot(DashDirection)
			local RDot = Right:Dot(DashDirection)
			
			local AnimName
			
			-- pick the correct dash animation based on the movement direction
			if math.abs(FDot) > math.abs(RDot) then
				if FDot > 0 then
					AnimName = "FrontDash"
				else
					AnimName = "BackDash"
				end
			else
				if RDot > 0 then
					AnimName = "RightDash"
				else
					AnimName = "LeftDash"
				end
			end
			
			-- play the correct dash animation if one exists
			if CachedAnimations[AnimName] then
				CurrentAnim = CachedAnimations[AnimName]
				CachedAnimations[AnimName]:Play()
			else
				warn("no animation for "..AnimName)
			end
			
			-- create the dash trails for both arms
			local Clone1 = Trail1:Clone()
			Clone1.Parent = Character:WaitForChild("Right Arm")
			
			local Clone2 = Trail2:Clone()
			Clone2.Parent = Character:WaitForChild("Right Arm")
			
			-- connect the trail attachments together
			for i, v : Trail in pairs(Clone1:GetChildren()) do
				v.Attachment0 = Clone1
				v.Attachment1 = Clone2
			end
			
			-- do the same thing for the left arm
			local Clone3 = Trail1:Clone()
			Clone3.Parent = Character:WaitForChild("Left Arm")
			
			local Clone4 = Trail2:Clone()
			Clone4.Parent = Character:WaitForChild("Left Arm")
			
			for i, v : Trail in pairs(Clone3:GetChildren()) do
				v.Attachment0 = Clone3
				v.Attachment1 = Clone4
			end
			
			-- push the player in the direction of the dash
			local BodyVelocity = Instance.new("BodyVelocity")
			BodyVelocity.MaxForce = Vector3.new(1e5, 0, 1e5)
			BodyVelocity.Velocity = DashDirection.Unit * 70
			BodyVelocity.Parent = RootPart
			
			CurrentDash = BodyVelocity
			
			-- clean up the dash movement and effects after the dash ends
			Debris:AddItem(BodyVelocity, 0.3)
			Debris:AddItem(Clone1, 0.6)
			Debris:AddItem(Clone2, 0.6)
			Debris:AddItem(Clone3, 0.6)
			Debris:AddItem(Clone4, 0.6)

			-- tell the server to play the dash sound
			Remotes.PlaySound:FireServer(ReplicatedStorage.Resources.Sounds.Dash, RootPart)
			
		elseif Input.KeyCode == Enum.KeyCode.W then
			-- keep track of W being held so other movement systems can use it
			KeysHeld.W = true
			
			-- pressing W twice quickly starts sprinting
			if tick() - LastWPress <= WPressTiming then
				print("hello?")
				Humanoid.WalkSpeed = 32
				CachedAnimations["Run"]:Play()
				Sprinting = true
				SprintStartTime = tick()
			else
				print(tick() - LastWPress)
				
				-- save when W was last pressed so we can check for a double press
				LastWPress = tick()
			end
			
		elseif Input.KeyCode == Enum.KeyCode.LeftControl and Sprinting and not DashDebounce then
			-- raycast down to make sure the player is actually on the ground before sliding
			local RayDirection = -RootPart.CFrame.UpVector * 5
			local GroundRay = workspace:Raycast(RootPart.Position, RayDirection, Params)
			
			if Sliding or not CanSlide or not GroundRay then return end
			
			Sliding = true
			CanSlide = false
			
			CachedAnimations["Slide"]:Play()
			Humanoid.HipHeight = -2
			
			-- create the velocity that moves the player forward during the slide
			SlideVelocity = Instance.new("BodyVelocity",RootPart)
			SlideVelocity.MaxForce = Vector3.new(40000,0,40000)
			SlideVelocity.Velocity = RootPart.CFrame.LookVector * 55
			
			-- gyro keeps the player aligned with the surface while sliding
			AlignGyro = Instance.new("BodyGyro",RootPart)
			AlignGyro.MaxTorque = Vector3.new(3e5,3e5,3e5)
			AlignGyro.P = 10000
			
			local PreviousY = 0
			CurrentMultiplier = 1
			
			-- update the slide every frame so slopes can speed up or slow down the player
			PosCheck = RunService.Heartbeat:Connect(function(deltaTime)
				local CurrentY = RootPart.Position.Y
				local VerticalChange = (CurrentY - PreviousY)
				PreviousY = CurrentY
				
				-- check the ground below the player so we know what surface we are sliding on
				local RayDirection = -RootPart.CFrame.UpVector * 10
				local GroundRay = workspace:Raycast(RootPart.Position, RayDirection, Params)
				
				if GroundRay then
					local CurrentRightVector = RootPart.CFrame.RightVector
					local UpVector = GroundRay.Normal
					
					-- create a new orientation using the slope normal so the player follows the ground
					local NewFacialVector = CurrentRightVector:Cross(UpVector)
					AlignGyro.CFrame = CFrame.fromMatrix(RootPart.Position, CurrentRightVector, UpVector, NewFacialVector)
				end
				
				-- apply the current slide speed
				SlideVelocity.Velocity = RootPart.CFrame.LookVector * (55 * CurrentMultiplier)
				
				-- flat ground slowly slows the player down
				if VerticalChange < 0.1 and VerticalChange > -0.1 then
					if CurrentMultiplier > 1 then 
						CurrentMultiplier = math.clamp(CurrentMultiplier - (1 * 2) * deltaTime, 0, 2)
					end
					
					CurrentMultiplier = math.clamp(CurrentMultiplier - 1 * deltaTime, 0, 2)
					
				-- going uphill slows the player down faster
				elseif VerticalChange > 0 then 
					if CurrentMultiplier > 1 then 
						CurrentMultiplier = math.clamp(CurrentMultiplier - (2 * 2) * deltaTime, 0, 2)
					end
					
					CurrentMultiplier = math.clamp(CurrentMultiplier -2 * deltaTime, 0, 2)
					
				-- going downhill speeds the player up
				else
					CurrentMultiplier = math.clamp(CurrentMultiplier + 1 * deltaTime, 0, 2)
				end
				
				-- make sure the multiplier never goes outside of the allowed range
				CurrentMultiplier = math.clamp(CurrentMultiplier,0,2)
				
				-- stop sliding if we lose the ground or slow down too much
				if CurrentMultiplier < 0.1 or not GroundRay then
					StopSlide()
				end
			end)
			
		elseif Input.KeyCode == Enum.KeyCode.Space then
			-- jumping during a slide cancels it and launches the player forward
			if Sliding then
				local CancelMultiplier = CurrentMultiplier
				
				StopSlide()
				
				local PushVelocity = Instance.new("BodyVelocity",RootPart)
				PushVelocity.MaxForce = Vector3.new(40000,40000,40000)
				PushVelocity.Velocity = (RootPart.CFrame.LookVector * (50 * CancelMultiplier)) + (RootPart.CFrame.UpVector * 50)
				Debris:AddItem(PushVelocity,0.1)
				
			-- holding W in the air near a climbable wall lets the player climb
			elseif IsInAir and KeysHeld.W and CanClimb and not IsClimbing and Grounded then
				TriggerWallClimb()
			end
		end
	end)
	
	
	UserInputService.InputEnded:Connect(function(Input, GPE)
		if GPE then return end
		
		if Input.KeyCode == Enum.KeyCode.W then
			KeysHeld.W = nil
			
			-- stop sprinting as soon as W is released
			if Sprinting then
				CancelSprinting()
				--SprintStartTime = nil
			end
		end
	end)
	
	
	RunService.Heartbeat:Connect(function()
		-- check for a wall directly in front of the player for climbing
		local Result = workspace:Raycast(RootPart.Position, RootPart.CFrame.LookVector * 5, Params)
		
		-- activate the stronger sprint effects after sprinting for 11 seconds
		if Sprinting and SprintStartTime and not SprintEffectActive then
			local SprintDuration = tick() - SprintStartTime
			
			if SprintDuration >= 11 then
				ActivateSprintEffects()
			end
		end
		
		-- check for a wall directly in front of the player while dashing
		if DashDebounce then
			local RayResult = workspace:Raycast(RootPart.Position, RootPart.CFrame.LookVector * 3, Params)
			
			if RayResult and RayResult.Instance.Name ~= "Baseplate" then
				if CurrentDash then 
					CurrentDash:Destroy()
				end
				
				--CancelDash()
			end
		end
		
		-- update whether the wall in front of the player can be climbed
		if Result then
			local Wall = Result.Instance
			local Climable = Wall:GetAttribute("climable") == true
			CanClimb = Climable
			
			if Climable ~= LastClimableState then
				LastClimableState = Climable
			end
			
		else
			CanClimb = false
			
			if LastClimableState ~= false then
				LastClimableState = false
			end
		end
	end)
	
	
	Remotes.PlaySound.OnClientEvent:Connect(function(Sound : Sound, Part : BasePart?)
		-- clone the sound so the original sound isnt moved or played directly
		
		local Clone = Sound:Clone()
		
		-- if a part was given, make the sound come from that part
		if Part then
			Clone.Parent = Part
		end
		
		Clone:Play()
		
		-- clean up the cloned sound after it finishes playing
		Debris:AddItem(Clone, Clone.TimeLength)
	end)
	
	
	-- wait for the character and map to finish setting up before connecting the ledges
	task.wait(1)
	
	-- check every ledge so the player can grab onto it while climbing
	for _, Ledge : BasePart in pairs(Ledges:GetChildren()) do
		Ledge.Touched:Connect(function(Hit)
			-- make sure we arent already grabbing a ledge or on cooldown
			if LedgeGrabCooldown or IsGrabbingLedge or not IsClimbing then return end
			
			-- make sure the thing touching the ledge is actually our character
			if not Hit:IsDescendantOf(Character) then return end
			
			LedgeGrabCooldown = true
			IsGrabbingLedge = true
			IsClimbing = false
			
			-- tell the server which ledge the player grabbed
			Remotes.GrabLedge:FireServer(Ledge)
			
			-- prevent the player from grabbing another ledge immediately
			task.delay(LedgeGrabCooldownTimer, function()
				LedgeGrabCooldown = false
				IsGrabbingLedge = false
			end)
		end)
	end
end


return MovementModule
