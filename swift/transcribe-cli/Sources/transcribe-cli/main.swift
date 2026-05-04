import Foundation
import Speech
import AVFoundation

func logErr(_ message: String) {
    FileHandle.standardError.write(Data("transcribe-cli: \(message)\n".utf8))
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: transcribe-cli <wav-path>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: arguments[1])

guard FileManager.default.fileExists(atPath: url.path) else {
    logErr("file not found: \(url.path)")
    exit(1)
}

func waitUntil(_ done: () -> Bool) {
    while !done() {
        _ = CFRunLoopRunInMode(.defaultMode, 0.1, true)
    }
}

logErr("requesting speech recognition authorization...")
var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
var authDone = false
SFSpeechRecognizer.requestAuthorization { status in
    authStatus = status
    authDone = true
}
waitUntil { authDone }

guard authStatus == .authorized else {
    logErr("speech recognition not authorized (status: \(authStatus.rawValue))")
    exit(1)
}
logErr("authorized.")

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")) else {
    logErr("ja-JP recognizer unavailable")
    exit(1)
}

guard recognizer.isAvailable else {
    logErr("recognizer not available")
    exit(1)
}

guard recognizer.supportsOnDeviceRecognition else {
    logErr("ja-JP on-device recognition not supported on this system")
    exit(1)
}

func isNoSpeechError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.code == 1110 || nsError.code == 203 || nsError.code == 216
}

func runRecognition(request: SFSpeechRecognitionRequest, beforeWait: () -> Void = {}) -> String {
    var text = ""
    var fatalError: Error?
    var finished = false

    let task = recognizer.recognitionTask(with: request) { result, error in
        if let error = error {
            if !isNoSpeechError(error) {
                fatalError = error
            }
            finished = true
            return
        }
        if let result = result, result.isFinal {
            text = result.bestTranscription.formattedString
            finished = true
        }
    }
    _ = task

    beforeWait()
    waitUntil { finished }

    if let error = fatalError {
        let nsError = error as NSError
        logErr("recognition failed: \(error.localizedDescription)")
        if nsError.localizedDescription.contains("Siri") || nsError.localizedDescription.contains("Dictation") {
            logErr("hint: enable Dictation (System Settings > Keyboard > Dictation, with 日本語 in languages) or Siri (System Settings > Apple Intelligence & Siri)")
        }
        exit(1)
    }
    return text
}

let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: url)
} catch {
    logErr("cannot read audio file: \(error.localizedDescription)")
    exit(1)
}

let sampleRate = audioFile.processingFormat.sampleRate
let totalFrames = audioFile.length
let durationSeconds = Double(totalFrames) / sampleRate
let chunkLengthSeconds: Double = 55.0

logErr(String(format: "duration: %.2fs, sampleRate: %.0fHz", durationSeconds, sampleRate))

if durationSeconds <= 60.0 {
    logErr("single-shot URL recognition")
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    let text = runRecognition(request: request)
    print(text)
} else {
    let chunkFrames = AVAudioFrameCount(chunkLengthSeconds * sampleRate)
    let chunkCount = (Double(totalFrames) / Double(chunkFrames)).rounded(.up)
    logErr("chunked recognition: \(Int(chunkCount)) chunk(s) of ~\(Int(chunkLengthSeconds))s")

    var startFrame: AVAudioFramePosition = 0
    var pieces: [String] = []
    var index = 0

    while startFrame < totalFrames {
        index += 1
        let remaining = totalFrames - startFrame
        let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            logErr("failed to allocate PCM buffer")
            exit(1)
        }
        audioFile.framePosition = startFrame
        do {
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            logErr("read error: \(error.localizedDescription)")
            exit(1)
        }

        logErr("chunk \(index)/\(Int(chunkCount)) recognizing...")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let text = runRecognition(request: request) {
            request.append(buffer)
            request.endAudio()
        }
        if !text.isEmpty {
            pieces.append(text)
        }
        startFrame += AVAudioFramePosition(chunkFrames)
    }

    print(pieces.joined(separator: "\n"))
}
