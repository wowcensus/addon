local WC = WoWCensus
local Pop = WC.Population

local INITIAL_DELAY = 15
local RESCAN_DELAY = 5
local SCAN_INTERVAL = 180
local SAMPLE_CAP = 200

local ChannelRoster = {}
Pop.ChannelRoster = ChannelRoster

local function retailAvailable()
    return WC:GameFlavor() == "retail"
        and type(GetNumDisplayChannels) == "function"
        and type(GetChannelDisplayInfo) == "function"
        and C_ChatInfo and type(C_ChatInfo.GetChannelRosterInfo) == "function"
end

local function enabled()
    return retailAvailable() and WC.db and WC.db.settings
        and WC.db.settings.channelRosterEnabled ~= false
end

local function rosterStore()
    local store = Pop:Store()
    store.channelRoster = store.channelRoster or { samples = {}, characters = {} }
    store.channelRoster.samples = store.channelRoster.samples or {}
    store.channelRoster.characters = store.channelRoster.characters or {}
    return store.channelRoster
end

local function rememberCharacter(seen, timestamp)
    local store = Pop:Store()
    local character = store.characters[seen.key]
    if not character then
        character = {
            key = seen.key, fullName = seen.fullName, name = seen.name,
            realm = seen.realm, firstName = seen.firstName, lastName = seen.lastName,
            firstSeen = timestamp, lastSeen = timestamp, seenCount = 0, days = {},
        }
        store.characters[seen.key] = character
    end

    character.fullName = character.fullName or seen.fullName
    character.name = character.name or seen.name
    character.realm = character.realm or seen.realm
    character.firstName = character.firstName or seen.firstName
    character.lastName = character.lastName or seen.lastName
    character.firstSeen = math.min(character.firstSeen or timestamp, timestamp)
    character.lastSeen = math.max(character.lastSeen or 0, timestamp)
    Pop:RememberSession(seen.key)

    local channelStore = rosterStore()
    local source = channelStore.characters[seen.key]
    if not source then
        source = {
            fullName = seen.fullName, guid = seen.guid,
            firstSeen = timestamp, lastSeen = timestamp, seenCount = 0, channels = {},
        }
        channelStore.characters[seen.key] = source
    end
    source.guid = source.guid or seen.guid
    source.lastSeen = timestamp
    source.seenCount = (source.seenCount or 0) + 1
    for channel in pairs(seen.channels) do source.channels[channel] = timestamp end
end

function ChannelRoster:Scan(announce, onlyIndex)
    if self.sweeping and not onlyIndex then return 0 end
    if not retailAvailable() then
        if announce then WC:Print("Channel roster collection is available on Retail only.") end
        return 0
    end
    if not enabled() then
        if announce then WC:Print("Channel roster collection is off. Use |cffffff00/wc roster on|r to enable it.") end
        return 0
    end
    if not onlyIndex and type(GetSelectedDisplayChannel) == "function" then
        local selected = GetSelectedDisplayChannel()
        if selected and selected > 0 then onlyIndex = selected end
    end

    local timestamp = time()
    local discovered, stats, diagnostics = {}, {}, {}
    for displayIndex = 1, (GetNumDisplayChannels() or 0) do
        local channelName, isHeader, _, channelNumber, memberCount, active =
            GetChannelDisplayInfo(displayIndex)
        if (not onlyIndex or displayIndex == onlyIndex)
            and not isHeader and active and channelNumber
            and memberCount and memberCount > 0 then
            local collected = 0
            for memberIndex = 1, memberCount do
                local playerName, _, _, guid =
                    C_ChatInfo.GetChannelRosterInfo(displayIndex, memberIndex)
                if playerName and playerName ~= "" then
                    local key, fullName, name, realm, firstName, lastName =
                        Pop:CharacterIdentity({ fullName = playerName })
                    if key then
                        local seen = discovered[key]
                        if not seen then
                            seen = {
                                key = key, fullName = fullName, name = name, realm = realm,
                                firstName = firstName, lastName = lastName, guid = guid, channels = {},
                            }
                            discovered[key] = seen
                        elseif guid and not seen.guid then
                            seen.guid = guid
                        end
                        seen.channels[channelName or tostring(channelNumber)] = true
                        collected = collected + 1
                    end
                end
            end
            local channelKey = channelName or tostring(channelNumber)
            if collected > 0 then stats[channelKey] = collected end
            if collected < memberCount then
                diagnostics[channelKey] = {
                    reported = memberCount, collected = collected,
                    displayIndex = displayIndex, channelNumber = channelNumber,
                }
            end
        end
    end

    local unique = 0
    for _, seen in pairs(discovered) do
        unique = unique + 1
        rememberCharacter(seen, timestamp)
    end

    local source = rosterStore()
    source.samples[#source.samples + 1] = {
        t = timestamp, unique = unique, channels = stats, diagnostics = diagnostics,
    }
    while #source.samples > SAMPLE_CAP do table.remove(source.samples, 1) end
    source.lastScan = timestamp
    local retention = (WC.db.settings and WC.db.settings.populationRetentionDays) or 35
    local cutoff = timestamp - retention * 86400
    local characters = Pop:Store().characters
    for key, character in pairs(source.characters) do
        if (character.lastSeen or 0) < cutoff then
            source.characters[key] = nil
            local canonical = characters[key]
            if canonical and (canonical.seenCount or 0) == 0 then
                characters[key] = nil
            end
        end
    end

    if announce then
        for channel, count in pairs(stats) do WC:Print("%s: %d channel member(s).", channel, count) end
        for channel, result in pairs(diagnostics) do
            WC:Print("|cffff8040%s roster incomplete: retrieved %d of %d reported member(s).|r",
                channel, result.collected, result.reported)
        end
        WC:Print("Channel rosters found %d unique character(s).", unique)
    else
        WC:Debug("Channel rosters found %d unique character(s).", unique)
        for channel, result in pairs(diagnostics) do
            WC:Debug("%s roster incomplete: retrieved %d of %d.",
                channel, result.collected, result.reported)
        end
    end
    WC:Fire("CHANNEL_ROSTER_SCAN_COMPLETE", source.samples[#source.samples])
    return unique
end

function ChannelRoster:Schedule(delay)
    if not enabled() or not C_Timer or not C_Timer.After then return end
    self.scheduleGeneration = (self.scheduleGeneration or 0) + 1
    local generation = self.scheduleGeneration
    C_Timer.After(delay or RESCAN_DELAY, function()
        if generation == ChannelRoster.scheduleGeneration then ChannelRoster:Scan(false) end
    end)
end

function ChannelRoster:ScanAll()
    if not retailAvailable() then
        WC:Print("Channel roster collection is available on Retail only.")
        return
    end
    if not enabled() then
        WC:Print("Channel roster collection is off. Use |cffffff00/wc roster on|r to enable it.")
        return
    end
    if self.sweeping then
        WC:Print("A channel roster sweep is already running.")
        return
    end
    if type(GetSelectedDisplayChannel) ~= "function"
        or type(SetSelectedDisplayChannel) ~= "function"
        or not C_Timer or type(C_Timer.After) ~= "function" then
        WC:Print("Channel selection API unavailable.")
        return
    end

    local original = GetSelectedDisplayChannel()
    local channels = {}
    for displayIndex = 1, (GetNumDisplayChannels() or 0) do
        local name, isHeader, _, channelNumber, memberCount, active =
            GetChannelDisplayInfo(displayIndex)
        if name and not isHeader and active and channelNumber
            and memberCount and memberCount > 0 then
            channels[#channels + 1] = {
                index = displayIndex, name = name,
                channelNumber = channelNumber, reported = memberCount,
            }
        end
    end

    if #channels == 0 then
        WC:Print("No populated joined channels are available to scan.")
        return
    end

    self.sweeping = true
    self.scheduleGeneration = (self.scheduleGeneration or 0) + 1
    local position, expectedSelection, total = 1, nil, 0

    local function finish(message)
        local current = GetSelectedDisplayChannel()
        if expectedSelection and current == expectedSelection and original and original > 0 then
            pcall(SetSelectedDisplayChannel, original)
        end
        ChannelRoster.sweeping = false
        if message then WC:Print("%s", message) end
        WC:Print("Channel sweep finished: %d discoveries across %d channel(s), before deduplication.",
            total, position - 1)
    end

    local nextChannel
    nextChannel = function()
        local channel = channels[position]
        if not channel then
            finish()
            return
        end

        if expectedSelection and GetSelectedDisplayChannel() ~= expectedSelection then
            finish("Sweep stopped because the selected channel changed.")
            return
        end

        local ok, selected = pcall(SetSelectedDisplayChannel, channel.index)
        if not ok or selected == false then
            finish(string.format("Could not select %s.", channel.name))
            return
        end
        expectedSelection = channel.index
        local attempts = 0

        local function collect()
            if GetSelectedDisplayChannel() ~= channel.index then
                finish("Sweep stopped because the selected channel changed.")
                return
            end

            attempts = attempts + 1
            local found = ChannelRoster:Scan(false, channel.index)
            if found == 0 and attempts < 3 then
                C_Timer.After(1, collect)
                return
            end

            total = total + found
            WC:Print("%s: %d character(s)%s.", channel.name, found,
                attempts > 1 and string.format(" after %d attempts", attempts) or "")
            position = position + 1
            C_Timer.After(0.5, nextChannel)
        end

        C_Timer.After(1.5, collect)
    end

    WC:Print("Scanning %d available channel(s). Do not change the selected channel until it finishes.",
        #channels)
    nextChannel()
end

function ChannelRoster:Init()
    if not retailAvailable() or self.initialized then return end
    self.initialized = true
    local events = CreateFrame("Frame")
    events:RegisterEvent("CHANNEL_UI_UPDATE")
    events:SetScript("OnEvent", function() ChannelRoster:Schedule(RESCAN_DELAY) end)
    self.eventFrame = events
    if enabled() then self:Schedule(INITIAL_DELAY) end
    if enabled() and C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(SCAN_INTERVAL, function() ChannelRoster:Scan(false) end)
    end
end

function ChannelRoster:SetEnabled(on)
    if not retailAvailable() then
        WC:Print("Channel roster collection is available on Retail only.")
        return
    end
    WC.db.settings.channelRosterEnabled = on and true or false
    self.scheduleGeneration = (self.scheduleGeneration or 0) + 1
    if self.ticker and self.ticker.Cancel then self.ticker:Cancel() end
    self.ticker = nil
    if on then
        self:Schedule(0)
        if C_Timer and C_Timer.NewTicker then
            self.ticker = C_Timer.NewTicker(SCAN_INTERVAL, function() ChannelRoster:Scan(false) end)
        end
    end
    WC:Print("Channel roster collection %s.", on and "on" or "off")
end

SLASH_WOWCENSUSROSTER1 = "/wcroster"
SlashCmdList.WOWCENSUSROSTER = function(input)
    if tostring(input or ""):lower():match("^%s*all%s*$") then
        ChannelRoster:ScanAll()
    else
        ChannelRoster:Scan(true)
    end
end
