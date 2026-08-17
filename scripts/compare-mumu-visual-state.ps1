Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Drawing

function Get-MumuVisualSample {
    param(
        [Parameter(Mandatory = $true)][Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory = $true)][int]$SampleWidth,
        [Parameter(Mandatory = $true)][int]$SampleHeight
    )

    $count = $SampleWidth * $SampleHeight
    $red = New-Object 'int[]' $count
    $green = New-Object 'int[]' $count
    $blue = New-Object 'int[]' $count
    $luminance = New-Object 'int[]' $count
    for ($sampleY = 0; $sampleY -lt $SampleHeight; $sampleY++) {
        $sourceY = [int][Math]::Floor((($sampleY * $Bitmap.Height) + [Math]::Floor($Bitmap.Height / 2.0)) / $SampleHeight)
        if ($sourceY -ge $Bitmap.Height) { $sourceY = $Bitmap.Height - 1 }
        for ($sampleX = 0; $sampleX -lt $SampleWidth; $sampleX++) {
            $sourceX = [int][Math]::Floor((($sampleX * $Bitmap.Width) + [Math]::Floor($Bitmap.Width / 2.0)) / $SampleWidth)
            if ($sourceX -ge $Bitmap.Width) { $sourceX = $Bitmap.Width - 1 }
            $pixel = $Bitmap.GetPixel($sourceX, $sourceY)
            $index = ($sampleY * $SampleWidth) + $sampleX
            $red[$index] = $pixel.R
            $green[$index] = $pixel.G
            $blue[$index] = $pixel.B
            $luminance[$index] = (($pixel.R * 77) + ($pixel.G * 150) + ($pixel.B * 29)) -shr 8
        }
    }

    $gradient = New-Object 'int[]' $count
    for ($sampleY = 0; $sampleY -lt $SampleHeight; $sampleY++) {
        $top = [Math]::Max(0, $sampleY - 1)
        $bottom = [Math]::Min($SampleHeight - 1, $sampleY + 1)
        for ($sampleX = 0; $sampleX -lt $SampleWidth; $sampleX++) {
            $left = [Math]::Max(0, $sampleX - 1)
            $right = [Math]::Min($SampleWidth - 1, $sampleX + 1)
            $horizontal = [Math]::Abs($luminance[($sampleY * $SampleWidth) + $right] - $luminance[($sampleY * $SampleWidth) + $left])
            $vertical = [Math]::Abs($luminance[($bottom * $SampleWidth) + $sampleX] - $luminance[($top * $SampleWidth) + $sampleX])
            $value = [int][Math]::Floor(($horizontal + $vertical + 1) / 2.0)
            $gradient[($sampleY * $SampleWidth) + $sampleX] = [Math]::Min(255, $value)
        }
    }

    return [pscustomobject]@{
        Red       = $red
        Green     = $green
        Blue      = $blue
        Luminance = $luminance
        Gradient  = $gradient
    }
}

function Get-MumuRgbDelta {
    param([object]$Left, [object]$Right, [int]$Index)
    return (
        [Math]::Abs($Left.Red[$Index] - $Right.Red[$Index]) +
        [Math]::Abs($Left.Green[$Index] - $Right.Green[$Index]) +
        [Math]::Abs($Left.Blue[$Index] - $Right.Blue[$Index])
    ) / 765.0
}

function Test-MumuLocalSample {
    param(
        [int]$SampleX,
        [int]$SampleY,
        [string]$Action,
        [double]$GuardX,
        [double]$GuardY,
        [double]$GuardX2,
        [double]$GuardY2
    )

    if ($Action -ne 'Swipe') {
        return ([Math]::Abs($SampleX - $GuardX) -le 4 -and [Math]::Abs($SampleY - $GuardY) -le 3)
    }

    $deltaX = $GuardX2 - $GuardX
    $deltaY = $GuardY2 - $GuardY
    $lengthSquared = ($deltaX * $deltaX) + ($deltaY * $deltaY)
    if ($lengthSquared -le 0) {
        $distanceSquared = (($SampleX - $GuardX) * ($SampleX - $GuardX)) + (($SampleY - $GuardY) * ($SampleY - $GuardY))
        return $distanceSquared -le 12.25
    }
    $projection = ((($SampleX - $GuardX) * $deltaX) + (($SampleY - $GuardY) * $deltaY)) / $lengthSquared
    $projection = [Math]::Max(0.0, [Math]::Min(1.0, $projection))
    $nearestX = $GuardX + ($projection * $deltaX)
    $nearestY = $GuardY + ($projection * $deltaY)
    $distanceSquared = (($SampleX - $nearestX) * ($SampleX - $nearestX)) + (($SampleY - $nearestY) * ($SampleY - $nearestY))
    return $distanceSquared -le 12.25
}

function Compare-MumuVisualFrames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][string]$LiveAPath,
        [Parameter(Mandatory = $true)][string]$LiveBPath,
        [Parameter(Mandatory = $true)][ValidateSet('Tap', 'Swipe', 'KeyEvent')][string]$Action,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [int]$X2,
        [int]$Y2,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$EvidenceWidth,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$EvidenceHeight
    )

    foreach ($path in @($EvidencePath, $LiveAPath, $LiveBPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Visual comparison image is missing: $path"
        }
    }

    $evidence = $null
    $liveA = $null
    $liveB = $null
    try {
        $evidence = [Drawing.Bitmap]::new($EvidencePath)
        $liveA = [Drawing.Bitmap]::new($LiveAPath)
        $liveB = [Drawing.Bitmap]::new($LiveBPath)
        if ($evidence.Width -ne $EvidenceWidth -or $evidence.Height -ne $EvidenceHeight) {
            throw "Evidence image dimensions changed: expected ${EvidenceWidth}x${EvidenceHeight}, image=$($evidence.Width)x$($evidence.Height)."
        }
        if ($liveA.Width -ne $EvidenceWidth -or $liveA.Height -ne $EvidenceHeight -or
            $liveB.Width -ne $EvidenceWidth -or $liveB.Height -ne $EvidenceHeight) {
            throw 'Live image dimensions do not match the evidence image.'
        }

        $sampleWidth = 64
        $sampleHeight = 36
        $pixelCount = $sampleWidth * $sampleHeight
        $evidenceSample = Get-MumuVisualSample -Bitmap $evidence -SampleWidth $sampleWidth -SampleHeight $sampleHeight
        $liveASample = Get-MumuVisualSample -Bitmap $liveA -SampleWidth $sampleWidth -SampleHeight $sampleHeight
        $liveBSample = Get-MumuVisualSample -Bitmap $liveB -SampleWidth $sampleWidth -SampleHeight $sampleHeight

        # These thresholds are intentionally fixed. The caller cannot relax this guard.
        $thresholds = [ordered]@{
            DynamicRgbMinimum              = 0.055
            DynamicLuminanceMinimum        = 0.055
            DynamicFractionMaximum         = 0.080
            ChangedRgbMinimum              = 0.100
            ChangedGradientMinimum         = 0.140
            GlobalMeanRgbMaximum            = 0.045
            GlobalMeanGradientMaximum       = 0.060
            GlobalChangedFractionMaximum    = 0.120
            LocalMeanRgbMaximum             = 0.025
            LocalMeanGradientMaximum        = 0.035
            LocalChangedFractionMaximum     = 0.060
            LocalDynamicFractionMaximum     = 0.250
        }

        $rawDynamic = New-Object 'bool[]' $pixelCount
        for ($index = 0; $index -lt $pixelCount; $index++) {
            $abRgb = Get-MumuRgbDelta -Left $liveASample -Right $liveBSample -Index $index
            $abLuminance = [Math]::Abs($liveASample.Luminance[$index] - $liveBSample.Luminance[$index]) / 255.0
            $rawDynamic[$index] = ($abRgb -gt $thresholds.DynamicRgbMinimum -or $abLuminance -gt $thresholds.DynamicLuminanceMinimum)
        }

        # Expand by one sample in every direction so animated edges do not leak into the static comparison.
        $dynamic = New-Object 'bool[]' $pixelCount
        for ($sampleY = 0; $sampleY -lt $sampleHeight; $sampleY++) {
            for ($sampleX = 0; $sampleX -lt $sampleWidth; $sampleX++) {
                $isDynamic = $false
                for ($offsetY = -1; $offsetY -le 1 -and -not $isDynamic; $offsetY++) {
                    $neighborY = $sampleY + $offsetY
                    if ($neighborY -lt 0 -or $neighborY -ge $sampleHeight) { continue }
                    for ($offsetX = -1; $offsetX -le 1; $offsetX++) {
                        $neighborX = $sampleX + $offsetX
                        if ($neighborX -lt 0 -or $neighborX -ge $sampleWidth) { continue }
                        if ($rawDynamic[($neighborY * $sampleWidth) + $neighborX]) {
                            $isDynamic = $true
                            break
                        }
                    }
                }
                $dynamic[($sampleY * $sampleWidth) + $sampleX] = $isDynamic
            }
        }

        $guardX = [Math]::Min($sampleWidth - 1, [Math]::Max(0, [Math]::Floor(($X * $sampleWidth) / [double]$EvidenceWidth)))
        $guardY = [Math]::Min($sampleHeight - 1, [Math]::Max(0, [Math]::Floor(($Y * $sampleHeight) / [double]$EvidenceHeight)))
        $guardX2 = [Math]::Min($sampleWidth - 1, [Math]::Max(0, [Math]::Floor(($X2 * $sampleWidth) / [double]$EvidenceWidth)))
        $guardY2 = [Math]::Min($sampleHeight - 1, [Math]::Max(0, [Math]::Floor(($Y2 * $sampleHeight) / [double]$EvidenceHeight)))

        $dynamicCount = 0
        $staticCount = 0
        $globalRgbTotal = 0.0
        $globalGradientTotal = 0.0
        $globalChangedCount = 0
        $localTotalCount = 0
        $localDynamicCount = 0
        $localStaticCount = 0
        $localRgbTotal = 0.0
        $localGradientTotal = 0.0
        $localChangedCount = 0

        for ($sampleY = 0; $sampleY -lt $sampleHeight; $sampleY++) {
            for ($sampleX = 0; $sampleX -lt $sampleWidth; $sampleX++) {
                $index = ($sampleY * $sampleWidth) + $sampleX
                $isLocal = Test-MumuLocalSample -SampleX $sampleX -SampleY $sampleY -Action $Action -GuardX $guardX -GuardY $guardY -GuardX2 $guardX2 -GuardY2 $guardY2
                if ($isLocal) { $localTotalCount++ }
                if ($dynamic[$index]) {
                    $dynamicCount++
                    if ($isLocal) { $localDynamicCount++ }
                    continue
                }

                $staticCount++
                $rgbEA = Get-MumuRgbDelta -Left $evidenceSample -Right $liveASample -Index $index
                $rgbEB = Get-MumuRgbDelta -Left $evidenceSample -Right $liveBSample -Index $index
                $rgbDelta = [Math]::Min($rgbEA, $rgbEB)
                $gradientEA = [Math]::Abs($evidenceSample.Gradient[$index] - $liveASample.Gradient[$index]) / 255.0
                $gradientEB = [Math]::Abs($evidenceSample.Gradient[$index] - $liveBSample.Gradient[$index]) / 255.0
                $gradientDelta = [Math]::Min($gradientEA, $gradientEB)
                $changed = ($rgbDelta -gt $thresholds.ChangedRgbMinimum -or $gradientDelta -gt $thresholds.ChangedGradientMinimum)
                $globalRgbTotal += $rgbDelta
                $globalGradientTotal += $gradientDelta
                if ($changed) { $globalChangedCount++ }
                if ($isLocal) {
                    $localStaticCount++
                    $localRgbTotal += $rgbDelta
                    $localGradientTotal += $gradientDelta
                    if ($changed) { $localChangedCount++ }
                }
            }
        }

        $dynamicFraction = $dynamicCount / [double]$pixelCount
        $globalMeanRgb = if ($staticCount -gt 0) { $globalRgbTotal / $staticCount } else { 1.0 }
        $globalMeanGradient = if ($staticCount -gt 0) { $globalGradientTotal / $staticCount } else { 1.0 }
        $globalChangedFraction = if ($staticCount -gt 0) { $globalChangedCount / [double]$staticCount } else { 1.0 }
        $localDynamicFraction = if ($localTotalCount -gt 0) { $localDynamicCount / [double]$localTotalCount } else { 1.0 }
        $localMeanRgb = if ($localStaticCount -gt 0) { $localRgbTotal / $localStaticCount } else { 1.0 }
        $localMeanGradient = if ($localStaticCount -gt 0) { $localGradientTotal / $localStaticCount } else { 1.0 }
        $localChangedFraction = if ($localStaticCount -gt 0) { $localChangedCount / [double]$localStaticCount } else { 1.0 }

        $decision = 'matched'
        if ($dynamicFraction -gt $thresholds.DynamicFractionMaximum -or $staticCount -eq 0) {
            $decision = 'too-dynamic'
        } elseif ($globalMeanRgb -gt $thresholds.GlobalMeanRgbMaximum -or
            $globalMeanGradient -gt $thresholds.GlobalMeanGradientMaximum -or
            $globalChangedFraction -gt $thresholds.GlobalChangedFractionMaximum) {
            $decision = 'global-changed'
        } elseif ($localDynamicFraction -gt $thresholds.LocalDynamicFractionMaximum -or $localStaticCount -eq 0 -or
            $localMeanRgb -gt $thresholds.LocalMeanRgbMaximum -or
            $localMeanGradient -gt $thresholds.LocalMeanGradientMaximum -or
            $localChangedFraction -gt $thresholds.LocalChangedFractionMaximum) {
            $decision = 'local-changed'
        }

        [pscustomobject]@{
            AlgorithmVersion      = 1
            Passed                = ($decision -eq 'matched')
            Decision              = $decision
            SampleWidth           = $sampleWidth
            SampleHeight          = $sampleHeight
            StaticPixelCount      = $staticCount
            DynamicPixelCount     = $dynamicCount
            DynamicFraction       = [Math]::Round($dynamicFraction, 6)
            GlobalMeanRgbDelta    = [Math]::Round($globalMeanRgb, 6)
            GlobalMeanGradientDelta = [Math]::Round($globalMeanGradient, 6)
            GlobalChangedFraction = [Math]::Round($globalChangedFraction, 6)
            LocalPixelCount       = $localTotalCount
            LocalStaticPixelCount = $localStaticCount
            LocalDynamicFraction  = [Math]::Round($localDynamicFraction, 6)
            LocalMeanRgbDelta     = [Math]::Round($localMeanRgb, 6)
            LocalMeanGradientDelta = [Math]::Round($localMeanGradient, 6)
            LocalChangedFraction  = [Math]::Round($localChangedFraction, 6)
            Thresholds            = [pscustomobject]$thresholds
        }
    } finally {
        if ($null -ne $liveB) { $liveB.Dispose() }
        if ($null -ne $liveA) { $liveA.Dispose() }
        if ($null -ne $evidence) { $evidence.Dispose() }
    }
}
