import QtQuick
import Quickshell
import Quickshell.Io

Scope {
  id: root

  property bool available: false
  property string group: ""
  property var data: null
  property var pending: null
  property var result: null

  readonly property bool busy: request !== null
  readonly property bool loading: busy && request.kind === "list"
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("../process-actions.py")).replace(/^file:\/\//, ""))
  readonly property var view: ({
    group: group, data: data, pending: pending, result: result, busy: busy, loading: loading
  })

  property var request: null
  property int generation: 0
  property bool timedOut: false

  onAvailableChanged: if (!available) clear()

  function clear() {
    generation++
    group = ""
    data = null
    pending = null
    result = null
    refresh.stop()
  }

  function select(name, forClosing) {
    if (!available || !name) return
    if (name === group && !forClosing && (!busy || loading)) {
      clear()
      return
    }
    if (busy || pending) return
    if (group !== name) clear()
    group = name
    result = null
    start("list", null, forClosing)
  }

  function start(kind, targets, forClosing) {
    if (!available || busy || !group) return
    refresh.stop()
    timedOut = false
    request = { kind: kind, generation: generation, forClosing: forClosing === true }
    const args = ["/usr/bin/python3", "-I", scriptPath, kind, group]
    if (targets) args.push(JSON.stringify(targets))
    worker.command = args
    timeout.restart()
    worker.running = true
  }

  function prepareGroup() {
    if (!data || !data.windowsAvailable || data.truncated) return
    const targets = []
    let windows = 0
    let processes = 0
    for (const member of data.members) {
      for (const window of member.windows) {
        targets.push([member.pid, member.start, window.id])
        windows++
      }
      if (member.canTerminate) {
        targets.push([member.pid, member.start])
        processes++
      }
    }
    if (targets.length) pending = { targets: targets, windows: windows, processes: processes }
    else result = { status: "none" }
  }

  function prepareTermination(member) {
    if (busy || pending || !member.canTerminate) return
    result = null
    pending = { targets: [[member.pid, member.start]], pid: member.pid }
  }

  function closeWindow(member, window) {
    if (busy || pending) return
    result = null
    start("apply", [[member.pid, member.start, window.id]])
  }

  function confirm() {
    if (busy || !pending) return
    const targets = pending.targets
    pending = null
    start("apply", targets)
  }

  function finish(exitCode, text) {
    timeout.stop()
    const completed = request
    request = null
    if (!completed || !available || completed.generation !== generation) return

    let reply = null
    try {
      if (exitCode === 0 && text.length <= 512 * 1024) reply = JSON.parse(text)
    } catch (error) {}

    if (completed.kind === "list") {
      data = reply && reply.status === "ok" && Array.isArray(reply.members) ? reply : null
      if (!data) result = { status: "failed" }
      else if (completed.forClosing) prepareGroup()
    } else {
      result = reply || { status: "failed" }
      refresh.restart()
    }
  }

  Timer {
    id: timeout
    interval: 5200
    onTriggered: {
      if (worker.running) {
        root.timedOut = true
        worker.running = false
      } else root.finish(-1, "")
    }
  }

  Timer {
    id: refresh
    interval: 300
    onTriggered: if (!root.pending) root.start("list")
  }

  Process {
    id: worker
    clearEnvironment: true
    environment: ({
      "LANG": "C.UTF-8",
      "LC_ALL": "C.UTF-8",
      "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || ""
    })
    stdout: StdioCollector { id: output }
    onExited: function(exitCode) { root.finish(root.timedOut ? -1 : exitCode, output.text) }
    // Quickshell emits runningChanged alone if the executable cannot start.
    onRunningChanged: if (!running && root.request) root.finish(-1, "")
  }
}
