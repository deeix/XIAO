# XIAO Companion

Minimal unsigned iOS companion app for Seeed Studio XIAO nRF52840 BLE testing.

The app:

- scans for BLE peripherals;
- connects to a selected device;
- subscribes to every notify/indicate characteristic it finds;
- logs incoming BLE packets as text or hex;
- can POST received packets to your API endpoint.
- remembers the selected BLE peripheral and tries to reconnect later;
- shows a local iOS notification when XIAO sends a BLE packet.

## Build IPA with GitHub Actions

1. Create a GitHub repository.
2. Push this folder to the repository.
3. Open `Actions`.
4. Run `Build iOS IPA`.
5. Download the `XIAOCompanion-unsigned-ipa` artifact.
6. Install `XIAOCompanion.ipa` with SideStore.

The app is intentionally built without signing:

```sh
CODE_SIGNING_ALLOWED=NO
```

SideStore signs it on the phone.

## First Test

1. Open the app.
2. Allow Bluetooth.
3. Tap `Scan for XIAO`.
4. Connect to your BLE device.
5. Send data from XIAO through a notify characteristic.

For database upload, enter an HTTPS endpoint and enable auto upload.

## Background behavior

The app includes `bluetooth-central` background mode. iOS can wake it for BLE events, restored connections, and reconnects, but it does not allow unlimited background execution.

Important: the app cannot directly see the private system ANCS connection state. If XIAO is connected to iOS for ANCS, your firmware should also expose a custom BLE service/characteristic and send a packet like:

```json
{"type":"status","ancs_connected":true}
```

The app will display any packet it receives and show a local notification.
