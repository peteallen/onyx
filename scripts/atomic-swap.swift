import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: atomic-swap.swift EXISTING_PATH REPLACEMENT_PATH\n".utf8)
    )
    exit(64)
}

let existingPath = CommandLine.arguments[1]
let replacementPath = CommandLine.arguments[2]

let result = existingPath.withCString { existingPointer in
    replacementPath.withCString { replacementPointer in
        renameatx_np(
            AT_FDCWD,
            existingPointer,
            AT_FDCWD,
            replacementPointer,
            UInt32(RENAME_SWAP)
        )
    }
}

guard result == 0 else {
    let errorNumber = errno
    let message = String(cString: strerror(errorNumber))
    FileHandle.standardError.write(
        Data("atomic-swap: \(message) (errno \(errorNumber))\n".utf8)
    )
    exit(1)
}
