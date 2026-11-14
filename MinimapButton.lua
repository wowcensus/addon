local addonName = ...
local WC = WoWCensus
local LDB = LibStub("LibDataBroker-1.1")
local DBIcon = LibStub("LibDBIcon-1.0")

local launcher = LDB:NewDataObject("WoWCensus", {
    type = "launcher",
    text = "WoWCensus",
    icon = "Interface\\AddOns\\" .. addonName .. "\\Media\\icon",
    OnClick = function(_, button)
        if button == "RightButton" then
            WC.db.settings.censusPassive = not WC.db.settings.censusPassive
            WC.db.settings.censusPassiveConfigured = true
            WC:Print("Passive census %s.", WC.db.settings.censusPassive and "on" or "off")
            if WC.UI and WC.UI.Refresh then WC.UI:Refresh() end
        else
            WC.UI:Toggle()
        end
    end,
    OnTooltipShow = function(tooltip)
        local count = WC.Population and WC.Population:SessionCount() or 0
        tooltip:AddLine("WoWCensus")
        tooltip:AddLine(string.format("%d unique characters since login", count), 1, 1, 1)
        tooltip:AddLine("Left-click: Open window", 0.8, 0.8, 0.8)
        tooltip:AddLine("Right-click: Toggle auto scan", 0.8, 0.8, 0.8)
        tooltip:AddLine("Drag: Move icon", 0.7, 0.7, 0.7)
    end,
})

function WC:SetMinimapShown(shown)
    self.db.minimap = self.db.minimap or { hide = false, minimapPos = 225 }
    self.db.minimap.hide = not shown
    if DBIcon:IsRegistered("WoWCensus") then
        if shown then DBIcon:Show("WoWCensus") else DBIcon:Hide("WoWCensus") end
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    WC.db.minimap = WC.db.minimap or {}
    if WC.db.minimap.hide == nil then WC.db.minimap.hide = false end
    if WC.db.minimap.minimapPos == nil then WC.db.minimap.minimapPos = 225 end
    if not DBIcon:IsRegistered("WoWCensus") then
        DBIcon:Register("WoWCensus", launcher, WC.db.minimap)
    end
end)
