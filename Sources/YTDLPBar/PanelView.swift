import SwiftUI
import YTDLPBarCore

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let text = model.menuBarText
        HStack(spacing: 3) {
            Image(systemName: text.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .id(text)
        .accessibilityLabel(text.isEmpty ? "YTDLP Bar" : "YTDLP Bar \(text)")
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var link = ""
    @State private var filledThisOpen = false
    @FocusState private var linkFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Paste a link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .focused($linkFocused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPressDownload(link: link))
                .help("Download")
                .accessibilityLabel("Download")
            }

            HStack(spacing: 8) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(DownloadMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Mode")

                if model.mode == .video {
                    Picker("Quality", selection: $model.quality) {
                        ForEach(VideoQuality.allCases, id: \.self) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Quality")
                } else {
                    Picker("Format", selection: $model.audioFormat) {
                        ForEach(AudioFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Audio format")
                    .help(model.audioFormat == .keep ? "Does not re-encode" : "Convert the audio")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    model.openDestination()
                } label: {
                    Label(model.destinationDisplay, systemImage: "folder")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                Button("Change") {
                    model.pickDestination()
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            Text("A playlist link downloads one video.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let banner = model.banner, !banner.isEmpty {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.showInstall {
                Button("Install with Homebrew") {
                    model.installTools()
                }
                .controlSize(.small)
                .disabled(model.queue.runningJob() != nil)
            }

            if !model.queue.activeJobs.isEmpty || !model.queue.finishedJobs.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.queue.activeJobs) { job in
                            JobRow(job: job, model: model)
                        }
                        ForEach(model.queue.finishedJobs) { job in
                            JobRow(job: job, model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.queue.hasFinished {
                    Button("Clear") { model.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if model.showUpdate {
                    Button("Update") { model.updateYTDLP() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.updateDisabled)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 400)
        .onAppear(perform: becomeOpen)
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive {
                filledThisOpen = false
            } else {
                becomeOpen()
            }
        }
        .onChange(of: link) { _, _ in
            model.banner = nil
        }
    }

    private func becomeOpen() {
        guard !filledThisOpen else { return }
        filledThisOpen = true
        if link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let pasted = model.clipboardLink() {
            link = pasted
        }
        linkFocused = true
    }

    private func submit() {
        if model.enqueue(link: link) {
            link = ""
        }
    }
}

private struct JobRow: View {
    let job: DownloadJob
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if job.status == .running {
                    Button("Cancel") { model.cancel(id: job.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if job.status == .queued {
                    Button("Remove") { model.removeQueued(id: job.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if job.status == .running, let percent = job.percent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .transaction { $0.disablesAnimations = true }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if job.status == .done {
                model.reveal(job: job)
            }
        }
        .help(job.status == .done ? "Show in Finder" : "")
        .accessibilityAddTraits(job.status == .done ? .isButton : [])
    }

    private var detail: String {
        switch job.status {
        case .queued:
            "Waiting · \(job.choiceLabel)"
        case .running:
            runningDetail
        case .done:
            "Done · \(job.choiceLabel)"
        case .cancelled:
            "Cancelled"
        case .failed:
            job.error.isEmpty ? "Failed" : job.error
        }
    }

    private var runningDetail: String {
        var parts: [String] = []
        if let percent = job.percent {
            parts.append("\(Int(percent.rounded()))%")
        }
        let speed = job.speed.trimmingCharacters(in: .whitespaces)
        if !speed.isEmpty, !Self.isUnknown(speed) {
            parts.append(speed)
        }
        let eta = job.eta.trimmingCharacters(in: .whitespaces)
        if !eta.isEmpty, !Self.isUnknown(eta) {
            parts.append("ETA \(eta)")
        }
        if parts.isEmpty { return "Starting…" }
        return parts.joined(separator: " · ")
    }

    private static func isUnknown(_ value: String) -> Bool {
        let text = value.lowercased()
        return text == "na" || text == "n/a" || text.hasPrefix("unknown")
    }
}
