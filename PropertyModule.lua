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
    local PROPERTIES_LOWER = {} -- {id=..., lowerName=...} precomputed sekali saja

    for _, prop in ipairs(PROPERTIES) do
        local displayName = "[Lv." .. prop.level .. "] " .. prop.name .. " ($" .. FormatMoneyShort(prop.baseCost) .. ")"
        table.insert(PropertyNamesList, displayName)
        PropertyMap[displayName] = prop.id
        PROPERTIES_BY_ID[prop.id] = prop
        table.insert(PROPERTIES_LOWER, { id = prop.id, lowerName = string.lower(prop.name) })
    end

    ----------------------------------------------------------------------------
    -- CONSTANT TABLES (hoisted, biar ga alokasi ulang tiap call -> kurangi GC)
    ----------------------------------------------------------------------------
    local PROPERTY_ID_ATTRS = {"PropertyId", "PropId", "id", "ID"}

    -- Cache hasil deteksi Property ID per Lot Node.
    -- weak-keys supaya kalau Instance-nya destroyed, cache auto ke-GC.
    local LotPropertyCache = setmetatable({}, { __mode = "k" })

    local function GetCurrentCash()
        local node = SafeFindPath(CashPath)
        if not node then return 0 end
        local raw = GetRawTextFromNode(node)
        return ParseAbbreviatedNumber(raw)
    end

    local function GetPropsCapInfo()
        local node = SafeFindPath(SummaryLotsPath)
        if not node then return 0, 0 end

        local raw = GetRawTextFromNode(node)
        local owned, max = string.match(tostring(raw), "(%d+)%s*/%s*(%d+)")
        return tonumber(owned) or 0, tonumber(max) or 0
    end

    local function ExtractLotNumber(lotName)
        return tonumber(string.match(lotName, "^Lot_(%d+)$"))
    end

    local function IsLotLocked(lotNode)
        local lockedNode = lotNode:FindFirstChild("Locked")
        return lockedNode ~= nil and (
            (lockedNode:IsA("GuiObject") and lockedNode.Visible == true) or
            (not lockedNode:IsA("GuiObject"))
        )
    end

    local function IsLotForSale(lotNode)
        local forSaleNode = lotNode:FindFirstChild("ForSale")
        return forSaleNode ~= nil and (
            (forSaleNode:IsA("GuiObject") and forSaleNode.Visible == true) or
            forSaleNode:FindFirstChild("Plus") ~= nil
        )
    end

    ----------------------------------------------------------------------------
    -- DETEKSI PROPERTY ID DARI LOT (DIOPTIMASI + DI-CACHE)
    ----------------------------------------------------------------------------
    -- Step 2 & 3 lama (loop PROPERTIES_BY_ID x FindFirstChild) diganti jadi
    -- 1x GetChildren() + hash lookup -> O(children) bukan O(properties).
    -- Step 4 (GetDescendants + string search) HANYA fallback terakhir,
    -- dan hasilnya di-cache supaya tidak diulang tiap scan.
    local function DetectPropertyIdFromLot(lotNode)
        local cached = LotPropertyCache[lotNode]
        if cached ~= nil then
            return cached
        end

        local result = nil

        -- 1. Attribute check
        for _, attr in ipairs(PROPERTY_ID_ATTRS) do
            local val = lotNode:GetAttribute(attr)
            if val and PROPERTIES_BY_ID[val] then
                result = val
                break
            end
        end

        -- 2. Nama child langsung (gabungan step lama 2 & 3, hash lookup O(1))
        if not result then
            for _, child in ipairs(lotNode:GetChildren()) do
                local name = child.Name
                if PROPERTIES_BY_ID[name] then
                    result = name
                    break
                end
                local matchedId = string.match(name, "^Tile_(.+)$") or string.match(name, "^Prop_(.+)$")
                if matchedId and PROPERTIES_BY_ID[matchedId] then
                    result = matchedId
                    break
                end
            end
        end

        -- 3. Fallback berat: scan text descendant (hanya kalau benar2 perlu)
        if not result then
            for _, child in ipairs(lotNode:GetDescendants()) do
                if child:IsA("TextLabel") or child:IsA("TextBox") then
                    local text = string.lower(child.Text)
                    for _, entry in ipairs(PROPERTIES_LOWER) do
                        if string.find(text, entry.lowerName, 1, true) then
                            result = entry.id
                            break
                        end
                    end
                    if result then break end
                end
            end
        end

        -- Hanya cache hasil POSITIF. Kalau nil, jangan di-cache
        -- (UI mungkin belum fully rendered, biar bisa re-detect nanti).
        if result then
            LotPropertyCache[lotNode] = result
        end

        return result
    end

    local function InvalidateLotCache(lotNode)
        if lotNode then
            LotPropertyCache[lotNode] = nil
        end
    end

    ----------------------------------------------------------------------------
    -- SCAN RINGAN: hanya ambil empty lot number, TANPA detect property (murah)
    -- Dipakai di loop pembelian supaya tidak trigger DetectPropertyIdFromLot
    -- untuk lot yang sudah owned & tidak relevan.
    ----------------------------------------------------------------------------
    local function GetEmptyLotNumbers()
        local streetNode = SafeFindPath(StreetPath)
        if not streetNode then return {} end

        local emptyLotNumbers = {}
        for _, lotNode in ipairs(streetNode:GetChildren()) do
            local lotNum = ExtractLotNumber(lotNode.Name)
            if lotNum and not IsLotLocked(lotNode) and IsLotForSale(lotNode) then
                table.insert(emptyLotNumbers, lotNum)
            end
        end

        table.sort(emptyLotNumbers)
        return emptyLotNumbers
    end

    ----------------------------------------------------------------------------
    -- SCAN PENUH (owned + empty) - dipakai saat memang butuh info property owned
    -- (upgrade weakest, manual wrongTile check, debug). Dipanggil MAX 1x/cycle.
    ----------------------------------------------------------------------------
    local function GetStreetLotsState()
        local streetNode = SafeFindPath(StreetPath)
        if not streetNode then return {}, {} end

        local ownedList = {}
        local emptyLotNumbers = {}

        for _, lotNode in ipairs(streetNode:GetChildren()) do
            local lotNum = ExtractLotNumber(lotNode.Name)
            if lotNum then
                if not IsLotLocked(lotNode) then
                    if IsLotForSale(lotNode) then
                        table.insert(emptyLotNumbers, lotNum)
                    else
                        local chip = lotNode:FindFirstChild("Chip")
                        local chipLabel = chip and chip:FindFirstChild("Label")
                        local earnValue = 0

                        if chipLabel then
                            local rawText = GetRawTextFromNode(chipLabel)
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

    local function TryBuyProperty(propId, lotNumber)
        local success, result = pcall(function()
            return BuyPropertyRemote:InvokeServer(PROPERTY_HASH, propId, lotNumber)
        end)
        if success and type(result) == "table" then
            return result.ok == true, result
        end
        return false, nil
    end

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
    -- BUTTON DEBUG & EARN CHECK (dipakai user manual, tidak perlu dioptimasi ekstrem)
    ----------------------------------------------------------------------------
    MainTab:CreateButton({
        Title = "📉 Check Lowest Earn Property",
        Callback = function()
            local cash = GetCurrentCash()
            local ownedList, _ = GetStreetLotsState()

            if #ownedList == 0 then
                QueueNotify({
                    Title = "Earn Check Result",
                    Content = "Tidak ada property yang dimiliki saat ini.",
                    Duration = 4
                })
                return
            end

            local lowest = nil
            for _, t in ipairs(ownedList) do
                if t.earn >= 0 then
                    if not lowest or t.earn < lowest.earn then
                        lowest = t
                    end
                end
            end

            local best = GetBestAffordableProperty(cash, State.Level)
            local propName = lowest.id and (PROPERTIES_BY_ID[lowest.id] and PROPERTIES_BY_ID[lowest.id].name or lowest.id) or "Unknown"

            print("==================================================")
            print("[LOWEST EARN CHECK]")
            print(string.format("Lowest Property : Lot_%d (%s)", lowest.lotNumber, propName))
            print(string.format("Current Earn    : $%s/hr", FormatMoneyShort(lowest.earn)))
            print("Current Cash    :", "$" .. FormatMoneyShort(cash))

            if best then
                local bestIncome = GetEffectiveIncome(best)
                print(string.format("Best Buyable    : %s ($%s/hr) - Cost: $%s", best.name, FormatMoneyShort(bestIncome), FormatMoneyShort(best.baseCost)))
                if bestIncome > lowest.earn then
                    print("Status          : READY TO UPGRADE (Property Baru Lebih Untung!)")
                else
                    print("Status          : WAITING (Cash cukup tapi property terbaik belum lebih untung dari lowest saat ini)")
                end
            else
                print("Status          : CANNOT AFFORD (Cash tidak cukup untuk upgrade)")
            end
            print("==================================================")

            local statusMsg = "Lot " .. lowest.lotNumber .. " (" .. propName .. ") - $" .. FormatMoneyShort(lowest.earn) .. "/hr"
            if best and GetEffectiveIncome(best) > lowest.earn then
                statusMsg = statusMsg .. "\nBisa Upgrade ke: " .. best.name
            else
                statusMsg = statusMsg .. "\nBelum ada upgrade yang lebih tinggi."
            end

            QueueNotify({
                Title = "Lowest Earn Property Detected",
                Content = statusMsg,
                Duration = 5
            })
        end
    })

    MainTab:CreateButton({
        Title = "🔍 Debug Full Property Info (F9)",
        Callback = function()
            local cash = GetCurrentCash()
            local owned, max = GetPropsCapInfo()
            local ownedList, emptyLotNumbers = GetStreetLotsState()
            local best = GetBestAffordableProperty(cash, State.Level)

            print("==================================================")
            print("[FULL PROPERTY DEBUG LOG]")
            print("--------------------------------------------------")
            print("Current Cash :", "$" .. FormatMoneyShort(cash), "(" .. cash .. ")")
            print("Player Level :", State.Level)
            print("Property Cap :", owned .. " / " .. max)
            print("--------------------------------------------------")
            print("UNLOCKED EMPTY LOTS (" .. #emptyLotNumbers .. "):", table.concat(emptyLotNumbers, ", "))
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
                Content = "Cek F9 Developer Console untuk detail lengkap.",
                Duration = 4
            })
        end
    })
    ----------------------------------------------------------------------------

    -- OPTIMIZED: hanya 1x scan street (GetEmptyLotNumbers, ringan),
    -- sisanya update index lokal & increment counter manual (tanpa rescan).
    local function RunAutoFillEmptySlots(curOwned, curMax)
        local MAX_BUY_PER_CYCLE = 15
        local emptyLotNumbers = GetEmptyLotNumbers()
        local idx = 1

        for _ = 1, MAX_BUY_PER_CYCLE do
            if curOwned >= curMax then break end
            if idx > #emptyLotNumbers then break end

            local targetLot = emptyLotNumbers[idx]
            local cash = GetCurrentCash()
            local best = GetBestAffordableProperty(cash, State.Level)

            if not best then break end

            local success = TryBuyProperty(best.id, targetLot)

            if success then
                curOwned = curOwned + 1
                idx = idx + 1

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

        if not lowest then return end

        local cash = GetCurrentCash()
        local best = GetBestAffordableProperty(cash, State.Level)

        if not best then return end
        if lowest.id and best.id == lowest.id then return end
        if GetEffectiveIncome(best) <= lowest.earn then return end

        local targetLotNumber = lowest.lotNumber
        local delSuccess = TryDeleteProperty(lowest.id or "", targetLotNumber)

        if delSuccess then
            InvalidateLotCache(lowest.node) -- WAJIB: property di lot ini berubah
            task.wait(0.6)

            local postDeleteCash = GetCurrentCash()
            local reconfirmedBest = GetBestAffordableProperty(postDeleteCash, State.Level)
            local targetToBuy = reconfirmedBest or best

            local buySuccess = TryBuyProperty(targetToBuy.id, targetLotNumber)

            if buySuccess then
                QueueNotify({
                    Title = "Property Upgraded!",
                    Content = "Lot " .. targetLotNumber .. " diganti ke: " .. targetToBuy.name,
                    Duration = 3
                })
            else
                local oldPropInfo = lowest.id and PROPERTIES_BY_ID[lowest.id]
                if oldPropInfo then
                    task.wait(0.5)
                    local rebuySuccess = TryBuyProperty(oldPropInfo.id, targetLotNumber)
                    if rebuySuccess then
                        QueueNotify({
                            Title = "Upgrade Gagal - Rollback",
                            Content = "Gagal beli baru, berhasil rebuy: " .. oldPropInfo.name,
                            Duration = 4
                        })
                    else
                        QueueNotify({
                            Title = "Upgrade Gagal!",
                            Content = "Slot " .. targetLotNumber .. " kosong, gagal beli/rollback.",
                            Duration = 5
                        })
                    end
                end
            end
        end
    end

    -- Mode Manual Select (OPTIMIZED: satu kali full scan, loop pakai index lokal)
    local function RunManualPropertyMode(owned, max)
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

        if wrongTile then
            local cash = GetCurrentCash()
            if cash >= propInfo.baseCost and State.Level >= propInfo.level then
                local targetLot = wrongTile.lotNumber
                local delSuccess = TryDeleteProperty(wrongTile.id or "", targetLot)
                if delSuccess then
                    InvalidateLotCache(wrongTile.node) -- WAJIB
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
            local idx = 1
            local curOwned = owned

            for _ = 1, MAX_BUY_PER_CYCLE do
                if curOwned >= max then break end
                if idx > #emptyLotNumbers then break end

                local targetLot = emptyLotNumbers[idx]
                local cash = GetCurrentCash()
                if cash < propInfo.baseCost or State.Level < propInfo.level then
                    break
                end

                local success = TryBuyProperty(SelectedPropertyId, targetLot)
                if success then
                    curOwned = curOwned + 1
                    idx = idx + 1
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
                RunAutoFillEmptySlots(owned, max)
            else
                RunAutoUpgradeWeakest()
            end
        else
            RunManualPropertyMode(owned, max)
        end
    end)
end

return PropertyModule
