local ML = WoWCensus
local U = ML.Util

function U.CountKeys(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

function U.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.Round(v)
    return math.floor(v + 0.5)
end

function U.Scale100(v, inMin, inMax)
    if inMax == inMin then return 0 end
    local t = (v - inMin) / (inMax - inMin)
    return U.Clamp(t * 100, 0, 100)
end

function U.WeightedAverage(entries)
    local sumPQ, sumQ = 0, 0
    for _, e in ipairs(entries) do
        sumPQ = sumPQ + e.price * e.quantity
        sumQ  = sumQ + e.quantity
    end
    if sumQ == 0 then return 0 end
    return U.Round(sumPQ / sumQ)
end

function U.WeightedPercentile(entries, p)
    if #entries == 0 then return 0 end
    local sorted = {}
    for i, e in ipairs(entries) do sorted[i] = e end
    table.sort(sorted, function(a, b) return a.price < b.price end)

    local total = 0
    for _, e in ipairs(sorted) do total = total + e.quantity end
    if total == 0 then return sorted[1].price end

    local target = p * total
    local cum = 0
    for _, e in ipairs(sorted) do
        cum = cum + e.quantity
        if cum >= target then return e.price end
    end
    return sorted[#sorted].price
end

function U.PushCapped(list, value, cap)
    table.insert(list, value)
    while #list > cap do table.remove(list, 1) end
end
