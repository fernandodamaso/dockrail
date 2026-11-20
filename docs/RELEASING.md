# Releasing Dockrail

Use this sequence for every Dockrail release:

1. Work on a feature branch in your own clone of
   https://github.com/fernandodamaso/dockrail. Do not edit an installed
   plugin checkout.
2. Update `manifest.json` and `CHANGELOG.md` together, including the release
   version and date.
3. Run the complete source gate: `omarchy plugin validate .`, every
   `tests/check_*.sh`, Qt Test with `qmltestrunner`, shell syntax checks,
   `qmllint`, `git diff --check`, and the standalone smoke test.
4. Open a pull request into `main` and follow `docs/DELIVERY.md`. Do not
   merge a local feature branch into `main` and push that merge. After the
   pull request lands, `origin/main` is the release commit.
5. Update one installed copy with `omarchy plugin update` and verify that its
   clean `HEAD` equals `origin/main`. Manually verify the dock after the
   update.
6. Create and push an annotated version tag, then publish the matching GitHub
   release.
7. Import upstream changes only on a dedicated branch after reviewing
   conflicts and rerunning the complete validation gate.

Do not edit the installed plugin. It is deployment state and receives changes
only through Git push followed by `omarchy plugin update`.
