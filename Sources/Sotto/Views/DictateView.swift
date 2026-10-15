import SwiftUI

struct DictateView: View {
    @EnvironmentObject var model: AppModel
    private var recording: Bool { model.phase == .recording }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Thoughts to text.").font(SottoTheme.font(41, weight: .bold)).tracking(-1.7)
                        Text("Speak naturally. Sotto turns your voice into text,\nready for wherever you’re writing.")
                            .font(SottoTheme.font(15)).foregroundStyle(SottoTheme.muted).lineSpacing(5)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(model.todayCount)).font(SottoTheme.font(40)).tracking(-2)
                        Text("dictations today").font(SottoTheme.font(11)).foregroundStyle(SottoTheme.muted)
                    }.padding(.top, 3)
                }
                recordingWorkspace
                transcriptWorkspace
                if let timing = model.lastTiming {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(model.latestPipelineLabel).font(SottoTheme.font(12, weight: .semibold))
                        Spacer()
                        Text(String(format: "%.0f ms speech · %.0f ms edit · %.0f ms insert", timing.transcriptionMilliseconds, timing.polishMilliseconds, timing.insertionMilliseconds))
                            .font(SottoTheme.font(11)).foregroundStyle(SottoTheme.muted).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                }
            }.padding(32)
        }
    }

    private var recordingWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(recording ? "Microphone is listening" : "Your voice starts here", systemImage: recording ? "mic.fill" : "mic")
                    .font(SottoTheme.font(12)).foregroundStyle(recording ? SottoTheme.orange : SottoTheme.muted)
                Spacer()
                Text(sottoDuration(model.elapsed)).font(SottoTheme.font(16)).monospacedDigit()
            }.padding(22)
            LiveWaveform(level: model.audioLevel, recording: recording)
                .frame(height: 107).padding(.horizontal, 22)
                .accessibilityLabel(recording ? "Live microphone level" : "Microphone inactive")
                .accessibilityValue("\(Int(model.audioLevel * 100)) percent")
            HStack(alignment: .center, spacing: 16) {
                Button { model.toggleRecording() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: recording ? "stop.fill" : "mic.fill").font(.system(size: 14))
                        Text(recording ? "Stop dictation" : "Start dictation")
                    }.frame(minWidth: 135)
                }.buttonStyle(SottoButtonStyle(prominent: true))
                    .disabled(model.phase.isBusy && !recording)
                    .keyboardShortcut(.return, modifiers: [.command])
                if model.phase.isBusy {
                    Button("Cancel") { model.cancelRecording() }.buttonStyle(.plain).font(SottoTheme.font(13))
                } else {
                    Text(model.settings.shortcut.compactTitle).font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
                }
                Spacer()
                if model.phase == .transcribing || model.phase == .inserting || model.phase == .requestingPermission {
                    ProgressView().controlSize(.small)
                }
            }.padding(22)
            Rectangle().fill(SottoTheme.line).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: model.settings.backend == .openRouter ? "cloud" : "lock")
                Text(model.settings.backend == .openRouter
                     ? "Audio is sent to OpenRouter"
                     : (model.checkingModel ? "Checking local engine…" : model.onDeviceStatus.title))
                Spacer()
                if let app = model.targetAppName { Text("For \(app)").lineLimit(1) }
            }.font(SottoTheme.font(11)).foregroundStyle(SottoTheme.muted).padding(.horizontal, 22).padding(.vertical, 13)
        }.background(Color.white).overlay(Rectangle().strokeBorder(SottoTheme.line))
    }

    private var transcriptWorkspace: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Transcript").font(SottoTheme.font(15, weight: .semibold))
                Spacer()
                Text("\(model.wordCount) words").font(SottoTheme.font(12)).foregroundStyle(SottoTheme.muted)
            }
            ZStack(alignment: .topLeading) {
                if model.transcript.isEmpty {
                    Text("Your transcript will appear here. You can edit it before copying or inserting.")
                        .font(SottoTheme.font(15)).foregroundStyle(SottoTheme.muted)
                        .padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $model.transcript).font(SottoTheme.font(16)).lineSpacing(5)
                    .scrollContentBackground(.hidden).frame(minHeight: 105)
                    .disabled(model.phase.isBusy)
                    .accessibilityLabel("Transcript")
            }
            HStack(spacing: 10) {
                Button { model.copyTranscript() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(SottoButtonStyle()).disabled(model.transcript.isEmpty)
                Button { model.insertTranscript() } label: { Label("Insert into app", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(SottoButtonStyle()).disabled(model.transcript.isEmpty || model.phase.isBusy)
                Spacer()
            }
        }.padding(22).background(Color.white).overlay(Rectangle().strokeBorder(SottoTheme.line))
    }
}

struct LiveWaveform: View {
    let level: Double
    let recording: Bool
    @State private var samples = Array(repeating: 0.0, count: 64)
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let width = size.width / CGFloat(samples.count)
                let middle = size.height / 2
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: middle)); baseline.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(baseline, with: .color(SottoTheme.line), lineWidth: 1)
                for index in samples.indices {
                    let height = max(2, samples[index] * (size.height - 8))
                    let rect = CGRect(x: CGFloat(index) * width + width * 0.2, y: middle - height / 2, width: max(2, width * 0.5), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(recording ? SottoTheme.orange : SottoTheme.ink.opacity(0.16)))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: level) { _, value in
            guard recording else { return }
            samples.removeFirst(); samples.append(min(1, max(0, value)))
        }
        .onChange(of: recording) { _, value in if !value { samples = Array(repeating: 0, count: 64) } }
    }
}
