# PANICORE radar companion v0.11.6 - performance; unchanged 250m/all-contact and range views.
# Display-only correction. Game-side bridge and all gameplay controls are unchanged.
# Windows PowerShell 5.1, .NET/WinForms. Runs locally; never sends coordinates online.
[CmdletBinding()]
param([switch]$Demo)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$OutLog = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Root),'Reports','Current','radar-viewer-status.txt')
function LogMessage([string]$message) {
    try {
        $parent = [IO.Path]::GetDirectoryName($OutLog)
        if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::AppendAllText($OutLog, ('{0} {1}' -f (Get-Date -Format 's'),$message) + [Environment]::NewLine)
    } catch { }
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $Invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # No-activate prevents F5 opening the viewer from stealing game focus.
    # Optimized double buffering prevents a blank repaint between position snapshots.
    # OS hotkeys are registered ONLY while the radar is visible, unregistered on F5 hide.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public sealed class PHCRadarNoFocusForm : Form {
    const uint MOD_SHIFT = 0x0004;
    const uint MOD_NOREPEAT = 0x4000;
    const uint VK_UP = 0x26;
    const uint VK_DOWN = 0x28;
    const int WM_HOTKEY = 0x0312;
    const int WM_NCHITTEST = 0x0084;
    const int WM_MOUSEACTIVATE = 0x0021;
    const int HTTRANSPARENT = -1;
    const int MA_NOACTIVATEANDEAT = 4;
    const int WS_EX_TRANSPARENT = 0x00000020;
    const int WS_EX_LAYERED = 0x00080000;
    const int WS_EX_NOACTIVATE = 0x08000000;
    const int HOTKEY_ZOOM_OUT = 0x4C01;
    const int HOTKEY_ZOOM_IN = 0x4C02;
    bool outRegistered = false;
    bool inRegistered = false;
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);
    public event EventHandler ZoomOutRequested;
    public event EventHandler ZoomInRequested;
    public bool ZoomHotkeysAvailable { get { return outRegistered && inRegistered; } }
    public PHCRadarNoFocusForm() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        this.UpdateStyles();
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT; return cp; }
    }
    private void UpdateHotkeys(bool visible) {
        if (visible && this.IsHandleCreated) {
            if (!outRegistered) outRegistered = RegisterHotKey(this.Handle, HOTKEY_ZOOM_OUT, MOD_SHIFT | MOD_NOREPEAT, VK_UP);
            if (!inRegistered) inRegistered = RegisterHotKey(this.Handle, HOTKEY_ZOOM_IN, MOD_SHIFT | MOD_NOREPEAT, VK_DOWN);
        } else {
            if (this.IsHandleCreated) {
                if (outRegistered) UnregisterHotKey(this.Handle, HOTKEY_ZOOM_OUT);
                if (inRegistered) UnregisterHotKey(this.Handle, HOTKEY_ZOOM_IN);
            }
            outRegistered = false;
            inRegistered = false;
        }
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        // Full opacity; WS_EX_TRANSPARENT makes mouse hit testing pass through.
        SetLayeredWindowAttributes(this.Handle, 0, 255, 2);
        if (this.Visible) UpdateHotkeys(true);
    }
    protected override void OnVisibleChanged(EventArgs e) {
        base.OnVisibleChanged(e);
        UpdateHotkeys(this.Visible);
    }
    protected override void OnHandleDestroyed(EventArgs e) {
        UpdateHotkeys(false);
        base.OnHandleDestroyed(e);
    }
    protected override void WndProc(ref Message m) {
        // Radar is a display, not an input surface. Never activate/capture mouse.
        if (m.Msg == WM_NCHITTEST) { m.Result = (IntPtr)HTTRANSPARENT; return; }
        if (m.Msg == WM_MOUSEACTIVATE) { m.Result = (IntPtr)MA_NOACTIVATEANDEAT; return; }
        if (m.Msg == WM_HOTKEY) {
            int id = m.WParam.ToInt32();
            if (id == HOTKEY_ZOOM_OUT) {
                EventHandler callback = ZoomOutRequested;
                if (callback != null) callback(this, EventArgs.Empty);
                return;
            }
            if (id == HOTKEY_ZOOM_IN) {
                EventHandler callback = ZoomInRequested;
                if (callback != null) callback(this, EventArgs.Empty);
                return;
            }
        }
        base.WndProc(ref m);
    }
}
'@ -ReferencedAssemblies @('System.Windows.Forms','System.Drawing')

    $script:mapName = 'WAITING FOR PANICORE'
    $script:actors = @()
    $script:drawOrder = @()
    # Keep brushes across paints instead of allocating one for every caption.
    $script:labelBrushes = @{}
    $script:currentStamp = [datetime]::MinValue
    $script:sourceFresh = $false
    $script:lastProcessCheck = [datetime]::MinValue
    $script:gameRunning = $true
    $script:currentSnapshot = ''
    $script:targetYaw = [double]0
    $script:renderYaw = [double]0
    $script:headingReady = $false
    $script:headingSource = 'VIEW'
    $script:lastReadCheck = [datetime]::MinValue
    $script:lastReadError = ''
    # Radius of the radar circle in world meters. Index 3 = 70m (original view).
    $script:zoomRanges = @(15,25,40,70,110,170,250)
    $script:zoomIndex = 3
    $script:visibleItems = 0
    $script:lastPaintError = ''
    $script:hotkeyAvailabilityLogged = $false
    $script:colorBackground = [System.Drawing.Color]::FromArgb(12,20,29)
    $script:dim = [System.Drawing.Color]::FromArgb(143,166,176)
    $script:gold = [System.Drawing.Color]::FromArgb(255,213,89)
    $script:red = [System.Drawing.Color]::FromArgb(255,92,112)
    $script:cyan = [System.Drawing.Color]::FromArgb(66,196,255)
    $script:green = [System.Drawing.Color]::FromArgb(77,215,153)
    $script:playerColor = [System.Drawing.Color]::FromArgb(195,161,255)
    $script:edgeItems = 0
    $script:visibleEnemies = 0
    $script:visiblePlayers = 0
    $script:hiddenLabels = 0
    $script:iceBlue = [System.Drawing.Color]::FromArgb(78,196,255)

    $form = [PHCRadarNoFocusForm]::new()
    $form.Text = 'PANICORE - Live Radar'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.MinimumSize = [System.Drawing.Size]::new(480,545)
    $form.BackColor = $script:colorBackground
    $form.ForeColor = [System.Drawing.Color]::White
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $desktop = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $width = [math]::Min(620,[math]::Max(430,($desktop.Width-75)))
    $height = [math]::Min(690,[math]::Max(490,($desktop.Height-90)))
    $form.ClientSize = [System.Drawing.Size]::new([int]$width,[int]$height)
    $form.Location = [System.Drawing.Point]::new([int][math]::Max($desktop.Left,($desktop.Right-$form.Width-18)),[int]($desktop.Top+20))
    $script:primaryFont = [System.Drawing.Font]::new('Segoe UI',13,[System.Drawing.FontStyle]::Bold)
    $script:smallFont = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Regular)
    $script:markerFont = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Bold)

    function WriteLabel($graphics,[string]$text,[float]$x,[float]$y,$color,$font) {
        # A small set of fixed colors is used throughout the radar. Cache their
        # GDI brushes to avoid hundreds of allocations while turning the player.
        $key = [string]$color.ToArgb()
        $brush = $script:labelBrushes[$key]
        if ($null -eq $brush) {
            $brush = [System.Drawing.SolidBrush]::new($color)
            $script:labelBrushes[$key] = $brush
        }
        $graphics.DrawString($text,$font,$brush,$x,$y)
    }
    function DrawRing($graphics,[float]$centerX,[float]$centerY,[float]$radius,$color) {
        $pen = [System.Drawing.Pen]::new($color,1.0)
        try { $graphics.DrawEllipse($pen,($centerX-$radius),($centerY-$radius),($radius*2),($radius*2)) }
        finally { $pen.Dispose() }
    }
    # Draw an actual vector arrow instead of spelling UP/DOWN. Never use
    # font glyph substitutes: GDI+ draws identical arrows on any Windows install.
    function DrawAltitudeArrow($graphics,[float]$centerX,[float]$centerY,[int]$direction,$color) {
        $pen = [System.Drawing.Pen]::new($color,[float]1.8)
        try {
            if ($direction -gt 0) {
                $graphics.DrawLine($pen,[float]$centerX,[float]($centerY+5),[float]$centerX,[float]($centerY-5))
                $graphics.DrawLine($pen,[float]($centerX-3),[float]($centerY-2),[float]$centerX,[float]($centerY-5))
                $graphics.DrawLine($pen,[float]($centerX+3),[float]($centerY-2),[float]$centerX,[float]($centerY-5))
            } else {
                $graphics.DrawLine($pen,[float]$centerX,[float]($centerY-5),[float]$centerX,[float]($centerY+5))
                $graphics.DrawLine($pen,[float]($centerX-3),[float]($centerY+2),[float]$centerX,[float]($centerY+5))
                $graphics.DrawLine($pen,[float]($centerX+3),[float]($centerY+2),[float]$centerX,[float]($centerY+5))
            }
        } finally { $pen.Dispose() }
    }
    # A vector snowflake (not a font character) avoids missing-glyph issues.
    # This is drawn IN PLACE OF the red enemy dot when that enemy is frozen.
    function DrawFrozenSnowflake($graphics,[float]$centerX,[float]$centerY,$color) {
        $back = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(225,8,27,43))
        $rim = [System.Drawing.Pen]::new($color,[float]1.15)
        $crystal = [System.Drawing.Pen]::new($color,[float]2.0)
        try {
            $graphics.FillEllipse($back,[float]($centerX-11),[float]($centerY-11),[float]22,[float]22)
            $graphics.DrawEllipse($rim,[float]($centerX-11),[float]($centerY-11),[float]22,[float]22)
            foreach ($deg in @(0,60,120)) {
                $radians = [double]($deg*[math]::PI/180)
                $dx = [float](8.0*[math]::Cos($radians))
                $dy = [float](8.0*[math]::Sin($radians))
                $graphics.DrawLine($crystal,[float]($centerX-$dx),[float]($centerY-$dy),[float]($centerX+$dx),[float]($centerY+$dy))
            }
            # Two small branches per arm make a clearly recognizable snow crystal.
            foreach ($deg in @(0,60,120,180,240,300)) {
                $radians = [double]($deg*[math]::PI/180)
                $ux = [double][math]::Cos($radians)
                $uy = [double][math]::Sin($radians)
                $vx = -$uy
                $vy = $ux
                $tipX = [float]($centerX+8*$ux)
                $tipY = [float]($centerY+8*$uy)
                $forkAX = [float]($centerX+5*$ux+2.3*$vx)
                $forkAY = [float]($centerY+5*$uy+2.3*$vy)
                $forkBX = [float]($centerX+5*$ux-2.3*$vx)
                $forkBY = [float]($centerY+5*$uy-2.3*$vy)
                $graphics.DrawLine($rim,$tipX,$tipY,$forkAX,$forkAY)
                $graphics.DrawLine($rim,$tipX,$tipY,$forkBX,$forkBY)
            }
        } finally { $crystal.Dispose(); $rim.Dispose(); $back.Dispose() }
    }
    function DrawEdgeChevron($graphics,[float]$px,[float]$py,[float]$cx,[float]$cy,$color) {
        $dx=[double]($px-$cx); $dy=[double]($py-$cy)
        $len=[math]::Sqrt($dx*$dx+$dy*$dy)
        if ($len -le 0.001) { return }
        $ux=$dx/$len; $uy=$dy/$len
        $pen=[System.Drawing.Pen]::new($color,[float]2)
        try {
            $tx=[float]($px+8*$ux); $ty=[float]($py+8*$uy)
            $graphics.DrawLine($pen,[float]($px+2*$ux-4*$uy),[float]($py+2*$uy+4*$ux),$tx,$ty)
            $graphics.DrawLine($pen,[float]($px+2*$ux+4*$uy),[float]($py+2*$uy-4*$ux),$tx,$ty)
        } finally { $pen.Dispose() }
    }
    function Set-RadarZoom([int]$step) {
        $newIndex = [math]::Max(0,[math]::Min(($script:zoomRanges.Count-1),($script:zoomIndex+$step)))
        if ($newIndex -ne $script:zoomIndex) {
            $script:zoomIndex = [int]$newIndex
            $form.Invalidate()
        }
    }
    $form.add_ZoomOutRequested({ Set-RadarZoom 1 })   # Shift+UP = wider view.
    $form.add_ZoomInRequested({ Set-RadarZoom -1 })   # Shift+DOWN = closer view.
    # Deliberately NO mouse wheel and NO clickable zoom buttons. Radar is
    # a display-only companion while PANICORE stays the focused input target.
    # Shift+UP/DOWN is the ONLY zoom input when the radar is visible.

    # Pure display math; also exercised by the startup preflight without opening a window.
    # Range is horizontal (top-down radar); label distance retains full 3D distance.
    function Get-RadarProjection {
        param(
            [double]$dx, [double]$dy, [double]$dz, [double]$headingDegrees,
            [double]$rangeMeters, [double]$radius,
            [double]$centerX, [double]$centerY
        )
        foreach ($number in @($dx,$dy,$dz,$headingDegrees,$rangeMeters,$radius,$centerX,$centerY)) {
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        }
        if ($rangeMeters -le 0 -or $radius -le 12) { return $null }
        $rangeCm = $rangeMeters*100.0
        $horizontalSq = $dx*$dx+$dy*$dy
        $outsideRange = ($horizontalSq -gt ($rangeCm*$rangeCm))
        $overview = ($rangeMeters -eq 250)
        # Only the fully zoomed-out 250m view includes out-of-range contacts.
        if ($outsideRange -and -not $overview) { return $null }
        $angle = $headingDegrees*[math]::PI/180.0
        $forward = $dx*[math]::Cos($angle)+$dy*[math]::Sin($angle)
        $right = -$dx*[math]::Sin($angle)+$dy*[math]::Cos($angle)
        $rx = $right*$radius/$rangeCm
        $ry = -$forward*$radius/$rangeCm
        $pixelDistance = [math]::Sqrt($rx*$rx+$ry*$ry)
        # Inset marker graphics slightly at the boundary. This visual padding
        # must NOT classify an in-range contact as a distant rim contact.
        $safeRadius = $radius-12.0
        if ($pixelDistance -gt $safeRadius) {
            $rx = $rx*$safeRadius/$pixelDistance
            $ry = $ry*$safeRadius/$pixelDistance
        }
        return [pscustomobject]@{
            Px=[float]($centerX+$rx); Py=[float]($centerY+$ry)
            Edge=[bool]$outsideRange
            RangeM=[double]([math]::Sqrt($horizontalSq+$dz*$dz)/100.0)
        }
    }

    function FindRadarPath() {
        $paths = New-Object System.Collections.Generic.List[string]
        [void]$paths.Add([IO.Path]::Combine($Root,'Runtime','ue4ss','Mods','PanicoreHostControl','RadarSnapshot.tsv'))
        [void]$paths.Add([IO.Path]::Combine($Root,'Runtime','ue4ss','Mods','PanicoreHostControl','Scripts','PHC_RadarSnapshot.tsv'))
        $state = [IO.Path]::Combine($Root,'State','active-session.json')
        if ([IO.File]::Exists($state)) {
            try {
                $s = [IO.File]::ReadAllText($state) | ConvertFrom-Json
                $bin = [string]$s.GameBin
                if ($bin -and [IO.Directory]::Exists($bin)) {
                    [void]$paths.Add([IO.Path]::Combine($bin,'ue4ss','Mods','PanicoreHostControl','RadarSnapshot.tsv'))
                }
            } catch { }
        }
        $best = ''
        $mostRecent = [datetime]::MinValue
        foreach ($path in $paths) {
            try {
                if ([IO.File]::Exists($path)) {
                    $when = [IO.File]::GetLastWriteTimeUtc($path)
                    if ($when -gt $mostRecent) { $mostRecent = $when; $best = $path }
                }
            } catch { }
        }
        return $best
    }

    $form.Add_Paint({
        param($sender,$e)
        # A drawing failure must never escape the WinForms Paint event: otherwise
        # .NET shows its modal exception dialog and the window turns white/red-X.
        try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $cw = [float]$sender.ClientSize.Width
        $ch = [float]$sender.ClientSize.Height
        WriteLabel $g 'PANICORE  |  LIVE RADAR' 15 9 $script:cyan $script:primaryFont
        WriteLabel $g $script:mapName 16 38 $script:dim $script:smallFont
        $directionTitle = if ($script:headingSource -eq 'BODY') { 'BODY UP' } else { 'HEADING UP' }
        WriteLabel $g ('{0}  |  RANGE {1}m' -f $directionTitle,$script:zoomRanges[$script:zoomIndex]) ($cw-186) 38 $script:dim $script:smallFont
        WriteLabel $g 'SHIFT+UP: ZOOM OUT    SHIFT+DOWN: ZOOM IN' 16 58 $script:dim $script:smallFont

        # The circle expands with the WINDOW, not a fixed 155px cap.
        $rad = [float][math]::Max(90,[math]::Min(($cw/2-34),(($ch-175)/2)))
        $cx = [float]($cw/2)
        $cy = [float](85+(($ch-85-88)/2))
        $areaBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(22,42,48))
        try { $g.FillEllipse($areaBrush,($cx-$rad),($cy-$rad),($rad*2),($rad*2)) }
        finally { $areaBrush.Dispose() }
        foreach ($frac in @(0.25,0.5,0.75,1.0)) {
            DrawRing $g $cx $cy ([float]($rad*$frac)) ([System.Drawing.Color]::FromArgb(43,105,111))
        }
        $cross = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(30,88,92),1)
        try {
            $g.DrawLine($cross,($cx-$rad),$cy,($cx+$rad),$cy)
            $g.DrawLine($cross,$cx,($cy-$rad),$cx,($cy+$rad))
        } finally { $cross.Dispose() }
        WriteLabel $g 'AHEAD' ($cx-22) ($cy-$rad-20) $script:dim $script:markerFont
        $script:visibleItems = 0
        $script:edgeItems = 0
        $script:visibleEnemies = 0
        $script:visiblePlayers = 0
        $script:hiddenLabels = 0
        $you = $null
        foreach ($v in $script:actors) { if ($v.Kind -eq 'Y') { $you = $v; break } }
        if ($null -eq $you -or -not $script:headingReady) {
            WriteLabel $g 'Waiting for player position / direction...' ($cx-120) ($cy-10) $script:dim $script:smallFont
        } else {
            $rangeMeters = [double]$script:zoomRanges[$script:zoomIndex]
            # Contacts are grouped/sorted once per incoming snapshot, not once
            # per repaint. Normal zoom range filtering still happens below.
            $shown = New-Object System.Collections.Generic.List[object]
            $seenIdentities = @{}
            $script:visibleItems = 0
            $script:edgeItems = 0
            foreach ($a in $script:drawOrder) {
                # Identity, never label/proximity, defines a duplicate actor.
                $identity = [string]$a.Identity
                if ($identity) {
                    $identityKey = ([string]$a.Kind) + '|' + $identity
                    if ($seenIdentities.ContainsKey($identityKey)) { continue }
                    $seenIdentities[$identityKey] = $true
                }
                $dx = [double]($a.X-$you.X)
                $dy = [double]($a.Y-$you.Y)
                $dz = [double]($a.Z-$you.Z)
                $projected = Get-RadarProjection -dx $dx -dy $dy -dz $dz -headingDegrees $script:renderYaw -rangeMeters $rangeMeters -radius $rad -centerX $cx -centerY $cy
                if ($null -eq $projected) { continue }
                $edge = [bool]$projected.Edge
                $col = $script:gold
                if ($a.Kind -eq 'I' -and $a.Category -eq 'IMPORTANT') { $col = $script:green }
                elseif ($a.Kind -eq 'E') { if ($a.Frozen) { $col = $script:iceBlue } else { $col = $script:red } }
                elseif ($a.Kind -eq 'P') { $col = $script:playerColor }
                if ($a.Kind -eq 'I') {
                    $script:visibleItems++
                    if ($edge) { $script:edgeItems++ }
                }
                if ($a.Kind -eq 'E') { $script:visibleEnemies++ }
                elseif ($a.Kind -eq 'P') { $script:visiblePlayers++ }
                [void]$shown.Add([pscustomobject]@{
                    Actor=$a; Px=$projected.Px; Py=$projected.Py
                    Dz=$dz; Edge=$edge; Color=$col
                    RangeM=$projected.RangeM
                })
            }

            # Close same-type contacts share ONE count label, e.g. BATTERY x2.
            # Their individual dots remain; different floors are never merged.
            # Every eligible contact keeps its marker. Captions must remain
            # next to their markers: omit a crowded caption, never its dot.
            $labelGroups = New-Object System.Collections.Generic.List[object]
            foreach ($mark in $shown) {
                $group = $null
                if ($mark.Actor.Kind -eq 'I') {
                    foreach ($candidate in $labelGroups) {
                        if ($candidate.Actor.Kind -ne 'I' -or $candidate.Actor.Label -ne $mark.Actor.Label -or
                            $candidate.Actor.Category -ne $mark.Actor.Category) { continue }
                        if ([math]::Abs($candidate.Dz-$mark.Dz) -gt 100) { continue }
                        $sx = [double]($candidate.Px-$mark.Px)
                        $sy = [double]($candidate.Py-$mark.Py)
                        if (($sx*$sx+$sy*$sy) -le 196) { $group=$candidate; break }
                    }
                }
                if ($null -eq $group) {
                    $members=New-Object System.Collections.Generic.List[object]
                    [void]$members.Add($mark)
                    [void]$labelGroups.Add([pscustomobject]@{
                        Actor=$mark.Actor; Px=$mark.Px; Py=$mark.Py; Dz=$mark.Dz
                        Color=$mark.Color; Edge=$mark.Edge; Members=$members
                    })
                } else {
                    [void]$group.Members.Add($mark)
                    if ($mark.Edge) { $group.Edge=$true }
                }
            }
            $labelBoxes = New-Object System.Collections.Generic.List[System.Drawing.RectangleF]
            $labelBoxes.Add([System.Drawing.RectangleF]::new([float]($cx-15),[float]($cy-10),[float]65,[float]35))
            # Precompute marker hitboxes once per frame, rather than allocating
            # them again for EVERY trial position of EVERY caption.
            $dotBoxes = New-Object System.Collections.Generic.List[System.Drawing.RectangleF]
            foreach ($otherMark in $shown) {
                $dotRadius = if ($otherMark.Actor.Kind -eq 'E' -and $otherMark.Actor.Frozen) { [float]12 } else { [float]5 }
                $dotBoxes.Add([System.Drawing.RectangleF]::new(
                    [float]($otherMark.Px-$dotRadius),[float]($otherMark.Py-$dotRadius),
                    [float](2*$dotRadius),[float](2*$dotRadius)))
            }
            # Prioritize nearby captions, with stable identity as a tie-breaker.
            $orderedLabels = @($labelGroups | Sort-Object @{Expression={ [double]$_.Members[0].RangeM }}, @{Expression={ [string]$_.Actor.Identity }})
            foreach ($kind in @('E','P','I')) {
                foreach ($mark in $orderedLabels) {
                    if ($mark.Actor.Kind -ne $kind) { continue }
                    $altDirection = 0
                    $altDistance = ''
                    if ([math]::Abs($mark.Dz) -gt 150) {
                        $altDirection = if ($mark.Dz -gt 0) { 1 } else { -1 }
                        $altDistance = ([string][math]::Round([math]::Abs($mark.Dz)/100,0)) + 'm'
                    }
                    $name = [string]$mark.Actor.Label
                    if ($mark.Members.Count -gt 1) { $name += (' x'+[string]$mark.Members.Count) }
                    $lo = [double]::PositiveInfinity; $hi = [double]0
                    foreach ($member in $mark.Members) {
                        $lo = [math]::Min($lo,[double]$member.RangeM)
                        $hi = [math]::Max($hi,[double]$member.RangeM)
                    }
                    $lo = [math]::Round($lo,0); $hi = [math]::Round($hi,0)
                    $rangeText = if ($hi-$lo -ge 2) { '{0}-{1}m' -f $lo,$hi } else { '{0}m' -f $lo }
                    $caption = $name + '  ' + $rangeText
                    $font = if ($kind -eq 'E') { $script:markerFont } else { $script:smallFont }
                    $nameWidth = [float]($g.MeasureString($caption,$font).Width)
                    $distanceWidth = [float]0
                    if ($altDirection -ne 0) { $distanceWidth = [float]($g.MeasureString($altDistance,$font).Width) }
                    # [name + actual range] | measured gap | vector arrow | height
                    $arrowColumnWidth = [float]0
                    if ($altDirection -ne 0) { $arrowColumnWidth = [float](12+10+6+$distanceWidth) }
                    $tagWidth = [float][math]::Ceiling(12+$nameWidth+$arrowColumnWidth)
                    $tagHeight = [float]23
                    $candidates = New-Object System.Collections.Generic.List[System.Drawing.PointF]
                    foreach ($yy in @([float]($mark.Py-30),[float]($mark.Py+9),[float]($mark.Py-11),[float]($mark.Py+33))) {
                        $candidates.Add([System.Drawing.PointF]::new([float]($mark.Px+13),$yy))
                        $candidates.Add([System.Drawing.PointF]::new([float]($mark.Px-$tagWidth-13),$yy))
                    }
                    # Local-only alternatives. Never park a caption across the
                    # window or connect it with a long line through the radar.
                    $candidates.Add([System.Drawing.PointF]::new([float]($mark.Px-$tagWidth/2),[float]($mark.Py-$tagHeight-13)))
                    $candidates.Add([System.Drawing.PointF]::new([float]($mark.Px-$tagWidth/2),[float]($mark.Py+13)))
                    $best = $null
                    $bestCost = [double]::PositiveInfinity
                    foreach ($loc in $candidates) {
                        $rect = [System.Drawing.RectangleF]::new([float]$loc.X,[float]$loc.Y,$tagWidth,$tagHeight)
                        if ($rect.Left -lt 7 -or $rect.Right -gt ($cw-7) -or $rect.Top -lt 89 -or $rect.Bottom -gt ($ch-93)) { continue }
                        $reservedRect = [System.Drawing.RectangleF]::Inflate($rect,[float]3,[float]2)
                        $overlap = [double]0
                        foreach ($prior in $labelBoxes) {
                            if ($reservedRect.IntersectsWith($prior)) {
                                $inter = [System.Drawing.RectangleF]::Intersect($reservedRect,$prior)
                                $overlap += [double]($inter.Width*$inter.Height)
                            }
                        }
                        foreach ($dotRect in $dotBoxes) {
                            if ($reservedRect.IntersectsWith($dotRect)) { $overlap += 2000; break }
                        }
                        $nearX = [math]::Max($rect.Left,[math]::Min($rect.Right,$mark.Px))
                        $nearY = [math]::Max($rect.Top,[math]::Min($rect.Bottom,$mark.Py))
                        $dist2 = [math]::Pow(($nearX-$mark.Px),2)+[math]::Pow(($nearY-$mark.Py),2)
                        # A local caption must be clear of other text/markers,
                        # and its nearest edge must remain within 32px of its dot.
                        if ($overlap -gt 0 -or $dist2 -gt 1024) { continue }
                        if ($dist2 -lt $bestCost) { $best=$rect; $bestCost=$dist2 }
                    }
                    if ($null -eq $best) {
                        # Declutter TEXT ONLY. The separate marker pass below
                        # still draws every contact in $shown, at all zooms.
                        $script:hiddenLabels++
                        continue
                    }
                    $rect=$best
                    $tagBrush=[System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(226,10,19,27))
                    $borderPen=[System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(80,$mark.Color),[float]1)
                    try {
                        $g.FillRectangle($tagBrush,$rect.X,$rect.Y,$rect.Width,$rect.Height)
                        $g.DrawRectangle($borderPen,$rect.X,$rect.Y,$rect.Width,$rect.Height)
                    } finally { $tagBrush.Dispose(); $borderPen.Dispose() }
                    $nameX=[float]($rect.X+6); $textY=[float]($rect.Y+3)
                    WriteLabel $g $caption $nameX $textY $mark.Color $font
                    if ($altDirection -ne 0) {
                        $arrowX=[float]($nameX+$nameWidth+15)
                        $arrowY=[float]($rect.Y+$tagHeight/2)
                        $distanceX=[float]($arrowX+12)
                        DrawAltitudeArrow $g $arrowX $arrowY $altDirection $mark.Color
                        WriteLabel $g $altDistance $distanceX $textY $mark.Color $font
                    }
                    $labelBoxes.Add([System.Drawing.RectangleF]::Inflate($rect,[float]3,[float]2))
                }
            }
            # Static, per-enemy markers. FROZEN enemies get a blue snowflake
            # INSTEAD of their normal red dot. No pulsing or separate status banner.
            foreach ($mark in $shown) {
                if ($mark.Edge) { DrawEdgeChevron $g $mark.Px $mark.Py $cx $cy $mark.Color }
                if ($mark.Actor.Kind -eq 'E' -and $mark.Actor.Frozen) {
                    DrawFrozenSnowflake $g $mark.Px $mark.Py $script:iceBlue
                } else {
                    $size = if ($mark.Actor.Kind -eq 'E') { 6.0 } elseif ($mark.Actor.Kind -eq 'P') { 5.5 } else { 4.0 }
                    $outline = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(170,$mark.Color),1)
                    $fill = [System.Drawing.SolidBrush]::new($mark.Color)
                    try {
                        $g.DrawEllipse($outline,[float]($mark.Px-$size-2),[float]($mark.Py-$size-2),[float](2*$size+4),[float](2*$size+4))
                        $g.FillEllipse($fill,[float]($mark.Px-$size),[float]($mark.Py-$size),[float](2*$size),[float](2*$size))
                    } finally { $outline.Dispose(); $fill.Dispose() }
                }
            }

            $centerBrush = [System.Drawing.SolidBrush]::new($script:cyan)
            try {
                $points = [System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new($cx,([float]($cy-10))),
                    [System.Drawing.PointF]::new(([float]($cx-6)),([float]($cy+7))),
                    [System.Drawing.PointF]::new($cx,([float]($cy+3))),
                    [System.Drawing.PointF]::new(([float]($cx+6)),([float]($cy+7))))
                $g.FillPolygon($centerBrush,$points)
            } finally { $centerBrush.Dispose() }
            WriteLabel $g 'YOU' ($cx+10) ($cy+4) $script:cyan $script:markerFont
        }
        $legendY = $ch-85
        $legendRightX = [float]($cw*0.51)
        WriteLabel $g 'GREEN  Escape tools' 18 $legendY $script:green $script:smallFont
        WriteLabel $g 'YELLOW  Other supplies' $legendRightX $legendY $script:gold $script:smallFont
        $legendSecond = [float]($legendY+18)
        $legendMiddleX = [float]($cw*0.34)
        $legendPlayersX = [float]($cw*0.69)
        WriteLabel $g 'RED  Active' 18 $legendSecond $script:red $script:smallFont
        WriteLabel $g 'BLUE  Frozen' $legendMiddleX $legendSecond $script:iceBlue $script:smallFont
        WriteLabel $g 'PURPLE  Players' $legendPlayersX $legendSecond $script:playerColor $script:smallFont
        $summary = ('Items {0} (rim {1}) | Monsters {2} | Players {3}' -f $script:visibleItems,$script:edgeItems,$script:visibleEnemies,$script:visiblePlayers)
        WriteLabel $g $summary 17 ($ch-43) $script:dim $script:smallFont
        $rangeHint = if ($script:zoomRanges[$script:zoomIndex] -eq 250) {
            'ALL contacts | Far contacts on rim | Zoom in for crowded labels'
        } else {
            'In-range contacts only | 250m shows all | F5 hide'
        }
        WriteLabel $g $rangeHint 17 ($ch-23) $script:dim $script:smallFont
        if (-not $script:sourceFresh -and -not $Demo) {
            WriteLabel $g 'DATA DELAY' ($cw-115) 10 $script:red $script:smallFont
        }
        if ($sender.Visible -and -not $sender.ZoomHotkeysAvailable) {
            WriteLabel $g 'SHIFT+ARROW ZOOM UNAVAILABLE' ($cw-290) ($ch-49) $script:red $script:smallFont
        }
        $script:lastPaintError = ''
        } catch {
            # One error entry per distinct issue, not hundreds per second.
            $paintError = [string]$_.Exception.Message
            if ($paintError -ne $script:lastPaintError) {
                $script:lastPaintError = $paintError
                LogMessage ('Radar paint error (handled): ' + $paintError)
            }
            try {
                $e.Graphics.Clear($script:colorBackground)
                $errBrush = [System.Drawing.SolidBrush]::new($script:red)
                try {
                    $e.Graphics.DrawString('Radar display error - see diagnostic log',
                        $script:smallFont, $errBrush, [float]15, [float]22)
                } finally { $errBrush.Dispose() }
            } catch { }
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    # Limit UI work to about 11 updates/second. The game and radar bridge
    # still supply positions continuously; redraw only when a frame changes.
    $timer.Interval = 90
    $timer.Add_Tick({
        if ($Demo) { return }
        $now = [datetime]::UtcNow
        # Smooth angle wrap (359 -> 0 is one degree, never a complete spin).
        if ($script:headingReady) {
            $delta = [double](($script:targetYaw-$script:renderYaw+540.0)%360.0-180.0)
            if ([math]::Abs($delta) -gt 0.03) {
                $script:renderYaw = [double](($script:renderYaw+$delta*0.45+360.0)%360.0)
                if ($form.Visible) { $form.Invalidate() }
            }
        }
        # File reads are 10 Hz; smoothing does not trigger extra game scans.
        if (($now-$script:lastReadCheck).TotalMilliseconds -lt 160) { return }
        $script:lastReadCheck = $now
        if (($now-$script:lastProcessCheck).TotalSeconds -gt 3) {
            $script:lastProcessCheck = $now
            $script:gameRunning = (@(Get-Process -Name 'Panicore-Win64-Shipping' -ErrorAction SilentlyContinue).Count -gt 0)
            if (-not $script:gameRunning) {
                $timer.Stop()
                $form.Close()
                return
            }
        }
        $path = FindRadarPath
        if (-not $path) { return }
        try {
            $modified = [IO.File]::GetLastWriteTimeUtc($path)
            $fresh = (($now-$modified).TotalSeconds -le 8)
            if ($fresh -ne $script:sourceFresh) {
                $script:sourceFresh = $fresh
                if ($form.Visible) { $form.Invalidate() }
            }
            # Don't repeatedly hide/show the entire window when a snapshot arrives late.
            # Display DATA DELAY instead, avoiding the heartbeat-like window flashes.
            if ($path -ne $script:currentSnapshot -or $modified -gt $script:currentStamp) {
                $raw = [IO.File]::ReadAllLines($path)
                # A write can be in progress. Reject incomplete frames without
                # clearing items or hiding the window; retry the same timestamp.
                if ($raw.Count -lt 2) { return }
                $header = @($raw[0] -split "`t")
                $footer = @($raw[$raw.Count-1] -split "`t")
                $rowCount = 0
                if ($header.Count -lt 4 -or $header[0] -ne 'PHC2' -or
                    $footer.Count -ne 2 -or $footer[0] -ne 'END' -or
                    -not [int]::TryParse($footer[1],[ref]$rowCount) -or
                    $rowCount -ne ($raw.Count-1)) { return }
                $yaw = [double]0
                $yawOK = [double]::TryParse($header[3],[System.Globalization.NumberStyles]::Float,$Invariant,[ref]$yaw)
                $yawOK = $yawOK -and -not [double]::IsNaN($yaw) -and -not [double]::IsInfinity($yaw)
                $active = ($header[1] -eq '1')
                $newActors = New-Object System.Collections.Generic.List[object]
                for ($i=1;$i -lt ($raw.Count-1);$i++) {
                    $bits = @($raw[$i] -split "`t")
                    if ($bits.Count -lt 5 -or @('Y','P','E','I') -notcontains $bits[0]) { continue }
                    try {
                        $x=[double]::Parse($bits[2],$Invariant)
                        $y=[double]::Parse($bits[3],$Invariant)
                        $z=[double]::Parse($bits[4],$Invariant)
                        if ([double]::IsNaN($x) -or [double]::IsNaN($y) -or [double]::IsNaN($z) -or
                            [math]::Abs($x) -gt 1e7 -or [math]::Abs($y) -gt 1e7 -or [math]::Abs($z) -gt 1e7) { continue }
                        $newActors.Add([pscustomobject]@{
                            Kind=$bits[0]; Label=$bits[1]; X=$x; Y=$y; Z=$z
                            Category=$(if ($bits.Count -ge 7) { $bits[6] } else { 'OTHER' })
                            Identity=$(if ($bits.Count -ge 8) { $bits[7] } else { '' })
                            Frozen=($bits.Count -ge 6 -and $bits[0] -eq 'E' -and $bits[5] -eq 'FROZEN')
                        })
                    } catch { }
                }
                $script:currentSnapshot = $path
                $script:currentStamp = $modified
                if ($yawOK) {
                    $script:targetYaw = [double](($yaw%360.0+360.0)%360.0)
                    if (-not $script:headingReady -or $script:mapName -ne $header[2]) { $script:renderYaw=$script:targetYaw }
                }
                $script:headingSource = if ($header.Count -ge 5) { $header[4] } else { 'VIEW' }
                $script:headingReady=$yawOK
                $script:mapName = $header[2]
                $script:actors = @($newActors.ToArray())
                # Sorting and PowerShell pipelines in the Paint event were a
                # major source of CPU work when the radar was rotating.
                $script:drawOrder = @(
                    @($script:actors | Where-Object { $_.Kind -eq 'I' } | Sort-Object Identity) +
                    @($script:actors | Where-Object { $_.Kind -eq 'E' }) +
                    @($script:actors | Where-Object { $_.Kind -eq 'P' })
                )
                if ($active) {
                    if (-not $form.Visible) {
                        # Keep the no-activate click-through window out of the taskbar.
                        $form.Show()
                        LogMessage ('Radar visible, Shift+Up/Down hotkeys registered: '+[string]$form.ZoomHotkeysAvailable)
                    }
                    $form.Invalidate()
                } else {
                    if ($form.Visible) { $form.Hide() }
                    $form.ShowInTaskbar = $false
                }
            }
        } catch {
            $message = [string]$_.Exception.Message
            if ($message -ne $script:lastReadError) { LogMessage ('Radar snapshot retry: '+$message); $script:lastReadError=$message }
        }
    })
    $form.Add_Shown({
        if ($Demo) {
            # Click-through preview is deliberately not mouse-interactive.
            # Auto-close after 20 seconds to avoid trapping the user in a demo.
            $script:demoTimer = [System.Windows.Forms.Timer]::new()
            $script:demoTimer.Interval = 20000
            $script:demoTimer.Add_Tick({ $script:demoTimer.Stop(); $form.Close() })
            $script:demoTimer.Start()
            $script:mapName = 'DEMO - SCHOOL'
            $script:headingReady = $true
            $script:renderYaw = [double]90
            $script:targetYaw = [double]90
            $script:sourceFresh = $true
            $script:actors = @(
                [pscustomobject]@{Kind='Y';Label='YOU';X=0;Y=0;Z=0},
                [pscustomobject]@{Kind='P';Label='CHRIS';X=1300;Y=-600;Z=0},
                [pscustomobject]@{Kind='E';Label='PUPPET';X=-2400;Y=2100;Z=300;Frozen=$true},
                [pscustomobject]@{Kind='E';Label='SANTA';X=-500;Y=-3000;Z=0;Frozen=$false},
                [pscustomobject]@{Kind='I';Label='FUSE';X=1500;Y=1100;Z=-400;Category='IMPORTANT';Identity='DEMO_FUSE'},
                [pscustomobject]@{Kind='I';Label='KEY';X=-2300;Y=-1000;Z=0;Category='IMPORTANT';Identity='DEMO_KEY'},
                [pscustomobject]@{Kind='I';Label='BATTERY';X=700;Y=1200;Z=0;Category='OTHER';Identity='DEMO_B1'},
                [pscustomobject]@{Kind='I';Label='BATTERY';X=720;Y=1220;Z=0;Category='OTHER';Identity='DEMO_B2'},
                [pscustomobject]@{Kind='I';Label='CROWBAR';X=34000;Y=3000;Z=700;Category='IMPORTANT';Identity='DEMO_FAR'}
            )
            $script:drawOrder = @($script:actors | Where-Object { $_.Kind -ne 'Y' })
            $form.Invalidate()
        } else {
            $form.Hide()
            $timer.Start()
        }
    })
    $form.Add_FormClosed({
        if ($script:demoTimer) { $script:demoTimer.Stop(); $script:demoTimer.Dispose() }
        $timer.Stop()
        $script:primaryFont.Dispose()
        $script:smallFont.Dispose()
        $script:markerFont.Dispose()
        foreach ($brush in $script:labelBrushes.Values) { if ($brush) { $brush.Dispose() } }
        $script:labelBrushes.Clear()
        $timer.Dispose()
    })
    LogMessage 'Radar viewer v0.11.6 started: throttled WinForms paint, cached captions, unchanged range filtering and mouse pass-through.'
    [System.Windows.Forms.Application]::Run($form)
} catch {
    LogMessage ('Radar viewer failed: '+$_.Exception.ToString())
}
