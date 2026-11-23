# Agent instructions

## Releases

Releases are cut by pushing a `vX.Y.Z` tag. `.github/workflows/release.yml` builds the IPA, creates the GitHub release and adds the version to `altstore-source.json`. The workflow uses `--generate-notes`, which only produces a "Full Changelog" compare link, so every release needs a real description and changelog added by hand.

When creating a release:

1. Push the tag and wait for the Release workflow to finish.
2. Read the commits since the previous tag (`git log vPREV..vX.Y.Z`) and their diffs. Commit bodies are often empty, so check the code to describe changes accurately.
3. Replace the release notes with `gh release edit vX.Y.Z --notes-file notes.md`, using this shape:

   ```markdown
   One or two sentences on what this release brings and why it matters to players.

   ## Changelog

   ### New
   - User-facing features and settings, named as they appear in the app.

   ### Fixes
   - What was wrong and what happens now.

   ### Notes
   - Migrations, changed defaults, device requirements or anything users should know. Omit if empty.

   **Full Changelog**: https://github.com/reefbarman/iPlayNow/compare/vPREV...vX.Y.Z
   ```

   For the first release, leave out the Full Changelog link and describe what the app does.

Write for players, not developers: describe behaviour, not internals. Leave out `docs:` and `chore:` commits unless they affect users. Omit empty sections.

4. Add the same New/Fixes/Notes entries to the top of `CHANGELOG.md` under `## vX.Y.Z (YYYY-MM-DD)`, replacing "No releases yet." on the first one.

## Documentation

`README.md` describes every headline feature and how to use the app. When a change adds or changes something players can see, update it in the same change. Use the names, defaults and settings paths the app shows.

## OpenNOW code

Only `NVSTKit/Sources/NVST` comes from OpenNOW. Mark every edit to those files with an `// iPlayNow:` comment. Nothing in the app's UI should mention OpenNOW.
