Do a Megadesk release. Follow these steps exactly:

## 1. Detect current version

Read the current MARKETING_VERSION from `Megadesk.xcodeproj/project.pbxproj`.

## 2. Ask which version to bump to

Use AskUserQuestion with a single-select question. Header: "Version bump". Show 3 options:
- patch (e.g. 0.5.2 → 0.5.3)
- minor (e.g. 0.5.2 → 0.6.0)
- major (e.g. 0.5.2 → 1.0.0)

Calculate the actual resulting version numbers from the current version and show them in each option's label, like "Patch → 0.5.3".

## 3. Bump the version

Update MARKETING_VERSION in `Megadesk.xcodeproj/project.pbxproj` (both Debug and Release entries) to the new version. Commit with message "Bump version to X.Y.Z".

## 4. Build the DMG

Run `./build-dmg.sh` from the project root. This takes several minutes — wait for it to complete.

If it fails, stop and show the error.

On success, capture from the output:
- The `sparkle:edSignature` value
- The `length` value

## 5. Create GitHub Release

Run:
```
gh release create vX.Y.Z ./megadesk-X.Y.Z.dmg \
  --title "Megadesk X.Y.Z" \
  --notes "..."
```

Use a brief but meaningful release note based on recent commits since the last tag (`git log vPREV..HEAD --oneline`).

## 6. Update docs/appcast.xml

Add a new `<item>` block at the top of the existing items, filling in:
- `<title>Version X.Y.Z</title>`
- `<pubDate>` — today's date in RFC 2822 format
- `<sparkle:version>` — the git commit count (`git rev-list --count HEAD`)
- `<sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>`
- `<sparkle:releaseNotesLink>` — the GitHub release URL
- `enclosure url` — the DMG download URL from GitHub
- `sparkle:edSignature` — from build output
- `length` — from build output

## 7. Commit and push

```
git add docs/appcast.xml
git commit -m "Publish appcast entry for vX.Y.Z"
git push origin main
```

## 8. Done

Show a summary with the release URL.
