Set-StrictMode -Version Latest

$script:EwiSchemaVersion = 1
$script:EwiPolicyVersion = 1
$script:EwiJsonDepth = 100
$script:EwiExcludedDirectories = @(
    '.git',
    '.metadata',
    '.vs',
    '__pycache__'
)
$script:EwiBuildDirectories = @(
    '.pio',
    'build',
    'cmakefiles',
    'debug',
    'dist',
    'out',
    'release'
)
$script:EwiExcludedFiles = @('Thumbs.db', '.DS_Store')
$script:EwiSecretNames = @(
    '.env',
    'id_rsa',
    'id_ed25519',
    'credentials.json',
    'secrets.json',
    'production.key',
    'signing.key'
)
$script:EwiSecretExtensions = @('.pfx', '.p12', '.pvk')
$script:EwiLegalNames = @('LICENSE', 'LICENSE.txt', 'LICENSE.md', 'NOTICE', 'NOTICE.txt', 'COPYING', 'COPYRIGHT')
$script:EwiAmbiguousLicenseNames = @('activation.dat', 'license.bin', 'license.dat', 'license.key', 'license.lic')
$script:EwiAmbiguousLicenseExtensions = @('.lic')

function Get-EwiTimestamp {
    [DateTimeOffset]::Now.ToString('o')
}

function New-EwiEvidenceId {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Prefix)

    $safePrefix = ConvertTo-EwiId -Value $Prefix -MaximumLength 80 -Fallback 'evidence'
    return $safePrefix + '-' + [DateTimeOffset]::Now.ToString('yyyyMMddHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
}

function ConvertTo-EwiId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Value,
        [int] $MaximumLength = 64,
        [string] $Fallback = 'item'
    )

    $id = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $id = $id.Trim('-')
    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = $Fallback
    }
    if ($id.Length -gt $MaximumLength) {
        $id = $id.Substring(0, $MaximumLength).TrimEnd('-')
    }
    if ($id -notmatch '^[a-z0-9]') {
        $id = "$Fallback-$id"
    }
    return $id
}

function Resolve-EwiPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path cannot be empty.'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Path]::IsPathFullyQualified($fullPath)) {
        throw "Path is not fully qualified: $Path"
    }

    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($root -notmatch '^[A-Za-z]:[\\/]$') {
        throw "Only local Windows drive paths are supported: $Path"
    }

    $segments = $fullPath.Substring($root.Length).Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries
    )
    $current = $root

    for ($index = 0; $index -lt $segments.Count; $index++) {
        $candidate = [IO.Path]::Combine($current, $segments[$index])
        if (-not (Test-Path -LiteralPath $candidate)) {
            if (-not $AllowMissing) {
                throw "Path does not exist: $candidate"
            }
            for ($tail = $index; $tail -lt $segments.Count; $tail++) {
                $current = [IO.Path]::Combine($current, $segments[$tail])
            }
            break
        }

        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $resolved = $item.ResolveLinkTarget($true)
            if ($null -eq $resolved) {
                throw "Cannot resolve reparse point: $candidate"
            }
            $current = $resolved.FullName
        }
        else {
            $current = $item.FullName
        }
    }

    $canonical = [IO.Path]::GetFullPath($current)
    if ($canonical.Length -gt $root.Length) {
        $canonical = $canonical.TrimEnd([char[]]@('\', '/'))
    }
    return $canonical
}

function Get-EwiPathIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $AllowMissing
    )

    (Resolve-EwiPath -Path $Path -AllowMissing:$AllowMissing).Replace('/', '\').TrimEnd('\').ToUpperInvariant()
}

function Test-EwiPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Parent,
        [switch] $AllowEqual,
        [switch] $AllowMissing
    )

    $pathIdentity = Get-EwiPathIdentity -Path $Path -AllowMissing:$AllowMissing
    $parentIdentity = Get-EwiPathIdentity -Path $Parent -AllowMissing:$AllowMissing
    if ($pathIdentity -eq $parentIdentity) {
        return [bool]$AllowEqual
    }
    return $pathIdentity.StartsWith($parentIdentity + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-EwiPathsSeparated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $First,
        [Parameter(Mandatory)] [string] $Second,
        [string] $FirstLabel = 'first path',
        [string] $SecondLabel = 'second path',
        [switch] $AllowMissing
    )

    if ((Test-EwiPathWithin -Path $First -Parent $Second -AllowEqual -AllowMissing:$AllowMissing) -or
        (Test-EwiPathWithin -Path $Second -Parent $First -AllowEqual -AllowMissing:$AllowMissing)) {
        throw "$FirstLabel and $SecondLabel must be real-path disjoint: '$First' and '$Second'."
    }
}

function Assert-EwiRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [switch] $AllowDot
    )

    $candidate = $Path.Replace('\', '/').TrimEnd('/')
    if ($AllowDot -and ($candidate -eq '' -or $candidate -eq '.')) {
        return '.'
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        [IO.Path]::IsPathFullyQualified($candidate) -or
        $candidate.StartsWith('/') -or
        $candidate -match '(^|/)\.\.(/|$)') {
        throw "Unsafe relative path: $Path"
    }
    return $candidate
}

function Join-EwiContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $RelativePath,
        [switch] $AllowDot
    )

    $rootPath = Resolve-EwiPath -Path $Root
    $safeRelative = Assert-EwiRelativePath -Path $RelativePath -AllowDot:$AllowDot
    if ($safeRelative -eq '.') {
        return $rootPath
    }
    $combined = Resolve-EwiPath -Path ([IO.Path]::Combine($rootPath, $safeRelative)) -AllowMissing
    if (-not (Test-EwiPathWithin -Path $combined -Parent $rootPath -AllowMissing)) {
        throw "Path escapes root '$rootPath': $RelativePath"
    }
    return $combined
}

function Get-EwiSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-EwiTextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-EwiCanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $Value)

    $oldWarningPreference = $WarningPreference
    try {
        $WarningPreference = 'Stop'
        try {
            return ConvertTo-Json -InputObject $Value -Depth $script:EwiJsonDepth -Compress -WarningAction Stop
        }
        catch {
            throw "JSON serialization depth exceeded or failed: $($_.Exception.Message)"
        }
    }
    finally {
        $WarningPreference = $oldWarningPreference
    }
}

function Get-EwiJsonKind {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string] -or $Value -is [char]) { return 'string' }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [System.Numerics.BigInteger]) {
        return 'integer'
    }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return 'number' }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) { return 'object' }
    if ($Value -is [Collections.IEnumerable]) { return 'array' }
    return 'unsupported'
}

function Get-EwiObjectProperties {
    param([Parameter(Mandatory)] $Value)

    $result = [ordered]@{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = $Value[$key]
        }
    }
    else {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -in @('NoteProperty', 'Property')) {
                $result[$property.Name] = $property.Value
            }
        }
    }
    return $result
}

function Test-EwiJsonEquivalent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Expected,
        [Parameter(Mandatory)] [AllowNull()] $Actual
    )

    $expectedKind = Get-EwiJsonKind $Expected
    $actualKind = Get-EwiJsonKind $Actual
    if ($expectedKind -ne $actualKind) { return $false }

    switch ($expectedKind) {
        'null' { return $true }
        'boolean' { return [bool]$Expected -eq [bool]$Actual }
        'string' { return [string]$Expected -ceq [string]$Actual }
        'integer' { return [decimal]$Expected -eq [decimal]$Actual }
        'number' { return [decimal]$Expected -eq [decimal]$Actual }
        'array' {
            $expectedArray = @($Expected)
            $actualArray = @($Actual)
            if ($expectedArray.Count -ne $actualArray.Count) { return $false }
            for ($index = 0; $index -lt $expectedArray.Count; $index++) {
                if (-not (Test-EwiJsonEquivalent -Expected $expectedArray[$index] -Actual $actualArray[$index])) {
                    return $false
                }
            }
            return $true
        }
        'object' {
            $expectedProperties = Get-EwiObjectProperties $Expected
            $actualProperties = Get-EwiObjectProperties $Actual
            $expectedKeys = @($expectedProperties.Keys | Sort-Object)
            $actualKeys = @($actualProperties.Keys | Sort-Object)
            if ($expectedKeys.Count -ne $actualKeys.Count) { return $false }
            for ($index = 0; $index -lt $expectedKeys.Count; $index++) {
                if ($expectedKeys[$index] -cne $actualKeys[$index]) { return $false }
                $key = $expectedKeys[$index]
                if (-not (Test-EwiJsonEquivalent -Expected $expectedProperties[$key] -Actual $actualProperties[$key])) {
                    return $false
                }
            }
            return $true
        }
        default { throw "Unsupported JSON value type: $($Expected.GetType().FullName)" }
    }
}

function Read-EwiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $SchemaPath
    )

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON file is empty: $Path"
    }
    if ($SchemaPath) {
        $valid = Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
        if (-not $valid) { throw "JSON does not match schema '$SchemaPath': $Path" }
    }
    return ($raw | ConvertFrom-Json -Depth $script:EwiJsonDepth -DateKind String -ErrorAction Stop)
}

function Write-EwiJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "JSON parent directory does not exist: $parent"
    }
    $json = ConvertTo-EwiCanonicalJson -Value $Value
    try {
        $schemaValid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
    }
    catch {
        throw "Refusing schema-invalid JSON write: $Path. $($_.Exception.Message)"
    }
    if (-not $schemaValid) {
        throw "Refusing schema-invalid JSON write: $Path"
    }
    $roundTrip = $json | ConvertFrom-Json -Depth $script:EwiJsonDepth -DateKind String -ErrorAction Stop
    if (-not (Test-EwiJsonEquivalent -Expected $Value -Actual $roundTrip)) {
        throw "JSON round-trip changed a type, key, array length, or value: $Path"
    }

    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $written = Read-EwiJson -Path $temporary -SchemaPath $SchemaPath
        if (-not (Test-EwiJsonEquivalent -Expected $Value -Actual $written)) {
            throw "Written JSON failed round-trip comparison: $Path"
        }
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-EwiJsonLinesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "JSONL parent directory does not exist: $parent"
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($record in $Records) {
        $line = ConvertTo-EwiCanonicalJson -Value $record
        try {
            $schemaValid = Test-Json -Json $line -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
        }
        catch {
            throw "JSONL record does not match schema '$SchemaPath': $Path. $($_.Exception.Message)"
        }
        if (-not $schemaValid) { throw "JSONL record does not match schema '$SchemaPath': $Path" }
        $parsed = $line | ConvertFrom-Json -Depth $script:EwiJsonDepth -DateKind String -ErrorAction Stop
        if (-not (Test-EwiJsonEquivalent -Expected $record -Actual $parsed)) {
            throw "JSONL record failed round-trip comparison: $Path"
        }
        $lines.Add($line)
    }

    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $content = if ($lines.Count) { [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine } else { '' }
        [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
        foreach ($line in [IO.File]::ReadLines($temporary)) {
            $null = $line | ConvertFrom-Json -Depth $script:EwiJsonDepth -DateKind String -ErrorAction Stop
            try {
                $schemaValid = Test-Json -Json $line -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
            }
            catch {
                throw "Written JSONL record failed schema validation: $Path. $($_.Exception.Message)"
            }
            if (-not $schemaValid) { throw "Written JSONL record failed schema validation: $Path" }
        }
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-EwiMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkspaceRoot)

    $identity = Get-EwiPathIdentity -Path $WorkspaceRoot -AllowMissing
    $digest = Get-EwiTextSha256 -Text $identity
    return "Local\embedded-workspace-init-$($digest.Substring(0, 24))"
}

function Invoke-EwiLocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceRoot,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int] $TimeoutSeconds = 30
    )

    $mutexName = Get-EwiMutexName -WorkspaceRoot $WorkspaceRoot
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Workspace is busy; mutex timed out without writing: $mutexName"
        }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-EwiProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ArgumentList,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [hashtable] $Environment = @{},
        [switch] $AllowFailure
    )

    $resolvedExecutable = (Get-Command -Name $Executable -ErrorAction Stop).Source
    $resolvedWorkingDirectory = Resolve-EwiPath -Path $WorkingDirectory
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedExecutable
    $startInfo.WorkingDirectory = $resolvedWorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ([IO.Path]::GetFileNameWithoutExtension($resolvedExecutable) -eq 'git') {
        foreach ($key in @($startInfo.Environment.Keys)) {
            if ($key -match '^GIT_(?:DIR|WORK_TREE|COMMON_DIR|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE|PREFIX|CONFIG(?:_COUNT|_PARAMETERS|_KEY_\d+|_VALUE_\d+)?|SHALLOW_FILE|GRAFT_FILE|REPLACE_REF_BASE)$') {
                $null = $startInfo.Environment.Remove($key)
            }
        }
    }
    foreach ($key in $Environment.Keys) { $startInfo.Environment[$key] = [string]$Environment[$key] }
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start executable: $resolvedExecutable" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $result = [pscustomobject][ordered]@{
        Executable = $resolvedExecutable
        Arguments = @($ArgumentList)
        WorkingDirectory = $resolvedWorkingDirectory
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
    $process.Dispose()
    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        throw "Process failed with exit code $($result.ExitCode): $resolvedExecutable`n$stderr"
    }
    return $result
}

function Get-EwiGitRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Repository)

    $repositoryPath = Resolve-EwiPath -Path $Repository
    $result = Invoke-EwiProcess -Executable 'git' -ArgumentList @('-C', $repositoryPath, 'rev-parse', '--show-toplevel') -WorkingDirectory $repositoryPath
    return Resolve-EwiPath -Path $result.StdOut.Trim()
}

function Invoke-EwiGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ArgumentList,
        [hashtable] $Environment = @{},
        [switch] $AllowFailure
    )

    $repositoryPath = Resolve-EwiPath -Path $Repository
    if ($ArgumentList.Count -eq 0 -or $ArgumentList[0] -ne 'init') {
        $actualRoot = Get-EwiGitRoot -Repository $repositoryPath
        if ((Get-EwiPathIdentity $actualRoot) -ne (Get-EwiPathIdentity $repositoryPath)) {
            throw "Git repository root mismatch. Expected '$repositoryPath', actual '$actualRoot'."
        }
    }
    return Invoke-EwiProcess -Executable 'git' -ArgumentList (@('-C', $repositoryPath) + $ArgumentList) -WorkingDirectory $repositoryPath -Environment $Environment -AllowFailure:$AllowFailure
}

function Initialize-EwiGitRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Repository)

    $repositoryPath = Resolve-EwiPath -Path $Repository
    if (Test-Path -LiteralPath (Join-Path $repositoryPath '.git')) {
        if ((Get-EwiPathIdentity (Get-EwiGitRoot $repositoryPath)) -ne (Get-EwiPathIdentity $repositoryPath)) {
            throw "Existing Git metadata does not belong to repository root: $repositoryPath"
        }
        return $false
    }
    $null = Invoke-EwiProcess -Executable 'git' -ArgumentList @('-C', $repositoryPath, 'init', '--initial-branch=main') -WorkingDirectory $repositoryPath
    $null = Invoke-EwiGit -Repository $repositoryPath -ArgumentList @('config', '--local', 'user.name', 'Embedded Workspace Agent')
    $null = Invoke-EwiGit -Repository $repositoryPath -ArgumentList @('config', '--local', 'user.email', 'embedded-workspace-init@local.invalid')
    return $true
}

function Add-EwiGitPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string[]] $RelativePaths
    )

    $paths = @($RelativePaths | ForEach-Object { Assert-EwiRelativePath -Path $_ } | Sort-Object -Unique)
    $chunk = [Collections.Generic.List[string]]::new()
    $length = 0
    foreach ($path in $paths) {
        if ($chunk.Count -gt 0 -and ($length + $path.Length) -gt 7000) {
            $null = Invoke-EwiGit -Repository $Repository -ArgumentList (@('add', '--') + @($chunk))
            $chunk.Clear()
            $length = 0
        }
        $chunk.Add($path)
        $length += $path.Length + 1
    }
    if ($chunk.Count -gt 0) {
        $null = Invoke-EwiGit -Repository $Repository -ArgumentList (@('add', '--') + @($chunk))
    }
}

function New-EwiGitCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string[]] $RelativePaths
    )

    $paths = @($RelativePaths | ForEach-Object { Assert-EwiRelativePath -Path $_ } | Sort-Object -Unique)
    Add-EwiGitPaths -Repository $Repository -RelativePaths $paths
    $requested = @{}
    foreach ($path in $paths) { $requested[$path.ToLowerInvariant()] = $true }
    $stagedNames = (Invoke-EwiGit -Repository $Repository -ArgumentList @('diff', '--cached', '--name-only', '-z')).StdOut
    $hasRequestedChange = @($stagedNames.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $requested.ContainsKey($_.Replace('\', '/').ToLowerInvariant()) }).Count -gt 0
    if (-not $hasRequestedChange) { return $null }

    $gitDirectory = (Invoke-EwiGit -Repository $Repository -ArgumentList @('rev-parse', '--absolute-git-dir')).StdOut.Trim()
    $pathspec = Join-Path $gitDirectory ('ewi-pathspec-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($pathspec, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            foreach ($path in $paths) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($path)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.WriteByte(0)
            }
        }
        finally { $stream.Dispose() }
        $commit = Invoke-EwiGit -Repository $Repository -ArgumentList @('commit', '--only', '-m', $Message, "--pathspec-from-file=$pathspec", '--pathspec-file-nul') -AllowFailure
        if ($commit.ExitCode -ne 0) {
            $chunk = [Collections.Generic.List[string]]::new()
            $length = 0
            foreach ($path in $paths) {
                if ($chunk.Count -gt 0 -and ($length + $path.Length) -gt 7000) {
                    $null = Invoke-EwiGit -Repository $Repository -ArgumentList (@('reset', '--') + @($chunk)) -AllowFailure
                    $chunk.Clear()
                    $length = 0
                }
                $chunk.Add($path)
                $length += $path.Length + 1
            }
            if ($chunk.Count -gt 0) { $null = Invoke-EwiGit -Repository $Repository -ArgumentList (@('reset', '--') + @($chunk)) -AllowFailure }
            throw "Git commit failed in '$Repository': $($commit.StdErr.Trim())"
        }
        return (Invoke-EwiGit -Repository $Repository -ArgumentList @('rev-parse', 'HEAD')).StdOut.Trim()
    }
    finally {
        if (Test-Path -LiteralPath $pathspec) { [IO.File]::Delete($pathspec) }
    }
}

function Get-EwiSensitiveClassification {
    param([Parameter(Mandatory)] [IO.FileInfo] $File)

    if ($script:EwiSecretNames -contains $File.Name.ToLowerInvariant()) { return 'definite' }
    if ($script:EwiSecretExtensions -contains $File.Extension.ToLowerInvariant()) { return 'definite' }
    if ($File.Name -match '(?i)(production|release)[-_]?(sign|signing|private|secret).*(key|pem)$') { return 'definite' }
    if ($File.Length -le 1048576) {
        try {
            $content = [IO.File]::ReadAllText($File.FullName)
            if ($content -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' -or
                $content -match '(?:AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})') { return 'definite' }
            if ($content -match '(?i)(?:api[_-]?key|client[_-]?secret|access[_-]?token)\s*[:=]\s*["''][^"'']{8,}') { return 'ambiguous' }
        }
        catch { return 'none' }
    }
    return 'none'
}

function Test-EwiLikelySecret {
    param([Parameter(Mandatory)] [IO.FileInfo] $File)
    return (Get-EwiSensitiveClassification -File $File) -ne 'none'
}

function Test-EwiAmbiguousLicenseFile {
    param([Parameter(Mandatory)] [IO.FileInfo] $File)

    if ($script:EwiLegalNames -contains $File.Name) { return $false }
    return $script:EwiAmbiguousLicenseNames -contains $File.Name.ToLowerInvariant() -or
        $script:EwiAmbiguousLicenseExtensions -contains $File.Extension.ToLowerInvariant()
}

function Get-EwiFileInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string] $MappingId = 'root',
        [switch] $IncludeBuildDirectories
    )

    $rootPath = Resolve-EwiPath -Path $Root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Inventory root is not a directory: $rootPath"
    }

    $files = [Collections.Generic.List[object]]::new()
    $excluded = [Collections.Generic.List[string]]::new()
    $sensitive = [Collections.Generic.List[string]]::new()
    $pendingReview = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $gitTopology = [Collections.Generic.List[string]]::new()
    $links = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $keilOutputDirectories = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($rootPath)

    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        }
        catch {
            $errors.Add("$directory :: $($_.Exception.Message)")
            continue
        }
        foreach ($project in @($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.uvprojx' })) {
            try {
                $xml = [xml][IO.File]::ReadAllText($project.FullName)
                foreach ($node in $xml.SelectNodes('//TargetCommonOption/OutputDirectory')) {
                    $output = [string]$node.InnerText
                    if ([string]::IsNullOrWhiteSpace($output)) { continue }
                    $outputPath = [IO.Path]::GetFullPath((Join-Path $project.DirectoryName $output))
                    if (Test-EwiPathWithin -Path $outputPath -Parent $rootPath -AllowEqual -AllowMissing) { $keilOutputDirectories.Add($outputPath) }
                }
            }
            catch { $errors.Add("$($project.FullName) :: unreadable Keil output configuration: $($_.Exception.Message)") }
        }
        foreach ($child in $children) {
            $relative = [IO.Path]::GetRelativePath($rootPath, $child.FullName).Replace('\', '/')
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $links.Add($relative)
                continue
            }
            if ($child.PSIsContainer) {
                if ($child.Name -eq '.git') {
                    if ((Get-EwiPathIdentity $directory) -ne (Get-EwiPathIdentity $rootPath)) { $gitTopology.Add($relative + '/') }
                    $excluded.Add($relative + '/')
                    continue
                }
                if ($script:EwiExcludedDirectories -contains $child.Name -or
                    (-not $IncludeBuildDirectories -and $script:EwiBuildDirectories -contains $child.Name.ToLowerInvariant())) {
                    $excluded.Add($relative + '/')
                }
                else {
                    $pending.Push($child.FullName)
                }
                continue
            }
            if ($script:EwiExcludedFiles -contains $child.Name) {
                $excluded.Add($relative)
                continue
            }
            if ($child.Name -match '\.uvguix\.' -or $child.Extension -eq '.dbgconf') {
                $excluded.Add($relative)
                continue
            }
            $inKeilOutput = @($keilOutputDirectories | Where-Object { Test-EwiPathWithin -Path $child.FullName -Parent $_ -AllowMissing }).Count -gt 0
            if (-not $IncludeBuildDirectories -and (($inKeilOutput -and $child.Extension -in @('.o', '.d', '.crf', '.axf', '.hex', '.map', '.lnp', '.dep', '.htm')) -or
                ($child.Extension -eq '.lst' -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($child.FullName, '.s')))))) {
                $excluded.Add($relative)
                continue
            }
            if ($child.Name -eq '.git') {
                $gitTopology.Add($relative)
                $excluded.Add($relative)
                continue
            }
            if (Test-EwiAmbiguousLicenseFile -File $child) {
                $pendingReview.Add($relative)
                continue
            }
            $sensitiveClassification = Get-EwiSensitiveClassification -File $child
            if ($sensitiveClassification -ne 'none') {
                if ($script:EwiLegalNames -contains $child.Name -and $sensitiveClassification -eq 'ambiguous') {
                    $warnings.Add("Legal file '$relative' matched a sensitive-content pattern and was retained for review.")
                }
                else {
                    $sensitive.Add($relative)
                    continue
                }
            }
            try {
                $files.Add([pscustomobject][ordered]@{
                    mapping_id = $MappingId
                    path = $relative
                    type = 'file'
                    size = [int64]$child.Length
                    mtime_utc = $child.LastWriteTimeUtc.ToString('o')
                    sha256 = Get-EwiSha256 -Path $child.FullName
                })
            }
            catch {
                $errors.Add("$relative :: $($_.Exception.Message)")
            }
        }
    }

    return [pscustomobject][ordered]@{
        root = $rootPath
        scan_complete = ($errors.Count -eq 0 -and $links.Count -eq 0)
        files = @($files | Sort-Object path)
        excluded = @($excluded | Sort-Object)
        sensitive = @($sensitive | Sort-Object)
        pending = @($pendingReview | Sort-Object)
        warnings = @($warnings | Sort-Object)
        git_topology = @($gitTopology | Sort-Object)
        links = @($links | Sort-Object)
        errors = @($errors)
    }
}

function Get-EwiInventoryDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Inventory)

    $facts = [Collections.Generic.List[string]]::new()
    foreach ($fact in @($Inventory.files | ForEach-Object {
        "$($_.mapping_id)`t$($_.path)`t$($_.type)`t$($_.size)`t$($_.sha256)"
    })) { $facts.Add("file`t$fact") }
    foreach ($category in @('excluded', 'sensitive', 'pending', 'warnings', 'git_topology', 'links', 'errors')) {
        foreach ($value in @($Inventory.$category)) { $facts.Add("$category`t$value") }
    }
    $facts.Sort([StringComparer]::Ordinal)
    Get-EwiTextSha256 -Text ([string]::Join("`n", $facts))
}

function Get-EwiMappingDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Mappings,
        [Parameter(Mandatory)] $LocalMappings
    )

    $facts = [Collections.Generic.List[object]]::new()
    foreach ($mapping in @($Mappings | Sort-Object mapping_id)) {
        $mappingId = [string]$mapping.mapping_id
        $localValue = if ($LocalMappings -is [Collections.IDictionary]) { $LocalMappings[$mappingId] } else {
            $property = $LocalMappings.PSObject.Properties[$mappingId]
            if ($null -eq $property) { $null } else { $property.Value }
        }
        if ($null -eq $localValue) { throw "Missing local mapping for digest: $mappingId" }
        $facts.Add([pscustomobject][ordered]@{
            mapping_id = $mappingId
            integration_subpath = (Assert-EwiRelativePath -Path ([string]$mapping.integration_subpath) -AllowDot)
            kind = [string]$mapping.kind
            source_identity = Get-EwiPathIdentity ([string]$localValue.source_path)
        })
    }
    return Get-EwiTextSha256 (ConvertTo-EwiCanonicalJson @($facts))
}

function Test-EwiInventoriesEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $First,
        [Parameter(Mandatory)] $Second
    )

    if (-not $First.scan_complete -or -not $Second.scan_complete) { return $false }
    return (Get-EwiInventoryDigest $First) -eq (Get-EwiInventoryDigest $Second)
}

function Copy-EwiSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $MappingId
    )

    $sourcePath = Resolve-EwiPath -Path $Source
    $destinationPath = Resolve-EwiPath -Path $Destination -AllowMissing
    Assert-EwiPathsSeparated -First $sourcePath -Second $destinationPath -FirstLabel 'source' -SecondLabel 'destination' -AllowMissing
    if (-not (Test-Path -LiteralPath $destinationPath)) {
        $null = New-Item -ItemType Directory -Path $destinationPath
    }
    $before = Get-EwiFileInventory -Root $sourcePath -MappingId $MappingId
    if (-not $before.scan_complete -or $before.git_topology.Count -gt 0) {
        throw "Source scan is incomplete; links or unreadable paths must be resolved: $sourcePath"
    }
    if ($before.sensitive.Count -gt 0 -or $before.pending.Count -gt 0) {
        throw "Sensitive or ambiguous-license files require explicit resolution before import: $([string]::Join(', ', @($before.sensitive) + @($before.pending)))"
    }

    $existingDestination = Get-EwiFileInventory -Root $destinationPath -MappingId $MappingId
    if (-not $existingDestination.scan_complete -or $existingDestination.git_topology.Count -gt 0 -or $existingDestination.sensitive.Count -gt 0 -or $existingDestination.pending.Count -gt 0) {
        throw "Existing destination is incomplete or contains unresolved sensitive files: $destinationPath"
    }
    $sourceByPath = @{}
    foreach ($entry in $before.files) { $sourceByPath[$entry.path.ToLowerInvariant()] = $entry }
    foreach ($entry in $existingDestination.files) {
        $key = $entry.path.ToLowerInvariant()
        if (-not $sourceByPath.ContainsKey($key) -or $sourceByPath[$key].sha256 -ne $entry.sha256) {
            throw "Existing destination content is not an exact partial snapshot: $($entry.path)"
        }
    }

    foreach ($entry in $before.files) {
        $sourceFile = Join-EwiContainedPath -Root $sourcePath -RelativePath $entry.path
        $destinationFile = Join-EwiContainedPath -Root $destinationPath -RelativePath $entry.path
        $destinationParent = Split-Path -Parent $destinationFile
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            $null = New-Item -ItemType Directory -Path $destinationParent
        }
        [IO.File]::Copy($sourceFile, $destinationFile, $true)
        if ((Get-EwiSha256 $destinationFile) -ne $entry.sha256) {
            throw "Copied file hash mismatch: $($entry.path)"
        }
    }

    $after = Get-EwiFileInventory -Root $sourcePath -MappingId $MappingId
    if (-not (Test-EwiInventoriesEqual -First $before -Second $after)) {
        throw "Source changed during copy; destination cannot become a baseline: $sourcePath"
    }
    return $before
}

function Assert-EwiActiveWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceRoot,
        [switch] $AllowInitializing
    )

    $root = Resolve-EwiPath -Path $WorkspaceRoot
    $configRoot = Join-Path $root 'workspace-management/config'
    $schemaRoot = Join-Path $root 'workspace-management/schemas'
    $workspace = Read-EwiJson -Path (Join-Path $configRoot 'workspace.json') -SchemaPath (Join-Path $schemaRoot 'workspace.schema.json')
    $local = Read-EwiJson -Path (Join-Path $configRoot 'targets.local.json') -SchemaPath (Join-Path $schemaRoot 'targets-local.schema.json')
    if ($workspace.layout_mode -ne 'pure' -or $workspace.managed_root -ne '.') {
        throw 'Only a pure workspace with managed_root "." is supported.'
    }
    if (-not $AllowInitializing -and $workspace.workspace_state -ne 'active') {
        throw "Workspace is not active: $($workspace.workspace_state)"
    }
    if ($AllowInitializing -and $workspace.workspace_state -notin @('active', 'initializing')) {
        throw "Unsupported workspace state: $($workspace.workspace_state)"
    }
    if ((Get-EwiPathIdentity $root) -ne (Get-EwiPathIdentity $local.workspace.root_path)) {
        throw "Current root does not match targets.local.json: $root"
    }
    if ($local.workspace.execution_environment -ne 'local') {
        throw "Workspace execution environment must be local: $($local.workspace.execution_environment)"
    }
    $gitMarker = Join-Path $root '.git'
    if (-not (Test-Path -LiteralPath $gitMarker -PathType Container)) {
        throw 'Managed root must own a .git directory; Codex/external worktree roots are not supported.'
    }
    if ((Get-EwiPathIdentity (Get-EwiGitRoot $root)) -ne (Get-EwiPathIdentity $root)) {
        throw 'Agent-management Git root does not match the registered workspace root.'
    }
    if (Test-Path -LiteralPath (Join-Path $root '.worktreeinclude')) {
        throw '.worktreeinclude is forbidden for the pure managed root.'
    }
    return [pscustomobject][ordered]@{
        root = $root
        workspace = $workspace
        local = $local
    }
}

function Write-EwiEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceRoot,
        [Parameter(Mandatory)] [string] $EvidenceId,
        [Parameter(Mandatory)] [string] $Kind,
        [Parameter(Mandatory)] $Subject,
        [Parameter(Mandatory)] $Result,
        [AllowEmptyCollection()] [object[]] $Artifacts = @()
    )

    $root = Resolve-EwiPath -Path $WorkspaceRoot
    $path = Join-Path $root "workspace-management/evidence/$EvidenceId.json"
    $schema = Join-Path $root 'workspace-management/schemas/evidence.schema.json'
    $evidence = [pscustomobject][ordered]@{
        schema = 1
        evidence_id = $EvidenceId
        kind = $Kind
        captured_at = Get-EwiTimestamp
        subject = $Subject
        result = $Result
        artifacts = @($Artifacts)
        runtime = [pscustomobject][ordered]@{
            powershell_path = (Get-Process -Id $PID).Path
            powershell_version = $PSVersionTable.PSVersion.ToString()
            schema_validator = 'Microsoft.PowerShell.Utility/Test-Json'
        }
    }
    Write-EwiJsonAtomic -Path $path -Value $evidence -SchemaPath $schema
    return $path
}

Export-ModuleMember -Function @(
    'Get-EwiTimestamp',
    'New-EwiEvidenceId',
    'ConvertTo-EwiId',
    'Resolve-EwiPath',
    'Get-EwiPathIdentity',
    'Test-EwiPathWithin',
    'Assert-EwiPathsSeparated',
    'Assert-EwiRelativePath',
    'Join-EwiContainedPath',
    'Get-EwiSha256',
    'Get-EwiTextSha256',
    'ConvertTo-EwiCanonicalJson',
    'Test-EwiJsonEquivalent',
    'Read-EwiJson',
    'Write-EwiJsonAtomic',
    'Write-EwiJsonLinesAtomic',
    'Get-EwiMutexName',
    'Invoke-EwiLocked',
    'Invoke-EwiProcess',
    'Get-EwiGitRoot',
    'Invoke-EwiGit',
    'Initialize-EwiGitRepository',
    'Add-EwiGitPaths',
    'New-EwiGitCommit',
    'Get-EwiFileInventory',
    'Get-EwiSensitiveClassification',
    'Test-EwiAmbiguousLicenseFile',
    'Get-EwiInventoryDigest',
    'Get-EwiMappingDigest',
    'Test-EwiInventoriesEqual',
    'Copy-EwiSnapshot',
    'Assert-EwiActiveWorkspace',
    'Write-EwiEvidence'
)
