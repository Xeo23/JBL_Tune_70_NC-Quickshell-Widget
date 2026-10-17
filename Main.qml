import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

PanelWindow {
    id: root
    implicitWidth: 500
    implicitHeight: 540
    color: "transparent"
    anchors { top: true; right: true }
    margins { top: 48; right: 16 }
    exclusionMode: ExclusionMode.Ignore

    property string scriptPath: Qt.resolvedUrl("./anc.py").toString().replace("file://", "")
    property string statusLine: "Checking headset…"
    property string selectedMode: ""
    property string currentMode: "UNKNOWN"
    property bool busy: false
    property bool deviceConnected: false
    // Start false so Component.onCompleted can launch the initial check.
    property bool checkingConnection: false
    property int batteryPercent: -1
    property bool checkingBattery: false
    property string pendingCommand: "get"

    function modeForCommand(cmd) {
        if (cmd === "anc" || cmd === "on") return "ANC"
        if (cmd === "ambient" || cmd === "aware") return "AMBIENTAWARE"
        if (cmd === "talkthru") return "TALKTHRU"
        if (cmd === "off") return "OFF"
        return "UNKNOWN"
    }

    function queryBattery() {
        if (checkingBattery) return
        checkingBattery = true
        batteryCheck.running = true
    }

    function checkConnection(command) {
        // Keep refresh available, but don't start overlapping checks.
        if (checkingConnection || busy) return
        pendingCommand = command || "get"
        checkingConnection = true
        connectionCheck.running = true
    }

    function runCommand(cmd) {
        if (busy) return
        busy = true
        selectedMode = cmd
        statusLine = cmd === "get" ? "Checking current mode…" : (cmd === "poweroff" ? "Sending power-off…" : "Applying " + cmd + "…")
        backend.command = ["python3", scriptPath, cmd]
        backend.running = true
    }

    Component.onCompleted: Qt.callLater(function() {
        root.checkConnection()
        root.queryBattery()
    })

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.queryBattery()
    }

    Process {
        id: batteryCheck
        command: ["python3", root.scriptPath, "battery"]
        stdout: StdioCollector {
            onStreamFinished: {
                const value = Number(text.trim())
                root.batteryPercent = text.trim().length > 0 && Number.isFinite(value) && value >= 0 && value <= 100 ? value : -1
                root.checkingBattery = false
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0) root.batteryPercent = -1
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.checkingBattery = false
            if (exitCode !== 0 && root.batteryPercent < 0) root.batteryPercent = -1
        }
    }

    Process {
        id: connectionCheck
        command: ["python3", root.scriptPath, "is_connected"]
        stdout: StdioCollector {
            onStreamFinished: {
                const result = text.trim().toUpperCase()
                root.deviceConnected = result.includes("CONNECTED") && !result.includes("DISCONNECTED")
                root.checkingConnection = false
                if (root.deviceConnected) {
                    // Every mode request is gated by a fresh Bluetooth check.
                    root.runCommand(root.pendingCommand || "get")
                } else {
                    root.currentMode = "UNKNOWN"
                    root.statusLine = "Headphones disconnected"
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0 && !root.deviceConnected) {
                    root.statusLine = "Headphones disconnected"
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && root.checkingConnection) {
                root.deviceConnected = false
                root.checkingConnection = false
                root.currentMode = "UNKNOWN"
                root.statusLine = "Headphones disconnected"
            }
        }
    }

    Process {
        id: backend
        command: ["python3", root.scriptPath, "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                const output = text.trim()
                const lines = output.split("\n")
                // For a mode change, trust only the protocol's response frame,
                // not any unsolicited/base frames received before the command.
                const candidates = root.selectedMode === "get"
                    ? lines
                    : lines.filter(line => line.includes(" response]") && line.includes("op=0x0901"))
                let matchedMode = ""
                for (let i = candidates.length - 1; i >= 0; --i) {
                    const match = candidates[i].match(/mode=([^\)\r\n]+)/)
                    if (match) {
                        matchedMode = match[1].trim().toUpperCase().replace(/[^A-Z]/g, "")
                        break
                    }
                }
                if (matchedMode) {
                    root.currentMode = matchedMode
                    const displayMode = matchedMode === "AMBIENTAWARE" ? "Ambient Aware"
                        : matchedMode === "TALKTHRU" ? "TalkThru" : matchedMode
                    root.statusLine = "Current mode: " + displayMode
                } else if (root.selectedMode === "get") {
                    root.statusLine = "Mode unavailable — check headset connection"
                } else if (root.selectedMode !== "poweroff") {
                    root.statusLine = "Command sent — mode response unavailable"
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const output = text.trim()
                if (output.length > 0) root.statusLine = output.split("\n").slice(-1)[0]
            }
        }
        onExited: (exitCode, exitStatus) => {
            const finishedCommand = root.selectedMode
            root.busy = false
            if (exitCode !== 0) {
                if (finishedCommand === "get") root.statusLine = "Couldn't read mode — check pairing / RFCOMM"
                else root.statusLine = "Command failed — check headset connection"
                return
            }
            if (finishedCommand === "poweroff") {
                root.statusLine = "Power-off command sent"
                root.currentMode = "UNKNOWN"
                root.deviceConnected = false
            } else if (finishedCommand !== "get") {
                // The setter command's response is parsed by stdout above.
                // Do not open a second RFCOMM connection with another `get`.
                if (root.statusLine === "Applying " + finishedCommand + "…")
                    root.statusLine = "Command sent"
            }
        }
    }

    component LineIcon: Canvas {
        property string kind: "anc"
        property color iconColor: "#f0f0f0"
        onPaint: {
            const c = getContext("2d")
            c.reset()
            c.clearRect(0, 0, width, height)
            c.save()
            c.scale(width / 48, height / 48)
            c.strokeStyle = iconColor
            c.fillStyle = iconColor
            c.lineWidth = 2.6
            c.lineCap = "round"
            c.lineJoin = "round"
            if (kind === "battery") {
                c.beginPath(); c.rect(4, 13, 36, 22); c.stroke()
                c.beginPath(); c.rect(40, 19, 4, 10); c.stroke()
            } else if (kind === "anc") {
                c.beginPath(); c.arc(24, 24, 19, 0, Math.PI * 2); c.stroke()
                c.lineWidth = 3.2
                c.beginPath(); c.moveTo(14, 21); c.lineTo(14, 27); c.moveTo(20, 15); c.lineTo(20, 33); c.moveTo(27, 12); c.lineTo(27, 36); c.moveTo(34, 19); c.lineTo(34, 29); c.stroke()
            } else if (kind === "ambient") {
                c.beginPath(); c.arc(20, 14, 8, Math.PI, Math.PI * 2); c.arc(20, 14, 8, 0, Math.PI); c.stroke()
                c.beginPath(); c.moveTo(6, 39); c.bezierCurveTo(7, 29, 13, 26, 20, 26); c.bezierCurveTo(28, 26, 34, 31, 35, 39); c.closePath(); c.stroke()
                c.beginPath(); c.arc(35, 18, 6, -0.9, 0.9); c.stroke()
                c.beginPath(); c.arc(35, 18, 11, -0.8, 0.8); c.stroke()
            } else if (kind === "talk") {
                c.beginPath(); c.moveTo(8, 9); c.quadraticCurveTo(8, 5, 13, 5); c.lineTo(35, 5); c.quadraticCurveTo(40, 5, 40, 10); c.lineTo(40, 29); c.quadraticCurveTo(40, 34, 35, 34); c.lineTo(22, 34); c.lineTo(12, 42); c.lineTo(12, 34); c.quadraticCurveTo(8, 33, 8, 29); c.closePath(); c.stroke()
                c.beginPath(); c.arc(25, 20, 5, -0.9, 0.9); c.stroke()
                c.beginPath(); c.arc(25, 20, 10, -0.8, 0.8); c.stroke()
            } else if (kind === "off") {
                c.beginPath(); c.arc(24, 24, 19, 0, Math.PI * 2); c.stroke()
                c.beginPath(); c.moveTo(11, 37); c.lineTo(37, 11); c.stroke()
            } else if (kind === "power") {
                c.beginPath(); c.arc(24, 25, 15, Math.PI * 0.22, Math.PI * 0.78, true); c.stroke()
                c.beginPath(); c.moveTo(24, 5); c.lineTo(24, 25); c.stroke()
            } else if (kind === "refresh") {
                c.beginPath(); c.arc(24, 24, 15, -2.5, -0.3); c.stroke()
                c.beginPath(); c.moveTo(9, 12); c.lineTo(9, 20); c.lineTo(17, 20); c.stroke()
                c.beginPath(); c.arc(24, 24, 15, 0.65, 2.85); c.stroke()
                c.beginPath(); c.moveTo(39, 36); c.lineTo(39, 28); c.lineTo(31, 28); c.stroke()
            } else if (kind === "close") {
                c.beginPath(); c.moveTo(14, 14); c.lineTo(34, 34); c.moveTo(34, 14); c.lineTo(14, 34); c.stroke()
            }
            c.restore()
        }
        onKindChanged: requestPaint()
        onIconColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    component CircleButton: Button {
        property color idleFill: "#151515"
        property color idleBorder: "#303030"
        property string iconKind: "refresh"
        property color iconColor: "#e6e6e6"
        implicitWidth: 54
        implicitHeight: 54
        padding: 0
        background: Rectangle {
            radius: 12
            color: parent.down ? "#292929" : parent.idleFill
            border.color: parent.idleBorder
            border.width: 1.2
        }
        contentItem: LineIcon {
            anchors.centerIn: parent
            width: 30
            height: 30
            kind: parent.iconKind
            iconColor: parent.iconColor
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 24
        color: "#0c0d0e"
        border.color: "#292c30"
        border.width: 1.5

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 40
                spacing: 16
                Label {
                    text: "JBL"
                    color: "#ff6a00"
                    font.pixelSize: 31
                    font.bold: true
                    font.letterSpacing: -1.5
                }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 34; color: "#45484b" }
                Label {
                    text: "TUNE 770NC"
                    color: "#ededed"
                    font.pixelSize: 23
                    font.letterSpacing: 2.2
                    font.bold: true
                    Layout.fillWidth: true
                }
                Button {
                    implicitWidth: 32; implicitHeight: 32; padding: 0
                    background: Item {}
                    contentItem: LineIcon { width: 27; height: 27; kind: "close"; iconColor: "#bfc2c5" }
                    onClicked: Qt.quit()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                spacing: 14
                LineIcon { Layout.preferredWidth: 30; Layout.preferredHeight: 30; kind: "battery"; iconColor: "#ff6a00" }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 12
                    radius: 6
                    color: "#292d31"
                    clip: true
                    Rectangle {
                        width: parent.width * (root.batteryPercent < 0 ? 0 : root.batteryPercent / 100)
                        height: parent.height
                        radius: 6
                        color: "#ff6a00"
                    }
                }
                Label {
                    Layout.preferredWidth: 52
                    horizontalAlignment: Text.AlignRight
                    text: root.batteryPercent < 0 ? "—%" : root.batteryPercent + "%"
                    color: root.batteryPercent < 0 ? "#8a8d90" : "#ff6a00"
                    font.pixelSize: 20
                    font.bold: true
                }
            }

            Label {
                text: "NOISE CONTROL"
                color: "#ff6a00"
                font.pixelSize: 17
                font.letterSpacing: 1.8
                font.bold: true
                Layout.topMargin: 1
            }

            GridLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                columns: 2
                rowSpacing: 10
                columnSpacing: 12
                Repeater {
                    model: [
                        { label: "ANC", cmd: "anc", icon: "anc", mode: "ANC" },
                        { label: "Ambient Aware", cmd: "ambient", icon: "ambient", mode: "AMBIENTAWARE" },
                        { label: "TalkThru", cmd: "talkthru", icon: "talk", mode: "TALKTHRU" },
                        { label: "Off", cmd: "off", icon: "off", mode: "OFF" }
                    ]
                    delegate: Button {
                        id: modeButton
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 94
                        padding: 8
                        background: Rectangle {
                            radius: 18
                            color: root.currentMode === modelData.mode ? "#21140d" : (modeButton.down ? "#222426" : "#111315")
                            border.color: root.currentMode === modelData.mode ? "#ff6a00" : "#303438"
                            border.width: root.currentMode === modelData.mode ? 2 : 1.3
                        }
                        contentItem: Column {
                            spacing: 7
                            LineIcon {
                                width: 48; height: 48
                                anchors.horizontalCenter: parent.horizontalCenter
                                kind: modelData.icon
                                iconColor: root.currentMode === modelData.mode ? "#ff6a00" : "#e3e5e7"
                            }
                            Text {
                                width: modeButton.width - 20
                                text: modelData.label
                                color: "#e5e6e8"
                                font.pixelSize: 17
                                font.bold: false
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.WordWrap
                            }
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: root.currentMode === modelData.mode ? "#ff6a00" : "#5b6065"
                            }
                        }
                        onClicked: root.checkConnection(modelData.cmd)
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                Layout.preferredHeight: 16
                text: root.statusLine
                color: root.statusLine.toLowerCase().includes("fail") || root.statusLine.toLowerCase().includes("couldn't") || root.statusLine.toLowerCase().includes("unavailable") ? "#ff9a9a" : "#777b80"
                font.pixelSize: 10
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#24272a" }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                spacing: 16
                CircleButton {
                    // Preserve the connection-state color cue: green when connected,
                    // red when disconnected.
                    idleFill: root.deviceConnected ? "#102017" : "#1b1212"
                    idleBorder: root.deviceConnected ? "#245b39" : "#442020"
                    iconKind: "power"
                    iconColor: root.deviceConnected ? "#45d483" : "#ff443f"
                    onClicked: root.checkConnection("poweroff")
                }
                Label {
                    text: "Power Off"
                    color: "#e8e8e8"
                    font.pixelSize: 17
                    font.bold: true
                    Layout.fillWidth: true
                }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 42; color: "#3c3f42" }
                CircleButton {
                    iconKind: "refresh"
                    iconColor: "#c9cccf"
                    onClicked: { root.checkConnection(); root.queryBattery() }
                }
                Label {
                    text: "Refresh"
                    color: "#e8e8e8"
                    font.pixelSize: 17
                    font.bold: true
                    Layout.fillWidth: true
                }
            }
        }
    }
}
