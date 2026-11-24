import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var fonts: FontLibrary
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.armscii) private var armscii = true
    @AppStorage(AppSettings.Key.fingerDrawing) private var fingerDrawing = false
    @AppStorage(AppSettings.Key.serifFallback) private var serif = AppSettings.defaultSerif
    @AppStorage(AppSettings.Key.sansFallback) private var sans = AppSettings.defaultSans
    @AppStorage(AppSettings.Key.monoFallback) private var mono = AppSettings.defaultMono
    @AppStorage(AppSettings.Key.paper) private var paper = PaperSize.a4.rawValue

    /// Armenian families the document engine can use (the app's and the added ones).
    private var engineFamilies: [String] {
        var seen = Set<String>()
        return fonts.allFaces.filter(\.supportsArmenian).map(\.family).filter { seen.insert($0).inserted }.sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Переводить ArmSCII в Юникод", isOn: $armscii)
            } header: {
                Text("Армянский текст")
            } footer: {
                Text("Старые документы, набранные шрифтами «Arial Armenian», «Times Armenian» и похожими, показываются как настоящий армянский текст.")
            }

            Section {
                familyPicker("С засечками", selection: $serif)
                familyPicker("Без засечек", selection: $sans)
                familyPicker("Моноширинный", selection: $mono)
            } header: {
                Text("Замена недостающих шрифтов")
            } footer: {
                Text("Если в документе армянский текст набран шрифтом, которого нет (например, GHEA Grapalat или Sylfaen), он будет показан выбранным шрифтом.")
            }

            Section {
                Toggle("Рисовать пальцем", isOn: $fingerDrawing)
                Picker("Бумага для TXT и HTML", selection: $paper) {
                    ForEach(PaperSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Когда рисование пальцем выключено, рисует только Apple Pencil, а пальцем листаются страницы.")
            }

            Section("О приложении") {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Движок документов", value: WordEngine.shared.version)
                Text("Документы Word, ODT и RTF открывает движок WordCraft (MIT / Apache 2.0). Шрифты Noto, DejaVu, Liberation, Carlito и Caladea распространяются по свободным лицензиям (OFL и др.), тексты лицензий лежат в папке Fonts приложения.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { dismiss() }
            }
        }
    }

    private func familyPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(engineFamilies + (engineFamilies.contains(selection.wrappedValue) ? [] : [selection.wrappedValue]), id: \.self) { family in
                Text(family).tag(family)
            }
        }
    }
}
