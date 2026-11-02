// FDM-1068: managed-storage classification helpers in DockIconModel.
// Copying/migration/prune behavior lives in scripts/dockrail_icons.py tests;
// these assertions pin the JS/Python contract both sides rely on.
import assert from "node:assert/strict"
import { hostHarness, loadModel, plain } from "./host_harness.mjs"

const icons = loadModel("DockIconModel")
const root = "/home/dock/.local/share/dockrail"
const prefix = "file:///" + "home/dock/.local/share/dockrail".split("/").map(encodeURIComponent).join("/") + "/icons/"

assert.equal(icons.managedIconPrefix(root), prefix)
assert.equal(icons.managedIconPrefix(""), "")
assert.equal(icons.managedIconPrefix("relative/root"), "")
assert.equal(icons.managedIconPrefix("/root with spaces/dockrail"),
  "file:///root%20with%20spaces/dockrail/icons/")

const managedPng = prefix + "ghostty-0123456789ab.png"
// Minted names are sanitized ASCII (see dockrail_icons.managed_file_name);
// keys with spaces mint "my-app-…", never percent-encoded segments.
const managedSvg = prefix + "my-app-fedcba987654.svg"
assert.equal(icons.isManagedIconSource(managedPng, root), true)
assert.equal(icons.isManagedIconSource(managedSvg, root), true)
assert.equal(icons.isManagedIconSource(prefix + "user-placed.png", root), true)
assert.equal(icons.isManagedIconSource("/home/dock/Pictures/a.png", root), false)
assert.equal(icons.isManagedIconSource("https://x/a.png", root), false)
assert.equal(icons.isManagedIconSource("bad", root), false)
assert.equal(icons.isManagedIconSource(managedPng, ""), false)
// A managed-looking name outside the managed dir is not managed storage.
assert.equal(icons.isManagedIconSource("/tmp/icons/ghostty-0123456789ab.png", root), false)

for (const name of ["ghostty-0123456789ab.png", "my-app-fedcba987654.svg", "a.b-c_d-0123456789ab.svg"])
  assert.equal(icons.isManagedIconFileName(name), true, name)
for (const name of ["", null, "ghostty-0123456789ab.png.bak", "0123456789ab.png",
  "ghostty-0123456789ab.jpeg", "ghostty-0123456789ab.PNG", "ghostty-0123456.svg", "-0123456789ab.png",
  "ghostty-0123456789ab.svg/extra"])
  assert.equal(icons.isManagedIconFileName(name), false, String(name))

const settings = {
  iconOverrides: {
    "org.ghostty": managedPng,
    "org.missing": "/nonexistent/legacy.png",
    "org.plain": "file:///home/dock/Pictures/plain.svg",
    "org.bad": "not-a-path"
  },
  windowIconOverrides: [
    { appId: "org.ghostty", titlePattern: "*solar*", source: managedSvg },
    { appId: "org.ghostty", titlePattern: "*gone*", source: "/nonexistent/gone.svg" }
  ]
}
assert.deepEqual(plain(icons.referencedManagedIconFiles(settings, root)),
  ["ghostty-0123456789ab.png", "my-app-fedcba987654.svg"])
assert.deepEqual(plain(icons.referencedManagedIconFiles({}, root)), [])
assert.deepEqual(plain(icons.referencedManagedIconFiles({
  iconOverrides: { "not-managed": "/tmp/a.png" } }, root)), [])
// Managed-looking file names referenced outside the managed dir never count.
assert.deepEqual(plain(icons.referencedManagedIconFiles({
  iconOverrides: { evil: "/tmp/icons/ghostty-0123456789ab.png" } }, root)), [])

assert.equal(icons.hasUnmanagedIconSources(settings, root), true)
assert.equal(icons.hasUnmanagedIconSources({
  iconOverrides: { "org.ghostty": managedPng },
  windowIconOverrides: [{ appId: "a", titlePattern: "*b*", source: managedSvg }]
}, root), false)
assert.equal(icons.hasUnmanagedIconSources({
  iconOverrides: { "org.missing": "/nonexistent/legacy.png" }
}, root), true)
assert.equal(icons.hasUnmanagedIconSources({}, root), false)
assert.equal(icons.hasUnmanagedIconSources({ iconOverrides: { bad: "nope" } }, root), false)

// Host migration patch: only helper-reported changes whose live raw value
// still matches are applied; concurrent edits and missing sources stay put.
const { host } = hostHarness({
  pinned: ["code"],
  iconOverrides: {
    "org.ghostty": "/art/ghostty.png",
    "org.stale": "/art/stale.png",
    "org.missing": "/nonexistent/legacy.svg"
  },
  windowIconOverrides: [
    { appId: "org.ghostty", titlePattern: "*solar*", source: "/art/sun.svg" }
  ]
})
const managedA = prefix + "ghostty-0123456789ab.png"
const managedB = prefix + "stale-fedcba987654.png"
const managedSun = prefix + "solar-aaaabbbbcccc.svg"
const live = host.settings
const patch = host.iconMigrationPatch([
  { container: "iconOverrides", locator: "org.ghostty", from: "/art/ghostty.png", to: managedA },
  { container: "iconOverrides", locator: "org.stale", from: "/art/CHANGED.png", to: managedB },
  { container: "iconOverrides", locator: "org.absent", from: "/art/x.png", to: managedB },
  { container: "windowIconOverrides",
    locator: { appId: "org.ghostty", titlePattern: "*solar*" },
    from: "/art/sun.svg", to: managedSun },
  { container: "windowIconOverrides",
    locator: { appId: "org.ghostty", titlePattern: "*gone*" },
    from: "/art/gone.svg", to: managedSun }
], live)
assert.deepEqual(plain(patch), {
  iconOverrides: {
    "org.ghostty": managedA,
    "org.stale": "/art/stale.png",
    "org.missing": "/nonexistent/legacy.svg"
  },
  windowIconOverrides: [
    { appId: "org.ghostty", titlePattern: "*solar*", source: managedSun }
  ]
})
// Unchanged live settings when nothing verifies.
assert.equal(host.iconMigrationPatch(
  [{ container: "iconOverrides", locator: "org.stale",
     from: "/art/CHANGED.png", to: managedB }], live), null)
assert.equal(host.iconMigrationPatch([], live), null)
// Raw values are compared after source normalization on both sides.
assert.deepEqual(plain(host.iconMigrationPatch([
  { container: "iconOverrides", locator: "org.ghostty",
    from: "file:///art/ghostty.png", to: managedA }
], live).iconOverrides)["org.ghostty"], managedA)
console.log("Managed icon storage model contract: PASS")
