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
-- Zeitfenster nach dem Schuss, in dem ein Treffer als Einschlag des Pfeils zaehlt.
-- Das Spiel nennt den Verursacher nicht, ein Begleiter kann also mit ausloesen.
local HIT_WINDOW_MIN, HIT_WINDOW_MAX = 0.15, 1.3
local PRACTICE_SPEED = 2.5 -- Tempo im Uebungsmodus, falls keine Waffe lesbar ist
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
local hitFlashAnimation
local awaitingHitSince -- Zeitpunkt des Schusses, dessen Einschlag noch aussteht
local practiceActive = false -- Uebungsmodus: Schuesse werden nur simuliert
local StartCycle -- beginnt einen neuen Schuss-Zyklus, unten definiert
local duration -- Zeit von Schuss zu Schuss in Sekunden, gelesen oder gemessen
local baseSpeed -- zuletzt vom Spiel gelesenes Tempo, nur ausserhalb des Kampfes lesbar
local reloadEnd -- Ende des Nachladens, nil wenn der Timer nicht laeuft
local aimStart -- Beginn des Stillstands beim Zielen, nil solange nicht gezielt wird
local aimDisturbed = false -- Bewegung hat das Zielen verzoegert, Abstand nicht messen
local lastShotTime
local isMoving = false
local autoShotActive = false
local barPositioning = false
local dragging = false
local currentPhase -- letzte gesetzte Phase, spart unnoetige Aufrufe

-- Farben fuer Leuchten und Kern. Der Kern bleibt fast weiss, das wirkt wie Neon.
local PHASES = {
    run = { glow = { 0.25, 0.92, 0.42 }, core = { 0.77, 1, 0.82 }, icon = "SymbolRun" },
    stand = { glow = { 1, 0.29, 0.22 }, core = { 1, 0.76, 0.72 }, icon = "SymbolHalt" },
    ready = { glow = { 0.25, 0.92, 0.42 }, core = { 0.77, 1, 0.82 } },
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
        symbol:SetVertexColor(unpack(look.glow))
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

-- Volle Leiste, Timer aus. OnUpdate laeuft nur, solange der Timer laeuft.
local function ShowReady()
    frame:SetScript("OnUpdate", nil)
    reloadEnd = nil
    aimStart = nil
    stopLine:Hide()
    perfectLock:Hide()
    SetStreak(0)
    SetProgress(1)
    -- Ohne laufenden Auto Shot passiert nichts, bis der Jaeger angreift.
    label:SetText(autoShotActive and "bereit" or "angreifen")
    SetPhase("ready")
end

-- Ein Schuss-Zyklus hat zwei Phasen. Beim Nachladen darf man frei laufen, danach
-- muss man fuer die Zielzeit stillstehen. Bewegung startet das Zielen neu.
local function OnUpdate()
    local now = GetTime()

    if now < reloadEnd then
        local remaining = reloadEnd + RED_WINDOW - now
        SetProgress(1 - remaining / duration)
        label:SetFormattedText("laufen %.1f", remaining)
        SetPhase("run")
        return
    end

    -- Ohne Auto Shot kommt kein Schuss mehr, der Timer endet hier.
    if not autoShotActive and not practiceActive then
        ShowReady()
        HideIfIdle()
        return
    end

    if isMoving then
        aimStart = nil
        aimDisturbed = true
        SetProgress(1 - RED_WINDOW / duration)
        label:SetText("stehen")
        SetPhase("stand")
        return
    end

    aimStart = aimStart or now
    local remaining = aimStart + RED_WINDOW - now
    if remaining > 0 then
        SetProgress(1 - remaining / duration)
        label:SetFormattedText("stehen %.1f", remaining)
        SetPhase("stand")
    elseif practiceActive then
        StartCycle(now) -- im Uebungsmodus faellt der Schuss genau hier
    else
        SetProgress(1)
        label:SetText("bereit")
        SetPhase("ready")
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
    awaitingHitSince = now

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

-- Der erste Treffer am Ziel im Zeitfenster loest einen Blitz aus, einmal je Schuss.
-- pcall, falls das Spiel die Art des Treffers an manchen Orten ebenfalls sperrt.
local function OnTargetCombat(_, action)
    if not awaitingHitSince then
        return
    end
    local elapsed = GetTime() - awaitingHitSince
    if elapsed > HIT_WINDOW_MAX then
        awaitingHitSince = nil
    elseif elapsed >= HIT_WINDOW_MIN then
        local ok, isHit = pcall(function()
            return action == "WOUND"
        end)
        if ok and isHit then
            awaitingHitSince = nil
            hitFlashAnimation:Stop()
            hitFlashAnimation:Play()
        end
    end
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
    text:SetPoint("BOTTOM", label, "TOP", -9, 3)
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

-- Kurzer weisser Blitz beim Einschlag, bewusst kleiner als der goldene Lichtstoss.
local function CreateHitFlash()
    local flash = core:CreateTexture(nil, "OVERLAY", nil, 1)
    flash:SetTexture(TEXTURE_PATH .. "NeonGlow")
    flash:SetBlendMode("ADD")
    flash:SetAllPoints()
    flash:SetAlpha(0)

    hitFlashAnimation = flash:CreateAnimationGroup()
    local flashIn = hitFlashAnimation:CreateAnimation("Alpha")
    flashIn:SetFromAlpha(0)
    flashIn:SetToAlpha(1)
    flashIn:SetDuration(0.04)
    flashIn:SetOrder(1)
    local flashOut = hitFlashAnimation:CreateAnimation("Alpha")
    flashOut:SetFromAlpha(1)
    flashOut:SetToAlpha(0)
    flashOut:SetDuration(0.2)
    flashOut:SetOrder(2)
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

    -- Symbol und Text ueber dem Balken, so verdecken sie die Fuellung nicht.
    -- Der Text sitzt etwas rechts der Mitte, damit beide zusammen mittig wirken.
    label = core:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("BOTTOM", core, "TOP", 9, 3)

    symbol = core:CreateTexture(nil, "OVERLAY")
    symbol:SetSize(18, 18)
    symbol:SetPoint("RIGHT", label, "LEFT", -3, 0)
    symbol:Hide()

    -- Senkrechte Linie: Dort stand die Zeit, als der Jaeger zuletzt angehalten hat.
    stopLine = core:CreateTexture(nil, "OVERLAY", nil, 3)
    stopLine:SetColorTexture(1, 1, 1, 1)
    stopLine:SetSize(2, BAR_HEIGHT + 6)
    stopLine:Hide()

    CreateProcEffect()
    CreateHitFlash()

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
    HF:On("UNIT_COMBAT", OnTargetCombat, "target")
    HF:On("UNIT_RANGEDDAMAGE", ReadSpeed, "player")
    HF:On("PLAYER_ENTERING_WORLD", ReadSpeed)

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
        if not reloadEnd then
            label:SetText("bereit")
        end
        frame:Show()
    end)

    -- Kommt STOP erst nach dem Kampfende, fiele die Leiste sonst nie mehr weg.
    HF:On("STOP_AUTOREPEAT_SPELL", function()
        autoShotActive = false
        if not reloadEnd then
            ShowReady() -- schaltet den Text zurueck auf "angreifen"
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
-- Gemessen wird nur das Timing, der Treffer-Blitz bleibt aus.
function AutoShot:SetPractice(enabled)
    practiceActive = enabled
    if enabled then
        ReadSpeed()
        if not duration then
            SetDuration(PRACTICE_SPEED)
        end
        StartCycle(GetTime())
    else
        ShowReady()
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

-- Farben des Neon-Glas-Menues, passend zum Balken.
local MENU_ACCENT = { 0.43, 0.96, 0.6 }
local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8x8"
local SOUND_LEVELS = { 25, 50, 75, 100 }

local function SetGlassLook(target, red, green, blue, fillAlpha, edgeAlpha)
    target:SetBackdrop({ bgFile = WHITE_TEXTURE, edgeFile = WHITE_TEXTURE, edgeSize = 1 })
    target:SetBackdropColor(red, green, blue, fillAlpha)
    target:SetBackdropBorderColor(red, green, blue, edgeAlpha)
end

local function CreateNeonButton(name, width, height)
    local button = CreateFrame("Button", name, menuFrame, "BackdropTemplate")
    button:SetSize(width, height)
    SetGlassLook(button, MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 0.14, 0.8)
    button:SetNormalFontObject(GameFontHighlight)
    button:SetHighlightTexture(WHITE_TEXTURE)
    button:GetHighlightTexture():SetVertexColor(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 0.2)
    return button
end

local function CreateSectionTitle(text, y)
    local title = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 14, y)
    title:SetTextColor(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3])
    title:SetText(text)
end

local function CreateMenu()
    menuFrame = CreateFrame("Frame", "HunterFlowMenu", UIParent, "BackdropTemplate")
    menuFrame:SetSize(300, 196)
    menuFrame:SetPoint("CENTER")
    menuFrame:SetFrameStrata("DIALOG")
    menuFrame:SetBackdrop({ bgFile = WHITE_TEXTURE, edgeFile = WHITE_TEXTURE, edgeSize = 1 })
    menuFrame:SetBackdropColor(0.035, 0.06, 0.055, 0.9)
    menuFrame:SetBackdropBorderColor(1, 1, 1, 0.28)
    menuFrame:SetMovable(true)
    menuFrame:SetClampedToScreen(true)
    menuFrame:EnableMouse(true)
    menuFrame:RegisterForDrag("LeftButton")
    menuFrame:SetScript("OnDragStart", menuFrame.StartMoving)
    menuFrame:SetScript("OnDragStop", menuFrame.StopMovingOrSizing)
    menuFrame:Hide()
    table.insert(UISpecialFrames, "HunterFlowMenu") -- schliesst mit Escape

    -- Kopf: Jaeger-Symbol, Name und Schliessen, darunter die leuchtende Linie
    local icon = menuFrame:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(HUNTER_ICON)
    icon:SetTexCoord(HUNTER_ICON_LEFT, HUNTER_ICON_RIGHT, HUNTER_ICON_TOP, HUNTER_ICON_BOTTOM)
    icon:SetSize(26, 26)
    icon:SetPoint("TOPLEFT", 14, -12)

    local title = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("HunterFlow")

    local close = CreateNeonButton("HunterFlowMenuClose", 20, 20)
    close:SetPoint("TOPRIGHT", -12, -14)
    SetGlassLook(close, 1, 1, 1, 0.04, 0.3)
    close:SetText("x")
    close:SetScript("OnClick", function()
        menuFrame:Hide()
    end)

    local headLine = menuFrame:CreateTexture(nil, "ARTWORK")
    headLine:SetColorTexture(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 0.8)
    headLine:SetPoint("TOPLEFT", 14, -44)
    headLine:SetPoint("TOPRIGHT", -14, -44)
    headLine:SetHeight(1)

    local headGlow = menuFrame:CreateTexture(nil, "ARTWORK")
    headGlow:SetColorTexture(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 0.14)
    headGlow:SetPoint("TOPLEFT", headLine, "BOTTOMLEFT")
    headGlow:SetPoint("TOPRIGHT", headLine, "BOTTOMRIGHT")
    headGlow:SetHeight(3)

    -- Bereich Leiste
    CreateSectionTitle("LEISTE", -54)

    local hint = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 14, -69)
    hint:SetText("Mit Shift und linker Maustaste verschieben")

    -- Der Knopf schliesst das Menue, damit beim Ueben nichts im Bild steht.
    local practiceButton = CreateNeonButton("HunterFlowMenuPractice", 272, 24)
    practiceButton:SetPoint("TOP", 0, -85)
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
    CreateSectionTitle("TÖNE", -118)

    local soundCheck = CreateFrame("CheckButton", "HunterFlowMenuSounds", menuFrame, "BackdropTemplate")
    soundCheck:SetSize(15, 15)
    soundCheck:SetPoint("TOPLEFT", 14, -134)
    SetGlassLook(soundCheck, MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 0.14, 0.8)
    soundCheck:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    soundCheck:GetCheckedTexture():SetVertexColor(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3])
    soundCheck:SetScript("OnClick", function(self)
        AutoShot:SetSoundsEnabled(self:GetChecked())
    end)

    local soundLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    soundLabel:SetPoint("LEFT", soundCheck, "RIGHT", 7, 0)
    soundLabel:SetText("Töne bei perfektem Timing")

    local volumeLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    volumeLabel:SetPoint("TOPLEFT", 14, -160)
    volumeLabel:SetText("Lautstärke")

    local volumeValue = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    volumeValue:SetPoint("TOPRIGHT", -14, -160)

    -- Vier anklickbare Stufen statt eines Reglers, mehr kann WoW bei eigenen Toenen nicht.
    local segments = {}
    local function UpdateVolume()
        local level = AutoShot:GetSoundLevel()
        volumeValue:SetFormattedText("%d %%", level)
        for index, segment in ipairs(segments) do
            if SOUND_LEVELS[index] <= level then
                segment.fill:SetColorTexture(MENU_ACCENT[1], MENU_ACCENT[2], MENU_ACCENT[3], 1)
            else
                segment.fill:SetColorTexture(1, 1, 1, 0.15)
            end
        end
    end

    for index, level in ipairs(SOUND_LEVELS) do
        local segment = CreateFrame("Button", nil, menuFrame)
        segment:SetSize(34, 14) -- etwas hoeher als der Balken, das trifft sich leichter
        segment:SetPoint("TOPLEFT", 86 + (index - 1) * 37, -158)
        segment.fill = segment:CreateTexture(nil, "ARTWORK")
        segment.fill:SetPoint("LEFT")
        segment.fill:SetPoint("RIGHT")
        segment.fill:SetHeight(8)
        segment:SetScript("OnClick", function()
            AutoShot:SetSoundLevel(level)
            UpdateVolume()
        end)
        segments[index] = segment
    end

    -- Solange das Menue offen ist, steht die Leiste zum Verschieben bereit.
    -- Erst nach dem Hide oben setzen, sonst liefe OnHide schon beim Aufbau.
    menuFrame:SetScript("OnShow", function()
        HF:SetPositioning(true)
        practiceButton:SetText(AutoShot:IsPracticing() and "Übungsmodus beenden" or "Übungsmodus starten")
        soundCheck:SetChecked(AutoShot:AreSoundsEnabled())
        UpdateVolume()
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
