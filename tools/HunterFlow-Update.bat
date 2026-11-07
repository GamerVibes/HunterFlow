@echo off
setlocal
set "HF_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:HF_SELF); Invoke-Expression $s.Substring($s.IndexOf('#PS-START'+'#'))"
echo.
pause
goto :eof
#PS-START#
# Installiert oder aktualisiert HunterFlow aus dem neuesten GitHub-Release.
# Alles ab hier ist PowerShell, die Zeilen darueber starten es per Doppelklick.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ZipUrl = 'https://github.com/GamerVibes/HunterFlow/releases/latest/download/HunterFlow.zip'
$ConfigDir = Join-Path $env:LOCALAPPDATA 'HunterFlow-Update'
$ConfigFile = Join-Path $ConfigDir 'wow-pfad.txt'

# Macht aus "World of Warcraft" oder "..\_forever_" den Pfad zu _forever_.
function Resolve-ForeverDir([string]$path) {
    if (-not $path) { return $null }
    $path = $path.Trim().Trim('"').TrimEnd('\')
    if (-not $path) { return $null }
    if ((Split-Path -Leaf $path) -eq '_forever_' -and (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    $inner = Join-Path $path '_forever_'
    if (Test-Path -LiteralPath $inner -PathType Container) { return $inner }
    return $null
}

# Sucht WoW ueber den Registry-Eintrag von Blizzard und typische Ordner.
function Find-ForeverDir {
    $candidates = @()
    try {
        $key = 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft'
        $install = (Get-ItemProperty -LiteralPath $key).InstallPath
        if ($install) {
            $install = $install.TrimEnd('\')
            $candidates += $install
            $candidates += (Split-Path -Parent $install)
        }
    } catch { }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        foreach ($sub in 'World of Warcraft', 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'Games\World of Warcraft', 'WOW\World of Warcraft', 'Blizzard\World of Warcraft') {
            $candidates += (Join-Path $drive.Root $sub)
        }
    }
    foreach ($candidate in $candidates) {
        $found = Resolve-ForeverDir $candidate
        if ($found) { return $found }
    }
    return $null
}

# Liefert den Pfad zu _forever_ und merkt ihn sich fuer das naechste Mal.
function Get-ForeverDir {
    if (Test-Path -LiteralPath $ConfigFile) {
        $saved = Resolve-ForeverDir (Get-Content -LiteralPath $ConfigFile -TotalCount 1)
        if ($saved) { return $saved }
    }
    $found = Find-ForeverDir
    while (-not $found) {
        Write-Host 'WoW Forever wurde nicht automatisch gefunden.'
        $answer = Read-Host 'Bitte den Ordner "World of Warcraft" hier einfügen'
        if (-not $answer) { throw 'Kein Ordner angegeben.' }
        $found = Resolve-ForeverDir $answer
        if (-not $found) { Write-Host 'In diesem Ordner liegt kein "_forever_".' }
    }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Set-Content -LiteralPath $ConfigFile -Value $found -Encoding UTF8
    return $found
}

function Get-TocVersion([string]$folder) {
    $toc = Join-Path $folder 'HunterFlow.toc'
    if (-not (Test-Path -LiteralPath $toc)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $toc -Encoding UTF8)) {
        if ($line -match '^##\s*Version:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return $null
}

# Die toc ohne Versionszeile. Aendert sie sich, liest WoW sie erst beim Neustart.
function Get-TocBody([string]$folder) {
    return ((Get-Content -LiteralPath (Join-Path $folder 'HunterFlow.toc') -Encoding UTF8) | Where-Object { $_ -notmatch '^##\s*Version:' }) -join "`n"
}

function Get-RelativeFiles([string]$folder) {
    return @(Get-ChildItem -LiteralPath $folder -Recurse -File | ForEach-Object { $_.FullName.Substring($folder.Length) })
}

function Update-HunterFlow {
    $forever = Get-ForeverDir
    $addons = Join-Path $forever 'Interface\AddOns'
    $target = Join-Path $addons 'HunterFlow'
    Write-Host "WoW Forever: $forever"

    # Ein verlinkter Ordner ist eine Entwicklerkopie, die wird nie angefasst.
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$target ist ein verlinkter Ordner (Junction). Das Update fasst ihn nicht an."
        }
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('HunterFlow-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Write-Host 'Lade die neueste Version ...'
        $zip = Join-Path $temp 'HunterFlow.zip'
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $temp 'neu')
        $new = Join-Path $temp 'neu\HunterFlow'
        $newVersion = Get-TocVersion $new
        if (-not $newVersion) { throw 'Die heruntergeladene Datei enthält kein gültiges HunterFlow.' }

        $oldVersion = Get-TocVersion $target
        if ($oldVersion -eq $newVersion) {
            Write-Host "Du hast schon die neueste Version ($newVersion)."
            return
        }

        # Beim Update den alten Stand als Sicherung behalten, ausserhalb von AddOns.
        $backup = Join-Path $forever 'HunterFlow-Backup'
        $needsRestart = $true
        $hadOld = Test-Path -LiteralPath $target
        if ($hadOld) {
            $oldFiles = Get-RelativeFiles $target
            $addedFiles = @(Get-RelativeFiles $new | Where-Object { $oldFiles -notcontains $_ })
            $needsRestart = ($addedFiles.Count -gt 0) -or ((Get-TocBody $target) -ne (Get-TocBody $new))
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
            Move-Item -LiteralPath $target -Destination $backup
        } else {
            New-Item -ItemType Directory -Force -Path $addons | Out-Null
        }
        try {
            Copy-Item -LiteralPath $new -Destination $target -Recurse
        } catch {
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            if ($hadOld) { Move-Item -LiteralPath $backup -Destination $target }
            throw
        }

        if ($hadOld) {
            Write-Host "Aktualisiert von $oldVersion auf $newVersion."
        } else {
            Write-Host "HunterFlow $newVersion ist installiert."
        }
        if ($needsRestart) {
            Write-Host 'Läuft WoW gerade, starte es einmal komplett neu.'
        } else {
            Write-Host 'Läuft WoW gerade, gib im Spiel /reload ein.'
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    Update-HunterFlow
} catch {
    Write-Host ''
    Write-Host 'Das Update hat nicht geklappt:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'Schick diese Meldung an Marvin. Dein bisheriges Add-on bleibt erhalten.'
}
