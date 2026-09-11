[CmdletBinding()]
param(
    # Defaults that depend on the script location are resolved in the body:
    # $PSScriptRoot is not reliably populated while param defaults evaluate.
    [string]$Output = '',
    [string]$DesktopOutput = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZCode-Control-9H-Iteration-Result-20260911.zip'),
    # Regression reference only (the 1.4.0 build the feedback screenshots came from).
    [Parameter(Mandatory = $true)]
    [string]$BaselineApk,
    # This iteration's release build.
    [string]$IterationApk = '',
    [string]$DesktopApkOutput = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZCode-Control-1.5.0-release.apk'),
    # Local directory holding the user-provided feedback screenshots, either
    # already named S01-…jpg … S11-…jpg or under their original hashed names.
    # Personal to the operator's machine; never a default in the repo.
    [Parameter(Mandatory = $true)]
    [string]$FeedbackDirectory,
    # Local directory holding workbuddy.apk / wb_libapp.so / wb_icons.txt.
    # Reference material only; never enters source, Git or the APK.
    [Parameter(Mandatory = $true)]
    [string]$WorkBuddyDirectory
)

$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Assert-SafeChild([string]$Candidate, [string]$Parent) {
    $candidatePath = Get-FullPath $Candidate
    $parentPath = (Get-FullPath $Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $parentPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside intended parent. Candidate=$candidatePath Parent=$parentPath"
    }
    return $candidatePath
}

function Assert-RequiredFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}

function Copy-RequiredFile([string]$Source, [string]$Destination) {
    Assert-RequiredFile $Source
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Get-FullPath (Join-Path $scriptDir '..')
$distRoot = Get-FullPath (Join-Path $projectRoot 'dist')
if (-not $Output) { $Output = Join-Path $distRoot 'ZCode-Control-9H-Iteration-Result-20260911.zip' }
if (-not $IterationApk) { $IterationApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk' }
$outputPath = Get-FullPath $Output
$desktopPath = Get-FullPath $DesktopOutput
$baselineApkPath = Get-FullPath $BaselineApk
$iterationApkPath = Get-FullPath $IterationApk
$desktopApkPath = Get-FullPath $DesktopApkOutput

New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
Assert-RequiredFile $baselineApkPath
Assert-RequiredFile $iterationApkPath

if (-not $outputPath.StartsWith(($distRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The ZIP output must stay inside the D: project dist directory: $outputPath"
}

$commit = (& git -C $projectRoot rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = 'unknown' }

$stageRoot = Join-Path $distRoot ('handoff-stage-' + [Guid]::NewGuid().ToString('N'))
Assert-SafeChild $stageRoot $distRoot | Out-Null
$bundleRoot = Join-Path $stageRoot 'ZCode-Control-Iteration-Handoff'

# Canonical name -> original attachment name (the user's export).
$feedbackMap = [ordered]@{
    'S01-new-conversation-create-failed.jpg' = '5370f3873e0e71a65f074803ec883dcd.jpg'
    'S02-conversation-native-unavailable.jpg' = 'cdda617764e1409bdd768f044a80bf7a.jpg'
    'S03-conversation-config-rejected.jpg' = '5ce72fa7144d872c7e494ab8ca75b820.jpg'
    'S04-model-empty-sheet.jpg' = 'ea2d3d9e04fb3a86dd783d683192c92e.jpg'
    'S05-duplicate-messages-attachment.jpg' = 'cb39f491c52021d914093400764414eb.jpg'
    'S06-stop-confirmation.jpg' = '21126b5830417c33735f21a62ea9ebfb.jpg'
    'S07-new-conversation-empty.jpg' = 'eb90c3b411f2e0d498b9dd6c51d21099.jpg'
    'S08-usage-remote-placeholder.jpg' = '7d31f6b2f2b4a3a01f6202dddb4413c4.jpg'
    'S09-model-remote-placeholder.jpg' = 'a5089bce2e1da260267738b95b3bfdbc.jpg'
    'S10-plugin-remote-placeholder.jpg' = '6edcd91e77c7a77a93cb5efa6c883dfb.jpg'
    'S11-mcp-remote-placeholder.jpg' = 'e6b42d04fd8a7819357ab1167fe55981.jpg'
}

$workbuddyFiles = @('wb_icons.txt', 'wb_libapp.so', 'workbuddy.apk')

try {
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null

    $sourceZip = Join-Path $bundleRoot 'source\zcode-control-source.zip'
    $sourceScript = Join-Path $projectRoot 'scripts\package-source.ps1'
    Assert-RequiredFile $sourceScript
    & $sourceScript -Output $sourceZip -StagingParent $distRoot

    $docTargets = @(
        'AI-EXECUTION-PROMPT.md',
        'HANDOFF.md',
        'HANDOFF-START-9H.md',
        'ITERATION-PLAN-9H.md',
        'FINAL-9H-EXECUTION-PLAN-20260911.md',
        'PROGRESS-9H.md',
        'PROTOCOL-DELTA-20260911.md',
        'UX-NATIVE-REBUILD-SPEC.md',
        'AUTOMATION-SELF-TEST-PLAN.md',
        'FEEDBACK-AUDIT-20260910.md',
        'ARCHITECTURE.md',
        'RELAY-PROTOCOL-VERIFIED.md',
        'WORKBUDDY-REFERENCE.md',
        'REFERENCE-PACKAGE-NOTICE.md'
    )
    foreach ($name in $docTargets) {
        Copy-RequiredFile (Join-Path $projectRoot "docs\$name") (Join-Path $bundleRoot "docs\$name")
    }
    Copy-RequiredFile (Join-Path $projectRoot 'docs\HANDOFF-START-9H.md') (Join-Path $bundleRoot 'START-HERE.md')
    Copy-RequiredFile (Join-Path $projectRoot 'docs\PROGRESS-9H.md') (Join-Path $bundleRoot 'HANDOFF-REPORT.md')

    # Baseline (regression reference) and this iteration's release build.
    Copy-RequiredFile $baselineApkPath (Join-Path $bundleRoot 'baseline\ZCode-Control-1.4.0-release.apk')
    $baselineHash = Get-Sha256 $baselineApkPath
    Set-Content -LiteralPath (Join-Path $bundleRoot 'baseline\SHA256SUMS.txt') -Encoding UTF8 -Value @(
        "$baselineHash  ZCode-Control-1.4.0-release.apk"
    )
    Copy-RequiredFile $iterationApkPath (Join-Path $bundleRoot 'release\ZCode-Control-1.5.0-release.apk')
    $iterationHash = Get-Sha256 $iterationApkPath
    Set-Content -LiteralPath (Join-Path $bundleRoot 'release\SHA256SUMS.txt') -Encoding UTF8 -Value @(
        "$iterationHash  ZCode-Control-1.5.0-release.apk"
    )

    # Feedback screenshots: accept either naming scheme.
    $feedbackOutput = Join-Path $bundleRoot 'feedback\current-run'
    foreach ($entry in $feedbackMap.GetEnumerator()) {
        $named = Join-Path $FeedbackDirectory $entry.Key
        $hashed = Join-Path $FeedbackDirectory $entry.Value
        $source = if (Test-Path -LiteralPath $named -PathType Leaf) { $named } else { $hashed }
        Copy-RequiredFile $source (Join-Path $feedbackOutput $entry.Key)
    }

    # WorkBuddy reference material: binaries only, clearly labelled.
    foreach ($name in $workbuddyFiles) {
        Copy-RequiredFile (Join-Path $WorkBuddyDirectory $name) (Join-Path $bundleRoot "reference\workbuddy\$name")
    }
    Copy-RequiredFile (Join-Path $projectRoot 'docs\REFERENCE-PACKAGE-NOTICE.md') (Join-Path $bundleRoot 'reference\workbuddy\README-REFERENCE-ONLY.md')

    # This project's own UI screenshots (upstream ZREMOTE era) — they are NOT
    # WorkBuddy material and must not be labelled as such.
    $ownUi = Join-Path $bundleRoot 'reference\zcode-control-ui'
    New-Item -ItemType Directory -Path $ownUi -Force | Out-Null
    foreach ($name in @('screenshot.jpg', 'screenshot-2.jpg', 'session-panel-en.png', 'session-panel-zh.png')) {
        $source = Join-Path $projectRoot "docs\$name"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $ownUi $name) -Force
        }
    }
    Set-Content -LiteralPath (Join-Path $ownUi 'README.md') -Encoding UTF8 -Value @(
        '# ZCode Control 自身界面截图',
        '',
        '这四张图来自本项目 README（上游 zremote 时期的设备管理页与会话面板），用于对照本项目历史 UI。',
        '它们不是 WorkBuddy 的界面；WorkBuddy 参考材料只有 reference/workbuddy/ 下的二进制与图标清单。'
    )

    $manifestPath = Join-Path $bundleRoot 'MANIFEST.md'
    $manifest = @"
# ZCode Control 9 小时迭代结果包

- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
- Source project: $projectRoot
- Source baseline: 8c79d3d
- Iteration head commit: $commit
- Baseline APK (regression reference): baseline/ZCode-Control-1.4.0-release.apk
- Baseline APK SHA-256: $baselineHash
- Iteration release APK: release/ZCode-Control-1.5.0-release.apk
- Iteration release APK SHA-256: $iterationHash
- Real-device test in this package: not executed; user requested testing stop
- Protocol evidence: static zod-schema verification against the local desktop bundle (docs/PROTOCOL-DELTA-20260911.md); app.asar itself was not copied
- WorkBuddy reference: reference/workbuddy/ only; excluded from source/GitHub
- Own UI screenshots: reference/zcode-control-ui/ (not WorkBuddy)

Read START-HERE.md, then HANDOFF-REPORT.md (= docs/PROGRESS-9H.md).
"@
    Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value $manifest

    $forbiddenNames = Get-ChildItem -LiteralPath $bundleRoot -Force -Recurse |
        Where-Object {
            $_.Name -in @('key.properties', 'local.properties') -or
            $_.Extension.ToLowerInvariant() -in @('.jks', '.keystore', '.p12')
        }
    if ($forbiddenNames) {
        throw "Refusing to package signing or local metadata: $($forbiddenNames.FullName -join ', ')"
    }

    $forbiddenDirectories = Get-ChildItem -LiteralPath $bundleRoot -Directory -Force -Recurse |
        Where-Object { $_.Name -in @('.git', '.dart_tool', 'build', 'coverage', '.gradle', '.cxx') }
    if ($forbiddenDirectories) {
        throw "Refusing to package generated or VCS directories: $($forbiddenDirectories.FullName -join ', ')"
    }

    $textExtensions = @('.dart', '.md', '.ps1', '.yaml', '.yml', '.json', '.txt', '.xml', '.gradle', '.properties', '.kts', '.arb')
    $unsafeText = Get-ChildItem -LiteralPath $bundleRoot -File -Force -Recurse |
        Where-Object { $_.Extension.ToLowerInvariant() -in $textExtensions } |
        ForEach-Object {
            $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
            if ($content -match 'remote/v4\?sid=[A-Za-z0-9_-]{8,}' -or
                $content -match 'passHash=[A-Za-z0-9+/=]{16,}' -or
                $content -match 'wxid_[A-Za-z0-9_]{6,}' -or
                $content -match '(?m)^\s*(keyPassword|storePassword)\s*=\s*(?!你的密码|your-password|CHANGE_ME)\S+') {
                $_.FullName
            }
        }
    if ($unsafeText) {
        throw "Refusing to package text that appears to contain a credential, personal id or live remote URL: $($unsafeText -join ', ')"
    }

    $checksumLines = Get-ChildItem -LiteralPath $bundleRoot -File -Force -Recurse |
        Where-Object { $_.Name -notin @('CHECKSUMS.sha256', 'MANIFEST.md') } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($bundleRoot, $_.FullName).Replace('\', '/')
            "$(Get-Sha256 $_.FullName)  $relative"
        }
    Set-Content -LiteralPath (Join-Path $bundleRoot 'CHECKSUMS.sha256') -Encoding UTF8 -Value $checksumLines

    $outputParent = Split-Path -Parent $outputPath
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    Compress-Archive -LiteralPath $bundleRoot -DestinationPath $outputPath -CompressionLevel Optimal

    # Use the Windows tar explicitly: a Git-Bash tar earlier on PATH treats
    # "D:" as a remote host.
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    $finalListing = @(& $tarExe -tf $outputPath)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the generated handoff ZIP."
    }
    $forbiddenArchiveEntries = $finalListing | Where-Object {
        $_ -match '(^|/)(key\.properties|local\.properties)$' -or
        $_ -match '\.(jks|keystore|p12)$' -or
        $_ -match '(^|/)(\.git|\.dart_tool|build|coverage|\.gradle|\.cxx)(/|$)'
    }
    if ($forbiddenArchiveEntries) {
        throw "Generated ZIP contains forbidden entries: $($forbiddenArchiveEntries -join ', ')"
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $desktopPath) -Force | Out-Null
    if (Test-Path -LiteralPath $desktopPath -PathType Leaf) {
        Remove-Item -LiteralPath $desktopPath -Force
    }
    Copy-Item -LiteralPath $outputPath -Destination $desktopPath -Force
    New-Item -ItemType Directory -Path (Split-Path -Parent $desktopApkPath) -Force | Out-Null
    Copy-Item -LiteralPath $iterationApkPath -Destination $desktopApkPath -Force

    $zipHash = Get-Sha256 $outputPath
    Write-Output "Created D: ZIP: $outputPath"
    Write-Output "Copied Desktop ZIP: $desktopPath"
    Write-Output "Copied Desktop APK: $desktopApkPath"
    Write-Output "Iteration APK SHA-256: $iterationHash"
    Write-Output "ZIP SHA-256: $zipHash"
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Assert-SafeChild $stageRoot $distRoot | Out-Null
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
