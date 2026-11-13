local ML = WoWCensus
local Pop = ML.Population
local U = ML.Util
local D = ML.Data

local COOLDOWN = 12
local ANSWER_TIMEOUT = 25
local WHO_EVENT_CAP = 80
local SCAN_CAP = 1000

Pop.pending = false
Pop.lastSend = nil
Pop.COOLDOWN = COOLDOWN
Pop.ANSWER_TIMEOUT = ANSWER_TIMEOUT
Pop.lastAnswer = nil

function Pop:TraceWho(event, fields)
    local store = self:Store()
    store.whoEvents = store.whoEvents or {}
    local entry = fields or {}
    entry.event = event
    entry.t = time()
    entry.region = ML:Region()
    entry.game = ML:GameFlavor()
    entry.realm = GetRealmName and GetRealmName() or ""
    local events = store.whoEvents
    events[#events + 1] = entry
    while #events > WHO_EVENT_CAP do table.remove(events, 1) end
end

function Pop:PrintWhoDiagnostics()
    local events = self:Store().whoEvents or {}
    ML:Print("Recent /who events (%d saved):", #events)
    for i = math.max(1, #events - 7), #events do
        local e = events[i]
        ML:Print("%s %s %s gap=%s response=%s count=%s",
            tostring(e.t or "?"), tostring(e.event or "?"), tostring(e.filter or ""),
            tostring(e.gapMs or "-"), tostring(e.elapsedMs or "-"), tostring(e.shown or "-"))
    end
end

local eventFrame
local silencedWhoFrames = {}
local whoSilenceGeneration = 0

local function frameListening(frame)
    if type(frame) ~= "table" or type(frame.IsEventRegistered) ~= "function" then return nil end
    local ok, listening = pcall(frame.IsEventRegistered, frame, "WHO_LIST_UPDATE")
    return ok and listening or nil
end

local function silenceWhoWindow()
    whoSilenceGeneration = whoSilenceGeneration + 1
    local found = {}
    if type(GetFramesRegisteredForEvent) == "function" then
        local frames = { GetFramesRegisteredForEvent("WHO_LIST_UPDATE") }
        for _, frame in ipairs(frames) do found[#found + 1] = frame end
    else
        for _, name in ipairs({ "LFGWhoListFrame", "FriendsFrame", "WhoFrame" }) do
            local frame = _G[name]
            if frame and frameListening(frame) ~= false then found[#found + 1] = frame end
        end
    end
    for _, frame in ipairs(found) do
        if frame ~= eventFrame and type(frame.UnregisterEvent) == "function"
            and frameListening(frame) ~= false then
            local ok = pcall(frame.UnregisterEvent, frame, "WHO_LIST_UPDATE")
            if ok and not silencedWhoFrames[frame] then silencedWhoFrames[frame] = true end
        end
    end
    return whoSilenceGeneration
end

local function restoreWhoWindow(generation)
    if generation and generation ~= whoSilenceGeneration then return end
    for frame in pairs(silencedWhoFrames) do
        if type(frame.RegisterEvent) == "function" and frameListening(frame) ~= true then
            pcall(frame.RegisterEvent, frame, "WHO_LIST_UPDATE")
        end
        silencedWhoFrames[frame] = nil
    end
end

local function sendWho(filter)
    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(filter)
    elseif SendWho then
        SendWho(filter)
    else
        error("SendWho API unavailable")
    end
end

local function setWhoToUi(on)
    if C_FriendList and C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(on)
    elseif SetWhoToUI then
        SetWhoToUI(on)
    end
end

local function numResults()
    if C_FriendList and C_FriendList.GetNumWhoResults then
        return C_FriendList.GetNumWhoResults()
    elseif GetNumWhoResults then
        return GetNumWhoResults()
    end
    return 0, 0
end

local function whoInfo(i)
    if C_FriendList and C_FriendList.GetWhoInfo then
        return C_FriendList.GetWhoInfo(i)
    elseif GetWhoInfo then

        local name, guild, level, race, class, zone, classFileName, sex = GetWhoInfo(i)
        return { fullName = name, fullGuildName = guild, level = level,
                 raceStr = race, classStr = class, area = zone,
                 filename = classFileName, gender = sex }
    end
end

local function answerFingerprint(roster, observed)
    local keys = {}
    for key in pairs(roster or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return tostring(observed or 0) .. "\n" .. table.concat(keys, "\n")
end

local function staleReason(filter, roster, observed)
    local lo, hi = tostring(filter or ""):match("(%d+)%s*%-%s*(%d+)")
    if not lo then
        local only = tostring(filter or ""):match("^%s*(%d+)%s*$")
        lo, hi = only, only
    end
    if lo then
        lo, hi = tonumber(lo), tonumber(hi)
        for _, row in pairs(roster or {}) do
            local level = tonumber(row.level)
            if level and (level < lo or level > hi) then
                return string.format("level %d is outside %d-%d", level, lo, hi)
            end
        end
    end
    local fp = answerFingerprint(roster, observed)
    local last = Pop.lastAnswer
    local disjoint = lo and last and last.lo
        and (tonumber(hi) < last.lo or tonumber(lo) > last.hi)
    if observed >= 10 and disjoint and last.filter ~= filter and last.fingerprint == fp then
        return "the client replayed the previous /who list"
    end
    Pop.lastAnswer = { filter = filter, fingerprint = fp,
        lo = tonumber(lo), hi = tonumber(hi) }
    return nil
end

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function identity(info)
    local firstName = trim(info.firstName or info.mainName)
    local lastName = trim(info.lastName or info.surname or info.secondaryName)
    local fullName = trim(info.fullName)
    if fullName == "" and firstName ~= "" then
        fullName = firstName .. (lastName ~= "" and (" " .. lastName) or "")
    end
    if fullName == "" then return nil end
    local directRealm = trim(info.realmName or info.realm or info.serverName)
    local name, realm

    local forever = Pop.Profiles and Pop.Profiles.DetectID and Pop.Profiles.DetectID() == "forever"
    if directRealm ~= "" then
        name, realm = fullName, directRealm
    elseif not forever then
        name, realm = fullName:match("^([^-]+)%-(.+)$")
    end
    name = trim(name or fullName)
    realm = trim(realm or GetRealmName() or "UnknownRealm")
    if firstName == "" then firstName, lastName = name:match("^(%S+)%s+(.+)$") end
    firstName = trim(firstName ~= "" and firstName or name)
    lastName = trim(lastName)
    if name == "" then return nil end

    local normalizedRealm = realm:lower():gsub("[%s'%-]", "")
    local key = ML:Region() .. ":" .. ML:GameFlavor() .. ":" .. normalizedRealm .. ":" .. name:lower()
    return key, name .. "-" .. realm, name, realm, firstName, lastName
end

local GEAR_BUDGET = 5

local DEFAULT_GEAR_SHARE = { Blacksmithing = 0.0390, Leatherworking = 0.0545, Tailoring = 0.0671 }

local function gearShare(profession)
    local share = D.GearCraftShare and D.GearCraftShare[profession]
    return share or DEFAULT_GEAR_SHARE[profession] or 0
end

local function gearSlot(profession)
    local share = gearShare(profession)
    return { [profession] = GEAR_BUDGET * share, Gear = GEAR_BUDGET * (1 - share) }
end

local function affinity(profession, extra)
    local aff = gearSlot(profession)
    for prof, w in pairs(extra) do aff[prof] = w end
    return aff
end

Pop.ClassAffinity = {
    WARRIOR = affinity("Blacksmithing", { Enchanting = 2, Alchemy = 1, Jewelcrafting = 1 }),
    PALADIN = affinity("Blacksmithing", { Enchanting = 2, Alchemy = 1, Jewelcrafting = 1 }),
    HUNTER  = affinity("Leatherworking", { Engineering = 1, Enchanting = 1, Alchemy = 1 }),
    ROGUE   = affinity("Leatherworking", { Alchemy = 2, Enchanting = 1 }),
    SHAMAN  = affinity("Leatherworking", { Enchanting = 1, Jewelcrafting = 1, Alchemy = 1 }),
    DRUID   = affinity("Leatherworking", { Alchemy = 1, Enchanting = 1 }),
    PRIEST  = affinity("Tailoring", { Enchanting = 2, Alchemy = 1, Jewelcrafting = 1 }),
    MAGE    = affinity("Tailoring", { Enchanting = 2, Jewelcrafting = 1, Alchemy = 1 }),
    WARLOCK = affinity("Tailoring", { Enchanting = 2, Alchemy = 1 }),

    DEATHKNIGHT = affinity("Blacksmithing", { Enchanting = 2, Alchemy = 1, Jewelcrafting = 1 }),
    MONK        = affinity("Leatherworking", { Alchemy = 1, Enchanting = 1, Jewelcrafting = 1 }),
    DEMONHUNTER = affinity("Leatherworking", { Alchemy = 2, Enchanting = 1 }),
    EVOKER      = affinity("Leatherworking", { Enchanting = 2, Alchemy = 1, Jewelcrafting = 1 }),
}

function Pop:ProfessionDemand(agg)
    if not agg or not agg.classes then return {} end
    local weights = {}
    for token, n in pairs(agg.classes) do
        local aff = self.ClassAffinity[token]
        if aff then
            for prof, w in pairs(aff) do
                weights[prof] = (weights[prof] or 0) + w * n
            end
        end
    end

    local max = 0
    for _, w in pairs(weights) do if w > max then max = w end end

    local out = {}
    for prof, w in pairs(weights) do
        out[#out + 1] = {
            prof   = prof,
            weight = w,
            score  = max > 0 and U.Round(w / max * 100) or 0,
        }
    end
    table.sort(out, function(a, b) return a.weight > b.weight end)
    return out
end

function Pop:Scan(filter, tag)
    if ML:Region() == "unknown" then
        ML:Print("Collection region is unknown. Set it with /wc region us|eu|kr|tw|cn before scanning.")
        return false
    end
    filter = filter and filter:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if filter == "" then
        local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 70
        filter = "1-" .. maxL
    end

    local now = GetTime()

    if self.pending then
        if tag ~= "census" then ML:Print("Population scan already in progress...") end
        return false
    end
    if self.lastSend and now - self.lastSend < COOLDOWN then
        if tag ~= "census" then ML:Print("Population scans are throttled \226\128\148 wait a few seconds and retry.") end
        return false
    end

    self.pending = true
    self.pendingFilter = filter
    self.pendingTag = tag
    local store = self:Store()
    self.pendingSweepID = store.activeSweepID
    local gapMs = self.lastSend and math.floor((now - self.lastSend) * 1000 + 0.5) or nil
    local bandwidthIn, bandwidthOut, homeMs, worldMs
    if GetNetStats then bandwidthIn, bandwidthOut, homeMs, worldMs = GetNetStats() end
    self.systemMessages = 0
    store.whoDiagnostic = { filter = filter, attemptedAt = time(), status = "waiting",
        gapMs = gapMs, homeMs = homeMs, worldMs = worldMs,
        region = ML:Region(), game = ML:GameFlavor(), realm = GetRealmName() }
    self.pendingStarted = now
    self.pendingToken = (self.pendingToken or 0) + 1
    local token = self.pendingToken
    self.lastSend = now
    self:TraceWho("QUERY_ATTEMPT", { filter = filter, gapMs = gapMs,
        homeMs = homeMs, worldMs = worldMs, source = tag or "manual" })
    local silenceGeneration = silenceWhoWindow()
    setWhoToUi(true)

    if tag ~= "census" then ML:Print("Population scan: |cffffffff%s|r ...", filter) end
    ML:Fire("POP_SCAN_START", filter)
    local sent, err = pcall(sendWho, filter)
    if not sent then
        self.pending = false
        self.pendingTag, self.pendingSweepID = nil, nil
        setWhoToUi(false)
        restoreWhoWindow()
        store.whoDiagnostic.status = "send error: " .. tostring(err)
        self:TraceWho("SEND_ERROR", { filter = filter, error = tostring(err) })
        ML:Print("/who send failed: %s", tostring(err))
        ML:Fire("POP_SCAN_FAILED", filter, tag)
        return false
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if self.pending then silenceWhoWindow() end
        end)
        C_Timer.After(ANSWER_TIMEOUT, function()
            if self.pendingToken == token then
                if self.pending then self:ExpirePending() end
                restoreWhoWindow()
            end
        end)
    else

        self.whoSilenceGeneration = silenceGeneration
    end
    return true
end

function Pop:ExpirePending()
    if not self.pending then return end
    local elapsedMs = math.floor((GetTime() - (self.pendingStarted or GetTime())) * 1000 + 0.5)
    local filter = self.pendingFilter
    self.lastTimeoutFilter = filter
    local diagnostic = self:Store().whoDiagnostic
    if diagnostic and diagnostic.status == "waiting" then
        diagnostic.status = "timeout_unknown"
        diagnostic.elapsedMs = elapsedMs
    end
    self:TraceWho("TIMEOUT_UNKNOWN", { filter = filter, elapsedMs = elapsedMs })
    self.pending = false
    self.pendingTag, self.pendingSweepID = nil, nil
    setWhoToUi(false)
    restoreWhoWindow()
end

function Pop:CooldownRemaining()
    return self.lastSend and math.max(COOLDOWN - (GetTime() - self.lastSend), 0) or 0
end

function Pop:Capture()
    if not self.pending then
        self:TraceWho("WHO_LIST_UPDATE_WITHOUT_PENDING")
        return
    end
    local elapsedMs = math.floor((GetTime() - (self.pendingStarted or GetTime())) * 1000 + 0.5)
    self.pending = false
    setWhoToUi(false)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() restoreWhoWindow() end)
    else
        restoreWhoWindow(self.whoSilenceGeneration)
    end

    local shown, total = numResults()
    shown = shown or 0
    local diagnostic = self:Store().whoDiagnostic
    if diagnostic then
        diagnostic.respondedAt = time()
        diagnostic.status = "response"
        diagnostic.observed = shown
        diagnostic.elapsedMs = elapsedMs
    end
    self:TraceWho("WHO_LIST_UPDATE", { filter = self.pendingFilter,
        elapsedMs = elapsedMs, shown = shown, total = total })

    local classes, races, roster = {}, {}, {}
    local observed = 0
    for i = 1, shown do
        local info = whoInfo(i)
        if info then
            local token = info.filename or info.classStr or "UNKNOWN"
            local race  = info.raceStr or "Unknown"
            classes[token] = (classes[token] or 0) + 1
            races[race]    = (races[race] or 0) + 1
            observed = observed + 1
            local key, fullName, name, realm, firstName, lastName = identity(info)
            if key and not roster[key] then
                roster[key] = {
                    key = key, fullName = fullName, name = name, realm = realm,
                    firstName = firstName, lastName = lastName,
                    guild = info.fullGuildName or "", level = info.level or 0,
                    race = race, class = info.classStr or token,
                    classFile = token, zone = info.area or "",
                }
            end
        end
    end

    local sample = {
        t        = time(),
        faction  = UnitFactionGroup and UnitFactionGroup("player") or "Neutral",
        filter   = self.pendingFilter,
        observed = observed,
        total    = total or observed,
        classes  = classes,
        races    = races,
    }
    local stale = staleReason(self.pendingFilter, roster, observed)
    if stale then
        if diagnostic then diagnostic.status = "stale: " .. stale end
        self:TraceWho("STALE_RESPONSE", { filter = self.pendingFilter, reason = stale, shown = shown })
        local tag = self.pendingTag
        self.pendingSweepID, self.pendingTag = nil, nil
        ML:Print("Ignored stale /who response for |cffffffff%s|r: %s.", sample.filter or "", stale)
        ML:Fire("POP_SCAN_STALE", sample.filter, tag)
        return
    end
    if self.lastTimeoutFilter == self.pendingFilter then
        self:TraceWho("RETRY_SUCCESS", { filter = self.pendingFilter, elapsedMs = elapsedMs, shown = shown })
        self.lastTimeoutFilter = nil
    end
    local unique = self:Record(sample, roster)
    self:RecordSweepQuery(sample, roster, self.pendingSweepID)
    self.pendingSweepID = nil
    local tag = self.pendingTag
    self.pendingTag = nil

    if tag ~= "census" then
        ML:Print("%s: %d result(s)%s; recorded %d unique character(s).",
            sample.filter or "", observed,
            self:IsCapped(observed) and " |cffff8040(capped \226\128\148 more exist)|r" or "", unique)
    end
    ML:Fire("POP_SCAN_COMPLETE", sample, tag)
end

function Pop:Store()
    local realm = ML.realm
    realm.population = realm.population or { samples = {}, characters = {} }
    realm.population.samples = realm.population.samples or {}
    self:UnpackCharacters(realm.population)
    realm.population.characters = realm.population.characters or {}
    realm.population.sweeps = realm.population.sweeps or {}
    return realm.population
end

local CHARACTER_FIELDS = {
    "fullName", "name", "firstName", "lastName", "realm", "guild",
    "level", "race", "class", "classFile", "zone", "firstSeen",
    "lastSeen", "seenCount",
}
local function packedField(value)
    local s = value == nil and "" or tostring(value)
    return #s .. ":" .. s
end

function Pop:PackCharacters(store)
    if not store or not store.characters then return end
    local chunks, records, count = { "MLC1" }, {}, 0
    for key, c in pairs(store.characters) do
        local fields = { packedField(key) }
        for _, name in ipairs(CHARACTER_FIELDS) do fields[#fields + 1] = packedField(c[name]) end
        local days = {}
        for day, d in pairs(c.days or {}) do
            days[#days + 1] = table.concat({ day, d.count or d[1] or 0,
                d.firstSeen or d[2] or 0, d.lastSeen or d[3] or 0 }, ",")
        end
        fields[#fields + 1] = packedField(table.concat(days, ";"))
        records[#records + 1] = table.concat(fields)
        count = count + 1
        if count == 256 then
            chunks[#chunks + 1] = table.concat(records)
            records, count = {}, 0
        end
    end
    if count > 0 then chunks[#chunks + 1] = table.concat(records) end
    store.charactersPacked = chunks
    store.characters = nil
end

function Pop:UnpackCharacters(store)
    if not store or not store.charactersPacked then return end
    local chunks = store.charactersPacked
    assert(chunks[1] == "MLC1", "Unknown packed population format")
    local characters = store.characters or {}
    for part = 2, #chunks do
        local chunk, cursor = chunks[part], 1
        local function field()
            local colon = chunk:find(":", cursor, true)
            assert(colon, "Truncated packed population field")
            local size = tonumber(chunk:sub(cursor, colon - 1))
            assert(size and size >= 0 and colon + size <= #chunk, "Invalid packed population field")
            local value = chunk:sub(colon + 1, colon + size)
            cursor = colon + size + 1
            return value
        end
        while cursor <= #chunk do
            local key = field()
            local c = { key = key, days = {} }
            for _, name in ipairs(CHARACTER_FIELDS) do c[name] = field() end
            for _, name in ipairs({ "level", "firstSeen", "lastSeen", "seenCount" }) do
                c[name] = tonumber(c[name]) or 0
            end
            local days = field()
            for token in days:gmatch("[^;]+") do
                local day, count, first, last = token:match("^(%d+),(%d+),(%d+),(%d+)$")
                assert(day, "Invalid packed population day")
                c.days[tonumber(day)] = { tonumber(count), tonumber(first), tonumber(last) }
            end
            characters[key] = c
        end
    end
    store.characters = characters
    store.charactersPacked = nil
end

function Pop:PackStorage()
    for _, realm in pairs(ML.db.realms or {}) do
        if realm.population then self:PackCharacters(realm.population) end
    end
end

function Pop:CompactStorage()
    local retention = (ML.db.settings and ML.db.settings.populationRetentionDays) or 35
    local cutoff = time() - retention * 86400
    local cutoffDay = math.floor(cutoff / 86400)
    for _, realm in pairs(ML.db.realms or {}) do
        local store = realm.population
        if store then
            self:UnpackCharacters(store)
            local kept = {}
            for _, sample in ipairs(store.samples or {}) do
                if (sample.t or 0) >= cutoff then kept[#kept + 1] = sample end
            end
            store.samples = kept
            for _, c in pairs(store.characters or {}) do
                for day, d in pairs(c.days or {}) do
                    if (tonumber(day) or 0) < cutoffDay then
                        c.days[day] = nil
                    else
                        c.days[day] = {
                            d.count or d[1] or 0,
                            d.firstSeen or d[2] or 0,
                            d.lastSeen or d[3] or 0,
                        }
                    end
                end
            end
            for id, sweep in pairs(store.sweeps or {}) do
                local ended = sweep.completedAt or sweep.startedAt or 0
                if sweep.status ~= "active" and ended < cutoff then
                    store.sweeps[id] = nil
                else
                    for _, q in ipairs(sweep.queries or {}) do q.keys = nil end
                    for key, o in pairs(sweep.observations or {}) do
                        sweep.observations[key] = {
                            o.queryIndex or o[1] or 0,
                            o.observedAt or o[2] or 0,
                            o.zone or o[3] or "",
                            o.level or o[4] or 0,
                            o.classFile or o[5] or "",
                            o.race or o[6] or "",
                        }
                    end
                end
            end
        end
    end
    ML.db.populationStorageVersion = 2
end

function Pop:StartSweep(label, quiet)
    local store = self:Store()
    if store.activeSweepID then
        self:FinishSweep("partial")
        ML:CensusPrint("Previous active sweep was closed as partial.")
    end
    store.nextSweepSeq = (store.nextSweepSeq or 0) + 1
    local started = time()
    local id = tostring(started) .. "-" .. tostring(store.nextSweepSeq)
    store.sweeps[id] = {
        id = id, startedAt = started, completedAt = 0, status = "active",
        label = trim(label), faction = UnitFactionGroup and UnitFactionGroup("player") or "Neutral",
        queries = {}, observations = {},
    }
    store.activeSweepID = id
    if not quiet then
        ML:CensusPrint("Started population sweep |cffffffff%s|r. Run /ml who filters, then /ml sweep complete or /ml sweep partial.", id)
    end
    ML:Fire("POP_SWEEP_CHANGED", store.sweeps[id])
    return id
end

function Pop:FinishSweep(status)
    local store = self:Store()
    local id = store.activeSweepID
    local sweep = id and store.sweeps[id]
    if not sweep then
        ML:Print("No population sweep is active.")
        return nil
    end
    status = status == "complete" and "complete" or "partial"
    sweep.status = status
    sweep.completedAt = time()
    store.activeSweepID = nil
    local chars = 0
    for _ in pairs(sweep.observations or {}) do chars = chars + 1 end
    ML:CensusPrint("Closed sweep |cffffffff%s|r as %s: %d queries, %d unique characters.",
        id, status, #(sweep.queries or {}), chars)
    ML:Fire("POP_SWEEP_CHANGED", sweep)
    return sweep
end

function Pop:SweepStatus()
    local store = self:Store()
    local sweep = store.activeSweepID and store.sweeps[store.activeSweepID]
    if not sweep then
        ML:Print("No population sweep is active.")
        return nil
    end
    local chars, capped = 0, 0
    for _ in pairs(sweep.observations or {}) do chars = chars + 1 end
    for _, q in ipairs(sweep.queries or {}) do if q.capped then capped = capped + 1 end end
    ML:CensusPrint("Sweep %s: %d queries, %d unique characters, %d capped queries.",
        sweep.id, #(sweep.queries or {}), chars, capped)
    return sweep
end

function Pop:RecordSweepQuery(sample, roster, sweepID)
    if not sweepID then return end
    local store = self:Store()
    local sweep = store.sweeps[sweepID]
    if not sweep or sweep.status ~= "active" then return end
    sweep.queries = sweep.queries or {}
    sweep.observations = sweep.observations or {}
    local queryIndex = #sweep.queries + 1
    sweep.queries[queryIndex] = {
        index = queryIndex, t = sample.t, filter = sample.filter,
        observed = sample.observed or 0, total = sample.total or sample.observed or 0,
        capped = (sample.total or 0) > (sample.observed or 0) or self:IsCapped(sample.observed),
    }
    for key, seen in pairs(roster or {}) do
        sweep.observations[key] = {
            queryIndex, sample.t, seen.zone or "", seen.level or 0,
            seen.classFile or "", seen.race or "",
        }
    end
    ML:Fire("POP_SWEEP_CHANGED", sweep)
end

function Pop:Record(sample, roster)
    local store = self:Store()
    U.PushCapped(store.samples, sample, SCAN_CAP)
    store.lastScan = sample.t
    local day = math.floor(sample.t / 86400)
    local unique = 0
    for key, seen in pairs(roster or {}) do
        unique = unique + 1
        local c = store.characters[key]
        if not c then
            c = { key = key, firstSeen = sample.t, seenCount = 0, days = {} }
            store.characters[key] = c
        end
        c.fullName, c.name, c.realm = seen.fullName, seen.name, seen.realm
        c.firstName, c.lastName = seen.firstName, seen.lastName
        c.guild, c.level, c.race = seen.guild, seen.level, seen.race
        c.class, c.classFile, c.zone = seen.class, seen.classFile, seen.zone
        c.firstSeen = math.min(c.firstSeen or sample.t, sample.t)
        c.lastSeen = math.max(c.lastSeen or 0, sample.t)
        c.seenCount = (c.seenCount or 0) + 1
        c.days = c.days or {}
        local d = c.days[day] or { 0, sample.t, sample.t }
        d[1] = (d.count or d[1] or 0) + 1
        d[2] = math.min(d.firstSeen or d[2] or sample.t, sample.t)
        d[3] = math.max(d.lastSeen or d[3] or 0, sample.t)
        d.count, d.firstSeen, d.lastSeen = nil, nil, nil
        c.days[day] = d
    end
    self:Purge()
    return unique
end

function Pop:Purge()
    local store = ML.realm.population
    if not store or not store.samples then return 0 end
    local days = ML.db.settings.populationRetentionDays or 35
    local cutoff = time() - days * 86400
    local cutoffDay = math.floor(cutoff / 86400)
    local kept, removed = {}, 0
    for _, s in ipairs(store.samples) do
        if s.t >= cutoff then kept[#kept + 1] = s else removed = removed + 1 end
    end
    store.samples = kept
    for _, c in pairs(store.characters or {}) do
        for day in pairs(c.days or {}) do
            if (tonumber(day) or 0) < cutoffDay then c.days[day] = nil end
        end
    end
    for id, sweep in pairs(store.sweeps or {}) do
        local ended = sweep.completedAt or sweep.startedAt or 0
        if sweep.status ~= "active" and ended < cutoff then store.sweeps[id] = nil end
    end
    return removed
end

function Pop:DumpZones()
    local store = ML.realm and ML.realm.population
    local characters = store and store.characters
    if not characters or not next(characters) then
        ML:CensusPrint("No population data yet -- run /ml who first.")
        return
    end
    local counts = {}
    for _, c in pairs(characters) do
        local zone = c.zone
        if zone and zone ~= "" then
            counts[zone] = (counts[zone] or 0) + 1
        end
    end
    local zones = {}
    for zone in pairs(counts) do zones[#zones + 1] = zone end
    table.sort(zones)
    ML:CensusPrint("%d distinct zone(s) captured for %s:", #zones, ML:RealmKey())
    for _, zone in ipairs(zones) do
        ML:CensusPrint("  %s (%d)", zone, counts[zone])
    end
end

function Pop:CharacterStats()
    local store = self:Store()
    local today = math.floor(time() / 86400)
    local stats = { lifetime = 0, today = 0, week = 0, month = 0,
                    newWeek = 0, returningWeek = 0, active3 = 0 }
    local weekStart, monthStart = today - 6, today - 29
    for _, c in pairs(store.characters) do
        stats.lifetime = stats.lifetime + 1
        local inToday, inWeek, inMonth, monthDays = false, false, false, 0
        for day in pairs(c.days or {}) do
            day = tonumber(day) or 0
            if day == today then inToday = true end
            if day >= weekStart then inWeek = true end
            if day >= monthStart then inMonth, monthDays = true, monthDays + 1 end
        end
        if inToday then stats.today = stats.today + 1 end
        if inWeek then
            stats.week = stats.week + 1
            if (c.firstSeen or 0) >= weekStart * 86400 then
                stats.newWeek = stats.newWeek + 1
            else
                stats.returningWeek = stats.returningWeek + 1
            end
        end
        if inMonth then stats.month = stats.month + 1 end
        if monthDays >= 3 then stats.active3 = stats.active3 + 1 end
    end
    stats.returningRate = stats.week > 0 and U.Round(stats.returningWeek / stats.week * 100) or 0
    return stats
end

function Pop:Aggregate(secondsAgo)
    local store = ML.realm.population
    if not store or not store.samples then return nil end
    local cutoff = secondsAgo and (time() - secondsAgo) or 0

    local classes, races = {}, {}
    local observed, samples, lastScan = 0, 0, nil
    for _, s in ipairs(store.samples) do
        if s.t >= cutoff then
            samples  = samples + 1
            observed = observed + (s.observed or 0)
            lastScan = s.t
            for k, v in pairs(s.classes or {}) do classes[k] = (classes[k] or 0) + v end
            for k, v in pairs(s.races or {})   do races[k]   = (races[k] or 0) + v end
        end
    end
    if samples == 0 then return nil end
    return { classes = classes, races = races, observed = observed,
             samples = samples, lastScan = lastScan }
end

function Pop:Latest()
    local store = ML.realm.population
    if not store or not store.samples or #store.samples == 0 then return nil end
    return store.samples[#store.samples]
end

function Pop:OnActionBlocked(event, addon, func)
    if addon ~= ML.ADDON then return end
    ML:Print("|cffff4040Blizzard blocked %s()|r (%s).", tostring(func), event)
    if self.pending then
        self:TraceWho("SEND_BLOCKED", { filter = self.pendingFilter, action = tostring(func) })
        local diagnostic = self:Store().whoDiagnostic
        if diagnostic then diagnostic.status = "blocked: " .. tostring(func) end
        self.pending = false
        setWhoToUi(false)
        restoreWhoWindow()
        local tag = self.pendingTag
        self.pendingTag, self.pendingSweepID = nil, nil

        if tag ~= "census" then
            ML:Print("That /who was not sent. Type it as |cffffff00/ml who <filter>|r in chat instead.")
        end
        ML:Fire("POP_SCAN_FAILED", self.pendingFilter, tag)
    end
end

eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("WHO_LIST_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
eventFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "WHO_LIST_UPDATE" then
        Pop:Capture()
    elseif event == "CHAT_MSG_SYSTEM" then
        if Pop.pending then
            Pop.systemMessages = (Pop.systemMessages or 0) + 1
            if Pop.systemMessages <= 4 then
                Pop:TraceWho("CHAT_MSG_SYSTEM_WHILE_PENDING", { filter = Pop.pendingFilter,
                    message = tostring((...)):sub(1, 180) })
            end
        end
    else
        Pop:OnActionBlocked(event, ...)
    end
end)

local BAD_PREFIX, GOOD_PREFIX = "tbc-anniversary:", "retail:"

local function mergeCharacter(into, from)
    if (from.lastSeen or 0) >= (into.lastSeen or 0) then
        for _, f in ipairs({ "fullName", "name", "realm", "firstName", "lastName",
                             "guild", "level", "race", "class", "classFile", "zone" }) do
            if from[f] ~= nil then into[f] = from[f] end
        end
    end
    into.firstSeen = math.min(into.firstSeen or from.firstSeen or 0, from.firstSeen or into.firstSeen or 0)
    into.lastSeen = math.max(into.lastSeen or 0, from.lastSeen or 0)
    into.seenCount = (into.seenCount or 0) + (from.seenCount or 0)
    into.days = into.days or {}
    for day, d in pairs(from.days or {}) do
        local e = into.days[day]
        if not e then
            into.days[day] = d
        else
            e[1] = (e[1] or 0) + (d[1] or 0)
            e[2] = math.min(e[2] or d[2] or 0, d[2] or e[2] or 0)
            e[3] = math.max(e[3] or 0, d[3] or 0)
        end
    end
end

function Pop:RepairForeverKeys()
    if not ML:IsForeverBeta() then return 0 end
    local fixed = 0
    for _, realm in pairs(ML.db.realms or {}) do
        local store = realm.population
        if store then
            local chars, bad = store.characters or {}, {}
            for key, c in pairs(chars) do
                if key:sub(1, #BAD_PREFIX) == BAD_PREFIX then bad[key] = c end
            end
            for key, c in pairs(bad) do
                local good = GOOD_PREFIX .. key:sub(#BAD_PREFIX + 1)
                chars[key] = nil
                c.key = good
                if chars[good] then mergeCharacter(chars[good], c) else chars[good] = c end
                fixed = fixed + 1
            end
            for _, sweep in pairs(store.sweeps or {}) do
                if sweep.label == "census tbc-anniversary" then sweep.label = "census forever" end
                local obs = sweep.observations or {}
                local moved = {}
                for key, o in pairs(obs) do
                    if key:sub(1, #BAD_PREFIX) == BAD_PREFIX then moved[key] = o end
                end
                for key, o in pairs(moved) do
                    obs[key] = nil
                    local good = GOOD_PREFIX .. key:sub(#BAD_PREFIX + 1)

                    if not obs[good] or (o[2] or 0) > (obs[good][2] or 0) then obs[good] = o end
                end
            end

            local st = store.census
            if st and st.profile == "tbc-anniversary" then
                st.profile, st.label = "forever", Pop.Profiles.profiles.forever.label
            end
        end
    end
    if fixed > 0 then ML:Print("Repaired %d Forever character records keyed under the wrong client.", fixed) end
    return fixed
end

function Pop:Init()

end
