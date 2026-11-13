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

function WC:RealmKey()
    return self:Region() .. ":" .. self:GameFlavor() .. ":" .. (GetRealmName() or "UnknownRealm") .. "-" .. (UnitFactionGroup("player") or "Neutral")
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
    return {
        game = self:GameFlavor(), region = self:Region(),
        regionID = GetCurrentRegion and GetCurrentRegion() or nil,
        realmID = GetRealmID and GetRealmID() or nil,
        realmName = GetRealmName and GetRealmName() or nil,
        realmNormalized = GetNormalizedRealmName and GetNormalizedRealmName() or nil,
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
        censusFixed = false, debug = false,
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
    self.db.realms[key] = self.db.realms[key] or {}
    self.realm = self.db.realms[key]
    self.realm.identity = self:RealmIdentity()
    self.Population:Store()
    if self.Population.RepairForeverKeys then self.Population:RepairForeverKeys() end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_LOGOUT")
boot:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" and addon == ADDON then
        WC:InitDB()
        WC:Fire("DB_READY")
    elseif event == "PLAYER_LOGIN" then
        WC:InitDB()
        WC.Population:Init()
        WC.Population.Passive:Init()
        WC.UI:Init()
        WC:Print("Loaded. /wc opens the window.")
    elseif event == "PLAYER_LOGOUT" and WC.db then
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
