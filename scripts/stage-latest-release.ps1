[CmdletBinding()]
param(
    [string]$Output = (Join-Path $PSScriptRoot '..\dist\staged'),
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

function CopyTree([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & $env:SystemRoot\System32\robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP /NJH /NJS `
        /XD '.git' '.dart_tool' 'build' 'dist' 'coverage' '.gradle' '.cxx' 'ephemeral' '__pycache__' 'Pods' `
        /XF 'key.properties' 'local.properties' 'Generated.xcconfig' 'flutter_export_environment.sh' '*.jks' '*.keystore' '*.p12' '.env' '.env.*'
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code ${LASTEXITCODE}: $Source"
    }
}

$projectRoot = FullPath (Join-Path $PSScriptRoot '..')
$outputRoot = FullPath $Output
$officialSourcePath = FullPath $OfficialSource
if (-not $OfficialAsar) {
    $asarCandidate = Get-ChildItem -Path 'D:\*\ZCode\resources\app.asar' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($asarCandidate) {
        $OfficialAsar = $asarCandidate.FullName
    }
}
$officialAsarPath = FullPath $OfficialAsar

RequireDirectory $officialSourcePath
RequireFile $officialAsarPath
$releaseApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
RequireFile $releaseApk

$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\S+)')
$version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { 'unknown' }
$safeVersion = $version -replace '[^A-Za-z0-9._-]', '-'

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$projectDestination = Join-Path $outputRoot 'project'
$releaseDestination = Join-Path $outputRoot 'release'
$referenceDestination = Join-Path $outputRoot 'reference\zcode-desktop-3.11.2'

if (Test-Path -LiteralPath $projectDestination) {
    throw "Refusing to overwrite an existing delivery project directory: $projectDestination"
}
New-Item -ItemType Directory -Path $projectDestination,$releaseDestination,$referenceDestination -Force | Out-Null

# Keep the complete current working source, but never carry VCS metadata,
# generated build output or local signing material into the delivery folder.
$projectDirectories = @(
    '.github', 'android', 'assets', 'docs', 'integration_test', 'ios', 'lib',
    'scripts', 'test', 'tools'
)
foreach ($relative in $projectDirectories) {
    $source = Join-Path $projectRoot $relative
    if (Test-Path -LiteralPath $source -PathType Container) {
        CopyTree $source (Join-Path $projectDestination $relative)
    }
}
$projectFiles = @(
    '.gitignore', '.metadata', 'analysis_options.yaml', 'LICENSE', 'l10n.yaml',
    'pubspec.lock', 'pubspec.yaml', 'README.md', 'README.en.md'
)
foreach ($name in $projectFiles) {
    $source = Join-Path $projectRoot $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $projectDestination $name) -Force
    }
}

# Preserve the newest installable app only.
Copy-Item -LiteralPath $releaseApk -Destination (Join-Path $releaseDestination "ZCode-Control-$safeVersion-release.apk") -Force

# Preserve the locally extracted official frontend and original app.asar for
# continued native implementation and protocol inspection.
CopyTree $officialSourcePath (Join-Path $referenceDestination 'frontend-source')
Copy-Item -LiteralPath $officialAsarPath -Destination (Join-Path $referenceDestination 'app.asar') -Force

$state = @"
# ZCode Control latest local delivery

- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
- App version: $version
- Project source: project/
- Latest APK: release/ZCode-Control-$safeVersion-release.apk
- Official desktop frontend: reference/zcode-desktop-3.11.2/frontend-source/
- Original desktop archive: reference/zcode-desktop-3.11.2/app.asar
- Previous APKs, debug builds and previous handoff archives are not included.
- Live remote credentials, private keys and user-specific QR links are not included.

## Request, API and WebView implementation locations

- `project/lib/ui/official_remote_page.dart` — official remote/v4 WebView host
- `project/lib/services/link_builder.dart` — link parsing, trusted-origin checks and URL reconstruction
- `project/lib/relay/` — relay protocol, frames, request/response assembly and service calls
- `project/lib/state/` — session, panel, plugin, skill, MCP and runtime state
- `project/docs/ZCODE-PROTOCOL.md` — protocol notes
- `project/docs/MOBILE-WEB-COVERAGE-20260911.md` — WebView/native coverage notes

The project directory is the current working tree, including the latest uncommitted development changes.
The reference directory is copied from the locally installed ZCode 3.11.2 desktop frontend.
"@
Set-Content -LiteralPath (Join-Path $outputRoot 'LATEST-STATE.md') -Encoding UTF8 -Value $state

$checksumLines = @(
    "$(Sha256 (Join-Path $releaseDestination "ZCode-Control-$safeVersion-release.apk"))  release/ZCode-Control-$safeVersion-release.apk",
    "$(Sha256 (Join-Path $referenceDestination 'app.asar'))  reference/zcode-desktop-3.11.2/app.asar"
)
Set-Content -LiteralPath (Join-Path $outputRoot 'CHECKSUMS.sha256') -Encoding UTF8 -Value $checksumLines

Write-Output "Created delivery folder: $outputRoot"
Write-Output "APK: $(Join-Path $releaseDestination "ZCode-Control-$safeVersion-release.apk")"
Write-Output "Source: $projectDestination"
Write-Output "Official frontend: $(Join-Path $referenceDestination 'frontend-source')"
Write-Output "Official app.asar: $(Join-Path $referenceDestination 'app.asar')"
