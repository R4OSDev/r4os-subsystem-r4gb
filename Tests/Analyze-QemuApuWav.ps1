[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$Path,

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(1, 10000000)]
    [int]$ExpectedFrames = 6000,

    [Parameter(ParameterSetName = 'File')]
    [ValidateRange(0.1, 20.0)]
    [double]$DurationTolerancePercent = 2.0,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$guestSampleRate = 48000

function Read-U16([byte[]]$Bytes, [int]$Offset) {
    return [uint16](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8))
}

function Read-U32([byte[]]$Bytes, [int]$Offset) {
    return [uint32](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8) -bor (([uint32]$Bytes[$Offset + 2]) -shl 16) -bor (([uint32]$Bytes[$Offset + 3]) -shl 24))
}

function Read-I16([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToInt16($Bytes, $Offset)
}

function Measure-R4GbSignal([int[]]$Left, [int[]]$Right, [int]$SampleRate) {
    if ($Left.Length -ne $Right.Length) { throw 'Stereo sample arrays differ in length.' }
    if ($SampleRate -le 0) { throw 'Sample rate must be positive.' }

    $maximumGap = [int][Math]::Ceiling($SampleRate * 0.001)
    $clusters = [Collections.Generic.List[object]]::new()
    $clusterStart = -1
    $lastActive = -1
    $clusterActive = 0
    $clusterLongestGap = 0

    for ($frame = 0; $frame -lt $Left.Length; $frame++) {
        $leftAbs = [Math]::Abs([int64]$Left[$frame])
        $rightAbs = [Math]::Abs([int64]$Right[$frame])
        $samePolarity = ($Left[$frame] -ge 0) -eq ($Right[$frame] -ge 0)
        $isR4Gb = $leftAbs -ge 128 -and $rightAbs -ge 48 -and $samePolarity -and
            ($leftAbs * 100) -ge ($rightAbs * 170) -and
            ($leftAbs * 100) -le ($rightAbs * 230)
        if (-not $isR4Gb) { continue }

        if ($clusterStart -lt 0) {
            $clusterStart = $frame
            $clusterActive = 1
            $clusterLongestGap = 0
        } else {
            $gap = $frame - $lastActive - 1
            if ($gap -gt $maximumGap) {
                $clusters.Add([pscustomobject]@{
                    Start = $clusterStart
                    End = $lastActive
                    Span = $lastActive - $clusterStart + 1
                    Active = $clusterActive
                    LongestGap = $clusterLongestGap
                })
                $clusterStart = $frame
                $clusterActive = 1
                $clusterLongestGap = 0
            } else {
                $clusterActive++
                if ($gap -gt $clusterLongestGap) { $clusterLongestGap = $gap }
            }
        }
        $lastActive = $frame
    }

    if ($clusterStart -ge 0) {
        $clusters.Add([pscustomobject]@{
            Start = $clusterStart
            End = $lastActive
            Span = $lastActive - $clusterStart + 1
            Active = $clusterActive
            LongestGap = $clusterLongestGap
        })
    }

    $expectedSignalFrames = [int][Math]::Round($SampleRate * ($ExpectedFrames / [double]$guestSampleRate))
    $best = @($clusters | Sort-Object Span -Descending | Select-Object -First 1)
    if ($best.Count -eq 0) {
        return [pscustomobject]@{
            SampleRate = $SampleRate
            Channels = 2
            Frames = $Left.Length
            ExpectedSignalFrames = $expectedSignalFrames
            SignalFrames = 0
            ActiveFrames = 0
            LongestGapFrames = 0
            LifecycleGaps = 0
            LifecycleGapFrames = 0
            StereoRatio = 0.0
            FrequencyHz = 0.0
            Continuous = $false
        }
    }

    $signal = $best[0]
    $lifecycleGaps = 0
    $lifecycleGapFrames = 0
    $maximumLifecycleGap = [int][Math]::Ceiling($SampleRate * 0.025)
    $minimumPrelude = [int][Math]::Floor($expectedSignalFrames * 0.02)
    $maximumPrelude = [int][Math]::Ceiling($expectedSignalFrames * 0.15)
    $minimumTail = [int][Math]::Floor($expectedSignalFrames * 0.85)
    $tolerance = $DurationTolerancePercent / 100.0
    $minimumFrames = [int][Math]::Floor($expectedSignalFrames * (1.0 - $tolerance))
    $maximumFrames = [int][Math]::Ceiling($expectedSignalFrames * (1.0 + $tolerance))

    # The scripted lifecycle probe resets the first guest once near the start
    # of the run. QEMU's resampler represents that deliberate reset as one
    # short silence. Accept exactly that shape: a bounded early prelude, one
    # <=25 ms transition, then a dominant sustained tail. A missing quantum in
    # the middle still forms two similarly sized clusters and remains invalid.
    $pairCandidates = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index + 1 -lt $clusters.Count; $index++) {
        $leftCluster = $clusters[$index]
        $rightCluster = $clusters[$index + 1]
        $gap = $rightCluster.Start - $leftCluster.End - 1
        $combinedSpan = $rightCluster.End - $leftCluster.Start + 1
        if ($leftCluster.Span -lt $minimumPrelude -or $leftCluster.Span -gt $maximumPrelude -or
            $rightCluster.Span -lt $minimumTail -or $gap -le $maximumGap -or $gap -gt $maximumLifecycleGap -or
            $combinedSpan -lt $minimumFrames -or $combinedSpan -gt $maximumFrames) { continue }
        $pairCandidates.Add([pscustomobject]@{
            Start = $leftCluster.Start
            End = $rightCluster.End
            Span = $combinedSpan
            Active = $leftCluster.Active + $rightCluster.Active
            LongestGap = [Math]::Max($leftCluster.LongestGap, $rightCluster.LongestGap)
            LifecycleGap = $gap
            Distance = [Math]::Abs($combinedSpan - $expectedSignalFrames)
        })
    }
    $selectedPair = @($pairCandidates | Sort-Object Distance | Select-Object -First 1)
    if ($selectedPair.Count -eq 1) {
        $signal = $selectedPair[0]
        $lifecycleGaps = 1
        $lifecycleGapFrames = $signal.LifecycleGap
    }

    $leftEnergy = 0.0
    $rightEnergy = 0.0
    $transitions = 0
    $previousSign = 0
    for ($frame = $signal.Start; $frame -le $signal.End; $frame++) {
        $leftSample = $Left[$frame]
        $rightSample = $Right[$frame]
        $leftEnergy += [double]$leftSample * $leftSample
        $rightEnergy += [double]$rightSample * $rightSample
        if ([Math]::Abs([int64]$leftSample) -lt 128) { continue }
        $sign = if ($leftSample -lt 0) { -1 } else { 1 }
        if ($previousSign -ne 0 -and $sign -ne $previousSign) { $transitions++ }
        $previousSign = $sign
    }
    $ratio = if ($rightEnergy -eq 0.0) { 0.0 } else { [Math]::Sqrt($leftEnergy / $rightEnergy) }
    $frequency = if ($signal.Span -eq 0) { 0.0 } else { ($transitions * $SampleRate) / (2.0 * $signal.Span) }
    # DurationTolerancePercent deliberately admits capture-edge loss from the
    # host resampler. Apply the 98% density requirement to that admitted span,
    # not again to the untolerated nominal duration.
    $minimumActive = [int][Math]::Floor($minimumFrames * 0.98)
    $continuous = $signal.Span -ge $minimumFrames -and $signal.Span -le $maximumFrames -and
        $signal.Active -ge $minimumActive -and $signal.LongestGap -le $maximumGap -and
        $ratio -ge 1.90 -and $ratio -le 2.10 -and
        $frequency -ge 400.0 -and $frequency -le 480.0

    return [pscustomobject]@{
        SampleRate = $SampleRate
        Channels = 2
        Frames = $Left.Length
        ExpectedSignalFrames = $expectedSignalFrames
        SignalFrames = $signal.Span
        ActiveFrames = $signal.Active
        LongestGapFrames = $signal.LongestGap
        LifecycleGaps = $lifecycleGaps
        LifecycleGapFrames = $lifecycleGapFrames
        StereoRatio = [Math]::Round($ratio, 4)
        FrequencyHz = [Math]::Round($frequency, 2)
        Continuous = $continuous
    }
}

function Read-Wav([string]$FilePath) {
    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "WAV file not found: $fullPath" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WAVE') {
        throw "Not a RIFF/WAVE file: $fullPath"
    }

    $formatOffset = -1
    $formatBytes = 0
    $dataOffset = -1
    $dataBytes = 0
    $cursor = 12
    while ($cursor + 8 -le $bytes.Length) {
        $chunk = [Text.Encoding]::ASCII.GetString($bytes, $cursor, 4)
        $length = [int](Read-U32 $bytes ($cursor + 4))
        $payload = $cursor + 8
        if ($chunk -ceq 'data' -and $length -eq 0 -and $payload -lt $bytes.Length) {
            $length = $bytes.Length - $payload
        }
        if ($payload + $length -gt $bytes.Length) { throw "Truncated WAV chunk: $chunk" }
        if ($chunk -ceq 'fmt ') {
            $formatOffset = $payload
            $formatBytes = $length
        } elseif ($chunk -ceq 'data') {
            $dataOffset = $payload
            $dataBytes = $length
        }
        $cursor = $payload + $length + ($length -band 1)
    }
    if ($formatOffset -lt 0 -or $formatBytes -lt 16 -or $dataOffset -lt 0) { throw 'WAV fmt or data chunk missing.' }

    $format = Read-U16 $bytes $formatOffset
    $channels = Read-U16 $bytes ($formatOffset + 2)
    $sampleRate = [int](Read-U32 $bytes ($formatOffset + 4))
    $bitsPerSample = Read-U16 $bytes ($formatOffset + 14)
    if ($format -ne 1 -or $channels -ne 2 -or $sampleRate -le 0 -or $bitsPerSample -ne 16) {
        throw "R4GB capture requires stereo PCM S16: format=$format channels=$channels rate=$sampleRate bits=$bitsPerSample"
    }

    $frameCount = [int]($dataBytes / 4)
    [int[]]$left = New-Object int[] $frameCount
    [int[]]$right = New-Object int[] $frameCount
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
        $left[$frame] = [int](Read-I16 $bytes ($dataOffset + $frame * 4))
        $right[$frame] = [int](Read-I16 $bytes ($dataOffset + $frame * 4 + 2))
    }
    return Measure-R4GbSignal $left $right $sampleRate
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($SelfTest) {
    [int[]]$left = New-Object int[] 7000
    [int[]]$right = New-Object int[] 7000
    for ($frame = 500; $frame -lt 6500; $frame++) {
        $sample = if (((($frame - 500) / 55) -band 1) -eq 0) { 7600 } else { -7600 }
        $left[$frame] = $sample
        $right[$frame] = [int]($sample / 2)
    }
    $continuous = Measure-R4GbSignal $left $right 48000
    Assert-Condition $continuous.Continuous 'Continuous R4GB fixture was rejected.'

    # A signal at the accepted duration edge may contain isolated resampler
    # zeros and must still pass the independent 98% density criterion.
    [int[]]$edgeLeft = New-Object int[] 7000
    [int[]]$edgeRight = New-Object int[] 7000
    for ($frame = 500; $frame -lt 6380; $frame++) {
        if ((($frame - 500) % 80) -eq 40) { continue }
        $sample = if (((($frame - 500) / 55) -band 1) -eq 0) { 7600 } else { -7600 }
        $edgeLeft[$frame] = $sample
        $edgeRight[$frame] = [int]($sample / 2)
    }
    $edge = Measure-R4GbSignal $edgeLeft $edgeRight 48000
    Assert-Condition $edge.Continuous 'Duration-edge signal with dense isolated resampler zeros was rejected.'

    [int[]]$lifecycleLeft = New-Object int[] 7000
    [int[]]$lifecycleRight = New-Object int[] 7000
    foreach ($range in @(@(500, 1100), @(1160, 6500))) {
        for ($frame = $range[0]; $frame -lt $range[1]; $frame++) {
            $sample = if (((($frame - 500) / 55) -band 1) -eq 0) { 7600 } else { -7600 }
            $lifecycleLeft[$frame] = $sample
            $lifecycleRight[$frame] = [int]($sample / 2)
        }
    }
    $lifecycle = Measure-R4GbSignal $lifecycleLeft $lifecycleRight 48000
    Assert-Condition ($lifecycle.Continuous -and $lifecycle.LifecycleGaps -eq 1) 'Bounded early lifecycle reset gap was rejected.'

    for ($frame = 3260; $frame -lt 3740; $frame++) {
        $left[$frame] = 0
        $right[$frame] = 0
    }
    $broken = Measure-R4GbSignal $left $right 48000
    Assert-Condition (-not $broken.Continuous) 'R4GB fixture with a missing quantum was accepted.'

    Write-Host 'R4GB QEMU WAV analyzer self-test OK: continuous stereo signal accepted and missing quantum rejected.'
    exit 0
}

$result = Read-Wav $Path
$result | Format-List
if (-not $result.Continuous) {
    Write-Host ("R4GB QEMU WAV analysis FAILED: signal=$($result.SignalFrames)/$($result.ExpectedSignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) lifecycle=$($result.LifecycleGaps)/$($result.LifecycleGapFrames) ratio=$($result.StereoRatio) frequency=$($result.FrequencyHz)")
    exit 1
}
Write-Host ("R4GB QEMU WAV analysis OK: signal=$($result.SignalFrames)/$($result.ExpectedSignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) lifecycle=$($result.LifecycleGaps)/$($result.LifecycleGapFrames) ratio=$($result.StereoRatio) frequency=$($result.FrequencyHz)")
exit 0
