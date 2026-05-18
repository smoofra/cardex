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

// This custom responder does the same thing whether the inventory command was initated by the
// app as a synchonous command, initiated by the reader when the user pulls the trigger.
private final class InventoryResponder: TSLAsciiCommandResponderBase  {
    let transponderResponder = TSLTransponderResponder()

    override init() {
        super.init(commandName: ".iv")
    }

    override func processReceivedLine(_ fullLine: String, header: String, value: String, moreLinesAvailable moreAvailable: Bool) -> Bool {
        switch header {
        case "EP":
            transponderResponder.processReceivedLine(header, value: value)
        case "OK", "ER":
            transponderResponder.transponderComplete(withMoreAvailable: false)
        default:
            break
        }
        return false // keep passing lines to other responders
    }
}

struct RFIDTag: Hashable {
    let epc: String
    let rssi: Int?
    var count: Int = 1
}

let requiredProtocolString: String = "com.uk.tsl.rfid"


final class RFIDReaderService: NSObject, ObservableObject, CBCentralManagerDelegate, TSLTransponderReceivedDelegate {

    @Published var isConnecting: Bool = false
    @Published var isScanning: Bool = false
    @Published var connection: Connection?
    @Published var tags: [RFIDTag] = []
    @Published var lastScanEPCs: Set<String> = []
    @Published var lastErrorMessage: String?

    private let scanQueue = DispatchQueue(label: "org.elder-gods.cardex.scan", qos: .default)
    private var scanTimeoutWorkItem: DispatchWorkItem? = nil
    private var powerSendWorkItem: DispatchWorkItem? = nil
    private var currentScanEPCs: Set<String> = []
    private var isShowingAccessoryPicker = false
    private var pendingPickerRequest = false
    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?
    private var triggerResponder: InventoryResponder

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
            self.isConnecting = true
            self.connectToAvailableAccessory(showPickerIfUnavailable: true)
        }
    }

    private func connectToAvailableAccessory(showPickerIfUnavailable: Bool) {
        if let accessory = findAccessory(matching: requiredProtocolString) {
            print("Found accessory: \(accessory.name). Attempting commander connect...")
            commander.connect(accessory)
            print("connect result isConnected:", commander.isConnected)
            if !commander.isConnected {
                isConnecting = false
            }
            return
        }

        print("No matching accessory for protocol: \(requiredProtocolString).")

        guard showPickerIfUnavailable else {
            isConnecting = false
            return
        }
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
            isConnecting = false
        default:
            print("Bluetooth unavailable: \(central.state.rawValue)")
            isConnecting = false
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
        triggerResponder = InventoryResponder()
        super.init()
        triggerResponder.transponderResponder.transponderDelegate = self


        let logger = TSLLoggerResponder.default()
        logger.lineReceivedBlock = { line in
            print("TSL:", line)
        }
        commander.add(logger)


        commander.add(triggerResponder)
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
            setupReader()
        } else {
            disconnect()
        }
    }

    private func setupReader() {
        scanQueue.async { [self] in
            if !commander.isConnected {
                disconnect()
                return
            }
            print("querying power range of reader")
            // Reset to defaults then read back — post-reset outputPower is the reader's maximum
            var cmd = TSLInventoryCommand.synchronousCommand()
            cmd.resetParameters = TSL_TriState_YES
            cmd.readParameters = TSL_TriState_YES
            cmd.takeNoAction = TSL_TriState_YES
            commander.execute(cmd)
            guard cmd.isSuccessful else {
                disconnect(errorMessage: "power range query failed")
                return
            }
            let lo = Int(TSLInventoryCommand.minimumOutputPower())
            let hi = Int(cmd.outputPower)
            if lo < 0 || hi < 0 || lo > hi {
                disconnect(errorMessage: "power range query returned nonsense values")
                return
            }
            
            print("setting up switch action")
            let switchAction = TSLSwitchActionCommand.synchronousCommand()
            switchAction.asynchronousReportingEnabled = TSL_TriState_YES
            switchAction.singlePressAction = TSL_SwitchAction_inventory
            commander.execute(switchAction)
            if !switchAction.isSuccessful {
                disconnect(errorMessage: "switch action setup failed")
                return
            }
            
            let power = min(max(self.connection?.power ?? 16, lo), hi)
            
            print("setting ip inventory command")
            cmd = TSLInventoryCommand.synchronousCommand()
            cmd.takeNoAction = TSL_TriState_YES
            cmd.includeEPC = TSL_TriState_YES
            cmd.includeTransponderRSSI = TSL_TriState_YES
            cmd.duplicateRemoval = TSL_DuplicateRemovalMode_On
            cmd.outputPower = Int32(power)
            commander.execute(cmd)
            if !cmd.isSuccessful {
                disconnect(errorMessage: "inventory command setup failed")
                return
            }
            
            DispatchQueue.main.async {
                self.connection = Connection(minPower: lo, maxPower: hi, power: power)
                self.isConnecting = false
            }
        }
    }

    func setPower(_ newPower: Int) {
        guard var conn = connection else { return }
        let clamped = min(max(newPower, conn.minPower), conn.maxPower)
        guard clamped != conn.power else { return }
        conn.power = clamped
        connection = conn

        // Debounce so dragging the slider doesn't flood the reader.
        powerSendWorkItem?.cancel()
        let item = DispatchWorkItem { [self] in
            self.sendPowerToReader(clamped)
        }
        powerSendWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func sendPowerToReader(_ power: Int) {
        scanQueue.async { [self] in
            let cmd = TSLInventoryCommand.synchronousCommand()
            cmd.takeNoAction = TSL_TriState_YES
            cmd.outputPower = Int32(power)
            commander.execute(cmd)
            if !cmd.isSuccessful {
                disconnect(errorMessage: "set power failed.")
            }
        }
    }
    
    func transponderReceived(_ transponder: TSLTransponderData, moreAvailable: Bool) {
        let epc = transponder.epc
        let rssi = transponder.rssi?.intValue
        DispatchQueue.main.async {
            if let epc {
                self.currentScanEPCs.insert(epc)
                if let index = self.tags.firstIndex(where: { $0.epc == epc }) {
                    self.tags[index] = RFIDTag(epc: epc, rssi: rssi, count: self.tags[index].count + 1)
                } else {
                    self.tags.append(RFIDTag(epc: epc, rssi: rssi))
                }
            }
            if !moreAvailable {
                self.lastScanEPCs = self.currentScanEPCs
                self.currentScanEPCs = []
            }
        }
    }
    
    func disconnect(errorMessage: String? = nil) {
        commander.disconnect()
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        powerSendWorkItem?.cancel()
        powerSendWorkItem = nil
        DispatchQueue.main.async { [self] in
            if let errorMessage {
                print(errorMessage)
                self.lastErrorMessage = errorMessage
            }
            self.connection = nil
            self.isScanning = false
            self.isConnecting = false
            self.currentScanEPCs = []
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
        currentScanEPCs = []

        scanTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [self] in
            print("Scan timeout reached.")
            stopScan()
        }
        scanTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)

        let inv = TSLInventoryCommand.synchronousCommand()
        inv.includeEPC = TSL_TriState_YES
        inv.includeTransponderRSSI = TSL_TriState_YES
        inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
        inv.outputPower = Int32(connection.power)

        scanQueue.async { [self] in
            commander.execute(inv)
            self.scanTimeoutWorkItem?.cancel()
            self.scanTimeoutWorkItem = nil
            DispatchQueue.main.async {
                self.isScanning = false
                self.scanTimeoutWorkItem?.cancel()
                self.scanTimeoutWorkItem = nil
                self.isScanning = false
                if !inv.isSuccessful {
                    print("failed!")
                    self.lastErrorMessage = inv.errorCode.map { "Reader error ER:\($0)" } ?? "unknown error"
                } else {
                    print("done.")
                }
            }
        }
    }

    func stopScan() {
        if !commander.isConnected { return }
        commander.abortSynchronousCommand()
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        self.isScanning = false
    }
}
