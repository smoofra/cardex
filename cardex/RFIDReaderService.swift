import Foundation
import Combine
@preconcurrency import TSLAsciiCommands
import ExternalAccessory
import CoreBluetooth
import os

private let log = Logger(subsystem: "org.elder-gods.cardex", category: "RFID")
private let protocolLog = Logger(subsystem: "org.elder-gods.cardex", category: "RFID.Protocol")

struct Connection {
    var minPower: Int
    var maxPower: Int
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
    
    enum State {
        case disconnected
        case connecting
        case setup(Task<Void, Never>)
        case connected(Connection)
        case scanning(Connection, Task<Void, Never>)
    }
    
    @Published var power: Int = 16
    @Published var state: State = .disconnected
    @Published var tags: [RFIDTag] = []
    @Published var lastScanEPCs: Set<String> = []
    @Published var lastErrorMessage: String?

    private let scanQueue = DispatchQueue(label: "org.elder-gods.cardex.scan", qos: .default)
    private var powerSendWorkItem: DispatchWorkItem? = nil
    private var currentScanEPCs: Set<String> = []
    private let commander: TSLAsciiCommander
    private var centralManager: CBCentralManager?

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
    
    var connection: Connection? {
        switch state {
        case .connected(let c):
            return c
        case .scanning(let c, _):
            return c
        default:
            return nil
        }
    }
    
    var connected: Bool {
        switch state {
        case .connected, .scanning:
            return true
        default:
            return false
        }
    }
    
    var disconnected: Bool {
        switch state {
        case .disconnected:
            return true
        default:
            return false
        }
    }

    @MainActor
    func connect() {
        guard case .disconnected = state else { return }
        log.info("connecting...")
        state = .connecting
        self.connectToAvailableAccessory(showPickerIfUnavailable: true)
    }

    @MainActor
    private func connectToAvailableAccessory(showPickerIfUnavailable: Bool) {
        guard case .connecting = state else { return }
        log.debug("trying to connect via EA...")
        if let accessory = findAccessory(matching: requiredProtocolString) {
            log.info("Found accessory: \(accessory.name, privacy: .public). Attempting commander connect...")
            commander.connect(accessory)
            if !commander.isConnected {
                disconnect(errorMessage:  "failed to connect to reader")
            }
            return
        }
        
        guard showPickerIfUnavailable else {
            disconnect(errorMessage: "No matching accessory")
            return
        }
        
        log.info("not found, showing picker")

        // Ensure Bluetooth permission is granted before showing the EA picker.
        // On iOS 26 the picker requires an authorized CBCentralManager or it fails
        // at the usermanagerd XPC layer before any UI appears.

        if let cm = centralManager, cm.state == .poweredOn {
            showBluetoothAccessoryPicker()
            return
        }

        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard case .connecting = state else { return }
        switch central.state {
        case .poweredOn:
            // Delay to let the scene return to foreground-active after the permission dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                self.showBluetoothAccessoryPicker()
            }
        case .unauthorized:
            disconnect(errorMessage: "Bluetooth permission denied")
        default:
            disconnect(errorMessage: "Bluetooth unavailable: \(central.state.rawValue)")
        }
    }

    @MainActor
    private func showBluetoothAccessoryPicker() {
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [self] error in
            DispatchQueue.main.async { [self] in
                guard case .connecting = state else { return }
                if let error = error {
                    disconnect(errorMessage: "Bluetooth picker error: \(error)")
                }
                connectToAvailableAccessory(showPickerIfUnavailable: false)
            }
        }
    }

    init(overrideInit: Bool = false) {
        commander = TSLAsciiCommander()
        super.init()

        let logger = TSLLoggerResponder.default()
        logger.lineReceivedBlock = { line in
            protocolLog.info("\(line, privacy: .public)")
        }
        commander.add(logger)
        let triggerResponder = InventoryResponder()
        triggerResponder.transponderResponder.transponderDelegate = self
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
        guard commander.isConnected else {
            disconnect(errorMessage: "reader disconnected")
            return
        }
        switch state {
        case .connecting:
            state = .setup(runOrDisconnect() {
                try await self.setupReader()
            })
        default:
            break
        }
    }

    @MainActor
    private func runOrDisconnect(_ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        return Task {
            do {
                try await work()
            } catch {
                disconnect(errorMessage: "\(error)")
            }
        }
    }
    


    // Run a synchronous reader command on scanQueue, throwing if the reader is
    // not connected, the command fails, or this connection attempt has been
    // superseded.
    @MainActor
    private func execute(_ cmd: TSLAsciiSelfResponderCommandBase, failure: String) async throws {
        var waiting = true
        let commander = self.commander
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
                scanQueue.async {
                    if !commander.isConnected {
                        k.resume(throwing: RFIDError(message: "reader disconnected"))
                    }
                    commander.execute(cmd)
                    waiting = false
                    k.resume()
                }
            }
        }, onCancel: {
            DispatchQueue.main.async {
                if waiting {
                    commander.abortSynchronousCommand()
                }
            }
        })
        try Task.checkCancellation()
        guard cmd.isSuccessful else {
            throw RFIDError(message: failure, code: cmd.errorCode)
        }
    }
    
    
    private func withTimeout(_ duration: Duration, work: @escaping @MainActor () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw RFIDError(message: "timeout reached")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @MainActor
    private func setupReader() async throws {
        guard case .setup = state else { return }
        try await withTimeout(.seconds(30)) { [self] in
            log.debug("querying power range of reader")
            // Reset to defaults then read back — post-reset outputPower is the reader's maximum
            let probe = TSLInventoryCommand.synchronousCommand()
            probe.resetParameters = TSL_TriState_YES
            probe.readParameters = TSL_TriState_YES
            probe.takeNoAction = TSL_TriState_YES
            try await execute(probe, failure: "power range query failed")
            
            let lo = Int(TSLInventoryCommand.minimumOutputPower())
            let hi = Int(probe.outputPower)
            guard lo >= 0, hi >= 0, lo <= hi else {
                throw RFIDError(message: "power range query returned nonsense values")
            }
            
            log.debug("setting up switch action")
            let switchAction = TSLSwitchActionCommand.synchronousCommand()
            switchAction.asynchronousReportingEnabled = TSL_TriState_YES
            switchAction.singlePressAction = TSL_SwitchAction_inventory
            try await execute(switchAction, failure: "switch action setup failed")
            
            power = min(max(power, lo), hi)
            
            log.debug("setting up inventory command")
            let inv = TSLInventoryCommand.synchronousCommand()
            inv.takeNoAction = TSL_TriState_YES
            inv.includeEPC = TSL_TriState_YES
            inv.includeTransponderRSSI = TSL_TriState_YES
            inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
            inv.outputPower = Int32(power)
            try await execute(inv, failure: "inventory command setup failed")
            
            state = .connected(Connection(minPower: lo, maxPower: hi))
        }
    }

    @MainActor
    func setPower(_ newPower: Int) {
        let connection: Connection
        switch state {
        case .scanning(let c, _), .connected(let c):
            connection = c
        default:
            return
        }
        
        let clamped = min(max(newPower, connection.minPower), connection.maxPower)
        guard clamped != power else { return }
        power = clamped

        // Debounce so dragging the slider doesn't flood the reader.
        powerSendWorkItem?.cancel()
        let item = DispatchWorkItem { [self] in
            self.sendPowerToReader(power)
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
            switch self.state {
            case .scanning, .connected:
                break
            default:
                return
            }
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
        DispatchQueue.main.async { [self] in
            switch self.state {
            case .disconnected, .connecting, .connected:
                break
            case .scanning(_, let task):
                task.cancel()
            case .setup(let task):
                task.cancel()
            }
            state = .disconnected
            powerSendWorkItem?.cancel()
            powerSendWorkItem = nil
            commander.disconnect()
            self.currentScanEPCs = []
            if let errorMessage {
                log.error("\(errorMessage, privacy: .public)")
                self.lastErrorMessage = errorMessage
            }
        }
    }

    @MainActor
    func clearTags() {
        self.tags.removeAll()
        self.lastScanEPCs = []
    }
    
    @MainActor
    func startScan() {
        guard case .connected(let connection) = state else { return }
        let task = runOrDisconnect {
            try await self.scan()
        }
        state = .scanning(connection, task)
    }

    @MainActor
    func stopScan() {
        guard case .scanning(let connection, let task) = state else {
            return
        }
        task.cancel()
        state = .connected(connection)
    }


    @MainActor
    func scan() async throws {
        guard case .scanning(let connection, _) = state else {
            return
        }
        currentScanEPCs = []
        let inv = TSLInventoryCommand.synchronousCommand()
        inv.includeEPC = TSL_TriState_YES
        inv.includeTransponderRSSI = TSL_TriState_YES
        inv.duplicateRemoval = TSL_DuplicateRemovalMode_On
        inv.outputPower = Int32(power)
        
        try await withTimeout(.seconds(5)) {
            do {
                try await self.execute(inv, failure: "scan failed")
            } catch let err as RFIDError {
                if err.code != "005" { // no tags found.  this is fine.
                    throw err
                }
            }
            log.debug("scan done")
            self.state = .connected(connection)
        }
    }
}
