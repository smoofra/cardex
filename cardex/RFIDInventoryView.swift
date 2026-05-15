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
                    if service.isConnected {
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
                    }
                }
                VStack(alignment: .leading) {
                    Text("Power: \(Int(service.power))")
                    let powerBinding = Binding<Double>(
                        get: { Double(service.power) },
                        set: { service.power = Int($0.rounded()) }
                    )
                    Slider(value: powerBinding, in: Double(service.minPower)...Double(service.maxPower), step: 1)
                        .disabled(!service.isConnected)
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
                        .disabled(!service.isConnected)
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
