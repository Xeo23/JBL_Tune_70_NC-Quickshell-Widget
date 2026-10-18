# JBL Tune 770NC Quickshell Widget
<img width="1312" height="1199" alt="image" src="https://github.com/user-attachments/assets/1367a502-f7ec-4026-8208-a5234307859a" />

A dark monochrome Quickshell control panel for the JBL Tune 770NC using the supplied Python Airoha RACE RFCOMM protocol.
Built using https://gist.github.com/wielkiborsuk/f46f6792ce9bba167a0736a2cc5ad6ae as a base, added power off, optimizations and performance enhancements.

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

