# JBL Tune 770NC Quickshell Widget

A dark monochrome Quickshell control panel for the JBL Tune 770NC using the supplied Python Airoha RACE RFCOMM protocol.

## Requirements
- Linux with Bluetooth enabled and the JBL Tune 770NC paired
- Quickshell and QtQuick modules
- Python 3
- Permission to connect to Bluetooth RFCOMM channel 21

## Run
Extract the ZIP, enter the project directory, and run:

```bash
chmod +x anc.py
quickshell -p ./Main.qml
```

The script uses the Bluetooth address `BD = "{your_headset_bluetooth_address}"` and RFCOMM channel 21. Change `BD` in `anc.py` if your headset address differs.

