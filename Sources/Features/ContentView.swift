import SwiftUI

/// First-install checkpoint. Connection adapters are not simulated.
struct ContentView: View {
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack(spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone")
              .font(.system(size: 38)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 5) {
              Text("Телефон и ноутбук").font(.title2.bold())
              Text("Подключение пока недоступно").font(.footnote).foregroundStyle(.secondary)
            }
          }.padding(.vertical, 12)
          VStack(alignment: .leading, spacing: 16) {
            Text("Порядок подключения").font(.headline)
            connection("Bluetooth", "Рядом с ноутбуком", icon: "antenna.radiowaves.left.and.right", number: "1")
            Divider()
            connection("Wi-Fi", "Если Bluetooth недоступен", icon: "wifi", number: "2")
            Divider()
            connection("Интернет", "Когда вы в разных сетях", icon: "globe", number: "3")
          }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
          Text("При восстановлении Bluetooth приложение должно возвращаться на него автоматически.")
            .font(.subheadline).foregroundStyle(.secondary)
          HStack(spacing: 14) {
            feature("Кликер", icon: "rectangle.on.rectangle")
            feature("Тачпад", icon: "hand.draw")
          }
          Text("Первая проверочная сборка: установка и запуск. Подключение к Windows и управление ещё не включены.")
            .font(.footnote).foregroundStyle(.secondary)
        }.padding(20)
      }.background(Color(.systemGroupedBackground)).navigationTitle("Bridge")
    }
  }
  private func connection(_ title: String, _ description: String, icon: String, number: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: icon).font(.title3).foregroundStyle(.blue).frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(description).font(.footnote).foregroundStyle(.secondary)
      }
      Spacer()
      Text(number).font(.caption.bold()).foregroundStyle(.secondary)
    }
  }
  private func feature(_ title: String, icon: String) -> some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.title2)
      Text(title).font(.headline)
    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
  }
}
