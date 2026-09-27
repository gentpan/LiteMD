import AppKit
import LiteMDConversion
import Speech

/// 录音转文字：使用系统语音识别，要求在本机完成识别（不上传音频）。
///
/// 模型由系统管理，不随应用打包；只在转写期间占用 CPU / 神经网络引擎。
enum AudioTranscriber {
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "mp4", "mov"]

    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case onDeviceUnavailable(String)
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                String(localized: "LiteMD is not allowed to use speech recognition. You can allow it in System Settings → Privacy & Security → Speech Recognition.")
            case .onDeviceUnavailable(let language):
                String(localized: "On-device speech recognition for \(language) is not available. Download the language in System Settings → Keyboard → Dictation.")
            case .noSpeech:
                String(localized: "No speech was recognized in this recording.")
            }
        }
    }

    /// 界面语言对应的识别语言。
    static var preferredLocale: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return language.hasPrefix("zh") ? Locale(identifier: "zh-CN") : Locale(identifier: "en-US")
    }

    static func transcribe(_ url: URL, locale: Locale = preferredLocale) async throws -> ConversionResult {
        guard await requestAuthorization() == .authorized else { throw TranscriptionError.notAuthorized }
        let languageName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable(languageName)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let segments: [(text: String, start: TimeInterval, end: TimeInterval)] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                let segments = result.transcriptions.first.map { transcription in
                    transcription.segments.map { ($0.substring, $0.timestamp, $0.timestamp + $0.duration) }
                } ?? []
                continuation.resume(returning: segments)
            }
        }

        let markdown = Self.markdown(title: url.deletingPathExtension().lastPathComponent, segments: segments, locale: locale)
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
        return ConversionResult(markdown: markdown, title: url.deletingPathExtension().lastPathComponent)
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// 停顿超过两秒另起一段，每段前标注时间。中文不在词之间加空格。
    static func markdown(title: String, segments: [(text: String, start: TimeInterval, end: TimeInterval)], locale: Locale) -> String {
        let joinsWithSpace = !(locale.language.languageCode?.identifier ?? "").hasPrefix("zh")
        var paragraphs: [(start: TimeInterval, text: String)] = []
        var previousEnd: TimeInterval = -.infinity
        for segment in segments {
            let word = segment.text.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            if paragraphs.isEmpty || segment.start - previousEnd > 2 {
                paragraphs.append((segment.start, word))
            } else {
                let isPunctuation = word.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                paragraphs[paragraphs.count - 1].text += (joinsWithSpace && !isPunctuation ? " " : "") + word
            }
            previousEnd = segment.end
        }
        var output = "# \(title)\n"
        for paragraph in paragraphs {
            output += "\n`\(timestamp(paragraph.start))` \(paragraph.text)\n"
        }
        return output
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }
}

@MainActor
extension AppModel {
    /// 系统听写：让编辑器获得焦点后开始听写（与“编辑 › 开始听写”相同）。
    func startDictation() {
        guard let editor = activeEditor else { return }
        editor.focus()
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }

    func transcribeAudioFromPanel() {
        guard let url = SystemIntegration.chooseRecording() else { return }
        Task { await importFile(url) }
    }
}
