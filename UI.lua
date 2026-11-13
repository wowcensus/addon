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

function UI:Refresh()
    if not frame then return end
    local census = WC.Population.Census
    local summary, last = census:Summary()
    local store = WC.Population:Store()
    local complete, partial = countRuns(store)
    setLine(1, "Runs", string.format("%d complete  ·  %d partial", complete, partial))
    if summary then
        local state = census:State()
        local sweep = state and store.sweeps and store.sweeps[state.sweepID]
        setLine(2, "Progress", string.format("%d / %d queries", summary.done, summary.total))
        setLine(3, "Last queries", recentQueries(sweep))
        setLine(4, "Running", summary.inflight or "—")
        setLine(5, "Next", summary.next or "—")
    else
        setLine(2, "Progress", last and (last.status .. " · " .. last.done .. " queries") or "No run yet")
        local latest
        for _, sweep in pairs(store.sweeps or {}) do
            if sweep.label and sweep.label:match("^census ")
                and (not latest or (sweep.startedAt or 0) > (latest.startedAt or 0)) then latest = sweep end
        end
        setLine(3, "Last queries", recentQueries(latest))
        setLine(4, "Running", "—")
        setLine(5, "Next", WC:Region() == "unknown" and "Set region: /wc region us|eu|kr|tw|cn" or "Start a run")
    end
    local diagnostic = store.whoDiagnostic
    local whoStatus = diagnostic and diagnostic.status or "No query sent"
    if diagnostic and whoStatus == "waiting" and time() - (diagnostic.attemptedAt or 0) >= (WC.Population.ANSWER_TIMEOUT or 25) then
        whoStatus = "no response yet"
    end
    setLine(6, "Last /who", diagnostic and (whoStatus .. " · " .. (diagnostic.filter or "")) or whoStatus)
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
    frame:SetSize(460, 355)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame.TitleText:SetText("WoWCensus")
    frame:Hide()
    lines, buttons = {}, {}
    local offsets = { 38, 72, 106, 205, 239, 273 }
    for i, label in ipairs({ "Runs", "Progress", "Last queries", "Running", "Next", "Last /who" }) do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("TOPLEFT", 18, -offsets[i])
        row:SetSize(424, i == 3 and 95 or 30)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("TOPLEFT")
        row.label:SetText(label)
        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("TOPLEFT", 0, -14)
        row.value:SetWidth(424)
        row.value:SetHeight(i == 3 and 76 or 16)
        row.value:SetJustifyH("LEFT")
        row.value:SetWordWrap(i == 3)
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
end
