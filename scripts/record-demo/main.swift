import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// usage: record-demo <app-executable> <locale en|ko> <output.mov>
// Creates a 1280x800 (2x) virtual display, starts the app's scripted demo on it, records that display at 60 fps
// with ScreenCaptureKit until the app quits, then removes the display. Nothing is drawn on the user's own screens.
let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: record-demo <app-executable> <en|ko> <output.mov>\n".utf8))
    exit(64)
}
let appPath = arguments[1], locale = arguments[2], output = URL(fileURLWithPath: arguments[3])
let pointWidth: UInt32 = 1280, pointHeight: UInt32 = 800

let descriptor = CGVirtualDisplayDescriptor()
descriptor.queue = DispatchQueue.main
descriptor.name = "Speech2Text Demo"
descriptor.maxPixelsWide = pointWidth * 2
descriptor.maxPixelsHigh = pointHeight * 2
descriptor.sizeInMillimeters = CGSize(width: 340, height: 212)
descriptor.productID = 0x4D47
descriptor.vendorID = 0x4D4C
descriptor.serialNum = 1
descriptor.terminationHandler = { _, _ in }
guard let display = CGVirtualDisplay(descriptor: descriptor) else {
    FileHandle.standardError.write(Data("virtual display could not be created\n".utf8))
    exit(70)
}
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 1
settings.modes = [CGVirtualDisplayMode(width: pointWidth, height: pointHeight, refreshRate: 60)]
guard display.apply(settings) else {
    FileHandle.standardError.write(Data("virtual display settings refused\n".utf8))
    exit(70)
}
let displayID = display.displayID
print("VIRTUAL_DISPLAY \(displayID)")

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var started = false
    var frames = 0
    let queue = DispatchQueue(label: "recorder")

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            started = true
        }
        if input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) { frames += 1 }
    }
}

Task {
    do {
        // The new display needs a moment before ScreenCaptureKit lists it.
        var target: SCDisplay?
        for _ in 0..<40 where target == nil {
            try await Task.sleep(for: .milliseconds(250))
            target = try await SCShareableContent.current.displays.first { $0.displayID == displayID }
        }
        guard let target else { throw NSError(domain: "record-demo", code: 1, userInfo: [NSLocalizedDescriptionKey: "display not shareable"]) }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pointWidth * 2)
        configuration.height = Int(pointHeight * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 8
        let recorder = try Recorder(url: output, width: configuration.width, height: configuration.height)
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        print("RECORDING")

        let app = Process()
        app.executableURL = URL(fileURLWithPath: appPath)
        // Launch-argument defaults keep this Mac's stored settings out of the picture; the demo writes none back.
        app.arguments = ["--demo", locale, "--demo-screen", String(displayID),
                         "-AppleLanguages", "(\(locale))", "-inputDeviceUID", "demo-mic", "-shortcuts", "x",
                         "-wakeListeningEnabled", "NO", "-commandJudge", "jev", "-punctuationStyle", "asIs",
                         "-overlayAutoCloseSeconds", "30", "-marksUncertainWords", "NO"]
        try app.run()
        while app.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        try await stream.stopCapture()
        recorder.queue.sync { recorder.input.markAsFinished() }
        await recorder.writer.finishWriting()
        print("FRAMES \(recorder.frames) STATUS \(recorder.writer.status.rawValue) APP_EXIT \(app.terminationStatus)")
        exit(recorder.writer.status == .completed ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("record-demo failed: \(error)\n".utf8))
        exit(1)
    }
}
withExtendedLifetime(display) { RunLoop.main.run() }
