import Foundation

// RAPT stores the Android application label as either a literal or a resource.
enum APKTitle {
    private struct Binary {
        let data: Data

        func number(_ at: Int, bytes: Int = 4) -> Int? {
            guard at >= 0, at <= data.count - bytes else { return nil }
            return (0..<bytes).reduce(0) { $0 | (Int(data[at + $1]) << ($1 * 8)) }
        }

        func chunks(_ start: Int, _ end: Int) -> [Chunk] {
            var result: [Chunk] = []
            var offset = start
            while offset <= end - 8, let type = number(offset, bytes: 2),
                  let header = number(offset + 2, bytes: 2), let size = number(offset + 4),
                  header >= 8, size >= header, size <= end - offset {
                result.append(Chunk(type: type, start: offset, header: header, end: offset + size))
                offset += size
            }
            return result
        }

        func string(_ index: Int, in pool: Chunk) -> String? {
            guard pool.header >= 28, let count = number(pool.start + 8), index < count, index >= 0,
                  index < (pool.end - pool.start - pool.header) / 4,
                  let flags = number(pool.start + 16), let base = number(pool.start + 20),
                  let offset = number(pool.start + pool.header + index * 4) else { return nil }
            var position = pool.start + base + offset
            guard position < pool.end else { return nil }
            if flags & 0x100 != 0 {
                func length() -> Int? {
                    guard position < pool.end, let first = number(position, bytes: 1) else { return nil }
                    position += 1
                    if first & 0x80 == 0 { return first }
                    guard position < pool.end, let second = number(position, bytes: 1) else { return nil }
                    position += 1
                    return ((first & 0x7f) << 8) | second
                }
                guard length() != nil, let bytes = length(), bytes <= pool.end - position else { return nil }
                return String(data: data[position..<position + bytes], encoding: .utf8)
            }
            guard let first = number(position, bytes: 2) else { return nil }
            position += 2
            var length = first
            if first & 0x8000 != 0 {
                guard let second = number(position, bytes: 2) else { return nil }
                position += 2
                length = ((first & 0x7fff) << 16) | second
            }
            guard position <= pool.end, length <= (pool.end - position) / 2 else { return nil }
            return String(data: data[position..<position + length * 2], encoding: .utf16LittleEndian)
        }
    }

    private struct Chunk {
        let type: Int
        let start: Int
        let header: Int
        let end: Int
    }

    static func read(manifest: Data, resources: () -> Data?) -> (title: String?, identifier: String?) {
        let xml = Binary(data: manifest)
        guard let root = xml.chunks(0, manifest.count).first, root.type == 3 else { return (nil, nil) }
        let children = xml.chunks(root.start + root.header, root.end)
        guard let pool = children.first(where: { $0.type == 1 }) else { return (nil, nil) }

        var title: String?
        var identifier: String?
        for element in children where element.type == 0x102 {
            let ext = element.start + element.header
            guard ext <= element.end - 20, let index = xml.number(ext + 4),
                  let name = xml.string(index, in: pool),
                  name == "manifest" || name == "application",
                  let start = xml.number(ext + 8, bytes: 2), let size = xml.number(ext + 10, bytes: 2),
                  let count = xml.number(ext + 12, bytes: 2),
                  start >= 20, size >= 20, start <= element.end - ext,
                  count <= (element.end - ext - start) / size else { continue }
            for offset in 0..<count {
                let at = ext + start + offset * size
                guard let attribute = xml.number(at + 4).flatMap({ xml.string($0, in: pool) }),
                      let type = xml.number(at + 15, bytes: 1), let value = xml.number(at + 16) else { continue }
                if name == "manifest", attribute == "package", type == 3 {
                    identifier = xml.string(value, in: pool)
                }
                if name == "application", attribute == "label" {
                    if type == 3 { title = xml.string(value, in: pool) }
                    if type == 1, let table = resources() { title = label(value, in: table) }
                }
            }
        }
        return (title, identifier)
    }

    private static func label(_ id: Int, in data: Data) -> String? {
        let table = Binary(data: data)
        guard let root = table.chunks(0, data.count).first, root.type == 2 else { return nil }
        let children = table.chunks(root.start + root.header, root.end)
        guard let pool = children.first(where: { $0.type == 1 }) else { return nil }
        let entry = id & 0xffff
        let type = (id >> 16) & 0xff
        for package in children where package.type == 0x200 && table.number(package.start + 8) == id >> 24 {
            let typeOffset = package.header >= 288 ? (table.number(package.start + 284) ?? 0) : 0
            let types = table.chunks(package.start + package.header, package.end)
            for item in types where item.type == 0x201 && table.number(item.start + 8, bytes: 1) == type - typeOffset {
                guard item.header >= 24, let flags = table.number(item.start + 9, bytes: 1),
                      flags & 1 == 0, let count = table.number(item.start + 12), entry < count,
                      let values = table.number(item.start + 16) else { continue }
                let width = flags & 2 == 0 ? 4 : 2
                let index = item.start + item.header + entry * width
                guard index <= item.end - width, let raw = table.number(index, bytes: width),
                      raw != (width == 4 ? 0xffffffff : 0xffff) else { continue }
                let start = item.start + values + raw * (width == 2 ? 4 : 1)
                guard start <= item.end - 8, let size = table.number(start, bytes: 2), size >= 8,
                      let entryFlags = table.number(start + 2, bytes: 2), entryFlags & 9 == 0,
                      start + size <= item.end - 8, table.number(start + size + 3, bytes: 1) == 3,
                      let value = table.number(start + size + 4),
                      let title = table.string(value, in: pool), !title.isEmpty else { continue }
                return title
            }
        }
        return nil
    }
}
