import Foundation
import Combine
import TSLAsciiCommands
import ExternalAccessory
import CoreBluetooth

final class RFIDReaderService: NSObject, ObservableObject, CBCentralManagerDelegate {

    struct RFIDTag: Hashable {
        let epc: String
        let rssi: Int?
    }

    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?

    private let requiredProtocolString: String = "com.uk.tsl.rfid"

    @Published var isConnected: Bool = false
    @Published var isScanning: Bool = false
    @Published var power: Int = 16
    @Published var minPower: Int = 4
    @Published var maxPower: Int = 29
    @Published var tags: [RFIDTag] = []
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
            isConnected = commander.isConnected
            print("connect result isConnected:", isConnected)
            return
        }

        isConnected = commander.isConnected
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
                                               selector: #selector(handleAccessoryDidConnect(_:)),
                                               name: .EAAccessoryDidConnect,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAccessoryDidDisconnect(_:)),
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = self.commander.isConnected
        }
    }

    @objc private func handleAccessoryDidConnect(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.connectToAvailableAccessory(showPickerIfUnavailable: false)
        }
    }

    @objc private func handleAccessoryDidDisconnect(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = self.commander.isConnected
        }
    }

    func disconnect() {
        commander.disconnect()
        isConnected = commander.isConnected
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
        }
    }

    func clearTags() {
        DispatchQueue.main.async {
            self.tags.removeAll()
        }
    }

    func scanOnce() {
        guard isConnected else { return }

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
        inv.outputPower = Int32(power)

        inv.transponderDataReceivedBlock = { [weak self] transponder, moreAvailable in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let epc = transponder.epc {
                    let rssi = transponder.rssi?.intValue
                    let newTag = RFIDTag(epc: epc, rssi: rssi)
                    if let index = self.tags.firstIndex(where: { $0.epc == epc }) {
                        self.tags[index] = newTag
                    } else {
                        self.tags.append(newTag)
                    }
                }

                if !moreAvailable {
                    self.scanTimeoutWorkItem?.cancel()
                    self.scanTimeoutWorkItem = nil
                    self.isScanning = false
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
