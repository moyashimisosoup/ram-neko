# Native pixel artwork: no image download, external font, or graphics runtime.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NekoWindow {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
'@
$script:nekoPixels = @(
    '................',
    '..##........##..',
    '..#p#......#p#..',
    '..#ww######ww#..',
    '.#wwwwwwwwwwww#.',
    '.#wwwwwwwwwwww#.',
    '.#www#wwww#www#.',
    '.#www#wwww#www#.',
    '.#ppwww##wwwpp#.',
    '..#wwwwmmwwww#..',
    '..#wwwwwwwwww#..',
    '...##########...',
    '...#wwwwwwww#...',
    '..#ww#wwww#ww#..',
    '..############..',
    '................'
)
function New-NekoBitmap([int]$Scale) {
    $colors = @{'#'='#48364F'; w='#FFF6E7'; p='#F3A7B8'; m='#C07891'}
    $bitmap = New-Object Drawing.Bitmap((16*$Scale),(16*$Scale))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        for($y=0;$y -lt 16;$y++) {
            if($script:nekoPixels[$y].Length -ne 16){throw 'Invalid cat pixel row'}
            for($x=0;$x -lt 16;$x++) {
                $key=[string]$script:nekoPixels[$y][$x]
                if($colors.ContainsKey($key)) {
                    $brush=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($colors[$key]))
                    try{$graphics.FillRectangle($brush,($x*$Scale),($y*$Scale),$Scale,$Scale)}finally{$brush.Dispose()}
                }
            }
        }
    } catch { $bitmap.Dispose(); throw } finally { $graphics.Dispose() }
    return ,$bitmap
}
function New-NekoIcon {
    $bitmap=New-NekoBitmap 2
    $handle=[IntPtr]::Zero
    try {
        $handle=$bitmap.GetHicon()
        $wrapper=[Drawing.Icon]::FromHandle($handle)
        try { return $wrapper.Clone() } finally { $wrapper.Dispose() }
    } finally {
        if($handle -ne [IntPtr]::Zero){[void][NekoWindow]::DestroyIcon($handle)}
        $bitmap.Dispose()
    }
}
function Set-PixelButton($Button) {
    $Button.FlatStyle='Flat'
    $Button.FlatAppearance.BorderSize=2
    $Button.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#6D547E')
    $Button.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#F5D6E2')
    $Button.FlatAppearance.MouseDownBackColor=[Drawing.ColorTranslator]::FromHtml('#E7B7D1')
    $Button.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF5EB')
    $Button.ForeColor=[Drawing.ColorTranslator]::FromHtml('#48364F')
    $Button.UseVisualStyleBackColor=$false
}

Add-Type -Path "$PSScriptRoot\GadgetControls.cs" -ReferencedAssemblies System.Windows.Forms,System.Drawing
