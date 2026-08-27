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
  property bool hasLock: false // auto-lock configured at all (independent of current lock state)
  property var configuredIdleTimeout: null // seconds, read back from pass-cli once a lock exists

  // ── PIN entry: unlock, and the two-step (enter/confirm) create-lock flow ──
  // pass-cli's lock code is its own secret, independent of any browser
  // extension's PIN — there's no API to read or reuse an extension's PIN or
  // its configured timeout, and this widget must work with pass-cli alone
  // (most installs won't have any particular browser extension present at
  // all). The idle-timeout is whatever the user types during setup below;
  // 300s (pass-cli's own default) is just the pre-filled starting value.
  readonly property int lockIdleTimeoutDefault: 300
  property string lockSetupIdleTimeoutText: String(lockIdleTimeoutDefault)
  property string lockSetupStage: "" // "" | "enter" | "confirm"
  property string lockSetupFirstCode: ""
  property bool pinBusy: false
  property string pinError: ""

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
          var d = JSON.parse(text)
          root.sessionState = d.state || "logged-out"
          root.hasLock = !!d.hasLock
          root.configuredIdleTimeout = (d.idleTimeout !== undefined && d.idleTimeout !== null) ? d.idleTimeout : null
        } catch (e) {
          root.sessionState = "logged-out"
          root.hasLock = false
          root.configuredIdleTimeout = null
        }
        if (root.sessionState !== "locked") {
          root.pinError = ""
          root.lockSetupStage = ""
          root.lockSetupFirstCode = ""
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

  // ── detail view: username + password/TOTP reveal ───────────────────────
  // List rows never show anything beyond the metadata pass-cli's item list
  // already returns (no username field there — confirmed against a real
  // 626-item vault). Opening an item's detail view is a single per-item
  // `view` call, same cost as one copy — that's what makes a real username
  // subtitle affordable here where it wasn't for every row in the list.
  property string detailUsername: ""
  property var detailUrls: []
  property string detailModified: ""
  property bool detailUsernameLoading: false
  property string revealedField: "" // "password" | "totp" | ""
  property string revealedValue: ""

  function findItem(key) {
    for (var i = 0; i < root.items.length; i++) {
      if (root.itemKey(root.items[i]) === key) return root.items[i]
    }
    return null
  }

  onExpandedKeyChanged: {
    root.hideReveal()
    root.detailUsername = ""
    root.detailUrls = []
    root.detailModified = ""
    root.detailUsernameLoading = false
    var it = root.findItem(root.expandedKey)
    if (it && it.item_type === "login") {
      root.detailUsernameLoading = true
      usernameFetchProc.command = [root.wrapperScript, "detail", it.share_id, it.id]
      usernameFetchProc.running = false; usernameFetchProc.running = true
    }
  }

  Process {
    id: usernameFetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detailUsernameLoading = false
        try {
          var d = JSON.parse(text)
          root.detailUsername = d.username || ""
          root.detailUrls = d.urls || []
          root.detailModified = d.modify_time || ""
        } catch (e) {
          root.detailUsername = ""
          root.detailUrls = []
          root.detailModified = ""
        }
      }
    }
    onExited: root.detailUsernameLoading = false
  }

  Timer {
    id: revealClearTimer
    interval: 20000
    repeat: false
    onTriggered: root.hideReveal()
  }
  function hideReveal() {
    revealClearTimer.stop()
    root.revealedField = ""
    root.revealedValue = ""
  }
  function revealField(shareId, itemId, field) {
    if (root.revealedField === field) { root.hideReveal(); return }
    root.revealedField = field
    root.revealedValue = ""
    revealFetchProc.field = field
    revealFetchProc.command = field === "totp"
      ? [root.wrapperScript, "totp", shareId, itemId]
      : [root.wrapperScript, "view", shareId, itemId, field]
    revealFetchProc.running = false; revealFetchProc.running = true
  }
  Process {
    id: revealFetchProc
    property string field: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          var v = revealFetchProc.field === "totp" ? (d.token || d.code || d.value) : d.value
          if (v) {
            root.revealedValue = String(v)
            revealClearTimer.restart()
          } else {
            root.revealedField = ""
          }
        } catch (e) {
          root.revealedField = ""
        }
      }
    }
  }

  // ── login: still needs a real TTY (one-time interactive web-login/2FA),
  // so it opens a terminal. Lock-code entry (unlock/create-lock/remove-lock)
  // is now inline via the pty-wrapped qs-protonpass-tty.py helper — the
  // code is written once to the Process's stdin and read with a line read
  // on the far end, not a wl-copy-style EOF claim, so a plain write() here
  // is sufficient (unlike the clipboard case documented above).
  Process {
    id: loginProc
    command: ["omarchy-launch-floating-terminal-with-presentation", "pass-cli login"]
  }
  function launchLogin() { loginProc.running = false; loginProc.running = true }

  Process {
    id: unlockPinProc
    property string pendingCode: ""
    command: [root.wrapperScript, "unlock"]
    stdinEnabled: true
    onStarted: { write(pendingCode + "\n"); pendingCode = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pinBusy = false
        var ok = false
        try { ok = JSON.parse(text).ok === true } catch (e) { ok = false }
        if (ok) {
          root.pinError = ""
          root.refreshStatus()
        } else {
          root.pinError = "Incorrect PIN"
          pinUnlockBoxes.clear()
        }
      }
    }
  }
  function submitUnlockPin(code) {
    root.pinBusy = true
    root.pinError = ""
    unlockPinProc.pendingCode = code
    unlockPinProc.running = false
    unlockPinProc.running = true
  }

  function clampedIdleTimeout() {
    var n = parseInt(root.lockSetupIdleTimeoutText, 10)
    if (!isFinite(n)) n = root.lockIdleTimeoutDefault
    return Math.max(30, Math.min(900, n))
  }

  Process {
    id: createLockProc
    property string pendingCode: ""
    property int idleTimeout: 300
    command: [root.wrapperScript, "create-lock", String(idleTimeout)]
    stdinEnabled: true
    onStarted: { write(pendingCode + "\n"); pendingCode = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pinBusy = false
        var ok = false
        try { ok = JSON.parse(text).ok === true } catch (e) { ok = false }
        if (ok) {
          root.lockSetupStage = ""
          root.lockSetupFirstCode = ""
          root.pinError = ""
          root.refreshStatus()
        } else {
          root.pinError = "Couldn't set up auto-lock — try again"
          root.lockSetupStage = "enter"
          root.lockSetupFirstCode = ""
          pinSetupBoxes.clear()
        }
      }
    }
  }
  function submitCreateLock(code) {
    root.pinBusy = true
    root.pinError = ""
    createLockProc.idleTimeout = root.clampedIdleTimeout()
    createLockProc.pendingCode = code
    createLockProc.running = false
    createLockProc.running = true
  }
  function startLockSetup() {
    root.lockSetupStage = "enter"
    root.lockSetupFirstCode = ""
    root.lockSetupIdleTimeoutText = String(root.lockIdleTimeoutDefault)
    root.pinError = ""
  }
  function cancelLockSetup() {
    root.lockSetupStage = ""
    root.lockSetupFirstCode = ""
    root.pinError = ""
  }
  function onLockSetupBoxesCompleted(code) {
    if (root.lockSetupStage === "enter") {
      root.lockSetupFirstCode = code
      root.lockSetupStage = "confirm"
      root.pinError = ""
      Qt.callLater(function() { pinSetupBoxes.clear() })
    } else if (root.lockSetupStage === "confirm") {
      if (code === root.lockSetupFirstCode) {
        root.submitCreateLock(code)
      } else {
        root.pinError = "PINs didn't match — try again"
        root.lockSetupStage = "enter"
        root.lockSetupFirstCode = ""
        pinSetupBoxes.clear()
      }
    } else if (root.lockSetupStage === "remove") {
      root.submitRemoveLock(code)
    }
  }
  function startLockRemoval() {
    root.lockSetupStage = "remove"
    root.pinError = ""
  }

  Process {
    id: removeLockProc
    property string pendingCode: ""
    command: [root.wrapperScript, "remove-lock"]
    stdinEnabled: true
    onStarted: { write(pendingCode + "\n"); pendingCode = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pinBusy = false
        var ok = false
        try { ok = JSON.parse(text).ok === true } catch (e) { ok = false }
        if (ok) {
          root.lockSetupStage = ""
          root.pinError = ""
          root.refreshStatus()
        } else {
          root.pinError = "Incorrect PIN"
          pinSetupBoxes.clear()
        }
      }
    }
  }
  function submitRemoveLock(code) {
    root.pinBusy = true
    root.pinError = ""
    removeLockProc.pendingCode = code
    removeLockProc.running = false
    removeLockProc.running = true
  }

  Process {
    id: logoutProc
    command: [root.wrapperScript, "logout"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refreshStatus()
    }
  }
  function signOut() { logoutProc.running = false; logoutProc.running = true }

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
          width: Style.space(11)
          height: Style.space(11)
          radius: width / 2
          color: "#e8a33d"
          border.width: 1
          border.color: Color.popups.background
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          Text {
            anchors.centerIn: parent
            text: "󰌾" // md-lock, verified via fontTools against the live Nerd Font
            color: "#1a1400"
            font.family: Style.font.family
            font.pixelSize: Style.space(8)
          }
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
    focusTarget: root.sessionState === "locked" ? pinUnlockBoxes
      : (root.sessionState === "unlocked" && root.lockSetupStage !== "") ? pinSetupBoxes
      : (root.sessionState === "unlocked") ? searchField
      : null

    onOpenChanged: {
      if (!open) {
        root.clearClipboardNow()
        root.copyFeedback = ""
        root.expandedKey = "" // cascades via onExpandedKeyChanged: clears reveal + detailUsername too
        root.searchQuery = ""
        searchField.text = ""
        root.cancelLockSetup()
        root.pinError = ""
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

    // ── 6-digit PIN entry: auto-advances on digit entry, backspace steps
    // back into an empty box, submits via `completed` once all boxes are
    // filled. FocusScope so `KeyboardPanel.focusTarget` can point at the
    // whole component and still land keyboard focus on whichever box is
    // logically focused (box 0 initially, or wherever clear()/focusIndex()
    // last left it) — a plain Item can't receive forceActiveFocus() and
    // hand it to the right descendant.
    component PinBoxes: FocusScope {
      id: pinBoxes
      property int length: 6
      property bool enabled: true
      signal completed(string code)

      implicitWidth: pinRow.implicitWidth
      implicitHeight: pinRow.implicitHeight

      function currentCode() {
        var s = ""
        for (var i = 0; i < pinRepeater.count; i++) {
          var it = pinRepeater.itemAt(i)
          s += it ? it.textInput.text : ""
        }
        return s
      }
      function focusIndex(i) {
        var it = pinRepeater.itemAt(i)
        if (it) it.textInput.forceActiveFocus()
      }
      function clear() {
        for (var i = 0; i < pinRepeater.count; i++) {
          var it = pinRepeater.itemAt(i)
          if (it) it.textInput.text = ""
        }
        Qt.callLater(function() { pinBoxes.focusIndex(0) })
      }

      Row {
        id: pinRow
        spacing: Style.spacing.sm
        Repeater {
          id: pinRepeater
          model: pinBoxes.length
          delegate: Rectangle {
            id: box
            required property int index
            property TextInput textInput: input
            width: Style.space(38)
            height: Style.space(46)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.05)
            border.width: input.activeFocus ? 2 : 1
            border.color: input.activeFocus ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)
            Behavior on border.color { ColorAnimation { duration: 100 } }

            TextInput {
              id: input
              anchors.fill: parent
              focus: box.index === 0
              horizontalAlignment: TextInput.AlignHCenter
              verticalAlignment: TextInput.AlignVCenter
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              maximumLength: 1
              echoMode: TextInput.Password
              passwordCharacter: "•"
              enabled: pinBoxes.enabled
              selectByMouse: true
              onTextChanged: {
                if (text.length > 1) { text = text.slice(-1); return }
                if (text.length === 1 && !/[0-9]/.test(text)) { text = ""; return }
                if (text.length === 1) {
                  if (box.index < pinBoxes.length - 1) pinBoxes.focusIndex(box.index + 1)
                  var code = pinBoxes.currentCode()
                  if (code.length === pinBoxes.length) pinBoxes.completed(code)
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Backspace && text.length === 0 && box.index > 0) {
                  pinBoxes.focusIndex(box.index - 1)
                  event.accepted = true
                }
              }
            }
          }
        }
      }
    }

    // ── credential field row: label + value, reveal + copy icons ──────────
    // Matches the extension's item-detail layout: username shown plain,
    // password/TOTP masked until explicitly revealed. Revealed values are
    // fetched fresh (never cached beyond root.revealedValue) and auto-hide
    // after 20s or when navigating away — see hideReveal()/onExpandedKeyChanged.
    component FieldRow: Rectangle {
      id: fr
      property string label: ""
      property string plainValue: ""
      property bool loading: false
      property bool secretField: false
      property bool revealed: false
      property string revealedText: ""
      signal copyRequested()
      signal revealRequested()

      width: parent.width
      height: Style.space(54)
      radius: Style.cornerRadius
      color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.05)
      border.width: 1
      border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)

      Column {
        anchors.left: parent.left
        anchors.right: actions.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: Style.spacing.sm
        spacing: Style.space(2)
        Text {
          text: fr.label
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width
          text: fr.loading ? "Loading…" : (fr.secretField ? (fr.revealed ? fr.revealedText : "••••••••••") : fr.plainValue)
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.xs
        spacing: Style.spacing.xxs
        PanelActionButton {
          visible: fr.secretField
          iconText: fr.revealed ? "󰈉" : "󰈈"
          foreground: Color.popups.text
          tooltipText: fr.revealed ? "Hide" : "Reveal"
          onClicked: fr.revealRequested()
        }
        PanelActionButton {
          iconText: "󰆏"
          foreground: Color.popups.text
          tooltipText: "Copy"
          onClicked: fr.copyRequested()
        }
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

      // ── locked: inline PIN unlock, styled after the extension's own
      // lock screen (logo, title, subtitle, 6 boxes, Sign out link) ───────
      Column {
        visible: root.sessionState === "locked"
        width: parent.width
        spacing: Style.spacing.lg

        PanelSeparator { foreground: Color.popups.text }

        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          source: "icon.svg"
          sourceSize.width: Style.space(48)
          sourceSize.height: Style.space(48)
          fillMode: Image.PreserveAspectFit
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Unlock Proton Pass"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Enter your PIN code"
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Item {
          width: parent.width
          height: pinUnlockBoxes.implicitHeight
          PinBoxes {
            id: pinUnlockBoxes
            anchors.horizontalCenter: parent.horizontalCenter
            enabled: !root.pinBusy
            onCompleted: function(code) { root.submitUnlockPin(code) }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.pinBusy || root.pinError !== ""
          text: root.pinBusy ? "Unlocking…" : root.pinError
          color: root.pinBusy ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5) : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Sign out"
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, signOutMa.containsMouse ? 0.8 : 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: signOutMa.containsMouse

          MouseArea {
            id: signOutMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.signOut()
          }
        }
      }

      // ── unlocked: auto-lock set up / change, PIN entry (enter → confirm,
      // or a single entry to confirm removal) ─────────────────────────────
      Column {
        visible: root.sessionState === "unlocked" && root.lockSetupStage !== ""
        width: parent.width
        spacing: Style.spacing.lg

        PanelSeparator { foreground: Color.popups.text }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.lockSetupStage === "enter" ? "Choose a PIN"
            : root.lockSetupStage === "confirm" ? "Confirm your PIN"
            : "Enter your PIN to remove auto-lock"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          visible: root.lockSetupStage === "enter"
          horizontalAlignment: Text.AlignHCenter
          text: "Pick a 6-digit PIN and how long you can be idle before it locks."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Row {
          visible: root.lockSetupStage === "enter"
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.sm
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Lock after"
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          TextField {
            id: idleTimeoutField
            width: Style.space(64)
            verticalPadding: Style.space(2)
            foreground: Color.popups.text
            text: root.lockSetupIdleTimeoutText
            validator: IntValidator { bottom: 30; top: 900 }
            onTextChanged: root.lockSetupIdleTimeoutText = text
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "s idle (30–900)"
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: pinSetupBoxes.implicitHeight
          PinBoxes {
            id: pinSetupBoxes
            anchors.horizontalCenter: parent.horizontalCenter
            enabled: !root.pinBusy
            onCompleted: function(code) { root.onLockSetupBoxesCompleted(code) }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.pinBusy || root.pinError !== ""
          text: root.pinBusy ? "Working…" : root.pinError
          color: root.pinBusy ? Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5) : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        ActionBtn { label: "Cancel"; onClicked: root.cancelLockSetup() }
      }

      // ── unlocked: list view (vault picker + search + item list) ─────────
      Column {
        visible: root.sessionState === "unlocked" && root.expandedKey === "" && root.lockSetupStage === ""
        width: parent.width
        spacing: Style.spacing.md

        PanelSeparator { foreground: Color.popups.text }

        // Auto-lock status/setup — only pass-cli's own lock exists here,
        // separate from (and unreadable from) the browser extension's PIN;
        // see the header comment for why we can't just reuse the extension's.
        Item {
          width: parent.width
          height: lockStatusRow.implicitHeight
          Row {
            id: lockStatusRow
            width: parent.width
            spacing: Style.spacing.sm
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰌾"
              color: root.hasLock ? Color.accent : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(24) - autoLockLink.implicitWidth - Style.spacing.sm * 2
              text: root.hasLock ? ("Auto-lock on · " + (root.configuredIdleTimeout !== null ? root.configuredIdleTimeout + "s idle" : "idle timeout unknown")) : "Auto-lock isn't set up"
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Text {
              id: autoLockLink
              anchors.verticalCenter: parent.verticalCenter
              text: root.hasLock ? "Remove" : "Set up"
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, autoLockMa.containsMouse ? 1.0 : 0.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.underline: autoLockMa.containsMouse
              MouseArea {
                id: autoLockMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.hasLock ? root.startLockRemoval() : root.startLockSetup()
              }
            }
          }
        }

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
              delegate: Rectangle {
                id: rowCol
                required property var modelData
                readonly property string key: root.itemKey(modelData)
                width: itemsCol.width
                height: Style.space(44)
                radius: Style.cornerRadius
                color: rowMa.containsMouse
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
                  id: navArrow
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰅂"
                  color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, rowMa.containsMouse ? 0.6 : 0.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  Behavior on color { ColorAnimation { duration: 100 } }
                }

                Column {
                  anchors.left: avatar.right
                  anchors.right: navArrow.left
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
                    root.expandedKey = rowCol.key
                  }
                }
              }
            }
          }
        }
      }

      // ── unlocked: item detail (username/password/TOTP fields) ───────────
      Column {
        id: detailCol
        visible: root.sessionState === "unlocked" && root.expandedKey !== ""
        width: parent.width
        spacing: Style.spacing.md

        readonly property var item: root.findItem(root.expandedKey)
        readonly property bool isLogin: detailCol.item && detailCol.item.item_type === "login"

        PanelSeparator { foreground: Color.popups.text }

        Item {
          width: parent.width
          height: Math.max(Style.space(28), backBtn.height)

          PanelActionButton {
            id: backBtn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅁"
            foreground: Color.popups.text
            tooltipText: "Back"
            onClicked: root.expandedKey = ""
          }
          Rectangle {
            id: detailAvatar
            width: Style.space(28)
            height: Style.space(28)
            radius: Style.cornerRadius
            anchors.left: backBtn.right
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            color: root.avatarColor(detailCol.item ? detailCol.item.title : "")
            Text {
              anchors.centerIn: parent
              text: (detailCol.item && detailCol.item.title ? detailCol.item.title : "?").charAt(0).toUpperCase()
              color: "white"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
          Column {
            anchors.left: detailAvatar.right
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            Text {
              width: parent.width
              text: detailCol.item ? detailCol.item.title : ""
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              visible: text !== ""
              text: detailCol.item ? (detailCol.item.vault_name || "") : ""
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Column {
          visible: detailCol.isLogin
          width: parent.width
          spacing: Style.spacing.xs

          FieldRow {
            label: "Username"
            loading: root.detailUsernameLoading
            plainValue: root.detailUsername
            onCopyRequested: root.copyField(detailCol.item.share_id, detailCol.item.id, "username", "username")
          }
          FieldRow {
            label: "Password"
            secretField: true
            revealed: root.revealedField === "password"
            revealedText: root.revealedValue
            onRevealRequested: root.revealField(detailCol.item.share_id, detailCol.item.id, "password")
            onCopyRequested: root.copyField(detailCol.item.share_id, detailCol.item.id, "password", "password")
          }
          FieldRow {
            label: "2FA code"
            secretField: true
            revealed: root.revealedField === "totp"
            revealedText: root.revealedValue
            onRevealRequested: root.revealField(detailCol.item.share_id, detailCol.item.id, "totp")
            onCopyRequested: root.copyTotp(detailCol.item.share_id, detailCol.item.id)
          }
          FieldRow {
            visible: root.detailUrls.length > 0
            label: "Website"
            plainValue: root.detailUrls.length > 0 ? root.detailUrls[0] : ""
            onCopyRequested: {
              root.copyToClipboard(root.detailUrls[0])
              root.copyFeedback = "Copied website"
            }
          }
        }

        // Not a secret field, so no card / no copy action — just metadata,
        // same as the extension's plain (uncarded) detail rows.
        Column {
          visible: detailCol.isLogin && root.detailModified !== ""
          width: parent.width
          spacing: Style.space(2)
          Text {
            text: "Last modified"
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            text: {
              var d = new Date(root.detailModified)
              return isNaN(d.getTime()) ? root.detailModified : Qt.formatDateTime(d, "MMM d, yyyy · h:mm AP")
            }
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: detailCol.item && !detailCol.isLogin
          width: parent.width
          text: "This item type isn't supported here yet — open it in the Proton Pass app."
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          visible: root.copyFeedback !== ""
          width: parent.width
          text: root.copyFeedback + " — clears in 35s"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
