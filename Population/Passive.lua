local ML = WoWCensus
local Pop = ML.Population
local Passive = {}
Pop.Passive = Passive

local KEY_FUNCTIONS = {
    "MoveForwardStart", "MoveBackwardStart", "TurnLeftStart", "TurnRightStart",
    "StrafeLeftStart", "StrafeRightStart", "JumpOrAscendStart", "MoveAndSteerStart",
    "ToggleAutoRun", "StartAutoRun", "MoveViewInStart", "MoveViewOutStart",
}

local installed = false
local hookedKeys = 0
local keysUsable = true
local worldClicksUsable = true

local function buildID()
    return tostring((select(4, GetBuildInfo())) or "?")
end

function Passive:Input(source)
    if not (ML.db and ML.db.settings and ML.db.settings.censusPassive) then return end
    local C = Pop.Census
    if not C or not C:IsActive() or C:ViaChat() then return end
    if source ~= "world click" and not keysUsable then return end
    if source == "world click" and not worldClicksUsable then return end

    if Pop:CooldownRemaining() > 0 then return end
    if IsInInstance then
        local _, kind = IsInInstance()
        if kind == "pvp" or kind == "arena" then return end
    end
    C:RunNext(true, source or "passive")
end

function Passive:OnSendFailure(source)

    if source == "button" then return end
    if source and source ~= "world click" then
        if keysUsable then
            keysUsable = false
            ML.db.settings.censusPassiveKeysBlockedBuild = buildID()
            ML:Print("This client rejected passive /who from movement keys; continuing from world clicks.")
        end
        return
    end
    worldClicksUsable = false
    ML.db.settings.censusPassive = false
    Pop.Census:SetViaChat(true)
    ML:Print("This client rejected passive /who from world clicks too; passive mode is off and chat mode is ready.")
end

function Passive:InstallHooks()
    if installed then return end
    installed = true
    if WorldFrame and WorldFrame.HookScript then
        pcall(WorldFrame.HookScript, WorldFrame, "OnMouseDown", function() Passive:Input("world click") end)
    end
    if hooksecurefunc then
        for _, name in ipairs(KEY_FUNCTIONS) do
            if type(_G[name]) == "function" then
                local ok = pcall(hooksecurefunc, name, function() Passive:Input(name) end)
                if ok then hookedKeys = hookedKeys + 1 end
            end
        end
    end
end

function Passive:Init()
    self:InstallHooks()
    keysUsable = ML.db.settings.censusPassiveKeysBlockedBuild ~= buildID()
    local C = Pop.Census

    if Pop.Profiles and Pop.Profiles.DetectID and Pop.Profiles.DetectID() == "forever" then
        keysUsable = false
        ML.db.settings.censusPassiveKeysBlockedBuild = buildID()
    end
    if ML.db.settings.censusPassive and C:ViaChat() then C:SetViaChat(false, true) end
    if ML.db.settings.censusAutoStart and C and not C:IsActive() then C:Start() end
    if C and C:IsActive() and ML.db.settings.censusPassive then
        ML:CensusPrint("Passive census ready: the next eligible movement or world click will continue it.")
    end
    ML:Debug("passive census hooks: %d movement functions", hookedKeys)
end
