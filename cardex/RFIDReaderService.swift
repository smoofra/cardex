import Foundation
import Combine
import TSLAsciiCommands
import ExternalAccessory
import CoreBluetooth

struct Connection {
    var minPower: Int
    var maxPower: Int
    var power: Int
}

final class RFIDReaderService: NSObject, ObservableObject, CBCentralManagerDelegate {

    struct RFIDTag: Hashable {
        let epc: String
        let rssi: Int?
        var count: Int = 1
    }

    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?

    private let requiredProtocolString: String = "com.uk.tsl.rfid"

    @Published var isScanning: Bool = false
    @Published var connection: Connection?
    @Published var tags: [RFIDTag] = []
    @Published var lastScanEPCs: Set<String> = []
    @Published var lastErrorMessage: String?

    private let scanQueue = DispatchQueue(label: "org.elder-gods.cardex.scan", qos: .default)
    private var scanTimeoutWorkItem: DispatchWorkItem? = nil
    private var isShowingAccessoryPicker = false
    private var pendingPickerRequest = false

    // MARK: - Configuration

    private func findAccessory(matching protocolString: String) -> EAAccessory? {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        print("EA connected accessories:")
        accessories.forEach { acc in
            print("- \(acc.name) by \(acc.manufacturer) protocols: \(acc.protocolStrings)")
        }
        return accessories.first { $0.protocolStrings.contains(protocolString) }
    }

    func connect() {
        print("Attempting to connect via EAAccessory...")
        DispatchQueue.main.async {
            self.connectToAvailableAccessory(showPickerIfUnavailable: true)
        }
    }

    private func connectToAvailableAccessory(showPickerIfUnavailable: Bool) {
        if let accessory = findAccessory(matching: requiredProtocolString) {
            print("Found accessory: \(accessory.name). Attempting commander connect...")
            commander.connect(accessory)
            print("connect result isConnected:", commander.isConnected)
            return
        }

        print("No matching accessory for protocol: \(requiredProtocolString).")

        guard showPickerIfUnavailable else { return }
        requestBluetoothThenShowPicker()
    }

    // Ensure Bluetooth permission is granted before showing the EA picker.
    // On iOS 26 the picker requires an authorized CBCentralManager or it fails
    // at the usermanagerd XPC layer before any UI appears.
    private func requestBluetoothThenShowPicker() {
        guard !isShowingAccessoryPicker else { return }

        if let cm = centralManager, cm.state == .poweredOn {
            showBluetoothAccessoryPicker()
            return
        }

        pendingPickerRequest = true
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard pendingPickerRequest else { return }
        pendingPickerRequest = false

        switch central.state {
        case .poweredOn:
            // Delay to let the scene return to foreground-active after the permission dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showBluetoothAccessoryPicker()
            }
        case .unauthorized:
            print("Bluetooth permission denied — user must enable in Settings > Privacy > Bluetooth")
        default:
            print("Bluetooth unavailable: \(central.state.rawValue)")
        }
    }

    private func showBluetoothAccessoryPicker() {
        guard !isShowingAccessoryPicker else { return }
        isShowingAccessoryPicker = true

        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isShowingAccessoryPicker = false

                if let error = error {
                    let nsError = error as NSError
                    print("Bluetooth accessory picker error: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
                }

                self.connectToAvailableAccessory(showPickerIfUnavailable: false)
            }
        }
    }

    init(overrideInit: Bool = false) {
        commander = TSLAsciiCommander()

        super.init()

        let logger = TSLLoggerResponder.default()
        logger.lineReceivedBlock = { line in
            print("TSL:", line)
        }
        commander.add(logger)
        commander.addSynchronousResponder()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCommanderStateChanged(_:)),
                                               name:  NSNotification.Name.TSLCommanderStateChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCommanderStateChanged(_:)),
                                               name: .EAAccessoryDidConnect,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleCommanderStateChanged(_:)),
                                               name: .EAAccessoryDidDisconnect,
                                               object: nil)
        EAAccessoryManager.shared().registerForLocalNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        commander.halt()
    }

    @objc private func handleCommanderStateChanged(_ note: Notification) {
        if commander.isConnected {
            queryPowerRange()
        } else {
            disconnect()
        }
    }

    private func queryPowerRange() {
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            // Reset to defaults then read back — post-reset outputPower is the reader's maximum
            let cmd = TSLInventoryCommand.synchronousCommand()
            cmd.resetParameters = TSL_TriState_YES
            cmd.readParameters = TSL_TriState_YES
            cmd.takeNoAction = TSL_TriState_YES
            self.commander.execute(cmd)
            guard cmd.isSuccessful else {
                print("power range query failed")
                disconnect()
                return
            }
            let lo = Int(TSLInventoryCommand.minimumOutputPower())
            let hi = Int(cmd.outputPower)
            if lo < 0 || hi < 0 || lo > hi {
                print("power range query returned nonsensical values")
                disconnect()
                return
            }
            DispatchQueue.main.async {
                let power = min(max(self.connection?.power ?? 16, lo), hi)
                self.connection = Connection(minPower: lo, maxPower: hi, power: power)
            }
        }
    }

    func disconnect() {
        commander.disconnect()
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        DispatchQueue.main.async { [weak self] in
            self?.connection = nil
            self?.isScanning = false
        }
    }

    func clearTags() {
        DispatchQueue.main.async {
            self.tags.removeAll()
            self.lastScanEPCs = []
        }
    }

    func scanOnce() {
        guard let connection else { return }

        isScanning = true
        lastErrorMessage = nil

        scanTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            print("Scan timeout reached. Aborting command and resetting state.")
            self.commander.abortSynchronousCommand()
            DispatchQueue.main.async {
                self.isScanning = false
            }
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)

        let inv = TSLInventoryCommand.synchronousCommand()
        inv.includeEPC = TSL_TriState_YES
        inv.includeTransponderRSSI = TSL_TriState_YES
        inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
        inv.outputPower = Int32(connection.power)

        var currentScanEPCs = Set<String>()

        inv.transponderDataReceivedBlock = { [weak self] transponder, moreAvailable in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let epc = transponder.epc {
                    let rssi = transponder.rssi?.intValue
                    currentScanEPCs.insert(epc)
                    if let index = self.tags.firstIndex(where: { $0.epc == epc }) {
                        self.tags[index] = RFIDTag(epc: epc, rssi: rssi, count: self.tags[index].count + 1)
                    } else {
                        self.tags.append(RFIDTag(epc: epc, rssi: rssi))
                    }
                }

                if !moreAvailable {
                    self.scanTimeoutWorkItem?.cancel()
                    self.scanTimeoutWorkItem = nil
                    self.isScanning = false
                    self.lastScanEPCs = currentScanEPCs
                }
            }
        }
        scanQueue.async { [weak self] in
            guard let self = self else { return }
            self.commander.execute(inv)

            DispatchQueue.main.async {
                self.scanTimeoutWorkItem?.cancel()
                self.scanTimeoutWorkItem = nil
                self.isScanning = false
                if !inv.isSuccessful {
                    print("failed!")
                    self.lastErrorMessage = inv.errorCode.map { "Reader error ER:\($0)" } ?? "Reader error"
                } else {
                    print("done.")
                }
            }
        }
    }

    func stopScan() {
        commander.abortSynchronousCommand()
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        DispatchQueue.main.async {
            self.isScanning = false
        }
    }
}
