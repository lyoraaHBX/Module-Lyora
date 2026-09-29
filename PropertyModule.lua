local PropertyModule = {}

function PropertyModule.Init(Context, PROPERTIES)
    local ReplicatedStorage = Context.ReplicatedStorage
    local MainTab = Context.MainTab
    local Scheduler = Context.Scheduler
    local QueueNotify = Context.QueueNotify
    local ForceSetToggleOff = Context.ForceSetToggleOff
    local SafeFindPath = Context.SafeFindPath
    local GetRawTextFromNode = Context.GetRawTextFromNode
    local ParseAbbreviatedNumber = Context.ParseAbbreviatedNumber
    local FormatMoneyShort = Context.FormatMoneyShort
    local State = Context.State

    local BuyPropertyRemote = ReplicatedStorage:WaitForChild("MW"):WaitForChild("Remotes"):WaitForChild("BuyProperty")
    local DeletePropertyRemote = ReplicatedStorage:WaitForChild("MW"):WaitForChild("Remotes"):WaitForChild("DeleteProperty")
    local PROPERTY_HASH = "ca01587a32b24eb1a0527e8e595e8483"

    -- Path UI Terbaru
    local CashPath = {"PlayerGui", "MafiaWarsUI", "Root", "TopBar", "CashCluster", "CashValue"}
    local SummaryLotsPath = {"PlayerGui", "MafiaWarsUI", "Root", "Content", "PropsPanel", "Scroller", "Summary", "Lots", "Value"}
    local StreetPath = {"PlayerGui", "MafiaWarsUI", "Root", "Content", "PropsPanel", "Scroller", "YourBlock", "Street"}

    local PropertyNamesList = {}
    local PropertyMap = {}
    local PROPERTIES_BY_ID = {}

    for _, prop in ipairs(PROPERTIES) do
        local displayName = "[Lv." .. prop.level .. "] " .. prop.name .. " ($" .. FormatMoneyShort(prop.baseCost) .. ")"
        table.insert(PropertyNamesList, displayName)
        PropertyMap[displayName] = prop.id
        PROPERTIES_BY_ID[prop.id] = prop
    end

    local function GetCurrentCash()
        local node = SafeFindPath(CashPath)
        if not node then return 0 end
        local raw = GetRawTextFromNode(node)
        return ParseAbbreviatedNumber(raw)
    end

    -- Membaca slot owned / cap (misal: "10/14") dari Summary.Lots.Value
    local function GetPropsCapInfo()
        local node = SafeFindPath(SummaryLotsPath)
        if not node then return 0, 0 end

        local raw = GetRawTextFromNode(node)
        local owned, max = string.match(tostring(raw), "(%d+)%s*/%s*(%d+)")
        return tonumber(owned) or 0, tonumber(max) or 0
    end

    -- Mengambil nomor Lot dari nama (contoh "Lot_8" -> 8)
    local function ExtractLotNumber(lotName)
        return tonumber(string.match(lotName, "^Lot_(%d+)$"))
    end

    -- Fungsi pembantu untuk mendeteksi Property ID dari sebuah Node Lot
    local function DetectPropertyIdFromLot(lotNode)
        -- 1. Cek dari Attribute jika ada
        for _, attr in ipairs({"PropertyId", "PropId", "id", "ID"}) do
            local val = lotNode:GetAttribute(attr)
            if val and PROPERTIES_BY_ID[val] then
                return val
            end
        end

        -- 2. Cek apakah ada child bernama propId
        for propId, _ in pairs(PROPERTIES_BY_ID) do
            if lotNode:FindFirstChild(propId) then
                return propId
            end
        end

        -- 3. Cek nama child / tile
        for _, child in ipairs(lotNode:GetChildren()) do
            if PROPERTIES_BY_ID[child.Name] then
                return child.Name
            end
            local matchedId = string.match(child.Name, "^Tile_(.+)$") or string.match(child.Name, "^Prop_(.+)$")
            if matchedId and PROPERTIES_BY_ID[matchedId] then
                return matchedId
            end
        end

        -- 4. Cek TextLabel di dalam Lot yang mencocokkan nama Property
        for _, child in ipairs(lotNode:GetDescendants()) do
            if child:IsA("TextLabel") or child:IsA("TextBox") then
                local text = child.Text
                for propId, propObj in pairs(PROPERTIES_BY_ID) do
                    if string.find(string.lower(text), string.lower(propObj.name), 1, true) then
                        return propId
                    end
                end
            end
        end

        return nil
    end

    -- Mengambil daftar Lot yang dimiliki & Lot yang kosong
    local function GetStreetLotsState()
        local streetNode = SafeFindPath(StreetPath)
        if not streetNode then return {}, {} end

        local ownedList = {}
        local emptyLotNumbers = {}

        for _, lotNode in ipairs(streetNode:GetChildren()) do
            local lotNum = ExtractLotNumber(lotNode.Name)
            if lotNum then
                -- Cek apakah Lot ini kosong (ForSale.Plus ada / ForSale Visible)
                local forSaleNode = lotNode:FindFirstChild("ForSale")
                local isForSale = forSaleNode and (forSaleNode:FindFirstChild("Plus") or forSaleNode.Visible == true)

                if isForSale then
                    table.insert(emptyLotNumbers, lotNum)
                else
                    -- Lot Terisi
                    local chipLabel = lotNode:FindFirstChild("Chip") and lotNode.Chip:FindFirstChild("Label")
                    local earnValue = 0

                    if chipLabel then
                        local rawText = GetRawTextFromNode(chipLabel)
                        -- Pembersihan string: "$12.09M/hr" -> "12.09M"
                        local cleanText = string.gsub(tostring(rawText), "[%$%s/hrHRhH]", "")
                        earnValue = ParseAbbreviatedNumber(cleanText)
                    end

                    local propId = DetectPropertyIdFromLot(lotNode)

                    table.insert(ownedList, {
                        id = propId,
                        lotNumber = lotNum,
                        earn = earnValue,
                        node = lotNode
                    })
                end
            end
        end

        table.sort(emptyLotNumbers)
        return ownedList, emptyLotNumbers
    end

    local function GetBestAffordableProperty(cash, level)
        local best = nil
        for _, prop in ipairs(PROPERTIES) do
            if level >= prop.level and prop.baseCost <= cash then
                if not best or prop.baseCost > best.baseCost then
                    best = prop
                end
            end
        end
        return best
    end

    local function GetEffectiveIncome(prop)
        if prop.incomePerHour then return prop.incomePerHour end
        if prop.goldPerDay then return math.huge end
        return 0
    end

    -- Remote Invoke Buy dengan Parameter Lot Number
    local function TryBuyProperty(propId, lotNumber)
        local success, result = pcall(function()
            return BuyPropertyRemote:InvokeServer(PROPERTY_HASH, propId, lotNumber)
        end)
        if success and type(result) == "table" then
            return result.ok == true, result
        end
        return false, nil
    end

    -- Remote Invoke Delete dengan Parameter Lot Number
    local function TryDeleteProperty(propId, lotNumber)
        local success, result = pcall(function()
            return DeletePropertyRemote:InvokeServer(PROPERTY_HASH, propId, lotNumber)
        end)
        if success and type(result) == "table" then
            return result.ok == true, result
        end
        return false, nil
    end

    local AutoPropertyEnabled = false
    local AutoHighestPropertyMode = true
    local SelectedPropertyId = PROPERTIES[1].id
    local AutoPropertyToggleRef = nil

    MainTab:CreateSection("Auto Property")

    AutoPropertyToggleRef = MainTab:CreateToggle({
        Title = "Enable Auto Property",
        Default = false,
        Flag = "AutoPropertyToggle",
        Callback = function(Value)
            AutoPropertyEnabled = Value
            if Value then
                QueueNotify({
                    Title = "Auto Property Started",
                    Content = AutoHighestPropertyMode and "Mode: Auto Select Best" or "Mode: Manual Select",
                    Duration = 3
                })
            end
        end
    })

    MainTab:CreateToggle({
        Title = "Auto Select Best Property (Fill + Auto Upgrade)",
        Default = true,
        Flag = "AutoHighestPropertyToggle",
        Callback = function(Value)
            AutoHighestPropertyMode = Value
        end
    })

    MainTab:CreateDropdown({
        Title = "Manual Select Property",
        Options = PropertyNamesList,
        Multi = false,
        Flag = "SelectedManualProperty",
        Callback = function(Selected)
            if PropertyMap[Selected] then
                SelectedPropertyId = PropertyMap[Selected]
            end
        end
    })

    ----------------------------------------------------------------------------
    -- BUTTON DEBUG
    ----------------------------------------------------------------------------
    MainTab:CreateButton({
        Title = "🔍 Debug Property Info (Check F9)",
        Callback = function()
            local cash = GetCurrentCash()
            local owned, max = GetPropsCapInfo()
            local ownedList, emptyLotNumbers = GetStreetLotsState()
            local best = GetBestAffordableProperty(cash, State.Level)

            print("==================================================")
            print("[PROPERTY DEBUG LOG]")
            print("--------------------------------------------------")
            print("Current Cash :", "$" .. FormatMoneyShort(cash), "(" .. cash .. ")")
            print("Player Level :", State.Level)
            print("Property Cap :", owned .. " / " .. max)
            print("--------------------------------------------------")
            print("EMPTY LOTS (" .. #emptyLotNumbers .. "):", table.concat(emptyLotNumbers, ", "))
            print("--------------------------------------------------")
            print("OWNED LOTS (" .. #ownedList .. "):")
            for _, item in ipairs(ownedList) do
                local propName = item.id and (PROPERTIES_BY_ID[item.id] and PROPERTIES_BY_ID[item.id].name or item.id) or "UNKNOWN ID"
                print(string.format("  • Lot_%d | Prop: %s | Earn/hr: $%s", item.lotNumber, propName, FormatMoneyShort(item.earn)))
            end
            print("--------------------------------------------------")
            print("BEST AFFORDABLE PROPERTY:")
            if best then
                print("  • Name : " .. best.name)
                print("  • ID   : " .. best.id)
                print("  • Cost : $" .. FormatMoneyShort(best.baseCost))
            else
                print("  • None (Insufficient Cash or Level)")
            end
            print("==================================================")

            QueueNotify({
                Title = "Debug Dumped to Console",
                Content = "Cek F9 Developer Console untuk detailnya.",
                Duration = 4
            })
        end
    })
    ----------------------------------------------------------------------------

    -- Mengisi Lot yang kosong secara otomatis
    local function RunAutoFillEmptySlots()
        local MAX_BUY_PER_CYCLE = 15

        for i = 1, MAX_BUY_PER_CYCLE do
            local curOwned, curMax = GetPropsCapInfo()
            if curMax == 0 or curOwned >= curMax then break end

            local _, emptyLotNumbers = GetStreetLotsState()
            if #emptyLotNumbers == 0 then break end

            local targetLot = emptyLotNumbers[1]
            local cash = GetCurrentCash()
            local best = GetBestAffordableProperty(cash, State.Level)

            if not best then break end

            local success = TryBuyProperty(best.id, targetLot)

            if success then
                QueueNotify({
                    Title = "Property Bought!",
                    Content = best.name .. " [Lot " .. targetLot .. "] ($" .. FormatMoneyShort(best.baseCost) .. ")",
                    Duration = 2
                })
                task.wait(0.7)
            else
                break
            end
        end
    end

    -- Upgrade Property terlemah berdasarkan Earn Income
    local function RunAutoUpgradeWeakest()
        local ownedList, _ = GetStreetLotsState()
        if #ownedList == 0 then return end

        local lowest = nil
        for _, t in ipairs(ownedList) do
            if t.earn >= 0 then
                if not lowest or t.earn < lowest.earn then
                    lowest = t
                end
            end
        end

        if not lowest or not lowest.id then return end

        local cash = GetCurrentCash()
        local best = GetBestAffordableProperty(cash, State.Level)

        if not best then return end
        if best.id == lowest.id then return end
        if GetEffectiveIncome(best) <= lowest.earn then return end

        local targetLotNumber = lowest.lotNumber
        local delSuccess = TryDeleteProperty(lowest.id, targetLotNumber)

        if delSuccess then
            task.wait(0.6)

            local postDeleteCash = GetCurrentCash()
            local reconfirmedBest = GetBestAffordableProperty(postDeleteCash, State.Level)
            local targetToBuy = reconfirmedBest or best

            local buySuccess = TryBuyProperty(targetToBuy.id, targetLotNumber)

            if buySuccess then
                QueueNotify({
                    Title = "Property Upgraded!",
                    Content = "Diganti ke: " .. targetToBuy.name .. " [Lot " .. targetLotNumber .. "]",
                    Duration = 3
                })
            else
                local oldPropInfo = PROPERTIES_BY_ID[lowest.id]
                if oldPropInfo then
                    task.wait(0.5)
                    local rebuySuccess = TryBuyProperty(oldPropInfo.id, targetLotNumber)
                    if rebuySuccess then
                        QueueNotify({
                            Title = "Upgrade Gagal - Rollback",
                            Content = "Gagal beli property baru, berhasil rebuy: " .. oldPropInfo.name,
                            Duration = 4
                        })
                    else
                        QueueNotify({
                            Title = "Upgrade Gagal!",
                            Content = "Slot kosong, gagal beli property baru maupun rollback. Cek cash secara manual.",
                            Duration = 5
                        })
                    end
                end
            end
        end
    end

    -- Mode Manual Select
    local function RunManualPropertyMode()
        local owned, max = GetPropsCapInfo()
        if max == 0 then return end

        local ownedList, emptyLotNumbers = GetStreetLotsState()

        local wrongTile = nil
        local matchingCount = 0

        for _, t in ipairs(ownedList) do
            if t.id == SelectedPropertyId then
                matchingCount = matchingCount + 1
            elseif not wrongTile then
                wrongTile = t
            end
        end

        local propInfo = PROPERTIES_BY_ID[SelectedPropertyId]
        if not propInfo then return end

        if wrongTile and wrongTile.id then
            local cash = GetCurrentCash()
            if cash >= propInfo.baseCost and State.Level >= propInfo.level then
                local targetLot = wrongTile.lotNumber
                local delSuccess = TryDeleteProperty(wrongTile.id, targetLot)
                if delSuccess then
                    task.wait(0.6)

                    local postDeleteCash = GetCurrentCash()
                    if postDeleteCash >= propInfo.baseCost then
                        local buySuccess = TryBuyProperty(SelectedPropertyId, targetLot)
                        if buySuccess then
                            QueueNotify({
                                Title = "Property Replaced",
                                Content = "Diganti ke: " .. propInfo.name .. " [Lot " .. targetLot .. "]",
                                Duration = 3
                            })
                        else
                            QueueNotify({
                                Title = "Replace Gagal!",
                                Content = "Slot kosong, gagal beli property pilihan. Cek cash.",
                                Duration = 4
                            })
                        end
                    end
                end
            end
        elseif #emptyLotNumbers > 0 then
            local MAX_BUY_PER_CYCLE = 15
            for i = 1, MAX_BUY_PER_CYCLE do
                local curOwned, curMax = GetPropsCapInfo()
                if curOwned >= curMax then break end

                local _, currentEmptyLots = GetStreetLotsState()
                if #currentEmptyLots == 0 then break end

                local targetLot = currentEmptyLots[1]
                local cash = GetCurrentCash()
                if cash < propInfo.baseCost or State.Level < propInfo.level then
                    break
                end

                local success = TryBuyProperty(SelectedPropertyId, targetLot)
                if success then
                    QueueNotify({
                        Title = "Property Bought!",
                        Content = propInfo.name .. " [Lot " .. targetLot .. "]",
                        Duration = 2
                    })
                    task.wait(0.7)
                else
                    break
                end
            end
        else
            AutoPropertyEnabled = false
            ForceSetToggleOff(AutoPropertyToggleRef, "AutoPropertyToggle")

            QueueNotify({
                Title = "Manual Auto Buy Complete",
                Content = "Semua slot (" .. max .. ") sudah terisi: " .. propInfo.name,
                Duration = 4
            })
        end
    end

    Scheduler:Add("AutoProperty", 2.5, function()
        if not AutoPropertyEnabled then return end

        local owned, max = GetPropsCapInfo()
        if max == 0 then return end

        if AutoHighestPropertyMode then
            if owned < max then
                RunAutoFillEmptySlots()
            else
                RunAutoUpgradeWeakest()
            end
        else
            RunManualPropertyMode()
        end
    end)
end

return PropertyModule
