# tooling-sync branch — NEVER merge this into master or any working branch

This branch exists only to move personal dev tooling (Android build/deploy
scripts + their docs) between this developer's two machines via `git
push`/`pull`. It intentionally carries no relation to feature work and must
never appear in a PR diff or reach `master`.

What's here: `forge-gui-android/scripts/*.ps1`, `forge-gui-android/scripts/ANDROID_BUILD_SETUP.md`.
Full usage instructions are in that `.md` file.

What's deliberately NOT here (see `forge-gui-android/scripts/.gitignore` on
this branch): `.device-state.json`, `backups/` — per-machine state and real
save-game data, never belongs in git history on any branch.

Also never put here: the signing keystore itself
(`%USERPROFILE%\.forge-android-build\debug.keystore`). That's private key
material — transfer it machine-to-machine by hand (USB/cloud/scp), never via
git, not even on this private branch. See the `.md` file, section on keystore
sync.
