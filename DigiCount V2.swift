import SwiftUI
import Speech
import AVFoundation

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
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionStart: Date?
    
    private var lastProcessed = ""
    
    func start() {
        if isRecording { stop() }
        count = 0
        lastProcessed = ""
        sessionStart = Date()
        requestPermissionsAndStart()
    }
    
    private func requestPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized else { return }
            
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try? session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            
            self.beginRecognition()
        }
    }
    
    private func beginRecognition() {
        DispatchQueue.main.async { self.isRecording = true }
        
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req
        
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                let digits = transcript.filter { "0123456789".contains($0) }
                
                if digits.count > self.lastProcessed.count {
                    let newDigits = digits.count - self.lastProcessed.count
                    self.lastProcessed = digits
                    DispatchQueue.main.async {
                        self.count += newDigits
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.isRecording = false }
            }
        }
    }
    
    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        
        if let start = sessionStart {
            let log = SessionLog(
                startTime: start,
                endTime: Date(),
                totalDigits: count
            )
            sessions.append(log)
        }
        sessionStart = nil
    }
    
    func resetAll() {
        stop()
        count = 0
        sessions.removeAll()
        isRecording = false
        sessionStart = nil
        lastProcessed = ""
    }
    
    func deleteSession(_ session: SessionLog) {
        sessions.removeAll { $0.id == session.id }
    }
}

// MARK: - View
struct ContentView: View {
    @StateObject private var model = SpeechCounter()
    
    var body: some View {
        HStack {
            // Counter + controls
            VStack(spacing: 40) {
                Text("\(model.count)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.blue)
                
                HStack(spacing: 20) {
                    Button(model.isRecording ? "Stop" : "Start") {
                        model.isRecording ? model.stop() : model.start()
                    }
                    .padding()
                    .background(model.isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)
                    
                    Button("Reset") {
                        model.resetAll()
                    }
                    .padding()
                    .background(Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .font(.title2)
                }
            }
            .frame(maxWidth: .infinity)
            
            // Session log summaries
            VStack(alignment: .leading) {
                Text("Session Log")
                    .font(.headline)
                
                ScrollView {
                    ForEach(model.sessions) { session in
                        HStack {
                            Text(session.summary)
                                .font(.caption)
                            Spacer()
                            Button(action: {
                                model.deleteSession(session)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        Divider()
                    }
                }
            }
            .frame(width: 320)
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)
        }
        .padding()
    }
}
