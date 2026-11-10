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

-- Texte der Oberflaeche. Englisch ist der Standard, deutsche Clients bekommen Deutsch.
local L = {
    shown = "Bar shown. Hold Shift and drag with the left mouse button to move it, /hflow hides it again.",
    positioningDone = "Positioning finished.",
    attack = "attack",
    stop = "stop",
    aimInterrupted = "Aim interrupted",
    tooClose = "Too close!",
    tooFar = "Too far away!",
    showRange = '"Too close" / "Too far" message',
    perfect = "Perfect!",
    perfectStreak = "%dx Perfect!",
    sectionBar = "Bar",
    moveHint = "Hold Shift and drag with the left mouse button to move it",
    practiceStart = "Start practice mode",
    practiceStop = "End practice mode",
    practiceRunning = "Practice mode running. Move on green, stop on gold. End it from the menu.",
    sectionSounds = "Sounds",
    soundsOnPerfect = "Sounds on",
    volume = "Volume: %d %%",
    leftClick = "Left click",
    menu = "Menu",
    drag = "Drag",
    moveButton = "Move button",
}
if GetLocale() == "deDE" then
    L.shown = "Leiste eingeblendet. Mit Shift und linker Maustaste verschieben, /hflow blendet sie wieder aus."
    L.positioningDone = "Positionieren beendet."
    L.attack = "angreifen"
    L.stop = "anhalten"
    L.aimInterrupted = "Zielen unterbrochen"
    L.tooClose = "Zu nah!"
    L.tooFar = "Zu weit entfernt!"
    L.showRange = 'Meldung "Zu nah" / "Zu weit"'
    L.perfect = "Perfekt!"
    L.perfectStreak = "%dx Perfekt!"
    L.sectionBar = "Leiste"
    L.moveHint = "Mit Shift und linker Maustaste verschieben"
    L.practiceStart = "Übungsmodus starten"
    L.practiceStop = "Übungsmodus beenden"
    L.practiceRunning = "Übungsmodus läuft. Im Grünen laufen, im Gold anhalten. Beenden über das Menü."
    L.sectionSounds = "Töne"
    L.soundsOnPerfect = "Töne an"
    L.volume = "Lautstärke: %d %%"
    L.leftClick = "Linksklick"
    L.menu = "Menü"
    L.drag = "Ziehen"
    L.moveButton = "Knopf verschieben"
end

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
    HunterFlowDB.rangeProbe = nil -- Reichweiten-Messung vom 10.11.2026, ausgewertet
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
        HF:Print(L.shown)
    else
        HF:Print(L.positioningDone)
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
local AIM_WIDTH, BAR_GAP = 40, 4 -- links das Zielfeld, rechts daneben die Nachladeleiste
local RELOAD_WIDTH = BAR_WIDTH - AIM_WIDTH - BAR_GAP
local ABORT_TIME = 0.9 -- so lange laeuft die Anzeige "Zielen unterbrochen"
local DEFAULT_Y = -150 -- etwas unterhalb der Bildschirmmitte
local DRAG_EXTRA_TOP = 34 -- Symbol ueber der Leiste (28 hoch, 3 Abstand) plus etwas Rand
local DRAG_EXTRA_BOTTOM = 22 -- Hinweistext unter der Leiste
local TEXTURE_PATH = "Interface\\AddOns\\HunterFlow\\Textures\\"
local SOUND_PATH = "Interface\\AddOns\\HunterFlow\\Sounds\\"
local DEFAULT_SOUND_LEVEL = 75 -- Prozent, moeglich sind 25, 50, 75 und 100

local AutoShot = {}
local db, frame, content, bar, core, perfectMark, stopLine, symbol, label, procAnimation
local aimBar, aimCore, aimFlash -- Zielfeld links, dort steht der Jaeger bis zum Schuss
local hintText, shotAnimation, rangeText
local abortAt, abortFrom -- Beginn und Fuellstand eines unterbrochenen Zielens
local reloadTime -- Nachladezeit, also Tempo minus Zielzeit
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
local outOfRange = false -- zu nah oder zu weit, Leiste und Symbole sind dann ausgeblendet
local rangeDisturbed = false -- seit dem letzten Schuss ausser Reichweite gewesen

-- Der ganze Balken traegt die Farbe der Phase, das liest man auch im Augenwinkel.
-- Der Kern bleibt fast weiss, das wirkt wie Neon.
local PHASES = {
    idle = { glow = { 0.55, 0.6, 0.57 }, core = { 0.78, 0.82, 0.8 } },
    shot = { glow = { 0.3, 0.7, 1 }, core = { 0.82, 0.93, 1 }, icon = "SymbolBow", iconColor = { 0.3, 0.7, 1 } },
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

-- Fuellung der Nachladeleiste.
local function SetProgress(value)
    bar:SetValue(value)
    core:SetValue(value)
end

-- Fuellung des Zielfelds, rot beim Zielen, grau beim Auslaufen nach einem Abbruch.
local AIM_LOOK = { glow = { 1, 0.29, 0.22 }, core = { 1, 0.76, 0.72 } }
local AIM_FADED = { glow = { 0.43, 0.35, 0.34 }, core = { 0.66, 0.58, 0.56 } }

local function SetAim(value, faded)
    local look = faded and AIM_FADED or AIM_LOOK
    aimBar:SetStatusBarColor(unpack(look.glow))
    aimCore:SetStatusBarColor(unpack(look.core))
    aimBar:SetValue(value)
    aimCore:SetValue(value)
end

-- Hinweis unter der Leiste. "Zu nah!" steht an derselben Stelle und hat Vorrang.
local HINT_ABORT = { 1, 0.54, 0.48 }
local HINT_STOP = { 1, 0.7, 0.66 }

local function SetHint(text, alpha, color)
    if text and not rangeText:IsShown() then
        hintText:SetText(text)
        hintText:SetTextColor(unpack(color))
        hintText:SetAlpha(alpha)
        hintText:Show()
    else
        hintText:Hide()
    end
end

-- Zielen unterbrochen: Die Leiste wackelt, das Zielfeld blinkt rot und laeuft grau aus.
-- Auto Shot bleibt dabei an, das Zielen beginnt neu, sobald der Jaeger wieder steht.
local function StopAbort()
    abortAt = nil
    aimFlash:SetAlpha(0)
    content:SetPoint("CENTER", frame, "CENTER", 0, 0)
end

-- Laeuft in jedem Bild mit und meldet, ob das Zielfeld gerade grau auslaeuft.
local function UpdateAbort(now)
    if not abortAt then
        return false
    end
    local age = now - abortAt
    if age >= ABORT_TIME then
        StopAbort()
        return false
    end

    local shake = 0
    if age < 0.3 then
        shake = math.sin(age * 70) * 3 * (1 - age / 0.3)
    end
    content:SetPoint("CENTER", frame, "CENTER", shake, 0)

    local flash = 0
    if age < 0.45 then
        flash = 0.6 * (1 - age / 0.45) * (math.sin(age * 40) > 0 and 1 or 0.35)
    end
    aimFlash:SetAlpha(flash)

    local alpha = age < 0.12 and age / 0.12 or math.min(1, (ABORT_TIME - age) / 0.3)
    SetHint(L.aimInterrupted, alpha, HINT_ABORT)

    if age < 0.25 then
        SetAim(abortFrom * (1 - age / 0.25), true)
        return true
    end
    return false
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

-- Leere graue Leiste, Timer aus. OnUpdate laeuft nur, solange Auto Shot, Uebungsmodus
-- oder ein Nachladen aktiv ist.
local function ShowIdle()
    frame:SetScript("OnUpdate", nil)
    reloadEnd = nil
    aimStart = nil
    StopAbort()
    SetHint(nil)
    stopLine:Hide()
    perfectLock:Hide()
    SetStreak(0)
    SetProgress(0)
    SetAim(0)
    -- Ohne laufenden Auto Shot passiert nichts, bis der Jaeger angreift.
    label:SetText(autoShotActive and "" or L.attack)
    SetPhase("idle")
end

-- Ein Schuss-Zyklus hat zwei Phasen und beginnt mit dem Zielen: links im Zielfeld stillstehen,
-- am Ende faellt der Schuss. Danach rechts nachladen, dabei darf man laufen, am Ende kommt Gold.
-- So sieht der erste Schuss genauso aus wie jeder weitere. Bewegung startet das Zielen neu.
local function OnUpdate()
    local now = GetTime()
    local draining = UpdateAbort(now)

    if reloadEnd and now < reloadEnd then
        SetProgress((now - cycleStartedAt) / reloadTime)
        if not draining then
            SetAim(0)
        end
        if not abortAt then
            SetHint(nil)
        end
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

    -- Zielen: Die Nachladeleiste ist leer, das Zielfeld fuellt sich.
    SetPhase("stand")
    SetProgress(0)

    -- Ausser Reichweite ist die Leiste ausgeblendet und es wird nicht gezielt. Gemessen:
    -- Auto Shot bleibt dabei an, nach der Rueckkehr faellt der Schuss etwa 0,5 Sek. nach dem Anhalten.
    if outOfRange then
        aimStart = nil
        SetAim(0)
        return
    end

    -- Ohne bekanntes Tempo ist die Nachladezeit offen, bis der zweite Schuss sie misst.
    if not duration and lastShotTime then
        SetAim(0)
        return
    end

    if isMoving then
        aimStart = nil
        aimDisturbed = true
        if not draining then
            SetAim(0)
        end
        if not abortAt then
            -- Wartet aufs Anhalten, das Zielfeld pulsiert.
            aimFlash:SetAlpha(0.25 + 0.25 * math.max(0, math.sin(now * 14)))
            SetHint(L.stop, 1, HINT_STOP)
        end
        return
    end

    if not abortAt then
        aimFlash:SetAlpha(0)
        SetHint(nil)
    end
    aimStart = aimStart or now
    local filled = (now - aimStart) / RED_WINDOW
    if filled >= 1 and practiceActive then
        StartCycle(now) -- im Uebungsmodus faellt der Schuss genau hier
        return
    end
    SetAim(math.min(filled, 1)) -- voll wartet es auf die Meldung des echten Schusses
end

-- Ein Schuss ist gefallen, echt oder im Uebungsmodus simuliert.
function StartCycle(now)
    -- Perfekt: im goldenen Bereich angehalten und bis zum Schuss stehen geblieben.
    if perfectStop and not aimDisturbed then
        SetStreak(perfectStreak + 1)
        if perfectStreak >= STREAK_MIN then
            procText:SetFormattedText(L.perfectStreak, perfectStreak)
        else
            procText:SetText(L.perfect)
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
    rangeDisturbed = false
    aimStart = nil
    cycleStartedAt = now
    goldAnnounced = false
    label:SetText("")

    -- Der Schuss ist raus: Abbruch-Anzeige weg, die Leiste leuchtet kurz blau.
    StopAbort()
    SetHint(nil)
    SetAim(0)
    shotAnimation:Stop()
    shotAnimation:Play()

    frame:Show()
    frame:SetScript("OnUpdate", OnUpdate)
    if duration then
        reloadEnd = now + reloadTime
    end
end

local function SetDuration(speed)
    duration = speed
    reloadTime = math.max(speed - RED_WINDOW, 0.1)
    -- Gold am Ende der Nachladeleiste, dort anhalten ist perfekt.
    local share = math.min(PERFECT_WINDOW / reloadTime, 1)
    perfectMark:SetPoint("TOPLEFT", RELOAD_WIDTH * (1 - share), -2)
    perfectMark:SetPoint("BOTTOMRIGHT", -4, 2)
    perfectMark:Show()
    perfectLock:SetPoint("TOPLEFT", core, "TOPLEFT", RELOAD_WIDTH * (1 - share), -2)
    perfectLock:SetPoint("BOTTOMRIGHT", core, "BOTTOMRIGHT", -4, 2)
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
    -- So greift auch Hast, allerdings erst ab dem zweiten Schuss damit. War der Jaeger
    -- zwischendurch zu nah oder zu weit, ist der Abstand zu lang und zaehlt nicht.
    if not ReadSpeed() and lastShotTime and not aimDisturbed and not rangeDisturbed then
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
    burst:SetPoint("CENTER", content, "CENTER")
    burst:SetSize(BAR_WIDTH + 12, BAR_HEIGHT + 22)
    burst:SetAlpha(0)

    local text = core:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("BOTTOM", content, "TOP", 0, 33) -- ueber dem Symbol
    text:SetTextColor(1, 0.85, 0.35)
    text:SetText(L.perfect)
    text:SetAlpha(0)
    procText = text

    -- Bleibt rechts ueber dem Balken stehen, bis die Serie reisst.
    streakLabel = core:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    streakLabel:SetPoint("BOTTOMRIGHT", content, "TOPRIGHT", 0, 3)
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

-- Reichweite: "Zu nah!" oder "Zu weit entfernt!" unter der Leiste, in Reichweite nichts.
-- Gemessen am 10.11.2026 in Forever, auch im Kampf lesbar und nicht gesperrt:
-- C_Spell.IsSpellInRange(75) sagt nur "in Schussweite" oder nicht, egal ob zu nah oder zu weit.
-- CheckInteractDistance(4) (etwa 28 Meter) trennt die beiden: Wer ausserhalb der Schussweite
-- und trotzdem innerhalb von 28 Metern steht, ist zu nah, denn Auto Shot reicht weiter.
-- Die globale Funktion IsSpellInRange gibt es in Forever nicht.
local RANGE_CHECK_INTERVAL = 0.1
local NEAR_DISTANCE_INDEX = 4 -- Folgen-Abstand, etwa 28 Meter
local RANGE_COLORS = {
    close = { 1, 0.25, 0.2 },
    far = { 0.72, 0.74, 0.71 },
}
local rangeCheckElapsed = 0
local rangeKey -- zuletzt angewendeter Zustand samt Schalter, spart unnoetige Aufrufe

local function AutoShotInRange()
    if C_Spell and C_Spell.IsSpellInRange then
        return C_Spell.IsSpellInRange(AUTO_SHOT_SPELL_ID, "target")
    end
    if IsSpellInRange and GetSpellInfo then
        return IsSpellInRange((GetSpellInfo(AUTO_SHOT_SPELL_ID)), "target")
    end
    return nil
end

-- Nur bei lebendem feindlichem Ziel. pcall, damit ein gesperrter Wert oder eine fehlende
-- Funktion nur "nichts zeigen" bedeutet statt eines Lua-Fehlers.
local function ReadRangeState()
    local ok, state = pcall(function()
        if not UnitExists("target") or not UnitCanAttack("player", "target") or UnitIsDead("target") then
            return nil
        end
        local inRange = AutoShotInRange()
        if inRange == nil then
            return nil
        end
        if inRange == true or inRange == 1 then
            return "ok"
        end
        if CheckInteractDistance("target", NEAR_DISTANCE_INDEX) then
            return "close"
        end
        return "far"
    end)
    if ok then
        return state
    end
    return nil
end

-- Ausserhalb der Reichweite sind Leiste und Symbole immer ausgeblendet, die Leiste kommt
-- erst in Reichweite (Marvins Wunsch). Der Schalter im Menue betrifft nur den Text.
-- Im Uebungsmodus und beim Positionieren bleibt die Leiste sichtbar.
local function ApplyRange(state)
    if practiceActive or barPositioning then
        state = nil
    end
    local key = tostring(state) .. (db.rangeOff and ":ohne Text" or ":mit Text")
    if key == rangeKey then
        return
    end
    rangeKey = key
    outOfRange = state == "close" or state == "far"
    if outOfRange then
        if db.rangeOff then
            rangeText:Hide()
        else
            rangeText:SetText(state == "close" and L.tooClose or L.tooFar)
            rangeText:SetTextColor(unpack(RANGE_COLORS[state]))
            rangeText:Show()
        end
        content:Hide()
        -- Ausser Reichweite zielt niemand: Zielen neu beginnen, ohne Abbruch-Anzeige.
        rangeDisturbed = true
        aimStart = nil
        StopAbort()
    else
        rangeText:Hide()
        content:Show()
    end
end

local function CheckRange(_, elapsed)
    rangeCheckElapsed = rangeCheckElapsed + elapsed
    if rangeCheckElapsed < RANGE_CHECK_INTERVAL then
        return
    end
    rangeCheckElapsed = 0
    ApplyRange(ReadRangeState())
end

local function CreateBar()
    frame = CreateFrame("Frame", nil, UIParent)
    frame:SetSize(BAR_WIDTH, BAR_HEIGHT)
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or DEFAULT_Y)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    -- Greifbar ist auch das Symbol darueber und der Hinweis darunter, nicht nur der Balken.
    -- Die Maus ist trotzdem nur bei gedruecktem Shift aktiv.
    frame:SetHitRectInsets(0, 0, -(DRAG_EXTRA_TOP), -(DRAG_EXTRA_BOTTOM))

    -- Alles Sichtbare sitzt auf einem Innenrahmen. Der darf beim Abbruch wackeln,
    -- ohne die gespeicherte Position der Leiste zu veraendern.
    content = CreateFrame("Frame", nil, frame)
    content:SetSize(BAR_WIDTH, BAR_HEIGHT)
    content:SetPoint("CENTER", frame, "CENTER", 0, 0)

    -- Neon: dunkles Glas hinten, darauf Leuchten und heller Kern als zwei Balken.
    -- Nur so bleibt die Mitte fast weiss, waehrend das Leuchten die Farbe traegt.
    -- Links das Zielfeld: Hier steht der Jaeger, am Ende faellt der Schuss.
    local aimBox = CreateFrame("Frame", nil, content)
    aimBox:SetSize(AIM_WIDTH, BAR_HEIGHT)
    aimBox:SetPoint("LEFT")

    local aimGlass = aimBox:CreateTexture(nil, "BACKGROUND")
    aimGlass:SetTexture(TEXTURE_PATH .. "NeonTrackShort")
    aimGlass:SetAllPoints()

    local aimTint = aimBox:CreateTexture(nil, "BORDER")
    aimTint:SetColorTexture(1, 0.24, 0.18, 0.2)
    aimTint:SetPoint("TOPLEFT", 3, -2)
    aimTint:SetPoint("BOTTOMRIGHT", -3, 2)

    aimBar = CreateFrame("StatusBar", nil, aimBox)
    aimBar:SetAllPoints()
    aimBar:SetStatusBarTexture(TEXTURE_PATH .. "NeonGlowShort")
    aimBar:GetStatusBarTexture():SetBlendMode("ADD")
    aimBar:SetMinMaxValues(0, 1)

    aimCore = CreateFrame("StatusBar", nil, aimBar)
    aimCore:SetAllPoints()
    aimCore:SetStatusBarTexture(TEXTURE_PATH .. "NeonCoreShort")
    aimCore:SetMinMaxValues(0, 1)

    -- Blinkt beim Abbruch und pulsiert, solange der Jaeger noch laeuft.
    aimFlash = aimCore:CreateTexture(nil, "OVERLAY")
    aimFlash:SetColorTexture(1, 0.29, 0.22, 1)
    aimFlash:SetPoint("TOPLEFT", 2, -2)
    aimFlash:SetPoint("BOTTOMRIGHT", -2, 2)
    aimFlash:SetAlpha(0)

    -- Rechts die Nachladeleiste: Hier darf man laufen, am Ende kommt Gold zum Anhalten.
    local reloadBox = CreateFrame("Frame", nil, content)
    reloadBox:SetSize(RELOAD_WIDTH, BAR_HEIGHT)
    reloadBox:SetPoint("RIGHT")

    local glass = reloadBox:CreateTexture(nil, "BACKGROUND")
    glass:SetTexture(TEXTURE_PATH .. "NeonTrack")
    glass:SetAllPoints()

    bar = CreateFrame("StatusBar", nil, reloadBox)
    bar:SetAllPoints()
    bar:SetStatusBarTexture(TEXTURE_PATH .. "NeonGlow")
    bar:GetStatusBarTexture():SetBlendMode("ADD")
    bar:SetMinMaxValues(0, 1)

    core = CreateFrame("StatusBar", nil, bar)
    core:SetAllPoints()
    core:SetStatusBarTexture(TEXTURE_PATH .. "NeonCore")
    core:SetMinMaxValues(0, 1)

    -- Goldener Bereich am rechten Ende, liegt ueber dem Leuchten und unter dem Kern.
    perfectMark = bar:CreateTexture(nil, "OVERLAY", nil, -1)
    perfectMark:SetColorTexture(1, 0.8, 0.25, 0.55)
    perfectMark:Hide()

    -- Blaues Aufleuchten ueber beiden Teilen, so lange wie der Bogen zu sehen ist.
    -- Eigener Rahmen ueber den Balken, sonst laege das Licht darunter.
    local shotFrame = CreateFrame("Frame", nil, content)
    shotFrame:SetAllPoints()
    shotFrame:SetFrameLevel(core:GetFrameLevel() + 1)
    local shotGlow = shotFrame:CreateTexture(nil, "OVERLAY")
    shotGlow:SetTexture(TEXTURE_PATH .. "NeonGlow")
    shotGlow:SetVertexColor(0.3, 0.7, 1)
    shotGlow:SetBlendMode("ADD")
    shotGlow:SetPoint("CENTER")
    shotGlow:SetSize(BAR_WIDTH + 12, BAR_HEIGHT + 18)
    shotGlow:SetAlpha(0)

    shotAnimation = shotGlow:CreateAnimationGroup()
    local shotIn = shotAnimation:CreateAnimation("Alpha")
    shotIn:SetFromAlpha(0)
    shotIn:SetToAlpha(0.9)
    shotIn:SetDuration(0.05)
    shotIn:SetOrder(1)
    local shotOut = shotAnimation:CreateAnimation("Alpha")
    shotOut:SetFromAlpha(0.9)
    shotOut:SetToAlpha(0)
    shotOut:SetDuration(SHOT_SYMBOL_TIME - 0.05)
    shotOut:SetOrder(2)

    -- Grosses Symbol ueber der Leiste. Text gibt es nur, solange Auto Shot aus ist.
    label = core:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("BOTTOM", content, "TOP", 0, 4)

    symbol = core:CreateTexture(nil, "OVERLAY")
    symbol:SetSize(28, 28)
    symbol:SetPoint("BOTTOM", content, "TOP", 0, 3)
    symbol:Hide()

    -- Hinweise "anhalten" und "Zielen unterbrochen" unter der Leiste, wackeln mit.
    hintText = core:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    hintText:SetPoint("TOP", content, "BOTTOM", 0, -3)
    hintText:Hide()

    -- Warnung direkt unter dem Balken. Eigener Rahmen, denn wer aus dem Nahkampf angreift,
    -- hat noch keinen Schuss und damit auch keine sichtbare Leiste.
    local rangeFrame = CreateFrame("Frame", nil, UIParent)
    rangeFrame:SetSize(1, 1)
    rangeFrame:SetPoint("TOP", frame, "BOTTOM", 0, -3)
    rangeFrame:SetScript("OnUpdate", CheckRange)

    rangeText = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rangeText:SetPoint("TOP")
    rangeText:SetTextColor(1, 0.25, 0.2)
    rangeText:SetText(L.tooClose)
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
    db.aimLog = nil -- Rest der Zielzeit-Messung, ausgewertet am 09.11.2026
    if db.soundsOff == nil then
        db.soundsOff = true -- Toene sind ab Werk aus, wer sie im Menue einschaltet, behaelt das
    end
    CreateBar()

    HF:On("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded, "player")
    HF:On("UNIT_RANGEDDAMAGE", ReadSpeed, "player")
    HF:On("PLAYER_ENTERING_WORLD", ReadSpeed)
    HF:On("PLAYER_TARGET_CHANGED", function()
        ApplyRange(ReadRangeState()) -- sofort, nicht erst beim naechsten Pruefen
    end)

    HF:On("PLAYER_STARTED_MOVING", function()
        isMoving = true
        perfectStop = false
        perfectLock:Hide()
        -- Losgelaufen, waehrend das Zielfeld sich fuellte: Das Zielen ist unterbrochen.
        if aimStart then
            local now = GetTime()
            local filled = math.min((now - aimStart) / RED_WINDOW, 1)
            if filled > 0 then
                abortAt = now
                abortFrom = filled
            end
        end
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
            -- Die Linie zeigt, wo im Nachladen angehalten wurde. Nach dem Ende steht sie ganz rechts.
            local position = math.min((now - cycleStartedAt) / reloadTime, 1)
            stopLine:ClearAllPoints()
            stopLine:SetPoint("CENTER", core, "LEFT", RELOAD_WIDTH * position, 0)
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
        -- Die Leiste erscheint sofort, denn der erste Schuss beginnt mit dem Zielen.
        label:SetText("")
        frame:Show()
        frame:SetScript("OnUpdate", OnUpdate)
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
        if autoShotActive then
            frame:SetScript("OnUpdate", OnUpdate) -- echter Auto Shot laeuft weiter
        end
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

function AutoShot:SetRangeEnabled(enabled)
    db.rangeOff = not enabled
    ApplyRange(ReadRangeState())
end

function AutoShot:IsRangeEnabled()
    return not db.rangeOff
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

-- Eigenes Logo wie auf CurseForge (Laeufer mit Bogen auf der Plakette), auch in der Add-on-Liste.
local LOGO_TEXTURE = TEXTURE_PATH .. "Logo"
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
    menuFrame:SetSize(300, 244)
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
    CreateSectionTitle(L.sectionBar, -34)

    local hint = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 16, -52)
    hint:SetText(L.moveHint)

    -- Der Knopf schliesst das Menue, damit beim Ueben nichts im Bild steht.
    local practiceButton = CreateFrame("Button", "HunterFlowMenuPractice", menuFrame, "UIPanelButtonTemplate")
    practiceButton:SetSize(200, 22)
    practiceButton:SetPoint("TOP", 0, -68)
    practiceButton:SetScript("OnClick", function(self)
        local start = not AutoShot:IsPracticing()
        AutoShot:SetPractice(start)
        if start then
            HF:Print(L.practiceRunning)
            menuFrame:Hide()
        else
            self:SetText(L.practiceStart)
        end
    end)
    practiceButton:SetText(L.practiceStart)

    -- "Zu nah!" und "Zu weit entfernt!" unter der Leiste
    local rangeCheck = CreateFrame("CheckButton", "HunterFlowMenuRange", menuFrame, "UICheckButtonTemplate")
    rangeCheck:SetPoint("TOPLEFT", 12, -94)
    rangeCheck:SetScript("OnClick", function(self)
        AutoShot:SetRangeEnabled(self:GetChecked() and true or false)
    end)

    local rangeLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rangeLabel:SetPoint("LEFT", rangeCheck, "RIGHT", 2, 1)
    rangeLabel:SetText(L.showRange)

    -- Bereich Toene
    CreateSectionTitle(L.sectionSounds, -128)

    local soundCheck = CreateFrame("CheckButton", "HunterFlowMenuSounds", menuFrame, "UICheckButtonTemplate")
    soundCheck:SetPoint("TOPLEFT", 12, -142)
    soundCheck:SetScript("OnClick", function(self)
        AutoShot:SetSoundsEnabled(self:GetChecked() and true or false)
    end)

    local soundLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    soundLabel:SetPoint("LEFT", soundCheck, "RIGHT", 2, 1)
    soundLabel:SetText(L.soundsOnPerfect)

    -- Regler in Stufen, WoW kann eigenen Toenen keine freie Lautstaerke mitgeben.
    local sliderName = "HunterFlowMenuVolume"
    local volume = CreateFrame("Slider", sliderName, menuFrame, "OptionsSliderTemplate")
    volume:SetPoint("TOPLEFT", 20, -190)
    volume:SetWidth(260)
    volume:SetMinMaxValues(SOUND_LEVEL_MIN, SOUND_LEVEL_MAX)
    volume:SetValueStep(SOUND_LEVEL_STEP)
    if volume.SetObeyStepOnDrag then
        volume:SetObeyStepOnDrag(true)
    end
    _G[sliderName .. "Low"]:SetText(SOUND_LEVEL_MIN .. " %")
    _G[sliderName .. "High"]:SetText(SOUND_LEVEL_MAX .. " %")

    local function ShowVolumeText(level)
        _G[sliderName .. "Text"]:SetFormattedText(L.volume, level)
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
        practiceButton:SetText(AutoShot:IsPracticing() and L.practiceStop or L.practiceStart)
        soundCheck:SetChecked(AutoShot:AreSoundsEnabled())
        rangeCheck:SetChecked(AutoShot:IsRangeEnabled())
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
    icon:SetTexture(LOGO_TEXTURE)
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
        GameTooltip:AddDoubleLine(L.leftClick, L.menu, 0.67, 0.83, 0.45, 1, 1, 1)
        GameTooltip:AddDoubleLine(L.drag, L.moveButton, 0.67, 0.83, 0.45, 1, 1, 1)
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
