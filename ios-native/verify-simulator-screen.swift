import Foundation
import ImageIO
import Vision

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("GhostGPT screen verification failed: \(message)\n", stderr)
    exit(code)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: verify-simulator-screen.swift <screenshot.png>")
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard FileManager.default.fileExists(atPath: imageURL.path) else {
    fail("Screenshot does not exist: \(imageURL.path)")
}
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
    fail("ImageIO could not open screenshot: \(imageURL.path)")
}
guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("ImageIO could not decode screenshot: \(imageURL.path)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
request.minimumTextHeight = 0.005

do {
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    try handler.perform([request])
} catch {
    let nsError = error as NSError
    fail("Vision text recognition threw \(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)")
}

let visibleText = (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
print("Recognized simulator screen text:\n\(visibleText)")

guard visibleText.localizedCaseInsensitiveContains("GhostGPT") else {
    fail("Native GhostGPT screen text was not found in screenshot")
}
guard !visibleText.localizedCaseInsensitiveContains("Open GhostGPT") else {
    fail("Legacy web launch screen text is still visible")
}

print("GhostGPT simulator screen text verification passed.")
