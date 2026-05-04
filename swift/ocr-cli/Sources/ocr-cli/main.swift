import Foundation
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ocr-cli <image-path>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: arguments[1])

guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("ocr-cli: file not found: \(url.path)\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["ja-JP", "en-US"]
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(url: url, options: [:])

do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("ocr-cli: OCR failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

guard let observations = request.results else {
    exit(0)
}

for observation in observations {
    if let candidate = observation.topCandidates(1).first {
        print(candidate.string)
    }
}
