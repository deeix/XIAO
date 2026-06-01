import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @AppStorage("apiEndpoint") private var apiEndpoint = ""
    @AppStorage("autoUpload") private var autoUpload = false
    @AppStorage("autoReconnect") private var autoReconnect = true

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    HStack {
                        Text("Bluetooth")
                        Spacer()
                        Text(ble.bluetoothState)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Device")
                        Spacer()
                        Text(ble.connectedName ?? "Not connected")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Connection") {
                    Toggle("Auto reconnect", isOn: $autoReconnect)
                        .onChange(of: autoReconnect) { value in
                            ble.autoReconnect = value
                            if value {
                                ble.reconnectToSavedDevice()
                            }
                        }

                    Button("Reconnect saved XIAO") {
                        ble.reconnectToSavedDevice()
                    }

                    Button(ble.isScanning ? "Stop Scan" : "Scan for XIAO") {
                        ble.isScanning ? ble.stopScanning() : ble.startScanning()
                    }

                    ForEach(ble.devices) { device in
                        Button {
                            ble.connect(to: device)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.headline)
                                Text(device.id.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Database Upload") {
                    TextField("https://example.com/api/notifications", text: $apiEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Auto upload received packets", isOn: $autoUpload)
                        .onChange(of: autoUpload) { value in
                            ble.apiEndpoint = apiEndpoint
                            ble.autoUpload = value
                        }

                    Button("Send test event") {
                        ble.apiEndpoint = apiEndpoint
                        ble.sendTestEvent()
                    }
                    .disabled(apiEndpoint.isEmpty)
                }

                Section("Incoming BLE Data") {
                    Button("Clear Log", role: .destructive) {
                        ble.clearLog()
                    }

                    ForEach(ble.events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title)
                                .font(.headline)
                            Text(event.body)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("XIAO Companion")
            .onAppear {
                ble.apiEndpoint = apiEndpoint
                ble.autoUpload = autoUpload
                ble.autoReconnect = autoReconnect
            }
            .onChange(of: apiEndpoint) { value in
                ble.apiEndpoint = value
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(BLEManager())
    }
}
