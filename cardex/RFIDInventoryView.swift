import SwiftUI
import Combine

struct RFIDInventoryView: View {
    let onConfirm: (String) -> Void
    @ObservedObject var service: RFIDReaderService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack {
                    if service.connection != nil {
                        Button("Disconnect") {
                            service.disconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("Connect") {
                            service.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.isConnecting)
                    }
                }
                if let connection = service.connection {
                    VStack(alignment: .leading) {
                        Text("Power: \(connection.power)")
                        let powerBinding = Binding<Double>(
                            get: { Double(service.connection?.power ?? connection.minPower) },
                            set: {
                                service.connection?.power = Int($0.rounded())
                            }
                        )
                        Slider(value: powerBinding, in: Double(connection.minPower)...Double(connection.maxPower), step: 1)
                    }
                }
                HStack {
                    if service.isScanning {
                        Button("Stop") {
                            service.stopScan()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("Scan Once") {
                            service.scanOnce()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.connection == nil)
                    }

                    if service.lastScanEPCs.count == 1, let epc = service.lastScanEPCs.first {
                        Button("OK") {
                            onConfirm(epc)
                            service.clearTags()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                List(service.tags.sorted { $0.count > $1.count }, id: \.epc) { tag in
                    HStack {
                        Text(tag.epc)
                            .font(.body)
                        Spacer()
                        if let rssi = tag.rssi {
                            Text("RSSI: \(rssi)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        Text("×\(tag.count)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .monospacedDigit()
                        Button {
                            UIPasteboard.general.string = tag.epc
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .opacity(service.lastScanEPCs.isEmpty || service.lastScanEPCs.contains(tag.epc) ? 1.0 : 0.35)
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("RFID Inventory")
        }
        .onDisappear {
            service.stopScan()
            //service.disconnect()
        }
    }
}

#Preview {
    RFIDInventoryView(onConfirm: { _ in }, service: RFIDReaderService())
}
