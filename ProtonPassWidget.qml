import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Proton Pass bar-widget: vault selection, item search, and session
// lock/unlock, backed by the official `pass-cli` via qs-protonpass.sh.
//
// v1 scope: rich field support (username/password/TOTP copy) is for
// item_type "login" — the common case and what the browser extension is
// mostly used for. Other item types (note, alias, identity, ...) show a
// "view in app" fallback rather than reimplementing every field layout.
//
// Session states: missing (wrapper/pass-cli not set up) → logged-out →
// locked → unlocked. `pass-cli login` and `pass-cli session unlock` both
// require a real TTY (confirmed: piping the lock code via stdin fails
// reading /dev/tty), so both open a floating terminal rather than taking
// input inline in the popup.
//
// Clipboard: secret values flow from qs-protonpass.sh's stdout into a QML
// var that's never bound to any visible Text element, then out via
// Util.execDetached (printf | wl-copy) — the same pattern the network
// panel uses for the wifi passphrase and tailscale use for peer info.
// A Quickshell-managed Process can't be used for the wl-copy leg: wl-copy
// only claims the selection once its stdin hits EOF, and QML's Process
// exposes write() but no way to close/EOF the pipe, so it just hangs
// forever and nothing actually reaches the clipboard (confirmed with a
// manual fifo test). execDetached's child process tree closes stdin
// naturally when printf exits, so wl-copy backgrounds itself correctly.
// The clipboard is cleared automatically after ~35s or immediately if the
// popup closes.
BarWidget {
  id: root
  moduleName: "local.proton-pass"

  readonly property string home: Quickshell.env("HOME")
  readonly property string wrapperScript: home + "/.local/bin/qs-protonpass.sh"

  property bool wrapperInstalled: false
  property string sessionState: "missing" // missing | logged-out | locked | unlocked

  property var vaults: []             // [{value: share_id, label: name}]
  property string selectedVaultId: "" // "" = all vaults
  property var items: []              // raw item metadata
  property bool itemsLoading: false
  property string searchQuery: ""
  property string expandedKey: ""     // share_id + "|" + item_id
  property string copyFeedback: ""    // e.g. "Copied password" — label only, never the value

  readonly property var filteredItems: {
    var q = root.searchQuery.trim().toLowerCase()
    if (!q) return root.items
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      var it = root.items[i]
      var hay = (it.title + " " + (it.vault_name || "")).toLowerCase()
      if (hay.indexOf(q) !== -1) out.push(it)
    }
    return out
  }

  function itemKey(it) { return it.share_id + "|" + it.id }

  // ── wrapper script presence ─────────────────────────────────────────────
  FileView {
    id: scriptProbe
    path: root.wrapperScript
    onLoaded: { root.wrapperInstalled = true; root.refreshStatus() }
    onLoadFailed: { root.wrapperInstalled = false; root.sessionState = "missing" }
  }
  Component.onCompleted: scriptProbe.reload()

  // ── session status polling (cheap/local; keeps the badge accurate) ─────
  Process {
    id: statusProc
    command: [root.wrapperScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var prev = root.sessionState
        try {
          root.sessionState = (JSON.parse(text).state) || "logged-out"
        } catch (e) {
          root.sessionState = "logged-out"
        }
        if (root.sessionState === "unlocked" && detail.open && prev !== "unlocked") {
          root.refreshVaultsAndItems()
          Qt.callLater(function() { searchField.forceActiveFocus() })
        }
      }
    }
  }
  function refreshStatus() {
    if (!root.wrapperInstalled) { root.sessionState = "missing"; return }
    statusProc.running = false
    statusProc.running = true
  }

  Timer {
    interval: 45000
    repeat: true
    running: root.wrapperInstalled
    onTriggered: root.refreshStatus()
  }

  // ── vaults + items ───────────────────────────────────────────────────────
  Process {
    id: vaultsProc
    command: [root.wrapperScript, "vaults"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var opts = [{ value: "", label: "All vaults" }]
          var vs = d.vaults || []
          for (var i = 0; i < vs.length; i++) opts.push({ value: vs[i].share_id, label: vs[i].name })
          root.vaults = opts
        } catch (e) {}
      }
    }
  }

  Process {
    id: itemsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.itemsLoading = false
        try {
          root.items = JSON.parse(text).items || []
        } catch (e) {
          root.items = []
        }
      }
    }
    onExited: root.itemsLoading = false
  }

  function refreshVaultsAndItems() {
    vaultsProc.running = false; vaultsProc.running = true
    root.itemsLoading = true
    root.expandedKey = ""
    var args = [root.wrapperScript, "items"]
    if (root.selectedVaultId) { args.push("--vault"); args.push(root.selectedVaultId) }
    itemsProc.command = args
    itemsProc.running = false; itemsProc.running = true
  }

  onSelectedVaultIdChanged: if (detail.open && root.sessionState === "unlocked") root.refreshVaultsAndItems()

  // ── clipboard: detached printf|wl-copy, never a managed Process (see header) ──
  function copyToClipboard(secret) {
    Util.execDetached("printf %s " + Util.shellQuote(secret) + " | wl-copy")
  }
  Process {
    id: clipboardClearProc
    command: ["wl-copy", "--clear"]
  }
  Timer {
    id: clipboardClearTimer
    interval: 35000
    repeat: false
    onTriggered: { clipboardClearProc.running = false; clipboardClearProc.running = true; root.copyFeedback = "" }
  }
  function clearClipboardNow() {
    clipboardClearTimer.stop()
    clipboardClearProc.running = false; clipboardClearProc.running = true
  }

  Process {
    id: fieldFetchProc
    property string label: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          if (d.value) {
            root.copyToClipboard(d.value)
            clipboardClearTimer.restart()
            root.copyFeedback = "Copied " + fieldFetchProc.label
          } else {
            root.copyFeedback = "Nothing to copy"
          }
        } catch (e) {
          root.copyFeedback = "Copy failed"
        }
      }
    }
  }
  function copyField(shareId, itemId, field, label) {
    fieldFetchProc.label = label
    fieldFetchProc.command = [root.wrapperScript, "view", shareId, itemId, field]
    fieldFetchProc.running = false; fieldFetchProc.running = true
  }

  Process {
    id: totpFetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var code = d.token || d.code || d.value
          if (code) {
            root.copyToClipboard(String(code))
            clipboardClearTimer.restart()
            root.copyFeedback = "Copied TOTP code"
          } else {
            root.copyFeedback = "No TOTP for this item"
          }
        } catch (e) {
          root.copyFeedback = "No TOTP for this item"
        }
      }
    }
  }
  function copyTotp(shareId, itemId) {
    totpFetchProc.command = [root.wrapperScript, "totp", shareId, itemId]
    totpFetchProc.running = false; totpFetchProc.running = true
  }

  // ── login / unlock: both need a real TTY, so both open a terminal ──────
  Process {
    id: loginProc
    command: ["omarchy-launch-floating-terminal-with-presentation", "pass-cli login"]
  }
  Process {
    id: unlockProc
    command: ["omarchy-launch-floating-terminal-with-presentation", "pass-cli session unlock"]
  }
  function launchLogin()  { loginProc.running = false;  loginProc.running = true }
  function launchUnlock() { unlockProc.running = false; unlockProc.running = true }

  // ── bar chrome ───────────────────────────────────────────────────────────
  // One fixed mark (icon.svg), same idea as security-scan's single glyph —
  // state is conveyed by dimming/badging it, never by swapping the icon
  // shape (a lock/key/unlock swap read as "wrong icon" in testing).
  function avatarColor(title) {
    var palette = ["#6D4AFF", "#3DA5D9", "#33A67B", "#D97757", "#B85C9E", "#4A90D9"]
    var c = title && title.length ? title.charCodeAt(0) : 0
    return palette[c % palette.length]
  }
  function tooltipText() {
    if (root.sessionState === "missing") return "Proton Pass not set up\nClick for setup notes"
    if (root.sessionState === "logged-out") return "Not logged in\nClick to log in"
    if (root.sessionState === "locked") return "Locked\nClick to unlock"
    return "Proton Pass\nClick to browse vaults"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    fontSize: Style.bar.iconFont
    tooltipText: root.tooltipText()
    active: root.wrapperInstalled
    iconComponent: Component {
      Item {
        anchors.fill: parent
        Image {
          anchors.fill: parent
          source: "icon.svg"
          fillMode: Image.PreserveAspectFit
          smooth: true
          opacity: (root.sessionState === "missing" || root.sessionState === "logged-out") ? 0.4 : 1.0
        }
        Rectangle {
          visible: root.sessionState === "locked"
          width: Style.space(7)
          height: Style.space(7)
          radius: width / 2
          color: "#e8a33d"
          border.width: 1
          border.color: Color.popups.background
          anchors.right: parent.right
          anchors.bottom: parent.bottom
        }
      }
    }
    onPressed: {
      detail.open = !detail.open
      if (detail.open) {
        root.refreshStatus()
        if (root.sessionState === "unlocked") root.refreshVaultsAndItems()
      }
    }
  }

  // ── popup ────────────────────────────────────────────────────────────────
  // KeyboardPanel, not PopupCard: PopupCard wraps Quickshell's PopupWindow
  // (an xdg-popup), which never receives real Wayland keyboard focus unless
  // a click/hover already routed focus through its parent surface — so a
  // TextField inside one can look focused (blinking cursor) while every
  // keypress is silently dropped by the compositor. That was the actual
  // cause of the search box "not working". KeyboardPanel is built on
  // PanelWindow + WlrLayershell.keyboardFocus specifically for panels that
  // need real typed input (see its own header comment); `focusTarget` gets
  // both the compositor-level prime and the Qt-level forceActiveFocus().
  KeyboardPanel {
    id: detail
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: Style.space(320)
    contentHeight: bodyCol.implicitHeight + padding * 2
    focusTarget: root.sessionState === "unlocked" ? searchField : null

    onOpenChanged: {
      if (!open) {
        root.clearClipboardNow()
        root.copyFeedback = ""
        root.expandedKey = ""
        root.searchQuery = ""
        searchField.text = ""
      }
    }

    // ── reusable action button, same shape as security-scan's ─────────────
    component ActionBtn: Rectangle {
      id: ab
      property string label: ""
      signal clicked()

      width: Math.max(Style.space(90), lbl.implicitWidth + Style.spacing.lg)
      height: Style.spacing.controlHeight
      radius: Style.cornerRadius
      color: abMa.containsMouse ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08) : "transparent"
      border.width: 1
      border.color: abMa.containsMouse ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)
      Behavior on color { ColorAnimation { duration: 120 } }
      Text {
        id: lbl
        anchors.centerIn: parent
        text: ab.label
        color: abMa.containsMouse ? Color.accent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      MouseArea {
        id: abMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ab.clicked()
      }
    }

    Column {
      id: bodyCol
      width: detail.contentWidth - detail.padding * 2
      spacing: Style.spacing.lg

      Item {
        width: parent.width
        height: Style.spacing.xxl
        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Proton Pass"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        PanelActionButton {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: root.sessionState === "unlocked"
          iconText: "󰑐"
          foreground: Color.popups.text
          tooltipText: "Refresh"
          onClicked: root.refreshVaultsAndItems()
        }
      }

      // ── missing ──────────────────────────────────────────────────────────
      Column {
        visible: root.sessionState === "missing"
        width: parent.width
        spacing: Style.spacing.xs
        PanelSeparator { foreground: Color.popups.text }
        Text {
          width: parent.width
          text: "pass-cli not found, or the plugin's helper script isn't installed.\nRun install.sh, then `pass-cli login` in a terminal."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
      }

      // ── logged out ───────────────────────────────────────────────────────
      Column {
        visible: root.sessionState === "logged-out"
        width: parent.width
        spacing: Style.spacing.md
        PanelSeparator { foreground: Color.popups.text }
        Text {
          width: parent.width
          text: "Not logged in to Proton Pass."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
        ActionBtn { label: "Log in…"; onClicked: root.launchLogin() }
      }

      // ── locked ───────────────────────────────────────────────────────────
      Column {
        visible: root.sessionState === "locked"
        width: parent.width
        spacing: Style.spacing.md
        PanelSeparator { foreground: Color.popups.text }
        Text {
          width: parent.width
          text: "Session is locked."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
        ActionBtn { label: "Unlock…"; onClicked: root.launchUnlock() }
      }

      // ── unlocked: vault picker + search + item list ─────────────────────
      Column {
        visible: root.sessionState === "unlocked"
        width: parent.width
        spacing: Style.spacing.md

        PanelSeparator { foreground: Color.popups.text }

        SearchableDropdown {
          width: parent.width
          showLabel: false
          options: root.vaults
          value: root.selectedVaultId
          placeholderText: "Search vaults..."
          onChanged: function(v) { root.selectedVaultId = v }
        }

        Item {
          width: parent.width
          height: searchField.implicitHeight

          TextField {
            id: searchField
            anchors.fill: parent
            leftPadding: Style.space(30)
            placeholderText: "Search items..."
            foreground: Color.popups.text
            onTextChanged: root.searchQuery = text
          }
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍉"
            color: Qt.darker(Color.popups.text, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Text {
          visible: root.itemsLoading
          text: "Loading…"
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: !root.itemsLoading && root.filteredItems.length === 0
          text: root.items.length === 0 ? "No items in this vault." : "No matches."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: root.copyFeedback !== ""
          width: parent.width
          text: root.copyFeedback + " — clears in 35s"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Flickable {
          id: itemsFlickable
          width: parent.width
          height: Style.space(320)
          contentWidth: width
          contentHeight: itemsCol.implicitHeight
          clip: true
          visible: !root.itemsLoading && root.filteredItems.length > 0

          Column {
            id: itemsCol
            width: itemsFlickable.width
            spacing: Style.spacing.xxs

            Repeater {
              model: root.filteredItems
              delegate: Column {
                id: rowCol
                required property var modelData
                readonly property string key: root.itemKey(modelData)
                readonly property bool expanded: root.expandedKey === key
                readonly property bool isLogin: modelData.item_type === "login"
                width: itemsCol.width
                spacing: Style.spacing.xxs

                Rectangle {
                  width: parent.width
                  height: Style.space(44)
                  radius: Style.cornerRadius
                  color: rowMa.containsMouse || rowCol.expanded
                    ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.08)
                    : "transparent"
                  Behavior on color { ColorAnimation { duration: 100 } }

                  Rectangle {
                    id: avatar
                    width: Style.space(28)
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.avatarColor(rowCol.modelData.title)
                    Text {
                      anchors.centerIn: parent
                      text: (rowCol.modelData.title || "?").charAt(0).toUpperCase()
                      color: "white"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    id: chevron
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowCol.expanded ? "󰅃" : "󰅀"
                    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, rowMa.containsMouse || rowCol.expanded ? 0.6 : 0.3)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }

                  Column {
                    anchors.left: avatar.right
                    anchors.right: chevron.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.spacing.sm
                    anchors.rightMargin: Style.spacing.xs
                    spacing: Style.space(1)
                    Text {
                      width: parent.width
                      text: rowCol.modelData.title
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      visible: text !== ""
                      text: rowCol.modelData.vault_name || ""
                      color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.45)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    id: rowMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.copyFeedback = ""
                      root.expandedKey = rowCol.expanded ? "" : rowCol.key
                    }
                  }
                }

                Row {
                  visible: rowCol.expanded
                  width: parent.width
                  spacing: Style.spacing.xs
                  leftPadding: Style.space(28) + Style.spacing.sm * 2

                  ActionBtn {
                    label: "Copy username"
                    visible: rowCol.isLogin
                    onClicked: root.copyField(rowCol.modelData.share_id, rowCol.modelData.id, "username", "username")
                  }
                  ActionBtn {
                    label: "Copy password"
                    visible: rowCol.isLogin
                    onClicked: root.copyField(rowCol.modelData.share_id, rowCol.modelData.id, "password", "password")
                  }
                  ActionBtn {
                    label: "Copy TOTP"
                    visible: rowCol.isLogin
                    onClicked: root.copyTotp(rowCol.modelData.share_id, rowCol.modelData.id)
                  }
                }

                Text {
                  visible: rowCol.expanded && !rowCol.isLogin
                  width: parent.width
                  leftPadding: Style.space(28) + Style.spacing.sm * 2
                  text: "This item type isn't supported here yet — open it in the Proton Pass app."
                  color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }
    }
  }
}
