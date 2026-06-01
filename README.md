# XIAO Companion

Minimal unsigned iOS companion app for Seeed Studio XIAO nRF52840 BLE testing.

The app:

- scans for BLE peripherals;
- connects to a selected device;
- subscribes to every notify/indicate characteristic it finds;
- logs incoming BLE packets as text or hex;
- can POST received packets to your API endpoint.

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
