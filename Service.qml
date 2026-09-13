import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model
import "I18n.js" as I18n

// Talks to the PIA daemon through piactl. Owns every Process so Panel.qml can
// stay a pure view: it reads the properties below and calls the action
// functions, nothing else.
Item {
  id: root

  property var settings: ({})

  readonly property string language: I18n.language(Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || Qt.locale().name)
  function t(source, values) { return I18n.t(language, source, values) }

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
  property string connectedRegion: ""
  property string vpnIp: ""
  property string pubIp: ""
  property string protocol: ""
  property var portForward: ({ active: false, port: 0, label: "Inactive" })
  property bool requestPortForward: false
  property bool allowLan: false
  property var regions: []
  // -1 unknown, 0 logged out, 1 logged in. Fed by the daemon's own log line
  // ("Reapplying firewall rules; ... loggedIn: N", present while PIA debug
  // logging is on, its default) and by piactl error messages.
  property int loginState: -1
  readonly property bool loggedIn: loginState === 1
  readonly property bool needsLogin: loginState === 0
  // piactl exposes no account query and the daemon socket rejects foreign
  // clients, so the account name can only be learned when the user logs in
  // through this widget: bin/pia-login writes it to a marker file we read.
  // It is persisted in settings, so it survives restarts once known.
  property string accountName: Model.stringSetting(settings, "accountName", "")

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
  readonly property string regionLabel: I18n.regionLabel(language, Model.connectionRegionLabel(region, connectedRegion, connected))
  readonly property string protocolLabel: t(Model.protocolLabel(protocol))

  signal regionApplied(string id)

  property string _statusOutput: ""
  property string _statusError: ""
  property string _regionsOutput: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _setOutput: ""
  property string _setError: ""
  property string _lastNotifiedState: ""
  // Last state from a successful poll. Unlike rawState it survives a transient
  // poll failure, so a Connected -> (hiccup) -> Disconnected still notifies.
  property string _lastKnownState: ""
  property int _statusFailures: 0
  property double _lastRegionsRefreshMs: 0
  property string _probedCtlSetting: ""
  property int _monitorRetryMs: 5000

  readonly property string statusKeys: "connectionstate region vpnip pubip protocol portforward requestportforward allowlan"

  // Every `piactl get` opens its own daemon connection, and during a
  // transition the daemon can answer slowly, so the calls run in parallel and
  // the poll takes as long as the slowest one instead of the sum.
  readonly property string statusScript: "ctl=\"$1\"; keys=\"$2\"\n" +
    "d=$(mktemp -d) || exit 1\n" +
    "for k in $keys; do\n" +
    "  ( timeout 8 \"$ctl\" get \"$k\" >\"$d/$k\" 2>&1; echo $? >\"$d/$k.rc\" ) &\n" +
    "done\n" +
    // Unstable API: extract only the location, and tolerate missing support/jq.
    "( timeout 8 \"$ctl\" -u dump daemon-state 2>/dev/null | jq -r 'select(.connectionState == \"Connected\") | .connectedConfig.vpnLocation.id | select(type == \"string\") | select(test(\"^[a-zA-Z0-9_-]+$\"))' 2>/dev/null >\"$d/connectedregion\" ) &\n" +
    "wait\n" +
    "for k in $keys; do\n" +
    "  rc=$(cat \"$d/$k.rc\" 2>/dev/null); v=$(cat \"$d/$k\" 2>/dev/null); v=${v//$'\\n'/ }\n" +
    "  if [ \"$rc\" = 0 ]; then printf '%s=%s\\n' \"$k\" \"$v\"\n" +
    "  else printf 'error=%s\\n' \"${v:-piactl get $k failed (rc $rc)}\"; rm -rf \"$d\"; exit 1; fi\n" +
    "done\n" +
    "printf 'connectedregion=%s\\n' \"$(cat \"$d/connectedregion\" 2>/dev/null)\"\n" +
    "rm -rf \"$d\"\n" +
    "if [ -r /opt/piavpn/var/daemon.log ]; then\n" +
    "  l=$(tail -c 400000 /opt/piavpn/var/daemon.log 2>/dev/null | grep -oE 'loggedIn: [01]' | tail -1)\n" +
    "  [ -n \"$l\" ] && printf 'loggedin=%s\\n' \"${l#loggedIn: }\"\n" +
    "fi\n" +
    "exit 0\n"

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

  property bool _refreshPending: false

  function refreshStatus(forceRegions) {
    if (!installed) return
    var launched = false
    if (statusProcess.running) {
      // A state change arrived mid-poll; run again as soon as this one lands
      // instead of waiting for the next interval.
      _refreshPending = true
    } else {
      _statusOutput = ""
      _statusError = ""
      refreshing = true
      statusProcess.command = ["bash", "-c", statusScript, "pia-status", ctl, statusKeys]
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
    connectedRegion = ""
    transitioning = false
    _desired = -1
    rawState = ""
    _notifyWanted = ""
    settleTimer.stop()
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
    connectedRegion = connected ? String(v.connectedregion || "") : ""
    vpnIp = Model.cleanIp(v.vpnip)
    pubIp = Model.cleanIp(v.pubip)
    protocol = String(v.protocol || "").trim().toLowerCase()
    portForward = Model.portForwardInfo(v.portforward)
    requestPortForward = Model.parseBool(v.requestportforward, requestPortForward)
    allowLan = Model.parseBool(v.allowlan, allowLan)
    if (pendingRegion !== "" && region === pendingRegion) pendingRegion = ""
    if (v.loggedin === "1") loginState = 1
    else if (v.loggedin === "0" && !connected && !transitioning) loginState = 0
    if (connected || transitioning) loginState = 1
    lastError = ""

    // Resolve a held notification first; if it was dropped because the state
    // moved on, the new transition still gets its own chance below.
    if (_notifyWanted !== "") checkSettled()
    if (_notifyWanted === "") maybeNotify(previousState, info)
  }

  // piactl flips to Connected/Disconnected a beat before the tunnel details
  // settle (VPN IP appears or clears). Hold the notification until the IPs
  // agree with the state, polling briefly, so it never fires mid-transition.
  property string _notifyWanted: ""
  property int _settleTries: 0

  function maybeNotify(previousState, info) {
    if (!notificationsEnabled) return
    if (previousState === "" || previousState === info.raw) return
    if (info.raw !== "Connected" && info.raw !== "Disconnected" && info.raw !== "Interrupted") return
    if (_lastNotifiedState === info.raw) return
    if (info.raw === "Interrupted") {
      sendNotification(info.raw)
      return
    }
    _notifyWanted = info.raw
    _settleTries = 0
    checkSettled()
  }

  function checkSettled() {
    if (_notifyWanted === "") return
    if (rawState !== _notifyWanted) {
      // State moved on before the details settled; drop this one.
      _notifyWanted = ""
      settleTimer.stop()
      return
    }
    var settled = _notifyWanted === "Connected" ? (vpnIp !== "" && pubIp !== "") : (vpnIp === "")
    if (settled || _settleTries >= 5) {
      var state = _notifyWanted
      _notifyWanted = ""
      settleTimer.stop()
      sendNotification(state)
      return
    }
    _settleTries += 1
    settleTimer.restart()
  }

  function sendNotification(state) {
    _lastNotifiedState = state
    var title = state === "Connected" ? "VPN connected" : (state === "Interrupted" ? "VPN interrupted" : "VPN disconnected")
    // No addresses in the toast: the panel blurs them for a reason.
    var body = state === "Connected" ? regionLabel : "Private Internet Access"
    Quickshell.execDetached(["notify-send", "-a", "Private Internet Access",
      "-h", "string:omarchy-glyph:" + Model.SHIELD_GLYPH,
      "-h", "string:x-canonical-private-synchronous:pia-vpn", t(title), body])
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
    runAction(["bash", "-c", script, "pia-connect", ctl], t("Connecting…"))
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
    runSet([ctl, "set", "region", regionId], "region", t("Switching to {name}…", { name: I18n.regionLabel(language, Model.regionLabel(regionId)) }))
  }

  function setProtocol(value) {
    var proto = String(value || "").toLowerCase()
    if (!installed || (proto !== "wireguard" && proto !== "openvpn") || setProcess.running) return
    runSet([ctl, "set", "protocol", proto], "protocol", t("Switching to {name}…", { name: Model.protocolLabel(proto) }))
  }

  function toggleProtocol() {
    setProtocol(Model.otherProtocol(protocol))
  }

  function setRequestPortForward(enabled) {
    if (!installed || setProcess.running) return
    var flag = enabled ? "true" : "false"
    runSet([ctl, "set", "requestportforward", flag], "portforward", enabled ? t("Requesting port forwarding…") : t("Port forwarding off"))
  }

  function togglePortForward() {
    setRequestPortForward(!requestPortForward)
  }

  function setAllowLan(enabled) {
    if (!installed || setProcess.running) return
    var flag = enabled ? "true" : "false"
    runSet([ctl, "set", "allowlan", flag], "allowlan", enabled ? t("LAN access allowed") : t("LAN access blocked"))
  }

  function toggleAllowLan() {
    setAllowLan(!allowLan)
  }

  readonly property string loginMarker: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-pia-login." + (Quickshell.env("USER") || "user")
  property string _markerOutput: ""

  function login() {
    if (!installed) return
    Quickshell.execDetached(["bash", "-c", "rm -f \"$1\"; exec omarchy-launch-tui --app-id=pia-login bash \"$2\" \"$3\" \"$1\" \"$4\"", "pia-login-launch", loginMarker, pluginDir + "bin/pia-login", ctl, language])
    actionStatus = t("Opened the PIA login in a terminal")
    actionStatusTimer.restart()
    loginPollTimer.restart()
  }

  signal accountLearned(string name)

  function rememberAccount(name) {
    var value = String(name || "").trim()
    if (value === "" || value === accountName) return
    accountName = value
    accountLearned(value)
  }

  function logout() {
    if (!installed || actionProcess.running) return
    _desired = -1
    accountName = ""
    accountLearned("")
    loginState = 0
    runAction([ctl, "logout"], t("Logging out…"))
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    actionStatus = t("Copied {value}", { value: label || text })
    actionStatusTimer.restart()
  }

  function copyVpnIp() { copyToClipboard(vpnIp, t("VPN IP {ip}", { ip: vpnIp })) }
  function copyPubIp() { copyToClipboard(pubIp, t("public IP {ip}", { ip: pubIp })) }

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
    var text = Model.elide(stderr || stdout || t(fallback))
    lastError = text
    actionStatus = text
    actionStatusTimer.restart()
    if (Model.looksLikeLoginError(text)) loginState = 0
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
    id: statusRetry
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
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
    interval: 2000
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      if (!markerProcess.running) {
        root._markerOutput = ""
        markerProcess.command = ["bash", "-c", "[ -f \"$1\" ] || exit 3; cat \"$1\"; rm -f \"$1\"", "pia-marker", root.loginMarker]
        markerProcess.running = true
      }
      if (ticks >= 90) { ticks = 0; loginPollTimer.stop() }
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
      var parsed = Model.parseStatus(stdout)
      if (exitCode === 0 && parsed.ok) {
        root._statusFailures = 0
        root.applyStatus(stdout)
      } else {
        root._statusFailures += 1
        var message = parsed.ok ? (stderr || stdout) : parsed.error
        if (root._statusFailures < 3 && root.daemonUp && !Model.looksLikeDaemonError(message)) {
          // Likely a slow answer mid-transition: keep what we show and retry soon.
          statusRetry.restart()
        } else {
          root.resetUnavailable(Model.looksLikeDaemonError(message) ? "PIA daemon not running" : "Unavailable", Model.elide(message))
        }
      }
      if (root._refreshPending) {
        root._refreshPending = false
        Qt.callLater(function() { root.refreshStatus(false) })
      }
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

  Process {
    id: markerProcess
    running: false
    command: []
    stdout: StdioCollector { id: markerStdout; waitForEnd: true; onStreamFinished: root._markerOutput = text }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var name = String(markerStdout.text || root._markerOutput || "").trim()
      if (name === "") return
      root.rememberAccount(name)
      root.loginState = 1
      loginPollTimer.stop()
      root.actionStatus = root.t("Logged in as {name}", { name: name })
      actionStatusTimer.restart()
      delayedRefresh.restart()
    }
  }

  // piactl monitor streams a line on every connection state change, so the
  // bar reacts immediately instead of waiting for the next poll.
  function startMonitor() {
    if (!installed) return
    if (!monitorProcess.running) {
      monitorProcess.command = ["bash", "-c", "exec \"$1\" monitor connectionstate", "pia-monitor", ctl]
      monitorProcess.running = true
    }
    if (!ipMonitorProcess.running) {
      ipMonitorProcess.command = ["bash", "-c", "exec \"$1\" monitor vpnip", "pia-monitor-ip", ctl]
      ipMonitorProcess.running = true
    }
  }

  Process {
    id: ipMonitorProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) { monitorDebounce.restart() }
    }
    onExited: function(exitCode) {
      if (!root.installed) return
      if (!monitorRetry.running) { monitorRetry.interval = root._monitorRetryMs; monitorRetry.restart() }
    }
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
    if (ipMonitorProcess.running) ipMonitorProcess.running = false
    refresh()
  }

  Component.onDestruction: {
    if (monitorProcess.running) monitorProcess.running = false
    if (ipMonitorProcess.running) ipMonitorProcess.running = false
  }
}
