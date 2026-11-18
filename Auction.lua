local WC = WoWCensus
local A = {}
WC.Auction = A

local READ_BATCH = 150
local REPLY_TIMEOUT = 30
local button
local events = CreateFrame("Frame")

A.scanning = false
A.atAuctionHouse = false

local function modernAuctionHouse()
    if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then return false end
    if WOW_PROJECT_ID and WOW_PROJECT_MISTS_CLASSIC
        and WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC then return true end
    return type(QueryAuctionItems) ~= "function"
end

local function countKeys(rows)
    local n = 0
    for _ in pairs(rows or {}) do n = n + 1 end
    return n
end

local function weightedPrice(prices, percentile)
    if #prices == 0 then return 0 end
    table.sort(prices, function(a, b) return a.price < b.price end)
    local total = 0
    for _, row in ipairs(prices) do total = total + row.quantity end
    if total <= 0 then return prices[1].price end
    local target, seen = total * percentile, 0
    for _, row in ipairs(prices) do
        seen = seen + row.quantity
        if seen >= target then return row.price end
    end
    return prices[#prices].price
end

local function weightedAverage(prices)
    local value, quantity = 0, 0
    for _, row in ipairs(prices) do
        value = value + row.price * row.quantity
        quantity = quantity + row.quantity
    end
    return quantity > 0 and math.floor(value / quantity + 0.5) or 0
end

local function add(items, itemID, name, link, quantity, auctions, price)
    if not itemID or not quantity or quantity <= 0 or not price or price <= 0 then return false end
    local item = items[itemID]
    if not item then
        item = { name = name, link = link, quantity = 0, auctions = 0, prices = {} }
        items[itemID] = item
    end
    item.name = item.name or name
    item.link = item.link or link
    item.quantity = item.quantity + quantity
    item.auctions = item.auctions + (auctions or 0)
    item.prices[#item.prices + 1] = { price = price, quantity = quantity }
    return true
end

local function setButtonText(text)
    if button then button:SetText(text) end
end

function A:AtAuctionHouse()
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() then return true end
    if AuctionFrame and AuctionFrame:IsShown() then return true end
    return self.atAuctionHouse
end

function A:AttachButton()
    local parent = AuctionHouseFrame or AuctionFrame
    if not parent then return end
    if not button then
        button = CreateFrame("Button", "WoWCensusAuctionScanButton", parent, "UIPanelButtonTemplate")
        button:SetSize(112, 22)
        button:SetText("Census Scan")
        button:SetScript("OnClick", function() A:Start() end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("WoWCensus Auction Scan")
            GameTooltip:AddLine("Manually captures one Auction House snapshot for wowcensus.io. Nothing runs automatically.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        button:SetParent(parent)
    end
    button:ClearAllPoints()
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -38, -30)
    button:Show()
    setButtonText(self.scanning and "Scanning..." or "Census Scan")
end

function A:Reset()
    self.items = {}
    self.rows = 0
    self.readIndex = 1
    self.readTotal = 0
    self.awaiting = false
    self.action = nil
end

function A:Abort(reason)
    if not self.scanning then return end
    self.scanning = false
    self.awaiting = false
    setButtonText("Census Scan")
    WC:Print("Auction scan stopped: %s.", reason or "unknown error")
end

function A:ArmWatchdog()
    self.watchdog = (self.watchdog or 0) + 1
    local stamp = self.watchdog
    if C_Timer and C_Timer.After then
        C_Timer.After(REPLY_TIMEOUT, function()
            if A.scanning and A.awaiting and A.watchdog == stamp then
                A:Abort("no reply after 30 seconds")
            end
        end)
    end
end

function A:Start()
    if self.scanning then return end
    if not self:AtAuctionHouse() then
        WC:Print("Open the Auction House before starting a scan.")
        return
    end
    self:Reset()
    self.scanning = true
    setButtonText("Scanning...")

    if modernAuctionHouse() then
        self.mode = "browse"
        self.action = "start"
        WC:Print("Auction scan started.")
        self:TryBrowseAction()
        return
    end

    if type(QueryAuctionItems) ~= "function" or type(CanSendAuctionQuery) ~= "function" then
        return self:Abort("this client has no supported scan API")
    end
    local canQuery, canGetAll = CanSendAuctionQuery()
    if not canQuery then return self:Abort("the Auction House is busy; try again shortly") end
    if not canGetAll then return self:Abort("the full scan is on cooldown; try again later") end

    self.mode = "getAll"
    self.awaiting = true
    self:ArmWatchdog()
    WC:Print("Auction scan started.")
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false)
end

local function browseReady()
    return not C_AuctionHouse.IsThrottledMessageSystemReady
        or C_AuctionHouse.IsThrottledMessageSystemReady()
end

function A:TryBrowseAction()
    if not self.scanning or self.mode ~= "browse" or not self.action or not browseReady() then return end
    local action = self.action
    self.action = nil
    self.awaiting = true
    self:ArmWatchdog()
    if action == "start" then
        C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
    else
        C_AuctionHouse.RequestMoreBrowseResults()
    end
end

function A:ReadBrowseResults()
    if not self.scanning or self.mode ~= "browse" or not self.awaiting then return end
    self.awaiting = false
    if not C_AuctionHouse.HasFullBrowseResults() then
        self.action = "more"
        self:TryBrowseAction()
        return
    end

    -- Blizzard may replace or repeat partial batches while assembling the
    -- result set. Read only the final authoritative set to avoid double counts.
    self.items, self.rows = {}, 0
    local results = C_AuctionHouse.GetBrowseResults() or {}
    local added = 0
    for _, result in ipairs(results) do
        local key = result.itemKey
        local itemID = key and key.itemID
        local name, link
        if itemID and C_AuctionHouse.GetItemKeyInfo then
            local info = C_AuctionHouse.GetItemKeyInfo(key)
            name = info and info.itemName
        end
        if itemID and C_Item and C_Item.GetItemInfo then
            local itemName, itemLink = C_Item.GetItemInfo(itemID)
            name, link = name or itemName, itemLink
        elseif itemID and GetItemInfo then
            name, link = GetItemInfo(itemID)
        end
        if add(self.items, itemID, name, link, result.totalQuantity, 0, result.minPrice) then
            added = added + 1
        end
    end
    self.rows = self.rows + added
    if self.rows == 0 then return self:Abort("the scan returned no usable items") end
    self:Finish(false)
end

function A:BeginLegacyRead()
    self.awaiting = false
    self.readTotal = GetNumAuctionItems("list") or 0
    self.readIndex = 1
    self:ReadLegacyBatch()
end

function A:ReadLegacyBatch()
    if not self.scanning then return end
    local stop = math.min(self.readIndex + READ_BATCH - 1, self.readTotal)
    for index = self.readIndex, stop do
        local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
            GetAuctionItemInfo("list", index)
        if itemID and buyout and buyout > 0 then
            count = math.max(count or 1, 1)
            add(self.items, itemID, name, GetAuctionItemLink("list", index), count, 1,
                math.floor(buyout / count))
        end
    end
    self.rows = stop
    self.readIndex = stop + 1
    if self.readIndex > self.readTotal then
        self:Finish(true)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(0, function() A:ReadLegacyBatch() end)
    else
        self:ReadLegacyBatch()
    end
end

function A:Finish(auctionsAvailable)
    if not self.scanning then return end
    local captured = time()
    local realm = WC.realm
    realm.items = realm.items or {}
    for itemID, item in pairs(self.items) do
        local rec = realm.items[itemID] or { snaps = {} }
        rec.name, rec.link = item.name or rec.name, item.link or rec.link
        rec.snaps = rec.snaps or {}
        rec.snaps[#rec.snaps + 1] = {
            t = captured, q = item.quantity, a = item.auctions, s = 0,
            l = weightedPrice(item.prices, 0),
            m = weightedPrice(item.prices, 0.5),
            w = weightedAverage(item.prices), tc = 0,
        }
        while #rec.snaps > 8 do table.remove(rec.snaps, 1) end
        realm.items[itemID] = rec
    end
    realm.lastScan = captured
    realm.auctionsAvailable = auctionsAvailable and true or false
    realm.ownersAvailable = false
    realm.priceDistributionAvailable = auctionsAvailable and true or false
    local itemCount = countKeys(self.items)
    self.scanning = false
    self.awaiting = false
    setButtonText("Census Scan")
    WC:Print("Auction scan complete: %d rows, %d items saved.", self.rows, itemCount)
end

local function register(name)
    pcall(events.RegisterEvent, events, name)
end

register("AUCTION_HOUSE_SHOW")
register("AUCTION_HOUSE_CLOSED")
register("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
register("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
if modernAuctionHouse() then
    register("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    register("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    register("AUCTION_HOUSE_BROWSE_FAILURE")
    register("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
    register("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
else
    register("AUCTION_ITEM_LIST_UPDATE")
end

local AUCTIONEER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "AUCTION_HOUSE_SHOW" then
        A.atAuctionHouse = true
        A:AttachButton()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if AUCTIONEER == nil or arg1 == AUCTIONEER then
            A.atAuctionHouse = true
            if C_Timer and C_Timer.After then C_Timer.After(0, function() A:AttachButton() end) end
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        A.atAuctionHouse = false
        if button then button:Hide() end
        if A.scanning then A:Abort("the Auction House closed") end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if AUCTIONEER == nil or arg1 == AUCTIONEER then
            A.atAuctionHouse = false
            if button then button:Hide() end
            if A.scanning then A:Abort("the Auction House closed") end
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" and A.scanning and A.mode == "getAll" and A.awaiting then
        A:BeginLegacyRead()
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
        or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        A:ReadBrowseResults()
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        A:TryBrowseAction()
    elseif (event == "AUCTION_HOUSE_BROWSE_FAILURE"
        or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        and A.scanning and A.mode == "browse" then
        A:Abort("the Auction House rejected the scan")
    end
end)

function A:Init()
    self:Reset()
    if self:AtAuctionHouse() then self:AttachButton() end
end
