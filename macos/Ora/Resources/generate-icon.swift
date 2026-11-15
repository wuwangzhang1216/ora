#!/usr/bin/env swift
// Regenerate the compatibility icon from the approved Icon Composer document.
// App bundles compile the same source through scripts/compile-icon.sh.
// Usage: swift Resources/generate-icon.swift
import Foundation

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("ora-icon-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [resources.deletingLastPathComponent()
    .appendingPathComponent("scripts/compile-icon.sh").path, temporary.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let destination = resources.appendingPathComponent("AppIcon.icns")
let data = try Data(contentsOf: temporary.appendingPathComponent("AppIcon.icns"))
try data.write(to: destination, options: .atomic)
print("Updated " + destination.path)
