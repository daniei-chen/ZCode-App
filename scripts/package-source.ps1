[CmdletBinding()]
param(
    [string]$Output = (Join-Path (Get-Location) 'dist\zcode-control-source.zip'),
    [string]$StagingParent = [IO.Path]::GetTempPath()
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputPath = [IO.Path]::GetFullPath($Output)
$stagingParentPath = [IO.Path]::GetFullPath($StagingParent)
New-Item -ItemType Directory -Path $stagingParentPath -Force | Out-Null
$stageRoot = Join-Path $stagingParentPath ('zcode-control-package-' + [Guid]::NewGuid().ToString('N'))
$stageProject = Join-Path $stageRoot 'zcode-control'

$include = @(
    '.github',
    'android',
    'assets',
    'docs',
    'integration_test',
    'ios',
    'lib',
    'scripts',
    'test',
    '.gitignore',
    'analysis_options.yaml',
    'LICENSE',
    'l10n.yaml',
    'pubspec.lock',
    'pubspec.yaml',
    'README.md',
    'README.en.md'
)

try {
    New-Item -ItemType Directory -Path $stageProject -Force | Out-Null
    foreach ($relative in $include) {
        $source = Join-Path $projectRoot $relative
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Required delivery path is missing: $relative"
        }
        $destination = Join-Path $stageProject $relative
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }

    # Android/IDE local metadata may exist in a developer checkout. Strip it
    # only from the temporary staging tree; never mutate the source project.
    Get-ChildItem -LiteralPath $stageProject -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSIsContainer -and
            $_.Name -in @('.gradle', '.cxx', '.dart_tool', 'build', 'coverage', 'ephemeral')
        } |
        Remove-Item -Recurse -Force

    # Flutter-generated iOS files embed absolute local paths and must not ship.
    Get-ChildItem -LiteralPath $stageProject -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.PSIsContainer -and
            ($_.Name -in @('key.properties', 'local.properties',
                    'Generated.xcconfig', 'flutter_export_environment.sh') -or
                $_.Extension.ToLowerInvariant() -in @('.jks', '.keystore', '.p12'))
        } |
        Remove-Item -Force

    Get-ChildItem -LiteralPath $stageProject -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('key.properties', 'local.properties') -or
            $_.Extension.ToLowerInvariant() -in @('.jks', '.keystore', '.p12')
        } |
        Out-Null

    $forbidden = Get-ChildItem -LiteralPath $stageProject -Force -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '[\\/]\.git([\\/]|$)' -or
            $_.FullName -match '[\\/]tools([\\/]|$)' -or
            $_.Name -in @('.gradle', '.cxx') -or
            $_.Name -in @('key.properties', 'local.properties') -or
            $_.Extension.ToLowerInvariant() -in @('.jks', '.keystore', '.p12') -or
            $_.Name -in @('.dart_tool', 'build', 'coverage')
        }
    if ($forbidden) {
        throw "Refusing to package forbidden delivery data: $($forbidden.FullName -join ', ')"
    }

    $outputParent = Split-Path -Parent $outputPath
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    if (Test-Path -LiteralPath $outputPath) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    Compress-Archive -LiteralPath $stageProject -DestinationPath $outputPath -CompressionLevel Optimal
    Write-Output "Created $outputPath"
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
