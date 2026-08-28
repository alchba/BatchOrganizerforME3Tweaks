param(
    [string]$ModsRoot = '',
    [string]$StorageRoot = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$script:DefaultStageNames = [ordered]@{
    '0' = 'Creation Mods List'
    '1' = 'Base Mods'
    '2' = 'Systems & Shared Foundations'
    '3' = 'Gameplay & QoL'
    '4' = 'World, Missions & Expanded Content'
    '5' = 'Characters & Romances'
    '6' = 'Armors, Outfits & Appearance'
    '7' = 'Late Installers & Compatibility'
}
$script:StageNames = [ordered]@{}
$script:ManagedQueueFiles = @{}
$script:State = $null
$script:StorageRoot = if ([string]::IsNullOrWhiteSpace($StorageRoot)) { $PSScriptRoot } else { [System.IO.Path]::GetFullPath($StorageRoot) }
$script:SettingsPath = Join-Path $script:StorageRoot 'OrganizerSettings.json'
$script:QueueRegistryPath = Join-Path $script:StorageRoot 'OrganizerQueues.json'
$script:SetRegistryPath = Join-Path $script:StorageRoot 'OrganizerSets.json'
$script:RemovedMissingModsPath = Join-Path $script:StorageRoot 'OrganizerRemovedMissingMods.json'
$script:QueueRegistry = if (Test-Path -LiteralPath $script:QueueRegistryPath) {
    try { @(Get-Content -LiteralPath $script:QueueRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { @() }
} else { @() }
$loadedSetRegistry = if (Test-Path -LiteralPath $script:SetRegistryPath) {
    try { @(Get-Content -LiteralPath $script:SetRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { @() }
} else { @() }
$activeSetIdFromLegacyRegistry = @($loadedSetRegistry | Where-Object { $_.Active -eq $true } | Select-Object -First 1 | ForEach-Object { [string]$_.Id })
$activeSetIdFromLegacyRegistry = if ($activeSetIdFromLegacyRegistry.Count) { $activeSetIdFromLegacyRegistry[0] } else { 'default' }
$globalSetsById = [ordered]@{}
$canonicalSetIdByName = @{}
$canonicalSetIdByLegacyId = @{}
$setCandidates = @($loadedSetRegistry)
$setCandidates += @($script:QueueRegistry | Where-Object { [int]$_.Order -gt 0 } | ForEach-Object {
    [pscustomobject]@{ Id = $(if ($_.SetId) { [string]$_.SetId } else { 'default' }); Name = $(if ($_.SetName) { [string]$_.SetName } else { 'Default' }) }
})
foreach ($set in $setCandidates) {
    $legacyId = [string]$set.Id
    if ([string]::IsNullOrWhiteSpace($legacyId) -or $legacyId -eq 'creation') { continue }
    $name = if ([string]::IsNullOrWhiteSpace([string]$set.Name)) { $(if ($legacyId -eq 'default') { 'Default' } else { $legacyId }) } else { ([string]$set.Name).Trim() }
    $nameKey = $name.ToLowerInvariant()
    if ($legacyId -eq 'default') {
        $canonicalId = 'default'
        $canonicalSetIdByName[$nameKey] = $canonicalId
    } elseif ($canonicalSetIdByName.ContainsKey($nameKey)) {
        $canonicalId = [string]$canonicalSetIdByName[$nameKey]
    } else {
        $canonicalId = $legacyId
        $canonicalSetIdByName[$nameKey] = $canonicalId
    }
    $canonicalSetIdByLegacyId[$legacyId] = $canonicalId
    if (-not $globalSetsById.Contains($canonicalId)) {
        $globalSetsById[$canonicalId] = [pscustomobject][ordered]@{ Id = $canonicalId; Name = $name; Active = $false }
    }
}
if (-not $globalSetsById.Contains('default')) { $globalSetsById['default'] = [pscustomobject][ordered]@{ Id = 'default'; Name = 'Default'; Active = $false } }
foreach ($queue in @($script:QueueRegistry | Where-Object { [int]$_.Order -gt 0 })) {
    $legacyId = if ($queue.SetId) { [string]$queue.SetId } else { 'default' }
    if ($canonicalSetIdByLegacyId.ContainsKey($legacyId)) {
        $queue.SetId = [string]$canonicalSetIdByLegacyId[$legacyId]
        $queue.SetName = [string]$globalSetsById[$queue.SetId].Name
    }
}
if ($canonicalSetIdByLegacyId.ContainsKey($activeSetIdFromLegacyRegistry)) { $activeSetIdFromLegacyRegistry = [string]$canonicalSetIdByLegacyId[$activeSetIdFromLegacyRegistry] }
if (-not $globalSetsById.Contains($activeSetIdFromLegacyRegistry)) { $activeSetIdFromLegacyRegistry = 'default' }
foreach ($set in $globalSetsById.Values) { $set.Active = $set.Id -eq $activeSetIdFromLegacyRegistry }
$script:SetRegistry = @($globalSetsById.Values)
$script:RemovedMissingMods = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $script:RemovedMissingModsPath) {
    try { foreach ($entry in @(Get-Content -LiteralPath $script:RemovedMissingModsPath -Raw -Encoding UTF8 | ConvertFrom-Json)) { [void]$script:RemovedMissingMods.Add([string]$entry) } } catch { }
}
$script:DeclinedDefaultGames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:UpdatingCreationToggle = $false
$script:UpdatingSetBox = $false
$script:UpdatingActiveSetBox = $false
$script:UpdatingRestoreToggle = $false
$script:UpdatingAsiChecks = $false
$script:UpdatingAsiMode = $false
$script:WindowSettings = if (Test-Path -LiteralPath $script:SettingsPath) {
    try { Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
} else { $null }
$script:ModManagerRoot = $null
$script:QueueRoot = $null
$script:InactiveQueueRoot = $null

function Save-QueueRegistry {
    $ordered = @($script:QueueRegistry | Sort-Object Game, SetId, Order)
    [System.IO.File]::WriteAllText($script:QueueRegistryPath, (($ordered | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Save-SetRegistry {
    $ordered = @($script:SetRegistry | Sort-Object @{ Expression = { if ($_.Id -eq 'default') { 0 } else { 1 } } }, Name)
    [System.IO.File]::WriteAllText($script:SetRegistryPath, (($ordered | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Set-SetRegistryEntry {
    param([string]$SetId, [string]$Name)
    $existing = @($script:SetRegistry | Where-Object { $_.Id -eq $SetId } | Select-Object -First 1)
    $active = $existing.Count -and $existing[0].Active -eq $true
    $script:SetRegistry = @($script:SetRegistry | Where-Object { $_.Id -ne $SetId })
    $script:SetRegistry += [pscustomobject][ordered]@{ Id = $SetId; Name = $Name; Active = $active }
}

function Get-OrganizerSets {
    $sets = @($script:SetRegistry)
    if (-not @($sets | Where-Object { $_.Id -eq 'default' }).Count) {
        $sets += [pscustomobject][ordered]@{ Id = 'default'; Name = 'Default'; Active = $false }
    }
    return @($sets | Sort-Object @{ Expression = { if ($_.Id -eq 'default') { 0 } else { 1 } } }, Name)
}

function Get-ActiveSetId {
    $active = @(Get-OrganizerSets | Where-Object { $_.Active -eq $true } | Select-Object -First 1)
    return $(if ($active.Count) { [string]$active[0].Id } else { 'default' })
}

function Set-ActiveSetRegistryEntry {
    param([string]$SetId)
    foreach ($set in @($script:SetRegistry)) { $set.Active = $set.Id -eq $SetId }
    if (-not @($script:SetRegistry | Where-Object { $_.Id -eq $SetId }).Count) {
        Set-SetRegistryEntry -SetId $SetId -Name $SetId
        @($script:SetRegistry | Where-Object { $_.Id -eq $SetId })[0].Active = $true
    }
    Save-SetRegistry
}

function Save-RemovedMissingMods {
    $entries = @($script:RemovedMissingMods | Sort-Object)
    [System.IO.File]::WriteAllText($script:RemovedMissingModsPath, (($entries | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Set-QueueRegistryEntry {
    param([string]$Game, [string]$SetId = 'default', [string]$SetName = 'Default', [int]$Order, [string]$Name, [string]$QueueName, [string]$FileName)
    $effectiveSetId = if ($Order -eq 0) { 'creation' } else { $SetId }
    $effectiveSetName = if ($Order -eq 0) { 'Creation List' } else { $SetName }
    $script:QueueRegistry = @($script:QueueRegistry | Where-Object {
        $sameLegacyEntry = $_.Game -eq $Game -and -not $_.SetId -and [int]$_.Order -eq $Order -and ($effectiveSetId -eq 'default' -or $effectiveSetId -eq 'creation')
        -not ($sameLegacyEntry -or ($_.Game -eq $Game -and $_.SetId -eq $effectiveSetId -and [int]$_.Order -eq $Order))
    })
    $script:QueueRegistry += [pscustomobject][ordered]@{ Game = $Game; SetId = $effectiveSetId; SetName = $effectiveSetName; Order = $Order; Name = $Name; QueueName = $QueueName; FileName = $FileName }
}

function Remove-QueueRegistryEntry {
    param([string]$Game, [string]$SetId = 'default', [int]$Order)
    $effectiveSetId = if ($Order -eq 0) { 'creation' } else { $SetId }
    $script:QueueRegistry = @($script:QueueRegistry | Where-Object { -not ($_.Game -eq $Game -and $_.SetId -eq $effectiveSetId -and [int]$_.Order -eq $Order) })
    Save-QueueRegistry
}

function Test-ModManagerRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'ME3TweaksModManager.exe')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'data') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Path 'mods') -PathType Container)
}

function Set-ModManagerRoot {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Test-ModManagerRoot $resolved)) { throw "The selected folder is not a valid ME3Tweaks Mod Manager folder: $resolved" }
    $script:ModManagerRoot = $resolved
    $script:ModsRoot = Join-Path $resolved 'mods'
    $script:QueueRoot = Join-Path $script:ModsRoot 'BatchModQueues'
    $script:InactiveQueueRoot = Join-Path $script:QueueRoot 'OrganizerQueueSets'
    Set-Variable -Name ModsRoot -Scope Script -Value $script:ModsRoot
}

if (-not [string]::IsNullOrWhiteSpace($ModsRoot)) {
    $candidate = $ModsRoot
    if ((Split-Path $candidate -Leaf) -ieq 'ME3TweaksModManager.exe') { $candidate = Split-Path $candidate -Parent }
    elseif ((Split-Path $candidate -Leaf) -ieq 'mods') { $candidate = Split-Path $candidate -Parent }
    Set-ModManagerRoot $candidate
} elseif ($script:WindowSettings -and (Test-ModManagerRoot ([string]$script:WindowSettings.ModManagerRoot))) {
    Set-ModManagerRoot ([string]$script:WindowSettings.ModManagerRoot)
}

function Get-AsiManifestPath {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $cacheRoot = Join-Path $localAppData 'ME3Tweaks\CachedASIs'
    foreach ($name in @('manifest.xml', 'manifest_staged.xml')) {
        $candidate = Join-Path $cacheRoot $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-AsiCatalog {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game)

    $manifestPath = Get-AsiManifestPath
    if (-not $manifestPath) { return @() }
    try { [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 } catch { return @() }
    $manifestGame = @{ LE1 = 4; LE2 = 5; LE3 = 6 }[$Game]
    $result = [System.Collections.Generic.List[object]]::new()
    $referenceOrder = 0
    foreach ($group in @($manifest.ASIManifest.updategroup | Where-Object { [int]$_.game -eq $manifestGame } | Sort-Object { [int]$_.groupid })) {
        $latest = @($group.asimod | Sort-Object { [int]$_.version } -Descending | Select-Object -First 1)
        if (-not $latest.Count -or [string]$latest[0].hidden -eq '1') { continue }
        $plugin = $latest[0]
        $description = [System.Net.WebUtility]::HtmlDecode([string]$plugin.description)
        $description = [regex]::Replace($description, '(?i)<br\s*/?>', "`r`n")
        $description = [regex]::Replace($description, '<[^>]+>', '').Trim()
        $result.Add([pscustomobject]@{
            Key = [string]$group.groupid
            Game = $Game
            UpdateGroup = [int]$group.groupid
            CatalogVersion = [int]$plugin.version
            Name = [string]$plugin.name
            InstalledName = [string]$plugin.installedname
            Author = [string]$plugin.author
            Description = $description
            DeveloperOnly = [string]$plugin.devsonly -eq '1'
            SourceCode = [string]$plugin.sourcecode
            ReferenceOrder = $referenceOrder
            Memberships = [System.Collections.Generic.List[int]]::new()
            VersionsByStage = @{}
            Status = 'Unassigned'
        })
        $referenceOrder++
    }
    return @($result)
}

function Update-AsiRecordStatus {
    param($Record)
    if ($Record.Memberships.Count -eq 0) { $Record.Status = 'Unassigned'; return }
    $versions = @($Record.Memberships | ForEach-Object { if ($Record.VersionsByStage.ContainsKey([int]$_)) { [int]$Record.VersionsByStage[[int]$_] } } | Sort-Object -Unique)
    if ($Record.CatalogVersion -le 0) { $Record.Status = 'Metadata unavailable'; return }
    $outdated = @($versions | Where-Object { $_ -ne [int]$Record.CatalogVersion })
    if ($outdated.Count) {
        $Record.Status = "Catalog v$($Record.CatalogVersion); assigned version(s): $($versions -join ', ')"
    } else {
        $Record.Status = 'OK'
    }
}

function Set-AsiRecordQueueMembership {
    param($Record, [int]$Stage, [bool]$Include, [bool]$UseCatalogVersion = $false)
    if ($Include) {
        if (-not $Record.Memberships.Contains($Stage)) { $Record.Memberships.Add($Stage) }
        if (($UseCatalogVersion -or -not $Record.VersionsByStage.ContainsKey($Stage)) -and $Record.CatalogVersion -gt 0) {
            $Record.VersionsByStage[$Stage] = [int]$Record.CatalogVersion
        }
    } else {
        [void]$Record.Memberships.Remove($Stage)
    }
    Update-AsiRecordStatus -Record $Record
}

function Initialize-ManagedQueues {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game, [string]$SetId = 'default')

    $script:StageNames = [ordered]@{}
    $script:ManagedQueueFiles = @{}
    $registryChanged = $false
    $setRegistryChanged = $false
    $queueFiles = @(Get-ChildItem -LiteralPath $script:QueueRoot -Filter '*.biq2' -File)
    if (Test-Path -LiteralPath $script:InactiveQueueRoot) { $queueFiles += @(Get-ChildItem -LiteralPath $script:InactiveQueueRoot -Filter '*.biq2' -File -Recurse) }
    foreach ($file in $queueFiles) {
        try { $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($data.game -ne $Game) { continue }
        $queueName = [string]$data.queuename
        $registryEntry = @($script:QueueRegistry | Where-Object { $_.Game -eq $Game -and ($_.QueueName -eq $queueName -or $_.FileName -eq $file.Name) } | Select-Object -First 1)
        $recoverableOrganizerQueue = $queueName -match "^$([regex]::Escape($Game))\.(\d+) - (.+)$"
        $recoveredOrder = if ($recoverableOrganizerQueue) { [int]$matches[1] } else { -1 }
        $recoveredName = if ($recoverableOrganizerQueue) { [string]$matches[2] } else { '' }
        if ($data.organizerManaged -ne $true -and $registryEntry.Count -eq 0 -and -not $recoverableOrganizerQueue) { continue }
        $order = if ($registryEntry.Count) { [int]$registryEntry[0].Order } elseif ($data.organizerManaged -eq $true -and $null -ne $data.organizerOrder) { [int]$data.organizerOrder } else { $recoveredOrder }
        $name = if ($registryEntry.Count) { [string]$registryEntry[0].Name } elseif ($data.organizerName) { [string]$data.organizerName } elseif ($recoverableOrganizerQueue) { $recoveredName } else { ($queueName -replace "^$Game\.$order - ", '') }
        $queueSetId = if ($order -eq 0) { 'creation' } elseif ($registryEntry.Count -and $registryEntry[0].SetId) { [string]$registryEntry[0].SetId } elseif ($data.organizerSetId) { [string]$data.organizerSetId } else { 'default' }
        $queueSetName = if ($order -eq 0) { 'Creation List' } elseif ($registryEntry.Count -and $registryEntry[0].SetName) { [string]$registryEntry[0].SetName } elseif ($data.organizerSetName) { [string]$data.organizerSetName } elseif ($queueSetId -eq 'default') { 'Default' } else { $queueSetId }
        $data | Add-Member -NotePropertyName organizerManaged -NotePropertyValue $true -Force
        $data | Add-Member -NotePropertyName organizerOrder -NotePropertyValue $order -Force
        $data | Add-Member -NotePropertyName organizerName -NotePropertyValue $name -Force
        $data | Add-Member -NotePropertyName organizerRole -NotePropertyValue $(if ($order -eq 0) { 'Creation' } else { 'Assignment' }) -Force
        $data | Add-Member -NotePropertyName organizerSetId -NotePropertyValue $queueSetId -Force
        $data | Add-Member -NotePropertyName organizerSetName -NotePropertyValue $queueSetName -Force
        if ($order -gt 0) { Set-SetRegistryEntry -SetId $queueSetId -Name $queueSetName; $setRegistryChanged = $true }
        if ($order -gt 0 -and $queueSetId -ne $SetId) {
            Set-QueueRegistryEntry -Game $Game -SetId $queueSetId -SetName $queueSetName -Order $order -Name $name -QueueName $queueName -FileName $file.Name
            $registryChanged = $true
            continue
        }
        $script:StageNames[[string]$order] = $name
        $script:ManagedQueueFiles[$order] = $file.FullName
        Set-QueueRegistryEntry -Game $Game -SetId $queueSetId -SetName $queueSetName -Order $order -Name $name -QueueName $queueName -FileName $file.Name
        $registryChanged = $true
    }
    if (-not @($script:SetRegistry | Where-Object { $_.Id -eq 'default' }).Count) { Set-SetRegistryEntry -SetId 'default' -Name 'Default'; $setRegistryChanged = $true }
    if ($registryChanged) { Save-QueueRegistry }
    if ($setRegistryChanged) { Save-SetRegistry }
}

function Set-ActiveOrganizerSet {
    param([string]$SetId)
    [void](New-Item -ItemType Directory -Path $script:InactiveQueueRoot -Force)
    foreach ($game in @('LE1', 'LE2', 'LE3')) {
        $gameStore = Join-Path $script:InactiveQueueRoot $game
        [void](New-Item -ItemType Directory -Path $gameStore -Force)
        $entries = @($script:QueueRegistry | Where-Object { $_.Game -eq $game -and [int]$_.Order -gt 0 })
        foreach ($entry in $entries) {
            $entrySetId = if ($entry.SetId) { [string]$entry.SetId } else { 'default' }
            $targetDirectory = if ($entrySetId -eq $SetId) { $script:QueueRoot } else { Join-Path $gameStore $entrySetId }
            [void](New-Item -ItemType Directory -Path $targetDirectory -Force)
            $destination = Join-Path $targetDirectory ([string]$entry.FileName)
            $candidates = @()
            $topCandidate = Join-Path $script:QueueRoot ([string]$entry.FileName)
            if (Test-Path -LiteralPath $topCandidate) { $candidates += Get-Item -LiteralPath $topCandidate }
            if (Test-Path -LiteralPath $script:InactiveQueueRoot) {
                $candidates += @(Get-ChildItem -LiteralPath $script:InactiveQueueRoot -Filter ([string]$entry.FileName) -File -Recurse)
            }
            $source = @($candidates | Where-Object { $_.FullName -ne $destination } | Select-Object -First 1)
            if ($source.Count) {
                if (Test-Path -LiteralPath $destination) { throw "Cannot activate set because the destination already exists: $destination" }
                Move-Item -LiteralPath $source[0].FullName -Destination $destination
            }
        }
    }
    Set-ActiveSetRegistryEntry -SetId $SetId
}

function Get-ModFacts {
    param([string]$RelativePath)

    $path = Join-Path $ModsRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Exists = $false; Provided = @(); Required = @(); Conditional = @(); Incompatible = @(); Description = ''; MountIds = @() }
    }

    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $provided = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [regex]::Matches($text, '(?im)^\s*(?:source|dest)dirs\s*=\s*(.+)$')) {
        foreach ($match in [regex]::Matches($line.Groups[1].Value, '(?i)DLC_[A-Z0-9_]+')) {
            [void]$provided.Add($match.Value)
        }
    }
    foreach ($match in [regex]::Matches($text, '(?i)ModOperation\s*=\s*OP_ADD_CUSTOMDLC.{0,300}?ModDestDLC\s*=\s*(DLC_[A-Z0-9_]+)')) {
        [void]$provided.Add($match.Groups[1].Value)
    }
    $required = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [regex]::Matches($text, '(?im)^\s*requireddlc\s*=\s*(.+)$')) {
        foreach ($match in [regex]::Matches($line.Groups[1].Value, '(?i)DLC_MOD_[A-Z0-9_]+')) {
            [void]$required.Add($match.Value)
        }
    }
    $conditional = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($text, '(?i)(?:DLCRequirements|ConditionalDLC)\s*=\s*[+\-]?\s*(DLC_MOD_[A-Z0-9_]+)')) {
        [void]$conditional.Add($match.Groups[1].Value)
    }
    $incompatible = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [regex]::Matches($text, '(?im)^\s*incompatiblecustomdlc\s*=\s*(.+)$')) {
        foreach ($match in [regex]::Matches($line.Groups[1].Value, '(?i)DLC_MOD_[A-Z0-9_]+')) {
            [void]$incompatible.Add($match.Value)
        }
    }
    $description = if ($text -match '(?im)^\s*moddesc\s*=\s*(.+)$') { $matches[1].Trim() } else { '' }
    $description = [regex]::Replace($description, '(?i)<br\s*/?>', "`r`n")
    $description = [regex]::Replace($description, '<[^>]+>', '')
    $description = [System.Net.WebUtility]::HtmlDecode($description).Trim()
    $mountIds = [System.Collections.Generic.HashSet[int]]::new()
    $modRoot = Split-Path $path -Parent
    if ($RelativePath -like 'LE1\*') {
        foreach ($autoLoad in Get-ChildItem -LiteralPath $modRoot -Filter 'AutoLoad.ini' -Recurse -ErrorAction SilentlyContinue) {
            $autoText = Get-Content -LiteralPath $autoLoad.FullName -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($autoText, '(?im)^\s*ModMount\s*=\s*(\d+)')) { [void]$mountIds.Add([int]$match.Groups[1].Value) }
        }
    } else {
        $offset = if ($RelativePath -like 'LE2\*') { 12 } else { 16 }
        foreach ($mountFile in Get-ChildItem -LiteralPath $modRoot -Filter 'Mount.dlc' -Recurse -ErrorAction SilentlyContinue) {
            $bytes = [System.IO.File]::ReadAllBytes($mountFile.FullName)
            if ($bytes.Length -ge ($offset + 4)) {
                $mount = [BitConverter]::ToInt32($bytes, $offset)
                if ($mount -gt 0 -and $mount -lt 1000000) { [void]$mountIds.Add($mount) }
            }
        }
    }
    [pscustomobject]@{
        Exists = $true
        Provided = @($provided | Sort-Object)
        Required = @($required | Sort-Object)
        Conditional = @($conditional | Sort-Object)
        Incompatible = @($incompatible | Sort-Object)
        Description = $description
        MountIds = @($mountIds | Sort-Object)
    }
}

function Get-GameState {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game, [string]$SetId = 'default')

    Initialize-ManagedQueues -Game $Game -SetId $SetId
    $setInfo = @(Get-OrganizerSets | Where-Object { $_.Id -eq $SetId } | Select-Object -First 1)
    $setName = if ($setInfo.Count) { [string]$setInfo[0].Name } elseif ($SetId -eq 'default') { 'Default' } else { $SetId }
    $queues = @{}
    foreach ($stage in $script:StageNames.Keys) {
        $path = $script:ManagedQueueFiles[[int]$stage]
        if (-not (Test-Path -LiteralPath $path)) { throw "Working queue not found: $path" }
        $queueData = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $queueData | Add-Member -NotePropertyName organizerManaged -NotePropertyValue $true -Force
        $queueData | Add-Member -NotePropertyName organizerOrder -NotePropertyValue ([int]$stage) -Force
        $queueData | Add-Member -NotePropertyName organizerName -NotePropertyValue ([string]$script:StageNames[[string]$stage]) -Force
        $queueData | Add-Member -NotePropertyName organizerRole -NotePropertyValue $(if ([int]$stage -eq 0) { 'Creation' } else { 'Assignment' }) -Force
        $queueData | Add-Member -NotePropertyName organizerSetId -NotePropertyValue $(if ([int]$stage -eq 0) { 'creation' } else { $SetId }) -Force
        $queueData | Add-Member -NotePropertyName organizerSetName -NotePropertyValue $(if ([int]$stage -eq 0) { 'Creation List' } else { $setName }) -Force
        $queues[$stage] = [pscustomobject]@{
            Path = $path
            Data = $queueData
        }
    }

    $records = @{}
    $order = 0
    foreach ($stage in $script:StageNames.Keys) {
        $queueEntries = @($queues[$stage].Data.mods)
        for ($queueIndex = 0; $queueIndex -lt $queueEntries.Count; $queueIndex++) {
            $entry = $queueEntries[$queueIndex]
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.moddescpath)) { continue }
            $key = $entry.moddescpath.ToLowerInvariant()
            if (-not $records.ContainsKey($key)) {
                $records[$key] = [pscustomobject]@{
                    Key = $key; Name = $entry.modname; Path = $entry.moddescpath; SourceEntry = $entry
                    ReferenceOrder = $order; Facts = $null; InCreation = $false
                    Memberships = [System.Collections.Generic.List[int]]::new(); CurrentEntries = @{}; QueueOrders = @{}
                    Target = $null; Status = ''
                }
                $order++
            }
            if ([int]$stage -eq 0) {
                $records[$key].InCreation = $true
            } else {
                $records[$key].Memberships.Add([int]$stage)
            }
            $records[$key].CurrentEntries[[int]$stage] = $entry
            $records[$key].QueueOrders[[int]$stage] = $queueIndex
        }
    }

    $gameModRoot = Join-Path $ModsRoot $Game
    foreach ($directory in Get-ChildItem -LiteralPath $gameModRoot -Directory | Sort-Object Name) {
        $modDescFile = Join-Path $directory.FullName 'moddesc.ini'
        if (-not (Test-Path -LiteralPath $modDescFile)) { continue }
        $relativePath = "$Game\$($directory.Name)\moddesc.ini"
        $key = $relativePath.ToLowerInvariant()
        if ($records.ContainsKey($key)) { continue }
        $text = Get-Content -LiteralPath $modDescFile -Raw -Encoding UTF8
        $modName = if ($text -match '(?im)^\s*modname\s*=\s*(.+)$') { $matches[1].Trim() } else { $directory.Name }
        $hash = (Get-FileHash -LiteralPath $modDescFile -Algorithm MD5).Hash.ToLowerInvariant()
        $fileInfo = Get-Item -LiteralPath $modDescFile
        $entry = [pscustomobject][ordered]@{
            moddescpath = $relativePath
            configurationtime = '0001-01-01T00:00:00'
            moddeschash = $hash
            moddescsize = $fileInfo.Length
            downloadlink = $null
            userchosenoptions = $null
            allchosenoptions = $null
            haschosenoptions = $false
            IsStandalone = $false
            modname = $modName
        }
        $records[$key] = [pscustomobject]@{
            Key = $key; Name = $modName; Path = $relativePath; SourceEntry = $entry
            ReferenceOrder = $order; Facts = $null; InCreation = $false; DiscoveredFromFolder = $true
            Memberships = [System.Collections.Generic.List[int]]::new(); CurrentEntries = @{}; QueueOrders = @{}
            Target = $null; Status = ''
        }
        $order++
    }

    $removedMissingChanged = $false
    foreach ($record in @($records.Values)) {
        $record | Add-Member -NotePropertyName Game -NotePropertyValue $Game -Force
        $record.Facts = Get-ModFacts -RelativePath $record.Path
        if ($record.Memberships.Count -eq 1) { $record.Target = $record.Memberships[0] }
        $removedKey = "$Game|$($record.Key)"
        if ($record.Facts.Exists -and $script:RemovedMissingMods.Remove($removedKey)) { $removedMissingChanged = $true }
        elseif (-not $record.Facts.Exists -and $script:RemovedMissingMods.Contains($removedKey)) { [void]$records.Remove($record.Key) }
    }
    if ($removedMissingChanged) { Save-RemovedMissingMods }

    $asiRecords = @{}
    foreach ($catalogEntry in @(Get-AsiCatalog -Game $Game)) { $asiRecords[$catalogEntry.Key] = $catalogEntry }
    $asiReferenceOrder = $asiRecords.Count
    foreach ($stage in $script:StageNames.Keys) {
        foreach ($entry in @($queues[$stage].Data.asimods)) {
            if ($null -eq $entry -or $null -eq $entry.updategroup -or [string]::IsNullOrWhiteSpace([string]$entry.updategroup)) { continue }
            $key = [string][int]$entry.updategroup
            if (-not $asiRecords.ContainsKey($key)) {
                $asiRecords[$key] = [pscustomobject]@{
                    Key = $key; Game = $Game; UpdateGroup = [int]$entry.updategroup; CatalogVersion = 0
                    Name = "ASI update group $key"; InstalledName = ''; Author = ''; Description = 'This ASI plugin is present in a queue but was not found in the local ME3Tweaks ASI manifest.'
                    DeveloperOnly = $false; SourceCode = ''; ReferenceOrder = $asiReferenceOrder
                    Memberships = [System.Collections.Generic.List[int]]::new(); VersionsByStage = @{}; Status = ''
                }
                $asiReferenceOrder++
            }
            $record = $asiRecords[$key]
            if (-not $record.Memberships.Contains([int]$stage)) { $record.Memberships.Add([int]$stage) }
            $record.VersionsByStage[[int]$stage] = [int]$entry.version
        }
    }
    foreach ($record in $asiRecords.Values) { Update-AsiRecordStatus -Record $record }

    $stateStageNames = [ordered]@{}
    foreach ($stage in $script:StageNames.Keys) { $stateStageNames[$stage] = $script:StageNames[$stage] }
    $state = [pscustomobject]@{
        Game = $Game
        SetId = $SetId
        SetName = $setName
        StageNames = $stateStageNames
        Queues = $queues
        Records = $records
        AsiRecords = $asiRecords
        Providers = @{}
        Dirty = $false
    }
    Update-StateStatus -State $state
    return $state
}

function Get-AllGameState {
    param([string]$SetId = '')
    if ([string]::IsNullOrWhiteSpace($SetId) -or $SetId -eq 'active') { $SetId = Get-ActiveSetId }
    $gameStates = @{}
    $records = @{}
    $asiRecords = @{}
    foreach ($game in @('LE1', 'LE2', 'LE3')) {
        $gameState = Get-GameState -Game $game -SetId $SetId
        $queuedKeys = Get-AllOrganizerQueuedModKeys -Game $game
        foreach ($record in $gameState.Records.Values) { $record | Add-Member -NotePropertyName AnySetAssigned -NotePropertyValue $queuedKeys.Contains($record.Key) -Force }
        $gameStates[$game] = $gameState
        foreach ($record in $gameState.Records.Values) { $records["$game|$($record.Key)"] = $record }
        foreach ($record in $gameState.AsiRecords.Values) { $asiRecords["$game|$($record.Key)"] = $record }
    }
    $setInfo = @(Get-OrganizerSets | Where-Object { $_.Id -eq $SetId } | Select-Object -First 1)
    $setName = if ($setInfo.Count) { [string]$setInfo[0].Name } elseif ($SetId -eq 'default') { 'Default' } else { $SetId }
    [pscustomobject]@{ Game = 'All'; SetId = $SetId; SetName = $setName; Records = $records; AsiRecords = $asiRecords; GameStates = $gameStates; Dirty = $false }
}

function Get-AllOrganizerQueuedModKeys {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game)
    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($script:QueueRegistry | Where-Object { $_.Game -eq $Game })) {
        $candidatePaths = @(Join-Path $script:QueueRoot ([string]$entry.FileName))
        if (Test-Path -LiteralPath $script:InactiveQueueRoot) { $candidatePaths += @(Get-ChildItem -LiteralPath $script:InactiveQueueRoot -Filter ([string]$entry.FileName) -File -Recurse | ForEach-Object { $_.FullName }) }
        $path = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
        if (-not $path.Count) { continue }
        try { $data = Get-Content -LiteralPath $path[0] -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($mod in @($data.mods)) { if ($mod.moddescpath) { [void]$keys.Add(([string]$mod.moddescpath).ToLowerInvariant()) } }
    }
    return ,$keys
}

function Update-StateStatus {
    param($State)

    $providers = @{}
    foreach ($record in $State.Records.Values) {
        foreach ($dlc in $record.Facts.Provided) {
            if (-not $providers.ContainsKey($dlc)) { $providers[$dlc] = [System.Collections.Generic.List[object]]::new() }
            $providers[$dlc].Add($record)
        }
    }
    $State.Providers = $providers

    $incompatiblePartners = @{}
    foreach ($record in $State.Records.Values) {
        foreach ($dlc in $record.Facts.Incompatible) {
            if (-not $providers.ContainsKey($dlc)) { continue }
            foreach ($candidate in $providers[$dlc]) {
                if ($candidate.Key -eq $record.Key) { continue }
                $togetherInWorkingQueues = $null -ne $record.Target -and $null -ne $candidate.Target
                $togetherInCreation = $record.InCreation -and $candidate.InCreation
                if (-not ($togetherInWorkingQueues -or $togetherInCreation)) { continue }
                if (-not $incompatiblePartners.ContainsKey($record.Key)) {
                    $incompatiblePartners[$record.Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                if (-not $incompatiblePartners.ContainsKey($candidate.Key)) {
                    $incompatiblePartners[$candidate.Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$incompatiblePartners[$record.Key].Add([string]$candidate.Name)
                [void]$incompatiblePartners[$candidate.Key].Add([string]$record.Name)
            }
        }
    }

    foreach ($record in $State.Records.Values) {
        $problems = [System.Collections.Generic.List[string]]::new()
        if (-not $record.Facts.Exists) { $problems.Add('moddesc.ini is missing') }
        if ($record.Memberships.Count -gt 1 -and $null -eq $record.Target) {
            $problems.Add('Present in multiple working queues')
        } elseif ($null -eq $record.Target) {
            $problems.Add('Unassigned')
        }
        if ($incompatiblePartners.ContainsKey($record.Key)) {
            foreach ($partnerName in @($incompatiblePartners[$record.Key] | Sort-Object)) { $problems.Add("Incompatible with: $partnerName") }
        }

        if ($null -ne $record.Target) {
            foreach ($dlc in $record.Facts.Required) {
                $candidates = if ($providers.ContainsKey($dlc)) { @($providers[$dlc] | Where-Object { $_.Key -ne $record.Key }) } else { @() }
                if ($candidates.Count -eq 0) { $problems.Add("Dependency is missing: $dlc"); continue }
                $validProvider = @($candidates | Where-Object {
                    $null -ne $_.Target -and (
                        [int]$_.Target -lt [int]$record.Target -or
                        ([int]$_.Target -eq [int]$record.Target -and (Get-RecordQueueOrder $_) -le (Get-RecordQueueOrder $record))
                    )
                }).Count -gt 0
                if ($validProvider) { continue }
                $assignedCandidates = @($candidates | Where-Object { $null -ne $_.Target } | Sort-Object @{ Expression = { [int]$_.Target } }, @{ Expression = { Get-RecordQueueOrder $_ } }, Name)
                if ($assignedCandidates.Count -eq 0) {
                    $problems.Add("Dependency is unassigned: $($candidates[0].Name)")
                } elseif ([int]$assignedCandidates[0].Target -gt [int]$record.Target) {
                    $problems.Add("Dependency is installed later: $($assignedCandidates[0].Name)")
                } else {
                    $problems.Add("Dependency is ordered later: $($assignedCandidates[0].Name)")
                }
            }

            foreach ($dlc in $record.Facts.Conditional) {
                $patchTargets = if ($providers.ContainsKey($dlc)) { @($providers[$dlc] | Where-Object { $_.Key -ne $record.Key -and $null -ne $_.Target }) } else { @() }
                if ($patchTargets.Count -eq 0) { continue }
                $validTarget = @($patchTargets | Where-Object {
                    [int]$_.Target -lt [int]$record.Target -or
                    ([int]$_.Target -eq [int]$record.Target -and (Get-RecordQueueOrder $_) -le (Get-RecordQueueOrder $record))
                }).Count -gt 0
                if ($validTarget) { continue }
                $earliestTarget = @($patchTargets | Sort-Object @{ Expression = { [int]$_.Target } }, @{ Expression = { Get-RecordQueueOrder $_ } }, Name)[0]
                if ([int]$earliestTarget.Target -gt [int]$record.Target) {
                    $problems.Add("Compatibility target is installed later: $($earliestTarget.Name)")
                } else {
                    $problems.Add("Compatibility target is ordered later: $($earliestTarget.Name)")
                }
            }
        }
        $record.Status = if ($problems.Count) { $problems -join '; ' } else { 'OK' }
    }
}

function Set-RecordTarget {
    param($State, [object[]]$Records, [Nullable[int]]$Target)
    foreach ($record in $Records) {
        $oldTarget = $record.Target
        $record.Target = $Target
        $record.Memberships.Clear()
        if ($null -ne $Target) {
            $record.Memberships.Add([int]$Target)
            if (-not $record.QueueOrders.ContainsKey([int]$Target)) {
                $existingOrders = @($State.Records.Values | Where-Object { $_.Key -ne $record.Key -and $null -ne $_.Target -and [int]$_.Target -eq [int]$Target -and $_.QueueOrders.ContainsKey([int]$Target) } | ForEach-Object { [int]$_.QueueOrders[[int]$Target] })
                $record.QueueOrders[[int]$Target] = if ($existingOrders.Count) { (($existingOrders | Measure-Object -Maximum).Maximum + 1) } else { 0 }
            }
        }
    }
    $State.Dirty = $true
    Update-StateStatus -State $State
}

function Get-RecordQueueOrder {
    param($Record)
    if ($null -ne $Record.Target -and $Record.QueueOrders.ContainsKey([int]$Record.Target)) { return [int]$Record.QueueOrders[[int]$Record.Target] }
    return [int]::MaxValue
}

function Get-RecordCreationOrder {
    param($Record)
    if ($Record.InCreation -and $Record.QueueOrders.ContainsKey(0)) { return [int]$Record.QueueOrders[0] }
    return [int]::MaxValue
}

function Save-GameState {
    param($State)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $script:QueueRoot "OrganizerBackups\$stamp-$($State.Game)-$($State.SetId)"
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)

    foreach ($stage in @($State.StageNames.Keys | Sort-Object { [int]$_ })) {
        $queueInfo = $State.Queues[$stage]
        Copy-Item -LiteralPath $queueInfo.Path -Destination (Join-Path $backupRoot (Split-Path $queueInfo.Path -Leaf))
        $newMods = [System.Collections.Generic.List[object]]::new()
        $selected = if ([int]$stage -eq 0) {
            @($State.Records.Values | Where-Object { $_.InCreation } | Sort-Object @{ Expression = { if ($_.QueueOrders.ContainsKey(0)) { [int]$_.QueueOrders[0] } else { [int]::MaxValue } } }, ReferenceOrder, Name)
        } else {
            @($State.Records.Values | Where-Object { $null -ne $_.Target -and [int]$_.Target -eq [int]$stage } | Sort-Object @{ Expression = { Get-RecordQueueOrder $_ } }, ReferenceOrder, Name)
        }
        foreach ($record in $selected) {
            $entry = if ($record.CurrentEntries.ContainsKey([int]$stage)) {
                $record.CurrentEntries[[int]$stage]
            } else {
                $record.SourceEntry
            }
            $newMods.Add($entry)
        }
        $queueInfo.Data.mods = $newMods
        $newAsiMods = [System.Collections.Generic.List[object]]::new()
        $selectedAsi = @($State.AsiRecords.Values | Where-Object { $_.Memberships.Contains([int]$stage) } | Sort-Object ReferenceOrder, Name)
        foreach ($asiRecord in $selectedAsi) {
            $version = if ($asiRecord.VersionsByStage.ContainsKey([int]$stage)) { [int]$asiRecord.VersionsByStage[[int]$stage] } else { [int]$asiRecord.CatalogVersion }
            if ($version -le 0) { continue }
            $newAsiMods.Add([pscustomobject][ordered]@{ updategroup = [int]$asiRecord.UpdateGroup; version = $version })
        }
        $queueInfo.Data.asimods = $newAsiMods
        $json = $queueInfo.Data | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText($queueInfo.Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }
    $State.Dirty = $false
    return $backupRoot
}

function Invoke-SelfTest {
    $testMemberships = [System.Collections.Generic.List[int]]::new()
    $testAsiRecord = [pscustomobject]@{ Memberships = $testMemberships; VersionsByStage = @{}; CatalogVersion = 13; Status = '' }
    Set-AsiRecordQueueMembership -Record $testAsiRecord -Stage 1 -Include $true -UseCatalogVersion $true
    if (-not $testAsiRecord.Memberships.Contains(1) -or [int]$testAsiRecord.VersionsByStage[1] -ne 13 -or $testAsiRecord.Status -ne 'OK') { throw 'ASI membership addition regression test failed.' }
    Set-AsiRecordQueueMembership -Record $testAsiRecord -Stage 1 -Include $false
    if ($testAsiRecord.Memberships.Contains(1) -or $testAsiRecord.Status -ne 'Unassigned') { throw 'ASI membership removal regression test failed.' }
    $results = foreach ($game in @('LE1', 'LE2', 'LE3')) {
        $activeSetId = Get-ActiveSetId
        $state = Get-GameState -Game $game -SetId $activeSetId
        $missingMetadata = @($state.Records.Values | Where-Object { -not $_.Facts.Exists })
        foreach ($stage in $state.StageNames.Keys) {
            $originalAsi = @($state.Queues[$stage].Data.asimods | Where-Object { $null -ne $_.updategroup } | ForEach-Object { "$([int]$_.updategroup):$([int]$_.version)" } | Sort-Object)
            $rebuiltAsi = @($state.AsiRecords.Values | Where-Object { $_.Memberships.Contains([int]$stage) } | ForEach-Object {
                $version = if ($_.VersionsByStage.ContainsKey([int]$stage)) { [int]$_.VersionsByStage[[int]$stage] } else { [int]$_.CatalogVersion }
                "$([int]$_.UpdateGroup):$version"
            } | Sort-Object)
            if (($originalAsi -join '|') -ne ($rebuiltAsi -join '|')) { throw "ASI round-trip mismatch for $game queue $stage." }
        }
        [pscustomobject]@{
            Game = $game
            Set = $state.SetName
            Mods = $state.Records.Count
            InCreation = @($state.Records.Values | Where-Object { $_.InCreation }).Count
            Assigned = @($state.Records.Values | Where-Object { $null -ne $_.Target }).Count
            AsiCatalog = $state.AsiRecords.Count
            AsiInCreation = @($state.AsiRecords.Values | Where-Object { $_.Memberships.Contains(0) }).Count
            AsiAssigned = @($state.AsiRecords.Values | Where-Object { @($_.Memberships | Where-Object { $_ -gt 0 }).Count }).Count
            AsiVersionProblems = @($state.AsiRecords.Values | Where-Object { $_.Status -like 'Catalog v*' }).Count
            Duplicates = @($state.Records.Values | Where-Object { $_.Memberships.Count -gt 1 }).Count
            DependencyOrderProblems = @($state.Records.Values | Where-Object { $_.Status -like '*Dependency is installed later*' -or $_.Status -like '*Dependency is ordered later*' }).Count
            CompatibilityOrderProblems = @($state.Records.Values | Where-Object { $_.Status -like '*Compatibility target is installed later*' -or $_.Status -like '*Compatibility target is ordered later*' }).Count
            IncompatibilityProblems = @($state.Records.Values | Where-Object { $_.Status -like '*Incompatible with:*' }).Count
            MissingMetadata = $missingMetadata.Count
            MissingMetadataNames = @($missingMetadata.Name) -join '; '
            MissingProviders = @($state.Records.Values | Where-Object { $_.Status -like '*Dependency is missing*' }).Count
        }
    }
    $results | Format-Table -AutoSize
    $allState = Get-AllGameState
    Write-Output "All view mods: $($allState.Records.Count)"
    Write-Output "All view ASI plugins: $($allState.AsiRecords.Count)"
    Write-Output 'ASI membership add/remove: OK'
    Write-Output 'ASI queue round-trip: OK'
}

if ($SelfTest) {
    if (-not $script:QueueRoot) { throw 'SelfTest requires a valid saved ModManagerRoot or the -ModsRoot parameter.' }
    Invoke-SelfTest
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

public static class OrganizerTaskbarIdentity
{
    [DllImport("shell32.dll", SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    public static void Apply()
    {
        SetCurrentProcessExplicitAppUserModelID("ME3Tweaks.BatchQueueOrganizer");
    }
}
'@
[OrganizerTaskbarIdentity]::Apply()
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not $script:QueueRoot) {
    $picker = [System.Windows.Forms.OpenFileDialog]@{
        Title = 'Select ME3TweaksModManager.exe'
        Filter = 'ME3Tweaks Mod Manager|ME3TweaksModManager.exe'
        FileName = 'ME3TweaksModManager.exe'
        CheckFileExists = $true
        Multiselect = $false
    }
    while (-not $script:QueueRoot) {
        if ($picker.ShowDialog() -ne 'OK') {
            [System.Windows.Forms.MessageBox]::Show('The organizer needs the location of ME3TweaksModManager.exe to find the data and mods folders.', 'ME3Tweaks Batch Queue Organizer', 'OK', 'Information')
            exit 0
        }
        $candidateRoot = Split-Path $picker.FileName -Parent
        if (Test-ModManagerRoot $candidateRoot) {
            Set-ModManagerRoot $candidateRoot
        } else {
            [System.Windows.Forms.MessageBox]::Show('The selected executable is not inside a valid ME3Tweaks Mod Manager folder. The same folder must contain the data and mods subfolders.', 'Invalid ME3Tweaks folder', 'OK', 'Error')
        }
    }
    if (-not $script:WindowSettings) { $script:WindowSettings = [pscustomobject]@{} }
    $script:WindowSettings | Add-Member -NotePropertyName ModManagerRoot -NotePropertyValue $script:ModManagerRoot -Force
    [System.IO.File]::WriteAllText($script:SettingsPath, (($script:WindowSettings | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $picker.Dispose()
}

$form = [System.Windows.Forms.Form]@{
    Text = 'ME3Tweaks Batch Queue Organizer'
    Width = 1400
    Height = 820
    StartPosition = 'CenterScreen'
    MinimumSize = [System.Drawing.Size]::new(1050, 650)
}
$iconPath = Join-Path $PSScriptRoot 'ME3TweaksBatchQueueOrganizer.ico'
if (Test-Path -LiteralPath $iconPath) { $form.Icon = [System.Drawing.Icon]::new($iconPath) }

$top = [System.Windows.Forms.Panel]@{ Dock = 'Top'; Height = 82; Padding = [System.Windows.Forms.Padding]::new(8) }
$gameLabel = [System.Windows.Forms.Label]@{ Text = 'Game:'; AutoSize = $true; Left = 10; Top = 15 }
$gameBox = [System.Windows.Forms.ComboBox]@{ Left = 55; Top = 10; Width = 90; DropDownStyle = 'DropDownList' }
[void]$gameBox.Items.AddRange(@('All', 'LE1', 'LE2', 'LE3'))
$searchLabel = [System.Windows.Forms.Label]@{ Text = 'Search:'; AutoSize = $true; Left = 170; Top = 15 }
$searchBox = [System.Windows.Forms.TextBox]@{ Left = 220; Top = 10; Width = 210 }
$filterBox = [System.Windows.Forms.ComboBox]@{ Left = 445; Top = 10; Width = 105; DropDownStyle = 'DropDownList' }
[void]$filterBox.Items.AddRange(@('All mods', 'Unassigned', 'Problems', 'Duplicates', 'Only OK'))
$queueFilterBox = [System.Windows.Forms.ComboBox]@{ Left = 560; Top = 10; Width = 160; DropDownStyle = 'DropDownList' }
[void]$queueFilterBox.Items.Add('All assigned queues')
$sortBox = [System.Windows.Forms.ComboBox]@{ Left = 730; Top = 10; Width = 120; DropDownStyle = 'DropDownList' }
[void]$sortBox.Items.AddRange(@('Sort: Name', 'Sort: Order', 'Sort: Mount ID'))
$reloadButton = [System.Windows.Forms.Button]@{ Text = 'Reload'; Left = 860; Top = 8; Width = 70 }
$saveButton = [System.Windows.Forms.Button]@{ Text = 'Save queues'; Left = 940; Top = 8; Width = 100 }
$creationEditToggle = [System.Windows.Forms.CheckBox]@{ Text = 'Edit Creation List'; Left = 1050; Top = 12; Width = 145 }
$summaryLabel = [System.Windows.Forms.Label]@{ Left = 1205; Top = 14; Width = 190; AutoEllipsis = $true }
$setLabel = [System.Windows.Forms.Label]@{ Text = 'Set:'; AutoSize = $true; Left = 10; Top = 54 }
$setBox = [System.Windows.Forms.ComboBox]@{ Left = 55; Top = 49; Width = 220; DropDownStyle = 'DropDownList' }
$newSetButton = [System.Windows.Forms.Button]@{ Text = 'New set'; Left = 285; Top = 47; Width = 80 }
$renameSetButton = [System.Windows.Forms.Button]@{ Text = 'Rename'; Left = 375; Top = 47; Width = 90 }
$deleteSetButton = [System.Windows.Forms.Button]@{ Text = 'Delete'; Left = 475; Top = 47; Width = 80 }
$activeSetTitle = [System.Windows.Forms.Label]@{ Text = 'Active in ME3Tweaks:'; AutoSize = $true; Left = 580; Top = 54 }
$activeSetBox = [System.Windows.Forms.ComboBox]@{ Left = 710; Top = 49; Width = 220; DropDownStyle = 'DropDownList' }
$asiEditToggle = [System.Windows.Forms.CheckBox]@{ Text = 'Edit ASI Plugins'; Left = 945; Top = 51; Width = 140 }
$activeSetLabel = [System.Windows.Forms.Label]@{ Text = 'Changing the viewed set does not change ME3Tweaks.'; Left = 1090; Top = 53; Width = 295; AutoEllipsis = $true }
$top.Controls.AddRange(@($gameLabel, $gameBox, $searchLabel, $searchBox, $filterBox, $queueFilterBox, $sortBox, $reloadButton, $saveButton, $creationEditToggle, $summaryLabel, $setLabel, $setBox, $newSetButton, $renameSetButton, $deleteSetButton, $activeSetTitle, $activeSetBox, $asiEditToggle, $activeSetLabel))

$split = [System.Windows.Forms.SplitContainer]@{
    Dock = 'Fill'
    FixedPanel = 'Panel2'
    IsSplitterFixed = $false
    SplitterWidth = 4
}
$list = [System.Windows.Forms.ListView]@{ Dock = 'Fill'; View = 'Details'; FullRowSelect = $true; GridLines = $true; MultiSelect = $true; HideSelection = $false; AllowDrop = $true }
[void]$list.Columns.Add('Mod', 310)
[void]$list.Columns.Add('Game', 55)
[void]$list.Columns.Add('Creation', 75)
[void]$list.Columns.Add('Assigned working queue', 260)
[void]$list.Columns.Add('Order', 55)
[void]$list.Columns.Add('Mount ID', 85)
[void]$list.Columns.Add('Required dependencies', 250)
[void]$list.Columns.Add('Compatibility patches', 210)
[void]$list.Columns.Add('Status', 430)
$split.Panel1.Controls.Add($list)

$details = [System.Windows.Forms.Panel]@{ Dock = 'Fill'; Padding = [System.Windows.Forms.Padding]::new(12) }
$selectedLabel = [System.Windows.Forms.Label]@{ Text = 'No mod selected'; Left = 12; Top = 15; Width = 390; Height = 45; Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold) }
$pathLabel = [System.Windows.Forms.Label]@{ Left = 12; Top = 65; Width = 390; Height = 55; AutoEllipsis = $true }
$creationToggle = [System.Windows.Forms.CheckBox]@{ Text = 'Creation List'; Left = 12; Top = 125; Width = 390; ThreeState = $false }
$targetLabel = [System.Windows.Forms.Label]@{ Text = 'Target queue:'; Left = 12; Top = 155; AutoSize = $true }
$targetBox = [System.Windows.Forms.ComboBox]@{ Left = 12; Top = 180; Width = 390; DropDownStyle = 'DropDownList' }
[void]$targetBox.Items.Add('Unassigned')
$assignButton = [System.Windows.Forms.Button]@{ Text = 'Assign selected mods'; Left = 12; Top = 220; Width = 390; Height = 36 }
$moveUpButton = [System.Windows.Forms.Button]@{ Text = 'Move up'; Left = 12; Top = 265; Width = 190; Height = 30 }
$moveDownButton = [System.Windows.Forms.Button]@{ Text = 'Move down'; Left = 212; Top = 265; Width = 190; Height = 30 }
$mountOrderButton = [System.Windows.Forms.Button]@{ Text = 'Sort queue order by Mount ID'; Left = 12; Top = 300; Width = 390; Height = 30 }
$newQueueButton = [System.Windows.Forms.Button]@{ Text = 'New queue'; Left = 12; Top = 335; Width = 190; Height = 30 }
$deleteQueueButton = [System.Windows.Forms.Button]@{ Text = 'Delete filtered queue'; Left = 212; Top = 335; Width = 190; Height = 30 }
$backupButton = [System.Windows.Forms.Button]@{ Text = 'Manage backups'; Left = 12; Top = 370; Width = 390; Height = 30 }
$restoreBeforeInstallToggle = [System.Windows.Forms.CheckBox]@{ Text = 'Restore game before install'; Left = 12; Top = 410; Width = 390 }
$asiSelectAllButton = [System.Windows.Forms.Button]@{ Text = 'Select all ASI plugins'; Left = 12; Top = 125; Width = 190; Height = 32; Visible = $false }
$asiClearAllButton = [System.Windows.Forms.Button]@{ Text = 'Clear ASI plugins'; Left = 212; Top = 125; Width = 190; Height = 32; Visible = $false }
$asiModeHint = [System.Windows.Forms.Label]@{ Text = 'Select a specific queue above, then toggle its ASI plugins in the list.'; Left = 12; Top = 170; Width = 390; Height = 55; Visible = $false }
$dependencyLabel = [System.Windows.Forms.Label]@{ Text = 'Details'; Left = 12; Top = 440; AutoSize = $true }
$dependencyBox = [System.Windows.Forms.TextBox]@{ Left = 12; Top = 465; Width = 390; Height = 175; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical' }
$hint = [System.Windows.Forms.Label]@{ Text = 'Use Ctrl or Shift to select multiple mods.'; Left = 12; Top = 655; Width = 390; Height = 40 }
$details.Controls.AddRange(@($selectedLabel, $pathLabel, $creationToggle, $targetLabel, $targetBox, $assignButton, $moveUpButton, $moveDownButton, $mountOrderButton, $newQueueButton, $deleteQueueButton, $backupButton, $restoreBeforeInstallToggle, $asiSelectAllButton, $asiClearAllButton, $asiModeHint, $dependencyLabel, $dependencyBox, $hint))
$split.Panel2.Controls.Add($details)
$form.Controls.Add($split)
$form.Controls.Add($top)

function Get-MembershipText($record) {
    if ($record.Memberships.Count -eq 0) { return 'Unassigned' }
    $names = if ($script:State.Game -eq 'All') { $script:State.GameStates[$record.Game].StageNames } else { $script:State.StageNames }
    $setName = if ($script:State.Game -eq 'All') { $script:State.GameStates[$record.Game].SetName } else { $script:State.SetName }
    return (@($record.Memberships | Sort-Object | ForEach-Object { "$($record.Game) [$setName].$_ - $($names[[string]$_])" }) -join '; ')
}

function Get-AsiMembershipText($record) {
    if ($record.Memberships.Count -eq 0) { return 'Not used' }
    $gameState = if ($script:State.Game -eq 'All') { $script:State.GameStates[$record.Game] } else { $script:State }
    return (@($record.Memberships | Sort-Object | ForEach-Object {
        if ([int]$_ -eq 0) { "$($record.Game) Creation List" }
        else { "$($record.Game) [$($gameState.SetName)].$_ - $($gameState.StageNames[[string]$_])" }
    }) -join '; ')
}

function Set-ListMode {
    $asiMode = $asiEditToggle.Checked
    $headers = if ($asiMode) {
        @('ASI plugin', 'Game', 'Version', 'Assigned queues', 'Update group', 'Author', 'Type', 'Installed name', 'Status')
    } else {
        @('Mod', 'Game', 'Creation', 'Assigned working queue', 'Order', 'Mount ID', 'Required dependencies', 'Compatibility patches', 'Status')
    }
    for ($index = 0; $index -lt $list.Columns.Count; $index++) { $list.Columns[$index].Text = $headers[$index] }
    $wasUpdating = $script:UpdatingAsiChecks
    $script:UpdatingAsiChecks = $true
    $list.CheckBoxes = $asiMode -and $script:State -and $script:State.Game -ne 'All' -and $queueFilterBox.SelectedIndex -gt 0
    $script:UpdatingAsiChecks = $wasUpdating
}

function Set-FilterItemsForMode {
    $script:UpdatingAsiMode = $true
    try {
        $filterBox.Items.Clear()
        if ($asiEditToggle.Checked) {
            [void]$filterBox.Items.AddRange(@('All ASI plugins', 'Not in selected queue', 'Version problems', 'Multiple queues', 'Only selected'))
        } else {
            [void]$filterBox.Items.AddRange(@('All mods', 'Unassigned', 'Problems', 'Duplicates', 'Only OK'))
        }
        $filterBox.SelectedIndex = 0
    } finally { $script:UpdatingAsiMode = $false }
}

function Update-ModeControls {
    $asiMode = $asiEditToggle.Checked
    $creationMode = $creationEditToggle.Checked
    foreach ($control in @($creationToggle, $targetLabel, $targetBox, $assignButton, $moveUpButton, $moveDownButton, $mountOrderButton, $newQueueButton, $deleteQueueButton)) { $control.Visible = -not $asiMode }
    foreach ($control in @($asiSelectAllButton, $asiClearAllButton, $asiModeHint)) { $control.Visible = $asiMode }
    $asiSelectAllButton.Enabled = $asiMode -and $script:State -and $script:State.Game -ne 'All' -and $queueFilterBox.SelectedIndex -gt 0
    $asiClearAllButton.Enabled = $asiSelectAllButton.Enabled
    $sortBox.Enabled = -not $asiMode
    $creationEditToggle.Enabled = -not ($script:State -and $script:State.Game -eq 'All')
    $asiEditToggle.Enabled = $null -ne $script:State
    if ($asiMode) {
        $hint.Text = 'Check or uncheck ASI plugins for the selected queue. Developer tools are marked separately.'
    } else {
        $hint.Text = 'Use Ctrl or Shift to select multiple mods.'
    }
    if ($list.SelectedItems.Count -eq 0) {
        $selectedLabel.Text = if ($asiMode) { 'No ASI plugin selected' } else { 'No mod selected' }
        $pathLabel.Text = ''
        $dependencyBox.Text = ''
    }
    Set-ListMode
}

function Update-AssignButtonState {
    if (-not $script:State) { return }
    if ($asiEditToggle.Checked) { $assignButton.Enabled = $false; return }
    if ($script:State.Game -eq 'All') {
        $assignButton.Text = 'Remove selected missing mods'
        $selectedRecords = @($list.SelectedItems | ForEach-Object { $_.Tag })
        $assignButton.Enabled = $selectedRecords.Count -gt 0 -and @($selectedRecords | Where-Object {
            $_.Facts.Exists
        }).Count -eq 0
    } else {
        $assignButton.Text = 'Assign selected mods'
        $assignButton.Enabled = -not $creationEditToggle.Checked
    }
}

function Refresh-SetSelector {
    param([string]$PreferredSetId = '')
    $script:UpdatingSetBox = $true
    $script:UpdatingActiveSetBox = $true
    $setBox.Items.Clear()
    $activeSetBox.Items.Clear()
    $sets = @(Get-OrganizerSets)
    foreach ($set in $sets) {
        [void]$setBox.Items.Add([pscustomobject]@{ Text = [string]$set.Name; Id = [string]$set.Id; Name = [string]$set.Name })
        [void]$activeSetBox.Items.Add([pscustomobject]@{ Text = [string]$set.Name; Id = [string]$set.Id; Name = [string]$set.Name })
    }
    $setBox.DisplayMember = 'Text'
    $activeSetBox.DisplayMember = 'Text'
    $wantedId = if ($PreferredSetId) { $PreferredSetId } elseif ($script:State -and $script:State.SetId) { [string]$script:State.SetId } else { Get-ActiveSetId }
    $activeId = Get-ActiveSetId
    $setBox.SelectedIndex = 0
    $activeSetBox.SelectedIndex = 0
    for ($index = 0; $index -lt $setBox.Items.Count; $index++) {
        if ($setBox.Items[$index].Id -eq $wantedId) { $setBox.SelectedIndex = $index }
        if ($activeSetBox.Items[$index].Id -eq $activeId) { $activeSetBox.SelectedIndex = $index }
    }
    $setBox.Enabled = -not ($creationEditToggle.Checked -and [string]$gameBox.SelectedItem -ne 'All')
    $activeSetBox.Enabled = $true
    $newSetButton.Enabled = $setBox.Enabled
    $renameSetButton.Enabled = $setBox.Enabled
    $selectedSetId = if ($setBox.SelectedIndex -ge 0) { [string]$setBox.SelectedItem.Id } else { 'default' }
    $deleteSetButton.Enabled = $setBox.Enabled -and $sets.Count -gt 1 -and $selectedSetId -ne 'default'
    $script:UpdatingSetBox = $false
    $script:UpdatingActiveSetBox = $false
}

function Update-RestoreBeforeInstallToggle {
    $script:UpdatingRestoreToggle = $true
    $restoreBeforeInstallToggle.Checked = $false
    $restoreBeforeInstallToggle.Enabled = $false
    if ($script:State -and $script:State.Game -ne 'All') {
        $stage = if ($creationEditToggle.Checked) { 0 } elseif ($queueFilterBox.SelectedIndex -gt 0) { [int]$queueFilterBox.SelectedItem.Stage } else { -1 }
        if ($stage -ge 0 -and $script:State.Queues.ContainsKey([string]$stage)) {
            $restoreBeforeInstallToggle.Checked = $script:State.Queues[[string]$stage].Data.restorebeforeinstall -eq $true
            $restoreBeforeInstallToggle.Enabled = $true
        }
    }
    $script:UpdatingRestoreToggle = $false
}

function Refresh-QueueSelectors {
    $targetBox.Items.Clear()
    [void]$targetBox.Items.Add([pscustomobject]@{ Text = 'Unassigned'; Stage = $null })
    $queueFilterBox.Items.Clear()
    [void]$queueFilterBox.Items.Add([pscustomobject]@{ Text = 'All assigned queues'; Stage = $null })
    if ($script:State.Game -ne 'All') {
        if ($asiEditToggle.Checked -and $script:State.StageNames.Contains('0')) {
            [void]$queueFilterBox.Items.Add([pscustomobject]@{ Text = '0 - Creation List'; Stage = 0 })
        }
        foreach ($stage in @($script:State.StageNames.Keys | Where-Object { [int]$_ -ge 1 } | Sort-Object { [int]$_ })) {
            $item = [pscustomobject]@{ Text = "$stage - $($script:State.StageNames[$stage])"; Stage = [int]$stage }
            [void]$targetBox.Items.Add($item)
            [void]$queueFilterBox.Items.Add($item)
        }
    }
    $targetBox.DisplayMember = 'Text'
    $queueFilterBox.DisplayMember = 'Text'
    $targetBox.SelectedIndex = 0
    $queueFilterBox.SelectedIndex = if ($asiEditToggle.Checked -and $queueFilterBox.Items.Count -gt 2) { 2 } elseif ($asiEditToggle.Checked -and $queueFilterBox.Items.Count -gt 1) { 1 } else { 0 }
    $readOnly = $script:State.Game -eq 'All'
    if ($readOnly) { $creationEditToggle.Checked = $false }
    $creationEditToggle.Enabled = -not $readOnly
    $creationMode = $creationEditToggle.Checked -and -not $readOnly
    $targetBox.Enabled = -not ($readOnly -or $creationMode -or $asiEditToggle.Checked)
    $creationToggle.Enabled = $creationMode
    $assignButton.Enabled = -not ($readOnly -or $creationMode -or $asiEditToggle.Checked)
    $saveButton.Enabled = -not $readOnly
    $newQueueButton.Enabled = -not ($readOnly -or $creationMode -or $asiEditToggle.Checked)
    $deleteQueueButton.Enabled = -not ($readOnly -or $creationMode -or $asiEditToggle.Checked)
    $queueFilterBox.Enabled = -not $creationMode
    Update-MoveButtons
    Update-AssignButtonState
    Update-RestoreBeforeInstallToggle
    Update-ModeControls
}

function Refresh-AsiList {
    param([hashtable]$PreserveSelection)
    $script:UpdatingAsiChecks = $true
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $search = $searchBox.Text.Trim()
        $filter = [string]$filterBox.SelectedItem
        $stage = if ($script:State.Game -ne 'All' -and $queueFilterBox.SelectedIndex -gt 0) { [Nullable[int]]$queueFilterBox.SelectedItem.Stage } else { $null }
        $recordsToShow = @($script:State.AsiRecords.Values | Sort-Object Game, Name)
        $visible = 0
        foreach ($record in $recordsToShow) {
            if ($search -and $record.Name -notlike "*$search*" -and $record.InstalledName -notlike "*$search*" -and $record.Author -notlike "*$search*") { continue }
            $selectedInStage = $null -ne $stage -and $record.Memberships.Contains([int]$stage)
            $selectedInContext = if ($null -ne $stage) { $selectedInStage } else { $record.Memberships.Count -gt 0 }
            if ($filter -eq 'Not in selected queue' -and $selectedInContext) { continue }
            if ($filter -eq 'Version problems' -and $record.Status -notlike 'Catalog v*' -and $record.Status -ne 'Metadata unavailable') { continue }
            if ($filter -eq 'Multiple queues' -and $record.Memberships.Count -le 1) { continue }
            if ($filter -eq 'Only selected' -and -not $selectedInContext) { continue }
            $shownVersion = if ($selectedInStage -and $record.VersionsByStage.ContainsKey([int]$stage)) { [int]$record.VersionsByStage[[int]$stage] } elseif ($record.CatalogVersion -gt 0) { [int]$record.CatalogVersion } else { '-' }
            $item = [System.Windows.Forms.ListViewItem]::new($record.Name)
            [void]$item.SubItems.Add($record.Game)
            [void]$item.SubItems.Add($(if ($shownVersion -eq '-') { '-' } else { "v$shownVersion" }))
            [void]$item.SubItems.Add((Get-AsiMembershipText $record))
            [void]$item.SubItems.Add([string]$record.UpdateGroup)
            [void]$item.SubItems.Add($(if ($record.Author) { $record.Author } else { '-' }))
            [void]$item.SubItems.Add($(if ($record.DeveloperOnly) { 'Developer tool' } else { 'Standard' }))
            [void]$item.SubItems.Add($(if ($record.InstalledName) { $record.InstalledName } else { '-' }))
            [void]$item.SubItems.Add($record.Status)
            $item.Tag = $record
            if ($null -ne $stage) { $item.Checked = $selectedInStage }
            $selectionKey = "$($record.Game)|$($record.Key)"
            if ($PreserveSelection -and $PreserveSelection.ContainsKey($selectionKey)) { $item.Selected = $true }
            if ($record.Status -like 'Catalog v*' -or $record.Status -eq 'Metadata unavailable') { $item.BackColor = [System.Drawing.Color]::LightYellow }
            elseif ($selectedInStage) { $item.BackColor = [System.Drawing.Color]::Honeydew }
            elseif ($record.DeveloperOnly) { $item.BackColor = [System.Drawing.Color]::AliceBlue }
            [void]$list.Items.Add($item)
            $visible++
        }
        $assigned = @($script:State.AsiRecords.Values | Where-Object { $_.Memberships.Count -gt 0 }).Count
        $summaryLabel.Text = "$visible visible | $assigned/$($script:State.AsiRecords.Count) used"
        $activeSetLabel.Text = if ($null -ne $stage -and [int]$stage -eq 0) { 'Editing ASI plugins in the separate Creation List.' } else { "Viewing ASI plugins for: $($script:State.SetName)." }
    } finally {
        $list.EndUpdate()
        $script:UpdatingAsiChecks = $false
    }
}

function Refresh-List {
    param([hashtable]$PreserveSelection)
    if ($asiEditToggle.Checked) { Refresh-AsiList -PreserveSelection $PreserveSelection; return }
    $list.BeginUpdate()
    $list.Items.Clear()
    $search = $searchBox.Text.Trim()
    $filter = [string]$filterBox.SelectedItem
    $queueFilterStage = if ($queueFilterBox.SelectedIndex -gt 0) { [Nullable[int]]$queueFilterBox.SelectedItem.Stage } else { $null }
    $visible = 0
    $recordsToShow = switch ($sortBox.SelectedIndex) {
        1 {
            if ($creationEditToggle.Checked) { @($script:State.Records.Values | Sort-Object Game, @{ Expression = { if ($_.InCreation) { 0 } else { 1 } } }, @{ Expression = { Get-RecordCreationOrder $_ } }, Name) }
            else { @($script:State.Records.Values | Sort-Object Game, @{ Expression = { if ($null -eq $_.Target) { [int]::MaxValue } else { [int]$_.Target } } }, @{ Expression = { Get-RecordQueueOrder $_ } }, Name) }
        }
        2 { @($script:State.Records.Values | Sort-Object @{ Expression = { if ($_.Facts.MountIds.Count) { [int]$_.Facts.MountIds[0] } else { [int]::MaxValue } } }, Name) }
        default { @($script:State.Records.Values | Sort-Object Name) }
    }
    foreach ($record in $recordsToShow) {
        if ($search -and $record.Name -notlike "*$search*" -and $record.Path -notlike "*$search*") { continue }
        if ($filter -eq 'Unassigned' -and $null -ne $record.Target) { continue }
        if ($filter -eq 'Problems' -and ($record.Status -eq 'OK' -or $record.Status -eq 'Unassigned')) { continue }
        if ($filter -eq 'Duplicates' -and $record.Memberships.Count -le 1) { continue }
        if ($filter -eq 'Only OK' -and $record.Status -ne 'OK') { continue }
        if ($null -ne $queueFilterStage -and ($null -eq $record.Target -or [int]$record.Target -ne [int]$queueFilterStage)) { continue }
        $required = if ($record.Facts.Required.Count) { $record.Facts.Required -join ', ' } else { 'None' }
        $compatibility = if ($record.Facts.Conditional.Count) { $record.Facts.Conditional -join ', ' } else { 'None' }
        $item = [System.Windows.Forms.ListViewItem]::new($record.Name)
        [void]$item.SubItems.Add($record.Game)
        [void]$item.SubItems.Add($(if ($record.InCreation) { 'Yes' } else { 'No' }))
        [void]$item.SubItems.Add((Get-MembershipText $record))
        [void]$item.SubItems.Add($(if ($creationEditToggle.Checked) { if ($record.InCreation) { (Get-RecordCreationOrder $record) + 1 } else { '-' } } elseif ($null -ne $record.Target) { (Get-RecordQueueOrder $record) + 1 } else { '-' }))
        [void]$item.SubItems.Add($(if ($record.Facts.MountIds.Count) { $record.Facts.MountIds -join ', ' } else { '-' }))
        [void]$item.SubItems.Add($required)
        [void]$item.SubItems.Add($compatibility)
        [void]$item.SubItems.Add($record.Status)
        $item.Tag = $record
        if ($PreserveSelection -and $PreserveSelection.ContainsKey($record.Key)) { $item.Selected = $true }
        if ($record.Status -like '*Incompatible with:*') {
            $item.BackColor = [System.Drawing.Color]::LightCoral
            $item.ForeColor = [System.Drawing.Color]::DarkRed
        }
        elseif ($record.Status -like 'Present in multiple*') { $item.BackColor = [System.Drawing.Color]::MistyRose }
        elseif ($record.Status -ne 'OK' -and $record.Status -ne 'Unassigned') { $item.BackColor = [System.Drawing.Color]::LightYellow }
        elseif ($record.Status -eq 'OK') { $item.BackColor = [System.Drawing.Color]::Honeydew }
        [void]$list.Items.Add($item)
        $visible++
    }
    $assigned = @($script:State.Records.Values | Where-Object { $null -ne $_.Target }).Count
    $summaryLabel.Text = "$visible visible | $assigned/$($script:State.Records.Count) assigned"
    $activeSetLabel.Text = if ($creationEditToggle.Checked -and $script:State.Game -ne 'All') { 'Editing the separate Creation List.' } else { "Viewing: $($script:State.SetName). ME3Tweaks activation is independent." }
    $list.EndUpdate()
    if ($PreserveSelection -and $list.SelectedItems.Count -gt 0) {
        $list.SelectedItems[0].Focused = $true
        $list.SelectedItems[0].EnsureVisible()
        $list.Focus()
    }
}

function Load-SelectedGame {
    if ($script:State -and $script:State.Dirty) {
        $answer = [System.Windows.Forms.MessageBox]::Show('Discard unsaved changes?', 'ME3Tweaks Organizer', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return $false }
    }
    $selectedGame = [string]$gameBox.SelectedItem
    $viewedSetId = if ($setBox.SelectedIndex -ge 0) { [string]$setBox.SelectedItem.Id } elseif ($script:State -and $script:State.SetId) { [string]$script:State.SetId } else { Get-ActiveSetId }
    Refresh-SetSelector -PreferredSetId $viewedSetId
    $viewedSetId = [string]$setBox.SelectedItem.Id
    if ($selectedGame -eq 'All') {
        $script:State = Get-AllGameState -SetId $viewedSetId
    } else {
        $script:State = Get-GameState -Game $selectedGame -SetId $viewedSetId
    }
    $declineKey = "$selectedGame|$viewedSetId"
    if ($selectedGame -ne 'All' -and @($script:State.StageNames.Keys | Where-Object { [int]$_ -gt 0 }).Count -eq 0 -and -not $script:DeclinedDefaultGames.Contains($declineKey)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "No organizer-managed queues exist for $selectedGame in set '$($script:State.SetName)'.`r`n`r`nCreate the Creation List (if needed) and the default $selectedGame.1-$selectedGame.7 working queues in this set now?`r`n`r`nChoose No to keep this game empty and create your own queues instead.",
            'No organizer queues found',
            'YesNo',
            'Question'
        )
        if ($answer -eq 'Yes') {
            New-DefaultManagedQueues -Game $selectedGame -SetId $viewedSetId -SetName $script:State.SetName
            $script:State = Get-GameState -Game $selectedGame -SetId $viewedSetId
        } else {
            [void]$script:DeclinedDefaultGames.Add($declineKey)
        }
    }
    Refresh-QueueSelectors
    Refresh-List
    return $true
}

function Load-SelectedSet {
    if ($script:UpdatingSetBox -or -not $form.Visible -or $setBox.SelectedIndex -lt 0) { return }
    if ($script:State -and $script:State.Dirty) {
        $answer = [System.Windows.Forms.MessageBox]::Show('Discard unsaved changes before switching sets?', 'ME3Tweaks Organizer', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') {
            Refresh-SetSelector -PreferredSetId $script:State.SetId
            return
        }
    }
    $setId = [string]$setBox.SelectedItem.Id
    $game = [string]$gameBox.SelectedItem
    $script:State = if ($game -eq 'All') { Get-AllGameState -SetId $setId } else { Get-GameState -Game $game -SetId $setId }
    Refresh-SetSelector -PreferredSetId $setId
    Refresh-QueueSelectors
    Refresh-List
}

function Load-ActiveSet {
    if ($script:UpdatingActiveSetBox -or -not $form.Visible -or $activeSetBox.SelectedIndex -lt 0) { return }
    $newActiveId = [string]$activeSetBox.SelectedItem.Id
    $oldActiveId = Get-ActiveSetId
    if ($newActiveId -eq $oldActiveId) { return }
    if ($script:State -and $script:State.Dirty) {
        [System.Windows.Forms.MessageBox]::Show('Save or reload current changes before changing the set shown in ME3Tweaks.', 'ME3Tweaks Organizer', 'OK', 'Warning')
        Refresh-SetSelector -PreferredSetId $script:State.SetId
        return
    }
    $newName = [string]$activeSetBox.SelectedItem.Name
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Show only organizer queues from '$newName' in ME3Tweaks for all three games?`r`n`r`nThe set currently viewed in this tool will not change. Creation Lists and queues created directly in ME3Tweaks are not affected.",
        'Change active ME3Tweaks set',
        'YesNo',
        'Question'
    )
    if ($answer -ne 'Yes') { Refresh-SetSelector -PreferredSetId $script:State.SetId; return }
    Set-ActiveOrganizerSet -SetId $newActiveId
    $viewedSetId = [string]$script:State.SetId
    $script:State = if ($script:State.Game -eq 'All') { Get-AllGameState -SetId $viewedSetId } else { Get-GameState -Game $script:State.Game -SetId $viewedSetId }
    Refresh-SetSelector -PreferredSetId $viewedSetId
    Refresh-QueueSelectors
    Refresh-List
}

function New-ManagedQueueFile {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game, [string]$SetId = 'default', [string]$SetName = 'Default', [int]$Order, [string]$Name, $TemplateData = $null)
    $fileName = if ($Order -eq 0 -or $SetId -eq 'default') { "$Game.$Order - $Name.biq2" } else { "$Game.$SetId.$Order - $Name.biq2" }
    $activeSetId = Get-ActiveSetId
    $destinationDirectory = if ($Order -eq 0 -or $SetId -eq $activeSetId) { $script:QueueRoot } else { Join-Path (Join-Path $script:InactiveQueueRoot $Game) $SetId }
    [void](New-Item -ItemType Directory -Path $destinationDirectory -Force)
    $path = Join-Path $destinationDirectory $fileName
    if (Test-Path -LiteralPath $path) { return $path }
    $queueName = if ($Order -eq 0 -or $SetId -eq 'default') { "$Game.$Order - $Name" } else { "$Game [$SetName] $Order - $Name" }
    $queue = [ordered]@{
        game = $Game
        description = if ($Order -eq 0) { 'Organizer-managed Creation List.' } else { "Organizer-managed install group: $Name" }
        restorebeforeinstall = if ($null -ne $TemplateData) { $TemplateData.restorebeforeinstall -eq $true } else { $Order -eq 0 -or $Order -eq 1 }
        mods = if ($null -ne $TemplateData) { @($TemplateData.mods) } else { @() }
        asimods = if ($null -ne $TemplateData) { @($TemplateData.asimods) } else { @() }
        texturemodfiles = if ($null -ne $TemplateData) { @($TemplateData.texturemodfiles) } else { @() }
        queuename = $queueName
        ImporterDescription = "Organizer-managed $Game install group: $Name.`r`n`nImporting will add this install group to Batch Installer. This does not import any listed mods."
        organizerManaged = $true
        organizerOrder = $Order
        organizerName = $Name
        organizerRole = if ($Order -eq 0) { 'Creation' } else { 'Assignment' }
        organizerSetId = if ($Order -eq 0) { 'creation' } else { $SetId }
        organizerSetName = if ($Order -eq 0) { 'Creation List' } else { $SetName }
    }
    [System.IO.File]::WriteAllText($path, (($queue | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    Set-QueueRegistryEntry -Game $Game -SetId $SetId -SetName $SetName -Order $Order -Name $Name -QueueName $queueName -FileName (Split-Path $path -Leaf)
    return $path
}

function New-DefaultManagedQueues {
    param([ValidateSet('LE1', 'LE2', 'LE3')][string]$Game, [string]$SetId = 'default', [string]$SetName = 'Default')
    foreach ($stage in $script:DefaultStageNames.Keys) {
        [void](New-ManagedQueueFile -Game $Game -SetId $SetId -SetName $SetName -Order ([int]$stage) -Name ([string]$script:DefaultStageNames[$stage]))
    }
    Set-SetRegistryEntry -SetId $SetId -Name $SetName
    Save-QueueRegistry
    Save-SetRegistry
}

function Get-NewSetId {
    param([string]$Name)
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = 'set' }
    do { $id = "$slug-$([guid]::NewGuid().ToString('N').Substring(0, 6))" } while (@($script:SetRegistry | Where-Object { $_.Id -eq $id }).Count)
    return $id
}

function New-OrganizerSet {
    if ($script:State.Dirty) {
        [System.Windows.Forms.MessageBox]::Show('Save or reload the current changes before creating a set.', 'ME3Tweaks Organizer', 'OK', 'Warning')
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the name of the new set:', 'Create organizer set', '')
    $name = $name.Trim()
    if (-not $name) { return }
    if (@(Get-OrganizerSets | Where-Object { $_.Name -ieq $name }).Count) {
        [System.Windows.Forms.MessageBox]::Show('A global set with this name already exists.', 'Set already exists', 'OK', 'Error')
        return
    }
    $mode = [System.Windows.Forms.MessageBox]::Show(
        "Create the global set '$name' for LE1, LE2 and LE3?`r`n`r`nYes: clone all existing game queues and assignments from '$($script:State.SetName)'`r`nNo: create an empty set without queues`r`nCancel: do nothing",
        'Create organizer set',
        'YesNoCancel',
        'Question'
    )
    if ($mode -eq 'Cancel') { return }
    $setId = Get-NewSetId -Name $name
    $sourceSetId = [string]$script:State.SetId
    Set-SetRegistryEntry -SetId $setId -Name $name
    if ($mode -eq 'Yes') {
        foreach ($game in @('LE1', 'LE2', 'LE3')) {
            $sourceState = Get-GameState -Game $game -SetId $sourceSetId
            foreach ($stage in @($sourceState.StageNames.Keys | Where-Object { [int]$_ -gt 0 } | Sort-Object { [int]$_ })) {
                [void](New-ManagedQueueFile -Game $game -SetId $setId -SetName $name -Order ([int]$stage) -Name ([string]$sourceState.StageNames[$stage]) -TemplateData $sourceState.Queues[$stage].Data)
            }
        }
    }
    Save-QueueRegistry
    Save-SetRegistry
    Refresh-SetSelector -PreferredSetId $setId
    $script:State = if ($script:State.Game -eq 'All') { Get-AllGameState -SetId $setId } else { Get-GameState -Game $script:State.Game -SetId $setId }
    Refresh-QueueSelectors
    Refresh-List
}

function Rename-OrganizerSet {
    if ($script:State.Dirty) {
        if ($script:State.Dirty) { [System.Windows.Forms.MessageBox]::Show('Save or reload current changes before renaming the set.', 'ME3Tweaks Organizer', 'OK', 'Warning') }
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the new set name:', 'Rename organizer set', $script:State.SetName).Trim()
    if (-not $name -or $name -eq $script:State.SetName) { return }
    if (@(Get-OrganizerSets | Where-Object { $_.Id -ne $script:State.SetId -and $_.Name -ieq $name }).Count) {
        [System.Windows.Forms.MessageBox]::Show('A global set with this name already exists.', 'Set already exists', 'OK', 'Error')
        return
    }
    $setId = [string]$script:State.SetId
    foreach ($game in @('LE1', 'LE2', 'LE3')) {
        $gameState = Get-GameState -Game $game -SetId $setId
        $changed = $false
        foreach ($stage in @($gameState.StageNames.Keys | Where-Object { [int]$_ -gt 0 })) {
            $queueInfo = $gameState.Queues[$stage]
            $queueName = "$game [$name] $stage - $($gameState.StageNames[$stage])"
            $queueInfo.Data.queuename = $queueName
            $queueInfo.Data.organizerSetName = $name
            Set-QueueRegistryEntry -Game $game -SetId $setId -SetName $name -Order ([int]$stage) -Name ([string]$gameState.StageNames[$stage]) -QueueName $queueName -FileName (Split-Path $queueInfo.Path -Leaf)
            $changed = $true
        }
        if ($changed) { [void](Save-GameState -State $gameState) }
    }
    Set-SetRegistryEntry -SetId $setId -Name $name
    Save-QueueRegistry
    Save-SetRegistry
    $script:State = if ($script:State.Game -eq 'All') { Get-AllGameState -SetId $setId } else { Get-GameState -Game $script:State.Game -SetId $setId }
    Refresh-SetSelector -PreferredSetId $script:State.SetId
    Refresh-List
}

function Remove-OrganizerSet {
    if ($script:State.Dirty) {
        if ($script:State.Dirty) { [System.Windows.Forms.MessageBox]::Show('Save or reload current changes before deleting the set.', 'ME3Tweaks Organizer', 'OK', 'Warning') }
        return
    }
    $sets = @(Get-OrganizerSets)
    if ($script:State.SetId -eq 'default') {
        [System.Windows.Forms.MessageBox]::Show('The original Default set cannot be deleted. It can be renamed, and additional sets can be deleted.', 'Default set is protected', 'OK', 'Information')
        return
    }
    if ($sets.Count -le 1) { return }
    $setId = [string]$script:State.SetId
    $setName = [string]$script:State.SetName
    $entries = @($script:QueueRegistry | Where-Object { $_.SetId -eq $setId -and [int]$_.Order -gt 0 })
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete global set '$setName' and its $($entries.Count) queue(s) across LE1, LE2 and LE3?`r`n`r`nThe global Creation Lists are not affected. A backup will be created first.", 'Confirm set deletion', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    if ((Get-ActiveSetId) -eq $setId) { Set-ActiveOrganizerSet -SetId 'default' }
    $backupRoot = Join-Path $script:QueueRoot ("OrganizerBackups\{0}-delete-global-set-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $setId)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    foreach ($entry in $entries) {
        $candidates = @(Join-Path $script:QueueRoot ([string]$entry.FileName))
        if (Test-Path -LiteralPath $script:InactiveQueueRoot) { $candidates += @(Get-ChildItem -LiteralPath $script:InactiveQueueRoot -Filter ([string]$entry.FileName) -File -Recurse | ForEach-Object { $_.FullName }) }
        $existingPath = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
        if (-not $existingPath.Count) { continue }
        $path = (Resolve-Path -LiteralPath $existingPath[0]).Path
        $queueRootPath = (Resolve-Path -LiteralPath $script:QueueRoot).Path
        $inactiveRootPath = if (Test-Path -LiteralPath $script:InactiveQueueRoot) { (Resolve-Path -LiteralPath $script:InactiveQueueRoot).Path } else { '' }
        $pathParent = Split-Path $path -Parent
        if ($pathParent -ne $queueRootPath -and (-not $inactiveRootPath -or -not $pathParent.StartsWith($inactiveRootPath + [System.IO.Path]::DirectorySeparatorChar))) {
            throw "Refusing to delete a set queue outside organizer-managed locations: $path"
        }
        $backupName = "$($entry.Game)-$(Split-Path $path -Leaf)"
        Copy-Item -LiteralPath $path -Destination (Join-Path $backupRoot $backupName)
        Remove-Item -LiteralPath $path
    }
    $script:QueueRegistry = @($script:QueueRegistry | Where-Object { -not ($_.SetId -eq $setId -and [int]$_.Order -gt 0) })
    $script:SetRegistry = @($script:SetRegistry | Where-Object { $_.Id -ne $setId })
    Save-QueueRegistry
    Save-SetRegistry
    $nextSet = @(Get-OrganizerSets | Select-Object -First 1)[0]
    Refresh-SetSelector -PreferredSetId $nextSet.Id
    $script:State = if ($script:State.Game -eq 'All') { Get-AllGameState -SetId $nextSet.Id } else { Get-GameState -Game $script:State.Game -SetId $nextSet.Id }
    Refresh-QueueSelectors
    Refresh-List
}

function New-ManagedQueue {
    if ($script:State.Dirty) {
        [System.Windows.Forms.MessageBox]::Show('Save or reload the current changes before creating a queue.', 'ME3Tweaks Organizer', 'OK', 'Warning')
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the name of the new queue:', 'Create managed queue', '')
    $name = $name.Trim()
    if (-not $name) { return }
    if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        [System.Windows.Forms.MessageBox]::Show('The queue name contains characters that cannot be used in a file name.', 'Invalid queue name', 'OK', 'Error')
        return
    }
    $game = $script:State.Game
    if (-not $script:State.StageNames.Contains('0')) {
        [void](New-ManagedQueueFile -Game $game -Order 0 -Name ([string]$script:DefaultStageNames['0']))
    }
    $orders = @($script:State.StageNames.Keys | ForEach-Object { [int]$_ })
    $order = if ($orders.Count) { [int](($orders | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
    [void](New-ManagedQueueFile -Game $game -SetId $script:State.SetId -SetName $script:State.SetName -Order $order -Name $name)
    Save-QueueRegistry
    $script:State = Get-GameState -Game $game -SetId $script:State.SetId
    Refresh-QueueSelectors
    Refresh-List
}

function Remove-FilteredQueue {
    if ($queueFilterBox.SelectedIndex -le 0) {
        [System.Windows.Forms.MessageBox]::Show('Select a specific queue in the queue filter first.', 'No queue selected', 'OK', 'Information')
        return
    }
    if ($script:State.Dirty) {
        [System.Windows.Forms.MessageBox]::Show('Save or reload the current changes before deleting a queue.', 'ME3Tweaks Organizer', 'OK', 'Warning')
        return
    }
    $stage = [int]$queueFilterBox.SelectedItem.Stage
    if ($stage -eq 0) { return }
    $queueInfo = $script:State.Queues[[string]$stage]
    $modCount = if ($null -eq $queueInfo.Data.mods) { 0 } else { @($queueInfo.Data.mods).Count }
    $name = $script:State.StageNames[[string]$stage]
    $answer = [System.Windows.Forms.MessageBox]::Show("Delete '$name'?`r`n`r`n$modCount contained mods will become unassigned. A backup will be created first.", 'Confirm queue deletion', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    $resolvedRoot = (Resolve-Path -LiteralPath (Split-Path $queueInfo.Path -Parent)).Path
    $resolvedFile = (Resolve-Path -LiteralPath $queueInfo.Path).Path
    if ((Split-Path $resolvedFile -Parent) -ne $resolvedRoot) { throw "Refusing to delete a queue outside the managed queue directory: $resolvedFile" }
    $backupRoot = Join-Path $script:QueueRoot ("OrganizerBackups\{0}-delete-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:State.Game)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    Copy-Item -LiteralPath $resolvedFile -Destination (Join-Path $backupRoot (Split-Path $resolvedFile -Leaf))
    Remove-Item -LiteralPath $resolvedFile
    Remove-QueueRegistryEntry -Game $script:State.Game -SetId $script:State.SetId -Order $stage
    $script:State = Get-GameState -Game $script:State.Game -SetId $script:State.SetId
    Refresh-QueueSelectors
    Refresh-List
}

function Show-BackupManager {
    $backupRoot = Join-Path $script:QueueRoot 'OrganizerBackups'
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    $dialog = [System.Windows.Forms.Form]@{ Text = 'Organizer Backup Manager'; Width = 900; Height = 520; StartPosition = 'CenterParent'; MinimizeBox = $false; MaximizeBox = $false }
    if (Test-Path -LiteralPath $iconPath) { $dialog.Icon = [System.Drawing.Icon]::new($iconPath) }
    $backupList = [System.Windows.Forms.ListView]@{ Left = 12; Top = 12; Width = 858; Height = 410; View = 'Details'; FullRowSelect = $true; GridLines = $true; MultiSelect = $false }
    [void]$backupList.Columns.Add('Backup', 430)
    [void]$backupList.Columns.Add('Modified', 175)
    [void]$backupList.Columns.Add('Queue files', 95)
    [void]$backupList.Columns.Add('Size', 120)
    $restoreButton = [System.Windows.Forms.Button]@{ Text = 'Restore selected'; Left = 12; Top = 435; Width = 180; Height = 32 }
    $deleteBackupButton = [System.Windows.Forms.Button]@{ Text = 'Delete selected'; Left = 202; Top = 435; Width = 180; Height = 32 }
    $closeBackupButton = [System.Windows.Forms.Button]@{ Text = 'Close'; Left = 690; Top = 435; Width = 180; Height = 32 }
    $dialog.Controls.AddRange(@($backupList, $restoreButton, $deleteBackupButton, $closeBackupButton))

    $refreshBackups = {
        $backupList.Items.Clear()
        foreach ($directory in Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object LastWriteTime -Descending) {
            $files = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '*.biq2' -File)
            $size = ($files | Measure-Object Length -Sum).Sum
            $item = [System.Windows.Forms.ListViewItem]::new($directory.Name)
            [void]$item.SubItems.Add($directory.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
            [void]$item.SubItems.Add([string]$files.Count)
            [void]$item.SubItems.Add(('{0:N1} KB' -f ($size / 1KB)))
            $item.Tag = $directory.FullName
            [void]$backupList.Items.Add($item)
        }
    }
    & $refreshBackups

    $restoreButton.add_Click({
        if ($backupList.SelectedItems.Count -eq 0) { return }
        if ($script:State.Dirty) {
            [System.Windows.Forms.MessageBox]::Show('Save or reload current changes before restoring a backup.', 'ME3Tweaks Organizer', 'OK', 'Warning')
            return
        }
        $sourceDirectory = [string]$backupList.SelectedItems[0].Tag
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceDirectory -Filter '*.biq2' -File)
        if ($sourceFiles.Count -eq 0) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show("Restore $($sourceFiles.Count) queue file(s) from '$($backupList.SelectedItems[0].Text)'?`r`n`r`nThe current matching files will be backed up first.", 'Confirm backup restore', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $safetyDirectory = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-before-restore')
        [void](New-Item -ItemType Directory -Path $safetyDirectory -Force)
        foreach ($sourceFile in $sourceFiles) {
            $data = Get-Content -LiteralPath $sourceFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sourceFile.Name -match '^(LE[123])\.(\d+) - (.+)\.biq2$' -and $data.organizerManaged -ne $true) {
                $data | Add-Member -NotePropertyName organizerManaged -NotePropertyValue $true -Force
                $data | Add-Member -NotePropertyName organizerOrder -NotePropertyValue ([int]$matches[2]) -Force
                $data | Add-Member -NotePropertyName organizerName -NotePropertyValue $matches[3] -Force
                $data | Add-Member -NotePropertyName organizerRole -NotePropertyValue $(if ([int]$matches[2] -eq 0) { 'Creation' } else { 'Assignment' }) -Force
            }
            $restoreGame = [string]$data.game
            $knownQueue = @($script:QueueRegistry | Where-Object { $_.Game -eq $restoreGame -and $_.FileName -eq $sourceFile.Name } | Select-Object -First 1)
            $restoreOrder = if ($null -ne $data.organizerOrder) { [int]$data.organizerOrder } elseif ($knownQueue.Count) { [int]$knownQueue[0].Order } else { throw "Cannot identify organizer queue order in backup: $($sourceFile.Name)" }
            $matchingGlobalSet = if ($data.organizerSetName) { @(Get-OrganizerSets | Where-Object { $_.Name -ieq [string]$data.organizerSetName } | Select-Object -First 1) } else { @() }
            $restoreSetId = if ($restoreOrder -eq 0) { 'creation' } elseif ($knownQueue.Count -and $knownQueue[0].SetId) { [string]$knownQueue[0].SetId } elseif ($matchingGlobalSet.Count) { [string]$matchingGlobalSet[0].Id } elseif ($data.organizerSetId) { [string]$data.organizerSetId } else { 'default' }
            $restoreSetName = if ($restoreOrder -eq 0) { 'Creation List' } elseif ($knownQueue.Count -and $knownQueue[0].SetName) { [string]$knownQueue[0].SetName } elseif ($matchingGlobalSet.Count) { [string]$matchingGlobalSet[0].Name } elseif ($data.organizerSetName) { [string]$data.organizerSetName } else { 'Default' }
            $restoreQueueName = if ($data.organizerName) { [string]$data.organizerName } elseif ($knownQueue.Count) { [string]$knownQueue[0].Name } else { [string]$data.queuename }
            $data | Add-Member -NotePropertyName organizerManaged -NotePropertyValue $true -Force
            $data | Add-Member -NotePropertyName organizerOrder -NotePropertyValue $restoreOrder -Force
            $data | Add-Member -NotePropertyName organizerName -NotePropertyValue $restoreQueueName -Force
            $data | Add-Member -NotePropertyName organizerRole -NotePropertyValue $(if ($restoreOrder -eq 0) { 'Creation' } else { 'Assignment' }) -Force
            $data | Add-Member -NotePropertyName organizerSetId -NotePropertyValue $restoreSetId -Force
            $data | Add-Member -NotePropertyName organizerSetName -NotePropertyValue $restoreSetName -Force
            $activeSetId = if ($restoreOrder -eq 0) { 'creation' } else { Get-ActiveSetId }
            $destinationDirectory = if ($restoreOrder -eq 0 -or $restoreSetId -eq $activeSetId) { $script:QueueRoot } else { Join-Path (Join-Path $script:InactiveQueueRoot $restoreGame) $restoreSetId }
            [void](New-Item -ItemType Directory -Path $destinationDirectory -Force)
            $destination = Join-Path $destinationDirectory $sourceFile.Name
            if (Test-Path -LiteralPath $destination) { Copy-Item -LiteralPath $destination -Destination (Join-Path $safetyDirectory $sourceFile.Name) }
            [System.IO.File]::WriteAllText($destination, (($data | ConvertTo-Json -Depth 30) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            Set-QueueRegistryEntry -Game $restoreGame -SetId $restoreSetId -SetName $restoreSetName -Order $restoreOrder -Name $restoreQueueName -QueueName ([string]$data.queuename) -FileName $sourceFile.Name
            if ($restoreOrder -gt 0) { Set-SetRegistryEntry -SetId $restoreSetId -Name $restoreSetName }
        }
        Save-QueueRegistry
        Save-SetRegistry
        $script:State = if ($script:State.Game -eq 'All') { Get-AllGameState -SetId $script:State.SetId } else { Get-GameState -Game $script:State.Game -SetId $script:State.SetId }
        Refresh-SetSelector -PreferredSetId $script:State.SetId
        Refresh-QueueSelectors
        Refresh-List
        & $refreshBackups
        [System.Windows.Forms.MessageBox]::Show("Backup restored.`r`n`r`nSafety backup:`r`n$safetyDirectory", 'ME3Tweaks Organizer', 'OK', 'Information')
    })
    $deleteBackupButton.add_Click({
        if ($backupList.SelectedItems.Count -eq 0) { return }
        $selectedDirectory = [string]$backupList.SelectedItems[0].Tag
        $answer = [System.Windows.Forms.MessageBox]::Show("Permanently delete backup '$($backupList.SelectedItems[0].Text)'?`r`n`r`nThis cannot be undone.", 'Confirm backup deletion', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $resolvedRoot = (Resolve-Path -LiteralPath $backupRoot).Path
        $resolvedDirectory = (Resolve-Path -LiteralPath $selectedDirectory).Path
        if ((Split-Path $resolvedDirectory -Parent) -ne $resolvedRoot) { throw "Refusing to delete a directory outside OrganizerBackups: $resolvedDirectory" }
        [System.IO.Directory]::Delete($resolvedDirectory, $true)
        & $refreshBackups
    })
    $closeBackupButton.add_Click({ $dialog.Close() })
    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}

function Move-SelectedMods {
    param([ValidateSet('Up', 'Down')][string]$Direction)
    $creationMode = $creationEditToggle.Checked
    if ($script:State.Game -eq 'All' -or (-not $creationMode -and $queueFilterBox.SelectedIndex -le 0) -or $list.SelectedItems.Count -eq 0) { return }
    $stage = if ($creationMode) { 0 } else { [int]$queueFilterBox.SelectedItem.Stage }
    $ordered = [System.Collections.Generic.List[object]]::new()
    $queueRecords = if ($creationMode) { @($script:State.Records.Values | Where-Object { $_.InCreation } | Sort-Object @{ Expression = { Get-RecordCreationOrder $_ } }, Name) } else { @($script:State.Records.Values | Where-Object { $null -ne $_.Target -and [int]$_.Target -eq $stage } | Sort-Object @{ Expression = { Get-RecordQueueOrder $_ } }, Name) }
    foreach ($record in $queueRecords) { $ordered.Add($record) }
    for ($index = 0; $index -lt $ordered.Count; $index++) { $ordered[$index].QueueOrders[$stage] = $index }
    $selectedKeys = @{}
    foreach ($item in $list.SelectedItems) { $selectedKeys[$item.Tag.Key] = $true }
    if ($Direction -eq 'Up') {
        for ($index = 1; $index -lt $ordered.Count; $index++) {
            if ($selectedKeys.ContainsKey($ordered[$index].Key) -and -not $selectedKeys.ContainsKey($ordered[$index - 1].Key)) {
                $temporary = $ordered[$index - 1]; $ordered[$index - 1] = $ordered[$index]; $ordered[$index] = $temporary
            }
        }
    } else {
        for ($index = $ordered.Count - 2; $index -ge 0; $index--) {
            if ($selectedKeys.ContainsKey($ordered[$index].Key) -and -not $selectedKeys.ContainsKey($ordered[$index + 1].Key)) {
                $temporary = $ordered[$index + 1]; $ordered[$index + 1] = $ordered[$index]; $ordered[$index] = $temporary
            }
        }
    }
    for ($index = 0; $index -lt $ordered.Count; $index++) { $ordered[$index].QueueOrders[$stage] = $index }
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    $sortBox.SelectedIndex = 1
    Refresh-List -PreserveSelection $selectedKeys
}

function Set-QueueOrderByMountId {
    $creationMode = $creationEditToggle.Checked
    if ($script:State.Game -eq 'All' -or (-not $creationMode -and $queueFilterBox.SelectedIndex -le 0)) { return }
    $stage = if ($creationMode) { 0 } else { [int]$queueFilterBox.SelectedItem.Stage }
    $queueName = if ($creationMode) { "$($script:State.Game).0 - Creation List" } else { "$($script:State.Game).$stage - $($script:State.StageNames[[string]$stage])" }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "This will overwrite the manual order of every mod in:`r`n`r`n$queueName`r`n`r`nMods with a Mount ID will be sorted by Mount ID. Mods without one will be placed at the end and sorted by name.`r`n`r`nContinue?",
        'Sort queue order by Mount ID',
        'YesNo',
        'Warning'
    )
    if ($answer -ne 'Yes') { return }

    $queueRecords = if ($creationMode) {
        @($script:State.Records.Values | Where-Object { $_.InCreation })
    } else {
        @($script:State.Records.Values | Where-Object { $null -ne $_.Target -and [int]$_.Target -eq $stage })
    }
    $ordered = @($queueRecords | Sort-Object `
        @{ Expression = { if ($_.Facts.MountIds.Count) { 0 } else { 1 } } }, `
        @{ Expression = { if ($_.Facts.MountIds.Count) { [int](($_.Facts.MountIds | Measure-Object -Minimum).Minimum) } else { [int]::MaxValue } } }, `
        @{ Expression = { $_.Name } })
    for ($index = 0; $index -lt $ordered.Count; $index++) { $ordered[$index].QueueOrders[$stage] = $index }
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    $sortBox.SelectedIndex = 1
    Refresh-List
}

function Update-MoveButtons {
    $enabled = -not $asiEditToggle.Checked -and $script:State -and $script:State.Game -ne 'All' -and ($creationEditToggle.Checked -or $queueFilterBox.SelectedIndex -gt 0)
    $moveUpButton.Enabled = $enabled
    $moveDownButton.Enabled = $enabled
    $mountOrderButton.Enabled = $enabled
}

$list.add_ItemDrag({
    if (-not $asiEditToggle.Checked -and $script:State.Game -ne 'All' -and ($creationEditToggle.Checked -or $queueFilterBox.SelectedIndex -gt 0) -and $sortBox.SelectedIndex -eq 1) {
        [void]$list.DoDragDrop('OrganizerQueueMove', [System.Windows.Forms.DragDropEffects]::Move)
    }
})
$list.add_DragEnter({ param($sender, $eventArgs)
    if (-not $asiEditToggle.Checked -and $script:State.Game -ne 'All' -and ($creationEditToggle.Checked -or $queueFilterBox.SelectedIndex -gt 0) -and $sortBox.SelectedIndex -eq 1 -and $eventArgs.Data.GetDataPresent([string])) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Move
    } else { $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None }
})
$list.add_DragDrop({ param($sender, $eventArgs)
    if ($asiEditToggle.Checked) { return }
    $creationMode = $creationEditToggle.Checked
    if ($script:State.Game -eq 'All' -or (-not $creationMode -and $queueFilterBox.SelectedIndex -le 0) -or $sortBox.SelectedIndex -ne 1) { return }
    $stage = if ($creationMode) { 0 } else { [int]$queueFilterBox.SelectedItem.Stage }
    $selectedKeys = @{}
    foreach ($item in $list.SelectedItems) { $selectedKeys[$item.Tag.Key] = $true }
    if ($selectedKeys.Count -eq 0) { return }
    $ordered = if ($creationMode) { @($script:State.Records.Values | Where-Object { $_.InCreation } | Sort-Object @{ Expression = { Get-RecordCreationOrder $_ } }, Name) } else { @($script:State.Records.Values | Where-Object { $null -ne $_.Target -and [int]$_.Target -eq $stage } | Sort-Object @{ Expression = { Get-RecordQueueOrder $_ } }, Name) }
    $selectedRecords = @($ordered | Where-Object { $selectedKeys.ContainsKey($_.Key) })
    $remaining = @($ordered | Where-Object { -not $selectedKeys.ContainsKey($_.Key) })
    $point = $list.PointToClient([System.Drawing.Point]::new($eventArgs.X, $eventArgs.Y))
    $targetItem = $list.GetItemAt($point.X, $point.Y)
    $insertIndex = $remaining.Count
    $targetBelongsToQueue = $targetItem -and $(if ($creationMode) { $targetItem.Tag.InCreation } else { $null -ne $targetItem.Tag.Target -and [int]$targetItem.Tag.Target -eq $stage })
    if ($targetBelongsToQueue -and -not $selectedKeys.ContainsKey($targetItem.Tag.Key)) {
        $targetRecord = $targetItem.Tag
        $insertIndex = [Array]::IndexOf($remaining, $targetRecord)
        if ($point.Y -ge ($targetItem.Bounds.Top + ($targetItem.Bounds.Height / 2))) { $insertIndex++ }
    }
    $newOrder = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        if ($index -eq $insertIndex) { foreach ($record in $selectedRecords) { $newOrder.Add($record) } }
        $newOrder.Add($remaining[$index])
    }
    if ($insertIndex -ge $remaining.Count) { foreach ($record in $selectedRecords) { $newOrder.Add($record) } }
    for ($index = 0; $index -lt $newOrder.Count; $index++) { $newOrder[$index].QueueOrders[$stage] = $index }
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    Refresh-List -PreserveSelection $selectedKeys
})

$list.add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -eq 0) {
        $script:UpdatingCreationToggle = $true; $creationToggle.CheckState = 'Unchecked'; $script:UpdatingCreationToggle = $false
        $selectedLabel.Text = if ($asiEditToggle.Checked) { 'No ASI plugin selected' } else { 'No mod selected' }
        $pathLabel.Text = ''; $dependencyBox.Text = ''; Update-AssignButtonState; return
    }
    $records = @($list.SelectedItems | ForEach-Object { $_.Tag })
    if ($asiEditToggle.Checked) {
        $selectedLabel.Text = if ($records.Count -eq 1) { $records[0].Name } else { "$($records.Count) ASI plugins selected" }
        if ($records.Count -eq 1) {
            $record = $records[0]
            $pathLabel.Text = @($record.Author, $record.InstalledName | Where-Object { $_ }) -join ' | '
            $assignedVersions = @($record.Memberships | Sort-Object | ForEach-Object {
                $version = if ($record.VersionsByStage.ContainsKey([int]$_)) { $record.VersionsByStage[[int]$_] } else { '-' }
                "Queue $_`: v$version"
            })
            $dependencyBox.Text = "Game: $($record.Game)`r`nUpdate group: $($record.UpdateGroup)`r`nCatalog version: $(if($record.CatalogVersion -gt 0){'v' + $record.CatalogVersion}else{'Unknown'})`r`nType: $(if($record.DeveloperOnly){'Developer tool'}else{'Standard'})`r`n`r`nAssigned queues:`r`n$(if($record.Memberships.Count){Get-AsiMembershipText $record}else{'None'})`r`n$(if($assignedVersions.Count){$assignedVersions -join "`r`n"}else{''})`r`n`r`nStatus:`r`n$($record.Status)`r`n`r`nDescription:`r`n$(if($record.Description){$record.Description}else{'No description available.'})`r`n`r`nSource code:`r`n$(if($record.SourceCode){$record.SourceCode}else{'Not listed.'})"
        } else {
            $pathLabel.Text = ''
            $dependencyBox.Text = 'Use the checkboxes to change ASI assignments for the queue selected above.'
        }
        return
    }
    Update-AssignButtonState
    $creationCount = @($records | Where-Object { $_.InCreation }).Count
    $script:UpdatingCreationToggle = $true
    $creationToggle.CheckState = if ($creationCount -eq 0) { 'Unchecked' } elseif ($creationCount -eq $records.Count) { 'Checked' } else { 'Indeterminate' }
    $script:UpdatingCreationToggle = $false
    $selectedLabel.Text = if ($records.Count -eq 1) { $records[0].Name } else { "$($records.Count) mods selected" }
    if ($records.Count -eq 1) {
        $record = $records[0]
        $pathLabel.Text = $record.Path
        $targetBox.SelectedIndex = 0
        if ($null -ne $record.Target) {
            for ($index = 1; $index -lt $targetBox.Items.Count; $index++) {
                if ([int]$targetBox.Items[$index].Stage -eq [int]$record.Target) { $targetBox.SelectedIndex = $index; break }
            }
        }
        $shownOrder = if ($creationEditToggle.Checked) { if ($record.InCreation) { (Get-RecordCreationOrder $record) + 1 } else { 'Not in Creation' } } elseif ($null -ne $record.Target) { (Get-RecordQueueOrder $record) + 1 } else { 'Unassigned' }
        $dependencyBox.Text = "Creation queue: $(if($record.InCreation){'Yes'}else{'No'})`r`nMount ID: $(if($record.Facts.MountIds.Count){$record.Facts.MountIds -join ', '}else{'None'})`r`nQueue order: $shownOrder`r`n`r`nStatus:`r`n$($record.Status)`r`n`r`nProvides:`r`n$(if($record.Facts.Provided.Count){$record.Facts.Provided -join "`r`n"}else{'None'})`r`n`r`nRequired dependencies:`r`n$(if($record.Facts.Required.Count){$record.Facts.Required -join "`r`n"}else{'None'})`r`n`r`nOptional or patch detection:`r`n$(if($record.Facts.Conditional.Count){$record.Facts.Conditional -join "`r`n"}else{'None'})`r`n`r`nIncompatible DLC:`r`n$(if($record.Facts.Incompatible.Count){$record.Facts.Incompatible -join "`r`n"}else{'None'})`r`n`r`nDescription:`r`n$(if($record.Facts.Description){$record.Facts.Description}else{'No description available.'})"
    } else {
        $pathLabel.Text = ''; $targetBox.SelectedIndex = 0
        $dependencyBox.Text = 'The selected target queue will be applied to every selected mod.'
    }
})

$list.add_ItemCheck({ param($sender, $eventArgs)
    if ($script:UpdatingAsiChecks -or -not $asiEditToggle.Checked -or -not $script:State -or $script:State.Game -eq 'All' -or $queueFilterBox.SelectedIndex -le 0) { return }
    if ($eventArgs.Index -lt 0 -or $eventArgs.Index -ge $list.Items.Count) { return }
    $item = $list.Items[$eventArgs.Index]
    $record = $item.Tag
    if ($null -eq $record -or $null -eq $record.UpdateGroup) { return }
    $stage = [int]$queueFilterBox.SelectedItem.Stage
    $include = $eventArgs.NewValue -eq [System.Windows.Forms.CheckState]::Checked
    Set-AsiRecordQueueMembership -Record $record -Stage $stage -Include $include -UseCatalogVersion $include
    $script:State.Dirty = $true
    $item.SubItems[2].Text = if ($include) { "v$($record.VersionsByStage[$stage])" } elseif ($record.CatalogVersion -gt 0) { "v$($record.CatalogVersion)" } else { '-' }
    $item.SubItems[3].Text = Get-AsiMembershipText $record
    $item.SubItems[8].Text = $record.Status
    $item.BackColor = if ($record.Status -like 'Catalog v*' -or $record.Status -eq 'Metadata unavailable') { [System.Drawing.Color]::LightYellow } elseif ($include) { [System.Drawing.Color]::Honeydew } elseif ($record.DeveloperOnly) { [System.Drawing.Color]::AliceBlue } else { [System.Drawing.Color]::White }
    $assigned = @($script:State.AsiRecords.Values | Where-Object { $_.Memberships.Count -gt 0 }).Count
    $summaryLabel.Text = "$($list.Items.Count) visible | $assigned/$($script:State.AsiRecords.Count) used"
})

$asiSelectAllButton.add_Click({
    if (-not $asiEditToggle.Checked -or $script:State.Game -eq 'All' -or $queueFilterBox.SelectedIndex -le 0) { return }
    $stage = [int]$queueFilterBox.SelectedItem.Stage
    foreach ($record in $script:State.AsiRecords.Values) {
        if ($record.CatalogVersion -le 0) { continue }
        Set-AsiRecordQueueMembership -Record $record -Stage $stage -Include $true -UseCatalogVersion $true
    }
    $script:State.Dirty = $true
    Refresh-List
})

$asiClearAllButton.add_Click({
    if (-not $asiEditToggle.Checked -or $script:State.Game -eq 'All' -or $queueFilterBox.SelectedIndex -le 0) { return }
    $stage = [int]$queueFilterBox.SelectedItem.Stage
    foreach ($record in $script:State.AsiRecords.Values) {
        Set-AsiRecordQueueMembership -Record $record -Stage $stage -Include $false
    }
    $script:State.Dirty = $true
    Refresh-List
})

$creationToggle.add_CheckStateChanged({
    if ($script:UpdatingCreationToggle -or $script:State.Game -eq 'All' -or $list.SelectedItems.Count -eq 0 -or $creationToggle.CheckState -eq 'Indeterminate') { return }
    $addToCreation = $creationToggle.CheckState -eq 'Checked'
    $selectedKeys = @{}
    $records = @($list.SelectedItems | ForEach-Object { $_.Tag })
    foreach ($record in $records) {
        $selectedKeys[$record.Key] = $true
        $record.InCreation = $addToCreation
        if ($addToCreation -and -not $record.QueueOrders.ContainsKey(0)) {
            $existingOrders = @($script:State.Records.Values | Where-Object { $_.Key -ne $record.Key -and $_.InCreation -and $_.QueueOrders.ContainsKey(0) } | ForEach-Object { [int]$_.QueueOrders[0] })
            $record.QueueOrders[0] = if ($existingOrders.Count) { (($existingOrders | Measure-Object -Maximum).Maximum + 1) } else { 0 }
        }
        if (-not $addToCreation) { [void]$record.QueueOrders.Remove(0) }
    }
    $script:State.Dirty = $true
    Refresh-List -PreserveSelection $selectedKeys
})

$creationEditToggle.add_CheckedChanged({
    if ($script:UpdatingAsiMode -or -not $script:State -or $script:State.Game -eq 'All') { return }
    $creationMode = $creationEditToggle.Checked
    if ($creationMode -and $asiEditToggle.Checked) {
        $script:UpdatingAsiMode = $true
        $asiEditToggle.Checked = $false
        $script:UpdatingAsiMode = $false
        Set-FilterItemsForMode
        Refresh-QueueSelectors
    }
    if ($creationMode) { $queueFilterBox.SelectedIndex = 0; $sortBox.SelectedIndex = 1 }
    $queueFilterBox.Enabled = -not $creationMode
    $targetBox.Enabled = -not $creationMode
    $assignButton.Enabled = -not $creationMode
    $newQueueButton.Enabled = -not $creationMode
    $deleteQueueButton.Enabled = -not $creationMode
    $creationToggle.Enabled = $creationMode
    $setBox.Enabled = -not $creationMode
    $newSetButton.Enabled = -not $creationMode
    $renameSetButton.Enabled = -not $creationMode
    $deleteSetButton.Enabled = -not $creationMode -and $script:State.SetId -ne 'default' -and @(Get-OrganizerSets).Count -gt 1
    $activeSetLabel.Text = if ($creationMode) { 'Editing the separate Creation List.' } else { "Viewing: $($script:State.SetName). ME3Tweaks activation is independent." }
    Update-MoveButtons
    Update-AssignButtonState
    Update-RestoreBeforeInstallToggle
    Update-ModeControls
    Refresh-List
})

$asiEditToggle.add_CheckedChanged({
    if ($script:UpdatingAsiMode -or -not $script:State) { return }
    $script:UpdatingAsiMode = $true
    try {
        if ($asiEditToggle.Checked -and $creationEditToggle.Checked) { $creationEditToggle.Checked = $false }
    } finally { $script:UpdatingAsiMode = $false }
    Set-FilterItemsForMode
    Refresh-QueueSelectors
    Update-ModeControls
    Update-RestoreBeforeInstallToggle
    Refresh-List
})

function Remove-MissingModsFromAll {
    $records = @($list.SelectedItems | ForEach-Object { $_.Tag })
    if ($script:State.Game -ne 'All' -or $records.Count -eq 0) { return }
    $invalid = @($records | Where-Object { $_.Facts.Exists })
    if ($invalid.Count) {
        [System.Windows.Forms.MessageBox]::Show('Only mods whose moddesc.ini is missing can be removed from the All view.', 'Cannot remove selection', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Remove $($records.Count) selected missing mod(s) from all organizer queues?`r`n`r`nA backup will be created for every affected game. Existing mods cannot be removed here.",
        'Remove missing mods',
        'YesNo',
        'Warning'
    )
    if ($answer -ne 'Yes') { return }

    foreach ($game in @($records.Game | Sort-Object -Unique)) {
        $gameRecords = @($records | Where-Object { $_.Game -eq $game })
        foreach ($set in @(Get-OrganizerSets)) {
            $setState = Get-GameState -Game $game -SetId $set.Id
            $changed = $false
            foreach ($selectedRecord in $gameRecords) {
                if (-not $setState.Records.ContainsKey($selectedRecord.Key)) { continue }
                $record = $setState.Records[$selectedRecord.Key]
                if ($record.InCreation -or $null -ne $record.Target -or $record.Memberships.Count) { $changed = $true }
                $record.InCreation = $false
                $record.Target = $null
                $record.Memberships.Clear()
                $record.QueueOrders.Clear()
            }
            if ($changed) { [void](Save-GameState -State $setState) }
        }
        foreach ($selectedRecord in $gameRecords) { [void]$script:RemovedMissingMods.Add("$game|$($selectedRecord.Key)") }
    }
    Save-RemovedMissingMods
    $script:State = Get-AllGameState -SetId $script:State.SetId
    Refresh-QueueSelectors
    Refresh-List
}

$assignButton.add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    if ($script:State.Game -eq 'All') { Remove-MissingModsFromAll; return }
    $records = @($list.SelectedItems | ForEach-Object { $_.Tag })
    $target = if ($targetBox.SelectedIndex -le 0) { $null } else { [Nullable[int]]$targetBox.SelectedItem.Stage }
    Set-RecordTarget -State $script:State -Records $records -Target $target
    Refresh-List
})
$newQueueButton.add_Click({ New-ManagedQueue })
$deleteQueueButton.add_Click({ Remove-FilteredQueue })
$backupButton.add_Click({ Show-BackupManager })
$moveUpButton.add_Click({ Move-SelectedMods -Direction Up })
$moveDownButton.add_Click({ Move-SelectedMods -Direction Down })
$mountOrderButton.add_Click({ Set-QueueOrderByMountId })
$newSetButton.add_Click({ New-OrganizerSet })
$renameSetButton.add_Click({ Rename-OrganizerSet })
$deleteSetButton.add_Click({ Remove-OrganizerSet })
$setBox.add_SelectedIndexChanged({ Load-SelectedSet })
$activeSetBox.add_SelectedIndexChanged({ Load-ActiveSet })
$restoreBeforeInstallToggle.add_CheckedChanged({
    if ($script:UpdatingRestoreToggle -or -not $script:State -or $script:State.Game -eq 'All') { return }
    $stage = if ($creationEditToggle.Checked) { 0 } elseif ($queueFilterBox.SelectedIndex -gt 0) { [int]$queueFilterBox.SelectedItem.Stage } else { -1 }
    if ($stage -ge 0 -and $script:State.Queues.ContainsKey([string]$stage)) {
        $script:State.Queues[[string]$stage].Data.restorebeforeinstall = $restoreBeforeInstallToggle.Checked
        $script:State.Dirty = $true
    }
})
$searchBox.add_TextChanged({ Refresh-List })
$filterBox.add_SelectedIndexChanged({ if ($script:State -and -not $script:UpdatingAsiMode) { Refresh-List } })
$queueFilterBox.add_SelectedIndexChanged({ if ($script:State) { Update-ModeControls; Refresh-List; Update-MoveButtons; Update-RestoreBeforeInstallToggle } })
$sortBox.add_SelectedIndexChanged({ if ($script:State) { Refresh-List } })
$reloadButton.add_Click({ [void](Load-SelectedGame) })
$gameBox.add_SelectedIndexChanged({ if ($form.Visible) { [void](Load-SelectedGame) } })
$saveButton.add_Click({
    try {
        $backup = Save-GameState -State $script:State
        [System.Windows.Forms.MessageBox]::Show("Queues saved.`r`n`r`nBackup:`r`n$backup", 'ME3Tweaks Organizer', 'OK', 'Information')
        $script:State = Get-GameState -Game $script:State.Game -SetId $script:State.SetId
        Refresh-QueueSelectors
        Refresh-List
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed', 'OK', 'Error')
    }
})
$form.add_FormClosing({ param($sender, $eventArgs)
    if ($script:State -and $script:State.Dirty) {
        $answer = [System.Windows.Forms.MessageBox]::Show('There are unsaved changes. Close anyway?', 'ME3Tweaks Organizer', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $eventArgs.Cancel = $true }
    }
})
$form.add_Shown({
    if ($script:WindowSettings) {
        $savedBounds = [System.Drawing.Rectangle]::new([int]$script:WindowSettings.X, [int]$script:WindowSettings.Y, [int]$script:WindowSettings.Width, [int]$script:WindowSettings.Height)
        $visible = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($savedBounds) }).Count -gt 0
        if ($visible -and $savedBounds.Width -ge $form.MinimumSize.Width -and $savedBounds.Height -ge $form.MinimumSize.Height) {
            $form.StartPosition = 'Manual'
            $form.Bounds = $savedBounds
        }
    }
    $desiredDetailsWidth = if ($script:WindowSettings -and [int]$script:WindowSettings.DetailsWidth -ge 400) { [int]$script:WindowSettings.DetailsWidth } else { 410 }
    $availableWidth = $split.ClientSize.Width
    $split.SplitterDistance = [Math]::Max(600, $availableWidth - $desiredDetailsWidth - $split.SplitterWidth)
    $split.Panel1MinSize = 600
    $split.Panel2MinSize = 400
    if ($script:WindowSettings -and $script:WindowSettings.ColumnWidths -and @($script:WindowSettings.ColumnWidths).Count -eq $list.Columns.Count) {
        $savedWidths = @($script:WindowSettings.ColumnWidths)
        for ($index = 0; $index -lt [Math]::Min($savedWidths.Count, $list.Columns.Count); $index++) {
            if ([int]$savedWidths[$index] -ge 35) { $list.Columns[$index].Width = [int]$savedWidths[$index] }
        }
    }
    if ($script:WindowSettings -and $script:WindowSettings.Maximized -eq $true) { $form.WindowState = 'Maximized' }
})

$gameBox.SelectedIndex = 0
$filterBox.SelectedIndex = 0
$sortBox.SelectedIndex = 0
$initialSetId = Get-ActiveSetId
$script:State = Get-AllGameState -SetId $initialSetId
Refresh-SetSelector -PreferredSetId $initialSetId
$missingGames = @(@('LE1', 'LE2', 'LE3') | Where-Object { @($script:State.GameStates[$_].StageNames.Keys | Where-Object { [int]$_ -gt 0 }).Count -eq 0 })
if ($missingGames.Count) {
    $missingText = $missingGames -join ', '
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "No organizer-managed queues were found for: $missingText`r`n`r`nCreate the Creation List and default working queues 1-7 for the affected game(s)?`r`n`r`nChoose No to start normally and create your own queues.",
        'Create default organizer queues?',
        'YesNo',
        'Question'
    )
    if ($answer -eq 'Yes') {
        foreach ($missingGame in $missingGames) { New-DefaultManagedQueues -Game $missingGame -SetId $initialSetId -SetName $script:State.SetName }
        $script:State = Get-AllGameState -SetId $initialSetId
    } else {
        foreach ($missingGame in $missingGames) { [void]$script:DeclinedDefaultGames.Add("$missingGame|$initialSetId") }
    }
}
Refresh-QueueSelectors
Refresh-List
try {
    [void]$form.ShowDialog()
} finally {
    $bounds = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $settings = [ordered]@{
        ModManagerRoot = $script:ModManagerRoot
        X = $bounds.X; Y = $bounds.Y; Width = $bounds.Width; Height = $bounds.Height
        Maximized = $form.WindowState -eq 'Maximized'
        DetailsWidth = $split.Panel2.Width
        ColumnWidths = @($list.Columns | ForEach-Object { $_.Width })
    }
    [System.IO.File]::WriteAllText($script:SettingsPath, (($settings | ConvertTo-Json) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $form.Dispose()
    [System.Windows.Forms.Application]::ExitThread()
}
exit 0
