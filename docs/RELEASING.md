# Releasing Dockrail

Use this sequence for every Dockrail release:

1. Work on a feature branch in your own clone of
   https://github.com/fernandodamaso/dockrail. Do not edit an installed
   plugin checkout.
2. Update `manifest.json` and `CHANGELOG.md` together, including the release
   version. Leave the changelog heading as `## 3.1.0 - YYYY-MM-DD` until the
   release pull request is otherwise complete.
3. Run the complete source gate: `omarchy plugin validate .`, every
   `tests/check_*.sh`, Qt Test with `qmltestrunner`, shell syntax checks,
   `qmllint`, `git diff --check`, and the standalone smoke test.
4. Open a pull request into `main` and follow `docs/DELIVERY.md`. Do not
   merge a local feature branch into `main` and push that merge. The last
   commit on that pull request, immediately before merge, replaces
   `YYYY-MM-DD` in `CHANGELOG.md` with the release date. The merge commit is
   the release commit. Do not edit the date after it lands on `main`.
5. Update one installed copy with `omarchy plugin update`, then run
   `omarchy restart shell` before the manual dock check. Verify that the
   installed checkout's clean `HEAD` equals that merge commit on
   `origin/main`.
6. Run the native smoke checklist in `docs/release/3.1.0.md` on that same
   merge SHA. When it passes, tag that SHA and publish the matching GitHub
   release. Do not tag a different commit.
7. Import upstream changes only on a dedicated branch after reviewing
   conflicts and rerunning the complete validation gate.

Do not edit the installed plugin. It is deployment state and receives changes
only through Git push followed by `omarchy plugin update`.
