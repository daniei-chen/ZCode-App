[CmdletBinding()]
param(
    [string]$Output = '',
    [string]$OfficialSource = $env:ZCODE_OFFICIAL_SOURCE,
    [string]$OfficialAsar = ''
)

$ErrorActionPreference = 'Stop'

function FullPath([string]$Path) {
    [IO.Path]::GetFullPath($Path)
}

function RequireFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}

function RequireDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory is missing: $Path"
    }
}

function Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$projectRoot = FullPath (Join-Path $PSScriptRoot '..')
$distRoot = FullPath (Join-Path $projectRoot 'dist')
if (-not $Output) {
    $Output = Join-Path $distRoot 'ZCode-App-latest.zip'
}
$outputPath = FullPath $Output

if (-not $outputPath.StartsWith(($distRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The release ZIP must stay inside the project dist directory: $outputPath"
}

$officialSourcePath = FullPath $OfficialSource
if (-not $OfficialAsar) {
    # Resolve the installed desktop copy without embedding a machine-specific
    # non-ASCII directory name in this UTF-8 PowerShell script.
    $asarCandidate = Get-ChildItem -Path 'D:\*\ZCode\resources\app.asar' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($asarCandidate) {
        $OfficialAsar = $asarCandidate.FullName
    }
}
$officialAsarPath = FullPath $OfficialAsar
RequireDirectory $officialSourcePath
RequireFile $officialAsarPath

$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\S+)')
$version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { 'unknown' }
$safeVersion = $version -replace '[^A-Za-z0-9._-]', '-'
$releaseApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
RequireFile $releaseApk

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('zcode-latest-' + [Guid]::NewGuid().ToString('N'))
$bundleRoot = Join-Path $stageRoot 'ZCode-Control-latest'
$sourceZip = Join-Path $bundleRoot "source\ZCode-Control-source-$safeVersion.zip"
$officialSourceZip = Join-Path $bundleRoot 'reference\zcode-desktop-3.11.2\ZCode-desktop-3.11.2-frontend-source.zip'
$asarCopy = Join-Path $bundleRoot 'reference\zcode-desktop-3.11.2\app.asar'
$apkCopy = Join-Path $bundleRoot "release\ZCode-Control-$safeVersion-release.apk"

try {
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null

    # The source packager includes lib/, relay/API code, WebView integration,
    # request builders, docs, tests, Android/iOS projects and package metadata.
    & (Join-Path $projectRoot 'scripts\package-source.ps1') `
        -Output $sourceZip `
        -StagingParent ([IO.Path]::GetTempPath())

    # Preserve the extracted official desktop frontend and the original asar
    # as reference material for continued native reimplementation work.
    New-Item -ItemType Directory -Path (Split-Path -Parent $officialSourceZip) -Force | Out-Null
    Compress-Archive -LiteralPath $officialSourcePath -DestinationPath $officialSourceZip -CompressionLevel Optimal
    Copy-Item -LiteralPath $officialAsarPath -Destination $asarCopy -Force
    New-Item -ItemType Directory -Path (Split-Path -Parent $apkCopy) -Force | Out-Null
    Copy-Item -LiteralPath $releaseApk -Destination $apkCopy -Force

    $state = @"
# Latest ZCode Control package

- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
- App version: $version
- Source package: source/ZCode-Control-source-$safeVersion.zip
- Release APK: release/ZCode-Control-$safeVersion-release.apk
- Official desktop frontend reference: reference/zcode-desktop-3.11.2/
- Legacy APKs and previous handoff archives are intentionally not included.
- Live remote credentials, private keys and user-specific QR links are intentionally not included.

## Where the request and WebView code lives

- `lib/ui/official_remote_page.dart` — official remote/v4 WebView host
- `lib/services/link_builder.dart` — remote link parsing, trusted-origin checks and URL reconstruction
- `lib/relay/` — relay protocol, frames, request/response assembly and service calls
- `lib/state/` — session, panel, plugin, skill, MCP and runtime state
- `docs/ZCODE-PROTOCOL.md` — desktop protocol notes

The source ZIP contains the complete current working tree required to continue development.
The reference directory contains the locally extracted desktop frontend and its original app.asar.
"@
    $statePath = Join-Path $bundleRoot 'LATEST-STATE.md'
    Set-Content -LiteralPath $statePath -Encoding UTF8 -Value $state

    $topFiles = Get-ChildItem -LiteralPath $bundleRoot -File -Force -Recurse |
        Where-Object { $_.Name -ne 'CHECKSUMS.sha256' } |
        Sort-Object FullName
    $checksums = foreach ($file in $topFiles) {
        $relative = [IO.Path]::GetRelativePath($bundleRoot, $file.FullName).Replace('\', '/')
        "$(Sha256 $file.FullName)  $relative"
    }
    Set-Content -LiteralPath (Join-Path $bundleRoot 'CHECKSUMS.sha256') -Encoding UTF8 -Value $checksums

    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    Compress-Archive -LiteralPath $bundleRoot -DestinationPath $outputPath -CompressionLevel Optimal

    $zipHash = Sha256 $outputPath
    $zipSize = (Get-Item -LiteralPath $outputPath).Length
    Write-Output "Created: $outputPath"
    Write-Output "Bytes: $zipSize"
    Write-Output "SHA256: $zipHash"
    Write-Output "APK: $apkCopy"
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
