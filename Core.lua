local ADDON = ...
WoWCensus = WoWCensus or {}
local WC = WoWCensus
WC.ADDON = ADDON
WC.Population = WC.Population or {}
WC.Util = WC.Util or {}
WC.Data = WC.Data or {}
WC.UI = WC.UI or {}
WC.callbacks = {}

BINDING_HEADER_WOWCENSUS = "WoWCensus"
BINDING_NAME_WOWCENSUS_TOGGLE = "Toggle window"
BINDING_NAME_WOWCENSUS_NEXT = "Run next census query"

function WC:On(event, callback)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], callback)
end

function WC:Fire(event, ...)
    for _, callback in ipairs(self.callbacks[event] or {}) do
        local ok, err = pcall(callback, ...)
        if not ok then self:Debug("%s callback: %s", event, tostring(err)) end
    end
end

function WC:Print(format, ...)
    local message = select("#", ...) > 0 and string.format(format, ...) or format
    DEFAULT_CHAT_FRAME:AddMessage("|cff38bdf8WoWCensus|r: " .. message)
end

function WC:Debug(format, ...)
    if self.db and self.db.settings and self.db.settings.debug then
        self:Print("[debug] " .. format, ...)
    end
end

function WC:CensusPrint(format, ...) self:Debug(format, ...) end

local function present(value)
    return type(value) == "string" and value ~= "" and value or nil
end

local function playerServerID()
    local guid = UnitGUID and UnitGUID("player")
    return guid and tonumber(guid:match("^Player%-(%d+)%-")) or nil
end

local function savedRealm(identity, id, game, region)
    if type(identity) ~= "table" or identity.realmID ~= id or not present(identity.realmName) then return nil end
    if identity.game ~= game or identity.region ~= region then return nil end
    return identity
end

function WC:RealmName()
    local name = present(GetRealmName and GetRealmName())
    local id = GetRealmID and GetRealmID() or nil
    if name then return name, id, present(GetNormalizedRealmName and GetNormalizedRealmName()) end
    local server = playerServerID()
    if not server or not self.db then return nil end
    local game, region = self:GameFlavor(), self:Region()
    for _, source in ipairs({ self.db.realms or {}, self.db.leveling or {} }) do
        for _, entry in pairs(source) do
            local identity = savedRealm(type(entry) == "table" and entry.identity, server, game, region)
            if identity then return identity.realmName, server, identity.realmNormalized end
        end
    end
    return nil
end

function WC:RealmKey()
    local name = self:RealmName()
    if not name then return nil end
    return self:Region() .. ":" .. self:GameFlavor() .. ":" .. name .. "-" .. (UnitFactionGroup("player") or "Neutral")
end

function WC:Region()
    local portal = GetCVar and tostring(GetCVar("portal") or ""):upper() or ""

    local byPortal = { US = "us", EU = "eu", TW = "tw", CN = "cn" }
    if byPortal[portal] then return byPortal[portal] end
    local id = GetCurrentRegion and GetCurrentRegion()

    local byID = { [1] = "us", [3] = "eu", [4] = "tw", [5] = "cn" }
    local region = self:GameFlavor() == "retail" and byID[id] or nil
    if region then return region end
    if self.db and self.db.settings and self.db.settings.regionOverride then
        return self.db.settings.regionOverride
    end
    return "unknown"
end

function WC:RealmIdentity()
    local name, id, normalized = self:RealmName()
    return {
        game = self:GameFlavor(), region = self:Region(),
        regionID = GetCurrentRegion and GetCurrentRegion() or nil,
        realmID = name and id or nil,
        realmName = name,
        realmNormalized = normalized,
        faction = UnitFactionGroup and UnitFactionGroup("player") or nil,
    }
end

function WC:IsForeverBeta()
    local build = select(4, GetBuildInfo()) or 0
    return build >= 16000 and build < 20000
end

function WC:GameFlavor()
    if self:IsForeverBeta() then return "forever" end
    if WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then return "retail" end
    if WOW_PROJECT_ID and WOW_PROJECT_MISTS_CLASSIC and WOW_PROJECT_ID == WOW_PROJECT_MISTS_CLASSIC then return "mop-classic" end
    if WOW_PROJECT_ID and WOW_PROJECT_CLASSIC and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
        local season
        if C_Seasons and C_Seasons.GetActiveSeason then
            local ok, value = pcall(C_Seasons.GetActiveSeason)
            if ok then season = value end
        end
        local sod = Enum and Enum.SeasonID and Enum.SeasonID.SeasonOfDiscovery or 2
        if season == sod then return "sod" end
        local hardcore = false
        if C_GameRules and C_GameRules.IsHardcoreActive then
            local ok, value = pcall(C_GameRules.IsHardcoreActive)
            hardcore = ok and value
        end
        local hcSeason = Enum and Enum.SeasonID and Enum.SeasonID.Hardcore or 3
        if hardcore or season == hcSeason then return "hardcore" end
        return "classic-era"
    end
    return "tbc-anniversary"
end

function WC:InitDB()
    WoWCensusDB = type(WoWCensusDB) == "table" and WoWCensusDB or {}
    self.db = WoWCensusDB
    self.db.realms = self.db.realms or {}
    self.db.settings = self.db.settings or {}
    local defaults = {
        populationRetentionDays = 35,
        censusFixed = false, debug = false, channelRosterEnabled = true,
    }
    for key, value in pairs(defaults) do
        if self.db.settings[key] == nil then self.db.settings[key] = value end
    end

    if self.db.settings.censusAutoStartConfigured == nil then
        self.db.settings.censusAutoStart = true
        self.db.settings.censusAutoStartConfigured = true
    end

    if self.db.settings.censusPassiveConfigured == nil then
        self.db.settings.censusPassive = true
        self.db.settings.censusPassiveConfigured = true
    end
    local key = self:RealmKey()
    if key then
        if self.realmPending and not self.db.realms[key] then self.db.realms[key] = self.realmPending end
        self.realmPending, self.realmFallback = nil, nil
        self.db.realms[key] = self.db.realms[key] or {}
        self.realm = self.db.realms[key]
    else
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        if faction then
            key = self:Region() .. ":" .. self:GameFlavor() .. ":-" .. faction
            self.db.realms[key] = self.db.realms[key] or self.realmPending or {}
            self.realmPending, self.realmFallback = nil, key
            self.realm = self.db.realms[key]
        else
            self.realmPending = self.realmPending or {}
            self.realm = self.realmPending
        end
    end
    self.realm.identity = self:RealmIdentity()
    self.Population:Store()
    if self.Population.RepairForeverKeys then self.Population:RepairForeverKeys() end
end

function WC:RefreshRealm()
    if not self.db or not self:RealmName() then return end
    if self.realmPending or self.realmFallback then self:InitDB() end
    local identity = self:RealmIdentity()
    local guid = UnitGUID and UnitGUID("player")
    local character = guid and self.db.leveling and self.db.leveling[identity.game .. ":" .. guid]
    if type(character) == "table" and not (type(character.identity) == "table" and present(character.identity.realmName)) then
        character.identity = identity
    end
    if self.Sales and self.Sales.Refresh then self.Sales:Refresh() end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_LOGOUT")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(_, event, addon)
    if event == "PLAYER_ENTERING_WORLD" then
        WC:RefreshRealm()
    elseif event == "ADDON_LOADED" and addon == ADDON then
        WC:InitDB()
        WC:Fire("DB_READY")
    elseif event == "PLAYER_LOGIN" then
        WC:InitDB()
        WC:InitLeveling()
        WC.Population:Init()
        WC.Population.Passive:Init()
        WC.Population.ChannelRoster:Init()
        WC.Auction:Init()
        WC.Sales:Init()
        WC.UI:Init()
        WC:Print("Loaded. /wc opens the window.")
    elseif event == "PLAYER_LOGOUT" and WC.db then
        WC:RefreshRealm()
        if WC.Population.PackStorage then WC.Population:PackStorage() end
    end
end)

SLASH_WOWCENSUS1 = "/wowcensus"
SLASH_WOWCENSUS2 = "/wc"
SlashCmdList.WOWCENSUS = function(input)
    local command = (input or ""):lower():match("^%s*(.-)%s*$")
    local census = WC.Population.Census
    if command == "start" then census:Start()
    elseif command == "next" then census:RunNext(false, "slash")
    elseif command == "stop" then census:Stop()
    elseif command == "status" then census:Status()
    elseif command == "diag" then WC.Population:PrintWhoDiagnostics()
    elseif command == "roster" then WC.Population.ChannelRoster:Scan(true)
    elseif command == "roster all" then WC.Population.ChannelRoster:ScanAll()
    elseif command == "roster on" or command == "roster off" then
        WC.Population.ChannelRoster:SetEnabled(command == "roster on")
    elseif command:match("^who%s+") then
        local filter = (input or ""):match("^%s*%S+%s+(.+)%s*$")
        if filter and not census:TryChatQuery(filter) then WC.Population:Scan(filter) end
    elseif command == "passive on" or command == "passive off" then
        WC.db.settings.censusPassive = command == "passive on"
        WC.db.settings.censusPassiveConfigured = true
        WC:Print("Passive census %s.", WC.db.settings.censusPassive and "on" or "off")
        WC.UI:Refresh()
    elseif command == "auto on" or command == "auto off" then
        WC.db.settings.censusAutoStart = command == "auto on"
        WC.db.settings.censusAutoStartConfigured = true
        WC:Print("Start at login %s.", WC.db.settings.censusAutoStart and "on" or "off")
    elseif command == "market on" or command == "market off" then
        WC.Market:SetEnabled(command == "market on")
    elseif command == "auction" or command == "ah" then
        WC.Auction:Start()
    elseif command == "minimap" then
        local shown = WC.db.minimap and WC.db.minimap.hide
        WC:SetMinimapShown(shown and true or false)
        WC:Print("Minimap button %s.", (WC.db.minimap and WC.db.minimap.hide) and "hidden" or "shown")
    elseif command == "debug" then
        WC.db.settings.debug = not WC.db.settings.debug
        WC:Print("Debug %s.", WC.db.settings.debug and "on" or "off")
    elseif command:match("^region%s+") then
        local region = command:match("^region%s+(%a+)$")
        if region and ({ us = true, eu = true, kr = true, tw = true, cn = true })[region] then
            WC.db.settings.regionOverride = region
            WC:InitDB()
            WC:Print("Collection region: %s", region:upper())
            if WC.db.settings.censusAutoStart and not census:IsActive() then census:Start() end
        else WC:Print("Use /wc region us|eu|kr|tw|cn") end
    elseif command == "region" then
        WC:Print("Collection region: %s (client ID %s)", WC:Region(), tostring(GetCurrentRegion and GetCurrentRegion() or "unknown"))
    else WC.UI:Toggle() end
end
