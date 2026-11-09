// Self-contained bar widget: the popup lives right here, anchored to the
// icon button via PopupCard, exactly like the original widget (this is what
// made the old widget position/size itself correctly — PopupCard anchors to
// anchorItem automatically, no manual screen-edge math needed).
//
// Data layer reads ~/.local/state/omarchy/notifications/{live,history,quiet}.json
// and acts via `omarchy-shell notifications` IPC (Omarchy 4.5 no longer gives
// bar-widgets the first-party notifications service).
//
// UI: no more Pending/Recently tabs — a search field, a
// "Recent and live notifications" label with a Clear all button, then a
// single merged, newest-first list below (live + history combined).
import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "NotificationLogic.js" as NotificationLogic

BarWidget {
  id: root
  moduleName: "shavanced.notification-center"

  property bool popupOpen: false
  function close() { popupOpen = false }

  property string query: ""
  property var filteredRows: []
  property var historyRows: []

  // Locally-dismissed history entries, hidden until they drop out of the
  // on-disk history on their own (see dismiss()).
  property var hiddenHistoryKeys: ({})
  function historyKey(row) {
    if (row.id !== undefined && row.id !== null && row.id !== 0) return "id:" + row.id
    return "k:" + row.app + "|" + row.summary + "|" + row.timestamp
  }

  // Omarchy 4.5 no longer hands omarchy.notifications to bar-widget plugins,
  // so read the service's state files and drive it over `omarchy-shell` IPC.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/notifications"
  property var liveEntries: []
  property var historyEntries: []
  readonly property int liveCount: liveEntries.length
  readonly property int historyLimit: 10

  readonly property bool dndSupported: true
  property bool dndOn: false
  function ipc(args) {
    Quickshell.execDetached(["omarchy-shell", "notifications"].concat(args))
  }
  function toggleDnd() { ipc(["toggleDnd"]) }

  function parseArray(raw) {
    try {
      var value = JSON.parse(String(raw || "[]"))
      return Array.isArray(value) ? value : []
    } catch (e) {
      return [] // torn write; next fileChanged reloads
    }
  }

  FileView {
    path: root.stateDir + "/live.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.liveEntries = root.parseArray(text()); root.rebuildRows() }
    onLoadFailed: root.liveEntries = []
  }
  FileView {
    path: root.stateDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.historyEntries = root.parseArray(text()); root.rebuildRows() }
  }
  FileView {
    path: root.stateDir + "/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.dndOn = JSON.parse(text()).dnd === true } catch (e) {}
    }
  }

  readonly property string icon: {
    if (root.dndOn) return "󰂛"
    if (root.liveCount > 0) return "󱅫"
    return "󰂚"
  }

  // Theme palette (mirrors the old widget's tokens).
  readonly property color colForeground: Commons.Color.foreground
  readonly property color colDim: Qt.darker(Commons.Color.foreground, 1.4)
  readonly property color colBorder: Style.normalBorderFor(Commons.Color.foreground, Commons.Color.accent)
  readonly property color colSurface: Style.normalFillFor(Commons.Color.foreground, Commons.Color.accent)
  readonly property color colAccent: Commons.Color.accent
  readonly property int cardRadius: Style.cornerRadius

  function notificationIconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    return Quickshell.iconPath(value, true)
  }

  function formatTimestamp(ms) {
    var date = new Date(Number(ms) || Date.now())
    var now = new Date()
    var sameDay = date.getFullYear() === now.getFullYear()
      && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()
    var time = date.toLocaleTimeString(Qt.locale(), "hh:mm")
    return sameDay ? time : date.toLocaleDateString(Qt.locale(), "MMM d") + " · " + time
  }

  function rowMatches(row) {
    var needle = root.query.trim().toLowerCase()
    if (needle === "") return true
    var haystack = [row.app, row.summary, row.body].join(" ").toLowerCase()
    return haystack.indexOf(needle) >= 0
  }

  function rowFrom(entry, isLive) {
    return {
      isLive: isLive,
      id: entry.originalId !== undefined ? entry.originalId : null,
      key: String(entry.key || ""),
      app: String(entry.app || "Unknown application"),
      appIcon: String(entry.appIcon || ""),
      summary: String(entry.summary || "Notification"),
      body: String(entry.body || ""),
      glyph: String(entry.glyph || ""),
      urgency: Number(entry.urgency === undefined ? 1 : entry.urgency),
      timestamp: Number(entry.ts || 0) * 1000
    }
  }

  function rebuildRows() {
    var rows = []
    var history = root.historyEntries.slice()
      .sort(function(a, b) { return (b.ts || 0) - (a.ts || 0) })
      .slice(0, root.historyLimit)
    for (var h = 0; h < history.length; ++h) {
      var past = rowFrom(history[h], false)
      if (root.hiddenHistoryKeys[root.historyKey(past)] || !rowMatches(past)) continue
      rows.push(past)
    }
    for (var i = 0; i < root.liveEntries.length; ++i) {
      var live = rowFrom(root.liveEntries[i], true)
      if (rowMatches(live)) rows.push(live)
    }
    rows.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    root.filteredRows = rows
  }

  function dismiss(row) {
    if (!row) return
    if (row.isLive) {
      // shortcut: IPC only dismisses by summary substring, so same-summary cards close together
      ipc(["dismiss", row.summary])
    } else {
      // No IPC removes one history entry; hide it locally until it ages out.
      var next = Object.assign({}, root.hiddenHistoryKeys)
      next[root.historyKey(row)] = true
      root.hiddenHistoryKeys = next
    }
    rebuildRows()
  }

  function clearSearch() {
    root.query = ""
    searchField.text = ""
  }

  function clearAll() {
    ipc(["dismissAll"])
    var next = Object.assign({}, root.hiddenHistoryKeys)
    for (var i = 0; i < root.historyEntries.length; ++i)
      next[root.historyKey(rowFrom(root.historyEntries[i], false))] = true
    root.hiddenHistoryKeys = next
    rebuildRows()
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      clearSearch()
      rebuildRows()
    }
  }
  onQueryChanged: rebuildRows()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.liveCount > 0 && !root.dndOn
    tooltipText: root.dndOn ? "DND on — right-click to turn off"
      : (root.liveCount > 0 ? root.liveCount + " live notifications" : "Notification Center")

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.toggleDnd()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: searchField
    contentWidth: popup.fittedContentWidth(Style.space(440))
    contentHeight: popup.cappedContentHeight(Style.space(540))

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(10)

      // ----------------------------------------- header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "Notifications"
          font.family: root.bar ? root.bar.fontFamily : ""
          color: root.colForeground
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          text: root.liveCount === 1 ? "1 notification" : root.liveCount + " notifications"
          font.family: root.bar ? root.bar.fontFamily : ""
          color: root.colDim
          font.pixelSize: Style.font.caption
        }

        Item { Layout.fillWidth: true }

        BorderSurface {
          id: dndPill
          visible: root.dndSupported
          Layout.preferredHeight: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
          Layout.preferredWidth: dndLabel.implicitWidth + dndGlyph.implicitWidth + Style.space(18)
          radius: Math.min(Style.space(12), root.cardRadius + Style.space(6))
          color: root.dndOn ? root.colAccent : root.colSurface
          borderSpec: Border.flat(root.dndOn ? root.colAccent : root.colBorder, Style.normalBorderWidth)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              id: dndGlyph
              text: root.dndOn ? "󰂛" : "󰂚"
              font.family: root.bar ? root.bar.fontFamily : ""
              color: root.dndOn ? Commons.Color.background : root.colDim
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: dndLabel
              text: root.dndOn ? "DND on" : "DND off"
              font.family: root.bar ? root.bar.fontFamily : ""
              color: root.dndOn ? Commons.Color.background : root.colDim
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleDnd()
          }
        }

        BorderSurface {
          Layout.preferredWidth: Style.space(22)
          Layout.preferredHeight: Style.space(22)
          radius: Math.min(Style.space(6), root.cardRadius)
          color: closeHeaderArea.containsMouse ? root.colBorder : "transparent"
          borderSpec: Border.flat(root.colBorder, Style.normalBorderWidth)

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colForeground
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: closeHeaderArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.close()
          }
        }
      }

      // ----------------------------------------- search
      TextField {
        id: searchField
        Layout.fillWidth: true
        placeholderText: "Search notifications"
        activeFocusOnPress: true
        onTextEdited: root.query = text
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.query.length > 0) {
              root.clearSearch()
            } else {
              root.close()
            }
            event.accepted = true
          }
        }
      }

      // ----------------------------------------- label + clear all
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          Layout.fillWidth: true
          text: root.query.trim() === "" ? "Recent and live notifications" : root.filteredRows.length + " matching notifications"
          font.family: root.bar ? root.bar.fontFamily : ""
          color: root.colDim
          font.pixelSize: Style.font.caption
        }

        BorderSurface {
          Layout.preferredWidth: clearLabel.implicitWidth + Style.space(16)
          Layout.preferredHeight: Math.max(Style.space(22), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
          radius: Math.min(Style.space(6), root.cardRadius)
          color: clearArea.containsMouse ? root.colBorder : "transparent"
          borderSpec: Border.flat(root.colBorder, Style.normalBorderWidth)

          Text {
            id: clearLabel
            anchors.centerIn: parent
            text: "Clear all"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colForeground
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: clearArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clearAll()
          }
        }
      }

      // ----------------------------------------- list
      ListView {
        id: listView
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(8)
        model: root.filteredRows
        visible: count > 0

        delegate: BorderSurface {
          id: rowCard
          required property var modelData

          readonly property string smallIconSource: root.notificationIconSource(modelData.appIcon)
          readonly property bool hasIcon: modelData.glyph === "" && smallIconSource.length > 0
          readonly property string sanitizedBody: NotificationLogic.sanitizeBody(modelData.body, modelData.app, modelData.appIcon)

          width: listView.width
          implicitHeight: rowContent.implicitHeight + Style.spacing.panelGap
          radius: root.cardRadius
          color: "transparent"
          borderSpec: Border.flat(root.colBorder, Style.normalBorderWidth)

          // Left click dismisses. Hover reveals a dedicated close (x)
          // button as an alternate, more discoverable way to dismiss.
          MouseArea {
            id: rowHoverArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.dismiss(rowCard.modelData)
          }

          RowLayout {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: rowCard.borderLeft + Style.space(12)
            anchors.rightMargin: rowCard.borderRight + Style.space(12)
            spacing: Style.space(10)

            Text {
              Layout.alignment: Qt.AlignTop
              visible: rowCard.modelData.glyph !== ""
              text: rowCard.modelData.glyph
              color: rowCard.modelData.urgency === 2 ? Commons.Color.urgent : Commons.Color.accent
              font.family: root.bar ? root.bar.fontFamily : ""
              font.pixelSize: Style.font.icon
            }

            Item {
              Layout.preferredWidth: Style.space(32)
              Layout.preferredHeight: Style.space(32)
              Layout.alignment: Qt.AlignVCenter
              visible: rowCard.hasIcon && rowIconImage.status !== Image.Error

              Image {
                id: rowIconImage
                anchors.fill: parent
                source: rowCard.smallIconSource
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                asynchronous: true
                smooth: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  text: rowCard.modelData.app
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.colDim
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  text: root.formatTimestamp(rowCard.modelData.timestamp)
                  font.family: root.bar ? root.bar.fontFamily : ""
                  color: root.colDim
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                Layout.fillWidth: true
                visible: rowCard.modelData.summary.length > 0
                text: rowCard.modelData.summary
                font.family: root.bar ? root.bar.fontFamily : ""
                color: root.colForeground
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
              }

              Text {
                Layout.fillWidth: true
                visible: rowCard.sanitizedBody.length > 0
                text: rowCard.sanitizedBody
                textFormat: Text.PlainText
                font.family: root.bar ? root.bar.fontFamily : ""
                color: root.colDim
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 3
              }
            }

            // Close (x): visible ONLY while hovering this row.
            Rectangle {
              Layout.preferredWidth: Style.space(20)
              Layout.preferredHeight: Style.space(20)
              Layout.alignment: Qt.AlignVCenter
              visible: rowHoverArea.containsMouse
              radius: Math.min(4, root.cardRadius)
              color: closeArea.containsMouse ? root.colBorder : "transparent"

              Text {
                anchors.centerIn: parent
                text: "✕"
                font.family: root.bar ? root.bar.fontFamily : ""
                color: root.colDim
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  mouse.accepted = true
                  root.dismiss(rowCard.modelData)
                }
              }
            }
          }
        }
      }

      // ----------------------------------------- empty state
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: listView.count === 0

        ColumnLayout {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "󰂚"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colBorder
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.query.trim() === "" ? "No notifications" : "No matching notifications"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colDim
            font.pixelSize: Style.font.body
          }
        }
      }

      // ----------------------------------------- footer legend
      Text {
        Layout.fillWidth: true
        text: "Left-click or hover the ✕ to dismiss · Esc closes"
        font.family: root.bar ? root.bar.fontFamily : ""
        color: Qt.darker(root.colForeground, 1.55)
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }
}
