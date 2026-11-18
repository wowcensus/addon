local WC = WoWCensus
local frame = CreateFrame("Frame")
local history, queued, pending, lastLevelUp

local function now()
    return GetServerTime and GetServerTime() or time()
end

local function requestPlayed()
    if pending or not queued then return end
    local record = queued
    queued = nil
    if UnitLevel("player") ~= record.level or not RequestTimePlayed then return end

    pending = record
    if not pcall(RequestTimePlayed) then
        pending = nil
        return
    end
    C_Timer.After(10, function()
        if pending ~= record then return end
        pending = nil
        requestPlayed()
    end)
end

local function recordLevel(level, reason)
    if not history or type(level) ~= "number" or level < 1 then return end
    if reason == "level-up" then
        if lastLevelUp == level then return end
        lastLevelUp = level
    end

    local record = { level = level, observedAt = now(), reason = reason }
    history[#history + 1] = record
    queued = record
    -- Let the client update UnitLevel before requesting its counters.
    C_Timer.After(0, requestPlayed)
end

function WC:InitLeveling()
    local guid = UnitGUID("player")
    if not guid then return end

    local db = WC.db
    db.leveling = db.leveling or {}
    local identity = WC:RealmIdentity()
    local key = identity.game .. ":" .. guid
    local character = db.leveling[key] or { guid = guid, observations = {} }
    db.leveling[key] = character
    character.identity = identity
    history = character.observations

    local level = UnitLevel("player")
    local last = history[#history]
    if not last or last.level ~= level or not last.playedAt then
        recordLevel(level, "login")
    end
end

frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("TIME_PLAYED_MSG")
-- Some clients expose both events. The real flag excludes level scaling.
pcall(frame.RegisterEvent, frame, "PLAYER_LEVEL_CHANGED")
frame:SetScript("OnEvent", function(_, event, first, second, real)
    if event == "PLAYER_LEVEL_UP" then
        recordLevel(first, "level-up")
    elseif event == "PLAYER_LEVEL_CHANGED" then
        if real then
            if second > first then
                recordLevel(second, "level-up")
            else
                lastLevelUp = nil
            end
        end
    elseif pending then
        local record = pending
        pending = nil
        if UnitLevel("player") == record.level and type(first) == "number"
            and type(second) == "number" and second >= 0 and first >= second then
            record.totalPlayedSeconds = first
            record.levelPlayedSeconds = second
            record.playedAt = now()
        end
        C_Timer.After(0, requestPlayed)
    end
end)
