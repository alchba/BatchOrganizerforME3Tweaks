Batch Queue Organizer for ME3Tweaks v1.1.0
=======================================

QUICK INSTALLATION

1. Extract the download to a dedicated folder where your Windows account can
   create and update files.
2. Do not run the Organizer directly from a ZIP or another archive.
3. Run BatchQueueOrganizer.exe.
4. On first launch, select ME3TweaksModManager.exe when prompted.

ME3Tweaks Mod Manager is portable and does not need to be installed. The
Organizer uses the selected executable to locate its "mods" and "data"
folders automatically. The EXE is self-contained; no separate PowerShell
script or .NET Desktop Runtime installation is required.

IMPORTANT DATA

Keep the complete Organizer folder when updating or moving the application.
In addition to the generated Organizer*.json files, it can contain:

- OrganizerQueueSets         Canonical Organizer-managed queues for every set
- OrganizerBackups           Timestamped queue backups
- OrganizerMigrationArchive  Duplicate or old Organizer queue copies retained
                              during automatic migration
- OrganizerDeletedMods       Mods removed through the Organizer and retained
                              for recovery

"Active in ME3Tweaks" publishes exactly one Organizer target: either the three
Creation Lists or the working queues from one global set. Select "Creation
Lists" when you want to run the Creation installation, then switch to the
desired global set when you want to run its working queues. Viewing and editing
remain independent of this selection. Queues created directly in ME3Tweaks are
treated as foreign and are never edited or deleted by the Organizer.

If ME3Tweaks saves current install-group choices into an Organizer-published
queue, the Organizer imports that newer saved configuration on its next launch.
The previous canonical queue is backed up before Organizer metadata is restored
and the updated queue is published again.

BASIC USE

- Use List View to assign, order, rename, create, or delete queues and to edit
  Creation Lists, ASI plugins, local rules, and restore-before-install flags.
- Use Dependency Graph View to inspect queues and known dependency,
  compatibility, conflict, and integrated-mod relationships visually. Graph
  View is read-only; drag with the left mouse button to pan.
- Save queue changes before switching profiles or closing the Organizer.
- "Delete selected mods..." removes selected installed mod folders from
  ME3Tweaks and removes their references from every Organizer-managed queue.
  Affected queues are backed up and the mod folders are retained below
  OrganizerDeletedMods for recovery. Foreign ME3Tweaks queues are untouched.

UPDATING

Close the Organizer and replace BatchQueueOrganizer.exe with the new
version. Do not delete the generated JSON files or Organizer data folders.

UNINSTALLATION

Close the Organizer and back up its folder if you may want to restore its
queues later. Deleting the Organizer folder removes the application, settings,
canonical queue sets, backups, migration archives, and recoverable deleted
mods. Already published queue copies in ME3Tweaks are not removed
automatically.

For complete usage instructions, see:
Batch_Queue_Organizer_User_Guide.pdf
