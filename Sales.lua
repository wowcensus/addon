local WC = WoWCensus
local S = {}
WC.Sales = S

local RETENTION_DAYS = 90
local MAIL_MATCH_SECONDS = 900
local events = CreateFrame("Frame")
local log
local queue = {}
local lastSell
local mailSeen = {}
local ownedSeen = {}

local function now()
    return time()
end

local function serverNow()
    return GetServerTime and GetServerTime() or time()
end

local function gameClock()
    if GetGameTime then
        local ok, h, m = pcall(GetGameTime)
        if ok then return h, m end
    end
end

local function pattern(format)
    if type(format) ~= "string" then return nil end
    local escaped = format:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    escaped = escaped:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. escaped .. "$"
end

local SOLD = pattern(ERR_AUCTION_SOLD_S)
local EXPIRED = pattern(ERR_AUCTION_EXPIRED_S)

local function modern()
    if not (C_AuctionHouse and C_AuctionHouse.PostItem) then return false end
    if WOW_PROJECT_ID and WOW_PROJECT_MISTS_CLASSIC and WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC then return true end
    return type(PostAuction) ~= "function" and type(StartAuction) ~= "function"
end

local function itemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

function S:Enabled()
    return WC.Market and WC.Market.Enabled and WC.Market:Enabled()
end

function S:Log()
    if log then return log end
    local guid = UnitGUID and UnitGUID("player")
    if not guid or not WC.db then return nil end
    WC.db.auctionLog = WC.db.auctionLog or {}
    local identity = WC:RealmIdentity()
    local key = identity.game .. ":" .. guid
    local entry = WC.db.auctionLog[key] or { rows = {} }
    entry.identity = identity
    entry.char = UnitName and UnitName("player") or nil
    entry.realm = GetRealmName and GetRealmName() or nil
    entry.faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    entry.rows = entry.rows or {}
    local latest = {}
    for _, row in pairs(entry.rows) do
        if row.kind == "owned" and row.auctionID and (latest[row.auctionID] or 0) <= (row.t or 0) then
            latest[row.auctionID] = row.t or 0
            ownedSeen[row.auctionID] = row.status
        end
    end
    WC.db.auctionLog[key] = entry
    log = entry
    return log
end

function S:Add(row)
    if not self:Enabled() then return end
    local entry = self:Log()
    if not entry then return end
    row.t = row.t or now()
    row.st = row.st or serverNow()
    local base = table.concat({ row.kind, tostring(row.t), tostring(row.name), tostring(row.count),
        tostring(row.buyout), tostring(row.auctionID) }, "|")
    local key, n = base, 1
    while entry.rows[key] do
        n = n + 1
        key = base .. "#" .. n
    end
    entry.rows[key] = row
    WC:Fire("SALES_CHANGED")
    return key
end

function S:Prune()
    for _, entry in pairs(WC.db and WC.db.auctionLog or {}) do
        local cutoff = now() - RETENTION_DAYS * 86400
        for key, row in pairs(entry.rows or {}) do
            if (row.t or 0) < cutoff then entry.rows[key] = nil end
        end
    end
end

local function sellItem()
    if type(GetAuctionSellItemInfo) ~= "function" then return nil end
    local name, _, count, _, _, _, _, _, _, itemID = GetAuctionSellItemInfo()
    if not name then return nil end
    return { name = name, count = count, itemID = itemID }
end

local function onLegacyPost(bid, buyout, runTime, stackSize, numStacks)
    local item = sellItem() or lastSell
    if not item then return end
    local stacks = tonumber(numStacks) or 1
    for _ = 1, math.max(stacks, 1) do
        queue[#queue + 1] = {
            kind = "post", name = item.name, itemID = item.itemID,
            count = tonumber(stackSize) or item.count, bid = tonumber(bid), buyout = tonumber(buyout),
            runTime = tonumber(runTime), queuedAt = now(),
        }
    end
end

local function onLegacyStart(bid, buyout, runTime)
    local item = sellItem() or lastSell
    if not item then return end
    queue[#queue + 1] = {
        kind = "post", name = item.name, itemID = item.itemID, count = item.count,
        bid = tonumber(bid), buyout = tonumber(buyout), runTime = tonumber(runTime), queuedAt = now(),
    }
end

local function confirmPost(auctionID)
    while queue[1] and now() - (queue[1].queuedAt or 0) > 120 do table.remove(queue, 1) end
    local row = table.remove(queue, 1)
    if not row then return end
    row.queuedAt = nil
    row.auctionID = auctionID
    S:Add(row)
end

local function onLegacyCancel(index)
    if type(GetAuctionItemInfo) ~= "function" then return end
    local name, _, count, _, _, _, _, minBid, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo("owner", index)
    if not name then return end
    S:Add({ kind = "cancelled", name = name, count = count, itemID = itemID,
        bid = tonumber(minBid), buyout = tonumber(buyout) })
end

local function locationItem(location)
    local link, name, itemID
    if C_Item and C_Item.GetItemLink then
        local ok, value = pcall(C_Item.GetItemLink, location)
        if ok then link = value end
    end
    if C_Item and C_Item.GetItemName then
        local ok, value = pcall(C_Item.GetItemName, location)
        if ok then name = value end
    end
    if C_Item and C_Item.GetItemID then
        local ok, value = pcall(C_Item.GetItemID, location)
        if ok then itemID = value end
    end
    return name, itemID or itemIDFromLink(link)
end

local function onModernPostItem(location, duration, quantity, bid, buyout)
    local name, itemID = locationItem(location)
    queue[#queue + 1] = { kind = "post", name = name, itemID = itemID, count = tonumber(quantity),
        bid = tonumber(bid), buyout = tonumber(buyout), runTime = tonumber(duration), queuedAt = now() }
end

local function onModernPostCommodity(location, duration, quantity, unitPrice)
    local name, itemID = locationItem(location)
    local unit = tonumber(unitPrice)
    local count = tonumber(quantity)
    queue[#queue + 1] = { kind = "post", name = name, itemID = itemID, count = count,
        unitPrice = unit, buyout = unit and count and unit * count or nil,
        runTime = tonumber(duration), commodity = true, queuedAt = now() }
end

local function onModernCancel(auctionID)
    S:Add({ kind = "cancelled", auctionID = tonumber(auctionID) })
end

function S:ScanOwned()
    if not (self:Enabled() and C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetOwnedAuctionInfo) then return end
    local sold = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
    for index = 1, C_AuctionHouse.GetNumOwnedAuctions() or 0 do
        local info = C_AuctionHouse.GetOwnedAuctionInfo(index)
        local id = info and info.auctionID
        if id then
            local state = info.status == sold and "sold" or "active"
            if ownedSeen[id] ~= state then
                ownedSeen[id] = state
                self:Add({ kind = "owned", auctionID = id, status = state,
                    itemID = info.itemKey and info.itemKey.itemID or itemIDFromLink(info.itemLink),
                    count = info.quantity, bid = info.bidAmount, buyout = info.buyoutAmount,
                    timeLeftSeconds = info.timeLeftSeconds, timeLeft = info.timeLeft })
            end
        end
    end
end

local function knownMail(entry, base, expires)
    for _, seen in ipairs(mailSeen[base] or {}) do
        if math.abs(seen - expires) <= MAIL_MATCH_SECONDS then return true end
    end
    for _, row in pairs(entry.rows) do
        if row.kind == "mail" and row.base == base and math.abs((row.expires or 0) - expires) <= MAIL_MATCH_SECONDS then
            mailSeen[base] = mailSeen[base] or {}
            table.insert(mailSeen[base], row.expires)
            return true
        end
    end
    return false
end

function S:ScanMail()
    if not self:Enabled() or type(GetInboxNumItems) ~= "function" or type(GetInboxInvoiceInfo) ~= "function" then return end
    local entry = self:Log()
    if not entry then return end
    local hour, minute = gameClock()
    for index = 1, (GetInboxNumItems()) or 0 do
        local invoiceType, itemName, _, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count =
            GetInboxInvoiceInfo(index)
        if invoiceType and itemName then
            local daysLeft = select(7, GetInboxHeaderInfo(index))
            local t = now()
            local expires = daysLeft and math.floor(t + daysLeft * 86400) or nil
            local base = table.concat({ invoiceType, itemName, tostring(count), tostring(bid), tostring(buyout),
                tostring(deposit), tostring(consignment) }, "|")
            if expires and not knownMail(entry, base, expires) then
                mailSeen[base] = mailSeen[base] or {}
                table.insert(mailSeen[base], expires)
                self:Add({ kind = "mail", base = base, invoiceType = invoiceType, name = itemName,
                    count = tonumber(count), bid = tonumber(bid), buyout = tonumber(buyout),
                    deposit = tonumber(deposit), consignment = tonumber(consignment),
                    moneyDelay = tonumber(moneyDelay), etaHour = tonumber(etaHour), etaMin = tonumber(etaMin),
                    daysLeft = daysLeft, expires = expires, gameHour = hour, gameMinute = minute, t = t })
            end
        end
    end
end

local function onSystem(message)
    if type(message) ~= "string" then return end
    if message == ERR_AUCTION_STARTED and not modern() then
        confirmPost()
        return
    end
    local name = SOLD and message:match(SOLD)
    if name then
        S:Add({ kind = "sold", name = name })
        return
    end
    name = EXPIRED and message:match(EXPIRED)
    if name then
        S:Add({ kind = "expired", name = name })
    end
end

local function hook()
    if modern() then
        if C_AuctionHouse.PostItem then hooksecurefunc(C_AuctionHouse, "PostItem", onModernPostItem) end
        if C_AuctionHouse.PostCommodity then hooksecurefunc(C_AuctionHouse, "PostCommodity", onModernPostCommodity) end
        if C_AuctionHouse.CancelAuction then hooksecurefunc(C_AuctionHouse, "CancelAuction", onModernCancel) end
    else
        if type(PostAuction) == "function" then hooksecurefunc("PostAuction", onLegacyPost)
        elseif type(StartAuction) == "function" then hooksecurefunc("StartAuction", onLegacyStart) end
        if type(CancelAuction) == "function" then hooksecurefunc("CancelAuction", onLegacyCancel) end
    end
end

local function register(name)
    pcall(events.RegisterEvent, events, name)
end

function S:Init()
    self:Log()
    self:Prune()
    if self.hooked then return end
    self.hooked = true
    hook()
    register("CHAT_MSG_SYSTEM")
    register("MAIL_INBOX_UPDATE")
    register("AUCTION_HOUSE_CLOSED")
    if modern() then
        register("AUCTION_HOUSE_AUCTION_CREATED")
        register("OWNED_AUCTIONS_UPDATED")
    else
        register("NEW_AUCTION_UPDATE")
        register("UI_ERROR_MESSAGE")
    end
end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "CHAT_MSG_SYSTEM" then
        onSystem(arg1)
    elseif event == "MAIL_INBOX_UPDATE" then
        S:ScanMail()
    elseif event == "NEW_AUCTION_UPDATE" then
        lastSell = sellItem() or lastSell
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        confirmPost(tonumber(arg1))
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        S:ScanOwned()
    elseif event == "UI_ERROR_MESSAGE" and arg2 == ERR_AUCTION_DATABASE_ERROR then
        table.remove(queue, 1)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        queue = {}
        lastSell = nil
    end
end)
