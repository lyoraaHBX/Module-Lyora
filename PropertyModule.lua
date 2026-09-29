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

    local CashPath = {"PlayerGui", "MafiaWarsUI", "Root", "TopBar", "CashCluster", "CashValue"}

    -- REQ 3: Slot Cap X/Y -> Scroller.Summary.Lots.Value.ContentText (contoh: "10/14")
    local PropsLotsCapPath = {"PlayerGui", "MafiaWarsUI", "Root", "Content", "PropsPanel", "Scroller", "Summary", "Lots", "Value", "ContentText"}

    -- Base path untuk semua slot Lot_N (dipakai untuk REQ 1 & REQ 2)
    local PropsLotsBasePath = {"PlayerGui", "MafiaWarsUI", "Root", "Content", "PropsPanel", "Scroller", "YourBlock", "Street"}

    local PropertyNamesList = {}
    local PropertyMap = {}
    local PROPERTIES_BY_ID = {}

    for _, prop in ipairs(PROPERTIES) do
        local displayName = "[Lv." .. prop.level .. "] " .. prop.name .. " ($" .. FormatMoneyShort(prop.baseCost) .. ")"
        table.insert(PropertyNamesList, displayName)
        PropertyMap[displayName] = prop.id
        PROPERTIES_BY_ID[prop.id] = prop
    end

    -- Cache slot -> propId, dilacak dari hasil buy/delete script sendiri
    -- (struktur GUI baru tidak menyediakan info "id property" di slot, hanya status kosong & earn)
    local SlotOwnershipCache = {}

    local function GetCurrentCash()
        local node = SafeFindPath(CashPath)
        if not node then return 0 end
        local raw = GetRawTextFromNode(node)
        return ParseAbbreviatedNumber(raw)
    end

    -- REQ 3: Baca X/Y dari Summary.Lots.Value.ContentText
    local function GetPropsCapInfo()
        local node = SafeFindPath(PropsLotsCapPath)
        if not node then return 0, 0 end

        local raw = GetRawTextFromNode(node)
        local owned, max = string.match(tostring(raw), "(%d+)%s*/%s*(%d+)")
        return tonumber(owned) or 0, tonumber(max) or 0
    end

    -- REQ 2: Cek slot kosong via keberadaan Lot_{index}.ForSale.Plus
    local function IsSlotEmpty(slotIndex)
        local path = {}
        for _, p in ipairs(PropsLotsBasePath) do table.insert(path, p) end
        table.insert(path, "Lot_" .. tostring(slotIndex))
        table.insert(path, "ForSale")
        table.insert(path, "Plus")

        local node = SafeFindPath(path)
        return node ~= nil  -- ADA node ForSale.Plus = slot KOSONG
    end

    -- REQ 1: Baca earn dari Lot_{index}.Chip.Label.ContentText, contoh "$12.09M/hr"
    local function GetEarnForSlot(slotIndex)
        local path = {}
        for _, p in ipairs(PropsLotsBasePath) do table.insert(path, p) end
        table.insert(path, "Lot_" .. tostring(slotIndex))
        table.insert(path, "Chip")
        table.insert(path, "Label")
        table.insert(path, "ContentText")

        local node = SafeFindPath(path)
        if not node then return 0 end

        local raw = GetRawTextFromNode(node)
        if not raw then return 0 end

        -- Buang suffix "/hr" sebelum parsing jadi angka (misal "$12.09M/hr" -> "$12.09M")
        local cleaned = tostring(raw):gsub("/hr", "")
        return ParseAbbreviatedNumber(cleaned) or 0
    end

    -- Scan semua slot 1..maxSlots, kembalikan list slot TERISI beserta earn & id (cache, bisa nil)
    local function GetOwnedPropertiesList()
        local _, maxSlots = GetPropsCapInfo()
        local list = {}

        for i = 1, maxSlots do
            if not IsSlotEmpty(i) then
                table.insert(list, {
                    id = SlotOwnershipCache[i],
                    index = i,
                    earn = GetEarnForSlot(i),
                })
            end
        end

        return list
    end

    -- REQ 2: Cari index slot kosong pertama (dipakai untuk isi slot dengan buy)
    local function FindNextEmptySlotIndex(maxSlots)
        for i = 1, maxSlots do
            if IsSlotEmpty(i) then
                return i
            end
        end
        return nil
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

    local function TryBuyProperty(propId, slotIndex)
        local success, result = pcall(function()
            return BuyPropertyRemote:InvokeServer(PROPERTY_HASH, propId, slotIndex)
        end)
        if success and type(result) == "table" and result.ok == true then
            SlotOwnershipCache[slotIndex] = propId
            return true, result
        end
        return false, result
    end

    local function TryDeleteProperty(propId, slotIndex)
        local success, result = pcall(function()
            return DeletePropertyRemote:InvokeServer(PROPERTY_HASH, propId, slotIndex)
        end)
        if success and type(result) == "table" and result.ok == true then
            SlotOwnershipCache[slotIndex] = nil
            return true, result
        end
        return false, result
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

    -- REQ 2 dalam aksi: cari slot kosong -> isi dengan buy
    local function RunAutoFillEmptySlots()
        local MAX_BUY_PER_CYCLE = 15

        for i = 1, MAX_BUY_PER_CYCLE do
            local curOwned, curMax = GetPropsCapInfo()

            if curMax == 0 or curOwned >= curMax then
                break
            end

            local cash = GetCurrentCash()
            local best = GetBestAffordableProperty(cash, State.Level)

            if not best then
                break
            end

            local slotIndex = FindNextEmptySlotIndex(curMax)

            if not slotIndex then
                break
            end

            local success = TryBuyProperty(best.id, slotIndex)

            if success then
                QueueNotify({
                    Title = "Property Bought!",
                    Content = best.name .. " ($" .. FormatMoneyShort(best.baseCost) .. ")",
                    Duration = 2
                })
                task.wait(0.7)
            else
                break
            end
        end
    end

    -- REQ 1 dalam aksi: cari earn TERLEMAH, bandingkan dengan cash untuk cari pengganti
    local function RunAutoUpgradeWeakest()
        local ownedList = GetOwnedPropertiesList()
        if #ownedList == 0 then return end

        local lowest = nil
        for _, t in ipairs(ownedList) do
            if t.earn > 0 then
                if not lowest or t.earn < lowest.earn then
                    lowest = t
                end
            end
        end

        if not lowest then return end

        local cash = GetCurrentCash()
        local best = GetBestAffordableProperty(cash, State.Level)

        if not best then return end
        if best.id == lowest.id then return end
        if GetEffectiveIncome(best) <= lowest.earn then return end

        local delSuccess = TryDeleteProperty(lowest.id, lowest.index)

        if delSuccess then
            task.wait(0.6)

            local postDeleteCash = GetCurrentCash()
            local reconfirmedBest = GetBestAffordableProperty(postDeleteCash, State.Level)

            local targetToBuy = reconfirmedBest or best

            local buySuccess = TryBuyProperty(targetToBuy.id, lowest.index)

            if buySuccess then
                QueueNotify({
                    Title = "Property Upgraded!",
                    Content = "Diganti ke: " .. targetToBuy.name,
                    Duration = 3
                })
            else
                local oldPropInfo = PROPERTIES_BY_ID[lowest.id]
                if oldPropInfo then
                    task.wait(0.5)
                    local rebuySuccess = TryBuyProperty(oldPropInfo.id, lowest.index)
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
                else
                    QueueNotify({
                        Title = "Upgrade Gagal!",
                        Content = "Slot kosong (id lama tidak diketahui, tidak bisa rollback). Cek manual.",
                        Duration = 5
                    })
                end
            end
        end
    end

    local function RunManualPropertyMode()
        local owned, max = GetPropsCapInfo()
        if max == 0 then return end

        local ownedList = GetOwnedPropertiesList()

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
                local delSuccess = TryDeleteProperty(wrongTile.id, wrongTile.index)
                if delSuccess then
                    task.wait(0.6)

                    local postDeleteCash = GetCurrentCash()
                    if postDeleteCash >= propInfo.baseCost then
                        local buySuccess = TryBuyProperty(SelectedPropertyId, wrongTile.index)
                        if buySuccess then
                            QueueNotify({
                                Title = "Property Replaced",
                                Content = "Diganti ke: " .. propInfo.name,
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
        elseif matchingCount < max then
            local MAX_BUY_PER_CYCLE = 15
            for i = 1, MAX_BUY_PER_CYCLE do
                local curOwned, curMax = GetPropsCapInfo()
                if curOwned >= curMax then break end

                local cash = GetCurrentCash()
                if cash < propInfo.baseCost or State.Level < propInfo.level then
                    break
                end

                local slotIndex = FindNextEmptySlotIndex(curMax)
                if not slotIndex then break end

                local success = TryBuyProperty(SelectedPropertyId, slotIndex)
                if success then
                    QueueNotify({
                        Title = "Property Bought!",
                        Content = propInfo.name,
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

    ----------------------------------------------------------------
    -- DEBUG TOOLS
    ----------------------------------------------------------------
    MainTab:CreateSection("Debug Tools")

    MainTab:CreateButton({
        Title = "Debug: Cash & Slot Cap (X/Y)",
        Callback = function()
            local cash = GetCurrentCash()
            local owned, max = GetPropsCapInfo()

            print("========== [DEBUG] Cash & Cap ==========")
            print("Cash terbaca:", cash)
            print("Slot Cap (owned/max):", owned .. "/" .. max)
            print("=========================================")

            QueueNotify({
                Title = "Debug: Cash & Cap",
                Content = "Cash: " .. FormatMoneyShort(cash) .. " | Slot: " .. owned .. "/" .. max,
                Duration = 5
            })
        end
    })

    MainTab:CreateButton({
        Title = "Debug: Scan Semua Slot (Empty/Earn/CacheId)",
        Callback = function()
            local owned, max = GetPropsCapInfo()

            if max == 0 then
                print("[DEBUG] Gagal baca slot cap, max = 0. Cek path PropsLotsCapPath.")
                QueueNotify({ Title = "Debug: Scan Slot", Content = "Gagal baca slot cap (max=0)!", Duration = 4 })
                return
            end

            print("========== [DEBUG] Scan Semua Slot (1.." .. max .. ") ==========")
            local emptyCount = 0
            local filledCount = 0

            for i = 1, max do
                local isEmpty = IsSlotEmpty(i)
                local earn = GetEarnForSlot(i)
                local cachedId = SlotOwnershipCache[i]

                if isEmpty then
                    emptyCount = emptyCount + 1
                    print(string.format("Lot_%d -> KOSONG (ForSale.Plus ditemukan)", i))
                else
                    filledCount = filledCount + 1
                    print(string.format("Lot_%d -> TERISI | Earn: %s | CachedId: %s", i, tostring(earn), tostring(cachedId or "nil (tidak diketahui)")))
                end
            end

            print("Total: " .. filledCount .. " terisi, " .. emptyCount .. " kosong (dari " .. max .. " slot)")
            print("=================================================================")

            QueueNotify({
                Title = "Debug: Scan Slot",
                Content = filledCount .. " terisi, " .. emptyCount .. " kosong. Detail di console.",
                Duration = 5
            })
        end
    })

    MainTab:CreateButton({
        Title = "Debug: Cari Slot Kosong Berikutnya",
        Callback = function()
            local owned, max = GetPropsCapInfo()

            if max == 0 then
                QueueNotify({ Title = "Debug: Find Empty Slot", Content = "Gagal baca slot cap (max=0)!", Duration = 4 })
                return
            end

            local slotIndex = FindNextEmptySlotIndex(max)

            print("========== [DEBUG] Find Next Empty Slot ==========")
            print("Slot kosong ditemukan di index:", tostring(slotIndex))
            print("===================================================")

            QueueNotify({
                Title = "Debug: Find Empty Slot",
                Content = slotIndex and ("Slot kosong: Lot_" .. slotIndex) or "Tidak ada slot kosong!",
                Duration = 4
            })
        end
    })

    MainTab:CreateButton({
        Title = "Debug: Property Terbaik Terjangkau Saat Ini",
        Callback = function()
            local cash = GetCurrentCash()
            local level = State.Level
            local best = GetBestAffordableProperty(cash, level)

            print("========== [DEBUG] Best Affordable Property ==========")
            print("Cash:", cash, "| Level:", level)
            if best then
                print("Best Property:", best.id, "-", best.name, "| Cost:", best.baseCost, "| ReqLevel:", best.level)
            else
                print("Tidak ada property yang terjangkau!")
            end
            print("========================================================")

            QueueNotify({
                Title = "Debug: Best Property",
                Content = best and (best.name .. " ($" .. FormatMoneyShort(best.baseCost) .. ")") or "Tidak ada yang terjangkau!",
                Duration = 5
            })
        end
    })

    MainTab:CreateButton({
        Title = "Debug: Owned Properties List (Full)",
        Callback = function()
            local ownedList = GetOwnedPropertiesList()

            print("========== [DEBUG] Owned Properties List ==========")
            if #ownedList == 0 then
                print("Tidak ada property yang dimiliki (atau gagal baca).")
            else
                for _, t in ipairs(ownedList) do
                    print(string.format("Slot %d | Id: %s | Earn: %s", t.index, tostring(t.id or "nil"), tostring(t.earn)))
                end
            end
            print("Total owned:", #ownedList)
            print("=====================================================")

            QueueNotify({
                Title = "Debug: Owned List",
                Content = "Total dimiliki: " .. #ownedList .. ". Detail di console.",
                Duration = 4
            })
        end
    })

    MainTab:CreateButton({
        Title = "Debug: Cek Slot Terlemah (Untuk Upgrade)",
        Callback = function()
            local ownedList = GetOwnedPropertiesList()

            local lowest = nil
            for _, t in ipairs(ownedList) do
                if t.earn > 0 then
                    if not lowest or t.earn < lowest.earn then
                        lowest = t
                    end
                end
            end

            print("========== [DEBUG] Slot Terlemah ==========")
            if lowest then
                print(string.format("Slot %d | Id: %s | Earn: %s", lowest.index, tostring(lowest.id or "nil"), tostring(lowest.earn)))
            else
                print("Tidak ada slot dengan earn > 0 (mungkin belum ada property atau semua earn=0).")
            end
            print("=============================================")

            QueueNotify({
                Title = "Debug: Slot Terlemah",
                Content = lowest and ("Lot_" .. lowest.index .. " | Earn: " .. lowest.earn) or "Tidak ditemukan!",
                Duration = 4
            })
        end
    })
end

return PropertyModule
