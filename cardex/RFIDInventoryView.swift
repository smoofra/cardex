import SwiftUI
import Combine

struct RFIDInventoryView: View {
    let onConfirm: (String) -> Void
    @StateObject private var service = RFIDReaderService()
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
                            service.clearTags()
                            service.scanOnce()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!service.isConnected)
                    }

                    if service.tags.count == 1 {
                        Button("OK") {
                            onConfirm(service.tags[0].epc)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                List(service.tags, id: \.epc) { tag in
                    HStack {
                        Text(tag.epc)
                            .font(.body)
                        Spacer()
                        if let rssi = tag.rssi {
                            Text("RSSI: \(rssi)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
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
    RFIDInventoryView(onConfirm: { _ in })
}
