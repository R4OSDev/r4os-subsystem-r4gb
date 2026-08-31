[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$Path,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$guestFrames = 6000
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

    $best = @($clusters | Sort-Object Span -Descending | Select-Object -First 1)
    $expectedFrames = [int][Math]::Round($SampleRate * ($guestFrames / [double]$guestSampleRate))
    if ($best.Count -eq 0) {
        return [pscustomobject]@{
            SampleRate = $SampleRate
            Channels = 2
            Frames = $Left.Length
            ExpectedSignalFrames = $expectedFrames
            SignalFrames = 0
            ActiveFrames = 0
            LongestGapFrames = 0
            StereoRatio = 0.0
            FrequencyHz = 0.0
            Continuous = $false
        }
    }

    $signal = $best[0]
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
    $minimumFrames = [int][Math]::Floor($expectedFrames * 0.98)
    $maximumFrames = [int][Math]::Ceiling($expectedFrames * 1.02)
    $minimumActive = [int][Math]::Floor($expectedFrames * 0.98)
    $continuous = $signal.Span -ge $minimumFrames -and $signal.Span -le $maximumFrames -and
        $signal.Active -ge $minimumActive -and $signal.LongestGap -le $maximumGap -and
        $ratio -ge 1.90 -and $ratio -le 2.10 -and
        $frequency -ge 400.0 -and $frequency -le 480.0

    return [pscustomobject]@{
        SampleRate = $SampleRate
        Channels = 2
        Frames = $Left.Length
        ExpectedSignalFrames = $expectedFrames
        SignalFrames = $signal.Span
        ActiveFrames = $signal.Active
        LongestGapFrames = $signal.LongestGap
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
    Write-Host ("R4GB QEMU WAV analysis FAILED: signal=$($result.SignalFrames)/$($result.ExpectedSignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) ratio=$($result.StereoRatio) frequency=$($result.FrequencyHz)")
    exit 1
}
Write-Host ("R4GB QEMU WAV analysis OK: signal=$($result.SignalFrames)/$($result.ExpectedSignalFrames) active=$($result.ActiveFrames) gap=$($result.LongestGapFrames) ratio=$($result.StereoRatio) frequency=$($result.FrequencyHz)")
exit 0
