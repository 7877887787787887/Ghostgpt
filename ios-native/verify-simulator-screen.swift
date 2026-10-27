import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: verify-simulator-screen.swift <screenshot.png>")
}
let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Could not read simulator screenshot")
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(cgImage: image).perform([request])
let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
let normalizedText = visibleText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
print(visibleText)
guard normalizedText.localizedCaseInsensitiveContains("GhostGPT") else {
    fatalError("Native GhostGPT screen was not visible at launch")
}
guard normalizedText.localizedCaseInsensitiveContains("private AI workspace") else {
    fatalError("Expected native SwiftUI chat home screen was not visible")
}
guard !normalizedText.localizedCaseInsensitiveContains("Open GhostGPT") else {
    fatalError("Legacy web launch screen is still visible")
}
