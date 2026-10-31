# Ghost workspace repair

Goal: stop empty monitor-0 cards produced by uninitialized Quickshell workspace objects, without losing real windows or genuine unresolved workspaces.

Evidence: /home/admin/.local/state/omarchy/monitor-diagnostics/capture-20261031-1137/confirmed-findings.md. The live incident contains name-only objects with id=-1, monitor=null, lastIpcObject={}. A delayed client response recreated them after deletion/renumbering.

Implementation:
1. Add model regressions for empty orphan descriptors, window-backed uninitialized workspaces, hydrated named/empty workspaces and numbered initialization. Confirm failure first.
2. Ignore only uninitialized id=-1 descriptors lacking IPC data and a native monitor when collecting authoritative workspace descriptors. Keep record-backed groups reachable. Refresh scope on changeworkspaceid. Show ? for an unresolved monitor index instead of 0.
3. Run affected model, scope and QML tests; replay the controlled stale-response race using the corrected production model. Review the whole diff.
4. Commit source changes, select this checkout with the supported local dev switch, inspect both live dock surfaces, retain diagnostics, and record/commit the Omarchy configuration change. Do not edit deployed plugin files or merge/push main.

Scope: this is a Dockrail mitigation; Quickshell still retains stale internal objects. A cache fix can be pursued independently. No full list filtering: legitimate unresolved window groups must remain visible.
