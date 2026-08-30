[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $BuildArguments
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Parent $PSCommandPath
$settingsPath = Join-Path $moduleRoot 'Settings.R4S'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Settings file not found: $settingsPath"
}

$settings = @{}
foreach ($line in Get-Content -LiteralPath $settingsPath) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
    $separator = $trimmed.IndexOf('=')
    if ($separator -le 0) { continue }
    $settings[$trimmed.Substring(0, $separator)] = $trimmed.Substring($separator + 1)
}

function Resolve-ModulePath([string] $Name) {
    if (-not $settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($settings[$Name])) {
        throw "$Name is missing in $settingsPath"
    }
    $value = $settings[$Name]
    if ([System.IO.Path]::IsPathRooted($value)) {
        return [System.IO.Path]::GetFullPath($value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $moduleRoot $value))
}

$sdkRoot = Resolve-ModulePath 'SDK_ROOT'
$contractRoot = Resolve-ModulePath 'CONTRACT_ROOT'
$devkitRoot = Resolve-ModulePath 'DEVKIT_ROOT'
$artifactsRoot = Resolve-ModulePath 'ARTIFACTS_ROOT'
$zigSetting = $settings['ZIG_ROOT']
if ([string]::IsNullOrWhiteSpace($zigSetting)) { throw "ZIG_ROOT is missing in $settingsPath" }
$zigRoot = if ([System.IO.Path]::IsPathRooted($zigSetting)) {
    [System.IO.Path]::GetFullPath($zigSetting)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $devkitRoot $zigSetting))
}
$zigName = if ($IsWindows) { 'zig.exe' } else { 'zig' }
$zig = Join-Path $zigRoot $zigName

foreach ($required in @(
    (Join-Path $sdkRoot 'build.zig.zon'),
    (Join-Path $contractRoot 'build.zig.zon'),
    $zig
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required build dependency not found: $required"
    }
}

New-Item -ItemType Directory -Force -Path $artifactsRoot | Out-Null
Push-Location $moduleRoot
try {
    & $zig build --prefix $artifactsRoot "--fork=$sdkRoot" "--fork=$contractRoot" @BuildArguments
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
