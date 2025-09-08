import SwiftUI
import Speech
import AVFoundation
import AVFAudio

// MARK: - Model
struct SessionLog: Identifiable, Hashable {
    let id = UUID()
    let startTime: Date
    let endTime: Date
    let totalDigits: Int
    
    var durationString: String {
        let elapsed = endTime.timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return "\(minutes)m \(seconds)s"
    }
    
    var summary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(formatter.string(from: startTime)) → \(totalDigits) digits in \(durationString)"
    }
}

// MARK: - ViewModel
final class SpeechCounter: NSObject, ObservableObject {
    @Published var count = 0
    @Published var isRecording = false
    @Published var sessions: [SessionLog] = []
    @Published var elapsedText: String = "00:00"
    @Published var aggressiveWordMapping = true
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionStart: Date?
    private var timer: Timer?
    private var lastProcessedSegmentIndex: Int = 0
    
    // MARK: - Public controls
    func start() {
        if isRecording { stop() }
        task?.cancel()
        request?.endAudio()
        
        count = 0
        lastProcessedSegmentIndex = 0
        sessionStart = Date()
        updateElapsed(0)
        startTimer()
        requestAllPermissionsAndStart()
    }
    
    func stop() {
        guard isRecording else { return }
        stopTimer()
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
        
        if let start = sessionStart {
            let log = SessionLog(startTime: start, endTime: Date(), totalDigits: count)
            sessions.append(log)
        }
        sessionStart = nil
    }
    
    // ✅ Reset only the counter (not logs)
    func resetCounter() {
        stop()
        count = 0
        elapsedText = "00:00"
        lastProcessedSegmentIndex = 0
    }
    
    // ✅ Optional “Clear All” nuclear option
    func clearAll() {
        stop()
        count = 0
        sessions.removeAll()
        elapsedText = "00:00"
        lastProcessedSegmentIndex = 0
    }
    
    func deleteSession(_ session: SessionLog) {
        sessions.removeAll { $0.id == session.id }
    }
    
    // MARK: - Permissions
    private func requestAllPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized else {
                DispatchQueue.main.async { self.isRecording = false }
                return
            }
            
            AVAudioApplication.requestRecordPermission { granted in
                guard granted else {
                    DispatchQueue.main.async { self.isRecording = false }
                    return
                }
                self.configureSessionAndBeginRecognition()
            }
        }
    }
    
    // MARK: - Audio/Recognition
    private func configureSessionAndBeginRecognition() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        beginRecognition()
    }
    
    private func beginRecognition() {
        DispatchQueue.main.async { self.isRecording = true }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async { self.isRecording = false }
            return
        }
        
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13.0, macOS 10.15, *) {
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
        }
        self.request = req
        
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        lastProcessedSegmentIndex = 0
        
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.handleRecognitionResult(result)
            }
            if error != nil {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.stopTimer()
                }
            }
        }
    }
    
    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let segments = result.bestTranscription.segments
        guard lastProcessedSegmentIndex <= segments.count else { return }
        let newSegments = segments.suffix(from: lastProcessedSegmentIndex)
        
        var newDigitsTotal = 0
        for seg in newSegments {
            let piece = seg.substring.lowercased()
            newDigitsTotal += digitsFrom(piece, aggressive: aggressiveWordMapping)
        }
        
        if newDigitsTotal > 0 {
            DispatchQueue.main.async {
                self.count += newDigitsTotal
            }
        }
        lastProcessedSegmentIndex = segments.count
    }
    
    private func digitsFrom(_ text: String, aggressive: Bool) -> Int {
        var total = text.filter(\.isNumber).count
        
        let tokens = text.split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
        
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
        for t in tokens {
            if let d = map[t] {
                total += d.count
            }
        }
        return total
    }
    
    // MARK: - Timer
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.sessionStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.updateElapsed(elapsed)
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateElapsed(_ seconds: TimeInterval) {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        elapsedText = String(format: "%02d:%02d", m, s)
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject private var model = SpeechCounter()
    
    var body: some View {
        HStack {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text(model.elapsedText)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("\(model.count)")
                        .font(.system(size: 140, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                
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
                }
                
                Toggle(isOn: $model.aggressiveWordMapping) {
                    Text("Aggressive word→digit mapping")
                        .font(.subheadline)
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            
            VStack(alignment: .leading) {
                Text("Session Log")
                    .font(.headline)
                
                ScrollView {
                    ForEach(model.sessions) { session in
                        HStack {
                            Text(session.summary)
                                .font(.caption)
                            Spacer()
                            Button {
                                model.deleteSession(session)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
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
    }
}
