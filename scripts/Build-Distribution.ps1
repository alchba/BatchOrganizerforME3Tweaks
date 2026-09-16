param()

$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectFile = Join-Path $projectRoot 'src\BatchQueueOrganizerLauncher\BatchQueueOrganizerLauncher.csproj'
$publishRoot = Join-Path $projectRoot 'src\BatchQueueOrganizerLauncher\distribution-publish'
$distributionRoot = Join-Path $projectRoot 'distribute'
$distributionExe = Join-Path $distributionRoot 'BatchQueueOrganizer.exe'

if (Test-Path -LiteralPath $publishRoot) {
    $resolvedPublishRoot = [System.IO.Path]::GetFullPath($publishRoot)
    $expectedParent = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'src\BatchQueueOrganizerLauncher'))
    if ((Split-Path $resolvedPublishRoot -Parent) -ne $expectedParent) { throw "Unsafe publish path: $resolvedPublishRoot" }
    Remove-Item -LiteralPath $resolvedPublishRoot -Recurse -Force
}

[void](New-Item -ItemType Directory -Path $distributionRoot -Force)

dotnet publish $projectFile `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:EmbedOrganizerAssets=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -o $publishRoot

if ($LASTEXITCODE -ne 0) { throw "Distribution build failed with exit code $LASTEXITCODE." }

$publishedExe = Join-Path $publishRoot 'BatchQueueOrganizer.exe'
if (-not (Test-Path -LiteralPath $publishedExe)) { throw "Published executable was not found: $publishedExe" }
Copy-Item -LiteralPath $publishedExe -Destination $distributionExe -Force
Remove-Item -LiteralPath $publishRoot -Recurse -Force

$result = Get-Item -LiteralPath $distributionExe
Write-Output "Distribution executable created: $($result.FullName)"
Write-Output ("Size: {0:N1} MB" -f ($result.Length / 1MB))
