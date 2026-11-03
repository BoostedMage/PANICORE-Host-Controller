# PANICORE Controller v0.11.6.2 preflight. Windows PowerShell 5.1.
# Self-consistent checks; no references to deleted controls/banner scripts.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$script:errors = 0
function Bad([string]$kind,[string]$message) {
    $script:errors++
    Write-Host ('[ERROR] '+$kind+': '+$message) -ForegroundColor Red
}
function Good([string]$message) { Write-Host ('[OK] '+$message) -ForegroundColor Green }
$files = @('Verify_PowerShell.ps1','Portable_Controller.ps1','Radar_View.ps1')
foreach ($relative in $files) {
    $path = [IO.Path]::Combine($root,$relative)
    if (-not [IO.File]::Exists($path)) { Bad 'Syntax' ('Missing '+$relative); continue }
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        foreach ($issue in $parseErrors) {
            Bad 'Syntax' ('{0}:{1}:{2}: {3}' -f $relative,$issue.Extent.StartLineNumber,$issue.Extent.StartColumnNumber,$issue.Message)
        }
    } else { Good ('Syntax: '+$relative) }
}
$manifest = [IO.Path]::Combine($root,'SHA256_MANIFEST.txt')
$expected=@{}
if (-not [IO.File]::Exists($manifest)) { Bad 'Integrity' 'Manifest missing' }
else {
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64})  ([^\r\n]+)$') { Bad 'Integrity' ('Invalid manifest line: '+$line); continue }
        $digest=$Matches[1].ToUpperInvariant();$rel=$Matches[2]
        if ([IO.Path]::IsPathRooted($rel) -or $rel -match '(?:^|[/\\])\.\.(?:[/\\]|$)') { Bad 'Integrity' ('Unsafe path: '+$rel); continue }
        $path = [IO.Path]::GetFullPath([IO.Path]::Combine($root,$rel.Replace('/','\')))
        if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Bad 'Integrity' ('Escaped package: '+$rel); continue }
        if ($expected.ContainsKey($rel)) { Bad 'Integrity' ('Duplicate manifest item: '+$rel); continue }
        $expected[$rel]=$true
        if (-not [IO.File]::Exists($path)) { Bad 'Integrity' ('Missing '+$rel); continue }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant() -ne $digest) { Bad 'Integrity' ('Checksum mismatch '+$rel) }
    }
    foreach ($name in @('Verify_PowerShell.ps1','Portable_Controller.ps1','Radar_View.ps1','Mods/PanicoreHostControl/Scripts/main.lua')) {
        if (-not $expected.ContainsKey($name)) { Bad 'Integrity' ('Required asset not in manifest: '+$name) }
    }
    if ($expected.Count -ne 4) { Bad 'Integrity' ('Expected exactly 4 source assets, found '+$expected.Count) }
    if ($script:errors -eq 0) { Good ('Integrity: '+$expected.Count+' files match') }
}
$lua = [IO.Path]::Combine($root,'Mods','PanicoreHostControl','Scripts','main.lua')
$radar = [IO.Path]::Combine($root,'Radar_View.ps1')
# UE4SS's Lua interpreter rejects UTF-8 BOM at the start of main.lua.
# Check RAW BYTES: ReadAllText/Get-Content silently remove a BOM and did not
# detect the v0.11.6 regression. This must run before game-side deployment.
if ([IO.File]::Exists($lua)) {
    try {
        [byte[]]$luaBytes = [IO.File]::ReadAllBytes($lua)
        if ($luaBytes.Length -eq 0) {
            Bad 'Lua encoding' 'Controller main.lua is empty.'
        } elseif (($luaBytes.Length -ge 3) -and $luaBytes[0] -eq 239 -and $luaBytes[1] -eq 187 -and $luaBytes[2] -eq 191) {
            Bad 'Lua encoding' 'UTF-8 BOM detected in main.lua. UE4SS cannot load it; use the corrected package.'
        } elseif (($luaBytes.Length -ge 2) -and ((($luaBytes[0] -eq 255) -and ($luaBytes[1] -eq 254)) -or (($luaBytes[0] -eq 254) -and ($luaBytes[1] -eq 255)))) {
            Bad 'Lua encoding' 'UTF-16 byte-order mark detected in main.lua; Lua requires UTF-8 without BOM.'
        } elseif ([Array]::IndexOf($luaBytes,[byte]0) -ge 0) {
            Bad 'Lua encoding' 'NUL byte found in main.lua; check for unsupported Unicode/encoding.'
        } else {
            $strictUtf8 = [System.Text.UTF8Encoding]::new($false,$true)
            [void]$strictUtf8.GetString($luaBytes)
            Good 'Lua encoding: UTF-8 without BOM or NUL bytes.'
        }
    } catch {
        Bad 'Lua encoding' ('Unable to validate main.lua: ' + $_.Exception.Message)
    }
}
if ([IO.File]::Exists($lua) -and [IO.File]::Exists($radar)) {
    $l=[IO.File]::ReadAllText($lua);$r=[IO.File]::ReadAllText($radar)
    foreach ($key in @('Key.F5','Key.F6','Key.F7','Key.F8','frozen_actor_keys','item_snapshot','SlenderLikes','RADAR ITEM SCAN','LoopInGameThreadWithDelay','GetControlRotation','PHC2','refresh_pickups','StaticFindObject','RadarItems_Last.tsv')) {
        if (-not $l.Contains($key)) { Bad 'Feature' ('Missing '+$key) }
    }
    if ($l.Contains('scanned > 2500')) { Bad 'Feature' 'Obsolete 2500 actor item cutoff restored' }
    if ($l -match '(?m)^\s*(?:ExecuteWithDelay|ExecuteInGameThread)\s*\(') { Bad 'Feature' 'Independent native callback chain restored' }
    if ($l -match 'RegisterBeginPlayPostHook\s*\(') { Bad 'Feature' 'Unsafe global spawn hook restored' }
    foreach ($feature in @('WS_EX_TRANSPARENT','WS_EX_NOACTIVATE','HTTRANSPARENT','DrawFrozenSnowflake','DrawAltitudeArrow','RegisterHotKey','HEADING UP','targetYaw','PHC2','DrawEdgeChevron','seenIdentities','labelGroups','IMPORTANT','Get-RadarProjection')) {
        if (-not $r.Contains($feature)) { Bad 'Feature' ('Radar function missing '+$feature) }
    }
    if ($r.Contains('Select-Object -First 22')) { Bad 'Feature' 'Item-count cap restored' }
    if ($r.Contains('$linePen') -or $r.Contains('for ($yy=90;')) { Bad 'Feature' 'Distant label placement or connector lines restored' }
    if ($r.Contains('Add_MouseWheel') -or $r -match '\$(?:zoomOutButton|zoomInButton)\s*=') { Bad 'Feature' 'Mouse zoom restored' }
    # A small set of real, version-specific performance safeguards.
    if (-not $l.Contains('set_job("radar",200,build_snapshot)')) { Bad 'Performance' 'Radar sampling budget missing' }
    if (-not $l.Contains('WORK.now-lastPickupRefresh>=1000')) { Bad 'Performance' 'Pickup check budget missing' }
    if (-not $r.Contains('$timer.Interval = 90')) { Bad 'Performance' 'Radar WinForms throttling missing' }
    if (-not $r.Contains('$script:labelBrushes')) { Bad 'Performance' 'Caption brush cache missing' }
    if (-not $r.Contains('$dotBoxes')) { Bad 'Performance' 'Marker collision cache missing' }
    if (-not $r.Contains('$script:drawOrder')) { Bad 'Performance' 'Snapshot-time contact sorting missing' }
}
# Verify launcher/report scripts and that helper windows remain intentionally hidden.
$packageRoot = [IO.Path]::GetDirectoryName($root)
foreach ($requiredCmd in @('START_HERE.cmd','Uninstall.cmd','Generate_Report.cmd')) {
    if (-not [IO.File]::Exists([IO.Path]::Combine($packageRoot,$requiredCmd))) {
        Bad 'Package' ('Missing command: '+$requiredCmd)
    } else { Good ('Command: '+$requiredCmd) }
}
if ([IO.File]::Exists([IO.Path]::Combine($packageRoot,'CLEANUP_UNINSTALL.cmd'))) {
    Bad 'Package' 'Old CLEANUP_UNINSTALL.cmd should not be packaged.'
}
$controllerPath = [IO.Path]::Combine($root,'Portable_Controller.ps1')
if ([IO.File]::Exists($controllerPath)) {
    $controllerText = [IO.File]::ReadAllText($controllerPath)
    foreach ($iniSetting in @('ConsoleEnabled','GuiConsoleEnabled','GuiConsoleVisible')) {
        if (-not $controllerText.Contains("Set-Private-Ini `$settings 'Debug' '$iniSetting' '0'")) {
            Bad 'Windows' ('UE4SS console setting not disabled: '+$iniSetting)
        }
    }
    if (-not $controllerText.Contains('$psi.CreateNoWindow = $true') -or
        -not $controllerText.Contains('$psi.UseShellExecute = $false') -or
        -not $controllerText.Contains('Start-Hidden-Radar $radarFile')) {
        Bad 'Windows' 'Radar helper process must be started without a console.'
    }
    if (-not $controllerText.Contains("'Diagnostics' { Collect-Diagnostics }")) {
        Bad 'Report' 'Diagnostics action was removed.'
    }
    if (-not $controllerText.Contains("$evidenceNames = @('startup-last.txt'")) {
        Bad 'Report' 'Startup failure evidence is missing from report fingerprints.'
    }
}
# Verify the actual display-math function, not a separate copy. This does not
# execute Radar_View.ps1 or create a WinForms window.
if ($script:errors -eq 0 -and [IO.File]::Exists($radar)) {
    try {
        $pt=$null; $pe=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($radar,[ref]$pt,[ref]$pe)
        $definition=$ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-RadarProjection'
        },$true)
        if ($null -eq $definition) { throw 'Projection function not found.' }
        . ([scriptblock]::Create($definition.Extent.Text))
        foreach ($meters in @(15,25,40,70,110,170)) {
            $inside=Get-RadarProjection -dx ($meters*100.0) -dy 0 -dz 0 -headingDegrees 0 -rangeMeters $meters -radius 250 -centerX 300 -centerY 300
            $outside=Get-RadarProjection -dx ($meters*100.0+1) -dy 0 -dz 0 -headingDegrees 0 -rangeMeters $meters -radius 250 -centerX 300 -centerY 300
            if ($null -eq $inside -or $inside.Edge -or $null -ne $outside) { throw ('Range boundary failed at '+$meters+'m.') }
        }
        $far=Get-RadarProjection -dx 50000 -dy 0 -dz 0 -headingDegrees 0 -rangeMeters 250 -radius 250 -centerX 300 -centerY 300
        if ($null -eq $far -or -not $far.Edge -or [math]::Abs($far.Px-300) -gt 0.01 -or [math]::Abs($far.Py-62) -gt 0.01) { throw '250m overview rim failed.' }
        $front=Get-RadarProjection -dx 0 -dy 1000 -dz 0 -headingDegrees 90 -rangeMeters 70 -radius 250 -centerX 300 -centerY 300
        if ($null -eq $front -or [math]::Abs($front.Px-300) -gt 0.01 -or $front.Py -ge 300) { throw 'Heading-up rotation failed.' }
        $above=Get-RadarProjection -dx 0 -dy 0 -dz 10000 -headingDegrees 0 -rangeMeters 15 -radius 250 -centerX 300 -centerY 300
        if ($null -eq $above -or $above.Edge -or [math]::Abs($above.RangeM-100) -gt 0.01) { throw 'Horizontal range / altitude separation failed.' }
        Good 'Radar math: normal range boundaries, 250m overview, heading and height.'
    } catch { Bad 'Radar math' ([string]$_.Exception.Message) }
}
if ($script:errors -gt 0) {
    Write-Host ('[STOPPED] '+$script:errors+' errors; PANICORE was not modified.') -ForegroundColor Red
    exit 1
}
Good 'Package verification passed. The live game remains untested.'
exit 0
