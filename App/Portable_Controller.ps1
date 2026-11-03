# PANICORE Portable Host Controller v0.11.6.2 Quiet Setup - unchanged gameplay controller
# Windows PowerShell 5.1 - no Python or developer SDK required.
# This is a prototype and is not verified in a live PANICORE session.
[CmdletBinding()]
param(
    [ValidateSet('Launch','Check','Cleanup','Diagnostics')][string]$Action = 'Launch',
    [string]$GameFolder = '',
    [string]$StartupLog = ''
)

$ErrorActionPreference = 'Stop'
# One persistent startup report per attempt. Normal console output is still visible.
# If transcription is unavailable, the controller continues with the console output.
$script:phcTranscriptStarted = $false
if (-not [string]::IsNullOrWhiteSpace($StartupLog)) {
    try {
        $dir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StartupLog))
        if (-not [IO.Directory]::Exists($dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
        Start-Transcript -Path $StartupLog -Append -ErrorAction Stop | Out-Null
        $script:phcTranscriptStarted = $true
    } catch {
        Write-Host ('[WARNING] Could not start transcript at ' + $StartupLog + ': ' + $_.Exception.Message)
    }
}
$Root = $PSScriptRoot
$Resources = [IO.Path]::Combine($Root, 'Runtime')
$UE4SSRoot = [IO.Path]::Combine($Resources, 'ue4ss')
$ProxySource = [IO.Path]::Combine($Resources, 'dwmapi.dll')
$ModSource = [IO.Path]::Combine($Root, 'Mods', 'PanicoreHostControl')
$StateFolder = [IO.Path]::Combine($Root, 'State')
$SessionFile = [IO.Path]::Combine($StateFolder, 'active-session.json')
$SavedGamePathFile = [IO.Path]::Combine($StateFolder, 'game-bin.txt')
$PackageRoot = [IO.Path]::GetDirectoryName($Root)
$Reports = [IO.Path]::Combine($PackageRoot, 'Reports')
$CurrentReports = [IO.Path]::Combine($Reports, 'Current')
$PinnedArchiveName = 'zDEV-UE4SS_v3.0.1-1183-gcdbc0b66.zip'
$PinnedArchiveSha = '2B634E7E1446B360599C01419D8CA14823A5138FA7FDF8F7FC28A50A13054908'
$PinnedDllSha = 'C273E7228687B647226FD63D7CA65888D313ECE6BE18996EC1320D00A5EFE1F8'
$PinnedProxySha = 'F8BEC398FCBB2E3E8D1EF2875CAFCC15D09F82073402FC9879A9CBF78B8D9514'
$LastReportFile = [IO.Path]::Combine($StateFolder, 'last-report.json')
$Downloads = [IO.Path]::Combine($Root, 'Downloads')
$ModName = 'PanicoreHostControl'
$Version = '0.11.6.2 quieter windows, report command, encoding fix / 0.11.6 performance'
$SteamAppID = '2695940'

function Say([string]$msg) { Write-Host ('[PHC] ' + $msg) }
function Warn([string]$msg) { Write-Host ('[WARNING] ' + $msg) -ForegroundColor Yellow }
function Fail([string]$msg) { throw $msg }
function Folder([string]$path) { if (-not [IO.Directory]::Exists($path)) { [IO.Directory]::CreateDirectory($path) | Out-Null } }
function Exists([string]$path) {
    if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) { return $true }
    # May be a broken directory junction, which still needs safe cleanup.
    return ($null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue))
}
function Hash([string]$path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
function JSON-Save([string]$path, $obj) {
    Folder ([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}
function JSON-Read([string]$path) {
    if (-not [IO.File]::Exists($path)) { return $null }
    return ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
}
function Running-Game {
    return @(Get-Process -Name 'Panicore-Win64-Shipping' -ErrorAction SilentlyContinue).Count -gt 0
}
function Game-Bin([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $candidate = $raw.Trim().Trim('"')
    if ([IO.File]::Exists($candidate)) { $candidate = [IO.Path]::GetDirectoryName($candidate) }
    if (-not [IO.Directory]::Exists($candidate)) { return $null }
    $base = [IO.Path]::GetFullPath($candidate)
    $possibles = @(
        $base,
        [IO.Path]::Combine($base, 'Panicore', 'Binaries', 'Win64'),
        [IO.Path]::Combine($base, 'Binaries', 'Win64'),
        [IO.Path]::Combine($base, 'PANICORE', 'Panicore', 'Binaries', 'Win64')
    )
    foreach ($bin in $possibles) {
        if ([IO.File]::Exists([IO.Path]::Combine($bin, 'Panicore-Win64-Shipping.exe'))) {
            return [IO.Path]::GetFullPath($bin)
        }
    }
    return $null
}
function Find-Game {
    # Don't Join-Path against arbitrary drive letters. The previous installer
    # could throw when it encountered E: without an E: drive. IO.Directory.Exists
    # returns false cleanly and IO.Path.Combine never assumes a PowerShell drive.
    $baseCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base -and [IO.Directory]::Exists($base)) { [void]$baseCandidates.Add($base) }
    }
    foreach ($reg in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $props = Get-ItemProperty -Path $reg -ErrorAction Stop
            foreach ($value in @($props.SteamPath,$props.InstallPath)) {
                if ($value -and [IO.Directory]::Exists([string]$value)) { [void]$baseCandidates.Add([string]$value) }
            }
        } catch { }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            foreach ($name in @('Steam','SteamLibrary','Games\Steam','Games\SteamLibrary','Program Files (x86)\Steam')) {
                $guess = [IO.Path]::Combine($drive.RootDirectory.FullName, $name)
                if ([IO.Directory]::Exists($guess)) { [void]$baseCandidates.Add($guess) }
            }
        } catch { continue }
    }
    $allLibraries = New-Object System.Collections.Generic.List[string]
    foreach ($base in @($baseCandidates | Select-Object -Unique)) {
        $possibles = @($base,
            [IO.Path]::Combine($base, 'Steam'),
            [IO.Path]::Combine($base, 'SteamLibrary'))
        foreach ($lib in $possibles) {
            if (-not [IO.Directory]::Exists($lib)) { continue }
            [void]$allLibraries.Add($lib)
            $vdf = [IO.Path]::Combine($lib, 'steamapps', 'libraryfolders.vdf')
            if ([IO.File]::Exists($vdf)) {
                foreach ($line in [IO.File]::ReadAllLines($vdf)) {
                    if ($line -match '^\s*"path"\s*"([^"]+)"') {
                        $parsed = $Matches[1].Replace('\\', '\')
                        # A Steam library listing on a missing E: drive is ignored.
                        if ([IO.Directory]::Exists($parsed)) { [void]$allLibraries.Add($parsed) }
                    }
                }
            }
        }
    }
    foreach ($lib in @($allLibraries | Select-Object -Unique)) {
        $manifest = [IO.Path]::Combine($lib, 'steamapps', ('appmanifest_' + $SteamAppID + '.acf'))
        $names = @('PANICORE')
        if ([IO.File]::Exists($manifest)) {
            foreach ($line in [IO.File]::ReadAllLines($manifest)) {
                if ($line -match '^\s*"installdir"\s*"([^"]+)"') { $names = @($Matches[1]) + $names; break }
            }
        }
        foreach ($name in @($names | Select-Object -Unique)) {
            $candidate = [IO.Path]::Combine($lib, 'steamapps', 'common', $name)
            $bin = Game-Bin $candidate
            if ($bin) { return $bin }
        }
    }
    return $null
}
function Choose-Game([bool]$prompt) {
    if ($GameFolder) {
        $manual = Game-Bin $GameFolder
        if ($manual) { return $manual }
        Fail ('PANICORE was not found at the supplied path: ' + $GameFolder)
    }
    if ([IO.File]::Exists($SavedGamePathFile)) {
        $saved = Game-Bin ([IO.File]::ReadAllText($SavedGamePathFile).Trim())
        if ($saved) { return $saved }
    }
    $located = Find-Game
    if ($located) { return $located }
    if (-not $prompt) { return $null }
    Warn 'PANICORE was not detected in existing Steam drives. Missing drive letters are safely ignored.'
    Say 'In Steam: PANICORE > right-click > Manage > Browse local files.'
    $inputPath = Read-Host 'Paste the PANICORE folder path (or its Binaries\Win64 folder)'
    $located = Game-Bin $inputPath
    if (-not $located) { Fail 'Cannot identify Panicore-Win64-Shipping.exe in that folder. No game files were changed.' }
    return $located
}
function Get-VCRuntime {
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        try {
            $v = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($v.Installed -eq 1) { return ('Installed: ' + [string]$v.Version) }
        } catch { }
    }
    return $null
}
function Ensure-VCRuntime {
    $current = Get-VCRuntime
    if ($current) { Say ('Microsoft Visual C++ x64 runtime: ' + $current); return }
    Warn 'Microsoft Visual C++ x64 runtime not detected (system-wide Windows dependency).'
    $answer = Read-Host 'Download and install the official Microsoft runtime? [Y/n]'
    if ($answer -match '^(n|no)$') { Fail 'The required runtime was declined. No game files changed.' }
    Folder $Downloads
    $exe = [IO.Path]::Combine($Downloads, 'vc_redist.x64.exe')
    Say 'Downloading Microsoft signed runtime installer...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $exe
    $signature = Get-AuthenticodeSignature -FilePath $exe
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        Fail 'The Microsoft runtime signature was not valid. Installer will not run.'
    }
    $proc = Start-Process -FilePath $exe -ArgumentList @('/install','/passive','/norestart') -Verb RunAs -PassThru -Wait
    if (@(0,3010) -notcontains [int]$proc.ExitCode) { Fail ('Microsoft runtime error ' + $proc.ExitCode) }
    if (-not (Get-VCRuntime)) { Fail 'Windows does not report an installed Visual C++ runtime after setup.' }
    if ([int]$proc.ExitCode -eq 3010) { Warn 'The runtime installation requested a Windows restart.' }
    Say 'Microsoft runtime ready.'
}
function Check-Zip([string]$file) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($file)
    try {
        if ($archive.Entries.Count -gt 10000) { Fail 'UE4SS ZIP has too many entries.' }
        $total = [long]0
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ($name -match '(^|\\)\.\.(\\|$)' -or $name.StartsWith('\') -or
                $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
                Fail ('Unexpected ZIP path: ' + $name)
            }
            $total += $entry.Length
            if ($total -gt 800MB) { Fail 'UE4SS ZIP expanded size exceeds safety limit.' }
        }
    } finally { $archive.Dispose() }
}
function Assert-Runtime-Archive([string]$path) {
    if (-not [IO.File]::Exists($path) -or (Hash $path) -ne $PinnedArchiveSha) {
        Fail ('UE4SS archive is not the pinned, verified ' + $PinnedArchiveName + '. No unverified runtime will be installed.')
    }
}
function Download-UE4SS([string]$output) {
    $manual = [IO.Path]::Combine($Downloads, 'UE4SS_OFFLINE.zip')
    if ([IO.File]::Exists($manual)) {
        Assert-Runtime-Archive $manual
        [IO.File]::Copy($manual,$output,$true)
        return
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $uris = @(
        ('https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/' + $PinnedArchiveName),
        ('https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/' + $PinnedArchiveName)
    )
    Say ('Downloading exact UE4SS build: ' + $PinnedArchiveName)
    Say 'This build does not silently select a newer experimental DLL.'
    $downloaded = $false
    $lastError = ''
    foreach ($uri in $uris) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $output -ErrorAction Stop
            $downloaded = $true
            break
        } catch {
            $lastError = $_.Exception.Message
            if ([IO.File]::Exists($output)) { [IO.File]::Delete($output) }
        }
    }
    if (-not $downloaded) { Fail ('The pinned official UE4SS download is unavailable. Setup stopped safely: ' + $lastError) }
    Assert-Runtime-Archive $output
    Say 'Official UE4SS archive matches the pinned SHA256.'
}
function Set-Private-Ini([string]$path,[string]$section,[string]$key,[string]$value) {
    $output = New-Object System.Collections.Generic.List[string]
    $inSection=$false; $sawSection=$false; $wrote=$false
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            if ($inSection -and -not $wrote) { [void]$output.Add($key+' = '+$value); $wrote=$true }
            $inSection=($Matches[1] -ieq $section)
            if ($inSection) { $sawSection=$true }
        }
        if ($inSection -and $line -match ('^\s*'+[regex]::Escape($key)+'\s*=')) {
            if (-not $wrote) { [void]$output.Add($key+' = '+$value); $wrote=$true }
            continue
        }
        [void]$output.Add($line)
    }
    if (-not $sawSection) { [void]$output.Add('['+$section+']') }
    if (-not $wrote) { [void]$output.Add($key+' = '+$value) }
    [IO.File]::WriteAllLines($path,$output.ToArray(),(New-Object Text.UTF8Encoding($false)))
}
function Ensure-Runtime {
    if ([IO.File]::Exists([IO.Path]::Combine($UE4SSRoot, 'UE4SS.dll')) -and
        [IO.File]::Exists([IO.Path]::Combine($UE4SSRoot, 'UE4SS-settings.ini')) -and
        [IO.File]::Exists($ProxySource)) {
        Say 'Existing portable UE4SS framework found inside this folder.'
    } else {
        if ((Exists $UE4SSRoot) -or (Exists $ProxySource)) {
            Fail 'Partial portable Runtime detected. It was preserved; move it aside before retrying.'
        }
        Folder $Downloads
        $officialZip = [IO.Path]::Combine($Downloads, 'ue4ss-downloaded.zip')
        if ([IO.File]::Exists($officialZip)) {
            Say 'Reusing previous official UE4SS archive (validated again).'
        } else { Download-UE4SS $officialZip }
        Assert-Runtime-Archive $officialZip
        Check-Zip $officialZip
        $work = [IO.Path]::Combine($Root, 'Work_UE4SS_Extracted')
        if (Exists $work) { Fail 'Temporary Work_UE4SS_Extracted folder already exists. Please inspect it before retrying.' }
        Folder $work
        try {
            Expand-Archive -LiteralPath $officialZip -DestinationPath $work
            $dlls = @(Get-ChildItem -LiteralPath $work -Recurse -File | Where-Object { $_.Name -ieq 'UE4SS.dll' })
            if ($dlls.Count -ne 1 -or $dlls[0].Directory.Name -ine 'ue4ss') {
                Fail 'UE4SS release does not have the expected portable-compatible ue4ss\ folder layout.'
            }
            $sourceRoot = $dlls[0].Directory.FullName
            $sourceProxy = [IO.Path]::Combine([IO.Path]::GetDirectoryName($sourceRoot), 'dwmapi.dll')
            if (-not [IO.File]::Exists($sourceProxy) -or
                -not [IO.File]::Exists([IO.Path]::Combine($sourceRoot, 'UE4SS-settings.ini'))) {
                Fail 'Official release is missing a proxy DLL or settings; no game files changed.'
            }
            Folder $Resources
            Copy-Item -LiteralPath $sourceRoot -Destination $UE4SSRoot -Recurse
            Copy-Item -LiteralPath $sourceProxy -Destination $ProxySource
            Say 'UE4SS stored in App\Runtime. Nothing installed beside PANICORE yet.'
        } catch {
            if ([IO.Directory]::Exists($UE4SSRoot)) { Remove-Item -LiteralPath $UE4SSRoot -Force -Recurse }
            if ([IO.File]::Exists($ProxySource)) { [IO.File]::Delete($ProxySource) }
            throw
        } finally {
            # This is our own extraction-only folder, never a game directory.
            if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Force -Recurse }
        }
    }
    if ((Hash ([IO.Path]::Combine($UE4SSRoot,'UE4SS.dll'))) -ne $PinnedDllSha -or
        (Hash $ProxySource) -ne $PinnedProxySha) {
        Fail 'Portable runtime DLL differs from this audited build. Files were preserved; do not mix runtimes between versions.'
    }
    $settings = [IO.Path]::Combine($UE4SSRoot,'UE4SS-settings.ini')
    Set-Private-Ini $settings 'General' 'DefaultExecuteInGameThreadMethod' 'EngineTick'
    Set-Private-Ini $settings 'General' 'EnableHotReloadSystem' '0'
    Set-Private-Ini $settings 'General' 'EnableAutoReloadingLuaMods' '0'
    Set-Private-Ini $settings 'General' 'bUseUObjectArrayCache' 'false'
    Set-Private-Ini $settings 'General' 'bForceGUObjectArrayForIteration' 'true'
    # zDEV UE4SS enables a separate native console and graphical debug UI by
    # default. Keep persistent UE4SS.log but do not open those developer windows.
    Set-Private-Ini $settings 'Debug' 'ConsoleEnabled' '0'
    Set-Private-Ini $settings 'Debug' 'GuiConsoleEnabled' '0'
    Set-Private-Ini $settings 'Debug' 'GuiConsoleVisible' '0'
    $mods = [IO.Path]::Combine($UE4SSRoot, 'Mods')
    Folder $mods
    $destMod = [IO.Path]::Combine($mods, $ModName)
    $sourceLua = [IO.Path]::Combine($ModSource, 'Scripts', 'main.lua')
    $installedLua = [IO.Path]::Combine($destMod, 'Scripts', 'main.lua')
    if (-not [IO.File]::Exists($sourceLua)) { Fail 'Controller Lua file is missing. Extract the entire ZIP.' }
    if ([IO.File]::Exists($installedLua) -and (Hash $installedLua) -ne (Hash $sourceLua)) {
        $backup = [IO.Path]::Combine($Root, 'Backups', ('PanicoreHostControl-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
        Folder ([IO.Path]::GetDirectoryName($backup))
        Copy-Item -LiteralPath $destMod -Destination $backup -Recurse
        Say ('Backed up an older controller mod to ' + $backup)
    }
    if ([IO.Directory]::Exists($destMod)) {
        # This directory is inside our own portable UE4SS runtime, not the game.
        Remove-Item -LiteralPath $destMod -Force -Recurse
    }
    Copy-Item -LiteralPath $ModSource -Destination $destMod -Recurse
    # Only touch this package's private framework; never any third-party game mods.
    # Bundled sample/console mods must not add their own keybinds and callbacks.
    $txt = [IO.Path]::Combine($mods,'mods.txt')
    $modLines = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @(Get-ChildItem -LiteralPath $mods -Directory)) {
        if ($dir.Name -ine $ModName) {
            [void]$modLines.Add($dir.Name+' : 0')
            $enabled = [IO.Path]::Combine($dir.FullName,'enabled.txt')
            if ([IO.File]::Exists($enabled)) { [IO.File]::Delete($enabled) }
        }
    }
    [void]$modLines.Add($ModName+' : 1')
    [IO.File]::WriteAllLines($txt,$modLines.ToArray(),(New-Object Text.UTF8Encoding($false)))
    Set-Private-Ini $settings 'Overrides' 'ControllingModsTxt' $txt
    Folder $CurrentReports
    [IO.File]::WriteAllText([IO.Path]::Combine($destMod,'ReportDirectory.txt'),$CurrentReports,(New-Object Text.UTF8Encoding($false)))
    Say 'Controller mod registered in the portable runtime.'
}
function Assert-No-Conflicts([string]$bin) {
    foreach ($filename in @('dwmapi.dll','UE4SS.dll','xinput1_3.dll','ue4ss')) {
        $path = [IO.Path]::Combine($bin, $filename)
        if (Exists $path) { Fail ('Existing loader/mod files found in PANICORE: ' + $path + '. Close PANICORE and run Uninstall.cmd. Known previous controller deployments are handled automatically; unknown loaders are preserved.') }
    }
}
function Inventory([string]$source) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($source.Length).TrimStart([char[]]@('\','/'))
        [void]$items.Add([pscustomobject]@{ Relative = $relative; Sha256 = (Hash $file.FullName) })
    }
    return @($items.ToArray())
}
function Stage-Game([string]$bin) {
    Assert-No-Conflicts $bin
    $deployed = [IO.Path]::Combine($bin, 'ue4ss')
    $proxy = [IO.Path]::Combine($bin, 'dwmapi.dll')
    $state = [ordered]@{
        Version = $Version
        GameBin = $bin
        RuntimeRoot = $UE4SSRoot
        ProxySha256 = (Hash $ProxySource)
        Method = 'Junction'
        Created = (Get-Date).ToString('o')
        Inventory = @()
    }
    JSON-Save $SessionFile $state
    $linked = $false
    try {
        Say 'Creating temporary directory junction to portable UE4SS runtime...'
        New-Item -ItemType Junction -Path $deployed -Target $UE4SSRoot -ErrorAction Stop | Out-Null
        $linkItem = Get-Item -LiteralPath $deployed -Force
        if (($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Fail 'New game-side directory is not a reparse point.'
        }
        $linked = $true
    } catch {
        if (Exists $deployed) {
            # Never run Copy over a possible partial junction/unknown directory.
            throw
        }
        Warn 'A directory junction was unavailable (e.g., external filesystem). Using temporary copy instead.'
        $state.Method = 'Copy'
        $state.Inventory = @(Inventory $UE4SSRoot)
        JSON-Save $SessionFile $state
        Copy-Item -LiteralPath $UE4SSRoot -Destination $deployed -Recurse -ErrorAction Stop
    }
    if (-not [IO.File]::Exists([IO.Path]::Combine($deployed, 'UE4SS.dll'))) {
        Fail 'UE4SS.dll is inaccessible through the staged game directory.'
    }
    Copy-Item -LiteralPath $ProxySource -Destination $proxy -ErrorAction Stop
    Say ('Game loader enabled temporarily (' + $state.Method + ').')
    Say ('Desktop runtime remains at: ' + $UE4SSRoot)
}
function Junction-Owned([string]$junction, [string]$expectedTarget) {
    $item = Get-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    foreach ($raw in @($item.Target)) {
        if ($raw -and (Normal-Target ([string]$raw)) -ieq (Normal-Target $expectedTarget)) {
            return $true
        }
    }
    return $false
}
function Copy-Can-Be-Removed([string]$dir, $manifest) {
    $original = @{}
    foreach ($entry in @($manifest)) { $original[([string]$entry.Relative).ToLowerInvariant()] = [string]$entry.Sha256 }
    $seen = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($dir.Length).TrimStart([char[]]@('\','/'))
        $key = $relative.ToLowerInvariant()
        if ($key -in @('ue4ss.log','mods\panicorehostcontrol\radarsnapshot.tsv',
            'mods\panicorehostcontrol\scripts\phc_radarsnapshot.tsv')) { continue } # generated runtime state
        if (-not $original.ContainsKey($key)) {
            Warn ('Unknown file appeared in temporary game UE4SS folder: ' + $relative)
            return $false
        }
        if ((Hash $file.FullName) -ne $original[$key]) {
            Warn ('A file changed in the temporary UE4SS copy: ' + $relative)
            return $false
        }
        $seen[$key] = $true
    }
    return $true
}
function Cleanup-Game([bool]$quiet, [string]$statePath = $SessionFile) {
    $state = JSON-Read $statePath
    if (-not $state) {
        if (-not $quiet) { Say 'No portable deployment recorded. No game files were changed.' }
        return
    }
    if (Running-Game) { Fail 'Close PANICORE before removing its game-side loader.' }
    $bin = [string]$state.GameBin
    if (-not [IO.Directory]::Exists($bin) -or
        -not [IO.File]::Exists([IO.Path]::Combine($bin, 'Panicore-Win64-Shipping.exe'))) {
        Warn 'The previously saved game location is missing. Portable state was preserved for review.'
        return
    }
    $dest = [IO.Path]::Combine($bin, 'ue4ss')
    $proxy = [IO.Path]::Combine($bin, 'dwmapi.dll')
    $leftover = $false
    if (Exists $dest) {
        if ([string]$state.Method -eq 'Junction') {
            if (Junction-Owned $dest ([string]$state.RuntimeRoot)) {
                # Remove ONLY the junction itself. Never recursively delete its target.
                [IO.Directory]::Delete($dest, $false)
                Say 'Removed temporary ue4ss junction; Desktop runtime retained.'
            } else {
                Warn 'ue4ss is no longer our exact junction. It was not modified.'
                $leftover = $true
            }
        } elseif ([string]$state.Method -eq 'Copy') {
            $item = Get-Item -LiteralPath $dest -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Warn 'Temporary copy unexpectedly became a junction. It was not modified.'
                $leftover = $true
            } elseif (Copy-Can-Be-Removed $dest $state.Inventory) {
                Remove-Item -LiteralPath $dest -Force -Recurse -ErrorAction Stop
                Say 'Removed temporary UE4SS game folder after verifying file hashes.'
            } else {
                Warn 'Preserved the changed game-side UE4SS copy for manual review.'
                $leftover = $true
            }
        } else {
            Warn 'Unrecognized deployment method; no UE4SS files removed.'
            $leftover = $true
        }
    }
    if ([IO.File]::Exists($proxy)) {
        if ((Hash $proxy) -eq [string]$state.ProxySha256) {
            [IO.File]::Delete($proxy)
            Say 'Removed our temporary dwmapi.dll loader from game folder.'
        } else {
            Warn 'dwmapi.dll was modified by something else; it was preserved.'
            $leftover = $true
        }
    }
    if (-not $leftover -and -not (Exists $dest) -and -not (Exists $proxy)) {
        [IO.File]::Delete($statePath)
        if (-not $quiet) { Say 'Cleanup complete. Main controller and UE4SS remain in your portable folder only.' }
    } else { Warn 'Cleanup incomplete. Review the game folder before copying/deleting your Desktop package.' }
}

# Recognize legacy v0.3-v0.11.1 owned loader deployments without requiring
# the user to locate and execute an older installer. Never touch unowned mods.
function Normal-Target([string]$raw) {
    $v = $raw.Trim()
    if ($v.StartsWith('\\?\')) { $v = $v.Substring(4) }
    if ($v.StartsWith('\??\')) { $v = $v.Substring(4) }
    return $v.TrimEnd([char[]]@('\','/'))
}
function Is-Matching-State([string]$path, [string]$bin) {
    try {
        $s = JSON-Read $path
        if (-not $s -or -not $s.GameBin -or -not $s.RuntimeRoot -or -not $s.ProxySha256) { return $false }
        if ([IO.Path]::GetFullPath([string]$s.GameBin).TrimEnd('\') -ine [IO.Path]::GetFullPath($bin).TrimEnd('\')) { return $false }
        return @('Junction','Copy') -contains [string]$s.Method
    } catch { return $false }
}
function Prior-Session([string]$bin) {
    if (Is-Matching-State $SessionFile $bin) { return $SessionFile }
    $link = [IO.Path]::Combine($bin,'ue4ss')
    try {
        $item = Get-Item -LiteralPath $link -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            foreach ($raw in @($item.Target)) {
                if (-not $raw) { continue }
                $target = Normal-Target ([string]$raw)
                if ([IO.Path]::GetFileName($target) -ine 'ue4ss') { continue }
                $owner = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($target))
                $candidate = [IO.Path]::Combine($owner,'State','active-session.json')
                if (Is-Matching-State $candidate $bin) {
                    $old = JSON-Read $candidate
                    if ((Normal-Target ([string]$old.RuntimeRoot)) -ieq $target) { return $candidate }
                }
            }
        }
    } catch { }
    # Copy-fallback deployment lacks a junction target. Bounded lookup of the
    # usual extracted versions in Desktop/Downloads; never recursively roam a drive.
    $roots = @([IO.Path]::Combine($env:USERPROFILE,'Desktop'),
               [IO.Path]::Combine($env:USERPROFILE,'Downloads'), $PackageRoot)
    $count = 0
    foreach ($dir in $roots) {
        if (-not [IO.Directory]::Exists($dir)) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*PANICORE*Controller*' })) {
            $owners = @($child.FullName)
            foreach ($nested in @(Get-ChildItem -LiteralPath $child.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*PANICORE*Controller*' })) {
                $owners += [string]$nested.FullName
            }
            foreach ($owner in $owners) {
                foreach ($candidate in @([IO.Path]::Combine($owner,'State','active-session.json'),
                                          [IO.Path]::Combine($owner,'App','State','active-session.json'))) {
                    if (Is-Matching-State $candidate $bin) { return $candidate }
                }
                $count++
                if ($count -ge 80) { return $null }
            }
        }
    }
    return $null
}
function Cleanup-Recognized-Deployment([string]$bin) {
    $dest = [IO.Path]::Combine($bin,'ue4ss')
    $proxy = [IO.Path]::Combine($bin,'dwmapi.dll')
    if (-not (Exists $dest) -and -not (Exists $proxy)) { return }
    $ownedSession = Prior-Session $bin
    if (-not $ownedSession) {
        Fail ('An existing UE4SS loader could not be verified as ours: ' + $bin +
              '. Its files were preserved. Restore the original portable folder or inspect the loader manually.')
    }
    Say ('Found a verified previous controller deployment: ' + $ownedSession)
    Cleanup-Game $false $ownedSession
    if ((Exists $dest) -or (Exists $proxy)) {
        Fail 'Previous loader cleanup was incomplete; unknown or changed files were preserved.'
    }
}

function Stop-Legacy-Radar {
    # Target ONLY a PANICORE controller radar script from an earlier extracted
    # portable folder. Never stop an unrelated PowerShell process.
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            $command = [string]$process.CommandLine
            # Require an actual -File radar argument from a known portable
            # controller folder, not merely arbitrary text in a PowerShell command.
            $radarScript=$null
            if ($command -match '(?i)(?:^|\s)-File\s+"([^"\r\n]*Radar_View\.ps1)"(?:\s|$)') { $radarScript=$Matches[1] }
            elseif ($command -match '(?i)(?:^|\s)-File\s+(\S*Radar_View\.ps1)(?:\s|$)') { $radarScript=$Matches[1] }
            if ($radarScript -and $radarScript -match '(?i)PANICORE_Controller_Portable_v[0-9.]+[^\\/]*[\\/]' -and
                [string]$radarScript -ine [IO.Path]::Combine($Root,'Radar_View.ps1')) {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
                Say 'Closed a leftover radar viewer from an older controller.'
            }
        }
    } catch { Warn ('Could not inspect older radar processes: ' + $_.Exception.Message) }
}
function Stop-Owned-Radar {
    $pidFile = [IO.Path]::Combine($StateFolder,'radar-process.id')
    if (-not [IO.File]::Exists($pidFile)) { return }
    try {
        $radarPid = 0
        if (-not [int]::TryParse([IO.File]::ReadAllText($pidFile).Trim(),[ref]$radarPid)) { return }
        $record = Get-CimInstance Win32_Process -Filter ("ProcessId=$radarPid") -ErrorAction Stop
        if ($record -and [string]$record.Name -ieq 'powershell.exe' -and
            [string]$record.CommandLine -like ('*'+[IO.Path]::Combine($Root,'Radar_View.ps1')+'*')) {
            Stop-Process -Id $radarPid -Force -ErrorAction Stop
            Say 'Stopped the controller-owned radar viewer.'
        }
    } catch { Warn ('Could not stop older radar process: ' + $_.Exception.Message) }
    finally { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
}

function Cleanup-Portable-And-Prior {
    if (Running-Game) { Fail 'Close PANICORE before uninstalling the mod.' }
    Stop-Owned-Radar
    Stop-Legacy-Radar
    if ([IO.File]::Exists($SessionFile)) {
        try { Collect-Diagnostics } catch { Warn ('Could not preserve logs before cleanup: '+$_.Exception.Message) }
        Cleanup-Game $false
    }
    $bin = Choose-Game $false
    if (-not $bin) {
        Say 'No game found through Steam. If a loader remains on this PC, locate PANICORE through Steam > Browse local files.'
        $answer = Read-Host 'Paste its folder path to check, or press Enter to finish'
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $bin = Game-Bin $answer }
    }
    if ($bin) { Cleanup-Recognized-Deployment $bin }
    Say 'Cleanup finished. PANICORE saves and Steam files were not changed.'
    Say 'The portable folder and Reports are retained; you may delete that folder yourself when no longer needed.'
}

function Collect-Diagnostics {
    Folder $Reports
    Folder $CurrentReports
    Folder $StateFolder
    $state = JSON-Read $SessionFile
    $paths = New-Object System.Collections.Generic.List[string]
    [void]$paths.Add([IO.Path]::Combine($UE4SSRoot,'UE4SS.log'))
    if ($state) { [void]$paths.Add([IO.Path]::Combine([string]$state.GameBin,'ue4ss','UE4SS.log')) }
    $uniqueLogs = New-Object System.Collections.Generic.List[string]
    $seenLogHashes = @{}
    foreach ($log in @($paths | Select-Object -Unique)) {
        if (-not [IO.File]::Exists($log)) { continue }
        $fileHash = Hash $log
        if ($seenLogHashes.ContainsKey($fileHash)) { continue }
        $seenLogHashes[$fileHash] = $true
        [void]$uniqueLogs.Add($log)
    }
    # One report per unique log content, not one per collector invocation. When
    # the launcher automatically collects, a later click of 02 reuses its ZIP.
    # Also fingerprint setup evidence: if PANICORE never launched, a changed
    # preflight/startup failure must create an updated report rather than
    # silently returning a ZIP from an older successful gameplay session.
    $evidenceNames = @('startup-last.txt','preflight-last.txt','radar-viewer-status.txt','PHC_LastOperation.txt','RadarItems_Last.tsv','cleanup-last.txt')
    $evidenceHashes = New-Object System.Collections.Generic.List[string]
    foreach ($evidenceName in $evidenceNames) {
        $evidencePath = [IO.Path]::Combine($CurrentReports,$evidenceName)
        if ([IO.File]::Exists($evidencePath)) {
            try { [void]$evidenceHashes.Add($evidenceName + ':' + (Hash $evidencePath)) }
            catch { [void]$evidenceHashes.Add($evidenceName + ':unreadable') }
        }
    }
    $fingerprint = (@($seenLogHashes.Keys | Sort-Object) + @($evidenceHashes | Sort-Object)) -join '|'
    if ($fingerprint -eq '') { $fingerprint = 'NO-LOGS-OR-STARTUP-EVIDENCE' }
    $previous = JSON-Read $LastReportFile
    if ($previous -and $previous.Fingerprint -eq $fingerprint -and
        $previous.Zip -and [IO.File]::Exists([string]$previous.Zip)) {
        Say ('No new game log found. Reusing the single existing diagnostic ZIP: ' + $previous.Zip)
        return
    }

    $moment = Get-Date -Format 'yyyyMMdd_HHmmss'
    $txt = [IO.Path]::Combine($CurrentReports, 'SUMMARY_LAST.txt')
    $zip = [IO.Path]::Combine($Reports, ('PHC_Diagnostics_' + $moment + '.zip'))
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('PANICORE Portable Host Controller - diagnostic summary')
    [void]$lines.Add('Created: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$lines.Add('Setup version: ' + $Version)
    [void]$lines.Add('Diagnostics are local only. Review before uploading to anyone.')
    [void]$lines.Add('')
    if ($state) {
        [void]$lines.Add('Deployment method: ' + [string]$state.Method)
        $bin = [string]$state.GameBin
        $destLua = [IO.Path]::Combine($bin,'ue4ss','Mods','PanicoreHostControl','Scripts','main.lua')
        [void]$lines.Add('Game-side main.lua: ' + [IO.File]::Exists($destLua))
        [void]$lines.Add('Game-side dwmapi.dll: ' + [IO.File]::Exists([IO.Path]::Combine($bin,'dwmapi.dll')))
    } else { [void]$lines.Add('No active game-side deployment at report time.') }
    [void]$lines.Add('Portable UE4SS.dll present: ' + [IO.File]::Exists([IO.Path]::Combine($UE4SSRoot,'UE4SS.dll')))
    [void]$lines.Add('Portable controller Lua present: ' + [IO.File]::Exists([IO.Path]::Combine($UE4SSRoot,'Mods','PanicoreHostControl','Scripts','main.lua')))
    # Runtime fingerprints allow crash comparisons across changing UE4SS
    # experimental releases. No uploaded binary or local account data required.
    foreach ($pair in @(
        @('UE4SS.dll', [IO.Path]::Combine($UE4SSRoot,'UE4SS.dll')),
        @('portable dwmapi.dll', $ProxySource),
        @('controller main.lua', [IO.Path]::Combine($ModSource,'Scripts','main.lua'))
    )) {
        $filename = [string]$pair[0]
        $path = [string]$pair[1]
        if ([IO.File]::Exists($path)) {
            try { [void]$lines.Add('SHA256 ' + $filename + ': ' + (Hash $path)) }
            catch { [void]$lines.Add('SHA256 ' + $filename + ': unavailable') }
        }
    }
    if ($state) {
        $exe = [IO.Path]::Combine([string]$state.GameBin,'Panicore-Win64-Shipping.exe')
        if ([IO.File]::Exists($exe)) {
            try { [void]$lines.Add('SHA256 game executable: ' + (Hash $exe)) }
            catch { [void]$lines.Add('SHA256 game executable: unavailable') }
        }
    }


    foreach ($log in $uniqueLogs) {
        [void]$lines.Add('')
        [void]$lines.Add('--- UE4SS controller messages / loader errors ---')
        $tail = @(Get-Content -LiteralPath $log -Tail 30000 -ErrorAction Stop)
        $filtered = @($tail | Where-Object { $_ -match '(?i)\[PHC|PanicoreHostControl|\[ERROR\]|\[FATAL\]|UE4SS.*(error|fail|exception)' } | Select-Object -Last 12000)
        if ($filtered.Count -eq 0) { [void]$lines.Add('(No matching lines.)') }
        foreach ($line in $filtered) {
            $redacted = $line -replace '(?i)[A-Z]:\\Users\\[^\\\s]+\\', '<USER_HOME>\\'
            [void]$lines.Add([string]$redacted)
        }
        [void]$lines.Add('Matching lines: ' + $filtered.Count)
    }
    if ($uniqueLogs.Count -eq 0) { [void]$lines.Add('No UE4SS.log found. Loader or game may not have started.') }
    $radarStatus = [IO.Path]::Combine($CurrentReports,'radar-viewer-status.txt')
    if ([IO.File]::Exists($radarStatus)) {
        [void]$lines.Add('--- Radar viewer startup/status ---')
        foreach ($line in @(Get-Content -LiteralPath $radarStatus -Tail 25 -ErrorAction SilentlyContinue)) {
            [void]$lines.Add([string]$line)
        }
    }

    $startupPath = [IO.Path]::Combine($CurrentReports,'startup-last.txt')
    if ([IO.File]::Exists($startupPath)) {
        [void]$lines.Add('--- Setup/launcher output ---')
        foreach ($line in @(Get-Content -LiteralPath $startupPath -Tail 250 -ErrorAction SilentlyContinue)) {
            $clean = ([string]$line) -replace '(?i)[A-Z]:\\Users\\[^\\\s]+\\','<USER_HOME>\\'
            [void]$lines.Add($clean)
        }
    }
    [void]$lines.Add('')
    [void]$lines.Add('INTERPRETATION NOTE: FREEZE COMMAND APPLIED means the game API accepted the calls,')
    [void]$lines.Add('not that a remote multiplayer client saw the freeze. Distance=0 may also mean idle.')
    [void]$lines.Add('Flying movement mode ignores gravity; collision-off does not preserve floor collision.')
    [void]$lines.Add('Skin unlocks and zombie progression are not modified by this release.')
    [void]$lines.Add('No achievement or saved-game values are modified.')
    [void]$lines.Add('v0.11.6.2: original gameplay logic, BOM fix and radar perf preserved; consoles disabled; report command added.')
    # One upload ZIP, with raw evidence kept inside the Reports tree.
    # No saves, achievement values or binaries from the game directory are collected.
    $stage = [IO.Path]::Combine($Reports,'.building-'+[Guid]::NewGuid().ToString('N'))
    Folder $stage
    try {
        $summaryPath=[IO.Path]::Combine($stage,'SUMMARY.txt')
        [IO.File]::WriteAllLines($summaryPath,$lines.ToArray(),(New-Object Text.UTF8Encoding($false)))
        # The only user-facing report artifact is the ZIP in Reports/.
        [IO.File]::WriteAllLines($txt,$lines.ToArray(),(New-Object Text.UTF8Encoding($false)))
        $index=0
        foreach ($sourceLog in $uniqueLogs) {
            $index++
            Copy-Item -LiteralPath $sourceLog -Destination ([IO.Path]::Combine($stage,('UE4SS-'+$index+'.log')))
        }
        foreach ($name in $evidenceNames) {
            $evidence=[IO.Path]::Combine($CurrentReports,$name)
            if ([IO.File]::Exists($evidence)) { Copy-Item -LiteralPath $evidence -Destination ([IO.Path]::Combine($stage,$name)) }
        }
        foreach ($sourceConfig in @([IO.Path]::Combine($UE4SSRoot,'UE4SS-settings.ini'),[IO.Path]::Combine($UE4SSRoot,'Mods','mods.txt'))) {
            if ([IO.File]::Exists($sourceConfig)) { Copy-Item -LiteralPath $sourceConfig -Destination $stage }
        }
        # Include only crash files from this session, rather than unrelated older crashes.
        $cutoff = [datetime]::UtcNow.AddMinutes(-2)
        if ($state -and $state.Created) {
            try { $cutoff=([datetime]::Parse([string]$state.Created)).ToUniversalTime().AddSeconds(-5) } catch { }
        }
        $crashRoot=[IO.Path]::Combine($env:LOCALAPPDATA,'Panicore','Saved','Crashes')
        if ([IO.Directory]::Exists($crashRoot)) {
            $contexts=@(Get-ChildItem -LiteralPath $crashRoot -Filter 'CrashContext.runtime-xml' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $cutoff } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 2)
            $crashIndex=0
            foreach ($context in $contexts) {
                $crashIndex++
                $dest=[IO.Path]::Combine($stage,('Crash-'+$crashIndex))
                Folder $dest
                foreach ($name in @('CrashContext.runtime-xml','CrashReportClient.ini','UEMinidump.dmp')) {
                    $sourceCrash=[IO.Path]::Combine($context.Directory.FullName,$name)
                    if ([IO.File]::Exists($sourceCrash)) {
                        $size=(Get-Item -LiteralPath $sourceCrash).Length
                        if ($size -le 64MB) { Copy-Item -LiteralPath $sourceCrash -Destination $dest }
                        else { [IO.File]::AppendAllText($summaryPath,('Crash file omitted (over 64 MB): '+$name+[Environment]::NewLine)) }
                    }
                }
            }
        }
        [IO.File]::WriteAllText([IO.Path]::Combine($stage,'PRIVACY.txt'),
            'This local report can contain Windows paths, machine identifiers, raw loader logs, and crash dumps. Review it before uploading. No automatic upload occurs.')
        Compress-Archive -Path ([IO.Path]::Combine($stage,'*')) -DestinationPath $zip -CompressionLevel Optimal -Force
        JSON-Save $LastReportFile ([ordered]@{ Fingerprint=$fingerprint; Zip=$zip; Created=(Get-Date).ToString('o') })
    } finally {
        if ([IO.Directory]::Exists($stage)) { Remove-Item -LiteralPath $stage -Force -Recurse }
    }
    Say ('ONE diagnostic ZIP created: ' + $zip)
    Say 'It includes the summary, full loader log, runtime configuration and matching crash files when available.'

}
# Before experimental cosmetic/progression changes, back up the local PANICORE SaveGames.
# This does not touch Steam Cloud and never deletes existing saves.
function Start-Hidden-Radar([string]$radarFile) {
    # Start-Process -WindowStyle Hidden alone can briefly flash a console window.
    # CreateNoWindow prevents the secondary PowerShell process from allocating
    # a new console. Its WinForms radar window remains separately visible on F5.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [IO.Path]::Combine($PSHOME, 'powershell.exe')
    $psi.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "' + $radarFile + '"'
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) { Fail 'Windows did not start the background radar viewer.' }
    return $proc
}
function Launch-Game {
    if (Running-Game) { Fail 'Close PANICORE before using the portable launcher.' }
    Stop-Owned-Radar
    Stop-Legacy-Radar
    if ([IO.File]::Exists($SessionFile)) {
        $prior = JSON-Read $SessionFile
        $priorBin = if ($prior) { [string]$prior.GameBin } else { '' }
        if ($priorBin -and -not [IO.Directory]::Exists($priorBin)) {
            # When this single folder is copied to another computer, the prior
            # computer's game path may be gone. Archive rather than deleting
            # old cleanup information; users should clean up on the old PC first.
            $archive = [IO.Path]::Combine($Reports, ('unresolved-previous-machine-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'))
            [IO.File]::Move($SessionFile, $archive)
            Warn ('Previous machine path is unavailable. Archived old session to ' + $archive)
            Warn 'If the old computer still has staged loader files, run its cleanup utility there.'
        } else {
            Warn 'A previous temporary game deployment was detected. Preserving any previous game log before cleanup.'
            try { Collect-Diagnostics } catch { Warn ('Could not preserve previous diagnostics: ' + $_.Exception.Message) }
            Cleanup-Game $false
            if ([IO.File]::Exists($SessionFile)) { Fail 'Old deployment could not be cleaned. Use Uninstall.cmd and inspect its warning.' }
        }
    }
    $bin = Choose-Game $true
    Say ('PANICORE detected at: ' + $bin)
    Folder $StateFolder
    [IO.File]::WriteAllText($SavedGamePathFile, $bin, (New-Object Text.UTF8Encoding($false)))
    # Preflight before downloads. Clean only verified previous controller loaders.
    Cleanup-Recognized-Deployment $bin
    Assert-No-Conflicts $bin
    Ensure-VCRuntime
    Ensure-Runtime
    # No progression writes: automatic backups are intentionally disabled.
    $started = $false
    $radarProcess = $null
    try {
        Stage-Game $bin
        Say 'Launching PANICORE via Steam (app 2695940)...'
        try {
            Start-Process -FilePath ('steam://rungameid/' + $SteamAppID) -ErrorAction Stop | Out-Null
        } catch {
            Warn ('Steam launch link did not open: ' + $_.Exception.Message)
            Say 'Open PANICORE yourself from Steam now. The controller will watch for its process.'
        }
        $process = $null
        for ($second = 0; $second -lt 150; $second++) {
            $process = @(Get-Process -Name 'Panicore-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($process.Count -gt 0) { $started = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $started) {
            Fail 'PANICORE did not start within the launch-check window. Temporary game files will be removed.'
        }
        Say 'PANICORE launched. Keep this launcher window open until you exit the game.'
        $radarProcess = $null
        $radarFile = [IO.Path]::Combine($Root,'Radar_View.ps1')
        if ([IO.File]::Exists($radarFile)) {
            try {
                $radarProcess = Start-Hidden-Radar $radarFile
                [IO.File]::WriteAllText([IO.Path]::Combine($StateFolder,'radar-process.id'), [string]$radarProcess.Id)
                Say 'Radar viewer started hidden. F5 shows it; Shift+UP zooms OUT, Shift+DOWN zooms IN (only while open).'
            } catch { Warn ('Could not start radar viewer: '+$_.Exception.Message) }
        } else { Warn 'Radar_View.ps1 is missing: F5 will record positions but show no window.' }
        Say 'Controls: F5 radar window | F6 freeze/unfreeze ALL monsters | F7 noclip (Space UP, Ctrl DOWN) | F8 return to spawn.'
        Say 'Progression is NOT modified by this version. One gameplay report is created automatically in Reports.'
        # Steam can exit its launcher while the game remains running, so watch the real shipping process.
        while (Running-Game) { Start-Sleep -Seconds 2 }
        Say 'PANICORE closed.'
        Start-Sleep -Seconds 2
    } finally {
        if ($radarProcess) {
            try {
                $radarProcess.Refresh()
                if (-not $radarProcess.HasExited) { Stop-Process -Id $radarProcess.Id -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
        $pidFile = [IO.Path]::Combine($StateFolder,'radar-process.id')
        if ([IO.File]::Exists($pidFile)) { [IO.File]::Delete($pidFile) }
        try { Collect-Diagnostics } catch { Warn ('Could not automatically collect diagnostics: ' + $_.Exception.Message) }
        try { Cleanup-Game $false } catch { Warn ('Game cleanup failed: ' + $_.Exception.Message); Warn 'Run Uninstall.cmd after closing PANICORE.' }
    }
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (' PANICORE Controller ' + $Version) -ForegroundColor Cyan
Write-Host (' Action: ' + $Action) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host ''
try {
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'This controller requires a 64-bit Windows device.' }
    switch ($Action) {
        'Launch' { Launch-Game }
        'Cleanup' { Cleanup-Portable-And-Prior }
        'Diagnostics' { Collect-Diagnostics }
        'Check' {
            $bin = Choose-Game $false
            if ($bin) { Say ('PANICORE found: ' + $bin) } else { Warn 'PANICORE not auto-detected. Launcher will ask for the folder.' }
            $runtime = Get-VCRuntime
            if ($runtime) { Say ('Visual C++ runtime: ' + $runtime) } else { Warn 'Visual C++ x64 runtime not detected.' }
            if ([IO.File]::Exists([IO.Path]::Combine($UE4SSRoot,'UE4SS.dll')) -and [IO.File]::Exists($ProxySource)) {
                Say 'UE4SS portable framework found.'
            } else { Say 'UE4SS portable framework missing; launcher will download it.' }
            if ([IO.File]::Exists($SessionFile)) { Warn 'Temporary game deployment recorded. Cleanup may be needed.' }
            Say 'No game files were changed by this status check.'
        }
    }
} catch {
    Write-Host ''
    Write-Host ('[STOPPED] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No security exclusions, anti-cheat bypasses or Steam configuration changes were attempted.'
    # Transcript is the preferred log. Keep a small error record even if
    # a locked-down Windows host refused to start transcription.
    if (-not $script:phcTranscriptStarted -and -not [string]::IsNullOrWhiteSpace($StartupLog)) {
        try { [IO.File]::AppendAllText($StartupLog, ('[STOPPED] ' + $_.Exception.Message + [Environment]::NewLine)) } catch { }
    }
    $script:phcActionFailed = $true
    try { if ($Action -eq 'Launch') { Collect-Diagnostics } } catch { Write-Host ('[REPORT ERROR] ' + $_.Exception.Message) }
} finally {
    if ($script:phcTranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
if ($script:phcActionFailed) { exit 1 }
