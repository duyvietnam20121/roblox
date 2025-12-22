-- MainModule.lua (final)
local module = {}

-- services
local dss = game:GetService("DataStoreService")
local http = game:GetService("HttpService")
local mps = game:GetService("MarketplaceService")

-- stores
local mainStore = dss:GetDataStore("MainDataStore")

-- asset type IDs
module.assetTypeIds = {
	["T-Shirt"] = 2,
	["Shirt"]   = 11,
	["Pants"]   = 12,
	["Pass"]    = 34,
}

-- debug toggle
local DEBUG = true
local function log(...)
	if DEBUG then
		print("[inventory-debug]", ...)
	end
end

-- safe HTTP GET + JSON decode
local function safeGetJson(url)
	local ok, rawOrErr = pcall(function() return http:GetAsync(url) end)
	if not ok then
		return false, ("HTTP error: %s"):format(tostring(rawOrErr))
	end

	-- try decode; sometimes endpoint returns "true"/"false"
	local ok2, dataOrErr = pcall(function() return http:JSONDecode(rawOrErr) end)
	if not ok2 then
		if rawOrErr == "true" or rawOrErr == "false" then
			return true, (rawOrErr == "true")
		end
		return false, ("JSON decode error: %s"):format(tostring(dataOrErr))
	end

	return true, dataOrErr
end

-- normalize different raw item shapes into expected shape
local function normalizeItem(rawItem, assetTypeId)
	local item = { Item = {}, Creator = {}, Product = {} }

	-- asset id
	local assetId = rawItem["assetId"] or rawItem["id"] or rawItem["AssetId"] or rawItem["gamePassId"] or rawItem["asset_id"]
	item.Item.AssetId = assetId or 0

	-- asset type
	item.Item.AssetType = rawItem["assetType"] or rawItem["AssetType"] or assetTypeId or 0

	-- creator id
	local creatorId = nil
	if rawItem["creator"] then
		if type(rawItem["creator"]) == "table" then
			creatorId = rawItem["creator"]["id"] or rawItem["creator"]["creatorId"] or rawItem["creator"]["userId"] or rawItem["creator"]["creator_id"]
		else
			creatorId = rawItem["creator"]
		end
	end
	creatorId = creatorId or rawItem["creatorId"] or rawItem["CreatorId"] or (rawItem["Creator"] and rawItem["Creator"]["Id"]) or (rawItem["creator"] and rawItem["creator"]["creatorId"])
	item.Creator.Id = creatorId or 0

	-- price
	local price = nil
	if rawItem["product"] then
		price = rawItem["product"]["priceInRobux"] or rawItem["product"]["price"] or rawItem["product"]["PriceInRobux"]
	end
	price = price or rawItem["price"] or rawItem["PriceInRobux"] or rawItem["cost"]
	item.Product.PriceInRobux = tonumber(price) or 0

	-- isForSale
	local isForSale = nil
	if rawItem["product"] and rawItem["product"]["isForSale"] ~= nil then
		isForSale = rawItem["product"]["isForSale"]
	elseif rawItem["isForSale"] ~= nil then
		isForSale = rawItem["isForSale"]
	end
	if isForSale == nil then isForSale = true end
	item.Product.IsForSale = isForSale

	item._raw = rawItem
	return item
end

-- check can-view-inventory (returns boolean or nil+err)
local function checkCanView(plrId)
	local url = ("https://inventory.roproxy.com/v1/users/%s/can-view-inventory"):format(tostring(plrId))
	log("Checking can-view-inventory:", url)
	local ok, dataOrErr = safeGetJson(url)
	if not ok then
		log("can-view-inventory HTTP/JSON error:", dataOrErr)
		return nil, dataOrErr
	end

	if type(dataOrErr) == "boolean" then return dataOrErr end
	if type(dataOrErr) == "table" then
		return (dataOrErr["canView"] == true) or (dataOrErr["canViewInventory"] == true) or (dataOrErr["allowed"] == true) or (dataOrErr["can_view"] == true)
	end
	return false
end

-- try multiple catalog endpoints to fetch asset details (creator, price, isForSale)
local function fetchAssetDetails(assetId)
	-- returns table: { creatorId = number or nil, price = number or 0, isForSale = bool or nil, raw = rawResponse }
	local candidates = {
		("https://catalog.roproxy.com/v1/items/%s"):format(tostring(assetId)),
		("https://apis.roproxy.com/catalog/v1/items/%s"):format(tostring(assetId)),
		("https://catalog.roproxy.com/v1/items/%s?includeProduct=true"):format(tostring(assetId)),
		-- fallback to marketplace product (may be unsupported via proxy); keep as last
		("https://api.roproxy.com/marketplace/productinfo?assetId=%s"):format(tostring(assetId)),
	}

	for _, url in ipairs(candidates) do
		log("Trying asset details URL:", url)
		local ok, dataOrErr = safeGetJson(url)
		if not ok then
			log("  -> asset details HTTP/JSON error:", dataOrErr)
		else
			-- debug
			if DEBUG then
				local succ, enc = pcall(function() return http:JSONEncode(dataOrErr) end)
				if succ then log("DEBUG assetDetails raw (truncated):", string.sub(enc,1,800)) end
			end

			-- try common shapes
			-- shape A: { data = { item = {...}, product = {...} } }
			if type(dataOrErr) == "table" then
				-- try data.item or data
				local candidate = nil
				if dataOrErr["data"] then
					if type(dataOrErr["data"]) == "table" and (dataOrErr["data"]["item"] or dataOrErr["data"]["product"]) then
						candidate = dataOrErr["data"]
					elseif #dataOrErr["data"] > 0 then
						candidate = dataOrErr["data"]
					end
				end

				-- some proxies return direct object with fields
				local raw = nil
				if dataOrErr["data"] and type(dataOrErr["data"]) == "table" and (dataOrErr["data"]["item"] or dataOrErr["data"]["product"]) then
					raw = dataOrErr["data"]["item"] or dataOrErr["data"]["product"] or dataOrErr["data"]
				else
					raw = dataOrErr
				end

				-- find creator
				local creatorId = raw["creator"] and (raw["creator"]["id"] or raw["creator"]["creatorId"] or raw["creator"]["userId"]) or raw["creatorId"] or raw["CreatorId"] or raw["creatorid"] or raw["creator_id"]
				if not creatorId and raw["owner"] and raw["owner"]["userId"] then
					creatorId = raw["owner"]["userId"]
				end

				-- find product info/price
				local price = nil
				if raw["product"] then
					price = raw["product"]["priceInRobux"] or raw["product"]["price"] or raw["product"]["PriceInRobux"]
				end
				price = price or raw["price"] or raw["PriceInRobux"] or raw["cost"]

				-- isForSale
				local isForSale = nil
				if raw["product"] and raw["product"]["isForSale"] ~= nil then
					isForSale = raw["product"]["isForSale"]
				elseif raw["isForSale"] ~= nil then
					isForSale = raw["isForSale"]
				end

				-- success if we at least found creator or price
				if creatorId or price then
					return {
						creatorId = creatorId and tonumber(creatorId) or nil,
						price = tonumber(price) or 0,
						isForSale = (isForSale == nil) and nil or isForSale,
						raw = raw,
					}
				end
			end
		end
	end

	-- nothing found
	return { creatorId = nil, price = 0, isForSale = nil, raw = nil }
end

-- fetch inventory via v2 (returns normalized items with _raw for details)
local function fetchInventoryV2(plrId, assetId)
	local accumulated = {}
	local cursor = nil
	local page = 0

	repeat
		local url = ("https://inventory.roproxy.com/v2/users/%s/inventory/%s?limit=100"):format(tostring(plrId), tostring(assetId))
		if cursor and cursor ~= "" then url = url .. "&cursor=" .. tostring(cursor) end

		log("Fetching v2 inventory:", url, "(page", page, ")")
		local ok, dataOrErr = safeGetJson(url)
		if not ok then
			log("v2 inventory error:", dataOrErr)
			break
		end

		-- debug
		if DEBUG then
			local okEnc, enc = pcall(function() return http:JSONEncode(dataOrErr) end)
			if okEnc then log("DEBUG v2 raw (truncated):", string.sub(enc,1,1000)) end
		end

		-- inventory shape: { data = [ {...} ] } (your logs show this)
		local items = nil
		if type(dataOrErr) == "table" then
			if dataOrErr["data"] and type(dataOrErr["data"]) == "table" then
				items = dataOrErr["data"]
			elseif dataOrErr["Data"] and dataOrErr["Data"]["Items"] then
				items = dataOrErr["Data"]["Items"]
			elseif dataOrErr["items"] then
				items = dataOrErr["items"]
			elseif #dataOrErr > 0 then
				items = dataOrErr
			end
		end

		if items and type(items) == "table" and #items > 0 then
			for _, rawItem in ipairs(items) do
				-- rawItem contains assetId field (see your logs)
				local normalized = {
					Item = { AssetId = rawItem["assetId"] or rawItem["AssetId"] or rawItem["id"] or 0, AssetType = assetId },
					Creator = { Id = nil }, -- will fill after fetchAssetDetails
					Product = { PriceInRobux = 0, IsForSale = nil },
					_raw = rawItem,
				}
				table.insert(accumulated, normalized)
			end
			log("Fetched", #items, "inventory items from page", page)
		else
			log("No items array found on this v2 response (page", page, ")")
		end

		-- cursor detection
		local nextCursor = nil
		if type(dataOrErr) == "table" then
			if dataOrErr["nextCursor"] then
				nextCursor = dataOrErr["nextCursor"]
			elseif dataOrErr["data"] and dataOrErr["data"]["nextPageCursor"] then
				nextCursor = dataOrErr["data"]["nextPageCursor"]
			elseif dataOrErr["Data"] and dataOrErr["Data"]["nextPageCursor"] then
				nextCursor = dataOrErr["Data"]["nextPageCursor"]
			end
		end

		cursor = nextCursor
		page = page + 1
	until not cursor or cursor == ""

	return accumulated
end

-- fetch game-passes via v1 (returns normalized items)
local function fetchGamePassesV1(plrId)
	local accumulated = {}
	local url = ("https://apis.roproxy.com/game-passes/v1/users/%s/game-passes?count=100"):format(tostring(plrId))
	log("Fetching game-passes v1:", url)

	local ok, dataOrErr = safeGetJson(url)
	if not ok then
		log("game-passes v1 error:", dataOrErr)
		return accumulated
	end

	-- debug
	if DEBUG then
		local okEnc, enc = pcall(function() return http:JSONEncode(dataOrErr) end)
		if okEnc then log("DEBUG game-passes raw (truncated):", string.sub(enc,1,1000)) end
	end

	local list = nil
	if type(dataOrErr) == "table" then
		list = dataOrErr["gamePasses"] or dataOrErr["GamePasses"] or dataOrErr["data"] or dataOrErr
		if not list and #dataOrErr > 0 then list = dataOrErr end
	end

	if list and type(list) == "table" then
		for _, rawItem in ipairs(list) do
			-- map gamePass shape into module shape
			local normalized = {
				Item = { AssetId = rawItem["gamePassId"] or rawItem["id"] or rawItem["gamePass"] or 0, AssetType = module.assetTypeIds["Pass"] },
				Creator = { Id = (rawItem["creator"] and (rawItem["creator"]["creatorId"] or rawItem["creator"]["id"])) or rawItem["creatorId"] or rawItem["CreatorId"] },
				Product = { PriceInRobux = tonumber(rawItem["price"]) or 0, IsForSale = (rawItem["isForSale"] == nil) and true or rawItem["isForSale"] },
				_raw = rawItem,
			}
			table.insert(accumulated, normalized)
		end
	end

	return accumulated
end

-- primary: getItems (returns items created by player AND IsForSale true)
module.getItems = function(assetId, plrId)
	-- 1) check can-view-inventory for friendly warning (not required)
	local canView, canViewErr = checkCanView(plrId)
	if canView == false then
		warn("Inventory not viewable for user", plrId, "- ensure 'Who can view my inventory' = Everyone")
	end
	if canView == nil and canViewErr then
		log("can-view check returned unknown:", canViewErr)
	end

	local allItems = {}
	if assetId == module.assetTypeIds["Pass"] then
		allItems = fetchGamePassesV1(plrId)
	else
		-- inventory v2 -> then for each asset call fetchAssetDetails to get creator + price
		local inv = fetchInventoryV2(plrId, assetId)
		for _, item in ipairs(inv) do
			local aid = item.Item.AssetId
			if tonumber(aid) and tonumber(aid) > 0 then
				local details = fetchAssetDetails(aid)
				-- fill creator and product if found
				if details then
					item.Creator.Id = details.creatorId or item.Creator.Id or nil
					item.Product.PriceInRobux = details.price or item.Product.PriceInRobux or 0
					-- if details.isForSale explicitly returned use it, otherwise nil (we'll treat nil as true default)
					if details.isForSale ~= nil then
						item.Product.IsForSale = details.isForSale
					end
				end
			end
			table.insert(allItems, item)
		end
	end

	-- filter by created-by-player and IsForSale true
	local createdByUser = {}
	for _, item in ipairs(allItems) do
		pcall(function()
			local creatorId = tonumber((item.Creator and item.Creator.Id) or 0) or 0
			local isForSale = item.Product and item.Product.IsForSale
			-- treat nil isForSale as true for conservative behavior (gamepasses usually true, assets ambiguous)
			if isForSale == nil then isForSale = true end

			if creatorId ~= 0 and tostring(creatorId) == tostring(plrId) and isForSale == true then
				table.insert(createdByUser, item)
			end
		end)
	end

	-- helpful debug when empty
	if #createdByUser == 0 then
		if #allItems == 0 then
			warn("No items were returned from inventory/game-passes for user", plrId)
		else
			warn("Items were returned but none matched filter Creator==userId AND IsForSale==true for user", plrId)
			for i = 1, math.min(3, #allItems) do
				local sample = allItems[i]
				local okEnc, enc = pcall(function() return http:JSONEncode(sample._raw) end)
				if okEnc then
					warn(("Sample raw[%d] (truncated): %s"):format(i, string.sub(enc,1,800)))
				else
					warn("Sample raw encode failed for sample", i)
				end
			end
		end
	end

	return createdByUser
end

-- loadItems: keep UI logic compatible
module.loadItems = function(stand, plr)
	for _, frame in pairs(stand.Products.Items.ScrollingFrame:GetChildren()) do
		if frame:IsA("Frame") then frame:Destroy() end
	end

	local tshirts = module.getItems(module.assetTypeIds["T-Shirt"], plr.UserId)
	local passes = module.getItems(module.assetTypeIds["Pass"], plr.UserId)
	local shirts = module.getItems(module.assetTypeIds["Shirt"], plr.UserId)
	local pants = module.getItems(module.assetTypeIds["Pants"], plr.UserId)

	print(#tshirts,"T-Shirts found.")
	print(#shirts,"Shirts found.")
	print(#pants,"Pants found.")
	print(#passes,"Passes found.")

	local allItems = {}
	local tble = {tshirts,passes,shirts,pants}
	for _, itemType in pairs(tble) do
		for _, item in pairs(itemType) do
			table.insert(allItems,item)
		end
	end

	print("Total items found:",#allItems)
	print("Sorting items by price ascending...")
	table.sort(allItems, function(a, b)
		local pa = (a and a["Product"] and a["Product"]["PriceInRobux"]) or 0
		local pb = (b and b["Product"] and b["Product"]["PriceInRobux"]) or 0
		return pa < pb
	end)

	for _, item in pairs(allItems) do
		local frame = script.Template:Clone()
		frame.ItemID.Value = item["Item"]["AssetId"]
		frame.Cost.Value = item["Product"]["PriceInRobux"]
		frame.ItemTypeId.Value = item["Item"]["AssetType"]
		frame.RobuxCost.Text = "$"..tostring(item["Product"]["PriceInRobux"])
		frame.Parent = stand.Products.Items.ScrollingFrame
	end
end

module.clearStand = function(stand)
	print("Clearing stand...")
	stand.MessagePart.SurfaceGui.UserMessage.Text = "your text here"
	stand.Base.ClaimPrompt.Enabled = true
	stand.Base.ClaimedInfoDisplay.Enabled = false
	stand.Base.Unclaimed.Enabled = true
	stand.Claimed.Value = false
	stand.ClaimedUserName.Value = ""
	for _, frame in pairs(stand.Products.Items.ScrollingFrame:GetChildren()) do
		if frame:IsA("Frame") then frame:Destroy() end
	end
end

module.updateStandsEarned = function()
	for _, stand in pairs(game.Workspace.Stands:GetChildren()) do
		if stand.Claimed.Value == true then
			local plr = game.Players:FindFirstChild(stand.ClaimedUserName.Value)
			if plr then
				stand.Base.ClaimedInfoDisplay.UserRaised.Text = "R$"..tostring(plr.leaderstats.Recieved.Value).." Raised"
			else
				print("no player but claimed")
			end
		end
	end
end

module.findItem = function(itemID)
	for _, stand in pairs(game.Workspace.Stands:GetChildren()) do
		for _, frame in pairs(stand.Products.Items.ScrollingFrame:GetChildren()) do
			if frame:IsA("Frame") and frame.ItemID.Value == itemID then
				return frame
			end
		end
	end
end

return module
