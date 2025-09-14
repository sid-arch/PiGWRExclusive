import SwiftUI

struct VerificationResult {
    var totalExpected: Int
    var correct: Int
    var wrong: Int
    var missing: Int
    var hyphens: Int
}

struct ContentView: View {
    @State private var expectedDigits: String = ""
    @State private var pastedText: String = ""
    @State private var result: VerificationResult? = nil

    // 🔥 Placeholder for Pi (replace with full 1000+ digits)
    private let piDigits = "3141592653589793238462643383279502884197169399375105820974944592..."

    var body: some View {
        VStack(spacing: 20) {
            Text("DigiVerifier")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Step 1 – expected digits (box style)
            VStack(alignment: .leading) {
                Text("How many digits?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $expectedDigits)
                    .frame(height: 60)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, lineWidth: 1))
            }
            .padding(.horizontal)

            // Step 2 – transcript box
            VStack(alignment: .leading) {
                Text("Paste transcript")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextEditor(text: $pastedText)
                    .frame(height: 200)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray, lineWidth: 1))
                    .overlay(Text(pastedText.isEmpty ? "Paste transcript here..." : "")
                                .foregroundColor(.gray)
                                .padding(8),
                             alignment: .topLeading)
            }
            .padding(.horizontal)

            // Step 3 – check button
            Button("Check Digits") {
                runCheck()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .font(.title2)
            .padding(.horizontal)

            // Step 4 – results box
            if let res = result {
                VStack(spacing: 10) {
                    Text("Results").font(.headline)
                    Text("Expected: \(res.totalExpected)")
                    Text("✅ Correct: \(res.correct)")
                    Text("❌ Wrong: \(res.wrong)")
                    Text("🕳 Missing: \(res.missing)")
                    Text("– Hyphens: \(res.hyphens)")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
    }

    private func runCheck() {
        guard let expected = Int(expectedDigits), expected > 0 else { return }

        // Clean pasted text: keep only digits + hyphens
        let cleaned = pastedText.filter { "0123456789–-".contains($0) }
        let pastedDigits = cleaned.map { String($0) }

        let piArray = Array(piDigits.prefix(expected)).map { String($0) }

        var correct = 0, wrong = 0, missing = 0, hyphens = 0

        for i in 0..<expected {
            if i < pastedDigits.count {
                let val = pastedDigits[i]
                if val == "–" || val == "-" {
                    hyphens += 1
                } else if val == piArray[i] {
                    correct += 1
                } else {
                    wrong += 1
                }
            } else {
                missing += 1
            }
        }

        result = VerificationResult(
            totalExpected: expected,
            correct: correct,
            wrong: wrong,
            missing: missing,
            hyphens: hyphens
        )
    }
}
