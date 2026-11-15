import Foundation
import Metal

/// What this Mac lets the GPU address. On Apple silicon the GPU shares system
/// memory but may only use part of it (about three quarters on a 24 GB M2),
/// and a model plus its context window that exceeds that is partly moved to
/// the CPU by Ollama. Metal reports the real figure for this machine.
enum GPUMemory {
    static var limitBytes: Int64 {
        if let device = MTLCreateSystemDefaultDevice() {
            let reported = device.recommendedMaxWorkingSetSize
            if reported > 0 { return Int64(clamping: reported) }
        }
        // No Metal device: assume two thirds of RAM, the usual default share.
        return Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.67)
    }
}
