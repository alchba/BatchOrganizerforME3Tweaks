param(
    [string]$ModsRoot = '',
    [string]$StorageRoot = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.0.3'

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
$script:CustomRulesPath = Join-Path $script:StorageRoot 'OrganizerCustomRules.json'
$script:CustomRules = @()
$script:CustomRulesLoadError = ''
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

function ConvertTo-NormalizedRuleIdentity {
    param($Identity)

    if ($null -eq $Identity) { $Identity = [pscustomobject]@{} }
    $provided = @($Identity.providedDlc | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    $nexusId = 0
    if ($null -ne $Identity.nexusId) { [void][int]::TryParse([string]$Identity.nexusId, [ref]$nexusId) }
    return [pscustomobject][ordered]@{
        path = ([string]$Identity.path).Trim()
        nexusId = $nexusId
        providedDlc = $provided
        name = ([string]$Identity.name).Trim()
        version = ([string]$Identity.version).Trim()
    }
}

function ConvertTo-NormalizedVersionCondition {
    param($Condition)

    $side = if ($null -ne $Condition -and [string]$Condition.side -eq 'Subject') { 'Subject' } else { 'Target' }
    $operator = if ($null -ne $Condition) { [string]$Condition.operator } else { 'Any' }
    if ($operator -notin @('Any', 'Equal', 'LessThan', 'LessOrEqual', 'GreaterThan', 'GreaterOrEqual')) { $operator = 'Any' }
    $value = if ($null -ne $Condition) { ([string]$Condition.value).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($value)) { $operator = 'Any'; $value = '' }
    return [pscustomobject][ordered]@{
        side = $side
        operator = $operator
        value = $value
    }
}

function Load-CustomRules {
    $script:CustomRulesLoadError = ''
    $loadedRules = @()
    if (Test-Path -LiteralPath $script:CustomRulesPath -PathType Leaf) {
        try {
            $document = Get-Content -LiteralPath $script:CustomRulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $loadedRules = if ($null -ne $document.rules) { @($document.rules) } else { @($document) }
        } catch {
            $script:CustomRulesLoadError = $_.Exception.Message
            $loadedRules = @()
        }
    }
    $normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in $loadedRules) {
        $game = ([string]$rule.game).ToUpperInvariant()
        $relation = [string]$rule.relation
        if ($game -notin @('LE1', 'LE2', 'LE3') -or $relation -notin @('Requires', 'LoadAfter', 'Incompatible', 'IntegratedInto')) { continue }
        $id = [string]$rule.id
        if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString('D') }
        $createdUtc = [string]$rule.createdUtc
        if ([string]::IsNullOrWhiteSpace($createdUtc)) { $createdUtc = [DateTime]::UtcNow.ToString('o') }
        $normalized.Add([pscustomobject][ordered]@{
            id = $id
            game = $game
            relation = $relation
            subject = ConvertTo-NormalizedRuleIdentity $rule.subject
            target = ConvertTo-NormalizedRuleIdentity $rule.target
            versionCondition = ConvertTo-NormalizedVersionCondition $rule.versionCondition
            note = ([string]$rule.note).Trim()
            enabled = $rule.enabled -ne $false
            createdUtc = $createdUtc
        })
    }
    $script:CustomRules = @($normalized)
}

function Save-CustomRules {
    if (-not [string]::IsNullOrWhiteSpace($script:CustomRulesLoadError)) {
        throw "The existing custom rule file could not be read and will not be overwritten: $($script:CustomRulesLoadError)"
    }
    [void](New-Item -ItemType Directory -Path $script:StorageRoot -Force)
    $document = [pscustomobject][ordered]@{
        schemaVersion = 2
        rules = @($script:CustomRules | Sort-Object game, relation, @{ Expression = { $_.subject.name } }, @{ Expression = { $_.target.name } })
    }
    [System.IO.File]::WriteAllText($script:CustomRulesPath, (($document | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

Load-CustomRules

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
        return [pscustomobject]@{ Exists = $false; Provided = @(); Required = @(); Conditional = @(); Incompatible = @(); Description = ''; ModSite = ''; NexusId = 0; ModVersion = ''; MountIds = @() }
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
    $modSite = ''
    if ($text -match '(?im)^\s*modsite\s*=\s*(.+?)\s*$') {
        $candidate = [System.Net.WebUtility]::HtmlDecode($matches[1]).Trim().Trim('"').Trim("'")
        [Uri]$parsedUri = $null
        if ([Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$parsedUri) -and
            $parsedUri.Scheme -in @('http', 'https') -and
            ($parsedUri.DnsSafeHost -eq 'nexusmods.com' -or $parsedUri.DnsSafeHost.EndsWith('.nexusmods.com', [StringComparison]::OrdinalIgnoreCase))) {
            $modSite = $parsedUri.AbsoluteUri
        }
    }
    $nexusId = 0
    if ($text -match '(?im)^\s*nexuscode\s*=\s*(\d+)\s*$') {
        $nexusId = [int]$matches[1]
    } elseif ($modSite -match '(?i)/mods/(\d+)(?:/|$)') {
        $nexusId = [int]$matches[1]
    }
    $modVersion = if ($text -match '(?im)^\s*modver\s*=\s*(.+?)\s*$') { $matches[1].Trim() } else { '' }
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
        ModSite = $modSite
        NexusId = $nexusId
        ModVersion = $modVersion
        MountIds = @($mountIds | Sort-Object)
    }
}

function Get-RecordRuleIdentity {
    param($Record)

    return [pscustomobject][ordered]@{
        path = [string]$Record.Path
        nexusId = [int]$Record.Facts.NexusId
        providedDlc = @($Record.Facts.Provided)
        name = [string]$Record.Name
        version = [string]$Record.Facts.ModVersion
    }
}

function Resolve-RuleIdentity {
    param($State, $Identity)

    if ($null -eq $State -or $null -eq $Identity) { return $null }
    $records = @($State.Records.Values)
    $path = ([string]$Identity.path).Trim()
    if ($path) {
        $match = @($records | Where-Object { $_.Path -ieq $path })
        if ($match.Count -eq 1) { return $match[0] }
    }
    $provided = @($Identity.providedDlc | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($provided.Count) {
        $match = @($records | Where-Object {
            $recordProvided = @($_.Facts.Provided)
            @($provided | Where-Object { $recordProvided -icontains $_ }).Count -gt 0
        })
        if ($match.Count -eq 1) { return $match[0] }
    }
    $nexusId = 0
    if ($null -ne $Identity.nexusId) { [void][int]::TryParse([string]$Identity.nexusId, [ref]$nexusId) }
    if ($nexusId -gt 0) {
        $match = @($records | Where-Object { [int]$_.Facts.NexusId -eq $nexusId })
        if ($match.Count -eq 1) { return $match[0] }
    }
    $name = ([string]$Identity.name).Trim()
    if ($name) {
        $match = @($records | Where-Object { $_.Name -ieq $name })
        if ($match.Count -eq 1) { return $match[0] }
    }
    return $null
}

function Get-RuleIdentityDisplayName {
    param($Identity)
    if ($null -eq $Identity) { return 'Unknown mod' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Identity.name)) { return [string]$Identity.name }
    if (@($Identity.providedDlc).Count) { return (@($Identity.providedDlc) -join ', ') }
    if ([int]$Identity.nexusId -gt 0) { return "Nexus mod $($Identity.nexusId)" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Identity.path)) { return [string]$Identity.path }
    return 'Unknown mod'
}

function Compare-ModVersions {
    param([string]$Left, [string]$Right)

    $leftText = $Left.Trim().ToLowerInvariant() -replace '^v(?=\d)', ''
    $rightText = $Right.Trim().ToLowerInvariant() -replace '^v(?=\d)', ''
    if ($leftText -eq $rightText) { return 0 }
    $leftNumbers = @([regex]::Matches($leftText, '\d+') | ForEach-Object { [long]$_.Value })
    $rightNumbers = @([regex]::Matches($rightText, '\d+') | ForEach-Object { [long]$_.Value })
    if (-not $leftNumbers.Count -or -not $rightNumbers.Count) {
        return [Math]::Sign([string]::Compare($leftText, $rightText, [System.StringComparison]::OrdinalIgnoreCase))
    }
    $count = [Math]::Max($leftNumbers.Count, $rightNumbers.Count)
    for ($index = 0; $index -lt $count; $index++) {
        $leftPart = if ($index -lt $leftNumbers.Count) { $leftNumbers[$index] } else { 0 }
        $rightPart = if ($index -lt $rightNumbers.Count) { $rightNumbers[$index] } else { 0 }
        if ($leftPart -lt $rightPart) { return -1 }
        if ($leftPart -gt $rightPart) { return 1 }
    }
    $leftSuffix = ([regex]::Replace($leftText, '[\d\s._-]+', '')).Trim()
    $rightSuffix = ([regex]::Replace($rightText, '[\d\s._-]+', '')).Trim()
    if (-not $leftSuffix -and $rightSuffix) { return 1 }
    if ($leftSuffix -and -not $rightSuffix) { return -1 }
    return [Math]::Sign([string]::Compare($leftSuffix, $rightSuffix, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-VersionConditionDisplayText {
    param($Condition, [switch]$Compact)

    $normalized = ConvertTo-NormalizedVersionCondition $Condition
    if ($normalized.operator -eq 'Any') { return $(if ($Compact) { '' } else { 'Any version' }) }
    $side = if ($normalized.side -eq 'Subject') { 'selected mod' } else { 'target' }
    $operator = switch ($normalized.operator) {
        'Equal' { '=' }
        'LessThan' { '<' }
        'LessOrEqual' { '<=' }
        'GreaterThan' { '>' }
        'GreaterOrEqual' { '>=' }
    }
    return "$side version $operator $($normalized.value)"
}

function Test-RuleVersionCondition {
    param($Rule, $SubjectRecord, $TargetRecord)

    $condition = ConvertTo-NormalizedVersionCondition $Rule.versionCondition
    if ($condition.operator -eq 'Any') { return $true }
    $record = if ($condition.side -eq 'Subject') { $SubjectRecord } else { $TargetRecord }
    if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.Facts.ModVersion)) { return $false }
    $comparison = Compare-ModVersions -Left ([string]$record.Facts.ModVersion) -Right ([string]$condition.value)
    $result = switch ($condition.operator) {
        'Equal' { $comparison -eq 0 }
        'LessThan' { $comparison -lt 0 }
        'LessOrEqual' { $comparison -le 0 }
        'GreaterThan' { $comparison -gt 0 }
        'GreaterOrEqual' { $comparison -ge 0 }
        default { $true }
    }
    return [bool]$result
}

function Get-ResolvedCustomRules {
    param($State)

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in @($script:CustomRules | Where-Object { $_.enabled -ne $false -and $_.game -eq $State.Game })) {
        $subjectRecord = Resolve-RuleIdentity -State $State -Identity $rule.subject
        if ($null -eq $subjectRecord) { continue }
        $targetRecord = Resolve-RuleIdentity -State $State -Identity $rule.target
        $versionCondition = ConvertTo-NormalizedVersionCondition $rule.versionCondition
        $versionRecord = if ($versionCondition.side -eq 'Subject') { $subjectRecord } else { $targetRecord }
        $versionKnown = $versionCondition.operator -eq 'Any' -or ($null -ne $versionRecord -and -not [string]::IsNullOrWhiteSpace([string]$versionRecord.Facts.ModVersion))
        $applies = $versionCondition.operator -eq 'Any' -or ($versionKnown -and (Test-RuleVersionCondition -Rule $rule -SubjectRecord $subjectRecord -TargetRecord $targetRecord))
        $resolved.Add([pscustomobject]@{
            Rule = $rule
            Subject = $subjectRecord
            Target = $targetRecord
            TargetName = Get-RuleIdentityDisplayName $rule.target
            VersionConditionText = Get-VersionConditionDisplayText $rule.versionCondition -Compact
            VersionConditionKnown = $versionKnown
            ComparedVersion = $(if ($null -ne $versionRecord) { [string]$versionRecord.Facts.ModVersion } else { '' })
            Applies = $applies
        })
    }
    return @($resolved)
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

function Test-WorkingRecordComesFirst {
    param($Earlier, $Later)
    if ($null -eq $Earlier -or $null -eq $Later -or $null -eq $Earlier.Target -or $null -eq $Later.Target) { return $false }
    return [int]$Earlier.Target -lt [int]$Later.Target -or
        ([int]$Earlier.Target -eq [int]$Later.Target -and (Get-RecordQueueOrder $Earlier) -le (Get-RecordQueueOrder $Later))
}

function Test-CreationRecordComesFirst {
    param($Earlier, $Later)
    if ($null -eq $Earlier -or $null -eq $Later -or -not $Earlier.InCreation -or -not $Later.InCreation) { return $false }
    return (Get-RecordCreationOrder $Earlier) -le (Get-RecordCreationOrder $Later)
}

function Get-AutoSortBaseline {
    param([object[]]$Records)

    return @($Records | Sort-Object `
        @{ Expression = { if ($_.Facts.MountIds.Count) { 0 } else { 1 } } }, `
        @{ Expression = { if ($_.Facts.MountIds.Count) { [int]($_.Facts.MountIds | Measure-Object -Minimum).Minimum } else { [int]::MaxValue } } }, `
        @{ Expression = { [string]$_.Name } }, `
        @{ Expression = { [int]$_.ReferenceOrder } })
}

function Add-AutoSortReviewReason {
    param($Review, [string]$Key, [string]$Reason)
    if (-not $Review.ContainsKey($Key)) {
        $Review[$Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$Review[$Key].Add($Reason)
}

function Add-AutoSortEdge {
    param($Prerequisites, $Dependents, [string]$BeforeKey, [string]$AfterKey)
    if ($BeforeKey -eq $AfterKey -or -not $Prerequisites.ContainsKey($BeforeKey) -or -not $Prerequisites.ContainsKey($AfterKey)) { return }
    if ($Prerequisites[$AfterKey].Add($BeforeKey)) { [void]$Dependents[$BeforeKey].Add($AfterKey) }
}

function Get-AutoSortPlan {
    param($State, [object[]]$Records)

    $nodes = @{}
    $prerequisites = @{}
    $dependents = @{}
    $review = @{}
    foreach ($record in $Records) {
        $nodes[$record.Key] = $record
        $prerequisites[$record.Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $dependents[$record.Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $providers = @{}
    foreach ($record in $State.Records.Values) {
        foreach ($dlc in $record.Facts.Provided) {
            if (-not $providers.ContainsKey($dlc)) { $providers[$dlc] = [System.Collections.Generic.List[object]]::new() }
            $providers[$dlc].Add($record)
        }
    }

    foreach ($record in $Records) {
        foreach ($dlc in $record.Facts.Required) {
            $candidates = @(if ($providers.ContainsKey($dlc)) { @($providers[$dlc] | Where-Object { $_.Key -ne $record.Key }) } else { @() })
            if (-not $candidates.Count) { Add-AutoSortReviewReason $review $record.Key "Required mod is missing: $dlc"; continue }
            $earlierOutside = @($candidates | Where-Object { -not $nodes.ContainsKey($_.Key) -and ($_.InCreation -or ($null -ne $_.Target -and (Test-WorkingRecordComesFirst -Earlier $_ -Later $record))) })
            if ($earlierOutside.Count) { continue }
            $inside = @(Get-AutoSortBaseline @($candidates | Where-Object { $nodes.ContainsKey($_.Key) }))
            if ($inside.Count) {
                Add-AutoSortEdge $prerequisites $dependents $inside[0].Key $record.Key
                continue
            }
            $assignedLater = @($candidates | Where-Object { $null -ne $_.Target })
            if ($assignedLater.Count) { Add-AutoSortReviewReason $review $record.Key "Required mod is outside this sort scope and currently later: $($assignedLater[0].Name)" }
            else { Add-AutoSortReviewReason $review $record.Key "Required mod is unassigned: $($candidates[0].Name)" }
        }

        foreach ($dlc in $record.Facts.Conditional) {
            $candidates = @(if ($providers.ContainsKey($dlc)) { @($providers[$dlc] | Where-Object { $_.Key -ne $record.Key -and ($null -ne $_.Target -or $_.InCreation) }) } else { @() })
            foreach ($candidate in $candidates) {
                if ($nodes.ContainsKey($candidate.Key)) {
                    Add-AutoSortEdge $prerequisites $dependents $candidate.Key $record.Key
                } elseif (-not $candidate.InCreation -and -not (Test-WorkingRecordComesFirst -Earlier $candidate -Later $record)) {
                    Add-AutoSortReviewReason $review $record.Key "Compatibility target is outside this sort scope and currently later: $($candidate.Name)"
                }
            }
        }

        foreach ($resolvedRule in @($record.CustomRules)) {
            if ($resolvedRule.Rule.relation -notin @('Requires', 'LoadAfter')) { continue }
            if (-not $resolvedRule.VersionConditionKnown) {
                Add-AutoSortReviewReason $review $record.Key "Local rule version is unknown: $($resolvedRule.TargetName)"
                continue
            }
            if (-not $resolvedRule.Applies) { continue }
            $candidate = $resolvedRule.Target
            $isRequired = $resolvedRule.Rule.relation -eq 'Requires'
            if ($null -eq $candidate) {
                if ($isRequired) { Add-AutoSortReviewReason $review $record.Key "Local dependency is missing: $($resolvedRule.TargetName)" }
                continue
            }
            if ($nodes.ContainsKey($candidate.Key)) {
                Add-AutoSortEdge $prerequisites $dependents $candidate.Key $record.Key
            } elseif ($candidate.InCreation) {
                continue
            } elseif ($null -ne $candidate.Target) {
                if (-not (Test-WorkingRecordComesFirst -Earlier $candidate -Later $record)) {
                    $label = if ($isRequired) { 'Local dependency' } else { 'Local load-after target' }
                    Add-AutoSortReviewReason $review $record.Key "$label is outside this sort scope and currently later: $($candidate.Name)"
                }
            } elseif ($isRequired) {
                Add-AutoSortReviewReason $review $record.Key "Local dependency is unassigned: $($candidate.Name)"
            }
        }
    }

    $baseline = @(Get-AutoSortBaseline $Records)
    $baselineIndex = @{}
    for ($index = 0; $index -lt $baseline.Count; $index++) { $baselineIndex[$baseline[$index].Key] = $index }
    $indegree = @{}; foreach ($key in $nodes.Keys) { $indegree[$key] = $prerequisites[$key].Count }
    $remaining = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $nodes.Keys) { [void]$remaining.Add($key) }
    $ordered = [System.Collections.Generic.List[object]]::new()
    $cycleReported = $false

    while ($remaining.Count) {
        $ready = @($remaining | Where-Object { $indegree[$_] -le 0 } | Sort-Object `
            @{ Expression = { if ($review.ContainsKey($_)) { 1 } else { 0 } } }, `
            @{ Expression = { $baselineIndex[$_] } })
        if (-not $ready.Count) {
            $blockedNames = @($remaining | ForEach-Object { $nodes[$_].Name } | Sort-Object)
            foreach ($key in @($remaining)) { Add-AutoSortReviewReason $review $key "Dependency cycle or cycle-blocked chain: $($blockedNames -join ', ')" }
            $ready = @($remaining | Sort-Object @{ Expression = { $baselineIndex[$_] } } | Select-Object -First 1)
            $indegree[$ready[0]] = 0
            $cycleReported = $true
        }
        $key = [string]$ready[0]
        [void]$remaining.Remove($key)
        $ordered.Add($nodes[$key])
        foreach ($dependentKey in $dependents[$key]) { $indegree[$dependentKey] = [int]$indegree[$dependentKey] - 1 }
    }

    return [pscustomobject]@{
        Ordered = @($ordered)
        Review = $review
        EdgeCount = @($prerequisites.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        CycleDetected = $cycleReported
    }
}

function Clear-AutoSortReview {
    param($State, [object[]]$Records = @())
    if (-not $State) { return }
    $recordsToClear = if ($Records.Count) { @($Records) } else { @($State.Records.Values) }
    foreach ($record in $recordsToClear) {
        $record | Add-Member -NotePropertyName AutoSortReview -NotePropertyValue @() -Force
    }
}

function Set-AutoSortReview {
    param($State, $Plan)
    Clear-AutoSortReview -State $State
    foreach ($key in $Plan.Review.Keys) {
        if (-not $State.Records.ContainsKey($key)) { continue }
        $reasons = @($Plan.Review[$key] | Sort-Object)
        $State.Records[$key] | Add-Member -NotePropertyName AutoSortReview -NotePropertyValue $reasons -Force
    }
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

    foreach ($record in $State.Records.Values) {
        $record | Add-Member -NotePropertyName CustomRules -NotePropertyValue @() -Force
        $record | Add-Member -NotePropertyName ReferencedByCustomRules -NotePropertyValue @() -Force
    }
    $resolvedCustomRules = @(Get-ResolvedCustomRules -State $State)
    $activeCustomRules = @($resolvedCustomRules | Where-Object { $_.Applies })
    foreach ($resolvedRule in $resolvedCustomRules) {
        $resolvedRule.Subject.CustomRules = @($resolvedRule.Subject.CustomRules) + @($resolvedRule)
        if ($null -ne $resolvedRule.Target -and $resolvedRule.Target.Key -ne $resolvedRule.Subject.Key) {
            $resolvedRule.Target.ReferencedByCustomRules = @($resolvedRule.Target.ReferencedByCustomRules) + @($resolvedRule)
        }
    }

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
    foreach ($resolvedRule in @($activeCustomRules | Where-Object { $_.Rule.relation -eq 'Incompatible' -and $null -ne $_.Target })) {
        $record = $resolvedRule.Subject
        $candidate = $resolvedRule.Target
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
        $localMarker = if ($resolvedRule.VersionConditionText) { "[Local, $($resolvedRule.VersionConditionText)]" } else { '[Local]' }
        [void]$incompatiblePartners[$record.Key].Add("$($candidate.Name) $localMarker")
        [void]$incompatiblePartners[$candidate.Key].Add("$($record.Name) $localMarker")
    }

    $integratedTargets = @{}
    foreach ($resolvedRule in @($activeCustomRules | Where-Object { $_.Rule.relation -eq 'IntegratedInto' -and $null -ne $_.Target })) {
        $record = $resolvedRule.Subject
        $candidate = $resolvedRule.Target
        if ($candidate.Key -eq $record.Key) { continue }
        $togetherInWorkingQueues = $null -ne $record.Target -and $null -ne $candidate.Target
        $togetherInCreation = $record.InCreation -and $candidate.InCreation
        if (-not ($togetherInWorkingQueues -or $togetherInCreation)) { continue }
        if (-not $integratedTargets.ContainsKey($record.Key)) {
            $integratedTargets[$record.Key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $localMarker = if ($resolvedRule.VersionConditionText) { "[Local, $($resolvedRule.VersionConditionText)]" } else { '[Local]' }
        [void]$integratedTargets[$record.Key].Add("$($candidate.Name) $localMarker")
    }

    foreach ($record in $State.Records.Values) {
        $problems = [System.Collections.Generic.List[string]]::new()
        if ($record.PSObject.Properties['AutoSortReview']) {
            foreach ($reason in @($record.AutoSortReview)) { $problems.Add("Auto-sort review: $reason") }
        }
        if (-not $record.Facts.Exists) { $problems.Add('moddesc.ini is missing') }
        if ($record.Memberships.Count -gt 1 -and $null -eq $record.Target) {
            $problems.Add('Present in multiple working queues')
        } elseif ($null -eq $record.Target) {
            $problems.Add('Unassigned')
        }
        if ($incompatiblePartners.ContainsKey($record.Key)) {
            foreach ($partnerName in @($incompatiblePartners[$record.Key] | Sort-Object)) { $problems.Add("Incompatible with: $partnerName") }
        }
        if ($integratedTargets.ContainsKey($record.Key)) {
            foreach ($targetName in @($integratedTargets[$record.Key] | Sort-Object)) { $problems.Add("Already integrated into: $targetName") }
        }
        if ($null -ne $record.Target -or $record.InCreation) {
            foreach ($resolvedRule in @($record.CustomRules | Where-Object { -not $_.VersionConditionKnown })) {
                $problems.Add("Local rule version could not be checked: $($resolvedRule.TargetName) ($($resolvedRule.VersionConditionText))")
            }
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
        foreach ($resolvedRule in @($record.CustomRules | Where-Object { $_.Applies -and $_.Rule.relation -in @('Requires', 'LoadAfter') })) {
            $target = $resolvedRule.Target
            $targetName = [string]$resolvedRule.TargetName
            $isRequired = $resolvedRule.Rule.relation -eq 'Requires'
            if ($null -ne $record.Target) {
                if ($isRequired -and $null -eq $target) {
                    $problems.Add("Local dependency is missing: $targetName")
                } elseif ($isRequired -and $null -eq $target.Target) {
                    $problems.Add("Local dependency is unassigned: $targetName")
                } elseif ($null -ne $target -and $null -ne $target.Target -and -not (Test-WorkingRecordComesFirst -Earlier $target -Later $record)) {
                    $label = if ($isRequired) { 'Local dependency' } else { 'Local load-after target' }
                    if ([int]$target.Target -gt [int]$record.Target) {
                        $problems.Add("$label is installed later: $targetName")
                    } else {
                        $problems.Add("$label is ordered later: $targetName")
                    }
                }
            }
            if ($record.InCreation) {
                if ($isRequired -and $null -eq $target) {
                    $creationProblem = "Local Creation dependency is missing: $targetName"
                    if (-not $problems.Contains($creationProblem)) { $problems.Add($creationProblem) }
                } elseif ($isRequired -and -not $target.InCreation) {
                    $problems.Add("Local dependency is not in Creation List: $targetName")
                } elseif ($null -ne $target -and $target.InCreation -and -not (Test-CreationRecordComesFirst -Earlier $target -Later $record)) {
                    $label = if ($isRequired) { 'Local Creation dependency' } else { 'Local Creation load-after target' }
                    $problems.Add("$label is ordered later: $targetName")
                }
            }
        }
        $record.Status = if ($problems.Count) { $problems -join '; ' } else { 'OK' }
    }
}

function Set-RecordTarget {
    param($State, [object[]]$Records, [Nullable[int]]$Target)
    Clear-AutoSortReview -State $State
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
    $savedCustomRulesPath = $script:CustomRulesPath
    $savedCustomRulesForRoundTrip = @($script:CustomRules)
    $savedCustomRulesLoadError = $script:CustomRulesLoadError
    $testRulesDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ME3TweaksOrganizerRules-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $testRulesDirectory)
        $script:CustomRulesPath = Join-Path $testRulesDirectory 'OrganizerCustomRules.json'
        $script:CustomRulesLoadError = ''
        $script:CustomRules = @([pscustomobject][ordered]@{
            id = 'selftest-roundtrip'; game = 'LE1'; relation = 'Requires'
            subject = [pscustomobject]@{ path = 'LE1\Subject\moddesc.ini'; nexusId = 1; providedDlc = @('DLC_MOD_SUBJECT'); name = 'Subject'; version = '1.0' }
            target = [pscustomobject]@{ path = 'LE1\Target\moddesc.ini'; nexusId = 2; providedDlc = @('DLC_MOD_TARGET'); name = 'Target'; version = '2.0' }
            versionCondition = [pscustomobject]@{ side = 'Target'; operator = 'GreaterOrEqual'; value = '2.0' }
            note = 'Round-trip test'; enabled = $true; createdUtc = [DateTime]::UtcNow.ToString('o')
        })
        Save-CustomRules
        $script:CustomRules = @()
        Load-CustomRules
        if ($script:CustomRules.Count -ne 1 -or $script:CustomRules[0].relation -ne 'Requires' -or $script:CustomRules[0].target.name -ne 'Target' -or
            $script:CustomRules[0].versionCondition.operator -ne 'GreaterOrEqual' -or $script:CustomRules[0].versionCondition.value -ne '2.0') {
            throw 'Local rule JSON round-trip regression test failed.'
        }
    } finally {
        $script:CustomRulesPath = $savedCustomRulesPath
        $script:CustomRules = @($savedCustomRulesForRoundTrip)
        $script:CustomRulesLoadError = $savedCustomRulesLoadError
        if (Test-Path -LiteralPath $testRulesDirectory) { Remove-Item -LiteralPath $testRulesDirectory -Recurse -Force }
    }
    if ((Compare-ModVersions -Left '1.10' -Right '1.9') -le 0 -or (Compare-ModVersions -Left '2.0-beta' -Right '2.0') -ge 0) {
        throw 'Mod version comparison regression test failed.'
    }
    $versionTestRule = [pscustomobject]@{ versionCondition = [pscustomobject]@{ side = 'Target'; operator = 'GreaterThan'; value = '1.5' } }
    $versionTestTarget = [pscustomobject]@{ Facts = [pscustomobject]@{ ModVersion = '1.6' } }
    if (-not (Test-RuleVersionCondition -Rule $versionTestRule -SubjectRecord $null -TargetRecord $versionTestTarget)) { throw 'Version condition positive regression test failed.' }
    $versionTestTarget.Facts.ModVersion = '1.4'
    if (Test-RuleVersionCondition -Rule $versionTestRule -SubjectRecord $null -TargetRecord $versionTestTarget) { throw 'Version condition negative regression test failed.' }

    $newSortTestRecord = {
        param(
            [string]$Key, [string]$Name, $MountId,
            [string[]]$Provided = @(), [string[]]$Required = @(),
            [Nullable[int]]$Target = 1, [bool]$InCreation = $false,
            [int]$ReferenceOrder = 0
        )
        $memberships = [System.Collections.Generic.List[int]]::new()
        $queueOrders = @{}
        if ($null -ne $Target) { $memberships.Add([int]$Target); $queueOrders[[int]$Target] = $ReferenceOrder }
        [pscustomobject]@{
            Key = $Key; Name = $Name; ReferenceOrder = $ReferenceOrder; Target = $Target; InCreation = $InCreation
            Memberships = $memberships; QueueOrders = $queueOrders; CustomRules = @()
            Facts = [pscustomobject]@{
                MountIds = if ($null -eq $MountId) { @() } else { @([int]$MountId) }
                Provided = @($Provided); Required = @($Required); Conditional = @()
            }
        }
    }
    $provider = & $newSortTestRecord -Key 'provider' -Name 'Provider' -MountId 100 -Provided @('DLC_TEST_A') -ReferenceOrder 1
    $dependent = & $newSortTestRecord -Key 'dependent' -Name 'Dependent' -MountId 10 -Required @('DLC_TEST_A') -ReferenceOrder 0
    $plain = & $newSortTestRecord -Key 'plain' -Name 'Plain' -MountId 20 -ReferenceOrder 2
    $missing = & $newSortTestRecord -Key 'missing' -Name 'Missing dependency' -MountId 5 -Required @('DLC_TEST_MISSING') -ReferenceOrder 3
    $localTarget = & $newSortTestRecord -Key 'local-target' -Name 'Local target' -MountId 200 -ReferenceOrder 4
    $localSubject = & $newSortTestRecord -Key 'local-subject' -Name 'Local subject' -MountId 1 -ReferenceOrder 5
    $creationProvider = & $newSortTestRecord -Key 'creation-provider' -Name 'Creation provider' -MountId 300 -Provided @('DLC_TEST_CREATION') -Target $null -InCreation $true -ReferenceOrder 0
    $creationDependent = & $newSortTestRecord -Key 'creation-dependent' -Name 'Creation dependent' -MountId 2 -Required @('DLC_TEST_CREATION') -ReferenceOrder 6
    $localSubject.CustomRules = @([pscustomobject]@{
        VersionConditionKnown = $true; Applies = $true; Rule = [pscustomobject]@{ relation = 'LoadAfter' }
        Target = $localTarget; TargetName = $localTarget.Name
    })
    $sortState = [pscustomobject]@{ Records = @{} }
    foreach ($record in @($provider, $dependent, $plain, $missing, $localTarget, $localSubject, $creationProvider, $creationDependent)) { $sortState.Records[$record.Key] = $record }
    $sortScope = @($provider, $dependent, $plain, $missing, $localTarget, $localSubject, $creationDependent)
    $sortPlan = Get-AutoSortPlan -State $sortState -Records $sortScope
    $sortKeys = @($sortPlan.Ordered.Key)
    if ([Array]::IndexOf($sortKeys, 'provider') -ge [Array]::IndexOf($sortKeys, 'dependent')) { throw 'Auto-sort native dependency regression test failed.' }
    if ([Array]::IndexOf($sortKeys, 'local-target') -ge [Array]::IndexOf($sortKeys, 'local-subject')) { throw 'Auto-sort local load-after regression test failed.' }
    if (-not $sortPlan.Review.ContainsKey('missing') -or $sortKeys[-1] -ne 'missing') {
        $reviewText = @($sortPlan.Review.Keys | ForEach-Object { "$_=$(@($sortPlan.Review[$_] | Sort-Object) -join '|')" }) -join '; '
        throw "Auto-sort unresolved dependency placement regression test failed. Provider facts: $($provider.Facts.Provided -join ','); creation facts: $($creationProvider.Facts.Provided -join ','); Order: $($sortKeys -join ', '); reviews: $reviewText"
    }
    if ($sortPlan.Review.ContainsKey('creation-dependent')) { throw 'Auto-sort Creation provider regression test failed.' }

    $cycleA = & $newSortTestRecord -Key 'cycle-a' -Name 'Cycle A' -MountId 1
    $cycleB = & $newSortTestRecord -Key 'cycle-b' -Name 'Cycle B' -MountId 2
    $cycleA.CustomRules = @([pscustomobject]@{ VersionConditionKnown = $true; Applies = $true; Rule = [pscustomobject]@{ relation = 'Requires' }; Target = $cycleB; TargetName = $cycleB.Name })
    $cycleB.CustomRules = @([pscustomobject]@{ VersionConditionKnown = $true; Applies = $true; Rule = [pscustomobject]@{ relation = 'Requires' }; Target = $cycleA; TargetName = $cycleA.Name })
    $cycleState = [pscustomobject]@{ Records = @{ 'cycle-a' = $cycleA; 'cycle-b' = $cycleB } }
    $cyclePlan = Get-AutoSortPlan -State $cycleState -Records @($cycleA, $cycleB)
    if (-not $cyclePlan.CycleDetected -or $cyclePlan.Review.Count -ne 2) { throw 'Auto-sort dependency cycle regression test failed.' }

    $savedCustomRules = @($script:CustomRules)
    try {
        $ruleState = Get-GameState -Game 'LE1' -SetId (Get-ActiveSetId)
        $ruleRecords = @($ruleState.Records.Values | Where-Object { $null -ne $_.Target -and $_.Facts.Exists -and -not $_.InCreation } | Sort-Object @{ Expression = { [int]$_.Target } }, @{ Expression = { Get-RecordQueueOrder $_ } })
        if ($ruleRecords.Count -ge 2) {
            $earlierRecord = $ruleRecords[0]
            $laterRecord = $ruleRecords[-1]
            $testSubjectIdentity = Get-RecordRuleIdentity $earlierRecord
            $testTargetIdentity = Get-RecordRuleIdentity $laterRecord
            $script:CustomRules = @($savedCustomRules) + @([pscustomobject][ordered]@{
                id = 'selftest-local-incompatibility'
                game = 'LE1'
                relation = 'Incompatible'
                subject = $testSubjectIdentity
                target = $testTargetIdentity
                note = 'In-memory self-test only'
                enabled = $true
                createdUtc = [DateTime]::UtcNow.ToString('o')
            }, [pscustomobject][ordered]@{
                id = 'selftest-local-requires'; game = 'LE1'; relation = 'Requires'
                subject = $testSubjectIdentity; target = $testTargetIdentity; note = ''; enabled = $true; createdUtc = [DateTime]::UtcNow.ToString('o')
            }, [pscustomobject][ordered]@{
                id = 'selftest-local-loadafter'; game = 'LE1'; relation = 'LoadAfter'
                subject = $testSubjectIdentity; target = $testTargetIdentity; note = ''; enabled = $true; createdUtc = [DateTime]::UtcNow.ToString('o')
            }, [pscustomobject][ordered]@{
                id = 'selftest-local-integrated'; game = 'LE1'; relation = 'IntegratedInto'
                subject = $testSubjectIdentity; target = $testTargetIdentity; note = ''; enabled = $true; createdUtc = [DateTime]::UtcNow.ToString('o')
            })
            Update-StateStatus -State $ruleState
            if ($earlierRecord.Status -notlike '*Incompatible with:*' -or -not $earlierRecord.Status.Contains('[Local]') -or
                $laterRecord.Status -notlike '*Incompatible with:*' -or -not $laterRecord.Status.Contains('[Local]')) {
                throw 'Local incompatibility rule regression test failed.'
            }
            if ($earlierRecord.Status -notlike '*Local dependency is installed later:*' -or $earlierRecord.Status -notlike '*Local load-after target is installed later:*') {
                throw 'Local dependency/load-after ordering regression test failed.'
            }
            if ($earlierRecord.Status -notlike '*Already integrated into:*') { throw 'Local integrated-mod rule regression test failed.' }
        }
    } finally {
        $script:CustomRules = @($savedCustomRules)
    }
    $results = foreach ($game in @('LE1', 'LE2', 'LE3')) {
        $activeSetId = Get-ActiveSetId
        $state = Get-GameState -Game $game -SetId $activeSetId
        $missingMetadata = @($state.Records.Values | Where-Object { -not $_.Facts.Exists })
        $assignedForAutoSort = @($state.Records.Values | Where-Object { $null -ne $_.Target })
        $autoSortPlan = Get-AutoSortPlan -State $state -Records $assignedForAutoSort
        if ($autoSortPlan.Ordered.Count -ne $assignedForAutoSort.Count) { throw "Auto-sort did not return every assigned $game mod." }
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
            AutoSortEdges = $autoSortPlan.EdgeCount
            AutoSortReview = $autoSortPlan.Review.Count
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
    Write-Output 'Local rule resolution/status: OK'
    Write-Output 'Local rule JSON round-trip: OK'
    Write-Output 'Version conditions/integrated rules: OK'
    Write-Output 'Dependency-aware auto-sort graph: OK'
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
    Text = "ME3Tweaks Batch Queue Organizer v$($script:AppVersion)"
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
$mountOrderButton = [System.Windows.Forms.Button]@{ Text = 'Sort by Mount ID'; Left = 12; Top = 300; Width = 190; Height = 30 }
$dependencySortButton = [System.Windows.Forms.Button]@{ Text = 'Auto-sort...'; Left = 212; Top = 300; Width = 190; Height = 30 }
$newQueueButton = [System.Windows.Forms.Button]@{ Text = 'New queue'; Left = 12; Top = 335; Width = 120; Height = 30 }
$renameQueueButton = [System.Windows.Forms.Button]@{ Text = 'Rename queue'; Left = 142; Top = 335; Width = 120; Height = 30 }
$deleteQueueButton = [System.Windows.Forms.Button]@{ Text = 'Delete queue'; Left = 272; Top = 335; Width = 130; Height = 30 }
$backupButton = [System.Windows.Forms.Button]@{ Text = 'Manage backups'; Left = 12; Top = 370; Width = 390; Height = 30 }
$restoreBeforeInstallToggle = [System.Windows.Forms.CheckBox]@{ Text = 'Restore game before install'; Left = 12; Top = 410; Width = 390 }
$asiSelectAllButton = [System.Windows.Forms.Button]@{ Text = 'Select all ASI plugins'; Left = 12; Top = 125; Width = 190; Height = 32; Visible = $false }
$asiClearAllButton = [System.Windows.Forms.Button]@{ Text = 'Clear ASI plugins'; Left = 212; Top = 125; Width = 190; Height = 32; Visible = $false }
$asiModeHint = [System.Windows.Forms.Label]@{ Text = 'Select a specific queue above, then toggle its ASI plugins in the list.'; Left = 12; Top = 170; Width = 390; Height = 55; Visible = $false }
$dependencyLabel = [System.Windows.Forms.Label]@{ Text = 'Details'; Left = 12; Top = 440; AutoSize = $true }
$manageRulesButton = [System.Windows.Forms.Button]@{ Text = 'Manage local rules...'; Left = 252; Top = 435; Width = 150; Height = 26; Enabled = $false }
$dependencyBox = [System.Windows.Forms.TextBox]@{ Left = 12; Top = 465; Width = 390; Height = 145; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical' }
$nexusLabel = [System.Windows.Forms.Label]@{ Text = 'Nexus:'; Left = 12; Top = 623; AutoSize = $true }
$nexusLink = [System.Windows.Forms.LinkLabel]@{ Text = ''; Left = 62; Top = 620; Width = 340; Height = 22; AutoEllipsis = $true; LinkBehavior = 'HoverUnderline' }
$hint = [System.Windows.Forms.Label]@{ Text = 'Use Ctrl or Shift to select multiple mods.'; Left = 12; Top = 650; Width = 390; Height = 40 }
$details.Controls.AddRange(@($selectedLabel, $pathLabel, $creationToggle, $targetLabel, $targetBox, $assignButton, $moveUpButton, $moveDownButton, $mountOrderButton, $dependencySortButton, $newQueueButton, $renameQueueButton, $deleteQueueButton, $backupButton, $restoreBeforeInstallToggle, $asiSelectAllButton, $asiClearAllButton, $asiModeHint, $dependencyLabel, $manageRulesButton, $dependencyBox, $nexusLabel, $nexusLink, $hint))
$split.Panel2.Controls.Add($details)
$form.Controls.Add($split)
$form.Controls.Add($top)

function Set-NexusLink {
    param([string]$Url)

    $nexusLink.Text = ''
    $nexusLink.Tag = $null
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $nexusLink.Text = $Url
        $nexusLink.Tag = $Url
    }
}

$nexusLink.add_LinkClicked({
    $url = [string]$nexusLink.Tag
    if ([string]::IsNullOrWhiteSpace($url)) { return }
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($url)
        $startInfo.UseShellExecute = $true
        [void][System.Diagnostics.Process]::Start($startInfo)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not open the Nexus page.`r`n`r`n$($_.Exception.Message)", 'Open Nexus page', 'OK', 'Error')
    }
})

function Get-LocalRuleDetailsText {
    param($Record)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($resolvedRule in @($Record.CustomRules | Sort-Object @{ Expression = { $_.Rule.relation } }, TargetName)) {
        $relation = switch ($resolvedRule.Rule.relation) {
            'Requires' { 'Requires' }
            'LoadAfter' { 'Load after (when present)' }
            'Incompatible' { 'Incompatible with' }
            'IntegratedInto' { 'Integrated into' }
        }
        $line = "[Local] $relation`: $($resolvedRule.TargetName)"
        if ($resolvedRule.VersionConditionText) {
            if (-not $resolvedRule.VersionConditionKnown) { $line += " (cannot check $($resolvedRule.VersionConditionText): version unknown)" }
            elseif (-not $resolvedRule.Applies) { $line += " (inactive for installed version $($resolvedRule.ComparedVersion); requires $($resolvedRule.VersionConditionText))" }
            else { $line += " (when $($resolvedRule.VersionConditionText))" }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedRule.Rule.note)) { $line += " - $($resolvedRule.Rule.note)" }
        $lines.Add($line)
    }
    foreach ($resolvedRule in @($Record.ReferencedByCustomRules | Sort-Object @{ Expression = { $_.Rule.relation } }, @{ Expression = { $_.Subject.Name } })) {
        $relation = switch ($resolvedRule.Rule.relation) {
            'Requires' { 'Required by' }
            'LoadAfter' { 'Must load before' }
            'Incompatible' { 'Incompatible with' }
            'IntegratedInto' { 'Includes' }
        }
        $line = "[Local] $relation`: $($resolvedRule.Subject.Name)"
        if ($resolvedRule.VersionConditionText) {
            if (-not $resolvedRule.VersionConditionKnown) { $line += " (cannot check $($resolvedRule.VersionConditionText): version unknown)" }
            elseif (-not $resolvedRule.Applies) { $line += " (inactive for installed version $($resolvedRule.ComparedVersion); requires $($resolvedRule.VersionConditionText))" }
            else { $line += " (when $($resolvedRule.VersionConditionText))" }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedRule.Rule.note)) { $line += " - $($resolvedRule.Rule.note)" }
        $lines.Add($line)
    }
    return $(if ($lines.Count) { $lines -join "`r`n" } else { 'None' })
}

function Show-LocalRuleManager {
    if ($asiEditToggle.Checked -or $list.SelectedItems.Count -ne 1) { return }
    $subject = $list.SelectedItems[0].Tag
    if ($null -eq $subject -or $null -eq $subject.Facts -or -not $subject.Facts.Exists) {
        [System.Windows.Forms.MessageBox]::Show('Local rules can only be edited for a mod that is currently available.', 'Local rules', 'OK', 'Information')
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CustomRulesLoadError)) {
        [System.Windows.Forms.MessageBox]::Show("The local rule file could not be read, so editing is disabled to protect it.`r`n`r`n$($script:CustomRulesPath)`r`n`r`n$($script:CustomRulesLoadError)", 'Local rule file error', 'OK', 'Error')
        return
    }
    $gameState = if ($script:State.Game -eq 'All') { $script:State.GameStates[$subject.Game] } else { $script:State }
    $dialog = [System.Windows.Forms.Form]@{ Text = "Local rules - $($subject.Name)"; Width = 860; Height = 620; StartPosition = 'CenterParent'; MinimizeBox = $false; MaximizeBox = $false }
    if (Test-Path -LiteralPath $iconPath) { $dialog.Icon = [System.Drawing.Icon]::new($iconPath) }
    $subjectVersion = if ([string]::IsNullOrWhiteSpace([string]$subject.Facts.ModVersion)) { 'version unknown' } else { "version $($subject.Facts.ModVersion)" }
    $subjectLabel = [System.Windows.Forms.Label]@{ Text = "Rules defined for: $($subject.Name) ($($subject.Game), $subjectVersion)"; Left = 12; Top = 14; Width = 815; Height = 24; Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
    $rulesList = [System.Windows.Forms.ListView]@{ Left = 12; Top = 42; Width = 815; Height = 250; View = 'Details'; FullRowSelect = $true; GridLines = $true; MultiSelect = $true; HideSelection = $false }
    [void]$rulesList.Columns.Add('Rule', 145)
    [void]$rulesList.Columns.Add('Target mod', 245)
    [void]$rulesList.Columns.Add('Version condition', 195)
    [void]$rulesList.Columns.Add('Note', 225)
    $relationLabel = [System.Windows.Forms.Label]@{ Text = 'Rule type:'; Left = 12; Top = 305; AutoSize = $true }
    $relationBox = [System.Windows.Forms.ComboBox]@{ Left = 12; Top = 327; Width = 235; DropDownStyle = 'DropDownList'; DisplayMember = 'Display' }
    foreach ($option in @(
        [pscustomobject]@{ Display = 'Requires'; Relation = 'Requires' },
        [pscustomobject]@{ Display = 'Load after (when present)'; Relation = 'LoadAfter' },
        [pscustomobject]@{ Display = 'Incompatible'; Relation = 'Incompatible' },
        [pscustomobject]@{ Display = 'Integrated into target mod'; Relation = 'IntegratedInto' }
    )) { [void]$relationBox.Items.Add($option) }
    $relationBox.SelectedIndex = 0
    $targetModLabel = [System.Windows.Forms.Label]@{ Text = 'Target mod:'; Left = 260; Top = 305; AutoSize = $true }
    $targetModBox = [System.Windows.Forms.ComboBox]@{ Left = 260; Top = 327; Width = 567; DropDownStyle = 'DropDown'; DisplayMember = 'Display'; AutoCompleteMode = 'SuggestAppend'; AutoCompleteSource = 'ListItems' }
    foreach ($candidate in @($gameState.Records.Values | Where-Object { $_.Key -ne $subject.Key -and $_.Facts.Exists } | Sort-Object Name, Path)) {
        $candidateVersion = if ([string]::IsNullOrWhiteSpace([string]$candidate.Facts.ModVersion)) { 'version unknown' } else { "v$($candidate.Facts.ModVersion)" }
        [void]$targetModBox.Items.Add([pscustomobject]@{ Display = "$($candidate.Name) ($candidateVersion)  [$($candidate.Path)]"; Record = $candidate })
    }
    if ($targetModBox.Items.Count) { $targetModBox.SelectedIndex = 0 }
    $versionSideLabel = [System.Windows.Forms.Label]@{ Text = 'Version applies to:'; Left = 12; Top = 370; AutoSize = $true }
    $versionSideBox = [System.Windows.Forms.ComboBox]@{ Left = 12; Top = 392; Width = 190; DropDownStyle = 'DropDownList'; DisplayMember = 'Display'; Enabled = $false }
    [void]$versionSideBox.Items.Add([pscustomobject]@{ Display = 'Target mod'; Side = 'Target' })
    [void]$versionSideBox.Items.Add([pscustomobject]@{ Display = 'Selected mod'; Side = 'Subject' })
    $versionSideBox.SelectedIndex = 0
    $versionOperatorLabel = [System.Windows.Forms.Label]@{ Text = 'Version comparison:'; Left = 215; Top = 370; AutoSize = $true }
    $versionOperatorBox = [System.Windows.Forms.ComboBox]@{ Left = 215; Top = 392; Width = 240; DropDownStyle = 'DropDownList'; DisplayMember = 'Display' }
    foreach ($option in @(
        [pscustomobject]@{ Display = 'Any version'; Operator = 'Any' },
        [pscustomobject]@{ Display = 'Exactly (=)'; Operator = 'Equal' },
        [pscustomobject]@{ Display = 'Less than (<)'; Operator = 'LessThan' },
        [pscustomobject]@{ Display = 'At most (<=)'; Operator = 'LessOrEqual' },
        [pscustomobject]@{ Display = 'Greater than (>)'; Operator = 'GreaterThan' },
        [pscustomobject]@{ Display = 'At least (>=)'; Operator = 'GreaterOrEqual' }
    )) { [void]$versionOperatorBox.Items.Add($option) }
    $versionOperatorBox.SelectedIndex = 0
    $versionValueLabel = [System.Windows.Forms.Label]@{ Text = 'Version value (optional):'; Left = 470; Top = 370; AutoSize = $true }
    $versionValueBox = [System.Windows.Forms.TextBox]@{ Left = 470; Top = 392; Width = 357; Height = 25; Enabled = $false }
    $noteLabel = [System.Windows.Forms.Label]@{ Text = 'Optional note:'; Left = 12; Top = 435; AutoSize = $true }
    $noteBox = [System.Windows.Forms.TextBox]@{ Left = 12; Top = 457; Width = 815; Height = 25 }
    $addRuleButton = [System.Windows.Forms.Button]@{ Text = 'Add rule'; Left = 12; Top = 510; Width = 150; Height = 32 }
    $removeRuleButton = [System.Windows.Forms.Button]@{ Text = 'Remove selected'; Left = 172; Top = 510; Width = 170; Height = 32; Enabled = $false }
    $rulesHint = [System.Windows.Forms.Label]@{ Text = 'Rules apply to this game in every set. moddesc.ini metadata keeps priority.'; Left = 355; Top = 512; Width = 300; Height = 40 }
    $closeRulesButton = [System.Windows.Forms.Button]@{ Text = 'Close'; Left = 677; Top = 510; Width = 150; Height = 32 }
    $dialog.Controls.AddRange(@($subjectLabel, $rulesList, $relationLabel, $relationBox, $targetModLabel, $targetModBox, $versionSideLabel, $versionSideBox, $versionOperatorLabel, $versionOperatorBox, $versionValueLabel, $versionValueBox, $noteLabel, $noteBox, $addRuleButton, $removeRuleButton, $rulesHint, $closeRulesButton))
    $versionOperatorBox.add_SelectedIndexChanged({
        $usesVersion = $versionOperatorBox.SelectedIndex -gt 0
        $versionSideBox.Enabled = $usesVersion
        $versionValueBox.Enabled = $usesVersion
        if (-not $usesVersion) { $versionValueBox.Clear() }
    })

    $getSubjectRules = {
        @($script:CustomRules | Where-Object {
            $_.game -eq $subject.Game -and (Resolve-RuleIdentity -State $gameState -Identity $_.subject).Key -eq $subject.Key
        })
    }
    $refreshRules = {
        $rulesList.Items.Clear()
        foreach ($rule in @(& $getSubjectRules | Sort-Object relation, @{ Expression = { Get-RuleIdentityDisplayName $_.target } })) {
            $relation = switch ($rule.relation) { 'Requires' { 'Requires' }; 'LoadAfter' { 'Load after' }; 'Incompatible' { 'Incompatible' }; 'IntegratedInto' { 'Integrated into' } }
            $item = [System.Windows.Forms.ListViewItem]::new($relation)
            [void]$item.SubItems.Add((Get-RuleIdentityDisplayName $rule.target))
            [void]$item.SubItems.Add((Get-VersionConditionDisplayText $rule.versionCondition))
            [void]$item.SubItems.Add([string]$rule.note)
            $item.Tag = $rule
            [void]$rulesList.Items.Add($item)
        }
        $removeRuleButton.Enabled = $rulesList.SelectedItems.Count -gt 0
    }
    & $refreshRules
    $rulesList.add_SelectedIndexChanged({ $removeRuleButton.Enabled = $rulesList.SelectedItems.Count -gt 0 })
    $addRuleButton.add_Click({
        if ($targetModBox.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show('Select a target mod first.', 'Local rules', 'OK', 'Information')
            return
        }
        $relation = [string]$relationBox.SelectedItem.Relation
        $targetRecord = $targetModBox.SelectedItem.Record
        $versionOperator = [string]$versionOperatorBox.SelectedItem.Operator
        $versionValue = $versionValueBox.Text.Trim()
        if ($versionOperator -ne 'Any' -and [string]::IsNullOrWhiteSpace($versionValue)) {
            [System.Windows.Forms.MessageBox]::Show('Enter a version value, or select Any version.', 'Local rules', 'OK', 'Information')
            return
        }
        $versionCondition = ConvertTo-NormalizedVersionCondition ([pscustomobject]@{
            side = [string]$versionSideBox.SelectedItem.Side
            operator = $versionOperator
            value = $versionValue
        })
        $duplicate = @(& $getSubjectRules | Where-Object {
            $existingVersionCondition = ConvertTo-NormalizedVersionCondition $_.versionCondition
            $_.relation -eq $relation -and
            $existingVersionCondition.side -eq $versionCondition.side -and
            $existingVersionCondition.operator -eq $versionCondition.operator -and
            $existingVersionCondition.value -ieq $versionCondition.value -and (
                ([string]$_.target.path -and [string]$_.target.path -ieq [string]$targetRecord.Path) -or
                (Resolve-RuleIdentity -State $gameState -Identity $_.target).Key -eq $targetRecord.Key
            )
        }).Count -gt 0
        if ($duplicate) {
            [System.Windows.Forms.MessageBox]::Show('This rule already exists.', 'Local rules', 'OK', 'Information')
            return
        }
        $newRule = [pscustomobject][ordered]@{
            id = [guid]::NewGuid().ToString('D')
            game = [string]$subject.Game
            relation = $relation
            subject = Get-RecordRuleIdentity $subject
            target = Get-RecordRuleIdentity $targetRecord
            versionCondition = $versionCondition
            note = $noteBox.Text.Trim()
            enabled = $true
            createdUtc = [DateTime]::UtcNow.ToString('o')
        }
        $script:CustomRules += $newRule
        try {
            Save-CustomRules
        } catch {
            $script:CustomRules = @($script:CustomRules | Where-Object { $_.id -ne $newRule.id })
            [System.Windows.Forms.MessageBox]::Show("The local rule could not be saved.`r`n`r`n$($_.Exception.Message)", 'Save local rule', 'OK', 'Error')
            return
        }
        $noteBox.Clear()
        $versionOperatorBox.SelectedIndex = 0
        & $refreshRules
    })
    $removeRuleButton.add_Click({
        $selectedRules = @($rulesList.SelectedItems | ForEach-Object { $_.Tag })
        if (-not $selectedRules.Count) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show("Remove $($selectedRules.Count) selected local rule(s)?", 'Remove local rules', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $selectedIds = @{}; foreach ($rule in $selectedRules) { $selectedIds[[string]$rule.id] = $true }
        $previousRules = @($script:CustomRules)
        $script:CustomRules = @($script:CustomRules | Where-Object { -not $selectedIds.ContainsKey([string]$_.id) })
        try {
            Save-CustomRules
        } catch {
            $script:CustomRules = @($previousRules)
            [System.Windows.Forms.MessageBox]::Show("The local rules could not be saved.`r`n`r`n$($_.Exception.Message)", 'Save local rules', 'OK', 'Error')
            return
        }
        & $refreshRules
    })
    $closeRulesButton.add_Click({ $dialog.Close() })
    [void]$dialog.ShowDialog($form)

    if ($script:State.Game -eq 'All') {
        foreach ($state in $script:State.GameStates.Values) { Clear-AutoSortReview -State $state; Update-StateStatus -State $state }
    } else {
        Clear-AutoSortReview -State $script:State
        Update-StateStatus -State $script:State
    }
    $selectedKeys = @{}; $selectedKeys[$subject.Key] = $true
    Refresh-List -PreserveSelection $selectedKeys -PreserveViewport
}

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
    foreach ($control in @($creationToggle, $targetLabel, $targetBox, $assignButton, $moveUpButton, $moveDownButton, $mountOrderButton, $dependencySortButton, $newQueueButton, $renameQueueButton, $deleteQueueButton, $manageRulesButton)) { $control.Visible = -not $asiMode }
    foreach ($control in @($asiSelectAllButton, $asiClearAllButton, $asiModeHint)) { $control.Visible = $asiMode }
    $asiSelectAllButton.Enabled = $asiMode -and $script:State -and $script:State.Game -ne 'All' -and $queueFilterBox.SelectedIndex -gt 0
    $asiClearAllButton.Enabled = $asiSelectAllButton.Enabled
    $renameQueueButton.Enabled = -not $asiMode -and $script:State -and $script:State.Game -ne 'All' -and -not $creationMode -and $queueFilterBox.SelectedIndex -gt 0 -and [int]$queueFilterBox.SelectedItem.Stage -gt 0
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
        Set-NexusLink
        $manageRulesButton.Enabled = $false
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
    $renameQueueButton.Enabled = -not ($readOnly -or $creationMode -or $asiEditToggle.Checked) -and $queueFilterBox.SelectedIndex -gt 0 -and [int]$queueFilterBox.SelectedItem.Stage -gt 0
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
    param([hashtable]$PreserveSelection, [switch]$PreserveViewport)
    if ($asiEditToggle.Checked) { Refresh-AsiList -PreserveSelection $PreserveSelection; return }
    $preservedTopKey = ''
    $preservedTopIndex = -1
    if ($PreserveViewport -and $list.Items.Count -gt 0 -and $null -ne $list.TopItem) {
        $preservedTopIndex = $list.TopItem.Index
        if ($null -ne $list.TopItem.Tag) { $preservedTopKey = "$($list.TopItem.Tag.Game)|$($list.TopItem.Tag.Key)" }
    }
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
    $restoredTopItem = $null
    if ($PreserveViewport -and $list.Items.Count -gt 0) {
        if ($preservedTopKey) {
            foreach ($item in $list.Items) {
                if ("$($item.Tag.Game)|$($item.Tag.Key)" -eq $preservedTopKey) {
                    $restoredTopItem = $item
                    break
                }
            }
        }
        if ($null -eq $restoredTopItem -and $preservedTopIndex -ge 0) {
            $restoredTopItem = $list.Items[[Math]::Min($preservedTopIndex, $list.Items.Count - 1)]
        }
    }
    if ($PreserveSelection -and $list.SelectedItems.Count -gt 0) {
        $list.SelectedItems[0].Focused = $true
        if ($null -eq $restoredTopItem) { $list.SelectedItems[0].EnsureVisible() }
        $list.Focus()
    }
    if ($null -ne $restoredTopItem) { $list.TopItem = $restoredTopItem }
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

function Rename-FilteredQueue {
    if ($script:State.Game -eq 'All' -or $creationEditToggle.Checked -or $asiEditToggle.Checked -or $queueFilterBox.SelectedIndex -le 0) {
        [System.Windows.Forms.MessageBox]::Show('Select a specific working queue in the queue filter first.', 'No queue selected', 'OK', 'Information')
        return
    }
    if ($script:State.Dirty) {
        [System.Windows.Forms.MessageBox]::Show('Save or reload current changes before renaming a queue.', 'ME3Tweaks Organizer', 'OK', 'Warning')
        return
    }
    $stage = [int]$queueFilterBox.SelectedItem.Stage
    if ($stage -le 0 -or -not $script:State.Queues.ContainsKey([string]$stage)) { return }
    $oldName = [string]$script:State.StageNames[[string]$stage]
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the new queue name:', 'Rename managed queue', $oldName).Trim()
    if (-not $newName -or $newName -ceq $oldName) { return }
    if ($newName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        [System.Windows.Forms.MessageBox]::Show('The queue name contains characters that cannot be used in a file name.', 'Invalid queue name', 'OK', 'Error')
        return
    }

    $queueInfo = $script:State.Queues[[string]$stage]
    $oldPath = (Resolve-Path -LiteralPath $queueInfo.Path).Path
    $queueDirectory = Split-Path $oldPath -Parent
    $resolvedQueueRoot = [System.IO.Path]::GetFullPath($script:QueueRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $resolvedInactiveRoot = [System.IO.Path]::GetFullPath($script:InactiveQueueRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $allowedDirectory = $queueDirectory -ieq $resolvedQueueRoot -or
        $queueDirectory.StartsWith($resolvedInactiveRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $allowedDirectory) { throw "Refusing to rename a queue outside the managed queue directories: $oldPath" }
    $fileName = if ($script:State.SetId -eq 'default') {
        "$($script:State.Game).$stage - $newName.biq2"
    } else {
        "$($script:State.Game).$($script:State.SetId).$stage - $newName.biq2"
    }
    $newPath = Join-Path $queueDirectory $fileName
    if ($newPath -ine $oldPath -and (Test-Path -LiteralPath $newPath)) {
        [System.Windows.Forms.MessageBox]::Show('A queue file with the resulting name already exists.', 'Queue file already exists', 'OK', 'Error')
        return
    }

    $queueName = if ($script:State.SetId -eq 'default') {
        "$($script:State.Game).$stage - $newName"
    } else {
        "$($script:State.Game) [$($script:State.SetName)] $stage - $newName"
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Rename queue '$oldName' to '$newName'?`r`n`r`nThe queue contents and install order will not change. A backup will be created first.",
        'Confirm queue rename',
        'YesNo',
        'Question'
    )
    if ($answer -ne 'Yes') { return }

    $backupRoot = Join-Path $script:QueueRoot ("OrganizerBackups\{0}-rename-{1}-{2}-{3}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:State.Game, $script:State.SetId, $stage)
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    Copy-Item -LiteralPath $oldPath -Destination (Join-Path $backupRoot (Split-Path $oldPath -Leaf))

    $queueInfo.Data.queuename = $queueName
    $queueInfo.Data.organizerName = $newName
    $queueInfo.Data.description = "Organizer-managed install group: $newName"
    $queueInfo.Data.ImporterDescription = "Organizer-managed $($script:State.Game) install group: $newName.`r`n`r`nImporting will add this install group to Batch Installer. This does not import any listed mods."
    $json = ($queueInfo.Data | ConvertTo-Json -Depth 30) + [Environment]::NewLine
    if ($newPath -ieq $oldPath) {
        [System.IO.File]::WriteAllText($oldPath, $json, [System.Text.UTF8Encoding]::new($false))
        $fileName = Split-Path $oldPath -Leaf
    } else {
        [System.IO.File]::WriteAllText($newPath, $json, [System.Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $oldPath
    }
    Set-QueueRegistryEntry -Game $script:State.Game -SetId $script:State.SetId -SetName $script:State.SetName -Order $stage -Name $newName -QueueName $queueName -FileName $fileName
    Save-QueueRegistry
    $script:State = Get-GameState -Game $script:State.Game -SetId $script:State.SetId
    Refresh-QueueSelectors
    for ($index = 1; $index -lt $queueFilterBox.Items.Count; $index++) {
        if ([int]$queueFilterBox.Items[$index].Stage -eq $stage) { $queueFilterBox.SelectedIndex = $index; break }
    }
    Refresh-List
    [System.Windows.Forms.MessageBox]::Show("Queue renamed.`r`n`r`nBackup:`r`n$backupRoot", 'Queue renamed', 'OK', 'Information')
}

function Show-BackupManager {
    $backupRoot = Join-Path $script:QueueRoot 'OrganizerBackups'
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    $dialog = [System.Windows.Forms.Form]@{ Text = 'Organizer Backup Manager'; Width = 900; Height = 520; StartPosition = 'CenterParent'; MinimizeBox = $false; MaximizeBox = $false }
    if (Test-Path -LiteralPath $iconPath) { $dialog.Icon = [System.Drawing.Icon]::new($iconPath) }
    $backupList = [System.Windows.Forms.ListView]@{ Left = 12; Top = 12; Width = 858; Height = 410; View = 'Details'; FullRowSelect = $true; GridLines = $true; MultiSelect = $true; HideSelection = $false }
    [void]$backupList.Columns.Add('Backup', 430)
    [void]$backupList.Columns.Add('Modified', 175)
    [void]$backupList.Columns.Add('Queue files', 95)
    [void]$backupList.Columns.Add('Size', 120)
    $restoreButton = [System.Windows.Forms.Button]@{ Text = 'Restore selected'; Left = 12; Top = 435; Width = 180; Height = 32; Enabled = $false }
    $deleteBackupButton = [System.Windows.Forms.Button]@{ Text = 'Delete selected'; Left = 202; Top = 435; Width = 180; Height = 32; Enabled = $false }
    $backupSelectionHint = [System.Windows.Forms.Label]@{ Text = 'Use Ctrl or Shift to select multiple backups.'; Left = 400; Top = 444; Width = 275; Height = 24 }
    $closeBackupButton = [System.Windows.Forms.Button]@{ Text = 'Close'; Left = 690; Top = 435; Width = 180; Height = 32 }
    $dialog.Controls.AddRange(@($backupList, $restoreButton, $deleteBackupButton, $backupSelectionHint, $closeBackupButton))

    $updateBackupButtons = {
        $selectionCount = $backupList.SelectedItems.Count
        $restoreButton.Enabled = $selectionCount -eq 1
        $deleteBackupButton.Enabled = $selectionCount -gt 0
        $deleteBackupButton.Text = if ($selectionCount -gt 1) { "Delete selected ($selectionCount)" } else { 'Delete selected' }
    }

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
        & $updateBackupButtons
    }
    & $refreshBackups
    $backupList.add_SelectedIndexChanged({ & $updateBackupButtons })

    $restoreButton.add_Click({
        if ($backupList.SelectedItems.Count -ne 1) { return }
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
        $selectedItems = @($backupList.SelectedItems)
        $selectionCount = $selectedItems.Count
        $deleteDescription = if ($selectionCount -eq 1) { "backup '$($selectedItems[0].Text)'" } else { "$selectionCount selected backups" }
        $answer = [System.Windows.Forms.MessageBox]::Show("Permanently delete $deleteDescription?`r`n`r`nThis cannot be undone.", 'Confirm backup deletion', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $resolvedRoot = (Resolve-Path -LiteralPath $backupRoot).Path
        $resolvedDirectories = [System.Collections.Generic.List[string]]::new()
        foreach ($selectedItem in $selectedItems) {
            $resolvedDirectory = (Resolve-Path -LiteralPath ([string]$selectedItem.Tag)).Path
            if ((Split-Path $resolvedDirectory -Parent) -ne $resolvedRoot) { throw "Refusing to delete a directory outside OrganizerBackups: $resolvedDirectory" }
            $resolvedDirectories.Add($resolvedDirectory)
        }
        foreach ($resolvedDirectory in $resolvedDirectories) { [System.IO.Directory]::Delete($resolvedDirectory, $true) }
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
    Clear-AutoSortReview -State $script:State
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
    Clear-AutoSortReview -State $script:State
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    $sortBox.SelectedIndex = 1
    Refresh-List
}

function Show-AutoSortSummary {
    param($Plan, [string]$ScopeText)

    $reviewKeys = @($Plan.Review.Keys)
    $edgeCount = if ($null -eq $Plan.EdgeCount) { 0 } else { [int]$Plan.EdgeCount }
    $message = "Auto-sort completed for $ScopeText.`r`n`r`n$($Plan.Ordered.Count) mods sorted using $edgeCount dependency relationships."
    if (-not $reviewKeys.Count) {
        $message += "`r`n`r`nNo unresolved ordering cases were found."
        [System.Windows.Forms.MessageBox]::Show($message, 'Auto-sort completed', 'OK', 'Information')
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($reviewKeys | Sort-Object { $script:State.Records[$_].Name } | Select-Object -First 20)) {
        $record = $script:State.Records[$key]
        $lines.Add("- $($record.Name): $(@($Plan.Review[$key] | Sort-Object) -join '; ')")
    }
    if ($reviewKeys.Count -gt 20) { $lines.Add("- ... and $($reviewKeys.Count - 20) more") }
    $message += "`r`n`r`n$($reviewKeys.Count) mods need manual review and are marked yellow:`r`n`r`n$($lines -join "`r`n")"
    [System.Windows.Forms.MessageBox]::Show($message, 'Auto-sort completed with review items', 'OK', 'Warning')
}

function Invoke-DependencyAutoSort {
    param([ValidateSet('Queue', 'Set')][string]$Mode)

    if (-not $script:State -or $script:State.Game -eq 'All' -or $asiEditToggle.Checked -or $creationEditToggle.Checked) { return }
    $selectedKeys = @{}; foreach ($item in $list.SelectedItems) { $selectedKeys[$item.Tag.Key] = $true }

    if ($Mode -eq 'Queue') {
        if ($queueFilterBox.SelectedIndex -le 0 -or [int]$queueFilterBox.SelectedItem.Stage -le 0) { return }
        $stage = [int]$queueFilterBox.SelectedItem.Stage
        $queueName = "$($script:State.Game).$stage - $($script:State.StageNames[[string]$stage])"
        $records = @($script:State.Records.Values | Where-Object { $null -ne $_.Target -and [int]$_.Target -eq $stage })
        if ($records.Count -lt 2) {
            [System.Windows.Forms.MessageBox]::Show("$queueName contains fewer than two mods, so there is nothing to sort.", 'Auto-sort', 'OK', 'Information')
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "This will overwrite the manual order of every mod in:`r`n`r`n$queueName`r`n`r`nDependencies and local rules take priority. Mount ID and mod name are used as the baseline where no dependency dictates the order.`r`n`r`nChanges remain unsaved until you click Save queues. Continue?",
            'Dependency-aware auto-sort', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $plan = Get-AutoSortPlan -State $script:State -Records $records
        for ($index = 0; $index -lt $plan.Ordered.Count; $index++) { $plan.Ordered[$index].QueueOrders[$stage] = $index }
        Set-AutoSortReview -State $script:State -Plan $plan
        $script:State.Dirty = $true
        Update-StateStatus -State $script:State
        $sortBox.SelectedIndex = 1
        Refresh-List -PreserveSelection $selectedKeys -PreserveViewport
        Show-AutoSortSummary -Plan $plan -ScopeText $queueName
        return
    }

    $stages = @($script:State.StageNames.Keys | Where-Object { [int]$_ -gt 0 } | Sort-Object { [int]$_ } | ForEach-Object { [int]$_ })
    $records = @($script:State.Records.Values | Where-Object { $null -ne $_.Target })
    if ($records.Count -lt 2 -or -not $stages.Count) {
        [System.Windows.Forms.MessageBox]::Show('The current set contains fewer than two assigned mods, so there is nothing to sort.', 'Advanced auto-sort', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "ADVANCED OPTION`r`n`r`nThis can move mods between every working queue in the '$($script:State.SetName)' set for $($script:State.Game). Existing queue categories and names may no longer match their contents.`r`n`r`nThe Creation List is not changed. Existing mod counts per queue are retained, but all working queue assignments and manual orders are rebuilt from the dependency-aware result.`r`n`r`nChanges remain unsaved until you click Save queues; Reload discards them. Continue?",
        'Advanced cross-queue auto-sort', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $stageCounts = @{}
    foreach ($stage in $stages) { $stageCounts[$stage] = @($records | Where-Object { [int]$_.Target -eq $stage }).Count }
    $plan = Get-AutoSortPlan -State $script:State -Records $records
    foreach ($record in $records) {
        foreach ($queueOrderStage in @($record.QueueOrders.Keys | Where-Object { [int]$_ -gt 0 })) { $record.QueueOrders.Remove($queueOrderStage) }
    }
    $recordIndex = 0
    foreach ($stage in $stages) {
        for ($queueIndex = 0; $queueIndex -lt $stageCounts[$stage]; $queueIndex++) {
            $record = $plan.Ordered[$recordIndex++]
            $record.Target = [Nullable[int]]$stage
            $record.Memberships.Clear()
            $record.Memberships.Add($stage)
            $record.QueueOrders[$stage] = $queueIndex
        }
    }
    Set-AutoSortReview -State $script:State -Plan $plan
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    $sortBox.SelectedIndex = 1
    Refresh-List -PreserveSelection $selectedKeys -PreserveViewport
    Show-AutoSortSummary -Plan $plan -ScopeText "$($script:State.Game) set '$($script:State.SetName)'"
}

function Show-AutoSortDialog {
    if (-not $script:State -or $script:State.Game -eq 'All' -or $asiEditToggle.Checked -or $creationEditToggle.Checked) { return }
    $hasCurrentQueue = $queueFilterBox.SelectedIndex -gt 0 -and [int]$queueFilterBox.SelectedItem.Stage -gt 0
    $currentQueueName = if ($hasCurrentQueue) { [string]$queueFilterBox.SelectedItem.Text } else { 'Select a specific queue in the queue filter first.' }

    $dialog = [System.Windows.Forms.Form]@{ Text = 'Dependency-aware auto-sort'; Width = 650; Height = 370; StartPosition = 'CenterParent'; MinimizeBox = $false; MaximizeBox = $false; FormBorderStyle = 'FixedDialog' }
    if (Test-Path -LiteralPath $iconPath) { $dialog.Icon = [System.Drawing.Icon]::new($iconPath) }
    $intro = [System.Windows.Forms.Label]@{ Text = 'Choose how broadly the organizer may change the order. Dependencies and local rules take priority; Mount ID and name provide the remaining baseline order.'; Left = 18; Top = 18; Width = 595; Height = 48 }
    $queueRadio = [System.Windows.Forms.RadioButton]@{ Text = 'Sort only the currently filtered queue (recommended)'; Left = 18; Top = 76; Width = 595; Height = 24; Enabled = $hasCurrentQueue; Checked = $hasCurrentQueue }
    $queueDescription = [System.Windows.Forms.Label]@{ Text = $currentQueueName; Left = 40; Top = 103; Width = 570; Height = 30; ForeColor = [System.Drawing.Color]::DimGray }
    $setRadio = [System.Windows.Forms.RadioButton]@{ Text = 'Advanced: sort across all working queues for this game in the current set'; Left = 18; Top = 145; Width = 595; Height = 24; Checked = -not $hasCurrentQueue }
    $setDescription = [System.Windows.Forms.Label]@{ Text = 'This can move mods between queues and may make their category names inaccurate. Queue sizes are retained. The Creation List remains untouched.'; Left = 40; Top = 173; Width = 570; Height = 52; ForeColor = [System.Drawing.Color]::DarkRed }
    $reviewHint = [System.Windows.Forms.Label]@{ Text = 'Ambiguous, missing, or cyclic dependencies are placed as late as possible, marked yellow, and listed after sorting.'; Left = 18; Top = 232; Width = 595; Height = 42 }
    $startButton = [System.Windows.Forms.Button]@{ Text = 'Continue'; Left = 405; Top = 285; Width = 100; Height = 32; DialogResult = 'OK' }
    $cancelButton = [System.Windows.Forms.Button]@{ Text = 'Cancel'; Left = 515; Top = 285; Width = 100; Height = 32; DialogResult = 'Cancel' }
    $dialog.Controls.AddRange(@($intro, $queueRadio, $queueDescription, $setRadio, $setDescription, $reviewHint, $startButton, $cancelButton))
    $dialog.AcceptButton = $startButton; $dialog.CancelButton = $cancelButton
    $result = $dialog.ShowDialog($form)
    $mode = if ($queueRadio.Checked) { 'Queue' } else { 'Set' }
    $dialog.Dispose()
    if ($result -eq 'OK') { Invoke-DependencyAutoSort -Mode $mode }
}

function Update-MoveButtons {
    $enabled = -not $asiEditToggle.Checked -and $script:State -and $script:State.Game -ne 'All' -and ($creationEditToggle.Checked -or $queueFilterBox.SelectedIndex -gt 0)
    $moveUpButton.Enabled = $enabled
    $moveDownButton.Enabled = $enabled
    $mountOrderButton.Enabled = $enabled
    $dependencySortButton.Enabled = -not $asiEditToggle.Checked -and $script:State -and $script:State.Game -ne 'All' -and -not $creationEditToggle.Checked -and @($script:State.StageNames.Keys | Where-Object { [int]$_ -gt 0 }).Count -gt 0
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
    Clear-AutoSortReview -State $script:State
    $script:State.Dirty = $true
    Update-StateStatus -State $script:State
    Refresh-List -PreserveSelection $selectedKeys
})

$list.add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -eq 0) {
        $script:UpdatingCreationToggle = $true; $creationToggle.CheckState = 'Unchecked'; $script:UpdatingCreationToggle = $false
        $selectedLabel.Text = if ($asiEditToggle.Checked) { 'No ASI plugin selected' } else { 'No mod selected' }
        $pathLabel.Text = ''; $dependencyBox.Text = ''; $manageRulesButton.Enabled = $false; Set-NexusLink; Update-AssignButtonState; return
    }
    $records = @($list.SelectedItems | ForEach-Object { $_.Tag })
    $manageRulesButton.Enabled = -not $asiEditToggle.Checked -and $records.Count -eq 1 -and $records[0].Facts.Exists
    if ($asiEditToggle.Checked) {
        Set-NexusLink
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
        Set-NexusLink -Url $record.Facts.ModSite
        $targetBox.SelectedIndex = 0
        if ($null -ne $record.Target) {
            for ($index = 1; $index -lt $targetBox.Items.Count; $index++) {
                if ([int]$targetBox.Items[$index].Stage -eq [int]$record.Target) { $targetBox.SelectedIndex = $index; break }
            }
        }
        $shownOrder = if ($creationEditToggle.Checked) { if ($record.InCreation) { (Get-RecordCreationOrder $record) + 1 } else { 'Not in Creation' } } elseif ($null -ne $record.Target) { (Get-RecordQueueOrder $record) + 1 } else { 'Unassigned' }
        $dependencyBox.Text = "Creation queue: $(if($record.InCreation){'Yes'}else{'No'})`r`nMod version: $(if($record.Facts.ModVersion){$record.Facts.ModVersion}else{'Unknown'})`r`nMount ID: $(if($record.Facts.MountIds.Count){$record.Facts.MountIds -join ', '}else{'None'})`r`nQueue order: $shownOrder`r`n`r`nStatus:`r`n$($record.Status)`r`n`r`nProvides:`r`n$(if($record.Facts.Provided.Count){$record.Facts.Provided -join "`r`n"}else{'None'})`r`n`r`nRequired dependencies:`r`n$(if($record.Facts.Required.Count){$record.Facts.Required -join "`r`n"}else{'None'})`r`n`r`nOptional or patch detection:`r`n$(if($record.Facts.Conditional.Count){$record.Facts.Conditional -join "`r`n"}else{'None'})`r`n`r`nIncompatible DLC:`r`n$(if($record.Facts.Incompatible.Count){$record.Facts.Incompatible -join "`r`n"}else{'None'})`r`n`r`nLocal organizer rules:`r`n$(Get-LocalRuleDetailsText $record)`r`n`r`nDescription:`r`n$(if($record.Facts.Description){$record.Facts.Description}else{'No description available.'})"
    } else {
        $pathLabel.Text = ''; $targetBox.SelectedIndex = 0
        $manageRulesButton.Enabled = $false
        Set-NexusLink
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
    Clear-AutoSortReview -State $script:State
    Update-StateStatus -State $script:State
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
    $selectedKeys = @{}
    foreach ($record in $records) { $selectedKeys[$record.Key] = $true }
    $target = if ($targetBox.SelectedIndex -le 0) { $null } else { [Nullable[int]]$targetBox.SelectedItem.Stage }
    Set-RecordTarget -State $script:State -Records $records -Target $target
    Refresh-List -PreserveSelection $selectedKeys -PreserveViewport
})
$newQueueButton.add_Click({ New-ManagedQueue })
$renameQueueButton.add_Click({ Rename-FilteredQueue })
$manageRulesButton.add_Click({ Show-LocalRuleManager })
$deleteQueueButton.add_Click({ Remove-FilteredQueue })
$backupButton.add_Click({ Show-BackupManager })
$moveUpButton.add_Click({ Move-SelectedMods -Direction Up })
$moveDownButton.add_Click({ Move-SelectedMods -Direction Down })
$mountOrderButton.add_Click({ Set-QueueOrderByMountId })
$dependencySortButton.add_Click({ Show-AutoSortDialog })
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
