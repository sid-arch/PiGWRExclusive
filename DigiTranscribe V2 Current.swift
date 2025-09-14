import SwiftUI
import Speech
import AVFoundation
import AVFAudio

// MARK: - Model
struct SessionLog: Identifiable, Hashable, Codable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let totalDigits: Int
    let transcript: String

    init(id: UUID = UUID(), startTime: Date, endTime: Date, totalDigits: Int, transcript: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.totalDigits = totalDigits
        self.transcript = transcript
    }

    var durationString: String {
        let elapsed = endTime.timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return "\(minutes)m \(seconds)s"
    }

    var summary: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(f.string(from: startTime)) → \(totalDigits) digits in \(durationString)"
    }
}

// MARK: - Persistence Helper
class LogStorage {
    private let key = "SavedLogs"

    func save(_ logs: [SessionLog]) {
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func load() -> [SessionLog] {
        if let data = UserDefaults.standard.data(forKey: key),
           let logs = try? JSONDecoder().decode([SessionLog].self, from: data) {
            return logs
        }
        return []
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - ViewModel
final class SpeechTranscriber: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var count: Int = 0
    @Published var isRecording: Bool = false
    @Published var sessions: [SessionLog] = [] {
        didSet { storage.save(sessions) }
    }
    @Published var elapsedText: String = "00:00"
    @Published var aggressiveWordMapping: Bool = true

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var sessionStart: Date?
    private var lastDigitWallClock: Date?
    private var processedIndexThisCycle: Int = 0
    private let storage = LogStorage()

    override init() {
        super.init()
        sessions = storage.load()
    }

    // MARK: Controls
    func start() {
        if isRecording { stop() }
        transcript = ""
        count = 0
        elapsedText = "00:00"
        lastDigitWallClock = nil
        processedIndexThisCycle = 0
        sessionStart = Date()
        startTimer()
        setupAudioEngineIfNeeded()
        requestAllPermissionsAndStart()
    }

    func stop() {
        guard isRecording else { return }
        stopTimer()
        task?.cancel()
        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        if let start = sessionStart {
            let log = SessionLog(startTime: start,
                                 endTime: Date(),
                                 totalDigits: count,
                                 transcript: transcript)
            sessions.append(log)
        }
        sessionStart = nil
    }

    func resetCounter() {
        transcript = ""
        count = 0
        elapsedText = "00:00"
        lastDigitWallClock = nil
        processedIndexThisCycle = 0
    }

    func clearAll() {
        stop()
        transcript = ""
        count = 0
        sessions.removeAll()
        elapsedText = "00:00"
        lastDigitWallClock = nil
        processedIndexThisCycle = 0
        storage.clear()
    }

    func deleteSession(_ session: SessionLog) {
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: Permissions
    private func requestAllPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                DispatchQueue.main.async { self.isRecording = false }
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                guard granted else {
                    DispatchQueue.main.async { self.isRecording = false }
                    return
                }
                self.configureSessionAndBeginRecognitionLoop()
            }
        }
    }

    private func configureSessionAndBeginRecognitionLoop() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        DispatchQueue.main.async { self.isRecording = true }
        startRecognitionCycle()
    }

    // MARK: Audio Engine
    private func setupAudioEngineIfNeeded() {
        if audioEngine.isRunning { return }
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try? audioEngine.start()
    }

    // MARK: Recognition Loop
    private func startRecognitionCycle() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async { self.isRecording = false }
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req
        processedIndexThisCycle = 0

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handleRecognitionResult(result)
                if result.isFinal && self.isRecording {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        self.startRecognitionCycle()
                    }
                }
            }
            if error != nil, self.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.startRecognitionCycle()
                }
            }
        }
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let segments = result.bestTranscription.segments
        guard processedIndexThisCycle <= segments.count else { return }
        let newSegments = segments.suffix(from: processedIndexThisCycle)

        var appendString = ""
        var newDigitsCount = 0

        for seg in newSegments {
            let piece = seg.substring.lowercased()
            let digits = digitStringsFrom(piece, aggressive: aggressiveWordMapping)
            guard !digits.isEmpty else { continue }

            let now = Date()
            if let last = lastDigitWallClock, now.timeIntervalSince(last) > 2.0 {
                appendString += " – "
            }
            appendString += digits.joined()
            newDigitsCount += digits.count
            lastDigitWallClock = now
        }

        if newDigitsCount > 0 {
            DispatchQueue.main.async {
                self.transcript += appendString
                self.count += newDigitsCount
            }
        }

        processedIndexThisCycle = segments.count
    }

    private func digitStringsFrom(_ text: String, aggressive: Bool) -> [String] {
        var out: [String] = []
        for ch in text where ch.isNumber { out.append(String(ch)) }
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }

        let base: [String: String] = [
            "zero":"0","oh":"0","o":"0",
            "one":"1","won":"1",
            "two":"2","too":"2","to":"2",
            "three":"3","tree":"3",
            "four":"4","for":"4","fore":"4",
            "five":"5","six":"6",
            "seven":"7",
            "eight":"8","ate":"8",
            "nine":"9"
        ]
        let strict: [String: String] = [
            "zero":"0","oh":"0","one":"1","two":"2","three":"3",
            "four":"4","five":"5","six":"6","seven":"7",
            "eight":"8","nine":"9"
        ]

        let map = aggressive ? base : strict
        for t in tokens { if let d = map[t] { out.append(d) } }
        return out
    }

    // MARK: Timer
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let start = self.sessionStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            let m = Int(elapsed) / 60
            let s = Int(elapsed) % 60
            DispatchQueue.main.async {
                self.elapsedText = String(format: "%02d:%02d", m, s)
            }
        }
        if let timer { RunLoop.current.add(timer, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject private var model = SpeechTranscriber()
    @State private var selectedLog: SessionLog? = nil

    var body: some View {
        HStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(model.elapsedText)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(model.count)")
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }

                // Live transcript
                ScrollView {
                    Text(model.transcript)
                        .font(.body.monospaced())
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)

                HStack(spacing: 16) {
                    Button(model.isRecording ? "Stop" : "Start") {
                        model.isRecording ? model.stop() : model.start()
                    }
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(model.isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)

                    Button("Reset Counter") {
                        model.resetCounter()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)

                    Button("Clear Logs") {
                        model.clearAll()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.black)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)

                    Button("Copy") {
                        UIPasteboard.general.string = model.transcript
                    }
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)
                }

                Toggle(isOn: $model.aggressiveWordMapping) {
                    Text("Aggressive word→digit mapping")
                        .font(.subheadline)
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
            }
            .frame(maxWidth: .infinity)

            // Session log
            VStack(alignment: .leading) {
                Text("Session Log")
                    .font(.headline)

                ScrollView {
                    ForEach(model.sessions) { session in
                        Button {
                            selectedLog = session
                        } label: {
                            HStack {
                                Text(session.summary).font(.caption)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                            }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(width: 360)
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
        }
        .padding()
        .sheet(item: $selectedLog) { log in
            VStack(spacing: 16) {
                Text("Session Details")
                    .font(.headline)
                Text(log.summary)
                    .font(.subheadline)
                ScrollView {
                    Text(log.transcript)
                        .font(.body.monospaced())
                        .padding()
                }
                Button("Copy Transcript") {
                    UIPasteboard.general.string = log.transcript
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                Spacer()
            }
            .padding()
        }
    }
}
