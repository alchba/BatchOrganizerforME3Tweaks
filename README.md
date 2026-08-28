# ME3Tweaks Batch Queue Organizer

ME3Tweaks Batch Queue Organizer is an independent Windows companion utility for organizing ME3Tweaks Batch Installer queues for Mass Effect Legendary Edition.

It provides one interface for LE1, LE2, and LE3 working queues, global queue sets, separate Creation Lists, ASI plugin assignments, install order, dependency checks, declared incompatibilities, missing-mod cleanup, and backups.

The Organizer does not install game mods itself. It creates and manages Batch Installer queue files that are used through [ME3Tweaks Mod Manager](https://me3tweaks.com/modmanager).

## Features

- LE1, LE2, and LE3 queue management
- global queue sets with independent ME3Tweaks activation
- separate editable Creation Lists
- per-queue ASI plugin selection
- queue ordering by buttons, drag and drop, or Mount ID baseline
- requirement, compatibility-target, and declared-incompatibility checks
- direct Nexus links read from each mod's `modsite` metadata
- missing-mod cleanup across Organizer-managed sets
- restore-before-install settings
- automatic timestamped backups and a Backup Manager
- portable settings stored next to the application

## Repository Layout

```text
BatchQueueOrganizer.ps1
    Main application and Windows Forms user interface.

BatchQueueOrganizerLauncher/
    Small C# WinForms launcher used to provide a dedicated process, icon,
    taskbar entry, error reporting, and clean child-process shutdown.

Build-BatchQueueOrganizerDistribution.ps1
    Optional local script for creating the self-contained single-file EXE.
```

Generated `Organizer*.json` files are user-specific application data and are intentionally excluded from source control. Compiled binaries, `bin`, `obj`, publish directories, and distribution archives are also ignored.

## Run From Source

The PowerShell application can be started directly on Windows without compiling the C# launcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\BatchQueueOrganizer.ps1 -StorageRoot .
```

On first launch, select `ME3TweaksModManager.exe`. The Organizer uses that location to find the adjacent `mods` and `data` directories.

Running from source creates the local `Organizer*.json` files in the selected storage root. These files may contain local paths and personal queue configuration and must not be committed.

## Optional Launcher Build

Building is not required for reviewing the source code. To compile the launcher, install the .NET 9 SDK and run:

```powershell
dotnet build .\BatchQueueOrganizerLauncher\BatchQueueOrganizerLauncher.csproj -c Release
```

The normal framework-dependent launcher expects `BatchQueueOrganizer.ps1` next to the executable.

To create the public self-contained single-file distribution used by the Nexus release, run:

```powershell
.\Build-BatchQueueOrganizerDistribution.ps1
```

This embeds the PowerShell application and icon into the launcher and publishes a Windows x64 executable under `distribute`.

## Why the Self-Contained EXE Is Much Larger

The PowerShell source and ordinary launcher together are well below 1 MB because they rely on components already installed on the computer.

The public single-file EXE is approximately 48 MB because it is published with `.NET 9` as a self-contained application. The required .NET runtime, Windows Forms assemblies, native hosting components, launcher, icon, and embedded PowerShell script are compressed into one file. This lets users run the Organizer without first installing the matching .NET Desktop Runtime.

Most of the file size is the bundled .NET runtime, not the Organizer source. A framework-dependent release could be much smaller, but every user would then need the correct .NET runtime installed separately.

## Scope and Safety

- Only Organizer-managed queues are edited or deleted.
- Queues created directly in ME3Tweaks Mod Manager are treated as foreign and remain untouched.
- Queue files are backed up before changes are written.
- Creation Lists remain separate from global sets.
- Validation is based on metadata declared by installed mods and cannot identify undeclared conflicts.

## Credits

- Mgamerz for ME3Tweaks Mod Manager and the infrastructure that makes modern Mass Effect mod management possible.
- The ME3Tweaks Mod Manager team and contributors for the Batch Installer, ASI catalog, mod metadata format, development, and maintenance.
- Mod authors who provide accurate requirement and compatibility metadata.

This is an independent companion utility and is not an official component of ME3Tweaks Mod Manager.

## License

See [LICENSE](LICENSE). The source is published for transparency and code review. No ME3Tweaks Mod Manager code, game files, installed mods, or third-party mod assets are included.
