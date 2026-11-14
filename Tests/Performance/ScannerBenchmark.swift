import Foundation
import Darwin

@main struct ScannerBenchmark {
    static func main() async throws {
        let path = CommandLine.arguments[1]
        let repeats = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 3
        for _ in 0..<repeats {
            let result: ScanSnapshot
            if let workers = ProcessInfo.processInfo.environment["WORKERS"].flatMap(Int.init) {
                result = try await ParallelDiskScanner.scan(URL(fileURLWithPath: path), workers: workers,
                    depth: Int(ProcessInfo.processInfo.environment["DEPTH"] ?? "4")!)
            } else if ProcessInfo.processInfo.environment["SCANNER"] == "bulk" { result = try BulkScannerExperiment.scan(URL(fileURLWithPath: path))
            } else { result = try ProcessInfo.processInfo.environment["SCANNER"] == "fts" ? NativeDiskScanner.scan(URL(fileURLWithPath: path)) : ReferenceScanner.scan(URL(fileURLWithPath: path)) }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            print("seconds=\(result.elapsed) nodes=\(result.nodes.count) logical=\(result.root.logicalSize) allocated=\(result.root.allocatedSize) issues=\(result.issueCount) peakRSS=\(usage.ru_maxrss)")
        }
    }
}
