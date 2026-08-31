# Changelog

## 1.0.3 - 2026-08-31

- Added safe renaming for Organizer-managed working queues, including automatic backups.
- Added local per-mod rules for additional requirements, load-after relationships, incompatibilities, and mods integrated into another mod.
- Added optional subject- or target-version conditions to local rules.
- Added dependency-aware auto-sort for the currently filtered queue.
- Added an explicitly warned advanced auto-sort mode across all working queues for the selected game and set. Queue sizes are retained and the Creation List remains untouched.
- Added yellow review markers and a post-sort summary for missing, ambiguous, or cyclic dependency relationships.
- Added direct Nexus links for mods whose `moddesc.ini` declares a supported `modsite` URL.
- Added multi-selection to the Backup Manager for deleting several backups at once.
- Preserved the current list position after assigning mods to a queue.
- Expanded regression tests for ASI assignments, local rules, version conditions, queue metadata, and dependency sorting.

## 1.0.0 - 2026-08-25

- Initial public release.
- Added Organizer-managed queues for LE1, LE2, and LE3.
- Added global queue sets and independent ME3Tweaks activation.
- Added editable Creation Lists and per-queue ASI plugin selection.
- Added manual and Mount ID queue ordering, dependency checks, compatibility warnings, explicit incompatibility detection, and missing-mod cleanup.
- Added restore-before-install settings, automatic backups, and the Backup Manager.
- Added the portable self-contained Windows distribution with English Readme and PDF user guide.
