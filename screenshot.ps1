# dsh-screenshot — full-screen region capture overlay (Windows)
# Invoked by the host plugin. Reads output path from $env:DSH_SHOT_OUT.
# Before capturing, minimizes the DeepSeek Harness window so it does not
# block the region the user wants to screenshot; restores it afterwards.
# Exit 0 = finished (caller checks file existence); non-zero = error/cancelled.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Make the process DPI-aware so CopyFromScreen and mouse coordinates agree.
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class DshDpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
    [DshDpi]::SetProcessDPIAware() | Out-Null
} catch { }

# Window helpers: minimize/restore the DeepSeek window around the capture.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DshWin {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

# Double-buffered overlay form: everything is painted in OnPaint into an
# offscreen buffer and blitted in one shot, so dragging never flashes white.
Add-Type -ReferencedAssemblies 'System.Drawing', 'System.Windows.Forms' -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class DshOverlayForm : Form {
    public Bitmap BaseImage;      // dimmed full-screen snapshot
    public Bitmap SourceImage;    // original (undimmed) snapshot
    public Pen SelectionPen;
    public Point StartPoint = Point.Empty;
    public Point CurrentPoint = Point.Empty;
    public bool HasSelection = false;

    public DshOverlayForm() {
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.Opaque |
            ControlStyles.UserPaint,
            true);
        UpdateStyles();
        BackColor = Color.Black;
    }

    protected override void OnPaintBackground(PaintEventArgs e) {
        // Suppress background erase — the white flash came from this.
    }

    protected override void OnPaint(PaintEventArgs e) {
        if (BaseImage != null) {
            e.Graphics.DrawImage(BaseImage, 0, 0, BaseImage.Width, BaseImage.Height);
        }
        if (HasSelection && SourceImage != null) {
            int x = Math.Min(StartPoint.X, CurrentPoint.X);
            int y = Math.Min(StartPoint.Y, CurrentPoint.Y);
            int w = Math.Abs(CurrentPoint.X - StartPoint.X);
            int h = Math.Abs(CurrentPoint.Y - StartPoint.Y);
            if (w > 0 && h > 0) {
                Rectangle r = new Rectangle(x, y, w, h);
                // Reveal the bright original inside the selection.
                e.Graphics.DrawImage(SourceImage, r, r, GraphicsUnit.Pixel);
                if (SelectionPen != null) {
                    e.Graphics.DrawRectangle(SelectionPen, r);
                }
            }
        }
    }
}
"@

$outPath = $env:DSH_SHOT_OUT
if (-not $outPath) { [Environment]::Exit(2) }

# --- locate and minimize the DeepSeek window so it is out of the frame ---
$dshHwnd = [IntPtr]::Zero
$minimized = $false
$dshProc = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
    Select-Object -First 1
if (-not $dshProc) {
    $dshProc = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.ProcessName -like '*DeepSeek*' } |
        Select-Object -First 1
}
if ($dshProc) {
    $dshHwnd = $dshProc.MainWindowHandle
    [DshWin]::ShowWindow($dshHwnd, 6) | Out-Null   # SW_MINIMIZE
    $minimized = $true
    $deadline = [DateTime]::UtcNow.AddMilliseconds(1500)
    while (-not [DshWin]::IsIconic($dshHwnd) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 300   # let the minimize animation finish
}

$pen = $null
$form = $null
$src = $null
$dim = $null

try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

    # Full virtual-screen snapshot (DeepSeek window is already minimized).
    $src = New-Object System.Drawing.Bitmap ($vs.Width), ($vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($src)
    try {
        $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $src.Size)
    } finally {
        $g.Dispose()
    }

    # Dimmed copy used as the overlay mask background.
    $dim = New-Object System.Drawing.Bitmap ($src)
    $dg = [System.Drawing.Graphics]::FromImage($dim)
    try {
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(90, 0, 0, 0))
        try { $dg.FillRectangle($brush, 0, 0, $dim.Width, $dim.Height) } finally { $brush.Dispose() }
    } finally {
        $dg.Dispose()
    }

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0, 120, 255)), 2

    $form = New-Object DshOverlayForm
    $form.BaseImage = $dim
    $form.SourceImage = $src
    $form.SelectionPen = $pen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = $vs.Location
    $form.Size = $vs.Size
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::Cross
    $form.KeyPreview = $true

    $script:dragging = $false

    $form.Add_MouseDown({
        $script:dragging = $true
        $script:form.StartPoint = $_.Location
        $script:form.CurrentPoint = $_.Location
        $script:form.HasSelection = $true
        $script:form.Invalidate()
    })

    $form.Add_MouseMove({
        if ($script:dragging) {
            $script:form.CurrentPoint = $_.Location
            $script:form.Invalidate()
        }
    })

    $form.Add_MouseUp({
        if ($script:dragging) {
            $script:dragging = $false
            $script:form.CurrentPoint = $_.Location
            $x = [Math]::Min($script:form.StartPoint.X, $script:form.CurrentPoint.X)
            $y = [Math]::Min($script:form.StartPoint.Y, $script:form.CurrentPoint.Y)
            $w = [Math]::Abs($script:form.CurrentPoint.X - $script:form.StartPoint.X)
            $h = [Math]::Abs($script:form.CurrentPoint.Y - $script:form.StartPoint.Y)
            if ($w -gt 3 -and $h -gt 3) {
                $r = New-Object System.Drawing.Rectangle ($x), ($y), ($w), ($h)
                $crop = New-Object System.Drawing.Bitmap ($w), ($h)
                $cg = [System.Drawing.Graphics]::FromImage($crop)
                try {
                    $cg.DrawImage($script:src, 0, 0, $r, [System.Drawing.GraphicsUnit]::Pixel)
                } finally {
                    $cg.Dispose()
                }
                try {
                    $crop.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
                } finally {
                    $crop.Dispose()
                }
            }
            $script:form.Close()
        }
    })

    $form.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $script:form.Close()
        }
    })

    [System.Windows.Forms.Application]::Run($form) | Out-Null
} finally {
    # Restore the DeepSeek window once the overlay closes (or on any error).
    if ($minimized -and $dshHwnd -ne [IntPtr]::Zero) {
        try {
            [DshWin]::ShowWindow($dshHwnd, 9) | Out-Null   # SW_RESTORE
            [DshWin]::SetForegroundWindow($dshHwnd) | Out-Null
        } catch { }
    }
    if ($null -ne $pen) { $pen.Dispose() }
    if ($null -ne $form) { $form.Dispose() }
    if ($null -ne $src) { $src.Dispose() }
    if ($null -ne $dim) { $dim.Dispose() }
}

[Environment]::Exit(0)
