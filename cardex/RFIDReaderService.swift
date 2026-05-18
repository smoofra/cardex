import Foundation
import Combine
@preconcurrency import TSLAsciiCommands
import ExternalAccessory
import CoreBluetooth
import os

private let log = Logger(subsystem: "org.elder-gods.cardex", category: "RFID")
private let protocolLog = Logger(subsystem: "org.elder-gods.cardex", category: "RFID.Protocol")

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


struct RFIDError: Error, CustomStringConvertible {
    let message: String
    let code: String?
    
    init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
    
    var description: String {
        if let code {
            return "\(message): \(code)"
        }
        return message
    }
}


final class RFIDReaderService: NSObject, ObservableObject, CBCentralManagerDelegate, TSLTransponderReceivedDelegate {

    @Published var currentConnectionAttempt: Int?
    @Published var isScanning: Bool = false
    @Published var connection: Connection?
    @Published var tags: [RFIDTag] = []
    @Published var lastScanEPCs: Set<String> = []
    @Published var lastErrorMessage: String?

    private let scanQueue = DispatchQueue(label: "org.elder-gods.cardex.scan", qos: .default)
    private var powerSendWorkItem: DispatchWorkItem? = nil
    private var currentScanEPCs: Set<String> = []
    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?
    private var triggerResponder: InventoryResponder
    private var nextConnectionAttmept : Int = 0

    // MARK: - Configuration

    @MainActor
    private func findAccessory(matching protocolString: String) -> EAAccessory? {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        log.debug("EA connected accessories:")
        accessories.forEach { acc in
            log.debug("- \(acc.name, privacy: .public) by \(acc.manufacturer, privacy: .public) protocols: \(acc.protocolStrings, privacy: .public)")
        }
        return accessories.first { $0.protocolStrings.contains(protocolString) }
    }

    @MainActor
    func connect() {
        guard (currentConnectionAttempt == nil) else {
            fatalError("connect called while already connecting")
        }
        log.info("connecting...")
        let N = nextConnectionAttmept
        currentConnectionAttempt = N
        nextConnectionAttmept += 1
        self.connectToAvailableAccessory(N, showPickerIfUnavailable: true)
    }

    @MainActor
    private func connectToAvailableAccessory(_ N: Int, showPickerIfUnavailable: Bool) {
        log.debug("trying to connect via EA...")
        if let accessory = findAccessory(matching: requiredProtocolString) {
            log.info("Found accessory: \(accessory.name, privacy: .public). Attempting commander connect...")
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
        
        log.info("not found, showing picker")

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

    @MainActor
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
            protocolLog.info("\(line, privacy: .public)")
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

    @MainActor @objc
    private func handleCommanderStateChanged(_ note: Notification) {
        guard let N = currentConnectionAttempt ?? connection?.N else { return }
        guard commander.isConnected else {
            disconnect(N, errorMessage: "reader disconnected")
            return
        }
        runOrDisconnect(N) {
            try await self.setupReader(N)
        }
    }

    @MainActor
    private func runOrDisconnect(_ N: Int, _ work: @escaping @MainActor () async throws -> Void){
        Task {
            do {
                try await work()
            } catch {
                disconnect(N, errorMessage: "\(error)")
            }
        }
    }
    
    @MainActor
    private func atN(_ N: Int) -> Bool {
        if let N0 = self.connection?.N ?? self.currentConnectionAttempt, N0 != N {
            return false
        }
        return true
    }


    // Run a synchronous reader command on scanQueue, throwing if the reader is
    // not connected, the command fails, or this connection attempt has been
    // superseded.
    @MainActor
    private func execute(_ N: Int, _ cmd: TSLAsciiSelfResponderCommandBase, failure: String) async throws {
        guard commander.isConnected else {
            throw RFIDError(message: "reader is not connected")
        }
        guard atN(N) else {
            throw RFIDError(message: "connection attempt superseded")
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            scanQueue.async { [commander] in
                commander.execute(cmd)
                cont.resume()
            }
        }
        guard atN(N) else {
            throw RFIDError(message: "connection attempt superseded")
        }
        guard cmd.isSuccessful else {
            throw RFIDError(message: failure, code: cmd.errorCode)
        }
    }
    
    
    private func withTimeout(_ duration: Duration, work: @escaping @MainActor () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { [commander] group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                commander.abortSynchronousCommand()
                throw RFIDError(message: "timeout reached")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @MainActor
    private func setupReader(_ N: Int) async throws {
        try await withTimeout(.seconds(30)) { [self] in
            log.debug("querying power range of reader")
            // Reset to defaults then read back — post-reset outputPower is the reader's maximum
            let probe = TSLInventoryCommand.synchronousCommand()
            probe.resetParameters = TSL_TriState_YES
            probe.readParameters = TSL_TriState_YES
            probe.takeNoAction = TSL_TriState_YES
            try await execute(N, probe, failure: "power range query failed")
            
            let lo = Int(TSLInventoryCommand.minimumOutputPower())
            let hi = Int(probe.outputPower)
            guard lo >= 0, hi >= 0, lo <= hi else {
                throw RFIDError(message: "power range query returned nonsense values")
            }
            
            log.debug("setting up switch action")
            let switchAction = TSLSwitchActionCommand.synchronousCommand()
            switchAction.asynchronousReportingEnabled = TSL_TriState_YES
            switchAction.singlePressAction = TSL_SwitchAction_inventory
            try await execute(N, switchAction, failure: "switch action setup failed")
            
            let power = min(max(self.connection?.power ?? 16, lo), hi)
            
            log.debug("setting up inventory command")
            let inv = TSLInventoryCommand.synchronousCommand()
            inv.takeNoAction = TSL_TriState_YES
            inv.includeEPC = TSL_TriState_YES
            inv.includeTransponderRSSI = TSL_TriState_YES
            inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
            inv.outputPower = Int32(power)
            try await execute(N, inv, failure: "inventory command setup failed")
            
            guard atN(N) else { throw RFIDError(message: "connection attempt superseded") }
            self.connection = Connection(N: N, minPower: lo, maxPower: hi, power: power)
            self.currentConnectionAttempt = nil
        }
    }

    @MainActor
    func setPower(_ newPower: Int) {
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
            powerSendWorkItem?.cancel()
            powerSendWorkItem = nil
            commander.disconnect()
            if let errorMessage {
                log.error("\(errorMessage, privacy: .public)")
                self.lastErrorMessage = errorMessage
            }
            self.connection = nil
            self.isScanning = false
            self.currentConnectionAttempt = nil
            self.currentScanEPCs = []
        }
    }

    @MainActor
    func clearTags() {
        self.tags.removeAll()
        self.lastScanEPCs = []
    }
    
    @MainActor
    func startScan() {
        guard let connection else { return }
        runOrDisconnect(connection.N) { [self] in
            try await scan(connection)
        }
    }

    @MainActor
    func stopScan() {
        if !commander.isConnected { return }
        commander.abortSynchronousCommand()
        self.isScanning = false // FIXME?
    }


    @MainActor
    func scan(_ connection: Connection) async throws {
        isScanning = true
        lastErrorMessage = nil
        currentScanEPCs = []
        
        let inv = TSLInventoryCommand.synchronousCommand()
        inv.includeEPC = TSL_TriState_YES
        inv.includeTransponderRSSI = TSL_TriState_YES
        inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
        inv.outputPower = Int32(connection.power)
        
        try await withTimeout(.seconds(5)) { [self] in
            do {
                try await execute(connection.N, inv, failure: "scan failed")
            } catch let err as RFIDError {
                if err.code != "005" { // no tags found.  this is fine.
                    throw err
                }
            }
            self.isScanning = false
            log.debug("scan done")
        }
    }
}
