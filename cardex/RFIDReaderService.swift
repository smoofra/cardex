import Foundation
import Combine
import TSLAsciiCommands
import ExternalAccessory
import CoreBluetooth

struct Connection {
    let N: Int
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

    @Published var currentConnectionAttempt: Int?
    @Published var isScanning: Bool = false
    @Published var connection: Connection?
    @Published var tags: [RFIDTag] = []
    @Published var lastScanEPCs: Set<String> = []
    @Published var lastErrorMessage: String?

    private let scanQueue = DispatchQueue(label: "org.elder-gods.cardex.scan", qos: .default)
    private var timeout: DispatchWorkItem? = nil
    private var powerSendWorkItem: DispatchWorkItem? = nil
    private var currentScanEPCs: Set<String> = []
    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?
    private var triggerResponder: InventoryResponder
    private var nextConnectionAttmept : Int = 0

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
        assert(Thread.isMainThread)
        guard (currentConnectionAttempt == nil) else {
            fatalError("connect called while already connecting")
        }
        print("connecting...")
        let N = nextConnectionAttmept
        currentConnectionAttempt = N
        nextConnectionAttmept += 1
        self.connectToAvailableAccessory(N, showPickerIfUnavailable: true)
    }

    private func connectToAvailableAccessory(_ N: Int, showPickerIfUnavailable: Bool) {
        assert(Thread.isMainThread)
        print("trying to connect via EA...")
        if let accessory = findAccessory(matching: requiredProtocolString) {
            print("Found accessory: \(accessory.name). Attempting commander connect...")
            commander.connect(accessory)
            if !commander.isConnected {
                disconnect(N, errorMessage:  "failed to connect to reader")
            }
            return
        }
        
        guard showPickerIfUnavailable else {
            disconnect(N, errorMessage: "No matching accessory")
            return
        }
        
        print("not found, showing picker")

        // Ensure Bluetooth permission is granted before showing the EA picker.
        // On iOS 26 the picker requires an authorized CBCentralManager or it fails
        // at the usermanagerd XPC layer before any UI appears.

        if let cm = centralManager, cm.state == .poweredOn {
            showBluetoothAccessoryPicker(N)
            return
        }

        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let N = currentConnectionAttempt else { return }

        switch central.state {
        case .poweredOn:
            // Delay to let the scene return to foreground-active after the permission dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                self.showBluetoothAccessoryPicker(N)
            }
        case .unauthorized:
            disconnect(N, errorMessage: "Bluetooth permission denied")
        default:
            disconnect(N, errorMessage: "Bluetooth unavailable: \(central.state.rawValue)")
        }
    }

    private func showBluetoothAccessoryPicker(_ N: Int) {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [self] error in
            DispatchQueue.main.async { [self] in
                if let error = error {
                    disconnect(N, errorMessage: "Bluetooth picker error: \(error)")
                }
                connectToAvailableAccessory(N, showPickerIfUnavailable: false)
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
        assert(Thread.isMainThread)
        guard let N = currentConnectionAttempt ?? connection?.N else { return }
        if !commander.isConnected {
            disconnect(N, errorMessage: "reader disconnected")
        } else {
            setupReader(N)
        }
    }
    
    private func atN(_ N: Int) -> Bool {
        if let N0 = self.connection?.N ?? self.currentConnectionAttempt, N0 != N {
            return false
        }
        return true
    }

    private func setupReader(_ N: Int) {
        scanQueue.async { [self] in
            
            timeout?.cancel()
            let workItem = DispatchWorkItem { [self] in
                disconnect(N, errorMessage: "timeout reached.")
            }
            timeout = workItem
            scanQueue.asyncAfter(deadline: .now() + 30.0, execute: workItem)

            
            guard commander.isConnected, atN(N) else {
                disconnect(N, errorMessage: "reader is not connected")
                return
            }
            print("querying power range of reader")
            // Reset to defaults then read back — post-reset outputPower is the reader's maximum
            var cmd = TSLInventoryCommand.synchronousCommand()
            cmd.resetParameters = TSL_TriState_YES
            cmd.readParameters = TSL_TriState_YES
            cmd.takeNoAction = TSL_TriState_YES
            commander.execute(cmd)
            guard cmd.isSuccessful, atN(N) else {
                disconnect(N, errorMessage: "power range query failed")
                return
            }
            let lo = Int(TSLInventoryCommand.minimumOutputPower())
            let hi = Int(cmd.outputPower)
            if lo < 0 || hi < 0 || lo > hi {
                disconnect(N, errorMessage: "power range query returned nonsense values")
                return
            }
            
            print("setting up switch action")
            let switchAction = TSLSwitchActionCommand.synchronousCommand()
            switchAction.asynchronousReportingEnabled = TSL_TriState_YES
            switchAction.singlePressAction = TSL_SwitchAction_inventory
            commander.execute(switchAction)
            guard switchAction.isSuccessful,atN(N) else {
                disconnect(N, errorMessage: "switch action setup failed")
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
            guard cmd.isSuccessful, atN(N) else {
                disconnect(N, errorMessage: "inventory command setup failed")
                return
            }
            
            timeout?.cancel()
            
            DispatchQueue.main.async {
                self.connection = Connection(N: N, minPower: lo, maxPower: hi, power: power)
                self.currentConnectionAttempt = nil
            }
        }
    }

    func setPower(_ newPower: Int) {
        assert(Thread.isMainThread)
        guard var connection = self.connection else { return }
        let clamped = min(max(newPower, connection.minPower), connection.maxPower)
        guard clamped != connection.power else { return }
        connection.power = clamped
        self.connection = connection

        // Debounce so dragging the slider doesn't flood the reader.
        powerSendWorkItem?.cancel()
        let item = DispatchWorkItem { [self] in
            self.sendPowerToReader(connection)
        }
        powerSendWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func sendPowerToReader(_ connection: Connection) {
        scanQueue.async { [self] in
            let cmd = TSLInventoryCommand.synchronousCommand()
            cmd.takeNoAction = TSL_TriState_YES
            cmd.outputPower = Int32(connection.power)
            commander.execute(cmd)
            if !cmd.isSuccessful {
                disconnect(connection.N, errorMessage: "set power failed.")
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
    
    func disconnect(_ N: Int, errorMessage: String? = nil) {
        DispatchQueue.main.async { [self] in
            let N0 = self.currentConnectionAttempt ?? self.connection?.N
            if let N0, N < N0 {
                return
            }
            timeout?.cancel()
            timeout = nil
            powerSendWorkItem?.cancel()
            powerSendWorkItem = nil
            commander.disconnect()
            if let errorMessage {
                print("\(errorMessage)")
                self.lastErrorMessage = errorMessage
            }
            self.connection = nil
            self.isScanning = false
            self.currentConnectionAttempt = nil
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

        timeout?.cancel()
        let workItem = DispatchWorkItem { [self] in
            print("Scan timeout reached.")
            stopScan()
        }
        timeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)

        let inv = TSLInventoryCommand.synchronousCommand()
        inv.includeEPC = TSL_TriState_YES
        inv.includeTransponderRSSI = TSL_TriState_YES
        inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
        inv.outputPower = Int32(connection.power)

        scanQueue.async { [self] in
            commander.execute(inv)
            self.timeout?.cancel()
            self.timeout = nil
            DispatchQueue.main.async {
                self.isScanning = false
                self.timeout?.cancel()
                self.timeout = nil
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
        timeout?.cancel()
        timeout = nil
        self.isScanning = false
    }
}
