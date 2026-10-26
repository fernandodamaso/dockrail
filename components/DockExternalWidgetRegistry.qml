import QtQuick
import QtCore
import Quickshell.Io

// Host-owned discovery adapter for package-manager generated registry metadata.
// Runtime settings contain Widget IDs only; executable URLs are accepted only
// from this bounded SmartDock-owned registry under the XDG data directory.
Item {
  id: root

  property string dataRoot: ""
  readonly property string packageRoot: (root.dataRoot !== ""
    ? root.dataRoot
    : StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/smartdock")
    + "/widgets"
  readonly property string registryPath: packageRoot + "/registry.json"
  property bool registryKnown: false
  property var descriptors: ({})
  property var diagnostics: ({ errors: [] })

  function validId(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 64
      && /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/.test(value)
      && ["constructor", "prototype", "__proto__"].indexOf(value) < 0
  }

  function protectedId(value) {
    return ["demo.display", "demo.lists", "demo.inputs", "demo.actions-states",
      "herdr.agents", "t3.threads"].indexOf(value) >= 0
  }

  function validRevision(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
      && Math.floor(value) === value && value <= 9007199254740991
  }

  function validEntryPath(value) {
    if (typeof value !== "string" || value.length < 5 || value.length > 256
        || value.charAt(0) === "/" || value.slice(-4).toLowerCase() !== ".qml") return false
    var parts = value.split("/")
    if (!parts.length) return false
    for (var i = 0; i < parts.length; ++i) {
      if (!parts[i] || parts[i] === "." || parts[i] === ".." || parts[i].indexOf("\\") >= 0) return false
    }
    if (parts[0] === ".dev") return parts.length >= 3 && root.validId(parts[1])
    return root.validId(parts[0])
  }

  function allowedEntryPrefix(row) {
    if (!row || !root.validId(row.id) || !root.validEntryPath(row.entryPath)) return false
    var parts = row.entryPath.split("/")
    return parts[0] === ".dev" ? parts[1] === row.id : parts[0] === row.id
  }

  function entrySource(row) {
    var packageUrl = String(root.packageRoot)
    if (packageUrl.indexOf("file:") !== 0) packageUrl = "file://" + packageUrl
    return packageUrl + "/" + row.entryPath
      + "?smartdockRev=" + row.entryRevision
  }

  function descriptorFor(row) {
    return {
      id: row.id,
      label: row.name,
      iconName: row.icon,
      available: true,
      status: "ready",
      revision: row.revision,
      manageable: true,
      sourceOwned: false,
      packageType: "external",
      expandedView: null,
      compactView: null,
      popupView: null,
      expandedSource: root.entrySource(row),
      compactSource: "",
      popupSource: "",
      acquire: function(owner) { return root.acquire(row, owner) }
    }
  }

  function acquire(row, owner) {
    var lease = {
      provider: root,
      active: false,
      released: false,
      setActive: function(active, publish) {
        if (lease.released) throw new Error("released external Widget lease reused")
        lease.active = active === true
        if (lease.active && publish) {
          publish({
            status: "ready",
            revision: row.revision,
            data: {
              package: {
                id: row.id,
                name: row.name,
                version: row.version,
                apiVersion: row.apiVersion,
                development: row.development === true
              }
            }
          })
        }
      },
      release: function() {
        if (lease.released) return
        lease.released = true
        lease.active = false
      }
    }
    return lease
  }

  function clear(errorText) {
    root.descriptors = ({})
    root.diagnostics = ({ errors: errorText ? [{ error: errorText }] : [] })
  }

  function loadRegistry(raw) {
    var value
    try {
      if (typeof raw !== "string" || raw.length > 1024 * 1024)
        throw new Error("registry exceeds the 1 MiB runtime limit")
      value = JSON.parse(raw)
      if (!value || Array.isArray(value) || value.schemaVersion !== 1 || value.apiVersion !== 1
          || !Array.isArray(value.packages) || value.packages.length > 128)
        throw new Error("expected Widget registry schema v1")
    } catch (error) {
      root.registryKnown = true
      root.clear(String(error))
      return
    }

    var next = ({})
    var errors = Array.isArray(value.errors) ? value.errors.slice(0, 128) : []
    for (var i = 0; i < value.packages.length; ++i) {
      var row = value.packages[i]
      var errorText = ""
      if (!row || Array.isArray(row) || typeof row !== "object") errorText = "invalid package row"
      else if (!root.validId(row.id)) errorText = "invalid external Widget id"
      else if (root.protectedId(row.id)) errorText = "external package attempted to replace a source-owned Widget"
      else if (Object.prototype.hasOwnProperty.call(next, row.id)) errorText = "duplicate external Widget id"
      else if (row.apiVersion !== 1) errorText = "incompatible Widget package API"
      else if (typeof row.name !== "string" || !row.name || row.name.length > 128) errorText = "invalid Widget name"
      else if (typeof row.icon !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(row.icon)) errorText = "invalid Widget icon"
      else if (typeof row.version !== "string" || !row.version || row.version.length > 64) errorText = "invalid Widget version"
      else if (!root.validRevision(row.revision)) errorText = "invalid Widget revision"
      else if (!root.allowedEntryPrefix(row))
        errorText = "external Widget entry is outside its SmartDock package namespace"
      else if (typeof row.entryRevision !== "string" || !/^[0-9a-f]{16}$/.test(row.entryRevision))
        errorText = "invalid Widget entry revision"

      if (errorText) {
        errors.push({ id: row && row.id ? String(row.id) : "", error: errorText })
        continue
      }
      next[row.id] = root.descriptorFor(row)
    }
    root.registryKnown = true
    root.descriptors = next
    root.diagnostics = ({ errors: errors.slice(0, 128) })
  }

  FileView {
    id: registryFile
    path: root.registryPath
    watchChanges: true
    printErrors: false
    blockLoading: false
    onLoaded: root.loadRegistry(text())
    onFileChanged: reload()
    onLoadFailed: {
      root.registryKnown = false
      root.clear("")
    }
  }

  // FileView watches normal registry updates. This bounded retry only covers the
  // first package install when registry.json did not exist at shell startup.
  Timer {
    interval: 2000
    repeat: true
    running: !root.registryKnown
    onTriggered: registryFile.reload()
  }
}
