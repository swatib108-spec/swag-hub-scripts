-- SWAG_HUB V1 | Instant TP
-- Pick a pet (icon + value), press Steal: taken and delivered with the Instant TP logic only.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local localPlayer = Players.LocalPlayer

------------------------------------------------------------------ settings (same values as the hub)
local CFG = {
	SpeedCap = 1.15, -- never above 115% of the walk speed
	HopRatio = 1.515, -- hop distance = walk speed * ratio (a distance, not a speed)
	HopMin = 40,
	HopGap = 0.06, -- seconds between two hops (learned: grows after a pull-back, shrinks after a clean hop)
	HopGapMin = 0.06,
	HopGapMax = 0.2,
	HopRetries = 6,
	HopLift = 42, -- height of the hops above the start
	LandOffset = 14, -- landing spot in front of the line
	LandSettle = 0.08,
	DropDelay = 0.05,
	GrabInterval = 0.03,
	RegrabFar = 40, -- egg further than this: teleport onto it, otherwise run to it
	Height = 70, -- the safe-zone run starts above the base and comes down (same as the hub)
	ClimbShare = 0.5,
	CarryRatio = 0.9,
	EasyRatio = 1.3,
}
local FPS = { 60, 30, 0.15 }
local AUTO_REFRESH_INTERVAL = 4 -- refresh pet list every 4 seconds while the list is visible

------------------------------------------------------------------ game handles
local function safeRequire(getter)
	local ok, result = pcall(function()
		return require(getter())
	end)
	return ok and result or nil
end

local networkingFolder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Networking")
local EggState = safeRequire(function() return ReplicatedStorage.Client.EggState end)
local Assets = safeRequire(function() return ReplicatedStorage.Data.Assets end)
local Mutations = safeRequire(function() return ReplicatedStorage.Shared.Modules.Mutations end)

local function remote(name)
	return networkingFolder:FindFirstChild(name)
end

local function root()
	local character = localPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

-- "Humanoid Swap" (the hub's default shield, always on in the hub): the character runs on a copy of its humanoid,
-- the original is kept out of the character while we steal. Same code path as the hub.
local shield = { Original = nil, Clone = nil, Links = {}, Connection = nil, Added = nil }

local function walkSpeed()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local speed = humanoid and humanoid.WalkSpeed or 16
	if shield.Original and shield.Original.Health > 0 then
		speed = math.min(speed, shield.Original.WalkSpeed)
	end
	local ok, result = pcall(function()
		local stat = localPlayer:FindFirstChild("leaderstats")
		stat = stat and stat:FindFirstChild("Speed")
		local util = require(ReplicatedStorage.Shared.Util.TreadmillUtil)
		return stat and util.SpeedPowerToWalkSpeed(stat.Value) or nil
	end)
	if ok and type(result) == "number" and result > 0 then
		speed = math.min(speed, result)
	end
	return speed
end

local function shieldControls(humanoid)
	pcall(function()
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if module then
			local controls = require(module):GetControls()
			if type(controls) == "table" then
				controls.humanoid = humanoid
			end
		end
	end)
end

local function shieldAnimate(character)
	local animate = character and character:FindFirstChild("Animate")
	if animate and animate:IsA("LocalScript") then
		task.spawn(function()
			animate.Enabled = false
			task.wait()
			animate.Enabled = true
		end)
	end
end

local function shieldUnlink()
	for _, link in ipairs(shield.Links) do
		pcall(function()
			link:Disconnect()
		end)
	end
	table.clear(shield.Links)
end

local groundedStates = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

local function grounded(humanoid)
	if not humanoid or humanoid.Health <= 0 or humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	return groundedStates[humanoid:GetState()] == true
end

local function shieldSwap()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if shield.Clone and shield.Clone.Parent == character then
		return
	end
	if not grounded(humanoid) then
		return
	end

	local clone = humanoid:Clone()
	humanoid.Parent = nil
	clone.Parent = character
	workspace.CurrentCamera.CameraSubject = clone
	shieldControls(clone)
	shieldAnimate(character)
	shield.Original = humanoid
	shield.Clone = clone

	table.insert(shield.Links, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		if clone.Parent ~= nil then
			clone.WalkSpeed = humanoid.WalkSpeed
		end
	end))

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animator2 = clone:FindFirstChildOfClass("Animator")
	if animator and animator2 then
		table.insert(shield.Links, animator.AnimationPlayed:Connect(function(played)
			local animation = played.Animation
			if not animation or clone.Parent == nil then
				return
			end
			local ok, track = pcall(function()
				return animator2:LoadAnimation(animation)
			end)
			if not ok or not track then
				return
			end
			pcall(function()
				track.Priority = played.Priority
				track.Looped = played.Looped
				track:Play(0.05, math.max(played.WeightTarget, 0.01), played.Speed)
			end)
			local stopped
			stopped = played.Stopped:Connect(function()
				stopped:Disconnect()
				pcall(function()
					track:Stop(0.1)
				end)
			end)
		end))
	end

	table.insert(shield.Links, clone.Died:Connect(function()
		shieldUnlink()
		shield.Original, shield.Clone = nil, nil
		local current = localPlayer.Character
		if current and humanoid.Parent == nil then
			humanoid.Parent = current
			workspace.CurrentCamera.CameraSubject = humanoid
			shieldControls(humanoid)
		end
		pcall(function()
			clone:Destroy()
		end)
		humanoid.Health = 0
	end))
end

local function shieldUndo()
	shieldUnlink()
	local character = localPlayer.Character
	local original, clone = shield.Original, shield.Clone
	shield.Original, shield.Clone = nil, nil
	if original and clone and character and original.Parent == nil and clone.Parent == character then
		original.Parent = character
		workspace.CurrentCamera.CameraSubject = original
		shieldControls(original)
		pcall(function()
			clone:Destroy()
		end)
		shieldAnimate(character)
	end
end

local function shieldStart()
	shieldSwap()
	local n = 0
	shield.Connection = RunService.Heartbeat:Connect(function(dt)
		n += dt
		local character = localPlayer.Character
		local missing = not (shield.Clone and character and shield.Clone.Parent == character)
		if (missing and 0.25 or 3) <= n then
			n = 0
			shieldSwap()
		end
	end)
	shield.Added = localPlayer.CharacterAdded:Connect(function(character)
		shieldUnlink()
		shield.Original, shield.Clone = nil, nil
		task.spawn(function()
			character:WaitForChild("Humanoid", 10)
			task.wait(1)
			if shield.Connection and localPlayer.Character == character then
				shieldSwap()
			end
		end)
	end)
end

local function shieldStop()
	if shield.Connection then
		shield.Connection:Disconnect()
		shield.Connection = nil
	end
	if shield.Added then
		shield.Added:Disconnect()
		shield.Added = nil
	end
	shieldUndo()
end

------------------------------------------------------------------ carry / delivery state
local state = { Carrying = false, Uid = nil, Delivered = 0, Busy = false, Cancel = false, Mult = 1, PulledAt = 0, HeldSeen = 0, GuessedDrop = false }

if type(EggState) == "table" and type(EggState.CarryChanged) == "table" and type(EggState.CarryChanged.Connect) == "function" then
	EggState.CarryChanged:Connect(function(arg)
		local carrying = type(arg) == "table" and arg.IsCarrying == true
		if carrying and arg.GuardDisabled == true then
			carrying = false
		end
		state.GuessedDrop = false
		if carrying then
			state.HeldSeen = os.clock()
		end
		if carrying and type(arg.Uid) == "string" then
			state.Uid = arg.Uid
			local mult = tonumber(arg.SpeedMultiplier)
			if mult and mult > 0 then
				state.Mult = mult
			end
		end
		state.Carrying = carrying
	end)
end

pcall(function()
	remote("RE/EggWorld/FieldEggRedeemVerdict").OnClientEvent:Connect(function()
		state.Delivered = os.clock()
	end)
end)

-- the server pulling us back ("Relocate") is noted so the hop is simply repeated
pcall(function()
	remote("RE/RigSync/Refresh").OnClientEvent:Connect(function(arg)
		if type(arg) == "table" and arg.Action == "Relocate" then
			state.PulledAt = os.clock()
		end
	end)
end)

local function takeEgg(uid)
	if type(uid) == "string" and type(EggState) == "table" and type(EggState.CarryFieldEgg) == "function" then
		pcall(EggState.CarryFieldEgg, uid)
	end
end

local function dropEgg()
	if type(EggState) == "table" and type(EggState.DropFieldEgg) == "function" then
		pcall(EggState.DropFieldEgg, "PlayerRequest")
	end
end

-- the prompt of the egg itself (nearest egg prompt to the egg's position), never one of another egg
local function promptNear(position, radius)
	local best, bestDistance = nil, radius
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "SmartPromptPart" and child:IsA("BasePart") then
			local prompt = child:FindFirstChild("CarryAreaEgg")
			if prompt and prompt:IsA("ProximityPrompt") then
				local distance = (child.Position - position).Magnitude
				if distance < bestDistance then
					best, bestDistance = prompt, distance
				end
			end
		end
	end
	return best
end

-- the carried egg is welded to the character: used to catch a missed carry signal (same check as the hub)
local function heldByMe(uid)
	local character = localPlayer.Character
	if type(uid) ~= "string" or not character then
		return false
	end
	local egg = workspace:FindFirstChild(uid)
	if not egg then
		return false
	end
	for _, d in ipairs(egg:GetDescendants()) do
		if d:IsA("WeldConstraint") or d:IsA("JointInstance") then
			local ok, a, b = pcall(function()
				return d.Part0, d.Part1
			end)
			if ok and ((a and a:IsDescendantOf(character)) or (b and b:IsDescendantOf(character))) then
				return true
			end
		end
	end
	return false
end

task.spawn(function()
	while true do
		task.wait(0.2)
		if not state.Carrying then
			if state.GuessedDrop and heldByMe(state.Uid) then
				state.GuessedDrop, state.Carrying, state.HeldSeen = false, true, os.clock()
			end
		elseif heldByMe(state.Uid) then
			state.HeldSeen = os.clock()
		elseif os.clock() - state.HeldSeen > 0.8 then
			state.Carrying, state.GuessedDrop = false, true
		end
	end
end)

local function snapshot()
	local list = {}
	local ok, result = pcall(function()
		return remote("RF/EggWorld/AskFieldEggSnapshot"):InvokeServer()
	end)
	local records = ok and type(result) == "table" and result.Records or nil
	if type(records) ~= "table" then
		return list
	end
	-- The server snapshot can contain the same pet UID more than once.
	-- Keep only one row per UID so refreshing cannot duplicate pets in the UI.
	local seenUids = {}
	for _, record in pairs(records) do
		if type(record) == "table" and type(record.Uid) == "string" and (record.State == "Slot" or record.State == "Dropped") and typeof(record.BottomCFrame) == "CFrame" then
			if not seenUids[record.Uid] then
				seenUids[record.Uid] = true
				list[#list + 1] = record
			end
		end
	end
	return list
end

local function eggPosition(uid)
	for _, record in ipairs(snapshot()) do
		if record.Uid == uid then
			return record.BottomCFrame.Position
		end
	end
	return nil
end

------------------------------------------------------------------ egg info for the list (icon, name, value)
local function describe(record)
	local directory = type(Assets) == "table" and Assets.Directory or nil
	local entry = type(directory) == "table" and directory[tostring(record.AssetCategory)] or nil
	local info = { Uid = record.Uid, Category = tostring(record.AssetCategory), Name = tostring(record.AssetCategory), Icon = "", Rarity = 0, Value = 0 }

	if type(entry) == "table" then
		info.Name = tostring(entry.DisplayName or record.AssetCategory)
		local icon = entry.Icon
		if icon ~= nil and tostring(icon) ~= "" then
			icon = tostring(icon)
			info.Icon = tonumber(icon) and ("rbxassetid://" .. icon) or icon
		end
		if type(entry.Rarity) == "table" then
			info.Rarity = tonumber(entry.Rarity.RarityNumber or entry.Rarity.Rank) or 0
		end

		local scale = tonumber(record.AssetScale) or 1
		local factor = scale > 5 and (scale / 5) ^ 1.2 * 19.637875755794113 or scale ^ 1.85
		local mutation = 1
		if type(Mutations) == "table" and type(Mutations.EarningsFor) == "function" then
			local okM, resM = pcall(Mutations.EarningsFor, type(record.Mutations) == "table" and record.Mutations or {})
			if okM and type(resM) == "number" then
				mutation = resM
			end
		end
		info.Value = (tonumber(entry.EarningRate) or 0) * factor * mutation
	end

	return info
end

local function money(value)
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if value >= u[1] then
			return string.format("$%.2f%s/s", value / u[1], u[2])
		end
	end
	return string.format("$%d/s", math.floor(value + 0.5))
end

------------------------------------------------------------------ Instant TP logic
local status = function(text) end

local function frozenCamera()
	local camera = workspace.CurrentCamera
	if not camera then
		return function() end
	end
	local oldType = camera.CameraType
	local frame = camera.CFrame
	pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = frame
	end)
	return function()
		pcall(function()
			camera.CameraType = oldType
		end)
	end
end

local fpsGen = 0
local function fpsOn()
	if typeof(setfpscap) ~= "function" then
		return
	end
	fpsGen += 1
	local mine = fpsGen
	task.spawn(function()
		local high = true
		local started = os.clock()
		while fpsGen == mine and os.clock() - started < 60 do
			pcall(setfpscap, high and FPS[1] or FPS[2])
			high = not high
			task.wait(FPS[3])
		end
	end)
end

local function fpsOff()
	fpsGen += 1
	if typeof(setfpscap) == "function" then
		pcall(setfpscap, 240)
	end
end

-- a still copy of the player stays where the egg was taken during the flight; removed on arrival
local stealClone = nil
local function dropClone()
	local copy = stealClone
	stealClone = nil
	if copy then
		pcall(function()
			copy:Destroy()
		end)
	end
end

local function postClone()
	dropClone()
	local character = localPlayer.Character
	if not character then
		return
	end
	local was = character.Archivable
	character.Archivable = true
	local copy = character:Clone()
	character.Archivable = was
	if copy then
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("LuaSourceContainer") or d:IsA("Humanoid") then
				pcall(function()
					d:Destroy()
				end)
			elseif d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
			end
		end
		copy.Name = "Clone"
		copy.Parent = workspace
		stealClone = copy
	end
end

local function lineInfo()
	local world = workspace:FindFirstChild("World") or workspace:FindFirstChild("__OBJECTS")
	world = world and world:FindFirstChild("Areas")
	world = world and world:FindFirstChild("SeparationLine")
	local ok = world and world:IsA("BasePart")
	return ok and world.Position.X or 552.2, ok and world.Position.Y or 67.67
end

local function homePoint()
	for _, def in ipairs({
		{ { "GearGiver_Slap", "Podium" }, Vector3.new(-16.415, 21.072, -6.106) },
		{ { "World", "Machines", "RiftMachine", "Rift", "Meshes/VoidPortal_Cube.003" }, Vector3.new(-26.776, 1.75, 18.665) },
		{ { "__OBJECTS", "Machines", "RiftMachine", "Rift", "Meshes/VoidPortal_Cube.003" }, Vector3.new(-26.776, 1.75, 18.665) },
	}) do
		local node = workspace
		for _, name in ipairs(def[1]) do
			node = node and node:FindFirstChild(name) or nil
		end
		if node and node:IsA("BasePart") then
			return node.CFrame:PointToWorldSpace(def[2])
		end
	end
	return Vector3.new(528.7, 70.57, -364.11)
end

local function place(position)
	local r = root()
	if not r then
		return
	end
	pcall(function()
		r.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(90), 0)
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)
end

-- portals / arenas / teleporters are walked around (same list as the hub)
local dangerCache, dangerAt = {}, 0
local function dangers()
	if os.clock() - dangerAt < 1 then
		return dangerCache
	end
	dangerAt = os.clock()
	local list = {}
	local function add(inst)
		local ok, cf, size = pcall(function()
			if inst:IsA("Model") then
				return inst:GetBoundingBox()
			elseif inst:IsA("BasePart") then
				return inst.CFrame, inst.Size
			end
		end)
		if ok and cf and size then
			local half = Vector3.new(math.abs(size.X), 0, math.abs(size.Z)) * 0.5
			local rot = (cf - cf.Position):VectorToWorldSpace(half)
			local rx = math.max(math.abs(rot.X), half.X, half.Z)
			local rz = math.max(math.abs(rot.Z), half.X, half.Z)
			list[#list + 1] = { MinX = cf.Position.X - rx, MaxX = cf.Position.X + rx, MinZ = cf.Position.Z - rz, MaxZ = cf.Position.Z + rz }
		end
	end
	local function bad(name)
		if name == "ScrambleLocalVisuals" or name == "DrScrambleEvent" then
			return false
		end
		name = string.lower(name)
		return string.find(name, "portal", 1, true) or string.find(name, "teleport", 1, true) or string.find(name, "mech", 1, true) or string.find(name, "arena", 1, true) or string.find(name, "scramble", 1, true)
	end
	for _, child in ipairs(workspace:GetChildren()) do
		if (child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder")) and bad(child.Name) then
			if child:IsA("Folder") then
				for _, inner in ipairs(child:GetChildren()) do
					add(inner)
				end
			else
				add(child)
			end
		end
	end
	local build = workspace:FindFirstChild("World")
	build = build and build:FindFirstChild("Build")
	if build then
		for _, child in ipairs(build:GetChildren()) do
			if bad(child.Name) then
				for _, inner in ipairs(child:GetChildren()) do
					add(inner)
				end
			end
		end
	end
	dangerCache = list
	return list
end

-- if the straight line crosses a danger zone, aim at the corner of it instead
local function avoid(from, to)
	for _, d in ipairs(dangers()) do
		local x0, x1, z0, z1 = d.MinX - 12, d.MaxX + 12, d.MinZ - 12, d.MaxZ + 12
		local inside = from.X >= x0 and from.X <= x1 and from.Z >= z0 and from.Z <= z1
		if not inside then
			local t0, t1, hit = 0, 1, true
			for _, axis in ipairs({ { from.X, to.X - from.X, x0, x1 }, { from.Z, to.Z - from.Z, z0, z1 } }) do
				local pos, delta, lo, hi = axis[1], axis[2], axis[3], axis[4]
				if math.abs(delta) < 1e-6 then
					if pos < lo or pos > hi then
						hit = false
					end
				else
					local ta, tb = (lo - pos) / delta, (hi - pos) / delta
					if ta > tb then
						ta, tb = tb, ta
					end
					t0, t1 = math.max(t0, ta), math.min(t1, tb)
					if t0 > t1 then
						hit = false
					end
				end
			end
			if hit then
				local zLow, zHigh = z0 - 2, z1 + 2
				local z = math.abs(from.Z - zLow) <= math.abs(from.Z - zHigh) and zLow or zHigh
				if z < -440 or z > -290 then
					z = z == zLow and zHigh or zLow
				end
				local x = math.abs(from.X - x0) <= math.abs(from.X - x1) and x0 or x1
				if math.abs(from.Z - z) < 3 then
					x = math.abs(to.X - x0) <= math.abs(to.X - x1) and x0 or x1
				end
				return Vector3.new(x, to.Y, z)
			end
		end
	end
	return to
end

-- the hub's "Run" way to the egg: straight on the ground at 115% of the walk speed (never faster).
-- From the base side it first walks out to the safe-zone point, like the hub does.
local function runToEgg(uid, egg)
	local lineX = lineInfo()
	local home = homePoint()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		if character:FindFirstChildWhichIsA("Tool") then
			pcall(function()
				humanoid:UnequipTools()
			end)
		end
	end

	local r = root()
	if not r then
		return false
	end
	local stage = "field"
	if r.Position.X < lineX - 2 and Vector3.new(r.Position.X - home.X, 0, r.Position.Z - home.Z).Magnitude > 20 then
		stage = "safe"
	end

	local started, lastCheck, lastPos, lastTake = os.clock(), os.clock(), r.Position, 0
	while os.clock() - started < 120 and not state.Cancel do
		r = root()
		if not r then
			return false
		end
		local flatEgg = Vector3.new(egg.X - r.Position.X, 0, egg.Z - r.Position.Z)
		if stage == "field" and flatEgg.Magnitude <= 2.5 then
			break
		end
		local target = egg
		if stage == "safe" then
			if Vector3.new(home.X - r.Position.X, 0, home.Z - r.Position.Z).Magnitude <= 6 then
				stage = "field"
			else
				target = home
			end
		end

		local waypoint = avoid(r.Position, target)
		local flat = Vector3.new(waypoint.X - r.Position.X, 0, waypoint.Z - r.Position.Z)
		local unit = flat.Magnitude > 0.01 and flat.Unit or Vector3.zero
		local speed = math.max(walkSpeed() * CFG.SpeedCap, 8)
		local v = unit * math.min(speed, flat.Magnitude / 0.05)
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(v.X, r.AssemblyLinearVelocity.Y, v.Z)
			if humanoid and unit.Magnitude > 0 then
				humanoid:Move(unit, false)
			end
		end)

		-- stuck on something: jump
		if os.clock() - lastCheck >= 1.5 then
			if (r.Position - lastPos).Magnitude < 3 and humanoid and flatEgg.Magnitude > 15 then
				pcall(function()
					humanoid.Jump = true
				end)
			end
			lastPos, lastCheck = r.Position, os.clock()
		end

		-- close enough for the prompt: ask for the egg while arriving
		if stage == "field" and flatEgg.Magnitude <= 9 and os.clock() - lastTake > 0.1 then
			lastTake = os.clock()
			takeEgg(uid)
		end
		RunService.Heartbeat:Wait()
	end

	r = root()
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(0, r.AssemblyLinearVelocity.Y, 0)
			if humanoid then
				humanoid:Move(Vector3.zero, false)
			end
		end)
	end
	return state.Carrying or (r ~= nil and Vector3.new(egg.X - r.Position.X, 0, egg.Z - r.Position.Z).Magnitude <= 6)
end

-- current position of an egg lying in the world (cheap), with the snapshot as fallback
local function eggNow(uid, cache)
	local node = workspace:FindFirstChild(uid)
	local slots = workspace:FindFirstChild("AreaEggSlotsClient")
	node = node or (slots and slots:FindFirstChild(uid))
	if node then
		local ok, pos = pcall(function()
			return node:GetPivot().Position
		end)
		if ok and pos then
			cache.Pos, cache.At = pos, os.clock()
			return pos
		end
	end
	if os.clock() - cache.At >= 0.5 then
		cache.At = os.clock()
		cache.Pos = eggPosition(uid) or cache.Pos
	end
	return cache.Pos
end

-- take the egg that lies next to us (also used to take it back after the drop): follow it, fire its prompt and send the request
local function grab(uid, timeout)
	local cache = { At = 0 }
	local waited, since = 0, 1
	while not state.Carrying and waited < timeout and not state.Cancel do
		local r = root()
		local egg = eggNow(uid, cache)
		local dt = math.max(RunService.Heartbeat:Wait(), 1 / 240)
		waited += dt
		since += dt
		if r and egg then
			local delta = egg - r.Position
			if delta.Magnitude > 2 then
				local pace = math.max(walkSpeed() * CFG.SpeedCap, 16)
				local v = delta / math.max(0.08, dt)
				if v.Magnitude > pace then
					v = v.Unit * pace
				end
				pcall(function()
					r.AssemblyLinearVelocity = v + Vector3.new(0, workspace.Gravity * dt * 0.5, 0)
					r.AssemblyAngularVelocity = Vector3.zero
				end)
			end
			if since >= CFG.GrabInterval then
				since = 0
				local prompt = promptNear(egg - Vector3.new(0, 3, 0), 10)
				if prompt and typeof(fireproximityprompt) == "function" then
					pcall(function()
						prompt.HoldDuration = 0
					end)
					pcall(fireproximityprompt, prompt)
				end
				task.spawn(takeEgg, uid)
			end
		elseif since >= CFG.GrabInterval then
			since = 0
			task.spawn(takeEgg, uid)
		end
	end
	local r = root()
	if r then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
		end)
	end
	return state.Carrying and state.Uid == uid
end

local function regrab(uid)
	if state.Carrying then
		return true
	end
	local r = root()
	local egg = eggPosition(uid)
	if r and egg and Vector3.new(r.Position.X - egg.X, 0, r.Position.Z - egg.Z).Magnitude > CFG.RegrabFar then
		status("The egg fell far behind, teleporting onto it")
		place(egg + Vector3.new(0, 3, 0))
	else
		status("The egg fell close, taking it back")
	end
	return grab(uid, 3)
end

local function groundY(position, fallback)
	local y = fallback
	pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { localPlayer.Character }
		params.IgnoreWater = true
		local hit = workspace:Raycast(position + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), params)
		if hit and hit.Material ~= Enum.Material.Water and math.abs(hit.Position.Y - fallback) < 40 then
			y = hit.Position.Y + 3.5
		end
	end)
	return y
end

-- safe zone: same route as the Normal mode: checkpoint 7 studs past the line, then the base.
-- Speed = the hub's carry plan (never above 115% of the walk speed), the run starts above the base and comes down.
local function carrySpeed(distance)
	local ws = walkSpeed()
	local base = ws * math.min(CFG.CarryRatio, CFG.SpeedCap) * state.Mult
	local fast = base * 1.5 -- SpeedRatio
	local excess = 5.5 * base -- ExcessSeconds
	local limit = fast
	if distance and distance > excess then
		limit = math.min(fast, base * distance / (distance - excess))
	end
	return math.min(math.max(math.min(base * CFG.EasyRatio, limit), base), math.max(ws * CFG.SpeedCap, base))
end

local function runHome(lineX, laneZ)
	local started = state.Delivered
	local home = homePoint()
	-- Use several confirmed waypoints instead of aiming straight at the base.
	-- The X axis runs from the field (larger X) toward the safe zone (smaller X).
	local checkpoint = lineX - 7
	local height = math.max(20, CFG.Height)
	local share = math.clamp(CFG.ClimbShare, 0.1, 0.9)
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end

	local r = root()
	if not r then
		return false
	end

	-- Start above the route so the character can clear low obstacles.
	if character and home.Y + height - 2 > r.Position.Y then
		pcall(function()
			character:PivotTo(CFrame.new(Vector3.new(r.Position.X, home.Y + height, r.Position.Z)) * r.CFrame.Rotation)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
	end

	local speed = carrySpeed(Vector3.new(r.Position.X - home.X, 0, r.Position.Z - home.Z).Magnitude + height * 2)
	local waypoints = {
		{ Name = "Crossing into safe zone", Pos = Vector3.new(checkpoint, home.Y + height, laneZ), Radius = 5 },
		{ Name = "Aligning with safe-zone lane", Pos = Vector3.new(checkpoint - 4, home.Y + height * 0.8, home.Z), Radius = 5 },
		{ Name = "Approaching base", Pos = Vector3.new(home.X + 7, home.Y + height * 0.35, home.Z), Radius = 4.5 },
		{ Name = "Entering base", Pos = home, Radius = 3.5 },
	}
	local phase = 1
	local last = os.clock()
	local timeout = 0
	status(waypoints[phase].Name)

	while state.Carrying and state.Delivered <= started and not state.Cancel and timeout < 45 do
		r = root()
		if not r then
			return false
		end

		local now = os.clock()
		local dt = math.max(now - last, 1 / 240)
		last = now
		timeout += dt

		local step = waypoints[phase]
		local target = step.Pos
		local flatToTarget = Vector3.new(target.X - r.Position.X, 0, target.Z - r.Position.Z)

		-- Advance only after reaching each waypoint; this prevents the route
		-- from skipping the safe-zone crossing and the final base entrance.
		if flatToTarget.Magnitude <= step.Radius and math.abs(r.Position.Y - target.Y) <= 12 then
			if phase < #waypoints then
				phase += 1
				step = waypoints[phase]
				target = step.Pos
				status(step.Name)
				flatToTarget = Vector3.new(target.X - r.Position.X, 0, target.Z - r.Position.Z)
			else
				break
			end
		end

		local aim = avoid(r.Position, target)
		local flat = Vector3.new(aim.X - r.Position.X, 0, aim.Z - r.Position.Z)
		local unit = flat.Magnitude > 0.01 and flat.Unit or Vector3.zero

		-- Slow down near each waypoint so we don't overshoot it.
		local horizontal = math.sqrt(math.max(speed * speed - (math.clamp((target.Y - r.Position.Y) / 0.12, -speed * share, speed * share)) ^ 2, 0))
		local hSpeed = math.min(horizontal, flat.Magnitude / 0.08)
		local vy = math.clamp((target.Y - r.Position.Y) / 0.12, -speed * share, speed * share)
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.new(unit.X * hSpeed, vy, unit.Z * hSpeed)
			if humanoid and unit.Magnitude > 0 then
				humanoid:Move(unit, false)
			end
		end)

		RunService.Heartbeat:Wait()
	end

	r = root()
	if humanoid then
		pcall(function()
			humanoid:Move(Vector3.zero, false)
		end)
	end

	-- Confirm the character really reached the base before dropping the egg.
	if r and phase >= #waypoints and (r.Position - home).Magnitude <= 9 and state.Carrying and state.Delivered <= started and not state.Cancel then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end)
		status("At base — waiting for delivery")
		local settle = 0
		while settle < 1 and state.Carrying and state.Delivered <= started and not state.Cancel do
			settle += RunService.Heartbeat:Wait()
		end

		-- Retry the final approach/drop a few times if the base doesn't register it.
		for attempt = 1, 3 do
			if state.Delivered > started or not state.Carrying or state.Cancel then
				break
			end
			if attempt > 1 then
				status("Re-entering base (" .. attempt .. "/3)")
				local current = root()
				if current then
					local nudge = Vector3.new(home.X + (attempt == 2 and 2 or -2), home.Y + 2, home.Z)
					pcall(function()
						current.CFrame = CFrame.new(nudge) * current.CFrame.Rotation
						current.AssemblyLinearVelocity = Vector3.zero
					end)
					task.wait(0.25)
				end
			end
			dropEgg()
			local waited = 0
			while waited < 2.5 and state.Delivered <= started and state.Carrying and not state.Cancel do
				waited += RunService.Heartbeat:Wait()
			end
		end
	end

	return state.Delivered > started
end

local function instantTP(uid)
	local started = state.Delivered
	local lineX, lineY = lineInfo()
	local r = root()
	if not r then
		return false
	end
	local laneZ = math.clamp(r.Position.Z, -425, -300)
	local landing = Vector3.new(lineX + CFG.LandOffset, lineY + 3.35, laneZ)

	-- hops towards the line; a pull-back repeats the same hop with a longer pause (the pause is learned)
	local hopStep = math.max(walkSpeed() * CFG.HopRatio, CFG.HopMin)
	local hopY = r.Position.Y + CFG.HopLift
	local x = r.Position.X
	local retries = 0
	local releaseCamera = frozenCamera()
	state.ReleaseCamera = releaseCamera
	pcall(postClone)
	fpsOn()

	while x - hopStep > landing.X and not state.Cancel do
		if not state.Carrying then
			-- the server let go of the egg on the way: take it back right away
			if not regrab(uid) then
				break
			end
			local current = root()
			if current then
				x = math.min(x, current.Position.X)
			end
			continue
		end

		local nextX = x - hopStep
		status(string.format("Instant TP: hopping home, X %d", math.floor(nextX)))
		local pulledBefore = state.PulledAt
		local held = 0
		while held < CFG.HopGap do
			place(Vector3.new(nextX, hopY, laneZ))
			held += RunService.Heartbeat:Wait()
		end

		local check = root()
		local pulled = state.PulledAt > pulledBefore or (check ~= nil and (check.Position.X - nextX > 10 or check.AssemblyLinearVelocity.Magnitude > 150))
		if pulled and state.Carrying and not state.Cancel then
			retries += 1
			CFG.HopGap = math.min(CFG.HopGapMax, CFG.HopGap + 0.02)
			if retries > CFG.HopRetries then
				break
			end
			status(string.format("Instant TP: pulled back, retry %d/%d", retries, CFG.HopRetries))
			local settle = 0
			while settle < 0.12 and not state.Cancel do
				place(Vector3.new(x, hopY, laneZ))
				settle += RunService.Heartbeat:Wait()
			end
		else
			x = nextX
			CFG.HopGap = math.max(CFG.HopGapMin, CFG.HopGap - 0.01)
		end
	end

	-- landing in front of the line
	status("Instant TP: landing next to the line")
	landing = Vector3.new(landing.X, groundY(landing, landing.Y), landing.Z)
	local function land()
		local current = root()
		-- never jump backwards: if we are already closer to the line than the landing spot, stay
		if current and current.Position.X <= landing.X + 1 and current.Position.Y > landing.Y - 25 then
			pcall(function()
				current.AssemblyLinearVelocity = Vector3.zero
			end)
			return
		end
		place(landing)
	end
	land()
	for attempt = 1, 3 do
		local settle = 0
		while settle < CFG.LandSettle and not state.Cancel do
			settle += RunService.Heartbeat:Wait()
		end
		local landed = root()
		if state.Carrying and landed and (landed.Position.X - landing.X > 12 or landed.Position.Y < landing.Y - 25) then
			status("Instant TP: landing retry " .. attempt)
			land()
		else
			break
		end
	end
	dropClone()

	-- drop at the line, take it back
	if state.Carrying and not state.Cancel then
		local delay = 0
		while delay < CFG.DropDelay do
			delay += RunService.Heartbeat:Wait()
		end
		status("Instant TP: dropping the egg")
		dropEgg()
		local waited = 0
		while state.Carrying and waited < 1 and not state.Cancel do
			waited += RunService.Heartbeat:Wait()
		end
		local current = root()
		if current then
			pcall(function()
				current.AssemblyLinearVelocity = Vector3.zero
				current.AssemblyAngularVelocity = Vector3.zero
			end)
		end
		-- egg is down: let go of the camera and the copy, then take it back
		releaseCamera()
		dropClone()
		status("Instant TP: taking the egg back")
		if not grab(uid, 3) and not regrab(uid) then
			fpsOff()
			status("Could not take the egg back")
			return false
		end
		dropClone()
	end
	releaseCamera()

	-- straight to the safe zone
	local ok = false
	if state.Carrying then
		ok = runHome(lineX, laneZ)
	end
	fpsOff()
	return ok or state.Delivered >= started
end

local requestRefresh -- forward declaration: refresh immediately after stealing

local function stealAndDeliver(uid)
	if state.Busy then
		return
	end
	state.Busy = true
	state.Cancel = false
	task.spawn(function()
		-- Prevent a manual/auto-jump from interrupting the carry route.
		-- Restore the player's original jump settings when delivery finishes.
		local jumpHumanoid = nil
		local jumpingWasEnabled = true
		local autoJumpWasEnabled = true
		-- Also hide the on-screen mobile jump button while stealing/delivering.
		local hiddenJumpButtons = {}
		local function lockJumping()
			local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
			if playerGui then
				for _, button in ipairs(playerGui:GetDescendants()) do
					if button.Name == "JumpButton" and button:IsA("GuiObject") then
						if hiddenJumpButtons[button] == nil then
							 hiddenJumpButtons[button] = button.Visible
						end
						button.Visible = false
					end
				end
			end
			local character = localPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid ~= jumpHumanoid then
				jumpHumanoid = humanoid
				pcall(function()
					jumpingWasEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
					autoJumpWasEnabled = humanoid.AutoJumpEnabled
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
					humanoid.AutoJumpEnabled = false
					humanoid.Jump = false
				end)
			elseif humanoid then
				pcall(function()
					humanoid.Jump = false
				end)
			end
		end
		local jumpLockConnection = RunService.Heartbeat:Connect(lockJumping)
		lockJumping()
		local ok, err = pcall(function()
			status("Looking for the egg")
			local egg = eggPosition(uid)
			if not egg then
				status("That egg is gone")
				return
			end
			if state.Carrying and state.Uid ~= uid then
				dropEgg()
				local waited = 0
				while state.Carrying and waited < 1 do
					waited += RunService.Heartbeat:Wait()
				end
			end
			fpsOn()
			status("Going to the egg")
			if not runToEgg(uid, egg) then
				fpsOff()
				status("Could not reach the egg")
				return
			end
			status("Taking the egg")
			if not grab(uid, 4) then
				fpsOff()
				status("The egg would not come free")
				return
			end
			local delivered = instantTP(uid)
			status(delivered and "Delivered" or "Delivery failed")
		end)
		fpsOff()
		dropClone()
		if state.ReleaseCamera then
			pcall(state.ReleaseCamera)
			state.ReleaseCamera = nil
		end
		if not ok then
			status("Error: " .. tostring(err))
		end
		if jumpLockConnection then
			jumpLockConnection:Disconnect()
		end
		if jumpHumanoid and jumpHumanoid.Parent then
			pcall(function()
				jumpHumanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, jumpingWasEnabled)
				jumpHumanoid.AutoJumpEnabled = autoJumpWasEnabled
				jumpHumanoid.Jump = false
			end)
		end
		for button, wasVisible in pairs(hiddenJumpButtons) do
			if button and button.Parent then
				pcall(function() button.Visible = wasVisible end)
			end
		end
		state.Busy = false
		-- Refresh the egg list after success, failure, or cancellation so removed/changed eggs disappear.
		task.defer(function()
			if requestRefresh and not closed then
				requestRefresh()
			end
		end)
	end)
end

------------------------------------------------------------------ UI: full black + RGBStyle
-- RGBStyle = the hub's living effect: gradient bands that keep turning on every stroke and every text.
local WHITE = Color3.fromRGB(110, 255, 80) -- SWAG neon green
local SILVER = Color3.fromRGB(0, 220, 255) -- electric cyan
local STEEL = Color3.fromRGB(150, 80, 255) -- RGB violet
local BG = Color3.fromRGB(8, 12, 18)
local RARITY_COLORS = {
	Color3.fromRGB(190, 190, 190), Color3.fromRGB(110, 210, 110), Color3.fromRGB(90, 160, 255),
	Color3.fromRGB(190, 110, 255), Color3.fromRGB(255, 170, 50), Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 90, 200), Color3.fromRGB(80, 235, 235),
}

local function parentGui()
	if typeof(gethui) == "function" then
		local ok, result = pcall(gethui)
		if ok and typeof(result) == "Instance" then
			return result
		end
	end
	return CoreGui
end

local function make(class, props)
	local inst = Instance.new(class)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	return inst
end

local function corner(parent, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }).Parent = parent
end

local living = {}
local function bands(a, b)
	-- Full rainbow spectrum, animated by the shared rotating gradients.
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 45, 75)),
		ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 145, 35)),
		ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 240, 55)),
		ColorSequenceKeypoint.new(0.50, Color3.fromRGB(55, 255, 115)),
		ColorSequenceKeypoint.new(0.67, Color3.fromRGB(45, 190, 255)),
		ColorSequenceKeypoint.new(0.83, Color3.fromRGB(150, 75, 255)),
		ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 55, 205)),
	})
end

-- living stroke (bands turning around the border)
local function livingStroke(parent, thickness, bright)
	local s = make("UIStroke", { Thickness = thickness or 1, Color = WHITE, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	s.Parent = parent
	local g = make("UIGradient", { Rotation = 45, Color = bands(bright and WHITE or SILVER, STEEL) })
	g.Parent = s
	living[#living + 1] = g
	return s, g
end

-- living text (bands moving through the letters)
local function livingText(label)
	local g = make("UIGradient", { Color = bands(WHITE, SILVER) })
	g.Parent = label
	living[#living + 1] = g
	return g
end

local function text(parent, props)
	local alive = props.Living ~= false
	props.Living = nil
	props.BackgroundTransparency = 1
	props.TextColor3 = props.TextColor3 or WHITE
	local l = make("TextLabel", props)
	l.Parent = parent
	if alive then
		livingText(l)
	end
	return l
end

-- Remove every stale copy, not just the first matching ScreenGui.
local guiParent = parentGui()
for _, child in ipairs(guiParent:GetChildren()) do
	if child.Name == "SWAG_HUB V1" and child:IsA("ScreenGui") then
		pcall(function() child:Destroy() end)
	end
end

local gui = make("ScreenGui", { Name = "SWAG_HUB V1", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true })
gui.Parent = parentGui()

local W, H, HEADER = 320, 360, 40
local window = make("Frame", { Size = UDim2.fromOffset(W, H), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2), BackgroundColor3 = BG, BorderSizePixel = 0, ClipsDescendants = false })
window.Parent = gui
corner(window, 18)
livingStroke(window, 2, true)
local windowScale = make("UIScale", { Scale = 1 })
windowScale.Parent = window
local function tween(object, duration, props, style, direction)
    local ok, result = pcall(function()
        return TweenService:Create(object, TweenInfo.new(duration, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out), props)
    end)
    if ok and result then result:Play(); return result end
end
local function popWindow(show)
    if show then
        window.Visible = true
        windowScale.Scale = 0.88
        window.BackgroundTransparency = 0.18
        tween(windowScale, 0.36, {Scale = 1}, Enum.EasingStyle.Elastic)
        tween(window, 0.22, {BackgroundTransparency = 0})
        local oldRotation = window.Rotation
        window.Rotation = -1.5
        tween(window, 0.28, {Rotation = oldRotation}, Enum.EasingStyle.Back)
    else
        tween(windowScale, 0.16, {Scale = 0.88}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        local fade = tween(window, 0.16, {BackgroundTransparency = 0.25}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        if fade then fade.Completed:Connect(function() if window.Parent and not window.Visible then window.BackgroundTransparency = 0 end end) end
        task.delay(0.16, function() if window.Parent then window.Visible = false; windowScale.Scale = 1; window.BackgroundTransparency = 0 end end)
    end
end

-- Floating circular launcher: tap/click the rainbow S to show or hide the hub.
local launcher = make("TextButton", {
	Name = "SWAG_HUB_Launcher",
	Size = UDim2.fromOffset(54, 54),
	Position = UDim2.new(0, 22, 0.5, -27),
	BackgroundColor3 = Color3.fromRGB(10, 12, 20),
	BorderSizePixel = 0,
	Text = "S",
	Font = Enum.Font.GothamBlack,
	TextSize = 25,
	TextColor3 = Color3.new(1, 1, 1),
	AutoButtonColor = true,
	ZIndex = 20,
})
launcher.Parent = gui
corner(launcher, 100)
local launcherStroke = livingStroke(launcher, 3, true)
livingText(launcher)
-- Soft breathing glow for the circular S launcher. Size animation does not reset its dragged position.
local launcherAlive = true
task.spawn(function()
    local up = true
    while launcherAlive and launcher.Parent do
        local targetSize = up and UDim2.fromOffset(57,57) or UDim2.fromOffset(54,54)
        tween(launcher, 0.75, {Size = targetSize}, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        tween(launcherStroke, 0.75, {Transparency = up and 0.02 or 0.35}, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
        up = not up
        task.wait(0.76)
    end
end)
make("UIStroke", {Thickness = 1, Color = Color3.fromRGB(255,255,255), Transparency = 0.35}).Parent = launcher

-- Extra premium effects: a rainbow halo, tiny orbiting sparks, and a subtle hover pop.
local launcherHalo = make("Frame", {
    Name = "RainbowHalo", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 14, 1, 14),
    BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 19,
})
launcherHalo.Parent = launcher
corner(launcherHalo, 100)
local haloStroke = make("UIStroke", {Thickness = 1.5, Transparency = 0.18, Color = Color3.new(1,1,1)})
haloStroke.Parent = launcherHalo
local haloGradient = make("UIGradient", {Color = bands(WHITE, STEEL), Rotation = 0})
haloGradient.Parent = haloStroke

local sparkContainer = make("Frame", {Name = "Sparkles", BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 23})
sparkContainer.Parent = launcher
local sparkleAlive = true
task.spawn(function()
    local phase = 0
    while sparkleAlive and launcher.Parent do
        phase = (phase + 1) % 360
        haloGradient.Rotation = (haloGradient.Rotation + 3) % 360
        local pulse = 1 + 0.06 * math.sin(math.rad(phase * 2))
        launcherHalo.Size = UDim2.new(1, 14 * pulse, 1, 14 * pulse)
        haloStroke.Transparency = 0.12 + 0.22 * ((math.sin(math.rad(phase * 2)) + 1) / 2)
        task.wait(0.035)
    end
end)

-- Occasional little twinkles around the launcher; bounded count to keep it lightweight.
task.spawn(function()
    local colors = {
        Color3.fromRGB(255, 70, 100), Color3.fromRGB(255, 190, 45),
        Color3.fromRGB(70, 255, 150), Color3.fromRGB(70, 210, 255),
        Color3.fromRGB(190, 90, 255), Color3.fromRGB(255, 90, 220),
    }
    while sparkleAlive and launcher.Parent do
        local dot = make("Frame", {
            Name = "RGBTwinkle", AnchorPoint = Vector2.new(0.5,0.5),
            Position = UDim2.fromScale(math.random(5,95)/100, math.random(5,95)/100),
            Size = UDim2.fromOffset(3,3), BackgroundColor3 = colors[math.random(1,#colors)],
            BorderSizePixel = 0, BackgroundTransparency = 0, ZIndex = 24,
        })
        dot.Parent = sparkContainer
        corner(dot, 100)
        local endPos = UDim2.new(dot.Position.X.Scale, math.random(-14,14), dot.Position.Y.Scale, math.random(-14,14))
        tween(dot, 0.48, {Position = endPos, Size = UDim2.fromOffset(0,0), BackgroundTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        task.delay(0.52, function() if dot and dot.Parent then dot:Destroy() end end)
        task.wait(0.12)
    end
end)

launcher.MouseEnter:Connect(function()
    tween(launcher, 0.16, {Rotation = 8}, Enum.EasingStyle.Back)
end)
launcher.MouseLeave:Connect(function()
    tween(launcher, 0.16, {Rotation = 0}, Enum.EasingStyle.Back)
end)

local rotation = 0
local tick = 0
local shineConnection = RunService.Heartbeat:Connect(function(dt)
	tick += 1
	if tick % 2 ~= 0 then
		return
	end
	rotation = (rotation + dt * 72) % 360
	for _, g in ipairs(living) do
		if g.Parent then
			g.Rotation = g.Parent:IsA("UIStroke") and (45 + rotation) % 360 or rotation
		end
	end
end)

-- header: living light bar, the title is black
local header = make("Frame", { Size = UDim2.new(1, -12, 0, HEADER - 6), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = WHITE, BorderSizePixel = 0 })
header.Parent = window
corner(header, 10)
do
	local g = make("UIGradient", { Color = bands(WHITE, SILVER) })
	g.Parent = header
	living[#living + 1] = g
end
text(header, {
	Size = UDim2.new(1, -92, 1, 0), Position = UDim2.fromOffset(12, 0), Font = Enum.Font.GothamBlack, TextSize = 15,
	TextColor3 = Color3.fromRGB(5, 12, 16), TextXAlignment = Enum.TextXAlignment.Left, Text = "SWAG_HUB V1", Living = false,
})

local function headerButton(label, offset)
	local b = make("TextButton", { Size = UDim2.fromOffset(25, 24), Position = UDim2.new(1, offset, 0.5, -12), BackgroundColor3 = BG, Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = WHITE, Text = label, AutoButtonColor = true })
	b.Parent = header
	corner(b, 7)
	livingStroke(b, 1, true)
	livingText(b)
	return b
end
local minimize = headerButton("−", -55)
local close = headerButton("×", -25)

local body = make("Frame", { Size = UDim2.new(1, -16, 1, -(HEADER + 14)), Position = UDim2.fromOffset(8, HEADER + 8), BackgroundTransparency = 1 })
body.Parent = window

local subtitle = text(body, {
	Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(2, 0), Font = Enum.Font.GothamMedium, TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(165, 190, 200), Text = "EGG FINDER  •  AUTO REFRESH", Living = false,
})

local list = make("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -128), Position = UDim2.fromOffset(0, 24), BackgroundColor3 = Color3.fromRGB(11, 18, 26), BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = WHITE,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
})
list.Parent = body
corner(list, 12)
livingStroke(list, 1, false)
make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }).Parent = list
make("UIPadding", { PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7), PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }).Parent = list

local statusLabel = text(body, {
	Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 1, -61), Font = Enum.Font.GothamMedium, TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "Pick a pet",
})

-- the panel only shows what happens to the egg, never timings or internals
local PUBLIC = { ["Pick a pet"] = true, ["Looking for the egg"] = true, ["Going to the egg"] = true, ["Taking the egg"] = true, ["Delivered"] = true, ["Delivery failed"] = true, ["That egg is gone"] = true, ["Could not reach the egg"] = true, ["The egg would not come free"] = true, ["Cancelling"] = true }
status = function(msg)
	msg = tostring(msg)
	if PUBLIC[msg] or string.sub(msg, 1, 9) == "Selected:" then
		statusLabel.Text = msg
	elseif string.sub(msg, 1, 5) == "Error" then
		statusLabel.Text = "Something went wrong"
	elseif state.Busy then
		statusLabel.Text = "Delivering"
	end
end

local function bigButton(label, position, size)
	local b = make("TextButton", { Size = size, Position = position, BackgroundColor3 = BG, Font = Enum.Font.GothamBlack, TextSize = 14, TextColor3 = WHITE, Text = label, AutoButtonColor = true })
	b.Parent = body
	corner(b, 17)
	livingStroke(b, 1, true)
	livingText(b)
	return b
end
-- Auto Farm toggle; the existing STEAL button is reused.
local autoFarmEnabled = false
local autoFarmButton = bigButton("AUTO FARM: OFF", UDim2.new(0, 0, 1, -80), UDim2.new(1, 0, 0, 36))
local refreshButton = bigButton("↻  REFRESH", UDim2.new(0, 0, 1, -38), UDim2.new(0.43, -4, 0, 38))
local stealButton = bigButton("STEAL EGG  →", UDim2.new(0.43, 4, 1, -38), UDim2.new(0.57, -4, 0, 38))

local selectedUid = nil
local rows = {}
local refreshing = false
local refreshQueued = false
local closed = false
local uiConnections = {}
local function trackConnection(connection)
	uiConnections[#uiConnections + 1] = connection
	return connection
end
local function disconnectUI()
	for _, connection in ipairs(uiConnections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(uiConnections)
end

local function setSelected(uid)
	selectedUid = uid
	for rowUid, row in pairs(rows) do
		local on = rowUid == uid
		row.Stroke.Thickness = on and 1.5 or 1
		row.Gradient.Color = on and bands(WHITE, SILVER) or bands(Color3.fromRGB(50, 70, 78), Color3.fromRGB(30, 38, 48))
	end
end

local function rebuild()
	if refreshing or closed or not gui.Parent then
		refreshQueued = true
		return
	end
	refreshing = true
	refreshQueued = false
	-- Clear every old row directly from the list, not only rows tracked by UID.
	-- If the server returns duplicate UIDs, the rows table can track just one of them,
	-- leaving an untracked duplicate visible after refresh.
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(rows)
	-- drop gradients whose parents are gone
	for i = #living, 1, -1 do
		if not living[i].Parent then
			table.remove(living, i)
		end
	end

	local infos = {}
	local seenUids = {}
	for _, record in ipairs(snapshot()) do
		local uid = tostring(record.Uid or "")
		if uid ~= "" and not seenUids[uid] then
			seenUids[uid] = true
			infos[#infos + 1] = describe(record)
		end
	end
	table.sort(infos, function(a, b)
		return a.Value > b.Value
	end)

	local still = false
	for index, info in ipairs(infos) do
		still = still or info.Uid == selectedUid
		local frame = make("TextButton", { Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = Color3.fromRGB(13, 20, 29), LayoutOrder = index, Text = "", AutoButtonColor = true })
		frame.Parent = list
        frame.BackgroundTransparency = 0.35
        local rowScale = make("UIScale", {Scale = 0.94})
        rowScale.Parent = frame
        task.delay(math.min(index * 0.035, 0.35), function()
            if frame.Parent then
                tween(frame, 0.22, {BackgroundTransparency = 0}, Enum.EasingStyle.Quad)
                tween(rowScale, 0.25, {Scale = 1}, Enum.EasingStyle.Back)
            end
        end)
		corner(frame, 10)
		local rowStroke, rowGradient = livingStroke(frame, 1, false)

		make("ImageLabel", { Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(5, 4), BackgroundTransparency = 1, Image = info.Icon, ScaleType = Enum.ScaleType.Fit }).Parent = frame
		text(frame, {
			Size = UDim2.new(1, -48, 0, 19), Position = UDim2.fromOffset(46, 4), Font = Enum.Font.GothamBold, TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = info.Name,
			TextColor3 = RARITY_COLORS[math.clamp(info.Rarity, 1, #RARITY_COLORS)] or WHITE,
		})
		text(frame, {
			Size = UDim2.new(1, -48, 0, 15), Position = UDim2.fromOffset(46, 22), Font = Enum.Font.GothamMedium, TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left, Text = money(info.Value),
		})

		rows[info.Uid] = { Frame = frame, Stroke = rowStroke, Gradient = rowGradient }
		frame.MouseButton1Click:Connect(function()
			setSelected(info.Uid)
			status("Selected: " .. info.Name)
		end)
	end

	setSelected(still and selectedUid or nil)
	if #infos == 0 then
		selectedUid = nil
		status("Pick a pet")
	end
	refreshing = false
end

requestRefresh = function()
	if closed or state.Busy then return end
	if refreshing then
		refreshQueued = true
		return
	end
	rebuild()
	if refreshQueued and not state.Busy and not closed then
		refreshQueued = false
		task.defer(function()
			if not closed and not state.Busy then rebuild() end
		end)
	end
end

local function buttonMotion(button)
    local original = button.Size
    button.MouseButton1Down:Connect(function()
        tween(button, 0.07, {Size = UDim2.new(original.X.Scale, original.X.Offset, original.Y.Scale, math.max(30, original.Y.Offset - 3))}, Enum.EasingStyle.Quad)
    end)
    button.MouseButton1Up:Connect(function() tween(button, 0.12, {Size = original}, Enum.EasingStyle.Back) end)
    button.MouseEnter:Connect(function() tween(button, 0.14, {BackgroundColor3 = Color3.fromRGB(28, 22, 42)}, Enum.EasingStyle.Quad) end)
    button.MouseLeave:Connect(function() tween(button, 0.14, {BackgroundColor3 = BG}, Enum.EasingStyle.Quad) end)
end
buttonMotion(autoFarmButton)
buttonMotion(refreshButton)
buttonMotion(stealButton)
trackConnection(refreshButton.MouseButton1Click:Connect(requestRefresh))

trackConnection(autoFarmButton.Activated:Connect(function()
	autoFarmEnabled = not autoFarmEnabled
	autoFarmButton.Text = autoFarmEnabled and "AUTO FARM: ON" or "AUTO FARM: OFF"
	autoFarmButton.BackgroundColor3 = autoFarmEnabled and Color3.fromRGB(20, 105, 75) or BG
	status(autoFarmEnabled and "Auto Farm enabled" or "Auto Farm disabled")
end))

trackConnection(stealButton.MouseButton1Click:Connect(function()
	if state.Busy then
		state.Cancel = true
		status("Cancelling")
		return
	end

	if autoFarmEnabled then
		task.spawn(function()
			-- Re-scan after every attempt so eggs that appear later are also discovered.
			-- Each UID is attempted once per run to avoid getting stuck retrying a failed egg forever.
			local attempted = {}
			local completed = 0
			local failed = 0
			while gui.Parent and autoFarmEnabled and not state.Cancel do
				local nextUid = nil
				for _, record in ipairs(snapshot()) do
					local uid = type(record) == "table" and tostring(record.Uid or "") or ""
					if uid ~= "" and not attempted[uid] then
						nextUid = uid
						break
					end
				end
				if not nextUid then
					break
				end

				attempted[nextUid] = true
				local beforeDelivered = state.Delivered
				if eggPosition(nextUid) then
					status("Auto Farm: egg " .. (completed + failed + 1))
					stealAndDeliver(nextUid)
					local startedAt = os.clock()
					while state.Busy and gui.Parent and os.clock() - startedAt < 45 do
						task.wait(0.1)
					end
					if state.Busy then
						state.Cancel = true
						status("Auto Farm stopped: steal timed out")
						break
					end
					if state.Delivered > beforeDelivered then
						completed += 1
					else
						failed += 1
					end
					task.wait(0.25)
				else
					-- It disappeared between the scan and the attempt; don't retry this UID.
					failed += 1
				end
			end
			if gui.Parent then
				if autoFarmEnabled and not state.Cancel then
					status("Auto Farm done: " .. completed .. " delivered, " .. failed .. " failed")
				else
					status("Auto Farm stopped: " .. completed .. " delivered")
				end
			end
		end)
		return
	end

	if not selectedUid then
		status("Pick a pet")
		return
	end
	stealAndDeliver(selectedUid)
end))

task.spawn(function()
	while gui.Parent do
		task.wait(0.25)
		stealButton.Text = state.Busy and "Cancel" or (autoFarmEnabled and "STEAL ALL EGGS  →" or "STEAL EGG  →")
	end
end)

-- Smooth, reliable drag support (mouse + touchscreen).
-- Drag the rainbow title bar to move the panel; header buttons remain clickable.
do
	window.Active = true
	header.Active = true
	local dragging = false
	local dragStart = nil
	local startPosition = nil
	local dragInput = nil

	trackConnection(header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = window.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					dragInput = nil
				end
			end)
		end
	end))

	trackConnection(header.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end))

	trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and dragStart and startPosition and
			(input == dragInput or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			window.Position = UDim2.new(
				startPosition.X.Scale, startPosition.X.Offset + delta.X,
				startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
			)
		end
	end))
end

-- Make the circular S launcher itself draggable on mouse and touchscreen.
-- A drag does not trigger the open/close action when the pointer is released.
local launcherDragging = false
local launcherMoved = false
local launcherStartInput = nil
local launcherStartPos = nil
local launcherDragInput = nil
local launcherDownPos = nil

trackConnection(launcher.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        launcherDragging = true
        launcherMoved = false
        launcherStartInput = input
        launcherStartPos = launcher.Position
        launcherDownPos = input.Position
        launcherDragInput = nil
    end
end))

trackConnection(launcher.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        launcherDragInput = input
    end
end))

trackConnection(UserInputService.InputChanged:Connect(function(input)
    if launcherDragging and launcherStartPos and launcherDownPos and
       (input == launcherDragInput or input == launcherStartInput) then
        local delta = input.Position - launcherDownPos
        if math.abs(delta.X) > 5 or math.abs(delta.Y) > 5 then
            launcherMoved = true
        end
        if launcherMoved then
            launcher.Position = UDim2.new(
                launcherStartPos.X.Scale, launcherStartPos.X.Offset + delta.X,
                launcherStartPos.Y.Scale, launcherStartPos.Y.Offset + delta.Y
            )
        end
    end
end))

trackConnection(UserInputService.InputEnded:Connect(function(input)
    if launcherDragging and (input == launcherStartInput or input.UserInputType == Enum.UserInputType.MouseButton1) then
        launcherDragging = false
        launcherStartInput = nil
        launcherStartPos = nil
        launcherDownPos = nil
        launcherDragInput = nil
    end
end))

trackConnection(launcher.MouseButton1Click:Connect(function()
    if launcherMoved then
        launcherMoved = false
        return
    end
    popWindow(not window.Visible)
end))

trackConnection(minimize.MouseButton1Click:Connect(function()
    popWindow(false)
end))

local function cleanup()
	if closed then return end
	closed = true
	state.Cancel = true
	fpsOff()
	shieldStop()
	dropClone()
	if state.ReleaseCamera then
		pcall(state.ReleaseCamera)
		state.ReleaseCamera = nil
	end
	if shineConnection then shineConnection:Disconnect() end
	disconnectUI()
end

trackConnection(close.MouseButton1Click:Connect(function()
	-- Keep the floating S launcher alive so the panel can be reopened.
	popWindow(false)
end))
trackConnection(gui.Destroying:Connect(function() launcherAlive = false; cleanup() end))

-- Initial pop-in, then automatically refresh the list on a fixed interval.
windowScale.Scale = 0.88
window.BackgroundTransparency = 0.18
tween(windowScale, 0.32, {Scale = 1}, Enum.EasingStyle.Back)
tween(window, 0.24, {BackgroundTransparency = 0})
-- requestRefresh prevents overlapping refreshes; skip refresh while stealing or minimized.
requestRefresh()
task.spawn(function()
	while not closed and gui.Parent do
		task.wait(AUTO_REFRESH_INTERVAL)
		if closed or not gui.Parent then break end
		if not state.Busy and body.Visible then
			requestRefresh()
		end
	end
end)

shieldStart()


------------------------------------------------------------------ SWAG_HUB V1 key gate
-- Client-side key checks are a convenience gate, not secure authentication.
local REQUIRED_KEY = "swas_swas_swagg"
window.Visible = false
launcher.Visible = false
local keyOverlay = make("Frame", {
    Name = "SWAG_HUB_KeySystem", Size = UDim2.fromScale(1, 1),
    Position = UDim2.fromScale(0, 0), BackgroundColor3 = Color3.fromRGB(5, 7, 15),
    BackgroundTransparency = 0.08, BorderSizePixel = 0, ZIndex = 100,
})
keyOverlay.Parent = gui
local keyCard = make("Frame", {
    Size = UDim2.fromOffset(330, 225), AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(15, 18, 32),
    BorderSizePixel = 0, ZIndex = 101,
})
keyCard.Parent = keyOverlay
corner(keyCard, 18)
livingStroke(keyCard, 2, true)
local keyTitle = make("TextLabel", {
    Size = UDim2.new(1, -24, 0, 42), Position = UDim2.fromOffset(12, 12),
    BackgroundTransparency = 1, Text = "SWAG_HUB V1  •  KEY SYSTEM", TextColor3 = Color3.new(1,1,1),
    Font = Enum.Font.GothamBlack, TextSize = 17, ZIndex = 102,
})
keyTitle.Parent = keyCard
-- Drag the key window using its title bar; supports mouse and touch.
local keyDragging = false
local keyDragStart, keyCardStart
local keyDragInput
keyTitle.Active = true
keyTitle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        keyDragging = true
        keyDragStart = input.Position
        keyCardStart = keyCard.Position
        keyDragInput = input
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                keyDragging = false
                keyDragInput = nil
            end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if keyDragging and keyDragStart and keyCardStart and
       (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - keyDragStart
        keyCard.Position = UDim2.new(keyCardStart.X.Scale, keyCardStart.X.Offset + delta.X,
                                     keyCardStart.Y.Scale, keyCardStart.Y.Offset + delta.Y)
    end
end)
livingText(keyTitle)
local keyHint = make("TextLabel", {
    Size = UDim2.new(1, -28, 0, 28), Position = UDim2.fromOffset(14, 55),
    BackgroundTransparency = 1, Text = "Enter your access key to continue", TextColor3 = Color3.fromRGB(190,198,220),
    Font = Enum.Font.Gotham, TextSize = 13, ZIndex = 102,
})
keyHint.Parent = keyCard
local keyInput = make("TextBox", {
    Size = UDim2.new(1, -36, 0, 42), Position = UDim2.fromOffset(18, 91),
    BackgroundColor3 = Color3.fromRGB(25, 29, 47), BorderSizePixel = 0,
    PlaceholderText = "Enter key...", Text = "", ClearTextOnFocus = false,
    TextColor3 = Color3.new(1,1,1), PlaceholderColor3 = Color3.fromRGB(130,140,165),
    Font = Enum.Font.Gotham, TextSize = 14, ZIndex = 102,
})
keyInput.Parent = keyCard
corner(keyInput, 10)
local keyButton = make("TextButton", {
    Size = UDim2.new(1, -36, 0, 40), Position = UDim2.fromOffset(18, 145),
    BackgroundColor3 = Color3.fromRGB(45, 210, 125), BorderSizePixel = 0,
    Text = "UNLOCK HUB", TextColor3 = Color3.fromRGB(5, 12, 10),
    Font = Enum.Font.GothamBlack, TextSize = 14, ZIndex = 102,
})
keyButton.Parent = keyCard
corner(keyButton, 10)
local function validateKey()
    if keyInput.Text == REQUIRED_KEY then
        keyHint.Text = "KEY ACCEPTED — welcome!"
        keyHint.TextColor3 = Color3.fromRGB(90, 255, 160)
        keyButton.Text = "UNLOCKED ✓"
        task.wait(0.25)
        if keyOverlay.Parent then keyOverlay:Destroy() end
        launcher.Visible = true
        popWindow(true)
    else
        keyHint.Text = "Incorrect key. Please try again."
        keyHint.TextColor3 = Color3.fromRGB(255, 95, 110)
        keyInput.Text = ""
    end
end
keyButton.Activated:Connect(validateKey)
keyInput.FocusLost:Connect(function(enterPressed)
    if enterPressed then validateKey() end
end)
