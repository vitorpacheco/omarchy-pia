import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for Private Internet Access. All piactl traffic lives
// in Service.qml; this file only renders state and forwards intents.
Panel {
  id: root
  moduleName: "io.github.vitorpacheco.pia"
  ipcTarget: "pia"
  manageIpc: false

  // 0 is the hero switch, i >= 1 is rows[i - 1].
  property int cursorIndex: 0
  property bool cursorActive: false
  property string cursorRowId: ""
  property bool pickerOpen: false
  property string pickerQuery: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property var recentRegions: settings.recentRegions instanceof Array ? settings.recentRegions : []

  readonly property string toggleHint: pia.active ? "Disconnect from PIA" : "Connect to PIA"
  readonly property string heroMeta: {
    if (!pia.installed) return pia.checkedInstall ? "piactl not found" : "Looking for piactl…"
    if (!pia.daemonUp) return pia.stateLabel
    if (pia.connected) return (pia.accountName !== "" ? pia.accountName + " · " : "") + "Connected · " + pia.regionLabel
    if (pia.transitioning) return pia.stateLabel + " · " + pia.regionLabel
    if (pia._desired === 1) return "Connecting…"
    return "Disconnected"
  }
  // No hero pill: it truncates the title, and the protocol has its own row.
  readonly property string heroDetail: ""

  readonly property var rows: buildRows()
  readonly property int searchPos: indexOfKind(rows, "search")
  readonly property var topRows: searchPos < 0 ? rows : rows.slice(0, searchPos)
  readonly property var bottomRows: searchPos < 0 ? [] : rows.slice(searchPos + 1)

  function indexOfKind(list, kind) {
    for (var i = 0; i < list.length; i++) if (list[i].kind === kind) return i
    return -1
  }

  function regionIcon(entry) {
    if (!entry) return "󰇧"
    if (entry.auto) return "󰓅"
    if (entry.dedicated) return "󰌆"
    return entry.flag !== "" ? entry.flag : "󰇧"
  }

  function regionRow(entry, prefix) {
    return {
      kind: "row",
      id: prefix + entry.id,
      icon: regionIcon(entry),
      title: entry.label,
      subtitle: entry.auto ? "Let PIA pick the fastest server" : entry.id,
      trailing: pia.pendingRegion === entry.id ? "…" : (entry.id === pia.region ? "current" : ""),
      current: entry.id === pia.region,
      busy: pia.pendingRegion === entry.id,
      action: "region",
      region: entry.id
    }
  }

  function buildRows() {
    var list = []
    if (!pia.installed) {
      if (pia.checkedInstall) {
        list.push({ kind: "hint", id: "hint-install",
          text: "piactl was not found. Install the PIA desktop client (yay -S piavpn-bin), then run: sudo systemctl enable --now piavpn" })
        list.push({ kind: "row", id: "retry", icon: "󰑐", title: "Look again", subtitle: "Re-check for piactl", action: "retry" })
      }
      return list
    }

    if (!pia.daemonUp) {
      list.push({ kind: "hint", id: "hint-daemon",
        text: (pia.lastError !== "" ? pia.lastError + " — " : "") + "Start the daemon with: sudo systemctl start piavpn" })
      list.push({ kind: "row", id: "retry", icon: "󰑐", title: "Retry", subtitle: "Ask the daemon again", action: "retry" })
    }

    if (pia.needsLogin) {
      list.push({ kind: "row", id: "login", icon: "󰌆", title: "Log in to PIA", subtitle: "Opens a terminal to enter your credentials", action: "login" })
    }

    list.push({ kind: "section", id: "sec-connection", text: "CONNECTION" })
    var currentEntry = Model.regionEntry(pia.region)
    list.push({
      kind: "row", id: "region",
      icon: regionIcon(currentEntry),
      title: pia.region === "" ? "No region" : currentEntry.label,
      subtitle: pia.pendingRegion !== "" ? "Switching to " + Model.regionLabel(pia.pendingRegion) + "…" : "Region · press enter to change",
      busy: pia.pendingRegion !== "",
      action: "picker"
    })
    if (pia.connected) {
      list.push({ kind: "row", id: "vpnip", icon: "󰩟", title: pia.vpnIp !== "" ? pia.vpnIp : "—", subtitle: "VPN IP · copy with c", action: "copyVpn" })
      list.push({ kind: "row", id: "pubip", icon: "󰖟", title: pia.pubIp !== "" ? pia.pubIp : "—", subtitle: "Public IP · copy with p", action: "copyPub" })
    }

    list.push({ kind: "section", id: "sec-regions", text: "REGIONS" })
    list.push({ kind: "search", id: "search" })
    if (pickerOpen) {
      var filtered = Model.filterRegions(pia.regions, pickerQuery)
      if (pia.regions.length === 0) list.push({ kind: "hint", id: "hint-noregions", text: "No region list yet. The daemon must be running to fetch it." })
      else if (filtered.length === 0) list.push({ kind: "hint", id: "hint-nomatch", text: "No regions match \"" + pickerQuery + "\"." })
      for (var i = 0; i < filtered.length; i++) list.push(regionRow(filtered[i], "pick:"))
    } else {
      var pinned = Model.pinnedRegions(pia.region, recentRegions, pia.regions, pia.maxRecentRegions)
      for (var j = 0; j < pinned.length; j++) list.push(regionRow(pinned[j], "pin:"))
      list.push({ kind: "row", id: "choose", icon: "󰍉", title: "Choose region…",
        subtitle: pia.regions.length > 0 ? pia.regions.length + " regions available" : "Region list not loaded yet", action: "picker" })
    }

    list.push({ kind: "section", id: "sec-settings", text: "SETTINGS" })
    list.push({ kind: "row", id: "protocol", icon: "󰓡", title: "Protocol",
      subtitle: "Switch to " + Model.protocolLabel(Model.otherProtocol(pia.protocol)),
      trailing: pia.protocolLabel, busy: pia.pendingSetting === "protocol", action: "protocol" })
    list.push({ kind: "row", id: "portforward", icon: "󰁔", title: "Port forwarding",
      subtitle: pia.requestPortForward ? pia.portForward.label : "Request a forwarded port on connect",
      toggle: true, checked: pia.requestPortForward, busy: pia.pendingSetting === "portforward", action: "portforward" })
    list.push({ kind: "row", id: "allowlan", icon: "󰛳", title: "Allow LAN traffic",
      subtitle: "Reach printers and local devices while connected",
      toggle: true, checked: pia.allowLan, busy: pia.pendingSetting === "allowlan", action: "allowlan" })

    list.push({ kind: "section", id: "sec-account", text: "ACCOUNT" })
    // piactl has no "am I logged in" query, so the VPN state is the proxy:
    // connected means a valid session, anything else offers to log in. The
    // needsLogin call-to-action at the top already covers that case.
    if (pia.connected) list.push({ kind: "row", id: "logout", icon: "󰗼", title: "Log out", subtitle: pia.accountName !== "" ? "Signed in as " + pia.accountName : "Forget the PIA session on this machine", action: "logout" })
    else if (!pia.needsLogin) list.push({ kind: "row", id: "login", icon: "󰌆", title: "Log in", subtitle: "Opens a terminal to enter your credentials", action: "login" })
    return list
  }

  // ------------------------------------------------------------ cursor

  function isFocusable(row) {
    if (!row) return false
    if (row.kind === "search") return pickerOpen
    return row.kind === "row"
  }

  function rowAt(index) {
    if (index <= 0 || index > rows.length) return null
    return rows[index - 1]
  }

  function firstFocusable(from, step) {
    var i = from
    while (i >= 0 && i <= rows.length) {
      if (i === 0 || isFocusable(rows[i - 1])) return i
      i += step
    }
    return -1
  }

  function ensureCursor() {
    if (cursorIndex < 0) cursorIndex = 0
    if (cursorIndex > rows.length) cursorIndex = rows.length
    if (cursorIndex !== 0 && !isFocusable(rowAt(cursorIndex))) {
      var next = firstFocusable(cursorIndex, 1)
      if (next < 0) next = firstFocusable(cursorIndex, -1)
      cursorIndex = next < 0 ? 0 : next
    }
    var row = rowAt(cursorIndex)
    cursorRowId = row ? String(row.id) : ""
  }

  function restoreCursor() {
    var found = false
    if (cursorRowId !== "") {
      for (var i = 0; i < rows.length; i++) {
        if (String(rows[i].id) === cursorRowId) {
          cursorIndex = i + 1
          found = true
          break
        }
      }
    }
    // A picker match that just got filtered out must not drop the cursor onto
    // whatever row now sits at the same index — stay inside the picker.
    if (!found && pickerOpen && cursorRowId.indexOf("pick:") === 0) {
      var first = firstFocusable(searchPos + 2, 1)
      cursorIndex = first > 0 ? first : searchPos + 1
    }
    ensureCursor()
    syncSearchFocus()
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    pointerGate.reset()
    if (dy === 0) return
    ensureCursor()
    var next = firstFocusable(cursorIndex + (dy > 0 ? 1 : -1), dy > 0 ? 1 : -1)
    if (next >= 0) cursorIndex = next
    ensureCursor()
    syncSearchFocus()
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
    ensureCursor()
    syncSearchFocus()
  }

  // While the picker is open the search field keeps keyboard focus as long as
  // the cursor sits on the field or one of its matches, so typing keeps
  // filtering while arrows walk the results. Leaving the picker rows hands
  // the keys back to the panel dispatcher.
  function syncSearchFocus() {
    var row = rowAt(cursorIndex)
    var inPicker = pickerOpen && row && (row.kind === "search" || String(row.id).indexOf("pick:") === 0)
    if (inPicker) {
      if (!pickerSearch.activeFocus) pickerSearch.forceActiveFocus()
    } else if (pickerSearch.activeFocus) {
      keyCatcher.forceActiveFocus()
    }
  }

  function activateCursor() {
    ensureCursor()
    if (cursorIndex === 0) {
      pia.toggleVpn()
      return
    }
    activateRow(rowAt(cursorIndex))
  }

  function activateRow(row) {
    if (!row) return
    switch (row.action) {
    case "retry": pia.refresh(true); break
    case "login": pia.login(); break
    case "logout": pia.logout(); break
    case "picker": togglePicker(); break
    case "copyVpn": pia.copyVpnIp(); break
    case "copyPub": pia.copyPubIp(); break
    case "region": chooseRegion(row.region); break
    case "protocol": pia.toggleProtocol(); break
    case "portforward": pia.togglePortForward(); break
    case "allowlan": pia.toggleAllowLan(); break
    default: break
    }
  }

  function togglePicker() {
    if (pickerOpen) closePicker()
    else openPicker()
  }

  function openPicker() {
    pickerQuery = ""
    pickerOpen = true
    pia.refresh(true)
    Qt.callLater(function() {
      cursorActive = true
      cursorIndex = searchPos + 1
      ensureCursor()
      syncSearchFocus()
      scrollCursorIntoView()
    })
  }

  function closePicker() {
    pickerOpen = false
    pickerQuery = ""
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].id === "region") { cursorIndex = i + 1; break }
      }
      ensureCursor()
      scrollCursorIntoView()
    })
  }

  function chooseRegion(id) {
    var regionId = String(id || "")
    if (regionId === "") return
    pia.setRegion(regionId)
    if (pickerOpen) closePicker()
  }

  function persistAccount(name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    if (String(name || "") === "") delete entry.accountName
    else entry.accountName = String(name)
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function persistRecent(id) {
    var next = Model.pushRecent(recentRegions, id, pia.maxRecentRegions)
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.recentRegions = next
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function itemForIndex(index) {
    if (index <= 0) return hero
    var i = index - 1
    if (searchPos < 0 || i < searchPos) return topRepeater.itemAt(i)
    if (i === searchPos) return pickerSearch
    return bottomRepeater.itemAt(i - searchPos - 1)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    scrollItemIntoView(itemForIndex(cursorIndex))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      cursorRowId = ""
      pointerGate.reset()
      if (panelFlick) panelFlick.contentY = 0
      pia.refresh(true)
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (pickerOpen) {
      pickerOpen = false
      pickerQuery = ""
    }
  }
  onRowsChanged: restoreCursor()
  onCursorIndexChanged: scrollCursorIntoView()

  Service {
    id: pia
    settings: root.settings
    onRegionApplied: function(id) { root.persistRecent(id) }
    onAccountLearned: function(name) { root.persistAccount(name) }
  }

  // Rows scroll and rebuild under a stationary pointer all the time (every
  // status poll, every keyboard scroll). Only real pointer motion may move
  // the cursor, otherwise j/k fights the mouse.
  PointerMoveGate {
    id: pointerGate
    referenceItem: panelFlick
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): string { pia.connect(); return "ok" }
    function disconnect(): string { pia.disconnect(); return "ok" }
    function toggleVpn(): string { pia.toggleVpn(); return "ok" }
    function refresh(): string { pia.refresh(true); return "ok" }
    function status(): string { return pia.stateLabel }
    function region(): string { return pia.region }
    function account(): string { return pia.accountName !== "" ? pia.accountName : "unknown" }
    function setRegion(id: string): string { pia.setRegion(id); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "PIA · " + root.heroMeta
    iconComponent: Component {
      Item {
        PiaIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          fontFamily: button.fontFamily
          color: pia.active ? button.foreground : Qt.darker(button.foreground, 1.55)
          badgeColor: button.activeColor
          crossed: !pia.active && !pia.busy
          pulsing: pia.busy
          warning: pia.needsLogin
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) pia.toggleVpn()
      else if (buttonCode === Qt.MiddleButton) pia.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: pickerSearch.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.pickerOpen) root.closePicker()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") pia.toggleVpn()
        else if (t === "r" || t === "R") pia.refresh(true)
        else if (t === "c" || t === "C") pia.copyVpnIp()
        else if (t === "p" || t === "P") pia.copyPubIp()
        else if (t === "g" || t === "G" || t === "/") { if (pia.installed) root.openPicker() }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.cursorActive && root.cursorIndex === 0 && pia.installed
            function focusHero() { root.setCursor(0) }

            PanelHero {
              id: hero
              width: parent.width
              title: "Private Internet Access"
              meta: root.heroMeta
              detail: root.heroDetail
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: pia.active ? 1.0 : 0.5
              iconComponent: Component {
                PiaIcon {
                  iconSize: Style.font.display
                  fontFamily: hero.fontFamily
                  color: pia.active ? hero.foreground : Qt.darker(hero.foreground, 1.55)
                  badgeColor: Color.urgent
                  crossed: !pia.active && !pia.busy
                  pulsing: pia.busy
                  warning: pia.needsLogin
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: pia.installed
                  checked: pia.active
                  busy: pia.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: pia.toggleVpn()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: pia.active ? "Disconnect from PIA" : "Connect to PIA"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: pia.actionStatus !== "" || pia.lastError !== ""
            width: parent.width
            text: pia.actionStatus !== "" ? pia.actionStatus : pia.lastError
            color: pia.lastError !== "" && pia.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            id: topColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              id: topRepeater
              model: root.topRows
              PanelRow {
                required property var modelData
                required property int index
                width: topColumn.width
                row: modelData
                cursorSlot: index + 1
              }
            }
          }

          TextField {
            id: pickerSearch
            visible: root.pickerOpen
            width: parent.width
            foreground: root.foreground
            placeholderText: "Search regions"
            text: root.pickerQuery
            onTextChanged: {
              if (root.pickerQuery === text) return
              root.pickerQuery = text
              // Land on the first match so enter picks it straight away.
              Qt.callLater(function() {
                if (!root.pickerOpen) return
                var next = root.firstFocusable(root.searchPos + 2, 1)
                if (next > 0) { root.cursorActive = true; root.cursorIndex = next; root.ensureCursor() }
                root.syncSearchFocus()
              })
            }
            onAccepted: root.activateCursor()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) {
                root.moveCursor(0, 1); event.accepted = true; return
              }
              if (event.key === Qt.Key_Up) {
                root.moveCursor(0, -1); event.accepted = true; return
              }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activateCursor(); event.accepted = true; return
              }
              if (event.key === Qt.Key_Escape) {
                root.closePicker(); event.accepted = true
              }
            }
          }

          Column {
            id: bottomColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              id: bottomRepeater
              model: root.bottomRows
              PanelRow {
                required property var modelData
                required property int index
                width: bottomColumn.width
                row: modelData
                cursorSlot: root.searchPos + 2 + index
              }
            }
          }
        }
      }
    }
  }

  // One delegate for every entry of `rows`: section headers, hints and
  // actionable rows. Keeping it a single type means the Repeaters never have
  // to swap components while the list rebuilds.
  component PanelRow: Item {
    id: panelRow
    property var row: null
    property int cursorSlot: -1
    readonly property string kind: row ? String(row.kind || "") : ""
    readonly property bool isSection: kind === "section"
    readonly property bool isHint: kind === "hint"
    readonly property bool isRow: kind === "row"
    readonly property bool hasCursor: isRow && root.cursorActive && root.cursorIndex === cursorSlot

    implicitHeight: isSection ? sectionBlock.implicitHeight : (isHint ? hintText.implicitHeight + Style.space(4) : (isRow ? surface.implicitHeight : 0))
    height: implicitHeight

    Column {
      id: sectionBlock
      visible: panelRow.isSection
      width: parent.width
      spacing: Style.space(8)
      topPadding: Style.space(4)

      PanelSeparator { width: parent.width; foreground: root.foreground }

      PanelSectionHeader {
        text: panelRow.row && panelRow.row.text ? panelRow.row.text : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }

    Text {
      id: hintText
      visible: panelRow.isHint
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      text: panelRow.row && panelRow.row.text ? panelRow.row.text : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    CursorSurface {
      id: surface
      visible: panelRow.isRow
      width: parent.width
      hasCursor: panelRow.hasCursor
      current: panelRow.row && panelRow.row.current === true
      foreground: root.foreground
      fill: root.hoverFill
      currentFill: root.selectedFill
      implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: function(mouse) {
          if (pointerGate.moved(rowMouse, mouse)) root.setCursor(panelRow.cursorSlot)
        }
        onClicked: root.activateRow(panelRow.row)
      }

      RowLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: panelRow.row && panelRow.row.icon ? panelRow.row.icon : ""
          color: panelRow.row && (panelRow.row.current === true || panelRow.row.busy === true) ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          Layout.preferredWidth: Style.space(24)
          horizontalAlignment: Text.AlignHCenter
          Layout.alignment: Qt.AlignVCenter
          opacity: panelRow.row && panelRow.row.busy === true ? 0.45 : 1.0

          SequentialAnimation on opacity {
            running: panelRow.row && panelRow.row.busy === true
            loops: Animation.Infinite
            NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: panelRow.row && panelRow.row.title ? panelRow.row.title : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: panelRow.row && panelRow.row.current === true
            elide: Text.ElideRight
          }

          Text {
            Layout.fillWidth: true
            visible: text !== ""
            textFormat: Text.PlainText
            text: panelRow.row && panelRow.row.subtitle ? panelRow.row.subtitle : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          visible: text !== ""
          textFormat: Text.PlainText
          text: panelRow.row && panelRow.row.trailing ? panelRow.row.trailing : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        ToggleSwitch {
          visible: panelRow.row && panelRow.row.toggle === true
          checked: panelRow.row && panelRow.row.checked === true
          busy: panelRow.row && panelRow.row.busy === true
          interactive: false
          foreground: root.foreground
          Layout.alignment: Qt.AlignVCenter
        }
      }
    }
  }
}
