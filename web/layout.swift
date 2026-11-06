import Foundation
import CoreGraphics
import ColorSync

struct Screen: Encodable {
    let id: CGDirectDisplayID
    let uuid: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let main: Bool
    let mirrored: Bool

    var position: Position { Position(uuid: uuid, x: x, y: y) }
}

struct Position: Codable, Equatable {
    let uuid: String
    let x: Int
    let y: Int
}

struct LayoutRequest: Decodable {
    let positions: [Position]
    let expected: [ScreenGeometry]
}

struct ScreenGeometry: Codable, Equatable {
    let uuid: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct LayoutError: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func check(_ result: CGError, _ action: String) throws {
    guard result == .success else { throw LayoutError("\(action) failed (CGError \(result.rawValue)).") }
}

func screens() throws -> [Screen] {
    var count: UInt32 = 0
    try check(CGGetActiveDisplayList(0, nil, &count), "Display discovery")
    if count == 0 { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    try check(CGGetActiveDisplayList(count, &ids, &count), "Display discovery")
    return try ids.prefix(Int(count)).map { id in
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else {
            throw LayoutError("macOS did not provide a display identifier.")
        }
        let bounds = CGDisplayBounds(id)
        return Screen(id: id, uuid: CFUUIDCreateString(nil, ref.takeRetainedValue()) as String,
                      x: Int(bounds.minX.rounded()), y: Int(bounds.minY.rounded()),
                      width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()),
                      main: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0)
    }
}

func geometry(_ screens: [Screen]) -> [ScreenGeometry] {
    screens.map { ScreenGeometry(uuid: $0.uuid, x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        .sorted { $0.uuid < $1.uuid }
}

func validate(_ positions: [Position], against active: [Screen]) throws {
    guard active.count >= 2 else { throw LayoutError("Connect a second display to arrange your desktop.") }
    guard !active.contains(where: \.mirrored) else { throw LayoutError("Turn off display mirroring in System Settings to arrange these displays.") }
    let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.uuid, $0) })
    guard positions.count == active.count, Set(positions.map(\.uuid)) == Set(byID.keys) else {
        throw LayoutError("The connected displays changed. Refresh and try again.")
    }
    guard positions.allSatisfy({ (-100_000...100_000).contains($0.x) && (-100_000...100_000).contains($0.y) }),
          positions.filter({ $0.x == 0 && $0.y == 0 }).count == 1 else {
        throw LayoutError("The arrangement needs one main display at (0, 0) and valid coordinates.")
    }
    var neighbors = positions.map { _ in Set<Int>() }
    for (i, a) in positions.enumerated() {
        let aSize = byID[a.uuid]!
        for j in positions.indices where j > i {
            let b = positions[j]
            let bSize = byID[b.uuid]!
            let sharedX = min(a.x + aSize.width, b.x + bSize.width) - max(a.x, b.x)
            let sharedY = min(a.y + aSize.height, b.y + bSize.height) - max(a.y, b.y)
            if sharedX > 0 && sharedY > 0 { throw LayoutError("Displays cannot overlap.") }
            if (sharedX > 0 && sharedY == 0) || (sharedY > 0 && sharedX == 0) {
                neighbors[i].insert(j)
                neighbors[j].insert(i)
            }
        }
    }
    var connected: Set<Int> = [0]
    var queue = [0]
    while let i = queue.popLast() {
        for j in neighbors[i] where connected.insert(j).inserted { queue.append(j) }
    }
    guard connected.count == positions.count else {
        throw LayoutError("Each display must connect to the desktop along an edge.")
    }
}

func configure(_ positions: [Position], on active: [Screen]) throws {
    let ids = Dictionary(uniqueKeysWithValues: active.map { ($0.uuid, $0.id) })
    var configuration: CGDisplayConfigRef?
    try check(CGBeginDisplayConfiguration(&configuration), "Beginning arrangement")
    do {
        // Stage the primary last so it claims the global origin.
        for position in positions.sorted(by: { a, b in
            (a.x == 0 && a.y == 0 ? 1 : 0) < (b.x == 0 && b.y == 0 ? 1 : 0)
        }) {
            try check(CGConfigureDisplayOrigin(configuration, ids[position.uuid]!, Int32(position.x), Int32(position.y)),
                      "Setting display position")
        }
    } catch {
        CGCancelDisplayConfiguration(configuration)
        throw error
    }
    try check(CGCompleteDisplayConfiguration(configuration, .permanently), "Saving arrangement")
}

func output<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(value))
}

do {
    let active = try screens()
    switch CommandLine.arguments.dropFirst().first {
    case "list":
        try output(active)
    case "apply":
        let request = try JSONDecoder().decode(LayoutRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard geometry(active) == request.expected.sorted(by: { $0.uuid < $1.uuid }) else {
            throw LayoutError("Display positions or sizes changed. Refresh and try again.")
        }
        try validate(request.positions, against: active)
        try configure(request.positions, on: active)
        try output(try screens())
    default:
        throw LayoutError("Use layout list or layout apply.")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
