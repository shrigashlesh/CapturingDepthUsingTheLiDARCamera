import UIKit
import AVFoundation
import CoreImage
import Photos

// Protocol to notify when new camera data is captured.
protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject, AVPlayerItemMetadataOutputPushDelegate {
    
    // Custom error types for configuration failures.
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    
    // Desired video resolution for capture.
    private let preferredWidthResolution = 1920
    private let preferredHeightResolution = 1440
    
    // Queue to handle video processing with high priority.
    private let videoQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoQueue", qos: .userInteractive)
    
    // Capture session object to manage input/output.
    private(set) var captureSession: AVCaptureSession!
    
    // Outputs for depth data and video data.
    private var depthDataOutput: AVCaptureDepthDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    
    // Synchronizer to align depth and video outputs.
    private var outputVideoSync: AVCaptureDataOutputSynchronizer!
    
    // Metal texture cache for managing video frames.
    private var textureCache: CVMetalTextureCache!
    
    // AVAssetWriter components for video recording.
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var assetWriterPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor?
    private var assetWriterMetadataInput: AVAssetWriterInput?
    private var metadataAdapter: AVAssetWriterInputMetadataAdaptor?
    
    // Timestamp to manage frame timing during video recording.
    private var lastTimestamp: CMTime = .zero
    
    // Delegate to notify when new captured data is available.
    weak var delegate: CaptureDataReceiver?
    
    // Property to enable or disable depth filtering.
    var isFilteringEnabled = true {
        didSet {
            depthDataOutput.isFilteringEnabled = isFilteringEnabled
        }
    }
    
    // Property to control video recording state.
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
        
        // Create a Metal texture cache for video processing.
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  MetalEnvironment.shared.metalDevice,
                                  nil,
                                  &textureCache)
        
        // Set up the camera session, catching errors if setup fails.
        do {
            try setupSession()
        } catch {
            fatalError("Unable to configure the capture session.")
        }
    }
    
    // Set up the capture session with camera inputs and outputs.
    private func setupSession() throws {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .inputPriority
        
        // Begin configuration before adding inputs/outputs.
        captureSession.beginConfiguration()
        
        try setupCaptureInput()  // Configure the camera input.
        setupCaptureOutputs()    // Configure video and depth outputs.
        
        // Finalize and commit the session configuration.
        captureSession.commitConfiguration()
    }
    
    // Set up the camera input (LiDAR) for depth data and video.
    private func setupCaptureInput() throws {
        // Ensure the LiDAR camera is available.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw ConfigurationError.lidarDeviceUnavailable
        }
        
        // Find a suitable format for video that meets the required resolution.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == preferredWidthResolution &&
            format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Find a suitable depth data format.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Lock the device for configuration and set the formats.
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        device.unlockForConfiguration()
        
        // Add the camera input to the capture session.
        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(deviceInput)
    }
    
    // Set up the outputs for video and depth data.
    private func setupCaptureOutputs() {
        // Configure the video data output for the session.
        videoDataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(videoDataOutput)
        
        // Configure the depth data output for the session.
        depthDataOutput = AVCaptureDepthDataOutput()
        depthDataOutput.isFilteringEnabled = isFilteringEnabled
        captureSession.addOutput(depthDataOutput)
        
        // Synchronize depth and video outputs.
        outputVideoSync = AVCaptureDataOutputSynchronizer(dataOutputs: [depthDataOutput, videoDataOutput])
        outputVideoSync.setDelegate(self, queue: videoQueue)
        
        // Enable the camera's intrinsic matrix delivery for advanced processing.
        guard let outputConnection = videoDataOutput.connection(with: .video) else { return }
        if outputConnection.isCameraIntrinsicMatrixDeliverySupported {
            outputConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }
    
    // Start the camera stream.
    func startStream() {
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
        }
    }
    
    // Stop the camera stream.
    func stopStream() {
        captureSession.stopRunning()
    }
    
    // Start recording video, setting up the asset writer.
    private func startRecording() {
        let fileName = "\(UUID().uuidString).mov"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        do {
            // Set up the asset writer for video recording.
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            
            // Configure video settings.
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: preferredWidthResolution,
                AVVideoHeightKey: preferredHeightResolution
            ]
            
            // Add inputs for video frames and metadata.
            assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            assetWriterInput?.expectsMediaDataInRealTime = true
            
            assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: assetWriterInput!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                ]
            )
            
            let metaSpec: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/io.futrix.flytechy.3D",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.UTF-8",
            ]
            
            var metadataFormatDescription: CMFormatDescription?
            let metadataSpecifications = [metaSpec] as CFArray
            
            // Create metadata format description.
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: metadataSpecifications,
                formatDescriptionOut: &metadataFormatDescription
            )
            
            assetWriterMetadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataFormatDescription)
            assetWriterMetadataInput?.expectsMediaDataInRealTime = true
            metadataAdapter = AVAssetWriterInputMetadataAdaptor(assetWriterInput: assetWriterMetadataInput!)
            
            // Start writing session for video and metadata.
            if let assetWriter = assetWriter,
               let assetWriterInput = assetWriterInput,
               let assetWriterMetadataInput = assetWriterMetadataInput

            {
                assetWriter.add(assetWriterInput)
                assetWriter.add(assetWriterMetadataInput)
                assetWriter.startWriting()
                assetWriter.startSession(atSourceTime: .zero)
            }
        } catch {
            print("Error starting video recording: \(error)")
        }
    }
    
    // Append video frames and depth data during recording.
    private func appendPixelBufferAndDepth(pixelBuffer: CVPixelBuffer, depthData: AVDepthData, timestamp: CMTime) {
        guard let assetWriterPixelBufferInput = assetWriterPixelBufferInput else { return }
        
        // Set frame duration for 30fps video.
        let frameDuration = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        lastTimestamp = CMTimeAdd(lastTimestamp, frameDuration)
        
        // Append pixel buffer if the writer is ready.
        if assetWriterPixelBufferInput.assetWriterInput.isReadyForMoreMediaData {
            assetWriterPixelBufferInput.append(pixelBuffer, withPresentationTime: lastTimestamp)
        }
        
        // Write depth data and camera intrinsic/extrinsic information.
        writeDepthAndCameraData(depthData: depthData, frameDuration: frameDuration)
    }
    
    // Write depth data and camera information as metadata.
    private func writeDepthAndCameraData(depthData: AVDepthData, frameDuration: CMTime) {
        // Flatten the depth array
        let depthValues = flattenDepthArray(depthData: depthData)
        
        // Extract camera intrinsic matrix and view transform
        guard let cameraCalibrationData = depthData.cameraCalibrationData else {
            print("No camera calibration data available")
            return
        }
        
        // Camera intrinsic matrix (3x3 matrix in double format)
        let cameraIntrinsic = cameraCalibrationData.intrinsicMatrix

        // Convert the camera intrinsic matrix to an array
        let cameraIntrinsicArray = [
            cameraIntrinsic.columns.0.x, cameraIntrinsic.columns.0.y, cameraIntrinsic.columns.0.z,
            cameraIntrinsic.columns.1.x, cameraIntrinsic.columns.1.y, cameraIntrinsic.columns.1.z,
            cameraIntrinsic.columns.2.x, cameraIntrinsic.columns.2.y, cameraIntrinsic.columns.2.z
        ]
        
        // View transform (rotation and translation matrix - 4x3 matrix)
        let viewTransform = cameraCalibrationData.extrinsicMatrix
        let viewTransformArray = [
            viewTransform.columns.0.x, viewTransform.columns.0.y, viewTransform.columns.0.z,
            viewTransform.columns.1.x, viewTransform.columns.1.y, viewTransform.columns.1.z,
            viewTransform.columns.2.x, viewTransform.columns.2.y, viewTransform.columns.2.z,
            viewTransform.columns.3.x, viewTransform.columns.3.y, viewTransform.columns.3.z
        ]
        
        // Create a dictionary for JSON
        let depthDataDict: [String: Any] = [
            "depth": depthValues,
            "cameraIntrinsic": cameraIntrinsicArray,
            "viewTransform": viewTransformArray
        ]
        
        // Convert the dictionary to JSON data
        guard let jsonData = try? JSONSerialization.data(withJSONObject: depthDataDict, options: .prettyPrinted),
              let encodedDepthValues = String(data: jsonData, encoding: .utf8),
              let metadataAdapter = metadataAdapter else {
            return
        }
        
        // Create metadata item
        let metadataItem = AVMutableMetadataItem()
        metadataItem.key = "io.futrix.flytechy.3D" as (NSCopying & NSObjectProtocol)?
        metadataItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        metadataItem.value = encodedDepthValues as (NSCopying & NSObjectProtocol)?
        
        // Create a metadata timed group and append it
        let timedMetadataGroup = AVTimedMetadataGroup(items: [metadataItem], timeRange: CMTimeRangeMake(start: lastTimestamp, duration: frameDuration))
        
        if metadataAdapter.assetWriterInput.isReadyForMoreMediaData {
            metadataAdapter.append(timedMetadataGroup)
        }
    }

    
    // Flatten depth data into a 2D array for metadata storage.
    private func flattenDepthArray(depthData: AVDepthData)->[Float]{
        // Access the depth data map
        let depthDataMap = depthData.depthDataMap
        
        // Get the width and height of the depth data
        let width = CVPixelBufferGetWidth(depthDataMap)
        let height = CVPixelBufferGetHeight(depthDataMap)
        
        // Lock the pixel buffer to ensure data consistency
        CVPixelBufferLockBaseAddress(depthDataMap, .readOnly)
        
        // Access the base address of the depth data map
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthDataMap) else {
            CVPixelBufferUnlockBaseAddress(depthDataMap, .readOnly)
            return []
        }
        
        // Define an array to store depth data values
        var depthValues: [Float] = []
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthDataMap)
        
        // Iterate through the depth data map to extract depth values
        for y in 0..<height {
            let rowPointer = baseAddress.advanced(by: y * bytesPerRow)
            let depthRow = rowPointer.assumingMemoryBound(to: Float32.self)
            
            for x in 0..<width {
                let depthValue = depthRow[x]
                depthValues.append(depthValue)
            }
        }
        
        // Unlock the pixel buffer
        CVPixelBufferUnlockBaseAddress(depthDataMap, .readOnly)
        return depthValues
    }
    
    
    // Reset recording state and inputs after a session.
    private func resetRecordingState() {
        assetWriter = nil
        assetWriterInput = nil
        assetWriterPixelBufferInput = nil
        assetWriterMetadataInput = nil
    }
    
    // Finalize and complete the video recording.
    private func finishRecording() {
           
           if assetWriter?.status == .writing {
               assetWriter?.finishWriting { [weak self] in
                   guard let self = self else { return }
                   
                   if let videoURL = self.assetWriter?.outputURL {
                       DispatchQueue.main.async { [self] in
                           print("Saving video to gallery at path: \(videoURL.path)")
                           self.saveVideoWithMetadata(videoURL: videoURL)
                       }
                       self.resetRecordingState()
                   }
               }
           } else {
               print("Asset Writer not in a writable state: \(String(describing: assetWriter?.status))")
           }
           
       }
       
       func saveVideoWithMetadata(videoURL: URL) {
           // Request authorization if not already done
           PHPhotoLibrary.requestAuthorization { status in
               guard status == .authorized else {
                   print("Permission not granted to access photo library")
                   return
               }
               
               PHPhotoLibrary.shared().performChanges({
                   // Create a new asset creation request
                   let creationRequest = PHAssetCreationRequest.forAsset()
                   creationRequest.addResource(with: .video, fileURL: videoURL, options: nil)
                   creationRequest.creationDate = Date()
                   
               }) { success, error in
                   if success {
                       print("Video saved successfully with metadata.")
                   } else if let error = error {
                       print("Error saving video: \(error.localizedDescription)")
                   }
               }
           }
       }
}

// AVCaptureDataOutputSynchronizerDelegate method to handle synchronized video and depth data.
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
