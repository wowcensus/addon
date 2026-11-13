local ML = WoWCensus
local Pop = ML.Population
local P = Pop.Profiles
local U = ML.Util
local C = {}
Pop.Census = C

local TARGET = 35
local HISTORY_DAYS = 7
local LEARN_DAYS = 14
local ZONE_SPLITS = 4
local NAME_SPLITS = 16
local LETTER_MAX_SHARE = 0.4
local LETTER_COVERAGE = 0.98
local MIN_ZONE_SUPPORT = 3
local FIXED_SPLIT_AT = 40
local MERGE_TARGET = 40
local MAX_PRESPLIT_DEPTH = 8
local ANSWER_TIMEOUT = Pop.ANSWER_TIMEOUT or 25
local BACKOFF_MIN = 30
local BACKOFF_MAX = 90

local function nodeKey(n)
    if n.refreshFilter then return "refresh|" .. n.refreshFilter end
    return string.format("%d-%d|%s|%s|%s|%s", n.lo, n.hi, n.class or "", n.race or "",
        n.letter or "", n.zone or "")
end

local function splitsExhaustively(n)
    if n.refreshFilter or n.tail then return false end
    return n.hi > n.lo or not n.class or not n.race
end

function C:Filter(n)
    if n.refreshFilter then return n.refreshFilter end
    local parts = { n.lo == n.hi and tostring(n.lo) or (n.lo .. "-" .. n.hi) }
    if n.class then parts[#parts + 1] = 'c-"' .. P.ClassName(n.class) .. '"' end
    if n.race then parts[#parts + 1] = 'r-"' .. n.race .. '"' end
    if n.letter then parts[#parts + 1] = 'n-"' .. n.letter .. '"' end
    if n.zone then parts[#parts + 1] = 'z-"' .. n.zone .. '"' end
    return table.concat(parts, " ")
end

function C:State()
    local store = Pop:Store()
    store.censusLearned = store.censusLearned or {}
    store.censusSeen = store.censusSeen or {}
    return store.census, store
end

function C:Profile()
    if not self.profile then self.profile = P.Current() end
    return self.profile
end

function Pop:IsCapped(observed)
    local prof = C:Profile()
    return (observed or 0) >= ((prof and prof.capAt) or 49)
end

function C:History()
    if self.hist then return self.hist end
    local store = Pop:Store()
    local cutoff = time() - HISTORY_DAYS * 86400
    local recent, racesByClass, classCount, raceCount, pairCount = {}, {}, {}, {}, {}
    for _, c in pairs(store.characters or {}) do
        local L = tonumber(c.level) or 0
        if L > 0 and (c.lastSeen or 0) >= cutoff then recent[#recent + 1] = c end
        if c.classFile and c.race and c.race ~= "" then
            racesByClass[c.classFile] = racesByClass[c.classFile] or {}
            racesByClass[c.classFile][c.race] = true
            classCount[c.classFile] = (classCount[c.classFile] or 0) + 1
            raceCount[c.race] = (raceCount[c.race] or 0) + 1
            local pair = c.classFile .. "|" .. c.race
            pairCount[pair] = (pairCount[pair] or 0) + 1
        end
    end
    self.hist = { recent = recent, racesByClass = racesByClass, classCount = classCount,
        raceCount = raceCount, pairCount = pairCount }
    return self.hist
end

local function contains(have, want)
    return have ~= nil and tostring(have):lower():find(tostring(want):lower(), 1, true) ~= nil
end

local function matchesNode(c, n)
    local L = tonumber(c.level) or 0
    return L >= n.lo and L <= n.hi
        and (not n.class or c.classFile == n.class
            or (c.classFile and contains(P.ClassName(c.classFile), P.ClassName(n.class))))
        and (not n.race or contains(c.race, n.race))
        and (not n.letter or tostring(c.name or c.fullName or ""):lower():find(n.letter, 1, true))
end

function C:Weight(n)
    local w = 0
    for _, c in ipairs(self:History().recent) do
        if matchesNode(c, n) then w = w + 1 end
    end
    return w
end

function C:Estimate(n, st)
    if (st.ratioHist or 0) <= 0 then return nil end
    return self:Weight(n) * st.ratioObs / st.ratioHist
end

function C:SplitLevels(n, st, known)
    local width = n.hi - n.lo + 1
    local counts = {}
    for _, c in ipairs(self:History().recent) do
        if matchesNode(c, n) then
            local L = tonumber(c.level)
            counts[L] = (counts[L] or 0) + 1
        end
    end
    local weights, total = {}, 0
    for L = n.lo, n.hi do
        local w = (counts[L] or 0) + 1
        weights[#weights + 1] = w
        total = total + w
    end

    local k = 2
    local est = known or self:Estimate(n, st)
    if width <= 3 then
        k = width
    elseif est then
        k = math.ceil(math.max(est, self:Profile().capAt) / TARGET)
    end
    k = U.Clamp(k, 2, width)

    local kids, lo, acc, part = {}, n.lo, 0, 1
    for i = 1, width do
        local L = n.lo + i - 1
        acc = acc + weights[i]
        local mustCut = (width - i) == (k - part)
        if L == n.hi or (part < k and (acc >= total * part / k or mustCut)) then
            kids[#kids + 1] = { lo = lo, hi = L, class = n.class, race = n.race,
                letter = n.letter, zone = n.zone }
            lo, part = L + 1, part + 1
        end
    end
    return kids
end

local MIN_CLASS_HISTORY = 20
local MIN_RACE_HISTORY = 60
local function raceList(prof, class, hist)
    local list, seen = {}, {}
    local function add(r)
        if r and r ~= "" and not seen[r] then seen[r] = true; list[#list + 1] = r end
    end
    local allowed = prof.racesByClass and prof.racesByClass[class]
    if allowed then
        local mine = {}
        for _, r in ipairs(prof.races) do mine[r] = true end
        for _, r in ipairs(allowed) do if mine[r] then add(r) end end
        return list
    end
    local observed = hist.racesByClass[class] or {}
    local trusted = (hist.classCount[class] or 0) >= MIN_CLASS_HISTORY
    for _, r in ipairs(prof.races) do
        if not trusted or observed[r] then add(r) end
    end
    local extra = {}
    for r in pairs(observed) do if not seen[r] then extra[#extra + 1] = r end end
    table.sort(extra)
    for _, r in ipairs(extra) do add(r) end
    return list
end

function C:RaceList(class)
    return raceList(self:Profile(), class, self:History())
end

local function zoneList(prof, n, hist)
    local counts = {}
    local function tally(strict)
        for _, c in ipairs(hist.recent) do
            local L = tonumber(c.level) or 0
            local hit = strict and matchesNode(c, n) or (not strict and L >= n.lo and L <= n.hi)
            if hit and c.zone and c.zone ~= "" then
                counts[c.zone] = (counts[c.zone] or 0) + 1
            end
        end
    end

    local function ranked()
        local zones = {}
        for z, c in pairs(counts) do
            if c >= MIN_ZONE_SUPPORT then zones[#zones + 1] = z end
        end
        table.sort(zones, function(a, b)
            if counts[a] ~= counts[b] then return counts[a] > counts[b] end
            return a < b
        end)
        return zones
    end
    tally(true)
    local zones = ranked()
    if #zones < 2 then
        counts = {}
        tally(false)
        zones = ranked()
    end
    local out = {}
    for _, z in ipairs(zones) do
        if #out >= ZONE_SPLITS then break end
        out[#out + 1] = z
    end
    if #out == 0 then
        for i = 1, math.min(2, #prof.hotspots) do out[#out + 1] = prof.hotspots[i] end
    end
    return out
end

local function letterList(n, hist)
    local probe = { lo = 1, hi = math.huge, class = n.class, race = n.race }
    local names = {}
    for _, c in ipairs(hist.recent or {}) do
        if matchesNode(c, probe) then
            local name = tostring(c.name or c.fullName or ""):lower()
            if name ~= "" then names[#names + 1] = name end
        end
    end
    local order = "aeinorstludmchpgbyfkvwxqjz"
    local candidates = {}
    for i = 1, #order do
        local letter, hits = order:sub(i, i), 0
        for _, name in ipairs(names) do
            if name:find(letter, 1, true) then hits = hits + 1 end
        end
        if #names == 0 or (hits > 0 and hits <= #names * LETTER_MAX_SHARE) then
            candidates[#candidates + 1] = letter
        end
    end
    local chosen, covered, nCovered = {}, {}, 0
    while #chosen < NAME_SPLITS and #candidates > 0 do
        if #names > 0 and nCovered >= #names * LETTER_COVERAGE then break end
        local bestIndex, bestGain = 1, -1
        for i, letter in ipairs(candidates) do
            local gain = 0
            for j, name in ipairs(names) do
                if not covered[j] and name:find(letter, 1, true) then gain = gain + 1 end
            end
            if gain > bestGain then bestIndex, bestGain = i, gain end
        end
        if #names > 0 and bestGain == 0 then break end
        local letter = table.remove(candidates, bestIndex)
        chosen[#chosen + 1] = letter
        for j, name in ipairs(names) do
            if not covered[j] and name:find(letter, 1, true) then
                covered[j] = true
                nCovered = nCovered + 1
            end
        end
    end
    return chosen
end

function C:Learned(n)
    local _, store = self:State()
    local e = store.censusLearned[nodeKey(n)]
    if type(e) == "table" and (time() - (e.t or 0)) < LEARN_DAYS * 86400 then return e end
    return nil
end

function C:SplitKind(n, st)
    if self:Profile().id == "forever" then
        if n.hi > n.lo then return "level" end
        if not n.race then return "race" end
        if not n.class then return "class" end
        if not n.letter then return "letter" end
        return nil
    end
    local learned = self:Learned(n)
    local width = n.hi - n.lo + 1
    if learned and learned.kind == "class" and width > 1 then

        local total = self:ChildSum(n)
        if total and total / width <= self:Profile().capAt * 0.8 then return "level", total end
        return "class"
    end
    if learned and learned.kind and not (learned.kind == "level" and width == 1) then return learned.kind end
    if width > 1 then
        if not n.class then
            local est = self:Estimate(n, st)
            if est and est / width > TARGET then return "class" end
        end
        return "level"
    end
    if not n.class and not n.race then

        local prof, hist = self:Profile(), self:History()
        local function axisCost(axis, values)
            local counts, support = {}, 0
            for _, c in ipairs(hist.recent or {}) do
                if matchesNode(c, n) then
                    local value = axis == "class" and c.classFile or c.race
                    if value and value ~= "" then
                        counts[value] = (counts[value] or 0) + 1
                        support = support + 1
                    end
                end
            end
            if support < 20 then return nil end
            local cost = #values
            for _, value in ipairs(values) do
                if (counts[value] or 0) >= prof.capAt * 0.8 then
                    if axis == "class" then
                        cost = cost + math.max(#raceList(prof, value, hist) - 1, 1)
                    else
                        local possible = 0
                        for _, token in ipairs(prof.classes) do
                            local allowed = prof.racesByClass and prof.racesByClass[token]
                            if not allowed then
                                possible = possible + 1
                            else
                                for _, race in ipairs(allowed) do
                                    if race == value then possible = possible + 1 break end
                                end
                            end
                        end
                        cost = cost + math.max(possible - 1, 1)
                    end
                end
            end
            return cost
        end
        local classCost = axisCost("class", prof.classes)
        local raceCost = axisCost("race", prof.races)
        if raceCost and (not classCost or raceCost < classCost) then return "race" end
        return "class"
    end
    if not n.class then return "class" end
    if not n.race then return "race" end
    if not n.letter then return "letter" end
    if not n.zone then return "zone" end
    return nil
end

function C:Children(n, st)
    if n.tail then return {}, false, nil end
    local prof = self:Profile()
    local kind, total = self:SplitKind(n, st)
    local kids = {}
    if kind == "level" then
        local learned = self:Learned(n)
        if learned and learned.levels then
            for i = 1, #learned.levels, 2 do
                kids[#kids + 1] = { lo = learned.levels[i], hi = learned.levels[i + 1],
                    class = n.class, race = n.race, letter = n.letter, zone = n.zone }
            end
            kids = self:Compact(n, learned, kids)
        end

        if not learned or not learned.levels or #kids < 2 then
            kids = self:SplitLevels(n, st, total)

            if learned then self:Learn(n, kind, kids) end
        end
        return kids, true, kind
    elseif kind == "class" then

        local hist = n.race and not prof.racesByClass and prof.id ~= "forever" and self:History()
        local trusted = hist and (hist.raceCount[n.race] or 0) >= MIN_RACE_HISTORY
        for _, token in ipairs(prof.classes) do
            local include = true
            if n.race and prof.racesByClass and prof.racesByClass[token] then
                include = false
                for _, race in ipairs(prof.racesByClass[token]) do
                    if race == n.race then include = true break end
                end
            elseif trusted then
                include = (hist.racesByClass[token] or {})[n.race] and true or false
            end
            if include then kids[#kids + 1] = { lo = n.lo, hi = n.hi, class = token,
                race = n.race, letter = n.letter, zone = n.zone } end
        end
        return kids, true, kind
    elseif kind == "race" then
        local races = prof.id == "forever" and prof.races or raceList(prof, n.class, self:History())
        for _, race in ipairs(races) do
            kids[#kids + 1] = { lo = n.lo, hi = n.hi, class = n.class, race = race,
                letter = n.letter, zone = n.zone }
        end
        return kids, true, kind
    elseif kind == "letter" then
        for _, letter in ipairs(letterList(n, self:History())) do
            kids[#kids + 1] = { lo = n.lo, hi = n.hi, class = n.class, race = n.race,
                letter = letter, zone = n.zone }
        end
        return kids, false, kind
    elseif kind == "zone" then
        if not prof.zoneFallback then return kids, false, kind end
        for _, zone in ipairs(zoneList(prof, n, self:History())) do
            kids[#kids + 1] = { lo = n.lo, hi = n.hi, class = n.class, race = n.race,
                letter = n.letter, zone = zone }
        end
        return kids, false, kind
    end
    return kids, false, nil
end

function C:ChildSum(n)
    local _, store = self:State()
    local cutoff = time() - LEARN_DAYS * 86400
    local total = 0
    for _, token in ipairs(self:Profile().classes) do
        local k = { lo = n.lo, hi = n.hi, class = token }
        if self:Learned(k) then return nil end
        local s = store.censusSeen[nodeKey(k)]
        if not s or s.t < cutoff then return nil end
        total = total + s.n
    end
    return total
end

function C:Compact(n, learned, kids)
    local _, store = self:State()
    local cutoff = time() - LEARN_DAYS * 86400
    local function count(k)
        if self:Learned(k) then return nil end
        local s = store.censusSeen[nodeKey(k)]
        return s and s.t >= cutoff and s.n or nil
    end
    local out, cur, curN, curT = {}, nil, nil, nil
    local function flush()
        if not cur then return end
        out[#out + 1] = cur
        if curN then store.censusSeen[nodeKey(cur)] = { t = curT, n = curN } end
    end
    for _, k in ipairs(kids) do
        local c = count(k)
        local t = c and store.censusSeen[nodeKey(k)].t

        if cur and curN and c and curN + c <= MERGE_TARGET
            and not (cur.lo == n.lo and k.hi == n.hi) then
            cur = { lo = cur.lo, hi = k.hi, class = n.class, race = n.race,
                letter = n.letter, zone = n.zone }
            curN, curT = curN + c, math.min(curT, t)
        else
            flush()
            cur, curN, curT = k, c, t
        end
    end
    flush()
    if #out < #kids then
        learned.levels = {}
        for _, k in ipairs(out) do
            learned.levels[#learned.levels + 1] = k.lo
            learned.levels[#learned.levels + 1] = k.hi
        end
    end
    return out
end

function C:Learn(n, kind, kids)
    local _, store = self:State()
    local e = { t = time(), kind = kind }
    if kind == "level" then
        e.levels = {}
        for _, k in ipairs(kids) do
            e.levels[#e.levels + 1] = k.lo
            e.levels[#e.levels + 1] = k.hi
        end
    end
    store.censusLearned[nodeKey(n)] = e
end

function C:Fixed(st)
    if st and st.fixed ~= nil then return st.fixed end
    local set = ML.db.settings.censusFixed
    if set ~= nil then return set end

    if ML.db.settings.censusPassive then return false end
    return self:Profile().fixedPlan and true or false
end

function C:ShouldPreSplit(n, st)
    if n.refreshFilter then return false end

    local profile = self:Profile().id
    if (profile == "retail" or profile == "hardcore" or profile == "mop-classic") and not st.fixed then return false end
    if self:Learned(n) then return true end
    return st.fixed and self:Weight(n) >= FIXED_SPLIT_AT
end

function C:Expand(nodes, st, out, depth)
    for _, n in ipairs(nodes) do
        local exhaustive
        if self:Profile().id == "forever" then
            exhaustive = not n.refreshFilter and not n.tail and n.hi > n.lo
        else
            exhaustive = splitsExhaustively(n)
        end
        if depth < MAX_PRESPLIT_DEPTH and exhaustive and self:ShouldPreSplit(n, st) then
            st.preSplit = st.preSplit + 1
            self:Expand((self:Children(n, st)), st, out, depth + 1)
        else
            out[#out + 1] = n
        end
    end
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
end

C.Shuffle = shuffle

function C:Enqueue(nodes, st)
    local planned = {}
    self:Expand(nodes, st, planned, 0)
    for _, n in ipairs(planned) do
        table.insert(st.queue, math.random(#st.queue + 1), n)
    end
    return #planned
end

function C:PurgeLearned()
    local _, store = self:State()
    local cutoff = time() - LEARN_DAYS * 86400
    for key, e in pairs(store.censusLearned) do
        if type(e) ~= "table" or (e.t or 0) < cutoff then store.censusLearned[key] = nil end
    end
    for key, s in pairs(store.censusSeen) do
        if (s.t or 0) < cutoff then store.censusSeen[key] = nil end
    end
end

function C:SeedSeen()
    local _, store = self:State()
    local latest
    for _, sweep in pairs(store.sweeps or {}) do
        if (sweep.label or ""):match("^census ") and (not latest or sweep.startedAt > latest.startedAt) then
            latest = sweep
        end
    end
    local tokenOf = {}
    for _, token in ipairs(self:Profile().classes) do tokenOf[P.ClassName(token)] = token end
    for _, q in ipairs(latest and latest.queries or {}) do
        local f = q.filter or ""
        local levels, className = f:match('^(%S+) c%-"([^"]+)"$')
        levels = levels or f
        local lo, hi = levels:match("^(%d+)%-(%d+)$")
        if not lo then lo = levels:match("^(%d+)$"); hi = lo end
        local class = className and tokenOf[className]
        if lo and not q.capped and (class or not className) then
            local key = nodeKey({ lo = tonumber(lo), hi = tonumber(hi), class = class })
            if not store.censusSeen[key] then store.censusSeen[key] = { t = q.t, n = q.observed or 0 } end
        end
    end
end

function C:Outdated()
    local st = self:State()
    local prof = self:Profile()
    return st and prof and
        ((prof.id == "forever" and st.plan ~= "forever-broad-v6")
            or (prof.id == "retail" and not st.fixed and st.plan ~= "retail-broad-first-v1")
            or (prof.id == "hardcore" and not st.fixed and st.plan ~= "hardcore-broad-first-v1")
            or (prof.id == "mop-classic" and not st.fixed and st.plan ~= "mop-broad-first-v1")) or false
end

function C:ForeverMixedPlan(prof, firstLevel, lastLevel)
    local nodes = {}
    local lo = firstLevel or prof.minLevel or 1
    local last = lastLevel or prof.maxLevel
    while lo <= last do
        local hi = math.min(lo + 9, last)
        nodes[#nodes + 1] = { lo = lo, hi = hi, base = true }
        lo = hi + 1
    end
    shuffle(nodes)
    return nodes
end

function C:ForeverProbe(st, prof)
    if st.activeLevel >= prof.maxLevel then return nil end
    return { refreshFilter = (st.activeLevel + 1) .. "-" .. prof.maxLevel, probe = true }
end

function C:ExpandForever(st, prof, level)
    level = math.min(level or 0, prof.maxLevel)
    if level <= st.activeLevel then return end
    local previous = st.activeLevel
    st.activeLevel = level
    local nodes = self:ForeverMixedPlan(prof, previous + 1, level)
    st.baseRemaining = (st.baseRemaining or 0) + #nodes
    st.refinements = st.refinements or {}
    for _, node in ipairs(nodes) do
        table.insert(st.queue, math.random(#st.queue + 1), node)
    end
    local probe = self:ForeverProbe(st, prof)
    local queuedProbe = false
    for i = #st.queue, 1, -1 do
        local queued = st.queue[i]
        if queued.probe then
            if probe then
                queued.refreshFilter = probe.refreshFilter
                queuedProbe = true
            else
                table.remove(st.queue, i)
            end
        end
    end
    if probe and not queuedProbe then st.queue[#st.queue + 1] = probe end
    ML:Print("Forever reached level %d; added %d shuffled /who queries for levels %d-%d.", level, #nodes, previous + 1, level)
end

function C:Start()
    if ML:Region() == "unknown" then
        ML:Print("Collection region is unknown. Set it with /wc region us|eu|kr|tw|cn before starting.")
        return
    end
    local prof, why = P.Current()
    if not prof then ML:Print(why); return end
    self.profile, self.hist = prof, nil
    local st, store = self:State()
    if st and self:Outdated() then
        ML:Print("Replacing the running census with the current %s plan.", prof.label)
        self:Finish(true)
        st = nil
    end
    if st then
        ML:Print("A census is already running -- |cffffff00/wc next|r to continue or |cffffff00/wc stop|r.")
        return
    end
    self:PurgeLearned()
    self:SeedSeen()

    local sweepID = Pop:StartSweep("census " .. prof.id, true)
    st = {
        profile = prof.id, label = prof.label, faction = prof.faction,
        startedAt = time(), sweepID = sweepID, queue = {},
        done = 0, generated = 0, preSplit = 0, capped = 0, unresolved = 0, retries = 0,
        ratioObs = 0, ratioHist = 0,
    }
    st.fixed = self:Fixed()
    store.census = st

    if st.fixed then st.ratioObs, st.ratioHist = 1, 1 end

    local backbone = {}

    local adaptivePassive = ML.db.settings.censusPassive
    if prof.id == "forever" then

        st.plan, st.fixed = "forever-broad-v6", false
        st.ratioObs, st.ratioHist = 0, 0
        st.activeLevel = math.min(prof.maxLevel, math.max(30, store.foreverDiscoveredLevel or 30))
        st.nextProbeAt = 25
        backbone = self:ForeverMixedPlan(prof, prof.minLevel, st.activeLevel)
        st.baseRemaining = #backbone
        st.refinements = {}
    elseif prof.simpleRefresh and not adaptivePassive then

        for level = 1, math.min(prof.maxLevel, 20) do
            backbone[#backbone + 1] = { refreshFilter = tostring(level) }
        end
        for _, race in ipairs(prof.races) do
            backbone[#backbone + 1] = { refreshFilter = 'r-"' .. race .. '"' }
        end
        for _, class in ipairs(prof.classes) do
            backbone[#backbone + 1] = { refreshFilter = 'c-"' .. P.ClassName(class) .. '"' }
        end
        st.fixed = true
    else
        if prof.id == "retail" and not st.fixed then st.plan = "retail-broad-first-v1" end
        if prof.id == "hardcore" and not st.fixed then st.plan = "hardcore-broad-first-v1" end
        if prof.id == "mop-classic" and not st.fixed then st.plan = "mop-broad-first-v1" end
        for i = #prof.bands, 1, -1 do
            local b = prof.bands[i]
            if b[1] <= prof.maxLevel then
                backbone[#backbone + 1] = { lo = b[1], hi = math.min(b[2], prof.maxLevel) }
            end
        end
    end
    if st.plan == "forever-broad-v6" then
        for _, n in ipairs(backbone) do st.queue[#st.queue + 1] = n end
        local probe = self:ForeverProbe(st, prof)
        if probe then st.queue[#st.queue + 1] = probe end
    elseif st.plan == "mop-broad-first-v1" then

        for _, n in ipairs(backbone) do st.queue[#st.queue + 1] = n end
    else
        self:Enqueue(backbone, st)
    end
    if st.fixed then st.ratioObs, st.ratioHist = 0, 0 end
    if st.plan == "forever-broad-v6" then
        ML:Print("Census started: |cffffffff%s|r %s, levels 10-%d in order, then %d shuffled level/race and level/class queries across levels 1-%d. Name refinements follow the base sweep.",
            prof.label, prof.faction, math.min(30, prof.maxLevel), #backbone, prof.maxLevel)
    else
        ML:Print("Census started: |cffffffff%s|r %s, %s%d queries%s.",
            prof.label, prof.faction, st.fixed and "fixed list of " or "", #st.queue,
            st.fixed and " -- it will not grow; anything over 50 is recorded as 50+"
                or (st.preSplit > 0 and string.format(" planned (%d pre-split from earlier runs)", st.preSplit) or " planned"))
    end
    ML:Fire("CENSUS_CHANGED")
    self:PromptNext()
end

function C:Settle(st, quiet)
    if st.inflight then
        local sentAt = st.inflightSentAt or time()
        if time() - sentAt < ANSWER_TIMEOUT then
            if not quiet then ML:Print("Still waiting on the last /who...") end
            return nil
        end
        if Pop.pending then Pop:ExpirePending() end

        table.insert(st.queue, 1, st.inflight)
        st.inflight = nil
        st.inflightSentAt = nil
        local diagnostic = Pop:Store().whoDiagnostic
        if diagnostic and diagnostic.status == "waiting" then diagnostic.status = "timeout_unknown" end
        st.retries = st.retries + 1
        st.misses = (st.misses or 0) + 1
        if st.misses >= 2 then
            st.nextAttemptAt = time() + math.random(BACKOFF_MIN, BACKOFF_MAX)
            st.misses = 0
            if not quiet then ML:Print("No /who response; waiting before retry.") end
        end
    end
    if st.nextAttemptAt and time() < st.nextAttemptAt then return nil end
    st.nextAttemptAt = nil

    local prof = self:Profile()
    for i = #st.queue, 1, -1 do
        local n = st.queue[i]
        if n.lo and n.lo > prof.maxLevel then
            table.remove(st.queue, i)
        elseif n.hi and n.hi > prof.maxLevel then
            n.hi = prof.maxLevel
        end
    end

    if prof.id == "retail" then
        for i = #st.queue, 1, -1 do
            local n = st.queue[i]
            local allowed = n.class and n.race and prof.racesByClass[n.class]
            if allowed then
                local found = false
                for _, race in ipairs(allowed) do
                    if race == n.race then found = true break end
                end
                if not found then table.remove(st.queue, i) end
            end
        end
    end

    if not prof.zoneFallback then
        for i = #st.queue, 1, -1 do
            if st.queue[i].zone then table.remove(st.queue, i) end
        end
    end
    return st.queue[1]
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

function C:ViaChat()
    return ML.db.settings.censusViaChat
end

function C:SetViaChat(on, quiet)
    ML.db.settings.censusViaChat = on or nil
    if not quiet then
        ML:Print("Census chat mode %s.", on
            and "|cff40c040on|r -- press Enter on each /wc who the census types for you"
            or "off -- Run Next sends queries directly")
    end
    if on then self:PromptNext() end
    ML:Fire("CENSUS_CHANGED")
end

function C:PromptNext()
    local st = self:State()
    if not st or not self:ViaChat() then return end
    if self:Outdated() then self:Start(); return end
    local n = self:Settle(st, true)
    if not n then return end
    local filter = self:Filter(n)
    C_Timer.After(Pop:CooldownRemaining(), function()
        local s = self:State()
        if not s or s.inflight or not s.queue[1] or self:Filter(s.queue[1]) ~= filter then return end
        local command = "/wc who " .. filter

        ML:Print("Next: |cffffff00%s|r", command)
        local open = ChatFrame_OpenChat or (ChatFrameUtil and ChatFrameUtil.OpenChat)
        if open then
            open(command)

            C_Timer.After(0.1, function()
                local current = self:State()
                if not current or current.inflight or not current.queue[1]
                    or self:Filter(current.queue[1]) ~= filter then return end
                local active = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                if not active then open(command) end
            end)
        end
    end)
end

function C:TryChatQuery(filter)
    local st = self:State()
    if not st then return false end
    if self:Outdated() then self:Start(); return false end
    filter = trim(filter)
    local n = self:Settle(st, true)
    if not n or self:Filter(n) ~= filter then return false end
    self:Send(st, n, filter)
    return true
end

function C:Send(st, n, filter, source)
    table.remove(st.queue, 1)
    st.inflight = n
    st.inflightSentAt = time()
    st.inflightSource = source
    if not Pop:Scan(filter, "census") and st.inflight == n then

        table.insert(st.queue, 1, n)
        st.inflight = nil
        st.inflightSentAt = nil
        st.inflightSource = nil
        self:PromptNext()
        return
    end
    ML:Fire("CENSUS_CHANGED")
end

function C:RunNext(quiet, source)
    local st = self:State()
    if not st then
        ML:Print("No census is running -- |cffffff00/ml census start|r.")
        return
    end
    if self:Outdated() then
        ML:Print("Replacing the running census with the current %s plan.", self:Profile().label)
        self:Finish(true)
        self:Start()
        return
    end
    if self:ViaChat() then

        self:PromptNext()
        return
    end
    local n = self:Settle(st, quiet)
    if not n then

        if not st.inflight and not (st.nextAttemptAt and time() < st.nextAttemptAt) then self:Finish() end
        return
    end
    self:Send(st, n, self:Filter(n), source)
end

function C:OnScanComplete(sample, tag)
    local st, store = self:State()
    if tag ~= "census" or not st or not st.inflight then return end
    local n = st.inflight
    st.inflight = nil
    st.inflightSentAt = nil
    st.inflightSource = nil
    st.misses = 0
    st.nextAttemptAt = nil
    st.done = st.done + 1

    local observed = sample.observed or 0
    local key = nodeKey(n)
    local last = { filter = sample.filter, observed = observed, capped = false, split = 0 }
    if Pop:IsCapped(observed) then
        last.capped = true
        st.capped = st.capped + 1
        local kids, exhaustive, kind = {}, false, nil
        if not n.refreshFilter then kids, exhaustive, kind = self:Children(n, st) end
        if exhaustive then
            self:Learn(n, kind, kids)
        elseif not (n.refreshFilter and st.plan == "forever-broad-v6")
            and not n.zone and not n.letter then
            st.unresolved = st.unresolved + 1
        end
        if self:Fixed(st) then

            if exhaustive then st.unresolved = st.unresolved + 1 end
            kids = {}
        end
        if st.plan == "forever-broad-v6" and (n.base or (st.baseRemaining or 0) > 0) then
            for _, kid in ipairs(kids) do st.refinements[#st.refinements + 1] = kid end
            last.split = #kids
        else
            last.split = self:Enqueue(kids, st)
        end
        st.generated = st.generated + last.split

        local sweep = store.sweeps[st.sweepID]
        local q = sweep and sweep.queries and sweep.queries[#sweep.queries]
        if q and q.filter == sample.filter and
            exhaustive and #kids > 0 and last.split == #kids then
            q.split = true
        end
    else
        store.censusLearned[key] = nil
        if not n.zone then store.censusSeen[key] = { t = time(), n = observed } end

        if not n.zone then
            local raw = self:Weight(n)
            if raw > 0 then
                st.ratioObs = st.ratioObs + observed
                st.ratioHist = st.ratioHist + raw
            end
        end
    end
    if n.base then
        st.baseRemaining = math.max((st.baseRemaining or 1) - 1, 0)
        if st.baseRemaining == 0 and st.refinements then
            shuffle(st.refinements)
            for _, kid in ipairs(st.refinements) do st.queue[#st.queue + 1] = kid end
            st.refinements = nil
        end
    end
    if st.plan == "forever-broad-v6" then
        local prof = self:Profile()
        local found = sample.maxObservedLevel or 0
        if found > st.activeLevel then
            self:ExpandForever(st, prof, found)
            store.foreverDiscoveredLevel = st.activeLevel
        end
        if not n.probe and st.done >= (st.nextProbeAt or 25) and st.activeLevel < prof.maxLevel then
            local queuedProbe = false
            for _, queued in ipairs(st.queue) do
                if queued.probe then queuedProbe = true; break end
            end
            if not queuedProbe then table.insert(st.queue, 1, self:ForeverProbe(st, prof)) end
            st.nextProbeAt = st.done + 25
        end
    end
    st.last = last

    ML:CensusPrint("|cff808080%d/%d|r %s |cff808080=|r %s", st.done, st.done + #st.queue, sample.filter or "",
        last.capped and string.format("|cffff8040%d, split %d|r", observed, last.split) or tostring(observed))

    if #st.queue == 0 then
        self:Finish()
    else
        ML:Fire("CENSUS_CHANGED")
        self:PromptNext()
    end
end

function C:Counts(st)
    local _, store = self:State()
    local sweep = st and store.sweeps[st.sweepID]
    if not sweep then return 0, 0 end
    local unique, rows = 0, 0
    for _ in pairs(sweep.observations or {}) do unique = unique + 1 end
    for _, q in ipairs(sweep.queries or {}) do rows = rows + (q.observed or 0) end
    return unique, rows
end

function C:Finish(stopped)
    local st, store = self:State()
    if not st then return end
    local drained = #st.queue == 0 and not st.inflight
    local status = (not stopped and drained and st.unresolved == 0) and "complete" or "partial"
    local unique, rows = self:Counts(st)

    local focusOnline
    if st.plan == "focus" and drained and not stopped then
        local sweep = store.sweeps[st.sweepID]
        focusOnline = 0
        for _, o in pairs(sweep and sweep.observations or {}) do
            if (tonumber(o[4]) or 0) >= st.focusFrom then focusOnline = focusOnline + 1 end
        end
    end
    if store.activeSweepID == st.sweepID then Pop:FinishSweep(status) end
    if not store.censusRunTotals then

        local complete, partial = 0, 0
        for _, sweep in pairs(store.sweeps or {}) do
            if sweep.label and sweep.label:match("^census ") then
                if sweep.status == "complete" then complete = complete + 1
                elseif sweep.status == "partial" then partial = partial + 1 end
            end
        end
        store.censusRunTotals = { complete = complete, partial = partial }
    else
        store.censusRunTotals[status] = (store.censusRunTotals[status] or 0) + 1
    end
    store.censusLast = {
        profile = st.profile, label = st.label, faction = st.faction,
        startedAt = st.startedAt, finishedAt = time(), status = status, stopped = stopped and true or nil,
        done = st.done, generated = st.generated, preSplit = st.preSplit,
        unresolved = st.unresolved, remaining = #st.queue, unique = unique, rows = rows,
        focusFrom = focusOnline and st.focusFrom or nil, focusOnline = focusOnline,
    }
    store.census = nil
    ML:Print("Census %s: %d queries, %d unique characters (%d duplicate sightings), %d unresolved capped cell(s).",
        stopped and "stopped" or "finished", st.done, unique, math.max(rows - unique, 0), st.unresolved)
    if st.unresolved > 0 then
        ML:Print("Unresolved cells still hit the /who cap after every split -- treat counts as a lower bound.")
    end
    ML:Fire("CENSUS_CHANGED")
end

function C:Stop()
    if not self:State() then
        ML:Print("No census is running.")
        return
    end
    self:Finish(true)
end

function C:Forget()
    local _, store = self:State()
    local n = U.CountKeys(store.censusLearned)
    store.censusLearned = {}
    ML:Print("Forgot %d learned census split(s); the next census starts from the plain backbone.", n)
end

function C:PrintProfile()
    local prof, why = P.Current()
    if not prof then ML:Print(why); return end
    local _, store = self:State()
    local bands = {}
    for _, b in ipairs(prof.bands) do
        bands[#bands + 1] = b[1] == b[2] and tostring(b[1]) or (b[1] .. "-" .. b[2])
    end
    ML:Print("Census profile |cffffffff%s|r (%s), level cap %d, /who cap at %d results.",
        prof.label, prof.faction, prof.maxLevel, prof.capAt)
    ML:Print("  Backbone: %s", table.concat(bands, ", "))
    ML:Print("  Learned splits for %s: %d", ML:RealmKey(), U.CountKeys(store.censusLearned))
end

function C:Status()
    local st = self:State()
    if not st then
        ML:Print("No census is running -- |cffffff00/ml census start|r.")
        return
    end
    local unique, rows = self:Counts(st)
    local wait = st.nextAttemptAt and math.max(st.nextAttemptAt - time(), 0) or 0
    ML:Print("Census %s %s: %d/%d queries, next %s%s, %d unique, %d unresolved.",
        st.label, st.faction, st.done, st.done + #st.queue,
        st.queue[1] and self:Filter(st.queue[1]) or "--",
        wait > 0 and string.format(" (backoff %ds)", wait) or "", unique, st.unresolved)
end

function C:Summary()
    local st, store = self:State()
    if not st then return nil, store.censusLast end
    local unique, rows = self:Counts(st)
    return {
        label = st.label, faction = st.faction, done = st.done,
        total = st.done + #st.queue + (st.inflight and 1 or 0),
        inflight = st.inflight and self:Filter(st.inflight),
        next = st.queue[1] and self:Filter(st.queue[1]),
        last = st.last, generated = st.generated, preSplit = st.preSplit,
        unresolved = st.unresolved, retries = st.retries,
        passive = ML.db.settings.censusPassive and true or false,
        backoff = st.nextAttemptAt and math.max(st.nextAttemptAt - time(), 0) or 0,
        unique = unique, duplicates = math.max(rows - unique, 0),
    }, store.censusLast
end

function C:IsActive()
    return self:State() ~= nil
end

ML:On("POP_SCAN_COMPLETE", function(sample, tag) C:OnScanComplete(sample, tag) end)

ML:On("POP_SCAN_FAILED", function(_, tag)
    local st = C:State()
    if tag ~= "census" or not st or not st.inflight then return end
    local source = st.inflightSource
    table.insert(st.queue, 1, st.inflight)
    st.inflight = nil
    st.inflightSentAt = nil
    st.inflightSource = nil
    ML:Fire("CENSUS_CHANGED")
    if ML.db.settings.censusPassive and Pop.Passive then
        Pop.Passive:OnSendFailure(source)
    elseif C:ViaChat() then
        C:PromptNext()
    else
        C:SetViaChat(true)
    end
end)

ML:On("POP_SCAN_STALE", function(_, tag)
    local st = C:State()
    if tag ~= "census" or not st or not st.inflight then return end
    table.insert(st.queue, 1, st.inflight)
    st.inflight, st.inflightSentAt, st.inflightSource = nil, nil, nil
    ML:Fire("CENSUS_CHANGED")
end)
