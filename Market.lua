local WC = WoWCensus
local M = {}
WC.Market = M

local RETENTION_DAYS = 90
local STORE_VERSION = 3
local JOURNALATOR_SECTIONS = {
    "Posting", "Invoices", "Failures", "Vendoring", "VendorRepairs", "Questing", "LootContainers",
    "Taxis", "TrainingCosts", "Trades", "BasicMailSent", "BasicMailReceived", "Fulfilling",
    "CraftingOrdersPlaced", "CraftingOrdersFailed", "CraftingOrdersSucceeded",
    "TradingPostVendoring", "WoWTokens", "MissionTables",
}
local PRIVATE = {
    playerName = true, player = true, recipient = true, sender = true, subject = true, text = true,
    crafterName = true, crafterNote = true, customerNote = true,
}
local TSM_KINDS = { Sales = "sale", Buys = "buy", Expired = "expired", Cancelled = "cancelled" }

local function cleanItem(link)
    if type(link) ~= "string" then return nil, nil end
    local itemString = link:match("(item:[^|]*)")
    if not itemString then return nil, nil end
    itemString = itemString:gsub("Player%-%d+%-%x+", ""):gsub(":+$", "")
    return itemString, tonumber(itemString:match("^item:(%d+)"))
end

local function occurrence(seen, key)
    local n = (seen[key] or 0) + 1
    seen[key] = n
    return n == 1 and key or (key .. "#" .. n)
end

local function hash(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function serialize(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function copyValue(v, depth)
    if type(v) ~= "table" then return v end
    if depth > 6 then return nil end
    local out = {}
    for k, x in pairs(v) do
        if PRIVATE[k] then
        elseif type(k) == "string" and type(x) == "string" and k:match("Link$") then
            local itemString, itemID = cleanItem(x)
            local prefix = k:gsub("Link$", "")
            out[prefix .. "String"] = itemString
            out[prefix .. "ID"] = itemID
        elseif k == "guid" and type(x) == "string" and x:match("^Player%-") then
        else
            out[k] = copyValue(x, depth + 1)
        end
    end
    return out
end

local function journalatorReady()
    local J = _G.Journalator
    return type(J) == "table" and type(J.Archiving) == "table" and type(J.Archiving.GetRange) == "function"
        and type(J.State) == "table" and J.State.Archive ~= nil and type(_G.JOURNALATOR_ARCHIVE_TIMES) == "table"
end

function M:Sources()
    local found = {}
    local J = _G.Journalator
    if journalatorReady() or (type(J) == "table" and type(J.State) == "table" and type(J.State.Logs) == "table") then
        found[#found + 1] = "Journalator"
    end
    if type(_G.TradeSkillMasterDB) == "table" then found[#found + 1] = "TradeSkillMaster" end
    if type(_G.AUCTIONATOR_POSTING_HISTORY) == "table" then found[#found + 1] = "Auctionator" end
    if type(_G.ForeverDungeonJournalDB) == "table" or type(_G.ForeverDungeonJournalCharacterDB) == "table" then
        found[#found + 1] = "Dungeon Journal"
    end
    return found
end

function M:Enabled()
    return WC.db and WC.db.settings and WC.db.settings.marketCollect and true or false
end

function M:Store()
    local db = WC.db
    db.market = db.market or {}
    local m = db.market
    if m.version ~= STORE_VERSION then
        m.journalator, m.tsm, m.auctionator, m.cursor = nil, nil, nil, nil
        m.version = STORE_VERSION
    end
    m.game = WC:GameFlavor()
    m.region = WC:Region()
    m.journalator = m.journalator or {}
    for _, section in ipairs(JOURNALATOR_SECTIONS) do
        m.journalator[section] = m.journalator[section] or {}
    end
    m.tsm = m.tsm or {}
    m.auctionator = m.auctionator or {}
    m.cursor = m.cursor or {}
    return m
end

function M:Count()
    local m = WC.db and WC.db.market
    if not m then return 0 end
    local n = 0
    for _, rows in pairs(m.journalator or {}) do
        for _ in pairs(rows) do n = n + 1 end
    end
    for _ in pairs(m.tsm or {}) do n = n + 1 end
    for _ in pairs(m.auctionator or {}) do n = n + 1 end
    local dj = m.dungeonJournal
    if dj then
        if dj.account then n = n + 1 end
        for _ in pairs(dj.characters or {}) do n = n + 1 end
    end
    return n
end

local function journalatorRow(section, e)
    local row = copyValue(e, 0)
    local source = type(e.source) == "table" and e.source or {}
    row.source = nil
    row.char, row.realm, row.faction = source.character, source.realm, source.faction
    row.t, row.time = tonumber(e.time), nil
    local key = table.concat({ section, tostring(row.t), tostring(row.char), hash(serialize(row)) }, "|")
    return key, row
end

function M:CollectJournalator(m, cutoff)
    local J = _G.Journalator
    if type(J) ~= "table" or type(J.State) ~= "table" then return 0 end
    local live = type(J.State.Logs) == "table" and J.State.Logs or nil
    local canRange = journalatorReady()
    if not canRange and not live then return 0 end
    local since = math.max(cutoff, (m.cursor.journalator or 0) - 86400)
    local added, newest = 0, m.cursor.journalator or 0
    for _, section in ipairs(JOURNALATOR_SECTIONS) do
        m.journalator[section] = m.journalator[section] or {}
        local rows, seen, visited = m.journalator[section], {}, {}
        local function take(entries)
            if type(entries) ~= "table" then return end
            for _, e in ipairs(entries) do
                local t = type(e) == "table" and not visited[e] and tonumber(e.time)
                if t and t >= cutoff then
                    visited[e] = true
                    local key, row = journalatorRow(section, e)
                    key = occurrence(seen, key)
                    if not rows[key] then
                        rows[key] = row
                        added = added + 1
                    end
                    if t > newest then newest = t end
                end
            end
        end
        if canRange then
            local ok, entries = pcall(J.Archiving.GetRange, since, section)
            if ok then take(entries) end
        end
        if live then take(live[section]) end
    end
    m.cursor.journalator = newest
    return added
end

local function splitCSV(line)
    local out = {}
    for field in (line .. ","):gmatch("([^,]*),") do out[#out + 1] = field end
    return out
end

function M:CollectTSM(m, cutoff)
    local db = _G.TradeSkillMasterDB
    if type(db) ~= "table" then return 0 end
    local added = 0
    for key, value in pairs(db) do
        local realm, kind
        if type(key) == "string" then realm, kind = key:match("^r@(.-)@internalData@csv(%a+)$") end
        local label = kind and TSM_KINDS[kind]
        if label and type(value) == "string" then
            local header, seen = nil, {}
            for line in value:gmatch("[^\n]+") do
                if not header then
                    header = splitCSV(line)
                else
                    local fields, rec = splitCSV(line), {}
                    for i, name in ipairs(header) do rec[name] = fields[i] end
                    local t = tonumber(rec.time)
                    if t and t >= cutoff then
                        local rowKey = occurrence(seen, table.concat({ label, realm, tostring(rec.itemString),
                            tostring(rec.stackSize), tostring(rec.quantity), tostring(rec.price),
                            tostring(rec.player), tostring(rec.time), tostring(rec.source) }, "|"))
                        if not m.tsm[rowKey] then
                            m.tsm[rowKey] = {
                                kind = label, realm = realm, t = t, item = rec.itemString,
                                itemID = tonumber((rec.itemString or ""):match("^i:(%d+)")),
                                stack = tonumber(rec.stackSize), qty = tonumber(rec.quantity),
                                price = tonumber(rec.price), char = rec.player, source = rec.source,
                            }
                            added = added + 1
                        end
                    end
                end
            end
        end
    end
    return added
end

function M:CollectAuctionator(m, cutoff)
    local history = _G.AUCTIONATOR_POSTING_HISTORY
    if type(history) ~= "table" then return 0 end
    local added, seen = 0, {}
    for dbKey, posts in pairs(history) do
        if type(posts) == "table" and dbKey ~= "__dbversion" then
            for _, p in ipairs(posts) do
                local t = type(p) == "table" and tonumber(p.time)
                if t and t >= cutoff then
                    local key = occurrence(seen, table.concat({ tostring(dbKey), t, tostring(p.price), tostring(p.quantity) }, "|"))
                    if not m.auctionator[key] then
                        m.auctionator[key] = { key = tostring(dbKey), t = t, price = tonumber(p.price),
                            qty = tonumber(p.quantity), bid = tonumber(p.bidPrice) }
                        added = added + 1
                    end
                end
            end
        end
    end
    return added
end

local function snapshot(v, depth, seen)
    local kind = type(v)
    if kind == "string" or kind == "number" or kind == "boolean" then return v end
    if kind ~= "table" or depth > 16 or seen[v] then return nil end
    seen[v] = true
    local out = {}
    for k, x in pairs(v) do
        local kk = type(k)
        if kk == "string" or kk == "number" then out[k] = snapshot(x, depth + 1, seen) end
    end
    seen[v] = nil
    return out
end

function M:CollectDungeonJournal(m)
    local account, character = _G.ForeverDungeonJournalDB, _G.ForeverDungeonJournalCharacterDB
    if type(account) ~= "table" and type(character) ~= "table" then return 0 end
    m.dungeonJournal = m.dungeonJournal or {}
    local dj = m.dungeonJournal
    dj.characters = dj.characters or {}
    local copied = 0
    if type(account) == "table" then
        dj.account = snapshot(account, 0, {})
        dj.accountAt = time()
        copied = copied + 1
    end
    if type(character) == "table" then
        local name = UnitName and UnitName("player") or "Unknown"
        local realm = GetRealmName and GetRealmName() or "Unknown"
        dj.characters[name .. "-" .. realm] = {
            t = time(), char = name, realm = realm,
            faction = UnitFactionGroup and UnitFactionGroup("player") or nil,
            data = snapshot(character, 0, {}),
        }
        copied = copied + 1
    end
    return copied
end

function M:Prune(m, cutoff)
    local function sweep(rows)
        for key, row in pairs(rows) do
            if (row.t or 0) < cutoff then rows[key] = nil end
        end
    end
    for _, rows in pairs(m.journalator) do sweep(rows) end
    sweep(m.tsm)
    sweep(m.auctionator)
end

function M:Collect(reason, quiet)
    if not self:Enabled() or #self:Sources() == 0 then return 0 end
    local m = self:Store()
    local cutoff = time() - RETENTION_DAYS * 86400
    local added = 0
    for _, step in ipairs({ "CollectJournalator", "CollectTSM", "CollectAuctionator" }) do
        local ok, n = pcall(self[step], self, m, cutoff)
        if ok then
            added = added + (n or 0)
        else
            WC:Debug("Market %s: %s", step, tostring(n))
        end
    end
    local okDJ, djErr = pcall(self.CollectDungeonJournal, self, m)
    if not okDJ then WC:Debug("Market CollectDungeonJournal: %s", tostring(djErr)) end
    self:Prune(m, cutoff)
    m.collectedAt = time()
    if not quiet and added > 0 then
        WC:Print("Copied %d new record(s) from your other addons.", added)
    end
    WC:Fire("MARKET_CHANGED")
    return added
end

function M:SetEnabled(on)
    WC.db.settings.marketCollect = on and true or false
    if on then
        local found = self:Sources()
        if #found == 0 then
            WC:Print("Addon data collection on. Your own auction listings, sales and auction mail are now recorded. Journalator, TradeSkillMaster, Auctionator and Dungeon Journal are not loaded, so there is nothing to copy from them.")
        else
            WC:Print("Addon data collection on. Recording your own auctions and copying from %s.", table.concat(found, ", "))
            self:Collect("toggle")
        end
    else
        WC:Print("Addon data collection off. Already-copied records stay until the next upload.")
    end
    WC:Fire("MARKET_CHANGED")
end

local boot = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "MAIL_CLOSED", "AUCTION_HOUSE_CLOSED", "PLAYER_LOGOUT" }) do
    pcall(boot.RegisterEvent, boot, event)
end
boot:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        if C_Timer and C_Timer.After then
            C_Timer.After(10, function() M:Collect("login") end)
        else
            M:Collect("login")
        end
    elseif event == "PLAYER_LOGOUT" then
        M:Collect("logout", true)
    else
        M:Collect(event, true)
    end
end)
