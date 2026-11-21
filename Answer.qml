import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The answer card. bin/ask-ai summons it with {"job": "<file>"}; the hidden
// browser (browser/askd.py) writes that file as the AI answers:
//   {status: starting|sending|thinking|writing|done|error, ai, text, url, error}
// The card follows the file until it's done. It floats in the top-right
// corner and only takes the keyboard when clicked, so work carries on.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string jobPath: ""
  property var job: ({})

  readonly property string status: str(job.status, 20)
  readonly property bool busy: status !== "done" && status !== "error"
  readonly property string answer: str(job.text, 200000)
  readonly property string chatUrl: /^https:\/\//.test(str(job.url, 2000)) ? str(job.url, 2000) : ""

  readonly property int cardWidth: Math.min(Style.space(420), (targetScreen ? targetScreen.width : 1200) * 0.4)
  readonly property int maxCardHeight: (targetScreen ? targetScreen.height : 800) * 0.7

  readonly property color foreground: Commons.Color.menu.text
  readonly property color muted: Commons.Color.muted
  readonly property color accent: Commons.Color.accent

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function str(value, max) {
    return typeof value === "string" ? value.slice(0, max) : ""
  }

  // Answers come from a web page: show their Markdown, but never let it load
  // anything. Images and raw HTML are dropped; links stay as text you click.
  function safeMarkdown(text) {
    return text
      .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
      .replace(/<[^>]*>/g, "")
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    var path = str(payload.job, 4096)
    if (!/^\/.+\.json$/.test(path)) return
    root.job = ({ status: "starting", ai: str(payload.ai, 40) })
    root.jobPath = path
    jobFile.reload()
    root.targetScreen = root.focusedScreen()
    slide.x = 0
    root.focusPrimed = false
    primeTimer.restart()
    root.opened = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "skylightlim.ask-ai")
  }

  function statusLine() {
    switch (root.status) {
    case "starting": return strings.t("answer.starting")
    case "sending": return strings.t("answer.sending")
    case "thinking": return strings.t("answer.thinking")
    case "writing": return strings.t("answer.writing")
    case "error": return str(root.job.error, 300) || strings.t("answer.failed")
    default: return ""
    }
  }

  FileView {
    id: jobFile
    path: root.jobPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var next = JSON.parse(text())
        if (next && typeof next === "object") root.job = next
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // One fixed-size, see-through window in the top-right corner. The card
  // grows inside it; the window itself never resizes, because a resizing
  // layer surface flickers. Clicks outside the card pass through.
  property var targetScreen: null
  property bool focusPrimed: true

  Timer {
    id: primeTimer
    interval: 75
    onTriggered: root.focusPrimed = true
  }

  PanelWindow {
    id: window
    visible: root.opened && !!root.targetScreen
    screen: root.targetScreen
    anchors { top: true; right: true }
    margins {
      top: Style.bar.sizeHorizontal + Style.gapsOut * 2
      right: Style.gapsOut * 2
    }
    implicitWidth: root.cardWidth
    implicitHeight: root.maxCardHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: card }
    WlrLayershell.namespace: "skylightlim-ask-ai-answer"
    WlrLayershell.layer: WlrLayer.Overlay
    // Ask for the keyboard outright for a moment as the card appears (as
    // Omarchy's own panels do), then only when clicked: Esc works at once,
    // and a click anywhere else takes the keyboard back.
    WlrLayershell.keyboardFocus: root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    onVisibleChanged: if (visible) Qt.callLater(function() { keys.forceActiveFocus() })

    BorderSurface {
      id: card
      anchors.top: parent.top
      anchors.right: parent.right
      width: root.cardWidth
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset, root.maxCardHeight)
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      clip: true

      // Arrives once, gently; after that it only grows as text comes in.
      // Dragged to the right it fades as it goes, and past a third of its
      // width (or flung) it leaves.
      opacity: (root.opened ? 1 : 0) * (1 - Math.min(slide.x / width, 1) * 0.7)
      scale: root.opened ? 1 : 0.97
      transformOrigin: Item.TopRight
      transform: Translate { id: slide }
      Behavior on opacity {
        enabled: !swipe.active && !flyOut.running && !settle.running
        NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
      }
      Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      DragHandler {
        id: swipe
        target: null
        yAxis.enabled: false
        // Text keeps its drag for selecting; swipe from anywhere else.
        grabPermissions: PointerHandler.TakeOverForbidden
        onTranslationChanged: slide.x = Math.max(0, translation.x)
        onActiveChanged: {
          if (active) return
          if (slide.x > card.width / 3 || centroid.velocity.x > 700) flyOut.start()
          else settle.start()
        }
      }

      NumberAnimation {
        id: flyOut
        target: slide; property: "x"
        to: card.width + Style.gapsOut * 4
        duration: Style.duration(140); easing.type: Easing.OutCubic
        onFinished: root.dismiss()
      }

      NumberAnimation {
        id: settle
        target: slide; property: "x"
        to: 0
        duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut
      }

      // Takes the keyboard when the card appears, so Esc closes it; a click
      // anywhere else hands the keyboard back.
      Item {
        id: keys
        focus: true
        Keys.onEscapePressed: root.dismiss()
      }

      FontMetrics {
        id: line
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        width: card.width - card.contentLeftInset - card.contentRightInset
        spacing: Style.spacing.lg

        // What it's doing, until there's an answer to show.
        Label {
          width: parent.width
          rightPadding: closeButton.width + Style.spacing.lg
          visible: root.status === "error" || (root.busy && root.answer === "")
          wrapMode: Text.Wrap
          text: root.statusLine()
          color: root.foreground
          opacity: root.status === "error" ? 1 : 0.7
        }

        QQC.ScrollView {
          id: answerScroll
          width: parent.width
          visible: root.answer !== ""
          height: Math.min(answerText.implicitHeight, root.maxCardHeight - Style.space(90))
          contentWidth: availableWidth
          QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff
          clip: true

          QQC.TextArea {
            id: answerText
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.MarkdownText
            text: root.safeMarkdown(root.answer)
            color: root.foreground
            selectionColor: Style.selectionFillFor(root.foreground, root.accent)
            selectedTextColor: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            padding: 0
            // Room for the close button beside the first line.
            rightPadding: closeButton.width + Style.spacing.lg
            background: null
            onLinkActivated: function(link) {
              if (/^https?:\/\//.test(link)) Qt.openUrlExternally(link)
            }
          }
        }

        Row {
          anchors.right: parent.right
          spacing: Style.spacing.sm
          visible: !root.busy && (root.answer !== "" || root.chatUrl !== "")

          Button {
            text: strings.t("answer.copy")
            visible: root.answer !== ""
            foreground: root.foreground
            accent: root.accent
            onClicked: Quickshell.execDetached(["wl-copy", "--", root.answer])
          }

          Button {
            text: strings.t("answer.openChat")
            visible: root.chatUrl !== ""
            bordered: true
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              Quickshell.execDetached(["omarchy-launch-browser", root.chatUrl])
              root.dismiss()
            }
          }
        }
      }

      Item {
        id: closeButton
        readonly property int pad: Style.spacing.sm
        width: line.height + pad * 2
        height: width
        x: card.width - card.contentRightInset - width + pad
        y: card.contentTopInset - pad

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: closeMouse.containsMouse ? Style.hoverFill : "transparent"
        }

        Text {
          anchors.centerIn: parent
          text: "×"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: closeMouse.containsMouse ? 1 : 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.title
        }

        MouseArea {
          id: closeMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.dismiss()
        }
      }
    }
  }
}
