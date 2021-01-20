//
//  AudioManager.swift
//  AudioEngineLoopbackLatencyTest
//
//  Created by John Nastos on 1/6/21.
//

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import CoreAudio

let startDelay = 0.1

struct AudioManagerState {
    var secondsToTicks : Double = calculateSecondsToTicks()
    
    //time markers (all in host time)
    var audioBuffersScheduledAtHost : UInt64 = 0 //when does the original audio get played
    var inputNodeTapBeganAtHost : UInt64 = 0 //the first call to the input node tap
    var outputNodeTapBeganAtHost : UInt64 = 0 //first call to the output node tap

	var outputSafetyOffset: UInt32 = 0
	var inputSafetyOffset: UInt32 = 0
	var outputLatency: UInt32 = 0
	var inputLatency: UInt32 = 0
	var outputStreamLatency: UInt32 = 0
	var inputStreamLatency: UInt32 = 0
	var outputBufferSizeFrames: UInt32 = 0
	var inputBufferSizeFrames: UInt32 = 0
}

class AudioManager : ObservableObject {
    @Published var isRunning = false
    @Published var hasResultFileToPlay = false
    @Published var floatDataToDisplay : ([Float],[Float]) = ([],[])
    
    public var state = AudioManagerState()
    
    private var audioEngine = AVAudioEngine()
    
    //this node/buffer will play back our pre-recorded metronome audio file
    private var playerNode = AVAudioPlayerNode()
    private var metronomeFileBuffer : AVAudioPCMBuffer?
    
    //these files will get written to from the input taps
    private var inputRecordingFile : AVAudioFile?
    private var outputRecordingFile : AVAudioFile?
    
    //once the sync is done, this player can be used to play the resulting file
    private var resultAudioPlayer : AVAudioPlayer?
}

/* START AND STOP FUNCTIONS */
extension AudioManager {
    func start() {
        setupAudio()
        createRecordingAudioFiles()
        
        self.isRunning = true
        do {
            try audioEngine.start()
            print("Audio engine running")
        } catch {
            fatalError("Couldn't start engine: \(error)")
        }
        
        scheduleAndPlayAudioBuffers()
    }
    
    func stop() {
        DispatchQueue.main.async {
            self.audioEngine.stop()
            self.isRunning = false
            print("Audio engine stopped")
            self.createResultFile()
        }
    }
}

/* AUDIO ENGINE SETUP
 
    Set up the AVAudioEngine (connect nodes, input taps, etc)
    Reset state to get ready to capture timing values
 */
extension AudioManager {
    func setupAudio() {
        audioEngine.stop()
        playerNode.stop()
        playerNode.reset()
        
        state = AudioManagerState()
        loadAudioBuffers()
        
        setupAudioSession()
        audioEngine = AVAudioEngine()
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to:audioEngine.mainMixerNode, format: audioEngine.mainMixerNode.inputFormat(forBus: 0))
        
        installTapOnInputNode()
        installTapOnOutputNode()
        
        audioEngine.prepare()
		getDeviceProperties()
    }
    
    func setupAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker])
            print("Set audio session...")
            
            print("IO Buffer: \(AVAudioSession.sharedInstance().ioBufferDuration) -- \(AVAudioSession.sharedInstance().ioBufferDuration * audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)")
            print("Input latency: \(AVAudioSession.sharedInstance().inputLatency * audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)")
            print("Output latency: \(AVAudioSession.sharedInstance().outputLatency * audioEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)")
        } catch {
            assertionFailure("Error setting session active: \(error.localizedDescription)")
        }
        #endif
    }

	func getDeviceProperties() {
		#if os(macOS)
		var status: OSStatus = noErr

		let inputNodeID = audioEngine.inputNode.auAudioUnit.deviceID
		let outputNodeID = audioEngine.outputNode.auAudioUnit.deviceID

		var pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertySafetyOffset,
										mScope: kAudioObjectPropertyScopeOutput,
										mElement: kAudioObjectPropertyElementMaster)
		var answerSize = UInt32(MemoryLayout<UInt32>.size)
		var answer: UInt32 = 0
		status = AudioObjectGetPropertyData(outputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertySafetyOffset (output -- output scope): \(answer)")
		state.outputSafetyOffset = answer

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertySafetyOffset,
										mScope: kAudioObjectPropertyScopeInput,
										mElement: kAudioObjectPropertyElementMaster)
		answerSize = UInt32(MemoryLayout<UInt32>.size)
		answer = 0
		status = AudioObjectGetPropertyData(inputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertySafetyOffset (input -- input scope): \(answer)")
		state.inputSafetyOffset = answer

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency,
										mScope: kAudioObjectPropertyScopeOutput,
										mElement: kAudioObjectPropertyElementMaster)
		answerSize = UInt32(MemoryLayout<UInt32>.size)
		answer = 0
		status = AudioObjectGetPropertyData(outputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertyLatency (output - output scope): \(answer)")
		state.outputLatency = answer

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency,
										mScope: kAudioObjectPropertyScopeInput,
										mElement: kAudioObjectPropertyElementMaster)
		answerSize = UInt32(MemoryLayout<UInt32>.size)
		answer = 0
		status = AudioObjectGetPropertyData(inputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertyLatency (input -- input scope): \(answer)")
		state.inputLatency = answer

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
										mScope: kAudioObjectPropertyScopeOutput,
										mElement: kAudioObjectPropertyElementMaster)
		answerSize = UInt32(MemoryLayout<UInt32>.size)
		answer = 0
		status = AudioObjectGetPropertyData(outputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertyBufferFrameSize (output -- output scope): \(answer)")
		state.outputBufferSizeFrames = answer

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
										mScope: kAudioObjectPropertyScopeInput,
										mElement: kAudioObjectPropertyElementMaster)
		answerSize = UInt32(MemoryLayout<UInt32>.size)
		answer = 0
		status = AudioObjectGetPropertyData(inputNodeID, &pa, 0, nil, &answerSize, &answer)
		if status != noErr {
			fatalError("Error: \(status)")
		}
		print("kAudioDevicePropertyBufferFrameSize (input -- input scope): \(answer)")
		state.inputBufferSizeFrames = answer

		var streamsSize: UInt32 = 0

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMaster)
		status = AudioObjectGetPropertyDataSize(outputNodeID, &pa, 0, nil, &streamsSize)
		guard  status == noErr else {
			fatalError("Status: \(status)")
		}
		var numStreams: UInt32 = streamsSize / UInt32(MemoryLayout<AudioStreamID>.stride)
		var streams = [AudioStreamID](repeating: 0, count: Int(numStreams))
		status = AudioObjectGetPropertyData(outputNodeID, &pa, 0, nil, &streamsSize, &streams)
		guard  status == noErr else {
			fatalError("Status: \(status)")
		}

		for stream in streams {
			pa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency,
											mScope: kAudioObjectPropertyScopeOutput,
											mElement: kAudioObjectPropertyElementMaster)
			pa.mSelector = kAudioStreamPropertyLatency
			answerSize = UInt32(MemoryLayout<UInt32>.size)
			answer = 0
			status = AudioObjectGetPropertyData(stream, &pa, 0, nil, &answerSize, &answer)
			guard  status == noErr else {
				fatalError("Status: \(status)")
			}
			print("kAudioStreamPropertyLatency (stream 0x\(String(stream, radix: 16, uppercase: false)) output): \(answer)")
			state.outputStreamLatency = answer
		}

		pa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMaster)
		status = AudioObjectGetPropertyDataSize(outputNodeID, &pa, 0, nil, &streamsSize)
		guard  status == noErr else {
			fatalError("Status: \(status)")
		}
		numStreams = streamsSize / UInt32(MemoryLayout<AudioStreamID>.stride)
		streams = [AudioStreamID](repeating: 0, count: Int(numStreams))
		status = AudioObjectGetPropertyData(inputNodeID, &pa, 0, nil, &streamsSize, &streams)
		guard  status == noErr else {
			fatalError("Status: \(status)")
		}

		for stream in streams {
			pa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMaster)
			answerSize = UInt32(MemoryLayout<UInt32>.size)
			answer = 0
			status = AudioObjectGetPropertyData(stream, &pa, 0, nil, &answerSize, &answer)
			guard  status == noErr else {
				fatalError("Status: \(status)")
			}
			print("kAudioStreamPropertyLatency (stream 0x\(String(stream, radix: 16, uppercase: false)) input): \(answer)")
			state.inputStreamLatency = answer
		}

		#endif
	}
}

/* SCHEDULING OF BUFFERS DURING INITIAL PLAYBACK */
extension AudioManager {
    func scheduleAndPlayAudioBuffers() {
        guard let metronomeFileBuffer = self.metronomeFileBuffer else {
            fatalError("No buffer")
        }
        
        //delay the playback of the initial buffer so that we're not trying to play immediately when the engine starts
        let delay = startDelay * state.secondsToTicks
        let audioTime = AVAudioTime(hostTime: mach_absolute_time() + UInt64(delay))
        state.audioBuffersScheduledAtHost = audioTime.hostTime
        
        playerNode.play()
        playerNode.scheduleBuffer(metronomeFileBuffer, at: audioTime, options:[], completionHandler: {
            print("Played original buffer")
            self.stop()
        })
    }
}

/* AUDIO FILE SETUP FOR RECORDING INPUT TAPS */
extension AudioManager {
    var inputNodeFileURL : URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input_recorded.caf")
    }
    
    var outputNodeFileURL : URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("output_recorded.caf")
    }
    
    func createRecordingAudioFiles() {
        try? FileManager.default.removeItem(at: inputNodeFileURL)
        try? FileManager.default.removeItem(at: outputNodeFileURL)
        
        do {
            inputRecordingFile = try AVAudioFile(forWriting: inputNodeFileURL,
                                                 settings: audioEngine.inputNode.outputFormat(forBus: 0).settings)
            outputRecordingFile = try AVAudioFile(forWriting: outputNodeFileURL,
                                                  settings: audioEngine.mainMixerNode.outputFormat(forBus: 0).settings)
        } catch {
            fatalError("Couldn't make files: \(error)")
        }
    }
}

/* CREATE THE RESULT FILE
    
    createResultFile() is where the sync logic is implemented
 */
extension AudioManager {
    var resultFileURL : URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.caf")
    }
    
    func createResultFile() {
        let renderingEngine = AVAudioEngine()
        
        guard let metronomeFileBuffer = self.metronomeFileBuffer else {
            fatalError("No buffer")
        }
        
        guard let inputFileForReading = try? AVAudioFile(forReading: inputNodeFileURL),
              let outputFileForReading = try? AVAudioFile(forReading: outputNodeFileURL)
                else {
            fatalError("No input/output files for reading")
        }
    
        guard let inputFileBuffer = audioFileToBuffer(inputFileForReading),
              let outputFileBuffer = audioFileToBuffer(outputFileForReading)
                else {
            fatalError("No input/output file buffers")
        }
        
        let originalAudioPlayerNode = AVAudioPlayerNode()
        let recordedInputNodePlayer = AVAudioPlayerNode()
        let recordedOutputNodePlayer = AVAudioPlayerNode()
        
        renderingEngine.attach(originalAudioPlayerNode)
        renderingEngine.attach(recordedInputNodePlayer)
        renderingEngine.attach(recordedOutputNodePlayer)
        
        renderingEngine.connect(originalAudioPlayerNode,
                                to:renderingEngine.mainMixerNode,
                                format: renderingEngine.mainMixerNode.inputFormat(forBus: 0))
        
        renderingEngine.connect(recordedInputNodePlayer,
                                to:renderingEngine.mainMixerNode,
                                format: inputFileBuffer.format)
        renderingEngine.connect(recordedOutputNodePlayer,
                                to:renderingEngine.mainMixerNode,
                                format: outputFileBuffer.format)
        
        try? FileManager.default.removeItem(at: resultFileURL)
        
        let resultFormat = renderingEngine.outputNode.outputFormat(forBus: 0)
        
        guard let resultFile = try? AVAudioFile(forWriting: resultFileURL, settings: resultFormat.settings) else {
            fatalError("Couldn't make result file")
        }
        
        do {
            try renderingEngine.enableManualRenderingMode(.offline,
                                                          format: resultFormat,
                                                          maximumFrameCount: 4096)
            try renderingEngine.start()
        } catch {
            fatalError("Couldn't make result file: \(error)")
        }
        
        /* ---------------------------------------------- DETERMINE SYNC -------------------------------------- */

        //pan the nodes so that the result file is visually easy to see the sync on by comparing the waveforms of the channels
        originalAudioPlayerNode.pan = -1.0
        recordedOutputNodePlayer.pan = -1.0
        recordedInputNodePlayer.pan = 1.0

        originalAudioPlayerNode.play()
        recordedInputNodePlayer.play()
        recordedOutputNodePlayer.play()

		// The following computations work with the built-in audio on my MBP, presumably because the devices report accurate
		// latencies. The following values are what is reported for the aggregate device created by AVAudioEngine:

		// Output:
		// kAudioDevicePropertySafetyOffset:    144
		// kAudioDevicePropertyLatency:          11
		// kAudioStreamPropertyLatency:         424
		// kAudioDevicePropertyBufferFrameSize: 512

		// Input:
		// kAudioDevicePropertySafetyOffset:     154
		// kAudioDevicePropertyLatency:            0
		// kAudioStreamPropertyLatency:         2404
		// kAudioDevicePropertyBufferFrameSize:  512

		// It's possible that the results work by coincidence! The computations below don't work with my display's
		// audio. Further testing is required.

		// If the input and output devices are at different sample rates the math will need to be fixed.

		// The original audio file start time
		let originalStartingFrame: AVAudioFramePosition = AVAudioFramePosition(playerNode.outputFormat(forBus: 0).sampleRate * startDelay)
		// The output tap's first sample was delivered to the device after the buffer was filled once
		// A number of zero samples equal to the buffer size is produced initially
		let outputStartingFrame: AVAudioFramePosition = Int64(state.outputBufferSizeFrames)
		// The first output sample makes it way back into the input tap after accounting for all the latencies
		let inputStartingFrame: AVAudioFramePosition = outputStartingFrame - Int64(state.outputLatency + state.outputStreamLatency + state.outputSafetyOffset + state.inputSafetyOffset + state.inputLatency + state.inputStreamLatency)

		print("originalStartingFrame = \(originalStartingFrame)")
		print("outputStartingFrame = \(outputStartingFrame)")
		print("inputStartingFrame = \(inputStartingFrame)")

        //play the original metronome audio at sample position 0 and try to sync everything else up to it
        let originalAudioTime = AVAudioTime(sampleTime: originalStartingFrame, atRate: renderingEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        originalAudioPlayerNode.scheduleBuffer(metronomeFileBuffer, at: originalAudioTime, options: []) {
            print("Played original audio")
        }
        
        //play the tap of the output node at its determined sync time -- note that this seems to line up in the result file
		let outputAudioTime = AVAudioTime(sampleTime: outputStartingFrame, atRate: recordedOutputNodePlayer.outputFormat(forBus: 0).sampleRate)
        recordedOutputNodePlayer.scheduleBuffer(outputFileBuffer, at: outputAudioTime, options: []) {
            print("Output buffer played")
        }
        
        //play the tap of the input node at its determined sync time -- this _does not_ appear to line up in the result file
		let inputAudioTime = AVAudioTime(sampleTime: inputStartingFrame, atRate: renderingEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)
        recordedInputNodePlayer.scheduleBuffer(inputFileBuffer, at: inputAudioTime, options: []) {
            print("Input buffer played")
        }
        
        /* ---------------------------------------------- END DETERMINE SYNC -------------------------------------- */
        //The rest of the function just renders the result to a file -- no more sync calcluation
        
        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: renderingEngine.manualRenderingFormat,
            frameCapacity: renderingEngine.manualRenderingMaximumFrameCount)!
        
        do {
            while true {
                let framesToRender = renderBuffer.frameCapacity
                let status = try renderingEngine.renderOffline(framesToRender, to: renderBuffer)
                
                switch status {
                case .success:
                    try resultFile.write(from: renderBuffer)
                default:
                    break
                }
                
                if (renderingEngine.outputNode.lastRenderTime?.sampleTime ?? 0) > inputFileBuffer.frameLength {
                    break
                }
            }
        } catch {
            fatalError("Rendering error: \(error)")
        }
        
        renderingEngine.stop()
        
        print("Created result file at: \(resultFileURL.deletingLastPathComponent())")
        print("Terminal command:")
        print("open \(resultFileURL.deletingLastPathComponent().path)")
        self.hasResultFileToPlay = true
        self.floatDataToDisplay = convertAudioFileToVisualData(fileUrl: resultFileURL)
    }
    
    func playResult() {
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            #endif
            resultAudioPlayer = try AVAudioPlayer(contentsOf: resultFileURL, fileTypeHint: AVFileType.caf.rawValue)
            resultAudioPlayer?.prepareToPlay()
            resultAudioPlayer?.play()
        } catch {
            fatalError("Error making audio player")
        }
    }
}

/* INSTALL TAPS
    
 Also stores the host times for the first input buffers that come in
 Writes tap data to files
 */
extension AudioManager {
    func installTapOnInputNode() {
        audioEngine.inputNode.removeTap(onBus: 0)
        let recordingFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (pcmBuffer, timestamp) in
            if self.state.inputNodeTapBeganAtHost == 0 {
                self.state.inputNodeTapBeganAtHost = timestamp.hostTime
            }
            
            do {
                try self.inputRecordingFile?.write(from: pcmBuffer)
            } catch {
                fatalError("Couldn't write audio file")
            }
        }
    }
    
    func installTapOnOutputNode() {
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        let recordingFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (pcmBuffer, timestamp) in
            if self.state.outputNodeTapBeganAtHost == 0 {
                self.state.outputNodeTapBeganAtHost = timestamp.hostTime
            }
            do {
                try self.outputRecordingFile?.write(from: pcmBuffer)
            } catch {
                fatalError("Couldn't write audio file")
            }
        }
    }
}

//loading existing audio files
extension AudioManager {
    func loadAudioBuffers() {
        guard let audioBuffer1 = loadAudioFile("OriginalAudio") else {
            fatalError("Couldn't load audio buffer")
        }
        self.metronomeFileBuffer = audioBuffer1
    }
}
