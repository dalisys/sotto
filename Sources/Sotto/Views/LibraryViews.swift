import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var confirmClear = false
    private var filtered: [DictationRecord] {
        search.isEmpty ? model.history : model.history.filter { $0.text.localizedCaseInsensitiveContains(search) || ($0.applicationName?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Every thought, kept.").font(SottoTheme.font(32, weight: .bold)).tracking(-1)
                    Text("\(model.history.count) dictations · \(model.totalWords) words").font(SottoTheme.font(13)).foregroundStyle(SottoTheme.muted)
                }
                Spacer()
                Button { model.exportHistory() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SottoButtonStyle()).disabled(model.history.isEmpty)
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(SottoButtonStyle()).disabled(model.history.isEmpty).accessibilityLabel("Clear history")
            }
            if model.history.isEmpty {
                SottoEmptyState(symbol: "clock", title: "No dictations yet", detail: "Once you finish a dictation, its transcript appears here. Your history stays local.")
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(SottoTheme.muted)
                    TextField("Search transcripts", text: $search).textFieldStyle(.plain)
                }.padding(12).background(Color.white).overlay(Rectangle().strokeBorder(SottoTheme.line))
                if filtered.isEmpty {
                    SottoEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try searching for another word or app name.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { record in HistoryRow(record: record) }
                        }
                    }
                }
            }
        }.padding(32)
            .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Saved transcripts and retained recordings will be deleted locally.") }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let record: DictationRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let app = record.applicationName { Text("·"); Text(app).lineLimit(1) }
                Spacer()
                Text("\(record.wordCount) words · \(sottoDuration(record.duration))")
            }.font(SottoTheme.font(11)).foregroundStyle(SottoTheme.muted)
            Text(record.text).font(SottoTheme.font(15)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                Button { model.loadHistory(record) } label: { Label("Open", systemImage: "arrow.up.right") }
                    .disabled(model.phase.isBusy)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.text, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Spacer()
                Button { model.deleteHistory(id: record.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete dictation")
            }.buttonStyle(.plain).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
        }.padding(22).background(Color.white).overlay(Rectangle().strokeBorder(SottoTheme.line))
    }
}

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var phrase = ""
    @State private var replacement = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your words. Your spelling.").font(SottoTheme.font(32, weight: .bold)).tracking(-1)
                    Text("Teach Sotto names and terms you use. Replacements are applied to your finished transcript.")
                        .font(SottoTheme.font(14)).foregroundStyle(SottoTheme.muted).lineSpacing(4)
                }
                RuledSection("Add a word or phrase") {
                    HStack(alignment: .bottom, spacing: 16) {
                        entryField("Spoken phrase", text: $phrase, prompt: "e.g. sotto")
                        Image(systemName: "arrow.right").foregroundStyle(SottoTheme.muted).padding(.bottom, 10)
                        entryField("Preferred spelling", text: $replacement, prompt: "e.g. Sotto")
                        Button("Add") {
                            model.addDictionaryEntry(phrase: phrase, replacement: replacement)
                            phrase = ""; replacement = ""
                        }.buttonStyle(SottoButtonStyle(prominent: true))
                            .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phrase.count > 200 || replacement.count > 2_000)
                    }
                }
                if model.dictionary.isEmpty {
                    SottoEmptyState(symbol: "character.book.closed", title: "Make it sound like you", detail: "Add a name, a product, or a phrase that needs a particular spelling.").frame(minHeight: 215)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Spoken phrase").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Preferred spelling").frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 24, height: 1)
                        }.font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted).padding(18)
                        ForEach(model.dictionary) { entry in
                            Rectangle().fill(SottoTheme.line).frame(height: 1)
                            HStack {
                                Text(entry.phrase).frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.replacement).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.removeDictionaryEntry(id: entry.id) } label: { Image(systemName: "trash").frame(width: 24) }
                                    .buttonStyle(.plain).foregroundStyle(SottoTheme.muted).accessibilityLabel("Delete \(entry.phrase)")
                            }.font(SottoTheme.font(14)).padding(18)
                        }
                    }.background(Color.white).overlay(Rectangle().strokeBorder(SottoTheme.line))
                }
            }.padding(32)
        }
    }
    private func entryField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
            TextField(prompt, text: text).textFieldStyle(.plain).padding(11)
                .background(SottoTheme.surface).overlay(Rectangle().strokeBorder(SottoTheme.line))
                .accessibilityLabel(label)
        }
    }
}
