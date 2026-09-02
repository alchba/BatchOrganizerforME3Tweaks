# ME3Tweaks Batch Queue Organizer

Current version: **1.1.0**

ME3Tweaks Batch Queue Organizer is an independent Windows companion utility for organizing ME3Tweaks Batch Installer queues for Mass Effect Legendary Edition.

It provides one interface for LE1, LE2, and LE3 working queues, global queue sets, separate Creation Lists, ASI plugin assignments, install order, dependency checks, declared incompatibilities, a read-only Dependency Graph View, missing-mod cleanup, recoverable installed-mod deletion, and backups.

The Organizer does not install game mods itself. It creates and manages Batch Installer queue files that are used through [ME3Tweaks Mod Manager](https://me3tweaks.com/modmanager).

Nexus Mods page: [ME3Tweaks Batch Queue Organizer](https://www.nexusmods.com/masseffectlegendaryedition/mods/3399)

## Features

- LE1, LE2, and LE3 queue management
- global queue sets with independent ME3Tweaks activation
- separate editable Creation Lists with their own exclusive ME3Tweaks activation target
- per-queue ASI plugin selection
- queue creation, deletion, and safe renaming with automatic backups
- read-only Dependency Graph View with queue lanes, relationship lines, zoom, focus filters, and left-mouse drag panning
- queue ordering by buttons, drag and drop, Mount ID baseline, or dependency-aware auto-sort
- safe auto-sort for one filtered queue plus an explicitly warned advanced mode across all working queues in a set
- requirement, compatibility-target, and declared-incompatibility checks
- local per-mod rules for additional requirements, load-after relationships, incompatibilities, and mods integrated into another mod
- optional subject- or target-version conditions for local rules
- direct Nexus links read from each mod's `modsite` metadata
- missing-mod cleanup across Organizer-managed sets
- recoverable deletion of installed mods, including removal from every Organizer-managed queue while foreign ME3Tweaks queues remain untouched
- restore-before-install settings
- automatic timestamped backups and a Backup Manager
- canonical queue sets, backups, migration archives, deleted-mod recovery data, and portable settings stored next to the application
- ME3Tweaks-facing queue filenames matched to their visible names so saved install-group choices reuse the existing published projection instead of creating a duplicate; newer ME3Tweaks-saved choices are imported into the canonical Organizer queue on the next launch after an automatic backup

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

Generated `Organizer*.json` files and the `OrganizerQueueSets`, `OrganizerBackups`, `OrganizerMigrationArchive`, and `OrganizerDeletedMods` directories are user-specific application data and are intentionally excluded from source control. Compiled binaries, `bin`, `obj`, publish directories, and distribution archives are also ignored.

## Run From Source

The PowerShell application can be started directly on Windows without compiling the C# launcher:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\BatchQueueOrganizer.ps1 -StorageRoot .
```

On first launch, select `ME3TweaksModManager.exe`. The Organizer uses that location to find the adjacent `mods` and `data` directories.

Running from source creates the local `Organizer*.json` files in the selected storage root. These files may contain local paths and personal queue configuration and must not be committed.

Custom rules are stored in the versioned `OrganizerCustomRules.json` file. They apply to the selected game in every Organizer set and supplement the metadata from `moddesc.ini`; they never modify the installed mod's metadata. A rule may optionally be limited by the installed version of its selected mod or target mod. Without a version condition, it applies to every version.

Supported local relationships are `Requires`, `LoadAfter`, `Incompatible`, and `IntegratedInto`. Dependency-aware auto-sort uses the ordering relationships together with native mod metadata. Local rules remain user-owned data and are intentionally not included in this repository.

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
- Canonical Organizer queues and backups live beside the application. `Active in ME3Tweaks` projects exactly one Organizer target into `mods\BatchModQueues`: either the three Creation Lists or one global set's working queues. Older Organizer subfolders are migrated out automatically.
- Queue files are backed up before changes are written, renamed, or deleted.
- Installed mods are deleted only after an explicit confirmation. Their folders are moved to `OrganizerDeletedMods`, affected Organizer queue references are removed across every set, and foreign ME3Tweaks queues are not changed.
- Creation Lists remain separate from global sets and can be viewed or edited regardless of which activation target is published to ME3Tweaks.
- Dependency Graph View is intentionally read-only and cannot reassign or reorder mods.
- Normal auto-sort changes only the currently filtered working queue. Advanced auto-sort may move mods between every working queue in the selected game and set, while preserving each queue's mod count and leaving the Creation List untouched.
- Dependencies and local load-order rules take priority during auto-sort. Mount ID and mod name provide the baseline where no dependency dictates the order; unresolved or cyclic cases remain marked for manual review.
- Validation uses metadata declared by installed mods plus optional user-defined local rules. It cannot identify conflicts that are absent from both sources.

## Credits

- Mgamerz for ME3Tweaks Mod Manager and the infrastructure that makes modern Mass Effect mod management possible.
- The ME3Tweaks Mod Manager team and contributors for the Batch Installer, ASI catalog, mod metadata format, development, and maintenance.
- Mod authors who provide accurate requirement and compatibility metadata.

This is an independent companion utility and is not an official component of ME3Tweaks Mod Manager.

## License

See [LICENSE](LICENSE). The source is published for transparency and code review. No ME3Tweaks Mod Manager code, game files, installed mods, or third-party mod assets are included.
