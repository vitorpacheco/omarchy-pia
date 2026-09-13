import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to the PIA daemon through piactl. Owns every Process so Panel.qml can
// stay a pure view: it reads the properties below and calls the action
// functions, nothing else.
Item {
  id: root

  property var settings: ({})

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property int refreshIntervalSec: Model.intSetting(settings, "refreshIntervalSec", 30, 5, 3600)
  readonly property string ctlSetting: Model.stringSetting(settings, "ctlPath", "")
  readonly property bool backgroundMode: Model.boolSetting(settings, "backgroundMode", true)
  readonly property bool notificationsEnabled: Model.boolSetting(settings, "notifications", true)
  readonly property int maxRecentRegions: Model.intSetting(settings, "maxRecentRegions", 5, 0, 10)

  // Discovery
  property bool installed: false
  property bool checkedInstall: false
  property string ctl: ""

  // Live state from piactl
  property bool daemonUp: false
  property string rawState: ""
  property bool connected: false
  property bool transitioning: false
  property string stateLabel: "Checking…"
  property string region: ""
  property string vpnIp: ""
  property string pubIp: ""
  property string protocol: ""
  property var portForward: ({ active: false, port: 0, label: "Inactive" })
  property bool requestPortForward: false
  property bool allowLan: false
  property var regions: []
  property bool needsLogin: false

  // UI feedback
  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""
  property string pendingRegion: ""
  property string pendingSetting: ""

  // Optimistic on/off so the switch flips the instant it is clicked. -1 means
  // follow the daemon; 0/1 means a toggle is still catching up.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? connected : (_desired === 1)
  readonly property bool busy: transitioning || actionProcess.running || setProcess.running || _desired !== -1
  readonly property string regionLabel: Model.regionLabel(region)
  readonly property string protocolLabel: Model.protocolLabel(protocol)

  signal regionApplied(string id)

  property string _statusOutput: ""
  property string _statusError: ""
  property string _regionsOutput: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _setOutput: ""
  property string _setError: ""
  property string _lastNotifiedState: ""
  property double _lastRegionsRefreshMs: 0
  property string _probedCtlSetting: ""
  property int _monitorRetryMs: 5000

  readonly property string statusScript: "ctl=\"$1\"\n" +
    "for k in connectionstate region vpnip pubip protocol portforward requestportforward allowlan; do\n" +
    "  if v=$(timeout 8 \"$ctl\" get \"$k\" 2>&1); then\n" +
    "    v=${v//$'\\n'/ }\n" +
    "    printf '%s=%s\\n' \"$k\" \"$v\"\n" +
    "  else\n" +
    "    v=${v//$'\\n'/ }\n" +
    "    printf 'error=%s\\n' \"${v:-piactl get $k failed}\"\n" +
    "    exit 1\n" +
    "  fi\n" +
    "done\n"

  readonly property string whichScript: "for c in \"$1\" piactl /opt/piavpn/bin/piactl; do\n" +
    "  [ -n \"$c\" ] || continue\n" +
    "  if p=$(command -v \"$c\" 2>/dev/null) && [ -x \"$p\" ]; then\n" +
    "    printf 'ctl=%s\\n' \"$p\"\n" +
    "    exit 0\n" +
    "  fi\n" +
    "done\n" +
    "exit 1\n"

  // ------------------------------------------------------------ refresh

  function refresh(forceRegions) {
    if (installed) {
      refreshStatus(forceRegions === true)
      return
    }
    if (!whichProcess.running) {
      refreshing = true
      _probedCtlSetting = ctlSetting
      whichProcess.command = ["bash", "-c", whichScript, "pia-which", ctlSetting]
      whichProcess.running = true
    }
  }

  function refreshStatus(forceRegions) {
    if (!installed) return
    var launched = false
    if (!statusProcess.running) {
      _statusOutput = ""
      _statusError = ""
      refreshing = true
      statusProcess.command = ["bash", "-c", statusScript, "pia-status", ctl]
      statusProcess.running = true
      launched = true
    }
    var now = Date.now()
    var stale = now - _lastRegionsRefreshMs > 10 * 60 * 1000
    if ((forceRegions === true || regions.length === 0 || stale) && !regionsProcess.running) {
      _regionsOutput = ""
      _lastRegionsRefreshMs = now
      regionsProcess.command = ["bash", "-c", "exec timeout 8 \"$1\" get regions", "pia-regions", ctl]
      regionsProcess.running = true
      launched = true
    }
    if (launched && !pollWatchdog.running) pollWatchdog.start()
  }

  function resetUnavailable(message, error) {
    daemonUp = false
    connected = false
    transitioning = false
    _desired = -1
    rawState = ""
    stateLabel = message
    vpnIp = ""
    pubIp = ""
    portForward = { active: false, port: 0, label: "Inactive" }
    pendingRegion = ""
    pendingSetting = ""
    lastError = error || ""
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      var message = Model.looksLikeDaemonError(parsed.error) ? "PIA daemon not running" : "Unavailable"
      resetUnavailable(message, Model.elide(parsed.error))
      return
    }
    var v = parsed.values
    var info = Model.stateInfo(v.connectionstate)
    var previousState = rawState

    daemonUp = true
    rawState = info.raw
    connected = info.connected
    transitioning = info.busy
    stateLabel = info.label
    // Reality caught up with the pending toggle — stop overriding.
    if (_desired !== -1 && connected === (_desired === 1)) {
      _desired = -1
      desiredTimeout.stop()
    }
    if (v.region !== undefined) region = String(v.region)
    vpnIp = Model.cleanIp(v.vpnip)
    pubIp = Model.cleanIp(v.pubip)
    protocol = String(v.protocol || "").trim().toLowerCase()
    portForward = Model.portForwardInfo(v.portforward)
    requestPortForward = Model.parseBool(v.requestportforward, requestPortForward)
    allowLan = Model.parseBool(v.allowlan, allowLan)
    if (pendingRegion !== "" && region === pendingRegion) pendingRegion = ""
    if (connected || transitioning) needsLogin = false
    lastError = ""

    maybeNotify(previousState, info)
  }

  function maybeNotify(previousState, info) {
    if (!notificationsEnabled) return
    if (previousState === "" || previousState === info.raw) return
    if (info.raw !== "Connected" && info.raw !== "Disconnected" && info.raw !== "Interrupted") return
    if (_lastNotifiedState === info.raw) return
    _lastNotifiedState = info.raw
    var title = info.raw === "Connected" ? "VPN connected" : (info.raw === "Interrupted" ? "VPN interrupted" : "VPN disconnected")
    var body = info.raw === "Connected" ? regionLabel + (vpnIp !== "" ? " · " + vpnIp : "") : "Private Internet Access"
    Quickshell.execDetached(["notify-send", "-a", "Private Internet Access", "-i", "network-vpn-symbolic",
      "-h", "string:x-canonical-private-synchronous:pia-vpn", title, body])
  }

  function applyRegions(raw) {
    regions = Model.regionEntries(Model.parseRegions(raw))
  }

  // ------------------------------------------------------------ actions

  function toggleVpn() {
    if (!installed) return
    if (active) disconnect()
    else connect()
  }

  function connect() {
    if (!installed || actionProcess.running) return
    _desired = 1
    desiredTimeout.restart()
    var script = backgroundMode
      ? "\"$1\" background enable >/dev/null 2>&1; exec \"$1\" connect"
      : "exec \"$1\" connect"
    runAction(["bash", "-c", script, "pia-connect", ctl], "Connecting…")
  }

  function disconnect() {
    if (!installed || actionProcess.running) return
    _desired = 0
    desiredTimeout.restart()
    runAction([ctl, "disconnect"], "")
  }

  function setRegion(id) {
    var regionId = String(id || "")
    if (!installed || regionId === "" || setProcess.running) return
    if (regionId === region) {
      if (!active) connect()
      return
    }
    pendingRegion = regionId
    runSet([ctl, "set", "region", regionId], "region", "Switching to " + Model.regionLabel(regionId) + "…")
  }

  function setProtocol(value) {
    var proto = String(value || "").toLowerCase()
    if (!installed || (proto !== "wireguard" && proto !== "openvpn") || setProcess.running) return
    runSet([ctl, "set", "protocol", proto], "protocol", "Switching to " + Model.protocolLabel(proto) + "…")
  }

  function toggleProtocol() {
    setProtocol(Model.otherProtocol(protocol))
  }

  function setRequestPortForward(enabled) {
    if (!installed || setProcess.running) return
    var flag = enabled ? "true" : "false"
    runSet([ctl, "set", "requestportforward", flag], "portforward", enabled ? "Requesting port forwarding…" : "Port forwarding off")
  }

  function togglePortForward() {
    setRequestPortForward(!requestPortForward)
  }

  function setAllowLan(enabled) {
    if (!installed || setProcess.running) return
    var flag = enabled ? "true" : "false"
    runSet([ctl, "set", "allowlan", flag], "allowlan", enabled ? "LAN access allowed" : "LAN access blocked")
  }

  function toggleAllowLan() {
    setAllowLan(!allowLan)
  }

  function login() {
    if (!installed) return
    Quickshell.execDetached(["omarchy-launch-tui", "--app-id=pia-login", "bash", pluginDir + "bin/pia-login", ctl])
    actionStatus = "Opened the PIA login in a terminal"
    actionStatusTimer.restart()
    loginPollTimer.restart()
  }

  function logout() {
    if (!installed || actionProcess.running) return
    _desired = -1
    runAction([ctl, "logout"], "Logging out…")
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    actionStatus = "Copied " + (label || text)
    actionStatusTimer.restart()
  }

  function copyVpnIp() { copyToClipboard(vpnIp, "VPN IP " + vpnIp) }
  function copyPubIp() { copyToClipboard(pubIp, "public IP " + pubIp) }

  function runAction(command, label) {
    if (actionProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = label || ""
    actionProcess.command = command
    actionProcess.running = true
  }

  function runSet(command, key, label) {
    if (setProcess.running) return
    _setOutput = ""
    _setError = ""
    pendingSetting = key
    actionStatus = label || ""
    setProcess.command = command
    setProcess.running = true
  }

  function failWith(stderr, stdout, fallback) {
    var text = Model.elide(stderr || stdout || fallback)
    lastError = text
    actionStatus = text
    actionStatusTimer.restart()
    if (Model.looksLikeLoginError(text)) needsLogin = true
  }

  // ------------------------------------------------------------ timers

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Right after login the daemon can take a few seconds to come up; poll
    // quickly until it answers, then fall back to the normal interval.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.daemonUp || ticks >= 15) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // piactl monitor fires on every state hop; collapse bursts into one poll.
    id: monitorDebounce
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: monitorRetry
    interval: 5000
    repeat: false
    onTriggered: root.startMonitor()
  }

  Timer {
    // If the daemon never reaches the requested state (e.g. connect refused
    // without a non-zero exit), stop pretending after a while.
    id: desiredTimeout
    interval: 25000
    repeat: false
    onTriggered: root._desired = -1
  }

  Timer {
    // While the login terminal is open, poll a bit faster so the panel
    // reflects the new session without waiting for the next interval.
    id: loginPollTimer
    property int ticks: 0
    interval: 3000
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 40) { ticks = 0; loginPollTimer.stop() }
    }
    onRunningChanged: if (running) ticks = 0
  }

  Timer {
    // A hung piactl would otherwise block every later poll; reap it.
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (regionsProcess.running) regionsProcess.running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // ------------------------------------------------------------ processes

  Process {
    id: whichProcess
    running: false
    command: []
    stdout: StdioCollector { id: whichStdout; waitForEnd: true }
    onExited: function(exitCode) {
      // Settings usually land right after the first probe fires; if the path
      // changed underneath us, this result is stale — probe again.
      if (root._probedCtlSetting !== root.ctlSetting) {
        Qt.callLater(function() { root.refresh() })
        return
      }
      root.checkedInstall = true
      var parsed = Model.parseStatus(String(whichStdout.text || ""))
      var found = exitCode === 0 && parsed.values.ctl
      root.installed = !!found
      if (root.installed) {
        root.ctl = String(parsed.values.ctl)
        root.refreshStatus(true)
        root.startMonitor()
      } else {
        root.refreshing = false
        root.ctl = ""
        root.resetUnavailable("Not installed", "")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0 || stdout.indexOf("error=") !== -1) root.applyStatus(stdout)
      else root.resetUnavailable("Unavailable", Model.elide(stderr || stdout))
    }
  }

  Process {
    id: regionsProcess
    running: false
    command: []
    stdout: StdioCollector { id: regionsStdout; waitForEnd: true; onStreamFinished: root._regionsOutput = text }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyRegions(String(regionsStdout.text || root._regionsOutput || ""))
      else root._lastRegionsRefreshMs = 0
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || root._actionOutput || "")
      var stderr = String(actionStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.failWith(stderr, stdout, "piactl command failed")
      } else {
        root.lastError = ""
        if (root.actionStatus !== "" && !/…$/.test(root.actionStatus)) actionStatusTimer.restart()
        else root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: setProcess
    running: false
    command: []
    stdout: StdioCollector { id: setStdout; waitForEnd: true; onStreamFinished: root._setOutput = text }
    stderr: StdioCollector { id: setStderr; waitForEnd: true; onStreamFinished: root._setError = text }
    onExited: function(exitCode) {
      var stdout = String(setStdout.text || root._setOutput || "")
      var stderr = String(setStderr.text || root._setError || "")
      var key = root.pendingSetting
      root.pendingSetting = ""
      if (exitCode !== 0) {
        root.pendingRegion = ""
        root.failWith(stderr, stdout, "piactl set failed")
      } else {
        root.lastError = ""
        if (key === "region" && root.pendingRegion !== "") {
          var applied = root.pendingRegion
          root.region = applied
          root.regionApplied(applied)
          // Choosing a region while off is the natural "connect there" gesture.
          if (!root.active) root.connect()
        }
        if (/…$/.test(root.actionStatus)) root.actionStatus = ""
        else actionStatusTimer.restart()
      }
      delayedRefresh.restart()
    }
  }

  // piactl monitor streams a line on every connection state change, so the
  // bar reacts immediately instead of waiting for the next poll.
  function startMonitor() {
    if (!installed || monitorProcess.running) return
    monitorProcess.command = ["bash", "-c", "exec \"$1\" monitor connectionstate", "pia-monitor", ctl]
    monitorProcess.running = true
  }

  Process {
    id: monitorProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        root._monitorRetryMs = 5000
        monitorDebounce.restart()
      }
    }
    onExited: function(exitCode) {
      if (!root.installed) return
      monitorRetry.interval = root._monitorRetryMs
      monitorRetry.restart()
      root._monitorRetryMs = Math.min(root._monitorRetryMs * 2, 120000)
    }
  }

  onCtlSettingChanged: {
    installed = false
    ctl = ""
    if (monitorProcess.running) monitorProcess.running = false
    refresh()
  }

  Component.onDestruction: {
    if (monitorProcess.running) monitorProcess.running = false
  }
}
