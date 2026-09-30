--// ShopARide.lua - Modul Shop untuk Rossi.Draft (Ride A Pet)
--// Upload ke: https://raw.githubusercontent.com/lyoraaHBX/Module-Lyora/refs/heads/main/ShopARide.lua
--//
--// Dipanggil dari main:
--//   local Shop = loadstring(game:HttpGet(SHOP_URL))()
--//   Shop.Init({ ... })   -- lihat daftar ctx di bawah

local Module = {}

--[[
ctx yang dibutuhkan:
	Luno        : library LUNO UI (dipakai untuk Luno.Flags)
	ShopTab     : tab "Shop" yang sudah dibuat di main
	LocalPlayer : Players.LocalPlayer
	RunService  : RunService
	Remotes     : ReplicatedStorage.Remotes.Game
	Data        : tabel GameData (butuh Data.Shop)
	Util        : util main (butuh Util.Fire dan Util.Cash)
	On          : function(flag) -> boolean
	ToSet       : function(list) -> set
	OnCleanup   : function(fn) untuk daftar cleanup
	IsRunning   : function() -> boolean (false saat script dimatikan)
]]

function Module.Init(ctx)
	assert(type(ctx) == "table", "ShopARide: ctx tidak valid")

	local localPlayer = ctx.LocalPlayer
	local RunService = ctx.RunService
	local Remotes = ctx.Remotes
	local Data = ctx.Data
	local Util = ctx.Util
	local On = ctx.On
	local ToSet = ctx.ToSet
	local OnCleanup = ctx.OnCleanup
	local IsRunning = ctx.IsRunning
	local ShopTab = ctx.ShopTab

	-----------------------------------------------------------------
	-- STATE
	-----------------------------------------------------------------
	local ShopSelected = { Food = {}, Gears = {} }
	local shopStock = { Food = nil, Gears = nil }
	local shopCooldown = {}
	local keepCash = 0
	local ShopFlags = { Food = "AutoBuyFood", Gears = "AutoBuyRadars" }

	-----------------------------------------------------------------
	-- DATA HELPERS
	-----------------------------------------------------------------
	local function shopNames(category)
		local list = {}
		local shop = Data.Shop
		local cat = type(shop) == "table" and shop[category] or nil
		if type(cat) == "table" then
			for name, item in pairs(cat) do
				if type(item) == "table" then
					table.insert(list, { Name = name, Price = tonumber(item.Price) or 0 })
				end
			end
		end
		table.sort(list, function(a, b)
			return a.Price < b.Price
		end)
		local names = {}
		for _, it in ipairs(list) do
			table.insert(names, it.Name)
		end
		return names
	end

	local function shopPrice(category, name)
		local shop = Data.Shop
		local cat = type(shop) == "table" and shop[category] or nil
		local item = type(cat) == "table" and cat[name] or nil
		return type(item) == "table" and tonumber(item.Price) or math.huge
	end

	local function readStock(payload)
		if type(payload) ~= "table" then
			return
		end
		for key, group in pairs(payload) do
			if (key == "Food" or key == "Gears") and type(group) == "table" then
				local stock = {}
				for itemName, info in pairs(group) do
					if type(info) == "table" then
						stock[itemName] = tonumber(info.Amount) or info.InStock and 1 or 0
					end
				end
				shopStock[key] = stock
			end
		end
	end

	-----------------------------------------------------------------
	-- STOCK LISTENER
	-----------------------------------------------------------------
	for _, remoteName in ipairs({ "Restock", "ShopStock" }) do
		local remote = Remotes:FindFirstChild(remoteName)
		if remote and remote:IsA("RemoteEvent") then
			local conn = remote.OnClientEvent:Connect(readStock)
			OnCleanup(function()
				conn:Disconnect()
			end)
		end
	end
	Util.Fire("ShopStock")

	-----------------------------------------------------------------
	-- AUTO BUY
	-----------------------------------------------------------------
	local function ownedCount(name)
		local count = 0
		for _, container in ipairs({ localPlayer:FindFirstChildOfClass("Backpack"), localPlayer.Character }) do
			if container then
				for _, child in ipairs(container:GetChildren()) do
					if child:IsA("Tool") and string.gsub(child.Name, "%s*%[.*$", "") == name then
						local amount = child:FindFirstChild("Amount", true)
						count += amount and tonumber(amount.Value) or 1
					end
				end
			end
		end
		return count
	end

	local function autoBuy(category)
		if not On(ShopFlags[category]) then
			return
		end
		local opened = false

		for _, item in ipairs(shopNames(category)) do
			if ShopSelected[category][item] then
				local price = shopPrice(category, item)
				local stockTbl = shopStock[category]
				local stock = stockTbl and stockTbl[item]
				local canTry = stock == nil
				if canTry then
					canTry = (shopCooldown[category .. item] or 0) <= os.clock()
				end
				canTry = canTry or (stock ~= nil and stock > 0)

				local tries = 0
				while canTry and tries < 20 and Util.Cash() - price >= keepCash do
					if not opened then
						Util.Fire("SetOpenShop", category)
						task.wait(0.15)
						opened = true
					end

					local before = ownedCount(item)
					Util.Fire("BuyWithCash", category, item)
					tries += 1

					local t = os.clock() + 0.8
					while os.clock() < t and ownedCount(item) <= before do
						RunService.Heartbeat:Wait()
					end

					if ownedCount(item) > before then
						if stockTbl and stockTbl[item] then
							stockTbl[item] = math.max(0, stockTbl[item] - 1)
							canTry = stockTbl[item] > 0
						end
					else
						if stockTbl then
							stockTbl[item] = 0
						end
						shopCooldown[category .. item] = os.clock() + 30
						canTry = false
					end
				end
			end
		end
	end

	task.spawn(function()
		while IsRunning() do
			pcall(autoBuy, "Food")
			pcall(autoBuy, "Gears")
			task.wait(3)
		end
	end)

	-----------------------------------------------------------------
	-- UI
	-----------------------------------------------------------------
	ShopTab:CreateSection("Auto Shop", { Box = true })

	ShopTab:CreateToggle({
		Title = "Auto Buy Food",
		Default = false,
		Flag = "AutoBuyFood",
		Callback = function() end,
	})

	local foodList = shopNames("Food")
	ShopTab:CreateDropdown({
		Title = "Food To Buy",
		Options = #foodList > 0 and foodList or { "None" },
		Multi = true,
		Default = {},
		Flag = "FoodToBuy",
		Callback = function(value)
			ShopSelected.Food = ToSet(value)
		end,
	})

	ShopTab:CreateToggle({
		Title = "Auto Buy Radars",
		Default = false,
		Flag = "AutoBuyRadars",
		Callback = function() end,
	})

	local gearList = shopNames("Gears")
	ShopTab:CreateDropdown({
		Title = "Radars To Buy",
		Options = #gearList > 0 and gearList or { "None" },
		Multi = true,
		Default = {},
		Flag = "RadarsToBuy",
		Callback = function(value)
			ShopSelected.Gears = ToSet(value)
		end,
	})

	ShopTab:CreateInput({
		Title = "Keep Cash",
		Placeholder = "0",
		Callback = function(text)
			keepCash = math.max(0, tonumber(text) or 0)
		end,
	})
end

return Module
