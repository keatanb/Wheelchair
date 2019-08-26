local _, ns = ...

-- Assign global functions to locals for optimisation.
local GetContainerNumSlots = GetContainerNumSlots
local GetItemInfo = GetItemInfo
local GetContainerItemInfo = GetContainerItemInfo
local GetQuestLogItemLink = GetQuestLogItemLink
local PickupContainerItem = PickupContainerItem
local PickupMerchantItem = PickupMerchantItem
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown
local IsAltKeyDown = IsAltKeyDown
local UnitClass = UnitClass
local Baggins = Baggins

local ARMOUR = ns.ARMOUR
local WEAPON = ns.WEAPON
local WANTED_ITEMS = ns.WANTED_ITEMS

local BUYBACK_COUNT = 12
local FreeBagSpace

local _, PLAYERS_CLASS = UnitClass('player')

-- The typical life-cycle of the addon goes as follows:
--   1. Initially delays for 400ms before attempting to mark wares for the first time.
--   2. We look for and get the item buttons for every item (differs per bag addon).
--   3. Check if this item's ItemID is in our ItemsToSell.
--   4. If 'tis, draw some lovely coins on the itemButton!
--   5. a. Remove the OnUpdate (prev. used for 400ms delay).
--      b. If using the default WoW bags, keep a 30ms timer for re-marking.
--   6. Listen for BagUpdates to refresh the markings (moving an item, etc.).
--        PS: Baggins needs to also listen to the bags being opened!

-- Turns an integer value into the format "Xg Ys Zc".
function priceToGold(price)
	local gold = price / 10000
	local silver = (price % 10000) / 100
	local copper = (price % 10000) % 100

	return math.floor(gold) .. "|cFFFFCC33g|r " .. math.floor(silver) .. "|cFFC9C9C9s|r " .. math.floor(copper) .. "|cFFCC8890c|r"
end

local wheelchair = CreateFrame("Frame", nil, UIParent)
local salesDelay = CreateFrame("Frame")
local usingDefaultBags = false
local markCounter = 1
local countLimit = 1

wheelchair:RegisterEvent("PLAYER_ENTERING_WORLD")
wheelchair:RegisterEvent("ADDON_LOADED")
wheelchair:RegisterEvent("MERCHANT_SHOW")
wheelchair:RegisterEvent("LOOT_OPENED")

-- Is there really no better way to check soulbound-ness...?
local soulboundToolip
local function isSoulbound(itemLink)
	if not soulboundToolip then
		local tip = CreateFrame("GameTooltip")
		local leftside = {}
		for i = 1, 4 do
			local left, right = tip:CreateFontString(), tip:CreateFontString()
			left:SetFontObject(GameFontNormal)
			right:SetFontObject(GameFontNormal)
			tip:AddFontStrings(left, right)
			leftside[i] = left
		end
		tip.leftside = leftside
		soulboundToolip = tip
	end

	soulboundToolip:SetOwner(UIParent, "ANCHOR_NONE")
	soulboundToolip:ClearLines()
	soulboundToolip:SetHyperlink(itemLink)
	local secondLine = soulboundToolip.leftside[2]:GetText()
	local thirdLine = soulboundToolip.leftside[3]:GetText()
	-- 4th line is now needed if the item shows an Upgrade Level.
	local fourthLine = soulboundToolip.leftside[4]:GetText()
	soulboundToolip:Hide()

	return ((secondLine == ITEM_SOULBOUND or secondLine == ITEM_BIND_ON_PICKUP) or (thirdLine == ITEM_SOULBOUND or thirdLine == ITEM_BIND_ON_PICKUP) or (fourthLine == ITEM_SOULBOUND or fourthLine == ITEM_BIND_ON_PICKUP))
end

-- Serves to get the item's itemID + suffixID.
function parseItemString(itemString)
	if not itemString then
		return
	end

	local _, itemID, _, _, _, _, _, suffixID = strsplit(":", itemString)
	itemID = tonumber(itemID)
	suffixID = tonumber(suffixID)

	if not itemID then
		return
	end

	local uniqueItemID = itemID
	if suffixID and suffixID ~= 0 then
		uniqueItemID = itemID .. suffixID
	end

	return itemID, uniqueItemID
end

local function getUniqueItemID(bagNumber, slotNumber)
	local itemString = GetContainerItemLink(bagNumber, slotNumber)
	return parseItemString(itemString)
end

local function isUnwantedItem(itemType, subType, equipSlot)
	local unwantedItem = false

	-- Of course we never want to sell cloaks!
	local isCloak = equipSlot == 'INVTYPE_CLOAK'
	if AutoSellUnwantedItems and (itemType == WEAPON or itemType == ARMOUR) and not isCloak then
		unwantedItem = true
		for _, value in pairs(WANTED_ITEMS[PLAYERS_CLASS][itemType]) do
			if subType == value then
				unwantedItem = false
				break
			end
		end
	end

	return unwantedItem
end

local function itemIsToBeSold(itemID, uniqueItemID)
	local _, link, quality, _, _, itemType, subType, _, equipSlot, _, price = GetItemInfo(itemID)

	-- No price?  No sale!
	if not price or price <= 0 then
		return
	end

	local unmarkedItem = UnmarkedItems[uniqueItemID]

	local unwantedGrey = quality == 0 and AutoSellGreyItems and not unmarkedItem
	local unwantedWhite = quality == 1 and AutoSellWhiteItems and not unmarkedItem
	local unwantedGreen = quality == 2 and AutoSellGreenItems and not unmarkedItem
	local unwantedBlue = quality == 3 and AutoSellBlueItems and not unmarkedItem
	local unwantedPurple = quality == 4 and AutoSellPurpleItems and not unmarkedItem

	local unwantedItem = isUnwantedItem(itemType, subType, equipSlot) and not unmarkedItem

	local autoSellable = (unwantedGrey or unwantedWhite or unwantedGreen or unwantedBlue or unwantedPurple or unwantedItem)

	if autoSellable then
		if SoulboundOnly and not unwantedGrey then
			autoSellable = isSoulbound(link)
		end
	end

	return ItemsToSell[uniqueItemID] or autoSellable
end


function getMarkedAndCashValue()
	local totalMarkedPrice = 0
	local numItems = 0
	local cash
	for bag = 0, NUM_BAG_SLOTS do
		for bagSlot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, bagSlot)
			if link then
				local itemID, uniqueItemID = parseItemString(link)

				local _, _, _, _, _, _, _, _,_, _, vendorPrice, _, _, _, _, _,_ = GetItemInfo(link)
				if uniqueItemID and itemIsToBeSold(itemID, uniqueItemID) then
					local _, itemCount = GetContainerItemInfo(bag, bagSlot)
					local totalVendorPrice = vendorPrice * itemCount
					if totalMarkedPrice == nil then
						totalMarkedPrice = totalVendorPrice
						numItems = 1
					else
						totalMarkedPrice = totalMarkedPrice + totalVendorPrice
						numItems = numItems + 1
					end
				end
			end
		end
	end
	cash = GetMoney()
	return totalMarkedPrice, numItems, cash, priceToGold(totalMarkedPrice+cash)
end


local function getMostGarbageMarkedItem()
	local lastPrice, bagNum, slotNum, weakestLink
	for bag = 0, NUM_BAG_SLOTS do
		for bagSlot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, bagSlot)
			if link then
				local itemID, uniqueItemID = parseItemString(link)

				local _, _, _, _, _, _, _, _,_, _, vendorPrice, _, _, _, _, _,_ = GetItemInfo(link)
				if uniqueItemID and itemIsToBeSold(itemID, uniqueItemID) then
					local _, itemCount = GetContainerItemInfo(bag, bagSlot)
					local totalVendorPrice = vendorPrice * itemCount
					if lastPrice == nil then
						lastPrice = totalVendorPrice
						bagNum = bag
						slotNum = bagSlot
						weakestLink = link
					elseif lastPrice > totalVendorPrice then
						lastPrice = totalVendorPrice
						bagNum = bag
						slotNum = bagSlot
						weakestLink = link
					end
				end
			end
		end
	end
	return weakestLink, lastPrice, bagNum, slotNum
end

local function dropGarbage()
	-- Time delay
	local tDelay = 0

	if GetTime() - tDelay >= 0.3 then
		tDelay = GetTime()
		if GetCVarBool("autoLootDefault") ~= IsModifiedClick("AUTOLOOTTOGGLE") then
			for i = GetNumLootItems(), 1, -1 do
				LootSlot(i)
			end

            if GetNumLootItems() > FreeBagSpace then
                for i = GetNumLootItems(), 1, -1 do
                    local _, _, lootQuantity, _, _, locked, isQuestItem, _, isActive = GetLootSlotInfo(i)
                    local link = GetLootSlotLink(i)
                    if link and not locked then
                        local weakestLink, lowestAmt, lowestBagNum, lowestSlotNum = getMostGarbageMarkedItem()

                        if weakestLink == nil then
                            print("*** Can't brick anything, deal with it")
                        else
                            if isQuestItem or isActive then
                                PickupContainerItem(lowestBagNum,lowestSlotNum)
                                DeleteCursorItem()
                                LootSlot(i)
                                print("--- "..weakestLink .. priceToGold(lowestAmt) .. " bricked")
                                print("+++ "..link .. " quest item slipped in")
                            else
                                local price = select(11, GetItemInfo(link)) * lootQuantity
                                if price > lowestAmt then
                                    PickupContainerItem(lowestBagNum,lowestSlotNum)
                                    DeleteCursorItem()
                                    LootSlot(i)
                                    print("--- " .. weakestLink .. priceToGold(lowestAmt) .. " bricked")
                                    print("+++ " .. link .. priceToGold(price) .. " scavenged")
                                else
                                    print("!!! nothing less valuable marked in the wheelchair keep rollin")
                                end
                            end
                        end
                    end
                end
            end
			tDelay = GetTime()
		end
	end
end


local function peddleGoods()
	local total = 0
	local sellCount = 0
	local sellDelay = 0

	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemID, uniqueItemID = getUniqueItemID(bagNumber, slotNumber)

			if uniqueItemID and itemIsToBeSold(itemID, uniqueItemID) then
				local itemButton = _G["ContainerFrame" .. bagNumber + 1 .. "Item" .. bagsSlotCount - slotNumber + 1]

				if itemButton.coins then
					itemButton.coins:Hide()
				end

				local _, amount = GetContainerItemInfo(bagNumber, slotNumber)

				local _, _, _, _, _, _, _, _, _, _, price = GetItemInfo(itemID)
				if price and price > 0 then
					price = price * amount

					if total == 0 and (not Silent or not SilenceSaleSummary) then
						print("Wheelchair sold:")
					end

					total = total + price

					if not Silent then
						local _, link = GetItemInfo(itemID)
						local output = "    " .. sellCount + 1 .. '. ' .. link

						if amount > 1 then
							output = output .. "x" .. amount
						end

						output = output .. " for " .. priceToGold(price)
						print(output)
					end
				end

				-- Actually sell the item!
				if (sellDelay > 0) then
					local waitAnimationGroup = salesDelay:CreateAnimationGroup("sellDelay" .. sellCount)
					local waitAnimation = waitAnimationGroup:CreateAnimation("Translation")
					waitAnimation:SetDuration(sellDelay)
					waitAnimation:SetSmoothing("OUT")
					waitAnimationGroup:Play()

					waitAnimationGroup:SetScript("OnFinished", function()
						PickupContainerItem(bagNumber, slotNumber)
						PickupMerchantItem()
					end)
				else
					PickupContainerItem(bagNumber, slotNumber)
					PickupMerchantItem()
				end

				sellCount = sellCount + 1
				sellDelay = math.floor(sellCount / 6)
				if (SellLimit and sellCount >= BUYBACK_COUNT) then
					break
				end
			end

			if (SellLimit and sellCount >= BUYBACK_COUNT) then
				break
			end
		end
	end

	if total > 0 and not SilenceSaleSummary then
		print("For a total of " .. priceToGold(total))
	end
end

local function showCoinTexture(itemButton)
	if not itemButton.coins then
		local texture = itemButton:CreateTexture(nil, "OVERLAY")
		texture:SetTexture("Interface\\AddOns\\Wheelchair\\coins")

		-- Default padding for making bottom-right look great.
		local paddingX, paddingY = -3, 1
		if string.find(IconPlacement, "TOP") then
			paddingY = -3
		end
		if string.find(IconPlacement, "LEFT") then
			paddingX = 1
		end

		texture:SetPoint(IconPlacement, paddingX, paddingY)

		itemButton.coins = texture
	end

	itemButton.coins:Show()

	if not usingDefaultBags then
		wheelchair:SetScript("OnUpdate", nil)
	end
	markCounter = 0

	if usingDefaultBags or IsAddOnLoaded("Baggins") or IsAddOnLoaded("AdiBags") then
		-- Baggins/AdiBag update slower than the others, so we have to account for that.
		-- Default WoW bags need to constantly be updating, due to opening of individual bags.
		countLimit = 30
	else
		countLimit = 5
	end
end

local function displayCoins(itemID, uniqueItemID, itemButton)
	if uniqueItemID then
		if itemIsToBeSold(itemID, uniqueItemID) then
			showCoinTexture(itemButton)
		elseif itemButton.coins then
			itemButton.coins:Hide()
		end
	elseif itemButton.coins then
		itemButton.coins:Hide()
	end
end

local function checkItem(bagNumber, slotNumber, itemButton)
	local itemID, uniqueItemID = getUniqueItemID(bagNumber, slotNumber)
	displayCoins(itemID, uniqueItemID, itemButton)
end

local function markBagginsBags()
	for _, bag in ipairs(Baggins.bagframes) do
		for _, section in ipairs(bag.sections) do
			for _, itemButton in ipairs(section.items) do
				local itemsBagNumber = itemButton:GetParent():GetID()
				local itemsSlotNumber = itemButton:GetID()

				checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
			end
		end
	end
end

-- Also works for Bagnon.
local function markCombuctorBags()
	for bagNumber = 0, 4 do
		for slotNumber = 1, 36 do
			local itemButton = _G["ContainerFrame" .. bagNumber + 1 .. "Item" .. slotNumber]

			local itemButtonParent = itemButton:GetParent()
			if itemButtonParent then
				local itemsBagNumber = itemButtonParent:GetID()
				local itemsSlotNumber = itemButton:GetID()
				checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
			end
		end
	end
end

local function markOneBagBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["OneBagFrameBag" .. bagNumber .. "Item" .. bagsSlotCount - slotNumber + 1]

			if itemButton then
				local itemsBagNumber = itemButton:GetParent():GetID()
				local itemsSlotNumber = itemButton:GetID()
				checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
			end
		end
	end
end

local function markBaudBagBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["BaudBagSubBag" .. bagNumber .. "Item" .. slotNumber]
			checkItem(bagNumber, slotNumber, itemButton)
		end
	end
end

local function markAdiBagBags()
	local totalSlotCount = 0
	for bagNumber = 0, 4 do
		totalSlotCount = totalSlotCount + GetContainerNumSlots(bagNumber)
	end

	-- For some reason, AdiBags can have way more buttons than the actual amount of bag slots... not sure how or why.
	totalSlotCount = totalSlotCount + 60

	if totalSlotCount < 100 then
		totalSlotCount = 100
	end

	for slotNumber = 1, totalSlotCount do
		local itemButton = _G["AdiBagsItemButton" .. slotNumber]
		if itemButton then
			local _, bag, slot = strsplit('-', tostring(itemButton))

			bag = tonumber(bag)
			slot = tonumber(slot)

			if bag and slot then
				checkItem(bag, slot, itemButton)
			end
		end
	end
end

local function markArkInventoryBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["ARKINV_Frame1ScrollContainerBag" .. bagNumber + 1 .. "Item" .. slotNumber]
			-- Required to check for itemButton because ArkInventory changed when it builds the item objects so only the first slot of each bag is available prior to the first time its opened, causing Wheelchair to get a nil obj for itemButton. /vincentSDSH
			if itemButton then checkItem(bagNumber, slotNumber, itemButton) end
		end
	end
end

local function markCargBagsNivayaBags()
	local totalSlotCount = 0
	for bagNumber = 0, 4 do
		totalSlotCount = totalSlotCount + GetContainerNumSlots(bagNumber)
	end

	-- Somehow, Nivaya can have higher slot-numbers than actual bag slots exist...
	totalSlotCount = totalSlotCount * 5

	for slotNumber = 1, totalSlotCount do
		local itemButton = _G["NivayaSlot" .. slotNumber]
		if itemButton then
			local itemsBag = itemButton:GetParent()

			if itemsBag then
				local itemsBagNumber = itemsBag:GetID()
				local itemsSlotNumber = itemButton:GetID()
				checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
			end
		end
		slotNumber = slotNumber + 1
	end
end

local function markMonoBags()
	local totalSlotCount = 0
	for bagNumber = 0, 4 do
		totalSlotCount = totalSlotCount + GetContainerNumSlots(bagNumber)
	end

	for slotNumber = 1, totalSlotCount do
		local itemButton = _G["m_BagsSlot" .. slotNumber]
		if itemButton then
			local itemsBagNumber = itemButton:GetParent():GetID()
			local itemsSlotNumber = itemButton:GetID()
			checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
		end
		slotNumber = slotNumber + 1
	end
end

local function markDerpyBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["StuffingBag" .. bagNumber .. "_" .. slotNumber]
			checkItem(bagNumber, slotNumber, itemButton)
		end
	end
end

local function markElvUIBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["ElvUI_ContainerFrameBag" .. bagNumber .. "Slot" .. slotNumber]
			checkItem(bagNumber, slotNumber, itemButton)
		end
	end
end

local function markInventorianBags()
	for bagNumber = 0, NUM_CONTAINER_FRAMES do
		for slotNumber = 1, 36 do
			local itemButton = _G["ContainerFrame" .. bagNumber + 1 .. "Item" .. slotNumber]

			if itemButton then
				local itemButtonParent = itemButton:GetParent()
				if itemButtonParent then
					local itemsBagNumber = itemButtonParent:GetID()
					local itemsSlotNumber = itemButton:GetID()
					checkItem(itemsBagNumber, itemsSlotNumber, itemButton)
				end
			end
		end
	end
end

-- Special thanks to both Xodiv & Theroxis of Curse for this one.
local function markLiteBagBags()
	for i = 1, LiteBagInventoryPanel.size do
		local button = LiteBagInventoryPanel.itemButtons[i]
		local itemsBagNumber = button:GetParent():GetID()
		local itemsSlotNumber = button:GetID()
		checkItem(itemsBagNumber, itemsSlotNumber, button)
	end
end

-- Special thanks to Tymesink from WowInterface for this one.
local function markfamBagsBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["famBagsButton_" .. bagNumber .. "_" .. slotNumber]
			checkItem(bagNumber, slotNumber, itemButton)
		end
	end
end

local function markLUIBags()
	for bagNumber = 0, 4 do
		local bagsSlotCount = GetContainerNumSlots(bagNumber)
		for slotNumber = 1, bagsSlotCount do
			local itemButton = _G["LUIBags_Item" .. bagNumber .. "_" .. slotNumber]
			checkItem(bagNumber, slotNumber, itemButton)
		end
	end
end

-- Also works for bBag.
local function markNormalBags()
	for containerNumber = 0, NUM_BAG_SLOTS do
		--local container = _G["ContainerFrame" .. containerNumber + 1]
			local bagsSlotCount = GetContainerNumSlots(containerNumber)
			for slotNumber = 1, bagsSlotCount do
				local itemButton = _G["ContainerFrame" .. containerNumber + 1 .. "Item" .. bagsSlotCount - slotNumber + 1]
				local bagNumber = itemButton:GetParent():GetID()
				local actualSlotNumber = itemButton:GetID()
				checkItem(bagNumber, actualSlotNumber, itemButton)
			end
	end
end

-- TODO: Split these into separate, well-coded things already.
local function markWares()
	if IsAddOnLoaded("Baggins") then
		markBagginsBags()
	elseif IsAddOnLoaded("Combuctor") or IsAddOnLoaded("Bagnon") then
		markCombuctorBags()
	elseif IsAddOnLoaded("OneBag3") then
		markOneBagBags()
	elseif IsAddOnLoaded("BaudBag") then
		markBaudBagBags()
	elseif IsAddOnLoaded("AdiBags") then
		markAdiBagBags()
	elseif IsAddOnLoaded("ArkInventory") then
		markArkInventoryBags()
	elseif IsAddOnLoaded("famBags") then
		markfamBagsBags()
	elseif IsAddOnLoaded("cargBags_Nivaya") then
		markCargBagsNivayaBags()
	elseif IsAddOnLoaded("m_Bags") then
		markMonoBags()
	elseif IsAddOnLoaded("DerpyStuffing") then
		markDerpyBags()
	elseif IsAddOnLoaded("Inventorian") then
		markInventorianBags()
	elseif IsAddOnLoaded("LiteBag") then
		markLiteBagBags()
	elseif IsAddOnLoaded("ElvUI") and _G["ElvUI_ContainerFrame"] then
		markElvUIBags()
	elseif IsAddOnLoaded("LUI") and _G["LUIBags_Item0_1"] then
		markLUIBags()
	else
		usingDefaultBags = true
		markNormalBags()
	end
end

ns.markWares = markWares

local function onUpdate()
	markCounter = markCounter + 1
	if markCounter <= countLimit then
		return
	else
		markCounter = 0
		markWares()
	end
end

local function handleBagginsOpened()
	if markCounter == 0 then
		wheelchair:SetScript("OnUpdate", onUpdate)
	end
end

local function setupDefaults()
	-- Setup default settings.
	if not ItemsToSell then
		ItemsToSell = {}
	end

	if not UnmarkedItems then
		UnmarkedItems = {}
	end

	if not ModifierKey then
		ModifierKey = "CTRL"
	end

	if not IconPlacement then
		IconPlacement = "BOTTOMLEFT"
	end

	if AutoSellGreyItems == nil then
		AutoSellGreyItems = true
	end

	if AutoDropItemsToSell == nil then
		AutoDropItemsToSell = true
	end
end

local function setFreeBagSpace()
	FreeBagSpace = 0
	for i=0,NUM_BAG_SLOTS do
		FreeBagSpace = FreeBagSpace + GetContainerNumFreeSlots(i)
	end
	if FreeBagSpace <= 3 then
		UIErrorsFrame:AddMessage("Wheelchair has "..FreeBagSpace.." slots left.",1,0,0,5)
	end
end

local function handleEvent(_, event, addonName)
	if event == "ADDON_LOADED" and addonName == "Wheelchair" then
		wheelchair:UnregisterEvent("ADDON_LOADED")
		print("Wheelchair |cff9966ff[Loot]|r Enabled")

		setupDefaults()
		setFreeBagSpace()
		markWares()
		countLimit = 400
		wheelchair:SetScript("OnUpdate", onUpdate)

		if IsAddOnLoaded("Baggins") then
			Baggins:RegisterSignal("Baggins_BagOpened", handleBagginsOpened, Baggins)
		end

	elseif event == "PLAYER_ENTERING_WORLD" then
		wheelchair:RegisterEvent("BAG_UPDATE_DELAYED")
	elseif event == "BAG_UPDATE_DELAYED" then
		setFreeBagSpace()
		markWares()
	elseif event == "MERCHANT_SHOW" then
		peddleGoods()
	elseif event == "LOOT_OPENED" then
		if AutoDropItemsToSell then
			dropGarbage()
		end
	end
end

wheelchair:SetScript("OnEvent", handleEvent)

local function toggleItemPeddling(itemID, uniqueItemID)
	if itemIsToBeSold(itemID,uniqueItemID) then
		if UnmarkedItems[uniqueItemID] then
			UnmarkedItems[uniqueItemID] = nil
		else
			UnmarkedItems[uniqueItemID] = 1
			ItemsToSell[uniqueItemID] = nil
		end
	elseif ItemsToSell[uniqueItemID] then
		ItemsToSell[uniqueItemID] = nil
	else
		ItemsToSell[uniqueItemID] = 1
	end
end

local function handleItemClick(self, button)
	local ctrlKeyDown = IsControlKeyDown()
	local shiftKeyDown = IsShiftKeyDown()
	local altKeyDown = IsAltKeyDown()

	local modifierDown = (ModifierKey == 'CTRL' and ctrlKeyDown or (ModifierKey == 'SHIFT' and shiftKeyDown or (ModifierKey == 'ALT' and altKeyDown or (ModifierKey == 'CTRL-SHIFT' and ctrlKeyDown and shiftKeyDown or (ModifierKey == 'CTRL-ALT' and ctrlKeyDown and altKeyDown or (ModifierKey == 'ALT-SHIFT' and altKeyDown and shiftKeyDown))))))
	local usingWheelchair = (modifierDown and button == 'RightButton')
	if not usingWheelchair then
		return
	end

	local bagNumber = self:GetParent():GetID()
	local slotNumber = self:GetID()

	local itemID, uniqueItemID = getUniqueItemID(bagNumber, slotNumber)

	-- Empty bag slots cannot be sold, silly!
	if not itemID then
		return
	end

	toggleItemPeddling(itemID, uniqueItemID)
	markWares()
end

hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", handleItemClick)


-- Quest Reward handling.
local listeningToRewards = {}
local function checkQuestReward(itemButton, toggle)
	local rewardIndex = itemButton:GetID()

	local testReward = function(itemString)
		if not itemString then
			return
		end

		local itemID, uniqueItemID = parseItemString(itemString)

		if toggle then
			toggleItemPeddling(itemID, uniqueItemID)
		end

		displayCoins(itemID, uniqueItemID, itemButton)
	end

	testReward(GetQuestLogItemLink("reward", rewardIndex))
	testReward(GetQuestLogItemLink("choice", rewardIndex))
end

local function handleQuestFrameItemClick(self, _)
	local altKeyDown = IsAltKeyDown()
	if not altKeyDown then
		return
	end
	checkQuestReward(self, true)
	markWares()
end

local function setupQuestFrame(frameBaseName)
	for i = 1, 6 do
		local frameName = frameBaseName .. i
		local itemButton = _G[frameName]
		if itemButton then
			checkQuestReward(itemButton, false)

			if not listeningToRewards[frameName] then
				listeningToRewards[frameName] = true
				itemButton:HookScript("OnClick", handleQuestFrameItemClick)
			end
		end
	end
end

local function onQuestRewardsShow()
	setupQuestFrame("QuestInfoRewardsFrameQuestInfoItem")
end

local function onMapQuestRewardsShow()
	setupQuestFrame("MapQuestInfoRewardsFrameQuestInfoItem")
end

MapQuestInfoRewardsFrame:HookScript("OnShow", onMapQuestRewardsShow)
QuestInfoRewardsFrame:HookScript("OnShow", onQuestRewardsShow)
