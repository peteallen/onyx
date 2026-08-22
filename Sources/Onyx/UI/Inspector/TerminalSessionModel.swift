import AppKit
import Darwin
import Foundation

/// Owns one project shell for the lifetime of a workspace window. The process
/// is intentionally independent of the terminal drawer's visibility, so a
/// command keeps running when the drawer is closed and reopened.
@MainActor
final class TerminalSessionModel: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var workingDirectory: String?
    @Published private(set) var exitStatus: Int32?
    @Published var input = ""

    private var process: Process?
    private var masterHandle: FileHandle?
    private var slaveHandle: FileHandle?
    private var generation = UUID()
    private var lastSize = (columns: 100, rows: 24)
    private var escapeFilter = TerminalEscapeFilter()

    /// A terminal can be long lived, but unbounded UI text eventually makes
    /// AppKit layout expensive. Keep the recent output while the actual shell
    /// session continues uninterrupted.
    private static let maximumOutputCharacters = 500_000

    deinit {
        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        try? slaveHandle?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func start(in requestedDirectory: String?) {
        stop(appendStatus: false)
        output = ""
        exitStatus = nil
        escapeFilter = TerminalEscapeFilter()

        let directory = resolvedDirectory(requestedDirectory)
        workingDirectory = directory.path

        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        var size = winsize(
            ws_row: UInt16(clamping: lastSize.rows),
            ws_col: UInt16(clamping: lastSize.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&masterDescriptor, &slaveDescriptor, nil, nil, &size) == 0 else {
            append("Could not open a terminal: \(String(cString: strerror(errno)))\n")
            workingDirectory = nil
            return
        }

        let master = FileHandle(fileDescriptor: masterDescriptor, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveDescriptor, closeOnDealloc: true)
        let process = Process()
        let sessionGeneration = UUID()
        generation = sessionGeneration

        let shellPath = environmentShellPath()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["ONYX_TERMINAL"] = "1"
        environment["HISTFILE"] = "/dev/null"
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        master.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == sessionGeneration else { return }
                append(escapeFilter.consume(data))
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.processDidExit(status: status, generation: sessionGeneration)
            }
        }

        self.process = process
        masterHandle = master
        slaveHandle = slave

        do {
            try process.run()
            // The child owns its duplicated slave descriptor after spawn. The
            // parent keeps only the PTY master so EOF and job control work.
            try? slave.close()
            slaveHandle = nil
            isRunning = true
        } catch {
            master.readabilityHandler = nil
            try? master.close()
            try? slave.close()
            self.process = nil
            masterHandle = nil
            slaveHandle = nil
            workingDirectory = nil
            append("Could not start the shell: \(error.localizedDescription)\n")
        }
    }

    func sendInputLine() {
        let line = input
        input = ""
        guard isRunning else { return }
        write(Data((line + "\n").utf8))
    }

    func interrupt() {
        guard isRunning else { return }
        write(Data([0x03]))
    }

    func sendEndOfFile() {
        guard isRunning else { return }
        write(Data([0x04]))
    }

    func clear() {
        output = ""
    }

    func resize(columns: Int, rows: Int) {
        let boundedColumns = min(max(columns, 20), Int(UInt16.max))
        let boundedRows = min(max(rows, 4), Int(UInt16.max))
        guard lastSize != (boundedColumns, boundedRows) else { return }
        lastSize = (boundedColumns, boundedRows)
        guard let descriptor = masterHandle?.fileDescriptor else { return }

        var size = winsize(
            ws_row: UInt16(boundedRows),
            ws_col: UInt16(boundedColumns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(descriptor, TIOCSWINSZ, &size)
    }

    func stop(appendStatus: Bool = true) {
        generation = UUID()
        let wasRunning = process?.isRunning == true
        masterHandle?.readabilityHandler = nil
        if wasRunning {
            process?.terminate()
        }
        try? masterHandle?.close()
        try? slaveHandle?.close()
        process = nil
        masterHandle = nil
        slaveHandle = nil
        isRunning = false
        if wasRunning, appendStatus {
            append("\n[Shell stopped]\n")
        }
    }

    private func write(_ data: Data) {
        do {
            try masterHandle?.write(contentsOf: data)
        } catch {
            append("\n[Could not write to shell: \(error.localizedDescription)]\n")
        }
    }

    private func processDidExit(status: Int32, generation sessionGeneration: UUID) {
        guard generation == sessionGeneration else { return }
        masterHandle?.readabilityHandler = nil
        try? masterHandle?.close()
        try? slaveHandle?.close()
        masterHandle = nil
        slaveHandle = nil
        process = nil
        isRunning = false
        exitStatus = status
        append("\n[Shell exited with status \(status)]\n")
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        output.append(text)
        if output.count > Self.maximumOutputCharacters {
            output.removeFirst(output.count - Self.maximumOutputCharacters)
            output.insert(contentsOf: "[Earlier terminal output trimmed]\n", at: output.startIndex)
        }
    }

    private func resolvedDirectory(_ requestedDirectory: String?) -> URL {
        var isDirectory: ObjCBool = false
        if let requestedDirectory,
           FileManager.default.fileExists(atPath: requestedDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: requestedDirectory, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func environmentShellPath() -> String {
        let candidate = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        guard candidate.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: candidate) else {
            return "/bin/zsh"
        }
        return candidate
    }
}

/// Removes terminal-control sequences that SwiftUI's plain text renderer
/// cannot interpret. The PTY still receives full xterm input and dimensions;
/// this filter only affects the readable transcript shown in the drawer.
struct TerminalEscapeFilter {
    private enum State {
        case text
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private var state = State.text
    private var previousByteWasCarriageReturn = false
    private var undecodedUTF8: [UInt8] = []

    static func visibleText(from data: Data) -> String {
        var filter = Self()
        return filter.consume(data)
    }

    mutating func consume(_ data: Data) -> String {
        var visible: [UInt8] = []
        visible.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .text:
                switch byte {
                case 0x1B:
                    previousByteWasCarriageReturn = false
                    state = .escape
                case 0x08:
                    previousByteWasCarriageReturn = false
                    if !visible.isEmpty { visible.removeLast() }
                case 0x0D:
                    // Turn CR updates into readable history. If the next byte
                    // is LF, consume it so a split CRLF does not add a blank line.
                    if visible.last != 0x0A { visible.append(0x0A) }
                    previousByteWasCarriageReturn = true
                case 0x0A:
                    if previousByteWasCarriageReturn {
                        previousByteWasCarriageReturn = false
                    } else {
                        visible.append(byte)
                    }
                case 0x00, 0x07:
                    previousByteWasCarriageReturn = false
                    break
                default:
                    previousByteWasCarriageReturn = false
                    visible.append(byte)
                }
            case .escape:
                switch byte {
                case 0x5B: state = .controlSequence // ESC [
                case 0x5D: state = .operatingSystemCommand // ESC ]
                default: state = .text
                }
            case .controlSequence:
                // CSI parameters/intermediates end with a 0x40...0x7E byte.
                if (0x40 ... 0x7E).contains(byte) { state = .text }
            case .operatingSystemCommand:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                state = byte == 0x5C ? .text : .operatingSystemCommand
            }
        }

        let combined = undecodedUTF8 + visible
        let incompleteCount = incompleteUTF8SuffixLength(in: combined)
        let completeEnd = combined.count - incompleteCount
        undecodedUTF8 = Array(combined[completeEnd...])
        return String(decoding: combined[..<completeEnd], as: UTF8.self)
    }

    private func incompleteUTF8SuffixLength(in bytes: [UInt8]) -> Int {
        guard let finalByte = bytes.last, finalByte >= 0x80 else { return 0 }
        let lowerBound = max(bytes.count - 4, 0)
        var leadIndex = bytes.count - 1
        while leadIndex >= lowerBound, (bytes[leadIndex] & 0xC0) == 0x80 {
            if leadIndex == 0 { break }
            leadIndex -= 1
        }

        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2 ... 0xDF: expectedLength = 2
        case 0xE0 ... 0xEF: expectedLength = 3
        case 0xF0 ... 0xF4: expectedLength = 4
        default: return 0
        }

        let actualLength = bytes.count - leadIndex
        guard actualLength < expectedLength else { return 0 }
        guard bytes[(leadIndex + 1)...].allSatisfy({ ($0 & 0xC0) == 0x80 }) else { return 0 }
        return actualLength
    }
}
