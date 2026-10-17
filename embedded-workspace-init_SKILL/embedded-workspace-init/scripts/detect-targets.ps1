[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [switch] $Apply,
    [switch] $AllowInitializing,
    [int] $MutexTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/workspace-common.psm1') -Force

$context = Assert-EwiActiveWorkspace -WorkspaceRoot $WorkspaceRoot -AllowInitializing:$AllowInitializing
$root = $context.root
$targetsPath = Join-Path $root 'workspace-management/config/targets.json'
$schemaPath = Join-Path $root 'workspace-management/schemas/targets.schema.json'
$targets = Read-EwiJson -Path $targetsPath -SchemaPath $schemaPath
$initialHash = Get-EwiSha256 $targetsPath
$targetsOriginal = [IO.File]::ReadAllBytes($targetsPath)

function Get-TargetKeys {
    param($Object)
    if ($Object -is [Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object Name)
}

function Get-TargetValue {
    param($Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    return $Object.PSObject.Properties[$Name].Value
}

$markers = [ordered]@{
    '.project' = 'stm32cubeide-or-eclipse'
    'CMakeLists.txt' = 'cmake'
    'CMakePresets.json' = 'cmake'
    'Makefile' = 'make'
    'platformio.ini' = 'platformio'
    'sdkconfig' = 'esp-idf'
    'west.yml' = 'zephyr'
}
$known = @{}
foreach ($targetId in Get-TargetKeys $targets.targets) {
    $target = Get-TargetValue $targets.targets $targetId
    $known["$($target.source)|$(([string]$target.path).ToLowerInvariant())"] = $targetId
}

$candidates = [Collections.Generic.List[object]]::new()
$missing = [Collections.Generic.List[string]]::new()
$seen = @{}
foreach ($sourceId in Get-TargetKeys $targets.sources) {
    $source = Get-TargetValue $targets.sources $sourceId
    $integrationRoot = Join-EwiContainedPath -Root $root -RelativePath ([string]$source.integration_path)
    if (-not (Test-Path -LiteralPath $integrationRoot -PathType Container)) {
        $missing.Add("source:$sourceId")
        continue
    }
    $inventory = Get-EwiFileInventory -Root $integrationRoot -MappingId $sourceId
    if (-not $inventory.scan_complete) {
        throw "Target scan is incomplete for source '$sourceId'."
    }
    foreach ($entry in @($inventory.files)) {
        $name = [IO.Path]::GetFileName([string]$entry.path)
        $type = $null
        if ($markers.Contains($name)) { $type = $markers[$name] }
        elseif ([IO.Path]::GetExtension($name) -eq '.uvprojx') { $type = 'keil-mdk' }
        elseif ([IO.Path]::GetExtension($name) -eq '.ewp') { $type = 'iar-ew' }
        elseif ($entry.path -match '(^|/)nbproject/') { $type = 'mplab-x' }
        if ($null -eq $type) { continue }

        $projectPath = [IO.Path]::GetDirectoryName([string]$entry.path)
        if ([string]::IsNullOrWhiteSpace($projectPath)) { $projectPath = '.' }
        $projectPath = $projectPath.Replace('\', '/')
        $key = "$sourceId|$($projectPath.ToLowerInvariant())"
        $seen[$key] = $true
        if ($known.ContainsKey($key) -or @($candidates | Where-Object key -eq $key).Count -gt 0) { continue }

        $baseName = if ($projectPath -eq '.') { $sourceId } else { [IO.Path]::GetFileName($projectPath) }
        $baseId = ConvertTo-EwiId $baseName
        $targetId = $baseId
        $suffix = 2
        $allIds = @(Get-TargetKeys $targets.targets) + @($candidates | ForEach-Object target_id)
        while ($allIds -contains $targetId) {
            $targetId = "$baseId-$suffix"
            $suffix++
        }
        $projectRoot = Join-EwiContainedPath -Root $integrationRoot -RelativePath $projectPath -AllowDot
        $generator = @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.ioc' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        $generatorName = if ($generator.Count) { $generator[0].Name } else { $null }
        $mcu = $null
        if ($generator.Count) {
            $line = Select-String -LiteralPath $generator[0].FullName -Pattern '^Mcu\.(?:Name|CPN)=' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $line) { $mcu = ($line.Line -split '=', 2)[1].Trim() }
        }
        $candidates.Add([pscustomobject][ordered]@{
            key = $key
            target_id = $targetId
            source_id = $sourceId
            path = $projectPath
            mcu = $mcu
            project_type = $type
            entry = $name
            generator = $generatorName
        })
    }
}

foreach ($key in $known.Keys) {
    if (-not $seen.ContainsKey($key)) { $missing.Add("target:$($known[$key])") }
}

if (-not $Apply) {
    [pscustomobject][ordered]@{
        status = 'report-only'
        candidates = @($candidates)
        missing_or_moved = @($missing)
        changed = $false
    } | ConvertTo-Json -Depth 10
    return
}

$applied = Invoke-EwiLocked -WorkspaceRoot $root -TimeoutSeconds $MutexTimeoutSeconds -ScriptBlock {
    $null = Assert-EwiActiveWorkspace -WorkspaceRoot $root -AllowInitializing:$AllowInitializing
    if ((Get-EwiSha256 $targetsPath) -ne $initialHash) {
        throw 'targets.json changed after the scan; rerun detection.'
    }
    $current = Read-EwiJson -Path $targetsPath -SchemaPath $schemaPath
    foreach ($candidate in $candidates) {
        if (@($current.targets.PSObject.Properties | ForEach-Object Name) -contains $candidate.target_id) { continue }
        $value = [pscustomobject][ordered]@{
            source = $candidate.source_id
            path = $candidate.path
            mcu = $candidate.mcu
            project = [pscustomobject][ordered]@{
                type = $candidate.project_type
                entry = $candidate.entry
                generator = $candidate.generator
            }
            builds = [pscustomobject]@{}
        }
        $current.targets | Add-Member -NotePropertyName $candidate.target_id -NotePropertyValue $value
        $metadata = [pscustomobject][ordered]@{
            provenance = 'detected'
            verification = 'unverified'
            freshness = 'current'
        }
        $current.field_metadata | Add-Member -NotePropertyName "/targets/$($candidate.target_id)/project" -NotePropertyValue $metadata
    }
    $projectChanges = Initialize-EwiProjectDefinitions -Targets $current -WorkspaceRoot $root
    if ($candidates.Count -gt 0 -or $projectChanges) {
        try {
            Write-EwiJsonAtomic -Path $targetsPath -Value $current -SchemaPath $schemaPath
            $null = New-EwiGitCommit -Repository $root -Message 'chore: register detected embedded targets' -RelativePaths @('workspace-management/config/targets.json')
        }
        catch {
            [IO.File]::WriteAllBytes($targetsPath, $targetsOriginal)
            $null = Invoke-EwiGit -Repository $root -ArgumentList @('reset', '--', 'workspace-management/config/targets.json') -AllowFailure
            throw
        }
    }
    return [pscustomobject]@{ registered = $candidates.Count; project_changes = $projectChanges }
}

$output = [pscustomobject][ordered]@{
    status = 'applied'
    registered = $applied.registered
    missing_or_moved = @($missing)
    changed = ($applied.registered -gt 0 -or $applied.project_changes)
    evidence = $null
}
if ($output.changed) {
    $evidenceId = New-EwiEvidenceId 'target-detection'
    $null = Write-EwiEvidence -WorkspaceRoot $root -EvidenceId $evidenceId -Kind 'target-detection' `
        -Subject ([pscustomobject][ordered]@{ workspace = $root; source_id = $null; target_id = $null; build_id = $null; workstream_id = $null; publish_id = $null; reference_id = $null }) `
        -Result ([pscustomobject][ordered]@{ status = 'passed'; summary = "Registered $($applied.registered) newly detected embedded target(s)."; exit_code = 0; details = [pscustomobject][ordered]@{ registered = $applied.registered; project_changes = $applied.project_changes; missing_or_moved = @($missing) } }) -Artifacts @()
    $output.evidence = "workspace-management/evidence/$evidenceId.json"
}
$output | ConvertTo-Json -Depth 10
