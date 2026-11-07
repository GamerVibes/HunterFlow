-- HunterFlow: Hilfen fuer Jaeger in WoW Forever.
-- Aufbau: ein kleiner Kern (Events, Speicher, Slash-Befehl) und darauf Module.
-- Neue Module (Reichweite, Munition, Pet) brauchen nur Init und RegisterModule.

local ADDON_NAME, HF = ...

-- Andere Klassen steigen hier aus: keine Frames, keine Events, kein Slash-Befehl.
local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" then
    return
end

--------------------------------------------------------------------------------
-- Kern
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local listeners = {}
local modules = {}
local positioning = false

-- Meldet eine Funktion fuer ein Event an. Mit unit kommen nur Events dieser Einheit.
function HF:On(event, handler, unit)
    if not listeners[event] then
        listeners[event] = {}
        if unit then
            eventFrame:RegisterUnitEvent(event, unit)
        else
            eventFrame:RegisterEvent(event)
        end
    end
    table.insert(listeners[event], handler)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, handler in ipairs(listeners[event]) do
        handler(...)
    end
end)

-- Jedes Modul bekommt in HunterFlowDB einen eigenen Untertisch unter seiner id.
function HF:RegisterModule(id, module)
    modules[id] = module
end

function HF:Print(text)
    print("|cffabd473[HunterFlow]|r " .. text)
end

HF:On("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME then
        return
    end
    HunterFlowDB = HunterFlowDB or {}
    for id, module in pairs(modules) do
        HunterFlowDB[id] = HunterFlowDB[id] or {}
        module:Init(HunterFlowDB[id])
    end
end)

SLASH_HUNTERFLOW1 = "/hflow"
SlashCmdList["HUNTERFLOW"] = function()
    positioning = not positioning
    for _, module in pairs(modules) do
        if module.SetPositioning then
            module:SetPositioning(positioning)
        end
    end
    if positioning then
        HF:Print("Leiste eingeblendet. Mit Shift und linker Maustaste verschieben, /hflow blendet sie wieder aus.")
    else
        HF:Print("Positionieren beendet.")
    end
end

--------------------------------------------------------------------------------
-- Modul: Auto-Shot-Leiste
--------------------------------------------------------------------------------

local AUTO_SHOT_SPELL_ID = 75
local RED_WINDOW = 0.5 -- letzte Sekunden des Timers, rot markiert
local BAR_WIDTH, BAR_HEIGHT = 200, 14
local DEFAULT_Y = -150 -- etwas unterhalb der Bildschirmmitte

local AutoShot = {}
local db, frame, bar, windowMark, label
local duration -- aktuelle Schussgeschwindigkeit in Sekunden
local endTime -- Zeitpunkt, an dem der Timer ablaeuft, nil wenn er nicht laeuft
local autoShotActive = false
local barPositioning = false
local dragging = false
local barInWindow -- letzte gesetzte Farbe, spart unnoetige Aufrufe

local function SetBarColor(inWindow)
    if inWindow == barInWindow then
        return
    end
    barInWindow = inWindow
    if inWindow then
        bar:SetStatusBarColor(0.85, 0.15, 0.15)
    else
        bar:SetStatusBarColor(0.2, 0.8, 0.2)
    end
end

-- Versteckt die Leiste, wenn nichts mehr dafuer spricht, sie zu zeigen.
local function HideIfIdle()
    if not autoShotActive and not barPositioning and not InCombatLockdown() then
        frame:Hide()
    end
end

-- Volle Leiste, Timer aus. OnUpdate laeuft nur, solange der Timer laeuft.
local function ShowReady()
    frame:SetScript("OnUpdate", nil)
    endTime = nil
    bar:SetValue(1)
    label:SetText("bereit")
    SetBarColor(false)
end

local function OnUpdate()
    local remaining = endTime - GetTime()
    if remaining <= 0 then
        ShowReady()
        HideIfIdle()
        return
    end
    bar:SetValue(1 - remaining / duration)
    label:SetFormattedText("%.1f", remaining)
    SetBarColor(remaining <= RED_WINDOW)
end

-- Liest die Schussgeschwindigkeit. Aendert sie sich waehrend des Timers (Hast),
-- bleibt der Fortschritt der Leiste erhalten und nur die Restzeit skaliert mit.
local function ReadSpeed()
    local speed = UnitRangedDamage("player")
    if not speed or speed <= 0 then
        return
    end
    if endTime then
        local now = GetTime()
        endTime = now + (endTime - now) * speed / duration
    end
    duration = speed
    windowMark:SetWidth(BAR_WIDTH * math.min(RED_WINDOW / speed, 1))
    windowMark:Show()
end

local function OnSpellSucceeded(_, _, spellID)
    if spellID ~= AUTO_SHOT_SPELL_ID then
        return
    end
    ReadSpeed()
    if not duration then
        return
    end
    endTime = GetTime() + duration
    frame:SetScript("OnUpdate", OnUpdate)
    frame:Show()
end

local function StopDragging()
    if not dragging then
        return
    end
    dragging = false
    frame:StopMovingOrSizing()
    local point, _, relativePoint, x, y = frame:GetPoint()
    db.point, db.relativePoint, db.x, db.y = point, relativePoint, x, y
    frame:EnableMouse(IsShiftKeyDown())
end

local function CreateBar()
    frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(BAR_WIDTH, BAR_HEIGHT)
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or DEFAULT_Y)
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetAllPoints()
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)

    -- Roter Bereich am rechten Ende, liegt ueber der Fuellung und unter dem Text.
    windowMark = bar:CreateTexture(nil, "OVERLAY", nil, -1)
    windowMark:SetColorTexture(0.85, 0.15, 0.15, 0.45)
    windowMark:SetPoint("TOPRIGHT")
    windowMark:SetPoint("BOTTOMRIGHT")
    windowMark:Hide()

    label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")

    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() then
            dragging = true
            self:StartMoving()
        end
    end)
    frame:SetScript("OnMouseUp", StopDragging)
    frame:SetScript("OnHide", StopDragging)

    ShowReady()
    frame:Hide()
end

function AutoShot:Init(moduleDB)
    db = moduleDB
    CreateBar()

    HF:On("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded, "player")
    HF:On("UNIT_RANGEDDAMAGE", ReadSpeed, "player")

    HF:On("START_AUTOREPEAT_SPELL", function()
        autoShotActive = true
        ReadSpeed()
        frame:Show()
    end)

    -- Kommt STOP erst nach dem Kampfende, fiele die Leiste sonst nie mehr weg.
    HF:On("STOP_AUTOREPEAT_SPELL", function()
        autoShotActive = false
        HideIfIdle()
    end)

    HF:On("PLAYER_REGEN_ENABLED", HideIfIdle)

    -- Die Maus ist nur bei gedruecktem Shift aktiv, sonst schluckt die Leiste
    -- mitten im Bild Klicks und Kameradrehungen.
    HF:On("MODIFIER_STATE_CHANGED", function()
        if not dragging then
            frame:EnableMouse(IsShiftKeyDown())
        end
    end)
end

function AutoShot:SetPositioning(enabled)
    barPositioning = enabled
    if enabled then
        ReadSpeed()
        frame:Show()
    else
        HideIfIdle()
    end
end

HF:RegisterModule("autoShot", AutoShot)
