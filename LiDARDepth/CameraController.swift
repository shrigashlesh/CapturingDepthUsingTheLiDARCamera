import UIKit
import AVFoundation
import CoreImage

protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject {
    
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    
    private let preferredWidthResolution = 1920
    private let videoQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoQueue", qos: .userInteractive)
    
    private(set) var captureSession: AVCaptureSession!
    
    private var depthDataOutput: AVCaptureDepthDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    private var outputVideoSync: AVCaptureDataOutputSynchronizer!
    
    private var textureCache: CVMetalTextureCache!
    
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor?
    private var assetWriterMetadataInput: AVAssetWriterInput?
    private var assetWriterMetadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    private var lastTimestamp: CMTime = .zero

    weak var delegate: CaptureDataReceiver?
    
    var isFilteringEnabled = true {
        didSet {
            depthDataOutput.isFilteringEnabled = isFilteringEnabled
        }
    }
    
    var isRecording = false {
        didSet {
            if isRecording {
                startRecording()
            } else {
                finishRecording()
            }
        }
    }
    
    override init() {
        super.init()
        
        // Create a texture cache to hold sample buffer textures.
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  MetalEnvironment.shared.metalDevice,
                                  nil,
                                  &textureCache)
        
        do {
            try setupSession()
        } catch {
            fatalError("Unable to configure the capture session.")
        }
    }
    
    private func setupSession() throws {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .inputPriority

        // Configure the capture session.
        captureSession.beginConfiguration()
        
        try setupCaptureInput()
        setupCaptureOutputs()
        
        // Finalize the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    private func setupCaptureInput() throws {
        // Look up the LiDAR camera.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw ConfigurationError.lidarDeviceUnavailable
        }
        
        // Find a match that outputs video data in the format the app's custom Metal views require.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == preferredWidthResolution &&
            format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Find a match that outputs depth data in the format the app's custom Metal views require.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Begin the device configuration.
        try device.lockForConfiguration()

        // Configure the device and depth formats.
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat

        // Finish the device configuration.
        device.unlockForConfiguration()
        
        print("Selected video format: \(device.activeFormat)")
        print("Selected depth format: \(String(describing: device.activeDepthDataFormat))")
        
        // Add a device input to the capture session.
        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(deviceInput)
    }
    
    private func setupCaptureOutputs() {
        // Create an object to output video sample buffers.
        videoDataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(videoDataOutput)
        
        // Create an object to output depth data.
        depthDataOutput = AVCaptureDepthDataOutput()
        depthDataOutput.isFilteringEnabled = isFilteringEnabled
        captureSession.addOutput(depthDataOutput)

        // Create an object to synchronize the delivery of depth and video data.
        outputVideoSync = AVCaptureDataOutputSynchronizer(dataOutputs: [depthDataOutput, videoDataOutput])
        outputVideoSync.setDelegate(self, queue: videoQueue)

        // Enable camera intrinsics matrix delivery.
        guard let outputConnection = videoDataOutput.connection(with: .video) else { return }
        if outputConnection.isCameraIntrinsicMatrixDeliverySupported {
            outputConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }
    
    func startStream() {
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }
    
    func stopStream() {
        captureSession.stopRunning()
    }
   
    private func startRecording() {
        let fileName = "\(UUID().uuidString).mov"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            
            // Set up video settings
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: preferredWidthResolution,
                AVVideoHeightKey: preferredWidthResolution
            ]
            
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
            )
           
            
            let metadataItem = AVMutableMetadataItem()
            metadataItem.identifier = AVMetadataIdentifier("common/fishtechy_lidar")
            metadataItem.dataType = kCMMetadataBaseDataType_UTF8 as String?

            let metadata = [metadataItem]
            let metadataGroup = AVTimedMetadataGroup(items: metadata, timeRange: CMTimeRange(start: .zero, end: CMTime.positiveInfinity))
            let formatDesc = metadataGroup.copyFormatDescription()
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDesc)
            metadataInput.expectsMediaDataInRealTime = false
            assetWriterMetadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

            // Add inputs to asset writer
            if let assetWriter = assetWriter,
               let assetWriterInput = assetWriterInput,
               let _ = assetWriterPixelBufferInput , let assetWriterMetadataAdaptor = assetWriterMetadataAdaptor{
                assetWriter.add(assetWriterInput)
                assetWriter.add(metadataInput)
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: .zero)
            }
            
            // Reset the last timestamp to zero for a new recording
            lastTimestamp = .zero
        } catch {
            print("Error starting video recording: \(error)")
        }
    }


    private func appendPixelBufferAndDepth(pixelBuffer: CVPixelBuffer, depthData: AVDepthData, timestamp: CMTime) {
        guard let assetWriterPixelBufferInput = assetWriterPixelBufferInput else { return }
        
        // Increment timestamp by the duration of a frame (e.g., 1/30 second)
        let frameDuration = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        lastTimestamp = CMTimeAdd(lastTimestamp, frameDuration)
        
        if assetWriterPixelBufferInput.assetWriterInput.isReadyForMoreMediaData {
            assetWriterPixelBufferInput.append(pixelBuffer, withPresentationTime: lastTimestamp)
            
            // Append metadata
            appendMetadataForFrame(depthData: depthData, timestamp: lastTimestamp)
        }
    }

    private func appendMetadataForFrame(depthData: AVDepthData, timestamp: CMTime) {
        guard let assetWriterMetadataAdaptor = assetWriterMetadataAdaptor else {
            return
        }
        let metadataItem = AVMutableMetadataItem()
        metadataItem.key = "fishtechy_lidar" as NSString // Custom metadata key
        metadataItem.keySpace = AVMetadataKeySpace.common
        metadataItem.value = depthDataToString(depthData) as NSString // Convert depth data to string
        metadataItem.time = timestamp
        metadataItem.dataType = kCMMetadataBaseDataType_UTF8 as String?

        let metadata = [metadataItem]
        let metadataGroup = AVTimedMetadataGroup(items: metadata, timeRange: CMTimeRange(start: timestamp, duration: CMTime.zero))
        assetWriterMetadataAdaptor.append(metadataGroup)
    }



    private func finishRecording() {
        assetWriter?.finishWriting { [weak self] in
            guard let self = self else { return }
            
            if let videoURL = self.assetWriter?.outputURL {
                DispatchQueue.main.async {
                    // Ensure the video file is valid before saving
                    print("Saving video to gallery at path: \(videoURL.path)")
                    UISaveVideoAtPathToSavedPhotosAlbum(videoURL.path, self, #selector(self.video(_:didFinishSavingWithError:contextInfo:)), nil)
                }
            }
        }
    }

    @objc private func video(_ videoPath: String, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer) {
        if let error = error {
            print("Error saving video: \(error.localizedDescription)")
        } else {
            print("Video saved successfully to gallery.")
        }
    }
    
    private func depthDataToString(_ depthData: AVDepthData) -> String {
        // Convert depth data to a string or data for metadata.
        // Implement this based on your specific needs.
        return "Depth data as string or other format"
    }
}

// MARK: Output Synchronizer Delegate
extension CameraController: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Retrieve the synchronized depth and sample buffer container objects.
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        
        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            return
        }
        
        let depthData = syncedDepthData.depthData
        let sampleBuffer = syncedVideoData.sampleBuffer
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let cameraCalibrationData = depthData.cameraCalibrationData else {
            return
        }
        
        // Package the captured data.
        let data = CameraCapturedData(depth: syncedDepthData.depthData.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: videoPixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: videoPixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewData(capturedData: data)
        
        guard isRecording else { return }
        appendPixelBufferAndDepth(pixelBuffer: videoPixelBuffer, depthData: depthData, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
