import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Ask AI on the bar. The panel sets what Super+Shift+A (bin/ask-ai) does: which
// AI gets the capture, the pre-prompt that goes with it, whether to press Enter,
// and whether the chat opens on the scratchpad (Super+S). Choices save as
// they change, to ~/.local/state/ask-ai/state.json.
// Click the icon for the panel; right-click it to capture straight away.
Panel {
  id: root
  moduleName: "skylightlim.ask-ai"
  ipcTarget: "skylightlim.ask-ai"
  manageIpc: false // our IpcHandler below adds record()
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var defaultConfig: ({})
  property var userConfig: null
  property string lastWrittenState: ""
  property string flash: ""

  readonly property var config: mergeConfig(defaultConfig, userConfig)
  readonly property var targets: config.targets
  readonly property var prompts: config.prompts

  // The current choices. An empty promptName means the user's own text.
  property bool firstRun: true
  property string targetName: ""
  property string promptName: ""
  property string customText: ""
  property bool submit: false
  property bool special: false
  property bool card: true

  readonly property int targetIndex: indexOf(root.targets, root.targetName, 0)
  readonly property int promptIndex: root.firstRun
    ? (root.prompts.length ? 0 : -1)
    : (root.promptName ? indexOf(root.prompts, root.promptName, -1) : -1)
  readonly property string promptText: root.promptIndex >= 0 ? root.prompts[root.promptIndex].text : root.customText
  property bool syncing: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/ask-ai/config.json"
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state") + "/ask-ai/state.json"

  readonly property color foreground: Commons.Color.foreground
  readonly property color muted: Commons.Color.muted
  readonly property color accent: Commons.Color.accent
  readonly property string glyph: "󰙴"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ config

  function str(value, max) {
    return typeof value === "string" ? value.slice(0, max) : ""
  }

  function indexOf(list, name, fallback) {
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return i
    return list.length ? fallback : -1
  }

  function cleanTargets(list) {
    if (!Array.isArray(list)) return null
    var out = []
    for (var i = 0; i < list.length && out.length < 12; i++) {
      var t = list[i]
      if (!t || typeof t !== "object") continue
      var name = str(t.name, 40).trim()
      var url = str(t.url, 2000).trim()
      if (!name || (url && !/^https?:\/\//i.test(url))) continue
      out.push({ name: name, url: url, match: str(t.match, 200) })
    }
    return out.length ? out : null
  }

  function cleanPrompts(list) {
    if (!Array.isArray(list)) return null
    var out = []
    for (var i = 0; i < list.length && out.length < 50; i++) {
      var p = list[i]
      if (!p || typeof p !== "object") continue
      var name = str(p.name, 60).trim()
      if (name) out.push({ name: name, text: str(p.text, 8000) })
    }
    return out
  }

  // User values win field by field; anything missing or invalid falls back.
  function mergeConfig(defaults, user) {
    var d = defaults || ({})
    var u = user || ({})
    var prompts = cleanPrompts(u.prompts)
    return {
      targets: cleanTargets(u.targets) || cleanTargets(d.targets) || [{ name: "ChatGPT", url: "https://chatgpt.com/", match: "ChatGPT" }],
      prompts: prompts !== null ? prompts : (cleanPrompts(d.prompts) || [])
    }
  }

  function parse(text) {
    try {
      var value = JSON.parse(text || "")
      return value && typeof value === "object" && !Array.isArray(value) ? value : null
    } catch (e) {
      return null
    }
  }

  function applyState(st) {
    root.firstRun = st.target === undefined
    root.targetName = str(st.target, 40)
    root.promptName = str(st.prompt, 60)
    root.customText = str(st.custom, 8000)
    root.submit = st.submit === true
    root.special = st.special === true
    root.card = st.card !== false
    syncField()
  }

  function saveState() {
    var target = root.targets[root.targetIndex]
    var st = {
      target: target ? target.name : "",
      prompt: root.promptIndex >= 0 ? root.prompts[root.promptIndex].name : "",
      custom: root.customText,
      submit: root.submit,
      special: root.special,
      card: root.card
    }
    root.firstRun = false
    root.targetName = st.target
    root.promptName = st.prompt
    var text = JSON.stringify(st, null, 2) + "\n"
    root.lastWrittenState = text
    stateFile.setText(text)
  }

  // Saves the pre-prompt list, keeping every other key the user has set.
  function writePrompts(list) {
    var out = ({})
    var base = root.userConfig || root.defaultConfig || ({})
    for (var key in base) out[key] = base[key]
    out.prompts = list
    configFile.setText(JSON.stringify(out, null, 2) + "\n")
    root.userConfig = out
  }

  FileView {
    path: root.pluginDir + "config.default.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultConfig = root.parse(text()) || ({}); root.syncField() }
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userConfig = root.parse(text()); root.syncField() }
    onLoadFailed: root.userConfig = null
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    // Our own writes come back through the watch; only outside edits apply.
    onLoaded: if (text() !== root.lastWrittenState) root.applyState(root.parse(text()) || ({}))
    onFileChanged: reload()
  }

  onOpenedChanged: {
    if (!opened) {
      root.recordHint = ""
      stopRecording()
      return
    }
    root.flash = ""
    shortcutProc.running = true
    // The capture script creates these on first use.
    configFile.reload()
    stateFile.reload()
    syncField()
  }

  // ------------------------------------------------------------ actions

  function syncField() {
    if (promptField.activeFocus) return
    root.syncing = true
    promptField.text = root.promptText
    root.syncing = false
  }

  function selectTarget(index) {
    if (index < 0 || index >= root.targets.length) return
    root.targetName = root.targets[index].name
    root.firstRun = false
    saveState()
  }

  function stepTarget(delta) {
    var n = root.targets.length
    if (n) selectTarget((root.targetIndex + delta + n) % n)
  }

  function selectPrompt(index) {
    if (index < 0 || index >= root.prompts.length) return
    root.firstRun = false
    root.promptName = root.prompts[index].name
    saveState()
    if (root.opened) keyCatcher.forceActiveFocus()
    syncField()
  }

  function stepPrompt(delta) {
    var n = root.prompts.length
    if (!n) return
    selectPrompt(root.promptIndex < 0 ? (delta > 0 ? 0 : n - 1) : (root.promptIndex + delta + n) % n)
  }

  // Typing over a pre-prompt turns it into the user's own text.
  function promptEdited(text) {
    if (root.syncing) return
    if (root.promptIndex >= 0 && text === root.prompts[root.promptIndex].text) return
    root.firstRun = false
    root.promptName = ""
    root.customText = text
    saveTimer.restart()
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: root.saveState()
  }

  // A blank prompt to type a new pre-prompt into.
  function newPrompt() {
    root.firstRun = false
    root.promptName = ""
    root.customText = ""
    saveState()
    syncField()
    promptField.forceActiveFocus()
  }

  function toggleSubmit() {
    root.submit = !root.submit
    saveState()
  }

  function toggleSpecial() {
    root.special = !root.special
    saveState()
  }

  function toggleCard() {
    root.card = !root.card
    saveState()
  }

  // The hidden browser's own sign-ins, in a visible window.
  function signIn() {
    root.close()
    Quickshell.execDetached([root.pluginDir + "bin/ask-ai-login"])
  }

  function savePrompt() {
    var text = promptField.text.trim()
    if (!text) return
    for (var i = 0; i < root.prompts.length; i++) {
      if (root.prompts[i].text.trim() === text) { selectPrompt(i); return }
    }
    var name = text.split("\n")[0].trim()
    if (name.length > 28) name = name.slice(0, 27).trim() + "…"
    var base = name
    for (var n = 2; indexOf(root.prompts, name, -1) >= 0; n++) name = base + " " + n
    var next = root.prompts.slice()
    next.push({ name: name, text: text })
    writePrompts(next)
    selectPrompt(next.length - 1)
    root.flash = strings.t("saved").arg(name)
  }

  function deletePrompt() {
    if (root.promptIndex < 0) return
    var name = root.prompts[root.promptIndex].name
    var next = root.prompts.slice()
    next.splice(root.promptIndex, 1)
    root.customText = root.prompts[root.promptIndex].text
    writePrompts(next)
    root.promptName = ""
    saveState()
    syncField()
    root.flash = strings.t("deleted").arg(name)
  }

  function editConfig() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-editor", root.configPath])
  }

  // Close first, so the panel isn't in the capture.
  function captureNow() {
    if (saveTimer.running) { saveTimer.stop(); saveState() }
    root.close()
    captureTimer.restart()
  }

  Timer {
    id: captureTimer
    interval: 250
    onTriggered: Quickshell.execDetached([root.pluginDir + "bin/ask-ai"])
  }


  // ------------------------------------------------------------ shortcut

  property string shortcut: "SUPER + SHIFT + A"
  property bool recording: false
  property var heldKeys: []
  property string recordHint: ""
  property string pendingKeys: "" // a taken shortcut pressed once; again confirms

  function keyParts(combo) {
    return String(combo || "").split("+").map(function(p) { return p.trim() }).filter(function(p) { return p !== "" })
  }

  function prettyKey(name) {
    var fixed = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" }
    if (fixed[name]) return fixed[name]
    if (name.length === 1 || /^F\d+$/.test(name) || name === "…") return name
    return name.toLowerCase().split("_").map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
  }

  function modifierNames(mods) {
    var out = []
    if (mods & Qt.MetaModifier) out.push("SUPER")
    if (mods & Qt.ControlModifier) out.push("CTRL")
    if (mods & Qt.AltModifier) out.push("ALT")
    if (mods & Qt.ShiftModifier) out.push("SHIFT")
    return out
  }

  function modifierOf(key) {
    if (key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R) return Qt.MetaModifier
    if (key === Qt.Key_Control) return Qt.ControlModifier
    if (key === Qt.Key_Alt) return Qt.AltModifier
    if (key === Qt.Key_Shift) return Qt.ShiftModifier
    return 0
  }

  // Qt key -> Hyprland key name; "" for modifiers and keys it can't bind.
  // Shifted symbols map back to their key ("!" is 1), as Hyprland binds keys.
  readonly property var keyNames: {
    var pairs = [
      [Qt.Key_Space, "SPACE"], [Qt.Key_Return, "RETURN"], [Qt.Key_Enter, "RETURN"], [Qt.Key_Tab, "TAB"],
      [Qt.Key_Backtab, "TAB"], [Qt.Key_Backspace, "BACKSPACE"], [Qt.Key_Delete, "DELETE"], [Qt.Key_Insert, "INSERT"],
      [Qt.Key_Home, "HOME"], [Qt.Key_End, "END"], [Qt.Key_PageUp, "PAGE_UP"], [Qt.Key_PageDown, "PAGE_DOWN"],
      [Qt.Key_Left, "LEFT"], [Qt.Key_Right, "RIGHT"], [Qt.Key_Up, "UP"], [Qt.Key_Down, "DOWN"],
      [Qt.Key_Print, "PRINT"], [Qt.Key_Pause, "PAUSE"], [Qt.Key_Escape, "ESCAPE"],
      [Qt.Key_Comma, "COMMA"], [Qt.Key_Period, "PERIOD"], [Qt.Key_Slash, "SLASH"], [Qt.Key_Semicolon, "SEMICOLON"],
      [Qt.Key_Apostrophe, "APOSTROPHE"], [Qt.Key_BracketLeft, "BRACKETLEFT"], [Qt.Key_BracketRight, "BRACKETRIGHT"],
      [Qt.Key_Minus, "MINUS"], [Qt.Key_Equal, "EQUAL"], [Qt.Key_QuoteLeft, "GRAVE"], [Qt.Key_Backslash, "BACKSLASH"],
      [Qt.Key_Exclam, "1"], [Qt.Key_At, "2"], [Qt.Key_NumberSign, "3"], [Qt.Key_Dollar, "4"], [Qt.Key_Percent, "5"],
      [Qt.Key_AsciiCircum, "6"], [Qt.Key_Ampersand, "7"], [Qt.Key_Asterisk, "8"], [Qt.Key_ParenLeft, "9"],
      [Qt.Key_ParenRight, "0"], [Qt.Key_Underscore, "MINUS"], [Qt.Key_Plus, "EQUAL"], [Qt.Key_BraceLeft, "BRACKETLEFT"],
      [Qt.Key_BraceRight, "BRACKETRIGHT"], [Qt.Key_Colon, "SEMICOLON"], [Qt.Key_QuoteDbl, "APOSTROPHE"],
      [Qt.Key_Less, "COMMA"], [Qt.Key_Greater, "PERIOD"], [Qt.Key_Question, "SLASH"], [Qt.Key_AsciiTilde, "GRAVE"],
      [Qt.Key_Bar, "BACKSLASH"]
    ]
    var map = ({})
    for (var i = 0; i < pairs.length; i++) map[pairs[i][0]] = pairs[i][1]
    return map
  }

  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F24) return "F" + (key - Qt.Key_F1 + 1)
    return root.keyNames[key] || ""
  }

  function startRecording() {
    root.recording = true
    root.heldKeys = []
    root.recordHint = ""
    root.pendingKeys = ""
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.submap("ask-ai-record")'])
    recordTimeout.restart()
    recorder.forceActiveFocus()
  }

  function stopRecording() {
    if (!root.recording) return
    root.recording = false
    root.heldKeys = []
    recordTimeout.stop()
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.submap("reset")'])
    if (root.opened) keyCatcher.forceActiveFocus()
  }

  function recordKey(event) {
    event.accepted = true
    if (!root.recording) return
    recordTimeout.restart()
    var mods = root.modifierNames(event.modifiers)
    var key = root.keyName(event.key)
    if (key === "") {                       // a modifier on its own: show it held
      root.heldKeys = root.modifierNames(event.modifiers | root.modifierOf(event.key))
      return
    }
    if (key === "ESCAPE" && mods.length === 0) {
      root.recordHint = ""
      root.stopRecording()
      return
    }
    // A bare key would fire while typing; function keys and Print stand alone.
    if (mods.length === 0 && !/^(F\d+|PRINT|PAUSE|INSERT)$/.test(key)) {
      root.heldKeys = [key]
      root.recordHint = strings.t("shortcut.needsModifier")
      return
    }
    var combo = mods.concat([key]).join(" + ")
    root.heldKeys = mods.concat([key])
    checkProc.combo = combo
    checkProc.command = [root.pluginDir + "bin/ask-ai-bind", "--check", combo]
    checkProc.running = true
  }

  function checked(combo, result) {
    if (!root.recording) return
    if (result === "same") {
      root.recordHint = ""
      root.stopRecording()
    } else if (result === "free" || root.pendingKeys === combo) {
      applyProc.combo = combo
      applyProc.command = [root.pluginDir + "bin/ask-ai-bind", combo]
      applyProc.running = true
    } else {
      root.pendingKeys = combo
      root.recordHint = strings.t("shortcut.taken")
        .arg(root.keyParts(combo).map(root.prettyKey).join(" ")).arg(result || "?")
    }
  }

  Timer {
    id: recordTimeout
    interval: 12000
    onTriggered: { root.recordHint = ""; root.stopRecording() }
  }

  Process {
    id: checkProc
    property string combo: ""
    stdout: StdioCollector { onStreamFinished: root.checked(checkProc.combo, String(text).trim()) }
  }

  Process {
    id: applyProc
    property string combo: ""
    onExited: function(code) {
      if (code === 0) {
        root.shortcut = applyProc.combo
        root.recordHint = ""
      } else {
        root.recordHint = strings.t("shortcut.failed").arg(root.keyParts(applyProc.combo).map(root.prettyKey).join(" "))
      }
      root.stopRecording()
    }
  }

  Process {
    id: shortcutProc
    command: [root.pluginDir + "bin/ask-ai-bind", "--show"]
    stdout: StdioCollector {
      onStreamFinished: { var keys = String(text).trim(); if (keys) root.shortcut = keys }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function record(): void { root.open(); root.startRecording() }
  }

  // ------------------------------------------------------------ view
  //
  // Groups are set apart by space, not rules: a generous gap between groups,
  // a tight one inside them. Everything takes the theme's colours and font,
  // so the panel sits with the bar's other panels; the accent marks only what
  // is selected.

  readonly property int groupGap: Style.space(20)
  readonly property int innerGap: Style.spacing.lg

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // One key of the capture shortcut.
  component Keycap: Rectangle {
    property alias label: keyLabel.text
    property bool hot: false
    implicitWidth: Math.max(keyLabel.implicitWidth + Style.spacing.md * 2, implicitHeight)
    implicitHeight: keyLabel.implicitHeight + Style.spacing.xxs * 2
    radius: Math.min(Style.cornerRadius, Style.space(4))
    color: Util.alpha(root.foreground, hot ? 0.1 : 0.05)
    border.width: 1
    border.color: hot ? root.accent : Util.alpha(root.foreground, 0.2)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Label {
      id: keyLabel
      anchors.centerIn: parent
      font.pixelSize: Style.font.caption
    }
  }

  // A setting that is on or off: its name, any key that goes with it, and a
  // switch. The name toggles too.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property var keys: []
    property bool checked: false
    signal toggled()

    implicitHeight: Math.max(switchLabel.implicitHeight, rowSwitch.implicitHeight)

    Row {
      anchors.left: parent.left
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.lg

      Label {
        id: switchLabel
        anchors.verticalCenter: parent.verticalCenter
        text: switchRow.label

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: switchRow.toggled()
        }
      }

      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs
        Repeater {
          model: switchRow.keys
          Keycap { required property string modelData; label: modelData }
        }
      }
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: root.foreground
      accent: root.accent
      onToggled: switchRow.toggled()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.opened ? "" : strings.t("tooltip")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.captureNow()
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx) root.stepTarget(dx)
        if (dy) root.stepPrompt(dy)
      }
      onActivateRequested: root.captureNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t, modifiers) {
        if (t === "e" || t === "E") promptField.forceActiveFocus()
        else if (t === "s" || t === "S") root.toggleSubmit()
        else if (t === "w" || t === "W") root.toggleSpecial()
        else if (t === "c" || t === "C") root.toggleCard()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: root.groupGap

          // The shortcut, as keys. Click them to record a new one.
          Column {
            width: parent.width
            spacing: Style.spacing.md

            Row {
              spacing: Style.spacing.xl

              Label {
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyph
                font.pixelSize: Style.font.title
              }

              Item {
                id: shortcutKeys
                anchors.verticalCenter: parent.verticalCenter
                width: keyRow.implicitWidth
                height: keyRow.implicitHeight

                Row {
                  id: keyRow
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.recording ? (root.heldKeys.length ? root.heldKeys : ["…"]) : root.keyParts(root.shortcut)
                    Keycap {
                      required property string modelData
                      label: root.prettyKey(modelData)
                      hot: shortcutMouse.containsMouse || root.recording
                    }
                  }
                }

                MouseArea {
                  id: shortcutMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.recording ? root.stopRecording() : root.startRecording()
                }
              }

              Label {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.recording
                text: strings.t("shortcut.press")
                color: root.foreground
                opacity: 0.7
                font.pixelSize: Style.font.bodySmall
              }
            }

            Label {
              width: parent.width
              visible: root.recordHint !== ""
              wrapMode: Text.Wrap
              text: root.recordHint
              color: root.accent
              font.pixelSize: Style.font.bodySmall
            }

            // Takes the keys while recording; Hyprland's own shortcuts are
            // off meanwhile (the ask-ai-record submap), so every key lands here.
            Item {
              id: recorder
              width: 0
              height: 0
              Keys.onPressed: function(event) { root.recordKey(event) }
              Keys.onReleased: function(event) {
                if (root.recording && root.keyName(event.key) === "")
                  root.heldKeys = root.modifierNames(event.modifiers & ~root.modifierOf(event.key))
                event.accepted = true
              }
            }
          }

          // Where it goes.
          Column {
            width: parent.width
            spacing: root.innerGap

            PanelSectionHeader { text: strings.t("sendTo") }

            Flow {
              width: parent.width
              spacing: Style.spacing.md

              Repeater {
                model: root.targets

                Button {
                  required property var modelData
                  required property int index
                  text: modelData.name
                  selected: index === root.targetIndex
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.selectTarget(index)
                }
              }
            }
          }

          // What it says: a saved pre-prompt, or the user's own words.
          Column {
            width: parent.width
            spacing: root.innerGap

            Item {
              width: parent.width
              // Sized to the label alone, so this section's label sits as close
              // to its chips as "Send to" does; the small buttons overhang.
              height: promptHeader.implicitHeight

              PanelSectionHeader {
                id: promptHeader
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("prompt")
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.lg

                Label {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.flash
                  color: root.accent
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  text: strings.t("savePrompt")
                  foreground: root.foreground
                  accent: root.accent
                  visible: root.promptIndex < 0 && root.customText.trim() !== ""
                  onClicked: root.savePrompt()
                }

                Button {
                  text: strings.t("deletePrompt")
                  foreground: root.foreground
                  accent: root.accent
                  visible: root.promptIndex >= 0
                  onClicked: root.deletePrompt()
                }

                Button {
                  id: newButton
                  text: "+ " + strings.t("newPrompt")
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.newPrompt()
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.md
              visible: root.prompts.length > 0

              Repeater {
                model: root.prompts

                Button {
                  required property var modelData
                  required property int index
                  text: modelData.name
                  selected: index === root.promptIndex
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  onClicked: root.selectPrompt(index)
                }
              }
            }

            BorderSurface {
              width: parent.width
              height: Math.min(Math.max(promptField.implicitHeight, Style.space(56)), Style.space(140))
              radius: Style.cornerRadius
              color: Style.controlFill(promptField.activeFocus, promptHover.hovered, root.foreground, root.accent)
              borderSpec: Border.controlSpec(promptField.activeFocus ? "focus" : (promptHover.hovered ? "hover-cursor" : "normal"), root.foreground, root.accent)

              // A longer prompt grows the box rather than jumping it.
              Behavior on height {
                NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
              }

              HoverHandler { id: promptHover; cursorShape: Qt.IBeamCursor }

              QQC.ScrollView {
                anchors.fill: parent
                anchors.margins: Border.left(parent.borderSpec)
                clip: true
                // The text wraps, so it only ever scrolls down.
                contentWidth: availableWidth
                QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

                QQC.TextArea {
                  id: promptField
                  placeholderText: strings.t("placeholder")
                  placeholderTextColor: root.muted
                  color: root.foreground
                  selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                  selectedTextColor: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: TextEdit.Wrap
                  textFormat: TextEdit.PlainText
                  leftPadding: Style.spacing.controlPaddingX
                  rightPadding: Style.spacing.controlPaddingX
                  topPadding: Style.spacing.inputPaddingY
                  bottomPadding: Style.spacing.inputPaddingY
                  background: null

                  onTextChanged: root.promptEdited(text)

                  Keys.onPressed: function(event) {
                    if (promptField.inputMethodComposing) return
                    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                    if (event.key === Qt.Key_Escape || ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !shift)) {
                      // Done editing: back to the panel's keys.
                      if (saveTimer.running) { saveTimer.stop(); root.saveState() }
                      keyCatcher.forceActiveFocus()
                    } else if (ctrl && event.key === Qt.Key_S) {
                      root.savePrompt()
                    } else {
                      return
                    }
                    event.accepted = true
                  }
                }
              }
            }
          }

          // How it behaves once it gets there.
          Column {
            width: parent.width
            spacing: Style.spacing.xl

            SwitchRow {
              width: parent.width
              label: strings.t("card")
              checked: root.card
              onToggled: root.toggleCard()
            }

            // These only apply when the chat opens in your own browser.
            SwitchRow {
              width: parent.width
              visible: !root.card
              label: strings.t("autoSend")
              checked: root.submit
              onToggled: root.toggleSubmit()
            }

            SwitchRow {
              width: parent.width
              visible: !root.card
              label: strings.t("special")
              keys: ["Super", "S"]
              checked: root.special
              onToggled: root.toggleSpecial()
            }
          }

          Item {
            width: parent.width
            height: editButton.implicitHeight

            Row {
              anchors.right: parent.right
              spacing: Style.spacing.lg

              Button {
                text: strings.t("signIn")
                foreground: root.foreground
                accent: root.accent
                onClicked: root.signIn()
              }

              Button {
                id: editButton
                text: strings.t("editConfig")
                foreground: root.foreground
                accent: root.accent
                onClicked: root.editConfig()
              }
            }
          }
        }
      }
    }
  }
}
