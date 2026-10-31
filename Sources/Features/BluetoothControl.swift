import SwiftUI
import CoreBluetooth
import CryptoKit
import Security

struct NearbyBridge: Identifiable {
  let peripheral: CBPeripheral
  let name: String
  var id: UUID { peripheral.identifier }
}

enum BridgeKeychain {
  private static let service = "ru.atmosproduction.bridgephone.control"
  static func read() -> String? {
    let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
      kSecAttrAccount as String:"shtab", kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
    var value: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
    return String(data:data, encoding:.utf8)
  }
  static func save(_ key: String) -> Bool {
    let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"shtab"]
    let data = Data(key.utf8)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:data] as CFDictionary)
    if status == errSecSuccess { return true }
    guard status == errSecItemNotFound else { return false }
    var item = q
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }
}

@MainActor
final class BluetoothControl: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let service = CBUUID(string:"a7e0c0de-0000-4a7b-9c3d-000000000001")
  static let challengeID = CBUUID(string:"a7e0c0de-0000-4a7b-9c3d-000000000010")
  static let inputID = CBUUID(string:"a7e0c0de-0000-4a7b-9c3d-000000000011")
  @Published private(set) var enabled = UserDefaults.standard.bool(forKey:"bridgeBLEEnabled")
  @Published private(set) var ready = false
  @Published private(set) var status = "Управление через интернет"
  @Published private(set) var name = "Ноутбук"
  @Published private(set) var devices: [NearbyBridge] = []
  var changed: (() -> Void)?
  private var central: CBCentralManager?
  private var peer: CBPeripheral?
  private var challenge: CBCharacteristic?
  private var input: CBCharacteristic?
  private var active = false
  private var nonce = ""
  private var sequence: Int64 = 0
  private var serverOffset: Int64 = 0
  private var authenticating = false
  private var pending: ((Any?, String?) -> Void)?
  private var pendingEvents: [[String:Any]] = []
  private var timer: Timer?
  private var reconnect: Timer?

  func configure(key: String?) {
    if let key = key, key.range(of:"^[A-Za-z0-9_-]{16,128}$", options:.regularExpression) != nil {
      guard BridgeKeychain.save(key) else { update("Не удалось сохранить ключ на iPhone"); return }
    }
    guard BridgeKeychain.read() != nil else { update("Сначала войди в Штаб"); return }
    enabled = true
    UserDefaults.standard.set(true, forKey:"bridgeBLEEnabled")
    setActive(true)
  }
  func setActive(_ value: Bool) {
    active = value
    if !value { disconnect(); return }
    guard enabled, BridgeKeychain.read() != nil else { return }
    if central == nil {
      central = CBCentralManager(delegate:self, queue:.main, options:[CBCentralManagerOptionShowPowerAlertKey:true])
    } else if central?.state == .poweredOn { search() }
  }
  func disable() {
    enabled = false
    UserDefaults.standard.set(false, forKey:"bridgeBLEEnabled")
    disconnect()
    update("Управление через интернет")
  }
  private func update(_ text: String) { status = text; changed?() }
  func search() {
    guard active, enabled, central?.state == .poweredOn, peer == nil else { return }
    reconnect?.invalidate(); reconnect = nil
    update("Ищу ноутбук · пока через интернет")
    if let s = UserDefaults.standard.string(forKey:"bridgeBLEPeer"), let id = UUID(uuidString:s),
       let saved = central?.retrievePeripherals(withIdentifiers:[id]).first {
      select(saved); return
    }
    central?.scanForPeripherals(withServices:[Self.service], options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
  }
  func select(_ device: CBPeripheral) {
    guard active, enabled, central?.state == .poweredOn, peer == nil else { return }
    central?.stopScan()
    peer = device
    device.delegate = self
    update("Подключаюсь к «" + (device.name ?? "Bridge") + "»")
    central?.connect(device)
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval:12, repeats:false) { [weak self] _ in
      Task { @MainActor in self?.connectionFailed("Ноутбук не ответил · через интернет") }
    }
  }
  private func finish(_ error: String?) {
    timer?.invalidate(); timer = nil
    let callback = pending; pending = nil; pendingEvents = []
    callback?(error == nil ? ["ok":true] : nil, error)
  }
  private func disconnect() {
    reconnect?.invalidate(); reconnect = nil
    central?.stopScan()
    finish("Bluetooth отключён. Команда не повторяется через интернет.")
    ready = false; authenticating = false
    challenge = nil; input = nil; nonce = ""
    let previous = peer; peer = nil
    if let previous = previous { central?.cancelPeripheralConnection(previous) }
    changed?()
  }
  private func connectionFailed(_ text: String) {
    disconnect(); update(text)
    if active && enabled {
      reconnect = Timer.scheduledTimer(withTimeInterval:3, repeats:false) { [weak self] _ in
        Task { @MainActor in self?.search() }
      }
    }
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn { search() }
    else {
      disconnect()
      update(central.state == .unauthorized ? "Разреши Bluetooth в настройках iPhone · пока интернет" : "Bluetooth недоступен · через интернет")
    }
  }
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
    guard !devices.contains(where:{$0.id == peripheral.identifier}) else { return }
    let label = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Bridge"
    devices.append(NearbyBridge(peripheral:peripheral, name:label))
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peer?.identifier == peripheral.identifier else { central.cancelPeripheralConnection(peripheral); return }
    update("Проверяю ключ ноутбука…")
    peripheral.discoverServices([Self.service])
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peer?.identifier == peripheral.identifier else { return }
    connectionFailed("Не удалось подключиться · через интернет")
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard peer?.identifier == peripheral.identifier else { return }
    connectionFailed("Bluetooth потерян · через интернет")
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peer?.identifier == peripheral.identifier, active, enabled else { return }
    guard error == nil, let service = peripheral.services?.first(where:{$0.uuid == Self.service}) else {
      connectionFailed("Обнови Bridge на ноутбуке · пока интернет"); return
    }
    peripheral.discoverCharacteristics([Self.challengeID,Self.inputID], for:service)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peer?.identifier == peripheral.identifier, active, enabled else { return }
    challenge = service.characteristics?.first(where:{$0.uuid == Self.challengeID})
    input = service.characteristics?.first(where:{$0.uuid == Self.inputID})
    guard error == nil, let challenge = challenge, input != nil else {
      connectionFailed("В Bridge на ноутбуке ещё нет Bluetooth-пульта"); return
    }
    peripheral.readValue(for:challenge)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peer?.identifier == peripheral.identifier, active, enabled else { return }
    guard characteristic.uuid == Self.challengeID, error == nil, let data = characteristic.value,
          let value = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
          let challengeNonce = value["nonce"] as? String,
          challengeNonce.range(of:"^[0-9a-f]{32}$", options:.regularExpression) != nil,
          let time = value["time"] as? NSNumber, let key = BridgeKeychain.read(), let input = input else {
      connectionFailed("Не удалось проверить ноутбук · через интернет"); return
    }
    nonce = challengeNonce; sequence = 0
    serverOffset = time.int64Value - Self.now
    name = String((value["name"] as? String ?? "Ноутбук").prefix(80))
    let proof = HMAC<SHA256>.authenticationCode(for:Data(nonce.utf8), using:SymmetricKey(data:Data(key.utf8)))
      .map { String(format:"%02x", $0) }.joined()
    guard let auth = try? JSONSerialization.data(withJSONObject:["proof":proof]),
          auth.count <= peripheral.maximumWriteValueLength(for:.withResponse) else {
      connectionFailed("Размер Bluetooth-пакета не поддерживается"); return
    }
    authenticating = true
    peripheral.writeValue(auth, for:input, type:.withResponse)
  }
  private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
  func send(events:[[String:Any]], reply:@escaping (Any?,String?) -> Void) {
    guard ready, pending == nil, (1...12).contains(events.count),
          JSONSerialization.isValidJSONObject(events) else { reply(nil,"Bluetooth не готов"); return }
    pending = reply; pendingEvents = events
    writeNext()
  }
  private func writeNext() {
    guard let peer = peer, let input = input, ready else { finish("Bluetooth потерян"); return }
    if pendingEvents.isEmpty { finish(nil); return }
    let limit = peer.maximumWriteValueLength(for:.withResponse)
    var count = pendingEvents.count
    var data: Data?
    while count > 0 {
      let packet:[String:Any] = ["session":nonce,"seq":sequence+1,"expires":Self.now+serverOffset+2500,"events":Array(pendingEvents.prefix(count))]
      if let bytes = try? JSONSerialization.data(withJSONObject:packet), bytes.count <= limit { data = bytes; break }
      count -= 1
    }
    guard let data = data else { finish("Bluetooth-пакет слишком большой"); return }
    pendingEvents.removeFirst(count); sequence += 1
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval:4, repeats:false) { [weak self] _ in
      Task { @MainActor in self?.connectionFailed("Нет подтверждения Bluetooth. Повтори действие вручную.") }
    }
    peer.writeValue(data, for:input, type:.withResponse)
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard peer?.identifier == peripheral.identifier, active, enabled else { return }
    guard characteristic.uuid == Self.inputID else { return }
    if authenticating {
      authenticating = false
      guard error == nil else {
        disable(); update("Ключ не принят. Войди в тот же Штаб и подключи снова."); return
      }
      timer?.invalidate(); timer = nil
      UserDefaults.standard.set(peripheral.identifier.uuidString, forKey:"bridgeBLEPeer")
      ready = true
      update(name + " · Bluetooth")
    } else if pending != nil {
      if error != nil { connectionFailed("Команда Bluetooth отклонена. Повтори действие вручную.") }
      else { writeNext() }
    }
  }
  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard peer?.identifier == peripheral.identifier, invalidatedServices.contains(where:{$0.uuid == Self.service}) else { return }
    connectionFailed("Bridge на ноутбуке перезапущен · переподключаюсь")
  }
}

struct BluetoothSetup: View {
  @ObservedObject var control: BluetoothControl
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(control.status, systemImage:control.ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
          Text("Рядом — Bluetooth. При потере связи пульт возвращается на интернет, а при восстановлении Bluetooth — обратно.").font(.footnote).foregroundStyle(.secondary)
        }
        if !control.ready {
          Section("Ноутбуки рядом") {
            if control.devices.isEmpty { Text("Открой обновлённый Bridge на ноутбуке. Устройства появятся здесь.").foregroundStyle(.secondary) }
            ForEach(control.devices) { device in
              Button(device.name) { control.select(device.peripheral) }
            }
            Button("Повторить поиск") { control.search() }
          }
        }
        Section {
          Text("Первое подключение может запросить сопряжение iPhone с Windows. Ключ берётся из твоего входа в Штаб и хранится в защищённом хранилище iPhone.").font(.footnote)
          Button("Отключить Bluetooth-пульт", role:.destructive) { control.disable() }
        }
      }.navigationTitle("Bluetooth").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Готово") { dismiss() } } }
    }
  }
}
