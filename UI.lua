local WC = WoWCensus
local UI = WC.UI
local frame, lines, buttons

local function countRuns(store)
    if store.censusRunTotals then
        return store.censusRunTotals.complete or 0, store.censusRunTotals.partial or 0
    end
    local complete, partial = 0, 0
    for _, sweep in pairs(store.sweeps or {}) do
        if sweep.label and sweep.label:match("^census ") then
            if sweep.status == "complete" then complete = complete + 1
            elseif sweep.status == "partial" then partial = partial + 1 end
        end
    end
    return complete, partial
end

local function recentQueries(sweep)
    local queries = sweep and sweep.queries or {}
    local out = {}
    for i = #queries, math.max(#queries - 2, 1), -1 do
        local q = queries[i]
        out[#out + 1] = string.format("%s  (%d%s)", q.filter or "?", q.observed or 0,
            q.capped and "+" or "")
    end
    return #out > 0 and table.concat(out, "\n") or "—"
end

local function setLine(index, label, value)
    lines[index].label:SetText(label)
    lines[index].value:SetText(value or "—")
end

local function commas(n)
    local out = tostring(n or 0)
    while true do
        local replaced, count = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        out = replaced
        if count == 0 then return out end
    end
end

function UI:Refresh()
    if not frame then return end
    local census = WC.Population.Census
    local summary, last = census:Summary()
    local store = WC.Population:Store()
    local complete, partial = countRuns(store)
    setLine(1, "Runs", string.format("%d complete  ·  %d partial", complete, partial))
    setLine(2, "Discovered", string.format("%s unique since login", commas(WC.Population:SessionCount())))
    if summary then
        local state = census:State()
        local sweep = state and store.sweeps and store.sweeps[state.sweepID]
        setLine(3, "Progress", string.format("%d / %d queries", summary.done, summary.total))
        setLine(4, "Last queries", recentQueries(sweep))
        setLine(5, "Running", summary.inflight or "—")
        setLine(6, "Next", summary.next or "—")
    else
        setLine(3, "Progress", last and (last.status .. " · " .. last.done .. " queries") or "No run yet")
        local latest
        for _, sweep in pairs(store.sweeps or {}) do
            if sweep.label and sweep.label:match("^census ")
                and (not latest or (sweep.startedAt or 0) > (latest.startedAt or 0)) then latest = sweep end
        end
        setLine(4, "Last queries", recentQueries(latest))
        setLine(5, "Running", "—")
        setLine(6, "Next", WC:Region() == "unknown" and "Set region: /wc region us|eu|kr|tw|cn" or "Start a run")
    end
    local diagnostic = store.whoDiagnostic
    local whoStatus = diagnostic and diagnostic.status or "No query sent"
    if diagnostic and whoStatus == "waiting" and time() - (diagnostic.attemptedAt or 0) >= (WC.Population.ANSWER_TIMEOUT or 25) then
        whoStatus = "no response yet"
    end
    setLine(7, "Last /who", diagnostic and (whoStatus .. " · " .. (diagnostic.filter or "")) or whoStatus)
    if buttons.market and WC.Market then
        buttons.market:SetChecked(WC.Market:Enabled())
        if buttons.marketLabel then
            buttons.marketLabel:SetText(string.format("Collect other addon data (%s records)", commas(WC.Market:Count())))
        end
    end
    if buttons.minimap then
        buttons.minimap:SetChecked(not (WC.db.minimap and WC.db.minimap.hide))
    end
    buttons.start:SetText(summary and "Stop" or "Start")
    local state = summary and census:State()
    local canRetry = state and state.inflight and
        (not WC.Population.pending or time() - (state.inflightSentAt or 0) >= 15)
    buttons.next:SetEnabled(summary ~= nil and (summary.inflight == nil or canRetry))
    buttons.passive:SetText(WC.db.settings.censusPassive and "Auto: On" or "Auto: Off")
end

function UI:Build()
    if frame then return end
    frame = CreateFrame("Frame", "WoWCensusWindow", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 420)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.TitleText:SetText("WoWCensus")
    frame:Hide()
    lines, buttons = {}, {}
    local offsets = { 38, 72, 106, 140, 230, 264, 298 }
    for i, label in ipairs({ "Runs", "Discovered", "Progress", "Last queries", "Running", "Next", "Last /who" }) do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("TOPLEFT", 18, -offsets[i])
        row:SetSize(424, i == 4 and 86 or 30)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("TOPLEFT")
        row.label:SetText(label)
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("TOPLEFT", 0, -14)
        row.value:SetWidth(424)
        row.value:SetHeight(i == 4 and 68 or 16)
        row.value:SetJustifyH("LEFT")
        row.value:SetWordWrap(i == 4)
        lines[i] = row
    end
    buttons.start = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    buttons.start:SetSize(82, 23)
    buttons.start:SetPoint("BOTTOMLEFT", 18, 17)
    buttons.start:SetScript("OnClick", function()
        local census = WC.Population.Census
        if census:IsActive() then census:Stop() else census:Start() end
        UI:Refresh()
    end)
    buttons.next = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    buttons.next:SetSize(94, 23)
    buttons.next:SetPoint("LEFT", buttons.start, "RIGHT", 8, 0)
    buttons.next:SetText("Run Next")
    buttons.next:SetScript("OnClick", function()
        WC.Population.Census:RunNext(false, "button")
        UI:Refresh()
    end)
    buttons.passive = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    buttons.passive:SetSize(90, 23)
    buttons.passive:SetPoint("LEFT", buttons.next, "RIGHT", 8, 0)
    buttons.passive:SetScript("OnClick", function()
        WC.db.settings.censusPassive = not WC.db.settings.censusPassive
        WC.db.settings.censusPassiveConfigured = true
        WC:Print("Passive census %s.", WC.db.settings.censusPassive and "on" or "off")
        UI:Refresh()
    end)
    buttons.minimap = CreateFrame("CheckButton", "WoWCensusMinimapCheckbox", frame, "UICheckButtonTemplate")
    buttons.minimap:SetPoint("LEFT", buttons.passive, "RIGHT", 8, 0)
    buttons.minimap:SetChecked(not (WC.db.minimap and WC.db.minimap.hide))
    local minimapLabel = buttons.minimap.Text or _G.WoWCensusMinimapCheckboxText
    if minimapLabel then minimapLabel:SetText("Minimap") end
    buttons.minimap:SetScript("OnClick", function(self)
        WC:SetMinimapShown(self:GetChecked() and true or false)
    end)
    buttons.market = CreateFrame("CheckButton", "WoWCensusMarketCheckbox", frame, "UICheckButtonTemplate")
    buttons.market:SetPoint("BOTTOMLEFT", 14, 44)
    buttons.market:SetChecked(WC.Market and WC.Market:Enabled())
    buttons.marketLabel = buttons.market.Text or _G.WoWCensusMarketCheckboxText
    buttons.market:SetScript("OnClick", function(self)
        WC.Market:SetEnabled(self:GetChecked() and true or false)
        UI:Refresh()
    end)
    buttons.market:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Collect addon data")
        GameTooltip:AddLine("Copies everything Journalator logs (auctions, vendor sales, repairs, quests, loot, taxis, trainers, mail and trades) plus TradeSkillMaster and Auctionator auction history and everything Dungeon Journal saves into the WoWCensus save. Other players' names, mail subjects and mail text are not copied.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    buttons.market:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame:SetScript("OnShow", function() UI:Refresh() end)
    local elapsedSinceRefresh = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        elapsedSinceRefresh = elapsedSinceRefresh + elapsed
        if elapsedSinceRefresh >= 1 then
            elapsedSinceRefresh = 0
            UI:Refresh()
        end
    end)
end

function UI:Toggle()
    self:Build()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

function UI:Init()
    self:Build()
    WC:On("CENSUS_CHANGED", function() UI:Refresh() end)
    WC:On("POP_SWEEP_CHANGED", function() UI:Refresh() end)
    WC:On("MARKET_CHANGED", function() UI:Refresh() end)
end
