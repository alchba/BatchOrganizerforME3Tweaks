# Release Workflow

The GitHub workflow is prepared for future public releases, but it does not run until a version tag is pushed to the repository.

## Before tagging

1. Update the version in `README.md`, `CHANGELOG.md`, and `src/BatchQueueOrganizerLauncher/BatchQueueOrganizerLauncher.csproj`.
2. Build and test locally with `scripts/Build-Distribution.ps1` and the Organizer self-test against a valid ME3Tweaks installation.
3. Review the Nexus description, Readme, PDF guide, and release assets in `docs`.
4. Commit every intended source and documentation change.

## Create a release draft

Create and push an annotated version tag, for example:

```powershell
git tag -a v1.1.1 -m "Batch Queue Organizer for ME3Tweaks v1.1.1"
git push origin main --follow-tags
```

Pushing a tag beginning with `v` starts the **Create Windows release** GitHub Actions workflow. It:

- installs the .NET 9 SDK;
- builds the self-contained `BatchQueueOrganizer.exe`;
- validates the PowerShell source syntax;
- creates a portable release ZIP containing the EXE, Readme, and PDF guide;
- creates a structured source ZIP directly from the tagged Git repository;
- uploads both files to a new **draft** GitHub release.

The release stays a draft so its files, notes, version number, and links can be reviewed before it becomes public. This deliberately leaves publication under the author’s control.

The full Organizer self-test intentionally remains a local release check because it needs a valid ME3Tweaks Mod Manager folder with installed mod metadata. GitHub Actions has no safe access to a user's mod installation.

## After the workflow finishes

Open the draft release in GitHub, review its generated notes and attached files, then publish it when appropriate. Until Nexus external-link approval is available, do not add the GitHub URL to the public Nexus page.
