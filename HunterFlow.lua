-- HunterFlow: Das Add-on fuer Jaeger in WoW Forever, Schwerpunkt Kiten.
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
    HunterFlowDB.log = nil -- Reste frueherer Messungen
    HunterFlowDB.probe = nil
    for id, module in pairs(modules) do
        HunterFlowDB[id] = HunterFlowDB[id] or {}
        module:Init(HunterFlowDB[id])
    end
end)

-- Schaltet den Positioniermodus aller Module, fuer Menue und Slash-Befehl.
function HF:SetPositioning(enabled)
    positioning = enabled
    for _, module in pairs(modules) do
        if module.SetPositioning then
            module:SetPositioning(enabled)
        end
    end
end

SLASH_HUNTERFLOW1 = "/hflow"
SlashCmdList["HUNTERFLOW"] = function()
    HF:SetPositioning(not positioning)
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
local RED_WINDOW = 0.5 -- Zielzeit, so lange muss der Jaeger vor dem Schuss stillstehen
local PERFECT_WINDOW = 0.3 -- wer so kurz vor dem Zielen anhaelt, hat perfekt getimt
local PRACTICE_SPEED = 2.5 -- Tempo im Uebungsmodus, falls keine Waffe lesbar ist
local SHOT_SYMBOL_TIME = 0.35 -- so lange zeigt die Leiste nach dem Schuss den Bogen
local MAX_MEASURED_SPEED = 6 -- Obergrenze fuer gemessene Abstaende ohne bekanntes Tempo
local MEASURE_TOLERANCE = 0.2 -- erlaubte Abweichung nach oben, faengt Ping-Schwankungen ab
local BAR_WIDTH, BAR_HEIGHT = 200, 14
local DEFAULT_Y = -150 -- etwas unterhalb der Bildschirmmitte
local TEXTURE_PATH = "Interface\\AddOns\\HunterFlow\\Textures\\"
local SOUND_PATH = "Interface\\AddOns\\HunterFlow\\Sounds\\"
local DEFAULT_SOUND_LEVEL = 75 -- Prozent, moeglich sind 25, 50, 75 und 100

local AutoShot = {}
local db, frame, bar, core, windowMark, windowEdge, perfectMark, stopLine, symbol, label, procAnimation
local perfectLock, lockAnimation -- leuchtendes Gold, sobald im goldenen Bereich angehalten wurde
local STREAK_MIN = 3 -- ab so vielen perfekten Schuessen in Folge zeigt der Counter an
local perfectStreak = 0
local streakLabel, procText
local perfectStop = false -- im goldenen Bereich angehalten und seitdem nicht gelaufen
local practiceActive = false -- Uebungsmodus: Schuesse werden nur simuliert
local StartCycle -- beginnt einen neuen Schuss-Zyklus, unten definiert
local duration -- Zeit von Schuss zu Schuss in Sekunden, gelesen oder gemessen
local baseSpeed -- zuletzt vom Spiel gelesenes Tempo, nur ausserhalb des Kampfes lesbar
local reloadEnd -- Ende des Nachladens, nil wenn der Timer nicht laeuft
local aimStart -- Beginn des Stillstands beim Zielen, nil solange nicht gezielt wird
local aimDisturbed = false -- Bewegung hat das Zielen verzoegert, Abstand nicht messen
local lastShotTime
local isMoving = false
local cycleStartedAt = 0 -- Zeitpunkt des letzten Schusses, ab hier laeuft die Zeit
local goldAnnounced = false -- Hinweiston fuer diesen Zyklus schon gespielt
local autoShotActive = false
local barPositioning = false
local dragging = false
local currentPhase -- letzte gesetzte Phase, spart unnoetige Aufrufe

-- Der ganze Balken traegt die Farbe der Phase, das liest man auch im Augenwinkel.
-- Der Kern bleibt fast weiss, das wirkt wie Neon.
local PHASES = {
    idle = { glow = { 0.55, 0.6, 0.57 }, core = { 0.78, 0.82, 0.8 } },
    shot = { glow = { 0.25, 0.92, 0.42 }, core = { 0.77, 1, 0.82 }, icon = "SymbolBow", iconColor = { 0.3, 0.7, 1 } },
    run = { glow = { 0.25, 0.92, 0.42 }, core = { 0.77, 1, 0.82 }, icon = "SymbolRun" },
    gold = { glow = { 1, 0.78, 0.24 }, core = { 1, 0.94, 0.74 }, icon = "SymbolHalt" },
    stand = { glow = { 1, 0.29, 0.22 }, core = { 1, 0.76, 0.72 }, icon = "SymbolHalt" },
}

local function SetPhase(phase)
    if phase == currentPhase then
        return
    end
    currentPhase = phase
    local look = PHASES[phase]
    bar:SetStatusBarColor(unpack(look.glow))
    core:SetStatusBarColor(unpack(look.core))
    if look.icon then
        symbol:SetTexture(TEXTURE_PATH .. look.icon)
        symbol:SetVertexColor(unpack(look.iconColor or look.glow))
        symbol:Show()
    else
        symbol:Hide()
    end
end

local function SetProgress(value)
    bar:SetValue(value)
    core:SetValue(value)
end

-- Counter fuer perfekte Schuesse in Folge, sichtbar erst ab STREAK_MIN.
local function SetStreak(count)
    perfectStreak = count
    if count >= STREAK_MIN then
        streakLabel:SetFormattedText("%dx", count)
        streakLabel:Show()
    else
        streakLabel:Hide()
    end
end

-- Versteckt die Leiste, wenn nichts mehr dafuer spricht, sie zu zeigen.
local function HideIfIdle()
    if not autoShotActive and not practiceActive and not barPositioning and not InCombatLockdown() then
        frame:Hide()
    end
end

-- Spielt einen Effektton ueber den Soundeffekt-Kanal, im Menue abschaltbar.
local function PlayEffectSound(name)
    if db.soundsOff then
        return
    end
    -- Eine Datei je Lautstaerkestufe, die volle Stufe hat keinen Zusatz im Namen.
    local level = db.soundLevel or DEFAULT_SOUND_LEVEL
    local suffix = level == 100 and "" or level
    PlaySoundFile(SOUND_PATH .. name .. suffix .. ".ogg", "SFX")
end

-- Leere graue Leiste, Timer aus: Die Zeit beginnt erst mit dem ersten Schuss.
-- OnUpdate laeuft nur, solange der Timer laeuft.
local function ShowIdle()
    frame:SetScript("OnUpdate", nil)
    reloadEnd = nil
    aimStart = nil
    stopLine:Hide()
    perfectLock:Hide()
    SetStreak(0)
    SetProgress(0)
    -- Ohne laufenden Auto Shot passiert nichts, bis der Jaeger angreift.
    label:SetText(autoShotActive and "bereit" or "angreifen")
    SetPhase("idle")
end

-- Ein Schuss-Zyklus hat zwei Phasen. Beim Nachladen darf man frei laufen, danach
-- muss man fuer die Zielzeit stillstehen. Bewegung startet das Zielen neu.
local function OnUpdate()
    local now = GetTime()

    if now < reloadEnd then
        SetProgress(1 - (reloadEnd + RED_WINDOW - now) / duration)
        if now - cycleStartedAt < SHOT_SYMBOL_TIME then
            SetPhase("shot")
        elseif now >= reloadEnd - PERFECT_WINDOW then
            -- Hinweis zum Anhalten, damit man nicht auf den Balken schauen muss
            if not goldAnnounced then
                goldAnnounced = true
                PlayEffectSound("Tick")
            end
            SetPhase("gold")
        else
            SetPhase("run")
        end
        return
    end

    -- Ohne Auto Shot kommt kein Schuss mehr, der Timer endet hier.
    if not autoShotActive and not practiceActive then
        ShowIdle()
        HideIfIdle()
        return
    end

    SetPhase("stand")

    if isMoving then
        aimStart = nil
        aimDisturbed = true
        SetProgress(1 - RED_WINDOW / duration)
        return
    end

    aimStart = aimStart or now
    local remaining = aimStart + RED_WINDOW - now
    if remaining > 0 then
        SetProgress(1 - remaining / duration)
    elseif practiceActive then
        StartCycle(now) -- im Uebungsmodus faellt der Schuss genau hier
    else
        SetProgress(1) -- wartet auf die Meldung des echten Schusses
    end
end

-- Ein Schuss ist gefallen, echt oder im Uebungsmodus simuliert.
function StartCycle(now)
    -- Perfekt: im goldenen Bereich angehalten und bis zum Schuss stehen geblieben.
    if perfectStop and not aimDisturbed then
        SetStreak(perfectStreak + 1)
        if perfectStreak >= STREAK_MIN then
            procText:SetFormattedText("%dx Perfekt!", perfectStreak)
        else
            procText:SetText("Perfekt!")
        end
        procAnimation:Stop()
        procAnimation:Play()
        PlayEffectSound("Proc")
    else
        SetStreak(0)
    end
    perfectStop = false
    perfectLock:Hide()
    aimDisturbed = false
    aimStart = nil
    cycleStartedAt = now
    goldAnnounced = false
    label:SetText("")

    frame:Show()
    if duration then
        reloadEnd = now + duration - RED_WINDOW
        frame:SetScript("OnUpdate", OnUpdate)
    end
end

local function SetDuration(speed)
    duration = speed
    -- Der linke Rand liegt genau dort, wo die Fuellung beim Zielen beginnt.
    local share = math.min(RED_WINDOW / speed, 1)
    windowMark:SetPoint("TOPLEFT", BAR_WIDTH * (1 - share), -2)
    windowMark:SetPoint("BOTTOMRIGHT", -4, 2)
    windowMark:Show()
    -- Goldener Bereich direkt vor dem roten, dort anhalten ist perfekt.
    local perfectStart = math.max(1 - (RED_WINDOW + PERFECT_WINDOW) / speed, 0)
    perfectMark:SetPoint("TOPLEFT", BAR_WIDTH * perfectStart, -2)
    perfectMark:SetPoint("BOTTOMRIGHT", -BAR_WIDTH * share, 2)
    perfectMark:Show()
    perfectLock:SetPoint("TOPLEFT", core, "TOPLEFT", BAR_WIDTH * perfectStart, -2)
    perfectLock:SetPoint("BOTTOMRIGHT", core, "BOTTOMRIGHT", -BAR_WIDTH * share, 2)
    windowEdge:Show()
end

-- Liest das Tempo und meldet, ob das geklappt hat. Im Kampf liefert das Spiel einen
-- gesperrten Wert (secret value), jeder Vergleich damit waere ein Lua-Fehler.
local function ReadSpeed()
    local speed = UnitRangedDamage("player")
    local ok, usable = pcall(function()
        return speed and speed > 0
    end)
    if ok and usable then
        baseSpeed = speed
        SetDuration(speed)
        return true
    end
    return false
end

local function OnSpellSucceeded(_, _, spellID)
    if spellID ~= AUTO_SHOT_SPELL_ID then
        return
    end
    local now = GetTime()

    -- Im Kampf ist das Tempo gesperrt, dort zaehlt der gemessene Schussabstand.
    -- So greift auch Hast, allerdings erst ab dem zweiten Schuss damit.
    if not ReadSpeed() and lastShotTime and not aimDisturbed then
        local measured = now - lastShotTime
        if measured >= RED_WINDOW and measured <= (baseSpeed or MAX_MEASURED_SPEED) + MEASURE_TOLERANCE then
            SetDuration(measured)
        end
    end
    lastShotTime = now
    StartCycle(now)
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

-- Belohnung fuer perfektes Timing: goldener Lichtstoss und aufsteigender Text.
-- Die Animation laeuft von selbst und kostet ausserhalb des Effekts nichts.
local function CreateProcEffect()
    -- Erste Stufe beim Anhalten: Das Gold leuchtet auf und bleibt, die Fuellung
    -- ueberdeckt es nicht mehr. Der kurze Sprung wirkt wie ein Einrasten.
    perfectLock = core:CreateTexture(nil, "OVERLAY", nil, 2)
    perfectLock:SetColorTexture(1, 0.85, 0.35, 1)
    perfectLock:Hide()

    lockAnimation = perfectLock:CreateAnimationGroup()
    local snapOut = lockAnimation:CreateAnimation("Scale")
    snapOut:SetScale(1, 2)
    snapOut:SetDuration(0.06)
    snapOut:SetOrder(1)
    local snapBack = lockAnimation:CreateAnimation("Scale")
    snapBack:SetScale(1, 0.5)
    snapBack:SetDuration(0.1)
    snapBack:SetOrder(2)

    -- Zweite Stufe beim Schuss: der grosse Lichtstoss.
    local burst = core:CreateTexture(nil, "OVERLAY", nil, 2)
    burst:SetTexture(TEXTURE_PATH .. "NeonGlow")
    burst:SetVertexColor(1, 0.82, 0.3)
    burst:SetBlendMode("ADD")
    burst:SetPoint("CENTER")
    burst:SetSize(BAR_WIDTH + 12, BAR_HEIGHT + 22)
    burst:SetAlpha(0)

    local text = core:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("BOTTOM", core, "TOP", 0, 33) -- ueber dem Symbol
    text:SetTextColor(1, 0.85, 0.35)
    text:SetText("Perfekt!")
    text:SetAlpha(0)
    procText = text

    -- Bleibt rechts ueber dem Balken stehen, bis die Serie reisst.
    streakLabel = core:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    streakLabel:SetPoint("BOTTOMRIGHT", core, "TOPRIGHT", 0, 3)
    streakLabel:SetTextColor(1, 0.85, 0.35)
    streakLabel:Hide()

    -- Eine Gruppe je Element, beide werden gemeinsam gestartet.
    local burstGroup = burst:CreateAnimationGroup()
    local flashIn = burstGroup:CreateAnimation("Alpha")
    flashIn:SetFromAlpha(0)
    flashIn:SetToAlpha(1)
    flashIn:SetDuration(0.07)
    flashIn:SetOrder(1)
    local flashOut = burstGroup:CreateAnimation("Alpha")
    flashOut:SetFromAlpha(1)
    flashOut:SetToAlpha(0)
    flashOut:SetDuration(0.45)
    flashOut:SetOrder(2)
    local grow = burstGroup:CreateAnimation("Scale")
    grow:SetScale(1.06, 1.5)
    grow:SetDuration(0.45)
    grow:SetOrder(2)

    local textGroup = text:CreateAnimationGroup()
    local textIn = textGroup:CreateAnimation("Alpha")
    textIn:SetFromAlpha(0)
    textIn:SetToAlpha(1)
    textIn:SetDuration(0.08)
    textIn:SetOrder(1)
    local textOut = textGroup:CreateAnimation("Alpha")
    textOut:SetFromAlpha(1)
    textOut:SetToAlpha(0)
    textOut:SetStartDelay(0.3)
    textOut:SetDuration(0.4)
    textOut:SetOrder(2)
    local rise = textGroup:CreateAnimation("Translation")
    rise:SetOffset(0, 14)
    rise:SetDuration(0.7)
    rise:SetOrder(2)

    procAnimation = {
        Stop = function()
            burstGroup:Stop()
            textGroup:Stop()
        end,
        Play = function()
            burstGroup:Play()
            textGroup:Play()
        end,
    }
end

-- Meldung "Zu nah!": Die Fehlermeldung des Spiels loest sie aus, danach bleibt sie, bis
-- Auto Shot das Ziel wieder erreicht. Die Reichweite allein unterscheidet nicht zwischen
-- zu nah und zu weit, die Reichweite von Raptorstoss meldete im Test immer true.
local RANGE_CHECK_INTERVAL = 0.2
local TOO_CLOSE_HOLD = 0.5 -- Mindestdauer, die Reichweite springt erst kurz nach dem Fehler um
local rangeText
local tooClose = false
local tooCloseUntil = 0
local rangeCheckElapsed = 0

local function SafeText(value)
    local ok, text = pcall(table.concat, { tostring(value) })
    return ok and text or "gesperrt"
end

local function SpellName(spellID)
    if GetSpellInfo then
        return (GetSpellInfo(spellID))
    end
    return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
end

local function SpellRange(spellID)
    local name = SpellName(spellID)
    if IsSpellInRange then
        return IsSpellInRange(name, "target")
    end
    return C_Spell and C_Spell.IsSpellInRange and C_Spell.IsSpellInRange(name, "target")
end

-- pcall, damit ein gesperrter Wert nur "keine Meldung" bedeutet statt eines Fehlers.
-- Ohne Ziel kommt nil zurueck, dann gilt die Meldung ebenfalls nicht mehr.
local function AutoShotOutOfRange()
    local ok, result = pcall(function()
        local inRange = SpellRange(AUTO_SHOT_SPELL_ID)
        return inRange == false or inRange == 0
    end)
    return ok and result
end

local function CheckRange(_, elapsed)
    if not tooClose then
        return
    end
    rangeCheckElapsed = rangeCheckElapsed + elapsed
    if rangeCheckElapsed < RANGE_CHECK_INTERVAL then
        return
    end
    rangeCheckElapsed = 0

    if GetTime() >= tooCloseUntil and not AutoShotOutOfRange() then
        tooClose = false
        rangeText:Hide()
    end
end

local function OnErrorMessage(_, message)
    local text = SafeText(message)
    -- Der Vergleichstext steht zusaetzlich hier, belegt ist bisher nur der deutsche Wortlaut.
    if text == SPELL_FAILED_TOO_CLOSE or text:find("zu nah", 1, true) then
        tooClose = true
        tooCloseUntil = GetTime() + TOO_CLOSE_HOLD
        rangeText:Show()
    end
end

local function CreateBar()
    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(BAR_WIDTH, BAR_HEIGHT)
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or DEFAULT_Y)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    -- Neon: dunkles Glas hinten, darauf Leuchten und heller Kern als zwei Balken.
    -- Nur so bleibt die Mitte fast weiss, waehrend das Leuchten die Farbe traegt.
    local glass = frame:CreateTexture(nil, "BACKGROUND")
    glass:SetTexture(TEXTURE_PATH .. "NeonTrack")
    glass:SetAllPoints()

    bar = CreateFrame("StatusBar", nil, frame)
    bar:SetAllPoints()
    bar:SetStatusBarTexture(TEXTURE_PATH .. "NeonGlow")
    bar:GetStatusBarTexture():SetBlendMode("ADD")
    bar:SetMinMaxValues(0, 1)

    core = CreateFrame("StatusBar", nil, bar)
    core:SetAllPoints()
    core:SetStatusBarTexture(TEXTURE_PATH .. "NeonCore")
    core:SetMinMaxValues(0, 1)

    -- Roter Bereich am rechten Ende, liegt ueber dem Leuchten und unter dem Kern.
    windowMark = bar:CreateTexture(nil, "OVERLAY", nil, -1)
    windowMark:SetColorTexture(1, 0.24, 0.18, 0.2)
    windowMark:Hide()

    perfectMark = bar:CreateTexture(nil, "OVERLAY", nil, -1)
    perfectMark:SetColorTexture(1, 0.8, 0.25, 0.55)
    perfectMark:Hide()

    -- Feine Linie am Beginn des roten Bereichs.
    windowEdge = bar:CreateTexture(nil, "OVERLAY")
    windowEdge:SetColorTexture(1, 0.6, 0.53, 0.85)
    windowEdge:SetWidth(1)
    windowEdge:SetPoint("TOPRIGHT", windowMark, "TOPLEFT", 0, -1)
    windowEdge:SetPoint("BOTTOMRIGHT", windowMark, "BOTTOMLEFT", 0, 1)
    windowEdge:Hide()

    -- Grosses Symbol ueber dem Balken. Text gibt es nur vor dem ersten Schuss.
    label = core:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("BOTTOM", core, "TOP", 0, 4)

    symbol = core:CreateTexture(nil, "OVERLAY")
    symbol:SetSize(28, 28)
    symbol:SetPoint("BOTTOM", core, "TOP", 0, 3)
    symbol:Hide()

    -- Warnung direkt unter dem Balken. Eigener Rahmen, denn wer aus dem Nahkampf angreift,
    -- hat noch keinen Schuss und damit auch keine sichtbare Leiste.
    local rangeFrame = CreateFrame("Frame", nil, UIParent)
    rangeFrame:SetSize(1, 1)
    rangeFrame:SetPoint("TOP", frame, "BOTTOM", 0, -3)
    rangeFrame:SetScript("OnUpdate", CheckRange)

    rangeText = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rangeText:SetPoint("TOP")
    rangeText:SetTextColor(1, 0.25, 0.2)
    rangeText:SetText("Zu nah!")
    rangeText:Hide()

    -- Senkrechte Linie: Dort stand die Zeit, als der Jaeger zuletzt angehalten hat.
    stopLine = core:CreateTexture(nil, "OVERLAY", nil, 3)
    stopLine:SetColorTexture(1, 1, 1, 1)
    stopLine:SetSize(2, BAR_HEIGHT + 6)
    stopLine:Hide()

    CreateProcEffect()

    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() then
            dragging = true
            self:StartMoving()
        end
    end)
    frame:SetScript("OnMouseUp", StopDragging)
    frame:SetScript("OnHide", StopDragging)

    ShowIdle()
    frame:Hide()
end

function AutoShot:Init(moduleDB)
    db = moduleDB
    db.rangeLog = nil -- Rest der Reichweiten-Messung
    CreateBar()

    HF:On("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded, "player")
    HF:On("UNIT_RANGEDDAMAGE", ReadSpeed, "player")
    HF:On("PLAYER_ENTERING_WORLD", ReadSpeed)
    HF:On("UI_ERROR_MESSAGE", OnErrorMessage)

    HF:On("PLAYER_STARTED_MOVING", function()
        isMoving = true
        perfectStop = false
        perfectLock:Hide()
    end)
    HF:On("PLAYER_STOPPED_MOVING", function()
        isMoving = false
        local now = GetTime()
        perfectStop = reloadEnd ~= nil and now >= reloadEnd - PERFECT_WINDOW and now <= reloadEnd
        if perfectStop then
            perfectLock:Show()
            lockAnimation:Stop()
            lockAnimation:Play()
            PlayEffectSound("Lock")
        end
        if reloadEnd then
            -- Die Linie zeigt die echte Zeit im Zyklus, auch wenn der Balken im Roten wartet.
            local cycleStart = reloadEnd + RED_WINDOW - duration
            local position = math.min((now - cycleStart) / duration, 1)
            stopLine:ClearAllPoints()
            stopLine:SetPoint("CENTER", core, "LEFT", BAR_WIDTH * position, 0)
            stopLine:Show()
        end
    end)

    -- Sobald es ernst wird, endet der Uebungsmodus von selbst.
    HF:On("PLAYER_REGEN_DISABLED", function()
        if practiceActive then
            AutoShot:SetPractice(false)
        end
    end)

    HF:On("START_AUTOREPEAT_SPELL", function()
        if practiceActive then
            AutoShot:SetPractice(false)
        end
        autoShotActive = true
        lastShotTime = nil
        ReadSpeed()
        -- Die Leiste erscheint erst mit dem ersten Schuss, bis dahin passiert nichts.
        if not reloadEnd then
            label:SetText("bereit")
        end
    end)

    -- Kommt STOP erst nach dem Kampfende, fiele die Leiste sonst nie mehr weg.
    HF:On("STOP_AUTOREPEAT_SPELL", function()
        autoShotActive = false
        if not reloadEnd then
            ShowIdle() -- schaltet den Text zurueck auf "angreifen"
        end
        HideIfIdle()
    end)

    HF:On("PLAYER_REGEN_ENABLED", function()
        ReadSpeed()
        HideIfIdle()
    end)

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

-- Uebungsmodus: Die Leiste laeuft ohne Ziel weiter, Schuesse fallen nach der Zielzeit.
-- Gemessen wird nur das Timing.
function AutoShot:SetPractice(enabled)
    practiceActive = enabled
    if enabled then
        ReadSpeed()
        if not duration then
            SetDuration(PRACTICE_SPEED)
        end
        StartCycle(GetTime())
    else
        ShowIdle()
        HideIfIdle()
    end
end

function AutoShot:IsPracticing()
    return practiceActive
end

function AutoShot:SetSoundsEnabled(enabled)
    db.soundsOff = not enabled
end

function AutoShot:AreSoundsEnabled()
    return not db.soundsOff
end

function AutoShot:GetSoundLevel()
    return db.soundLevel or DEFAULT_SOUND_LEVEL
end

-- Spielt den Ton gleich in der neuen Lautstaerke, damit man sie direkt hoert.
function AutoShot:SetSoundLevel(level)
    db.soundLevel = level
    PlayEffectSound("Proc")
end

HF:RegisterModule("autoShot", AutoShot)

--------------------------------------------------------------------------------
-- Modul: Minimap-Knopf und Menue
--------------------------------------------------------------------------------

-- Runde Klassensymbole des Spiels, der Jaeger liegt in diesem Ausschnitt.
local HUNTER_ICON = "Interface\\TargetingFrame\\UI-Classes-Circles"
local HUNTER_ICON_LEFT, HUNTER_ICON_RIGHT, HUNTER_ICON_TOP, HUNTER_ICON_BOTTOM = 0, 0.25, 0.25, 0.5
local DEFAULT_MINIMAP_ANGLE = 0 -- 0 Grad liegt rechts an der Minimap

local Menu = {}
local menuDB, minimapButton, menuFrame

-- Das Menue nutzt die Fenster-Vorlagen des Spiels, wie das GamerVibes-Add-on.
local SOUND_LEVEL_MIN, SOUND_LEVEL_MAX, SOUND_LEVEL_STEP = 25, 100, 25

local function CreateSectionTitle(text, y)
    local title = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, y)
    title:SetText(text)
end

local function CreateMenu()
    -- Vorlage aus der modernen Oberflaeche. Fehlt sie im Client, ein
    -- schlichtes Fenster mit Rahmen als Rueckfall.
    local ok, window = pcall(CreateFrame, "Frame", "HunterFlowMenu", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        window = CreateFrame("Frame", "HunterFlowMenu", UIParent, "BackdropTemplate")
        window:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        local close = CreateFrame("Button", "HunterFlowMenuClose", window, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    menuFrame = window
    menuFrame:SetSize(300, 214)
    menuFrame:SetPoint("CENTER")
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetMovable(true)
    menuFrame:SetClampedToScreen(true)
    menuFrame:EnableMouse(true)
    menuFrame:RegisterForDrag("LeftButton")
    menuFrame:SetScript("OnDragStart", menuFrame.StartMoving)
    menuFrame:SetScript("OnDragStop", menuFrame.StopMovingOrSizing)
    menuFrame:Hide()
    table.insert(UISpecialFrames, "HunterFlowMenu") -- schliesst mit Escape

    -- Titel in der Kopfleiste der Vorlage, sonst oben mittig im Fenster
    if menuFrame.TitleText then
        menuFrame.TitleText:SetText("HunterFlow")
    else
        local title = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -8)
        title:SetText("HunterFlow")
    end

    -- Bereich Leiste
    CreateSectionTitle("Leiste", -34)

    local hint = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 16, -52)
    hint:SetText("Mit Shift und linker Maustaste verschieben")

    -- Der Knopf schliesst das Menue, damit beim Ueben nichts im Bild steht.
    local practiceButton = CreateFrame("Button", "HunterFlowMenuPractice", menuFrame, "UIPanelButtonTemplate")
    practiceButton:SetSize(200, 22)
    practiceButton:SetPoint("TOP", 0, -68)
    practiceButton:SetScript("OnClick", function(self)
        local start = not AutoShot:IsPracticing()
        AutoShot:SetPractice(start)
        if start then
            HF:Print("Übungsmodus läuft. Im Grünen laufen, im Gold anhalten. Beenden über das Menü.")
            menuFrame:Hide()
        else
            self:SetText("Übungsmodus starten")
        end
    end)
    practiceButton:SetText("Übungsmodus starten")

    -- Bereich Toene
    CreateSectionTitle("Töne", -98)

    local soundCheck = CreateFrame("CheckButton", "HunterFlowMenuSounds", menuFrame, "UICheckButtonTemplate")
    soundCheck:SetPoint("TOPLEFT", 12, -112)
    soundCheck:SetScript("OnClick", function(self)
        AutoShot:SetSoundsEnabled(self:GetChecked() and true or false)
    end)

    local soundLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    soundLabel:SetPoint("LEFT", soundCheck, "RIGHT", 2, 1)
    soundLabel:SetText("Töne bei perfektem Timing")

    -- Regler in Stufen, WoW kann eigenen Toenen keine freie Lautstaerke mitgeben.
    local sliderName = "HunterFlowMenuVolume"
    local volume = CreateFrame("Slider", sliderName, menuFrame, "OptionsSliderTemplate")
    volume:SetPoint("TOPLEFT", 20, -160)
    volume:SetWidth(260)
    volume:SetMinMaxValues(SOUND_LEVEL_MIN, SOUND_LEVEL_MAX)
    volume:SetValueStep(SOUND_LEVEL_STEP)
    if volume.SetObeyStepOnDrag then
        volume:SetObeyStepOnDrag(true)
    end
    _G[sliderName .. "Low"]:SetText(SOUND_LEVEL_MIN .. " %")
    _G[sliderName .. "High"]:SetText(SOUND_LEVEL_MAX .. " %")

    local function ShowVolumeText(level)
        _G[sliderName .. "Text"]:SetText("Lautstärke: " .. level .. " %")
    end

    -- Beim Oeffnen setzt der Code den Wert selbst, dann soll kein Probeton erklingen.
    local refreshing = false
    volume:SetScript("OnValueChanged", function(_, value)
        local level = math.floor(value / SOUND_LEVEL_STEP + 0.5) * SOUND_LEVEL_STEP
        ShowVolumeText(level)
        if not refreshing and level ~= AutoShot:GetSoundLevel() then
            AutoShot:SetSoundLevel(level)
        end
    end)

    -- Solange das Menue offen ist, steht die Leiste zum Verschieben bereit.
    -- Erst nach dem Hide oben setzen, sonst liefe OnHide schon beim Aufbau.
    menuFrame:SetScript("OnShow", function()
        HF:SetPositioning(true)
        practiceButton:SetText(AutoShot:IsPracticing() and "Übungsmodus beenden" or "Übungsmodus starten")
        soundCheck:SetChecked(AutoShot:AreSoundsEnabled())
        refreshing = true
        volume:SetValue(AutoShot:GetSoundLevel())
        ShowVolumeText(AutoShot:GetSoundLevel())
        refreshing = false
    end)
    menuFrame:SetScript("OnHide", function()
        HF:SetPositioning(false)
    end)
end

-- Setzt den Knopf auf den Ring der Minimap.
local function PlaceMinimapButton()
    local angle = math.rad(menuDB.minimapAngle or DEFAULT_MINIMAP_ANGLE)
    local radius = Minimap:GetWidth() / 2 + 10
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function FollowCursor()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    menuDB.minimapAngle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX))
    PlaceMinimapButton()
end

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "HunterFlowMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(HUNTER_ICON)
    icon:SetTexCoord(HUNTER_ICON_LEFT, HUNTER_ICON_RIGHT, HUNTER_ICON_TOP, HUNTER_ICON_BOTTOM)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 8, -7.15) -- gleiche Masse wie der GamerVibes-Knopf

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    minimapButton:SetScript("OnClick", function()
        menuFrame:SetShown(not menuFrame:IsShown())
    end)

    minimapButton:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", FollowCursor)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("HunterFlow")
        GameTooltip:AddDoubleLine("Linksklick", "Menü", 0.67, 0.83, 0.45, 1, 1, 1)
        GameTooltip:AddDoubleLine("Ziehen", "Knopf verschieben", 0.67, 0.83, 0.45, 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    PlaceMinimapButton()
end

function Menu:Init(moduleDB)
    menuDB = moduleDB
    CreateMenu()
    CreateMinimapButton()
end

HF:RegisterModule("menu", Menu)
