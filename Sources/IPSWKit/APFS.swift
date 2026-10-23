import Foundation

/// Just enough APFS to add a volume to an existing container in place.
///
/// An IPSW's root filesystem image holds a container with one volume, System. A restore adds
/// Preboot, Data, xART and others, and launchd's first mount phase refuses to continue without
/// Preboot (it bind-mounts `/private/preboot/<boot manifest hash>/usr/standalone/firmware`).
/// `APFSContainer.addVolume` writes a new volume with a small directory tree so a direct install
/// has the volumes iOS looks up by role, without a restore and without a computer.
///
/// Writes go into the latest checkpoint in place: free blocks are taken from the space manager's
/// bitmap, the volume is registered in the container object map and superblock, and every touched
/// object gets a new Fletcher-64 checksum. Only flat (single-leaf) object maps are handled, which is
/// what newfs_apfs produces for the one-volume containers in IPSWs.
public final class APFSContainer {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notAPFS
        case unsupported(String)
        case full

        public var description: String {
            switch self {
            case .notAPFS: return "No APFS container superblock found"
            case .unsupported(let s): return "Unsupported APFS layout: \(s)"
            case .full: return "The APFS container has no free blocks left"
            }
        }
    }

    /// Volume roles (`apfs_role`).
    public enum Role: UInt16 {
        case system = 0x0001, user = 0x0002, recovery = 0x0004, vm = 0x0008, preboot = 0x0010
        case installer = 0x0020, data = 0x0040, baseband = 0x0080, update = 0x00C0
        case xart = 0x0100, hardware = 0x0140
    }

    /// A directory tree to create in the new volume, as paths relative to its root.
    public struct Tree {
        public var directories: [String]
        /// Regular files by path; their parent directories are created as needed.
        public var files: [String: Data]
        /// Owner and permissions by path; anything not listed is root:wheel, 0755 or 0644.
        public var attributes: [String: Attributes]
        public init(directories: [String], files: [String: Data] = [:], attributes: [String: Attributes] = [:]) {
            self.directories = directories
            self.files = files
            self.attributes = attributes
        }
    }

    public struct Attributes: Equatable {
        public var uid: UInt32, gid: UInt32
        /// Permission bits only (e.g. 0o755); the file type is added from the entry.
        public var mode: UInt16
        public init(uid: UInt32, gid: UInt32, mode: UInt16) {
            self.uid = uid; self.gid = gid; self.mode = mode
        }
    }

    let handle: FileHandle
    let base: UInt64                     // byte offset of the container on the disk
    public private(set) var blockSize: UInt64 = 4096
    var superblock = Data()              // latest nx_superblock
    var superblockAddress: UInt64 = 0    // its block in the checkpoint descriptor area
    var xid: UInt64 = 0

    public init(handle: FileHandle, offset: UInt64) throws {
        self.handle = handle
        base = offset
        let block0 = try read(block: 0, count: 1, size: 4096)
        let r = ByteReader(block0)
        guard r.u32(at: 32) == 0x4253_584E else { throw Error.notAPFS }       // "NXSB"
        blockSize = UInt64(r.u32(at: 36))
        try findLatestSuperblock(block0)
    }

    // MARK: Block I/O

    func read(block: UInt64, count: Int = 1, size: UInt64? = nil) throws -> Data {
        let bs = size ?? blockSize
        try handle.seek(toOffset: base + block * bs)
        let n = Int(bs) * count
        guard let d = try handle.read(upToCount: n), d.count == n else {
            throw Error.unsupported("short read at block \(block)")
        }
        return d
    }

    func write(_ data: Data, block: UInt64) throws {
        try handle.seek(toOffset: base + block * blockSize)
        handle.write(data)
    }

    /// Fletcher-64 over everything after the checksum field, stored in its first 8 bytes.
    static func checksum(_ data: Data) -> UInt64 {
        var s1: UInt64 = 0, s2: UInt64 = 0
        let mod: UInt64 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var i = 8
            while i + 4 <= buf.count {
                let w = UInt64(buf.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian)
                s1 = (s1 + w) % mod
                s2 = (s2 + s1) % mod
                i += 4
            }
        }
        let c1 = mod - ((s1 + s2) % mod)
        let c2 = mod - ((s1 + c1) % mod)
        return c2 << 32 | c1
    }

    static func seal(_ data: inout Data) {
        data.put64(0, at: 0)
        data.put64(checksum(data), at: 0)
    }

    static func valid(_ data: Data) -> Bool {
        ByteReader(data).u64(at: 0) == checksum(data)
    }

    // MARK: Checkpoint

    private func findLatestSuperblock(_ block0: Data) throws {
        let r = ByteReader(block0)
        let descBlocks = UInt64(r.u32(at: 104) & 0x7FFF_FFFF)
        let descBase = r.u64(at: 112)
        guard r.u32(at: 104) & 0x8000_0000 == 0 else {
            throw Error.unsupported("non-contiguous checkpoint descriptor area")
        }
        var best: (Data, UInt64)?
        for i in 0..<descBlocks {
            let d = try read(block: descBase + i)
            let dr = ByteReader(d)
            guard dr.u32(at: 24) & 0xFFFF == 0x0001, dr.u32(at: 32) == 0x4253_584E, Self.valid(d) else { continue }
            if best == nil || dr.u64(at: 16) > ByteReader(best!.0).u64(at: 16) { best = (d, descBase + i) }
        }
        guard let (sb, addr) = best else { throw Error.notAPFS }
        superblock = sb
        superblockAddress = addr
        xid = ByteReader(sb).u64(at: 16)
    }

    /// Ephemeral objects of the latest checkpoint: (type, oid, paddr, size in bytes).
    func checkpointMappings() throws -> [(type: UInt32, oid: UInt64, paddr: UInt64, size: UInt32)] {
        let r = ByteReader(superblock)
        let descBlocks = UInt64(r.u32(at: 104) & 0x7FFF_FFFF)
        let descBase = r.u64(at: 112)
        let index = UInt64(r.u32(at: 136)), length = UInt64(r.u32(at: 140))
        var out: [(UInt32, UInt64, UInt64, UInt32)] = []
        for i in 0..<max(length, 1) - 1 {
            let d = try read(block: descBase + (index + i) % descBlocks)
            let m = ByteReader(d)
            guard m.u32(at: 24) & 0xFFFF == 0x000C else { continue }              // checkpoint map
            for e in 0..<Int(m.u32(at: 36)) {
                let o = 40 + e * 40
                out.append((m.u32(at: o), m.u64(at: o + 24), m.u64(at: o + 32), m.u32(at: o + 8)))
            }
        }
        return out.map { (type: $0.0, oid: $0.1, paddr: $0.2, size: $0.3) }
    }

    // MARK: Space manager

    /// Takes `count` free blocks from the main device and marks them allocated.
    func allocate(_ count: Int) throws -> [UInt64] {
        let spacemanOID = ByteReader(superblock).u64(at: 152)
        guard let sm = try checkpointMappings().first(where: { $0.oid == spacemanOID }) else {
            throw Error.unsupported("space manager not in checkpoint")
        }
        let smBlocks = Int((UInt64(sm.size) + blockSize - 1) / blockSize)
        var spaceman = try read(block: sm.paddr, count: smBlocks)
        let s = ByteReader(spaceman)
        let blocksPerChunk = UInt64(s.u32(at: 36))
        let cibCount = Int(s.u32(at: 48 + 16))
        let cabCount = s.u32(at: 48 + 20)
        let addrOffset = Int(s.u32(at: 48 + 32))
        guard cabCount == 0 else { throw Error.unsupported("chunk-info address blocks") }

        var taken: [UInt64] = []
        for c in 0..<cibCount where taken.count < count {
            let cibAddr = s.u64(at: addrOffset + c * 8)
            var cib = try read(block: cibAddr)
            let cr = ByteReader(cib)
            var cibDirty = false
            for i in 0..<Int(cr.u32(at: 36)) where taken.count < count {
                let o = 40 + i * 32
                let chunkStart = cr.u64(at: o + 8)
                let chunkBlocks = UInt64(cr.u32(at: o + 16))
                let free = cr.u32(at: o + 20)
                let bitmapAddr = cr.u64(at: o + 24)
                guard free > 0, bitmapAddr != 0 else { continue }   // a chunk without bitmap is never written
                var bitmap = try read(block: bitmapAddr)
                var got: UInt32 = 0
                for b in 0..<min(chunkBlocks, blocksPerChunk) where taken.count < count {
                    let byte = Int(b / 8), bit = UInt8(1 << (b % 8))
                    guard bitmap[byte] & bit == 0 else { continue }
                    bitmap[byte] |= bit
                    taken.append(chunkStart + b)
                    got += 1
                }
                guard got > 0 else { continue }
                try write(bitmap, block: bitmapAddr)
                cib.put32(free - got, at: o + 20)
                cib.put64(xid, at: o)
                cibDirty = true
            }
            if cibDirty {
                Self.seal(&cib)
                try write(cib, block: cibAddr)
            }
        }
        guard taken.count == count else { throw Error.full }
        spaceman.put64(s.u64(at: 48 + 24) - UInt64(count), at: 48 + 24)   // sm_dev[main].sm_free_count
        Self.seal(&spaceman)
        try write(spaceman, block: sm.paddr)
        return taken
    }

    // MARK: Object map

    /// Adds a (virtual oid, xid) → paddr mapping to a flat object map.
    func addMapping(omapAddress: UInt64, oid: UInt64, paddr: UInt64) throws {
        let omap = try read(block: omapAddress)
        let treeAddr = ByteReader(omap).u64(at: 48)
        var node = try read(block: treeAddr)
        let n = ByteReader(node)
        guard n.u16(at: 32) & 0x0007 == 0x0007 else { throw Error.unsupported("multi-level object map") }
        var entries: [(key: Data, value: Data)] = try FixedNode.entries(node, blockSize: blockSize)
        var key = Data(); key.appendLE64(oid); key.appendLE64(xid)
        var value = Data(); value.appendLE32(0); value.appendLE32(UInt32(blockSize)); value.appendLE64(paddr)
        entries.append((key, value))
        entries.sort { ByteReader($0.key).u64(at: 0) < ByteReader($1.key).u64(at: 0) }
        node = try FixedNode.build(from: node, entries: entries, blockSize: blockSize)
        Self.seal(&node)
        try write(node, block: treeAddr)
    }

    /// Physical address of the newest mapping for `oid` in a physical object map B-tree.
    func omapLookup(tree: UInt64, oid: UInt64) throws -> UInt64 {
        var addr = tree
        for _ in 0..<16 {
            let node = try read(block: addr)
            let n = ByteReader(node)
            let leaf = n.u16(at: 32) & 0x2 != 0
            let entries = try FixedNode.entries(node, blockSize: blockSize)
            if leaf {
                guard let hit = entries.filter({ ByteReader($0.key).u64(at: 0) == oid })
                    .max(by: { ByteReader($0.key).u64(at: 8) < ByteReader($1.key).u64(at: 8) }) else {
                    throw Error.unsupported("oid \(oid) not in object map")
                }
                return ByteReader(hit.value).u64(at: 8)
            }
            // Index node: descend into the last child whose first key is not past `oid`.
            guard let child = entries.last(where: { ByteReader($0.key).u64(at: 0) <= oid }) else {
                throw Error.unsupported("oid \(oid) not in object map")
            }
            addr = ByteReader(child.value).u64(at: 0)
        }
        throw Error.unsupported("object map deeper than 16 levels")
    }

    // MARK: Volumes

    public var volumeOIDs: [UInt64] {
        let r = ByteReader(superblock)
        return (0..<Int(r.u32(at: 180))).map { r.u64(at: 184 + $0 * 8) }.filter { $0 != 0 }
    }

    /// Reads the superblock of a volume through the container object map.
    func volumeSuperblock(_ oid: UInt64) throws -> Data {
        let omap = try read(block: ByteReader(superblock).u64(at: 160))
        return try read(block: omapLookup(tree: ByteReader(omap).u64(at: 48), oid: oid))
    }

    /// Roles of the volumes already in the container.
    public func roles() throws -> [UInt16] {
        try volumeOIDs.map { ByteReader(try volumeSuperblock($0)).u16(at: 964) }
    }

    /// Human-readable dump of every volume: superblock fields, object maps and the records of a
    /// single-leaf file-system tree. Used to compare volumes written here with ones made by Apple.
    public func dump() throws -> [String] {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        var out: [String] = []
        for oid in volumeOIDs {
            let sb = try volumeSuperblock(oid)
            let r = ByteReader(sb)
            let name = String(decoding: sb.slice(704, 256).prefix { $0 != 0 }, as: UTF8.self)
            out.append("volume \(name) oid \(oid) role 0x\(String(r.u16(at: 964), radix: 16))")
            out.append("  sb[32..320] " + hex(sb.slice(32, 288)))
            out.append("  sb[960..1056] " + hex(sb.slice(960, 96)))
            let omap = try read(block: r.u64(at: 128))
            out.append("  omap_phys[32..88] " + hex(omap.slice(32, 56)))
            let omapTree = try read(block: ByteReader(omap).u64(at: 48))
            out.append("  omap tree hdr " + hex(omapTree.slice(24, 32)) + " info " + hex(omapTree.slice(Int(blockSize) - 40, 40)))
            let root = try read(block: omapLookup(tree: ByteReader(omap).u64(at: 48), oid: r.u64(at: 136)))
            let n = ByteReader(root)
            out.append("  fs root hdr " + hex(root.slice(8, 48)) + " info " + hex(root.slice(Int(blockSize) - 40, 40)))
            guard n.u16(at: 32) & 0x2 != 0 else { out.append("  (fs root is an index node)"); continue }
            let tocOff = 56 + Int(n.u16(at: 40)), keyStart = tocOff + Int(n.u16(at: 42))
            let valEnd = Int(blockSize) - (n.u16(at: 32) & 0x1 != 0 ? 40 : 0)
            for i in 0..<Int(n.u32(at: 36)) {
                let t = tocOff + i * 8
                let k = root.slice(keyStart + Int(n.u16(at: t)), Int(n.u16(at: t + 2)))
                let vLen = Int(n.u16(at: t + 6))
                let v = vLen == 0 ? Data() : root.slice(valEnd - Int(n.u16(at: t + 4)), vLen)
                out.append("  rec k=\(hex(k)) v=\(hex(v))")
            }
        }
        return out
    }

    /// Adds an unencrypted volume with `role`, `name` and the directories in `tree`.
    /// The new volume copies the format flags of the container's first volume.
    public func addVolume(name: String, role: Role, tree: Tree) throws {
        guard try !roles().contains(role.rawValue) else { return }
        // newfs_apfs sizes nx_max_file_systems as one volume per 512 MiB, so small containers
        // have no spare slot; the superblock has room for 100, and the limit is only advisory.
        var maxVolumes = Int(ByteReader(superblock).u32(at: 180))
        if !(0..<maxVolumes).contains(where: { ByteReader(superblock).u64(at: 184 + $0 * 8) == 0 }), maxVolumes < 100 {
            maxVolumes += 1
            superblock.put32(UInt32(maxVolumes), at: 180)
        }
        let r = ByteReader(superblock)
        guard let slot = (0..<maxVolumes).first(where: { r.u64(at: 184 + $0 * 8) == 0 }),
              let templateOID = volumeOIDs.first else { throw Error.unsupported("no free volume slot") }
        let template = try volumeSuperblock(templateOID)

        let bs = Int(blockSize)
        let filePaths = tree.files.keys.sorted()
        let dataBlocks = filePaths.reduce(0) { $0 + (tree.files[$1]!.count + bs - 1) / bs }
        let infoAt = bs - FixedNode.infoSize
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        // Format details (B-tree flags, TOC sizes, object map flags) are copied from structures
        // Apple's tools wrote: the template volume's trees and the container's object map tree.
        let tpl = ByteReader(template)
        let tplOmap = try read(block: tpl.u64(at: 128))
        let tplFSRoot = try read(block: omapLookup(tree: ByteReader(tplOmap).u64(at: 48), oid: tpl.u64(at: 136)))
        let tplExtentRef = try read(block: tpl.u64(at: 144))
        let tplSnapMeta = try read(block: tpl.u64(at: 152))
        let containerOmap = try read(block: r.u64(at: 160))
        let omapModel = try read(block: ByteReader(containerOmap).u64(at: 48))
        let fsFlags = ByteReader(tplFSRoot).u32(at: infoAt)
        let extentFlags = ByteReader(tplExtentRef).u32(at: infoAt)
        let omapFlags = ByteReader(omapModel).u32(at: infoAt)

        let templateFlags = tpl.u64(at: 56)
        let caseInsensitive = templateFlags & 0x1 != 0
        let hashedNames = caseInsensitive || templateFlags & 0x8 != 0

        // The file-system records depend on where file data lands, and the trees' shapes only on
        // the records' sizes. Lay out the file data first, then size the trees, then place them.
        var dataAddrs = try allocate(dataBlocks)
        var files: [FSTree.File] = []
        for path in filePaths {
            let data = tree.files[path]!
            let count = (data.count + bs - 1) / bs
            let mine = Array(dataAddrs.prefix(count))
            dataAddrs.removeFirst(count)
            // Each file as runs of consecutive blocks (the allocator may hand out gaps).
            var runs: [(logical: UInt64, paddr: UInt64, blocks: UInt64)] = []
            for (i, b) in mine.enumerated() {
                if let last = runs.last, last.paddr + last.blocks == b {
                    runs[runs.count - 1].blocks += 1
                } else {
                    runs.append((UInt64(i) * blockSize, b, 1))
                }
                var chunk = data.slice(i * bs, min(bs, data.count - i * bs))
                chunk.append(Data(count: bs - chunk.count))
                try write(chunk, block: b)
            }
            files.append(FSTree.File(path: path, size: UInt64(data.count), runs: runs))
        }
        let fs = FSTree(directories: tree.directories, files: files, attributes: tree.attributes, blockSize: blockSize,
                        hashedNames: hashedNames, caseInsensitive: caseInsensitive, time: now)

        let fsPlan = BTree.plan(fs.records, blockSize: bs, fixed: nil, aligned: fsFlags & 0x40 == 0)
        let extentPlan = BTree.plan(fs.extentRefs, blockSize: bs, fixed: nil, aligned: extentFlags & 0x40 == 0)
        let fsNodes = fsPlan.reduce(0) { $0 + $1.count }, extentNodes = extentPlan.reduce(0) { $0 + $1.count }
        // The volume object map maps one virtual oid per file-system tree node.
        let omapSlots = (0..<fsNodes).map { (key: Data(count: 16), value: Data(count: 16)) }
        let omapPlan = BTree.plan(omapSlots, blockSize: bs, fixed: (16, 16), aligned: false)
        let omapNodes = omapPlan.reduce(0) { $0 + $1.count }

        // Blocks: volume superblock, volume omap, its tree, fs tree, extent-ref tree, snapshot tree.
        var meta = try allocate(3 + omapNodes + fsNodes + extentNodes)
        let sbAddr = meta.removeFirst(), omapAddr = meta.removeFirst(), snapAddr = meta.removeFirst()
        let omapTreeAddrs = Array(meta.prefix(omapNodes)); meta.removeFirst(omapNodes)
        let fsTreeAddrs = Array(meta.prefix(fsNodes)); meta.removeFirst(fsNodes)
        let extentAddrs = Array(meta.prefix(extentNodes))
        let ownedBlocks = UInt64(2 + omapNodes + fsNodes + extentNodes + dataBlocks)   // all but the superblock

        // Virtual oids come from the container's counter: the volume superblock first, then the
        // file-system tree nodes (root last, as BTree numbers them).
        let volumeOID = r.u64(at: 88)                  // nx_next_oid
        let fsOIDs = (0..<UInt64(fsNodes)).map { volumeOID + 1 + $0 }
        let fsTreeOID = fsOIDs.last!

        for (node, addr) in zip(BTree.serialize(fsPlan, ids: fsOIDs, blockSize: bs, xid: xid, virtual: true,
                                                subtype: 0x0E, flags: fsFlags, fixed: nil), fsTreeAddrs) {
            var node = node
            Self.seal(&node)
            try write(node, block: addr)
        }
        for (node, addr) in zip(BTree.serialize(extentPlan, ids: extentAddrs, blockSize: bs, xid: xid, virtual: false,
                                                subtype: 0x0F, flags: extentFlags, fixed: nil), extentAddrs) {
            var node = node
            Self.seal(&node)
            try write(node, block: addr)
        }
        var snapNode = VariableNode.build(records: [], blockSize: blockSize,
                                          header: (oid: snapAddr, xid: xid, type: 0x4000_0002, subtype: 0x10),
                                          info: (flags: ByteReader(tplSnapMeta).u32(at: infoAt), keyCount: 0))
        Self.seal(&snapNode)
        try write(snapNode, block: snapAddr)

        // Volume object map: each fs tree node's oid → its block. A single leaf is laid out like
        // the container's object map tree (whose TOC newfs_apfs sizes for the whole node).
        let mappings = zip(fsOIDs, fsTreeAddrs).map {
            (key: Data.le64($0.0) + Data.le64(xid), value: Data.le32(0) + Data.le32(UInt32(blockSize)) + Data.le64($0.1))
        }
        if omapNodes == 1 {
            var model = omapModel
            model.putHeader(oid: omapTreeAddrs[0], xid: xid, type: 0x4000_0002, subtype: 0x0B)
            model.put64(1, at: infoAt + 32)                                  // bt_node_count
            var omapNode = try FixedNode.build(from: model, entries: mappings, blockSize: blockSize)
            Self.seal(&omapNode)
            try write(omapNode, block: omapTreeAddrs[0])
        } else {
            let plan = BTree.plan(mappings, blockSize: bs, fixed: (16, 16), aligned: false)
            for (node, addr) in zip(BTree.serialize(plan, ids: omapTreeAddrs, blockSize: bs, xid: xid, virtual: false,
                                                    subtype: 0x0B, flags: omapFlags, fixed: (16, 16)), omapTreeAddrs) {
                var node = node
                Self.seal(&node)
                try write(node, block: addr)
            }
        }

        var omap = Data(count: Int(blockSize))
        omap.putHeader(oid: omapAddr, xid: xid, type: 0x4000_000B, subtype: 0)
        omap.put32(ByteReader(tplOmap).u32(at: 32), at: 32)                // om_flags
        omap.put32(ByteReader(tplOmap).u32(at: 40), at: 40)                // om_tree_type
        omap.put32(ByteReader(tplOmap).u32(at: 44), at: 44)                // om_snapshot_tree_type
        omap.put64(omapTreeAddrs.last!, at: 48)
        Self.seal(&omap)
        try write(omap, block: omapAddr)

        // Volume superblock, based on the template's format fields.
        var sb = Data(count: Int(blockSize))
        sb.replaceSubrange(32..<64, with: template[template.startIndex + 32..<template.startIndex + 64])
        sb.putHeader(oid: volumeOID, xid: xid, type: 0x0000_000D, subtype: 0)
        sb.put32(UInt32(slot), at: 36)                                   // apfs_fs_index
        sb.put64(ByteReader(template).u64(at: 40) & ~UInt64(0x10), at: 40)  // no volume-group inode space
        sb.put64(0, at: 48)
        sb.put64(templateFlags & 0x9, at: 56)                            // case/normalization only
        sb.put64(now, at: 64)
        sb.put64(ownedBlocks, at: 88)                                    // fs_alloc_count (the superblock is not counted)
        sb.replaceSubrange(96..<116, with: template[template.startIndex + 96..<template.startIndex + 116])
        sb.put32(0x0000_0002, at: 116)                                   // root tree: virtual
        sb.put32(0x4000_0002, at: 120)
        sb.put32(0x4000_0002, at: 124)
        sb.put64(omapAddr, at: 128)
        sb.put64(fsTreeOID, at: 136)
        sb.put64(extentAddrs.last!, at: 144)
        sb.put64(snapAddr, at: 152)
        sb.put64(fs.nextObjectID, at: 176)
        sb.put64(UInt64(files.count), at: 184)                           // num_files
        sb.put64(UInt64(fs.directoryCount), at: 192)
        sb.put64(ownedBlocks, at: 224)                                   // total_blocks_alloced
        var uuid = UUID().uuid
        Swift.withUnsafeBytes(of: &uuid) { sb.replaceSubrange(240..<256, with: $0) }
        sb.put64(now, at: 256)
        sb.put64(0x1, at: 264)                                           // APFS_FS_UNENCRYPTED
        let by = Data("ios-emul".utf8)
        sb.replaceSubrange(272..<(272 + by.count), with: by)
        sb.put64(now, at: 304); sb.put64(xid, at: 312)
        let vname = Data(name.utf8.prefix(255))
        sb.replaceSubrange(704..<(704 + vname.count), with: vname)
        sb.put32(3, at: 960)                                             // next_doc_id (MIN_DOC_ID)
        sb.put16(role.rawValue, at: 964)
        Self.seal(&sb)
        try write(sb, block: sbAddr)

        try addMapping(omapAddress: r.u64(at: 160), oid: volumeOID, paddr: sbAddr)

        // Register the volume in the container superblock (latest checkpoint copy and block 0).
        superblock.put64(fsTreeOID + 1, at: 88)
        superblock.put64(volumeOID, at: 184 + slot * 8)
        Self.seal(&superblock)
        try write(superblock, block: superblockAddress)
        try write(superblock, block: 0)
    }
}

// MARK: - B-tree nodes

/// Fixed-size key/value B-tree leaves (object maps: 16-byte keys and values).
enum FixedNode {
    static let infoSize = 40

    static func empty(blockSize: UInt64, oid: UInt64, xid: UInt64) -> Data {
        var d = Data(count: Int(blockSize))
        d.putHeader(oid: oid, xid: xid, type: 0x4000_0002, subtype: 0x0B)
        d.put16(0x0007, at: 32)                                  // root | leaf | fixed
        // btree_info_t: BTREE_UINT64_KEYS | BTREE_SEQUENTIAL_INSERT | BTREE_PHYSICAL
        let i = Int(blockSize) - infoSize
        d.put32(0x13, at: i); d.put32(UInt32(blockSize), at: i + 4)
        d.put32(16, at: i + 8); d.put32(16, at: i + 12)
        d.put32(16, at: i + 16); d.put32(16, at: i + 20)
        d.put64(0, at: i + 24); d.put64(1, at: i + 32)
        return d
    }

    static func entries(_ node: Data, blockSize: UInt64) throws -> [(key: Data, value: Data)] {
        let n = ByteReader(node)
        let count = Int(n.u32(at: 36))
        let tocOff = 56 + Int(n.u16(at: 40)), tocLen = Int(n.u16(at: 42))
        let keyStart = tocOff + tocLen
        let valEnd = Int(blockSize) - (n.u16(at: 32) & 0x1 != 0 ? infoSize : 0)
        return (0..<count).map { i in
            let k = keyStart + Int(n.u16(at: tocOff + i * 4))
            let v = valEnd - Int(n.u16(at: tocOff + i * 4 + 2))
            return (node.slice(k, 16), node.slice(v, min(16, valEnd - v)))   // index values are 8 bytes
        }
    }

    /// Rewrites a leaf with `entries` (sorted), keeping its header and btree_info.
    static func build(from node: Data, entries: [(key: Data, value: Data)], blockSize: UInt64) throws -> Data {
        var d = node
        let bs = Int(blockSize)
        let valEnd = bs - infoSize
        let oldTocLen = Int(ByteReader(node).u16(at: 42))
        let tocLen = max(oldTocLen, ((entries.count * 4 + 63) / 64) * 64)
        let keyStart = 56 + tocLen
        guard keyStart + entries.count * 16 <= valEnd - entries.count * 16 else {
            throw APFSContainer.Error.unsupported("object map leaf is full")
        }
        d.replaceSubrange(56..<valEnd, with: Data(count: valEnd - 56))
        d.put32(UInt32(entries.count), at: 36)
        d.put16(0, at: 40); d.put16(UInt16(tocLen), at: 42)
        for (i, e) in entries.enumerated() {
            d.put16(UInt16(i * 16), at: 56 + i * 4)
            d.put16(UInt16((i + 1) * 16), at: 56 + i * 4 + 2)
            d.replaceSubrange((keyStart + i * 16)..<(keyStart + i * 16 + 16), with: e.key)
            let v = valEnd - (i + 1) * 16
            d.replaceSubrange(v..<(v + 16), with: e.value)
        }
        let used = entries.count * 16
        d.put16(UInt16(used), at: 44)                                  // free space: after the keys
        d.put16(UInt16(valEnd - keyStart - 2 * used), at: 46)
        d.put16(0xFFFF, at: 48); d.put16(0, at: 50)                    // empty key free list
        d.put16(0xFFFF, at: 52); d.put16(0, at: 54)                    // empty value free list
        d.put64(UInt64(entries.count), at: bs - infoSize + 24)          // bt_key_count
        return d
    }
}

/// Multi-level B-trees written bottom-up from sorted records.
///
/// `plan` packs the records into leaves and adds index levels until one root remains; nodes are
/// numbered leaves first, level by level, so the root is last. `serialize` writes them with the
/// ids (virtual oids or block addresses) the caller assigned in that order.
enum BTree {
    typealias Record = (key: Data, value: Data)
    /// Levels from the leaves up; each node lists its records (leaves) or children's first keys
    /// (index nodes, whose values are filled in by `serialize`).
    typealias Plan = [[[Record]]]

    static func plan(_ records: [Record], blockSize: Int, fixed: (key: Int, value: Int)?, aligned: Bool) -> Plan {
        var levels: Plan = []
        var current = records
        var leaf = true
        while true {
            var nodes: [[Record]] = []
            var node: [Record] = []
            for rec in current {
                if !node.isEmpty, !fits(node + [rec], blockSize: blockSize, root: false, leaf: leaf, fixed: fixed, aligned: aligned) {
                    nodes.append(node)
                    node = []
                }
                node.append(rec)
            }
            nodes.append(node)
            // A lone node becomes the root, which also holds the 40-byte btree_info.
            if nodes.count == 1, !fits(nodes[0], blockSize: blockSize, root: true, leaf: leaf, fixed: fixed, aligned: aligned) {
                let half = nodes[0].count / 2
                nodes = [Array(nodes[0][..<half]), Array(nodes[0][half...])]
            }
            levels.append(nodes)
            if nodes.count == 1 { return levels }
            current = nodes.map { (key: $0[0].key, value: Data(count: 8)) }
            leaf = false
        }
    }

    static func serialize(_ plan: Plan, ids: [UInt64], blockSize: Int, xid: UInt64, virtual: Bool,
                          subtype: UInt32, flags: UInt32, fixed: (key: Int, value: Int)?) -> [Data] {
        let aligned = flags & 0x40 == 0
        let leafRecords = plan[0].reduce(0) { $0 + $1.count }
        let nodeCount = plan.reduce(0) { $0 + $1.count }
        var longestKey = 0, longestValue = 0
        for node in plan[0] { for r in node { longestKey = max(longestKey, r.key.count); longestValue = max(longestValue, r.value.count) } }
        var out: [Data] = []
        var first = 0                                   // id index of this level's first node
        for (level, nodes) in plan.enumerated() {
            let childFirst = first - (level > 0 ? plan[level - 1].count : 0)
            for (i, nodeRecords) in nodes.enumerated() {
                var records = nodeRecords
                let id = ids[first + i]
                let root = level == plan.count - 1
                if level > 0 {
                    let before = nodes[..<i].reduce(0) { $0 + $1.count }
                    for j in records.indices { records[j].value = Data.le64(ids[childFirst + before + j]) }
                }
                if root, level == 0, fixed == nil {
                    out.append(VariableNode.build(records: records, blockSize: UInt64(blockSize),
                                                  header: (oid: id, xid: xid, type: (virtual ? 0 : 0x4000_0000) | 2, subtype: subtype),
                                                  info: (flags: flags, keyCount: UInt64(leafRecords))))
                    continue
                }
                var d = Data(count: blockSize)
                d.putHeader(oid: id, xid: xid, type: (virtual ? 0 : 0x4000_0000) | (root ? 2 : 3), subtype: subtype)
                d.put16((root ? 1 : 0) | (level == 0 ? 2 : 0) | (fixed != nil ? 4 : 0), at: 32)
                d.put16(UInt16(level), at: 34)
                d.put32(UInt32(records.count), at: 36)
                let end = blockSize - (root ? FixedNode.infoSize : 0)
                let toc = tocLength(records.count, blockSize: blockSize, root: root, leaf: level == 0, fixed: fixed)
                let keyStart = 56 + toc
                d.put16(0, at: 40); d.put16(UInt16(toc), at: 42)
                var k = 0, v = 0
                for (j, rec) in records.enumerated() {
                    if fixed != nil {
                        d.put16(UInt16(k), at: 56 + j * 4)
                        d.replaceSubrange((keyStart + k)..<(keyStart + k + rec.key.count), with: rec.key)
                        k += rec.key.count
                        v += rec.value.count
                        d.put16(UInt16(v), at: 56 + j * 4 + 2)
                    } else {
                        d.put16(UInt16(k), at: 56 + j * 8); d.put16(UInt16(rec.key.count), at: 56 + j * 8 + 2)
                        d.replaceSubrange((keyStart + k)..<(keyStart + k + rec.key.count), with: rec.key)
                        k += aligned ? (rec.key.count + 7) & ~7 : rec.key.count
                        v += aligned ? (rec.value.count + 7) & ~7 : rec.value.count
                        d.put16(UInt16(v), at: 56 + j * 8 + 4); d.put16(UInt16(rec.value.count), at: 56 + j * 8 + 6)
                    }
                    d.replaceSubrange((end - v)..<(end - v + rec.value.count), with: rec.value)
                }
                d.put16(UInt16(k), at: 44); d.put16(UInt16(end - keyStart - k - v), at: 46)
                d.put16(0xFFFF, at: 48); d.put16(0, at: 50)
                d.put16(0xFFFF, at: 52); d.put16(0, at: 54)
                if root {
                    let i = blockSize - FixedNode.infoSize
                    d.put32(flags, at: i); d.put32(UInt32(blockSize), at: i + 4)
                    d.put32(UInt32(fixed?.key ?? 0), at: i + 8); d.put32(UInt32(fixed?.value ?? 0), at: i + 12)
                    d.put32(UInt32(fixed?.key ?? longestKey), at: i + 16)
                    d.put32(UInt32(fixed?.value ?? longestValue), at: i + 20)
                    d.put64(UInt64(leafRecords), at: i + 24); d.put64(UInt64(nodeCount), at: i + 32)
                }
                out.append(d)
            }
            first += nodes.count
        }
        return out
    }

    /// Table of contents size: variable nodes list what they hold (in 64-byte steps); fixed nodes
    /// are sized for as many entries as the node can take, as newfs_apfs does.
    static func tocLength(_ count: Int, blockSize: Int, root: Bool, leaf: Bool, fixed: (key: Int, value: Int)?) -> Int {
        guard let fixed else { return max(64, ((count * 8 + 63) / 64) * 64) }
        let end = blockSize - (root ? FixedNode.infoSize : 0)
        let entry = 4 + fixed.key + (leaf ? fixed.value : 8)
        let capacity = (end - 56) / entry
        return max(count, capacity) * 4
    }

    static func fits(_ records: [Record], blockSize: Int, root: Bool, leaf: Bool,
                     fixed: (key: Int, value: Int)?, aligned: Bool) -> Bool {
        let end = blockSize - (root ? FixedNode.infoSize : 0)
        if let fixed {
            let entry = 4 + fixed.key + (leaf ? fixed.value : 8)
            return 56 + records.count * entry <= end
        }
        let toc = tocLength(records.count, blockSize: blockSize, root: root, leaf: leaf, fixed: nil)
        let body = records.reduce(0) { sum, r in
            sum + (aligned ? (r.key.count + 7) & ~7 : r.key.count) + (aligned ? (r.value.count + 7) & ~7 : r.value.count)
        }
        return 56 + toc + body <= end
    }
}

/// Variable-size key/value root leaves (file-system, extent-reference and snapshot trees).
enum VariableNode {
    static func build(records: [(key: Data, value: Data)], blockSize: UInt64,
                      header: (oid: UInt64, xid: UInt64, type: UInt32, subtype: UInt32),
                      info: (flags: UInt32, keyCount: UInt64)) -> Data {
        let bs = Int(blockSize)
        var d = Data(count: bs)
        d.putHeader(oid: header.oid, xid: header.xid, type: header.type, subtype: header.subtype)
        d.put16(0x0003, at: 32)                                       // root | leaf
        d.put32(UInt32(records.count), at: 36)
        let tocLen = max(64, ((records.count * 8 + 63) / 64) * 64)
        d.put16(0, at: 40); d.put16(UInt16(tocLen), at: 42)
        let keyStart = 56 + tocLen
        let valEnd = bs - FixedNode.infoSize
        var k = 0, v = 0
        var longestKey = 0, longestValue = 0
        // Keys and values are 8-byte aligned unless the tree is BTREE_KV_NONALIGNED.
        let aligned = info.flags & 0x40 == 0
        for (i, rec) in records.enumerated() {
            let toc = 56 + i * 8
            d.put16(UInt16(k), at: toc); d.put16(UInt16(rec.key.count), at: toc + 2)
            d.replaceSubrange((keyStart + k)..<(keyStart + k + rec.key.count), with: rec.key)
            k += aligned ? (rec.key.count + 7) & ~7 : rec.key.count
            v += aligned ? (rec.value.count + 7) & ~7 : rec.value.count
            d.put16(UInt16(v), at: toc + 4); d.put16(UInt16(rec.value.count), at: toc + 6)
            if !rec.value.isEmpty {
                d.replaceSubrange((valEnd - v)..<(valEnd - v + rec.value.count), with: rec.value)
            }
            longestKey = max(longestKey, rec.key.count)
            longestValue = max(longestValue, rec.value.count)
        }
        d.put16(UInt16(k), at: 44); d.put16(UInt16(valEnd - keyStart - k - v), at: 46)
        d.put16(0xFFFF, at: 48); d.put16(0, at: 50)
        d.put16(0xFFFF, at: 52); d.put16(0, at: 54)
        let i = bs - FixedNode.infoSize
        d.put32(info.flags, at: i); d.put32(UInt32(blockSize), at: i + 4)
        d.put32(0, at: i + 8); d.put32(0, at: i + 12)                  // variable sizes
        d.put32(UInt32(longestKey), at: i + 16); d.put32(UInt32(longestValue), at: i + 20)
        d.put64(info.keyCount, at: i + 24); d.put64(1, at: i + 32)
        return d
    }
}

// MARK: - File-system records

/// Inode and directory records for a tree of empty directories.
struct FSTree {
    struct File {
        let path: String
        let size: UInt64
        let runs: [(logical: UInt64, paddr: UInt64, blocks: UInt64)]
    }

    private(set) var records: [(key: Data, value: Data)] = []
    /// Physical extent records for the extent-reference tree, one per run of file data.
    private(set) var extentRefs: [(key: Data, value: Data)] = []
    private(set) var nextObjectID: UInt64 = 16
    private(set) var directoryCount = 0

    static let rootID: UInt64 = 2, privateID: UInt64 = 3
    static let typeExtent: UInt64 = 2, typeInode: UInt64 = 3, typeDStreamID: UInt64 = 6
    static let typeFileExtent: UInt64 = 8, typeDirRecord: UInt64 = 9

    init(directories: [String], files: [File] = [], attributes: [String: APFSContainer.Attributes] = [:],
         blockSize: UInt64 = 4096, hashedNames: Bool, caseInsensitive: Bool, time: UInt64) {
        // Every intermediate directory, parents before children.
        var all = Set<String>()
        let fileDirs = files.map { $0.path.split(separator: "/").dropLast().joined(separator: "/") }.filter { !$0.isEmpty }
        for path in directories + fileDirs {
            var parts: [Substring] = []
            for part in path.split(separator: "/") {
                parts.append(part)
                all.insert(parts.joined(separator: "/"))
            }
        }
        let paths = all.sorted { $0.split(separator: "/").count != $1.split(separator: "/").count
            ? $0.split(separator: "/").count < $1.split(separator: "/").count : $0 < $1 }

        var ids: [String: UInt64] = ["": Self.rootID]
        var children: [UInt64: Int] = [:]
        var drecs: [(parent: UInt64, name: String, id: UInt64)] = []
        for path in paths {
            let parent = ids[path.split(separator: "/").dropLast().joined(separator: "/")]!
            let id = nextObjectID; nextObjectID += 1
            ids[path] = id
            children[parent, default: 0] += 1
            drecs.append((parent, String(path.split(separator: "/").last!), id))
        }
        directoryCount = paths.count
        var fileIDs: [UInt64] = []
        for file in files {
            let parent = ids[file.path.split(separator: "/").dropLast().joined(separator: "/")]!
            let id = nextObjectID; nextObjectID += 1
            fileIDs.append(id)
            children[parent, default: 0] += 1
            drecs.append((parent, String(file.path.split(separator: "/").last!), id))
        }
        let fileByID = Dictionary(uniqueKeysWithValues: zip(fileIDs, files))
        var pathByID = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        for (id, file) in fileByID { pathByID[id] = file.path }

        var recs: [(sort: (UInt64, UInt64, UInt32, String), key: Data, value: Data)] = []
        func inode(_ id: UInt64, parent: UInt64, name: String, children: Int) {
            recs.append(((id, Self.typeInode, 0, ""), Data.le64(id | Self.typeInode << 60),
                         Self.inodeValue(parent: parent, id: id, name: name, children: children, time: time,
                                         file: fileByID[id], attributes: pathByID[id].flatMap { attributes[$0] },
                                         blockSize: blockSize)))
        }
        inode(Self.rootID, parent: 1, name: "root", children: children[Self.rootID] ?? 0)
        inode(Self.privateID, parent: 1, name: "private-dir", children: 0)
        // The kernel finds the root and private directories through directory records in
        // ROOT_DIR_PARENT (1), as newfs_apfs writes them; without them a mount fails with
        // "No entry for root dir".
        drecs.insert((1, "root", Self.rootID), at: 0)
        drecs.insert((1, "private-dir", Self.privateID), at: 1)
        for d in drecs {
            if d.parent != 1 {
                inode(d.id, parent: d.parent, name: d.name, children: children[d.id] ?? 0)
            }
            var key = Data.le64(d.parent | Self.typeDirRecord << 60)
            let nameBytes = Data(d.name.utf8) + Data([0])
            var hash: UInt32 = 0
            if hashedNames {
                hash = Self.nameHash(d.name, caseInsensitive: caseInsensitive)
                key.appendLE32(UInt32(nameBytes.count) & 0x3FF | hash << 10)
            } else {
                key.appendLE16(UInt16(nameBytes.count))
            }
            key.append(nameBytes)
            var value = Data.le64(d.id)
            value.appendLE64(time)
            value.appendLE16(fileByID[d.id] == nil ? 4 : 8)          // DT_DIR / DT_REG
            recs.append(((d.parent, Self.typeDirRecord, hash, d.name), key, value))
        }
        // Each file's data stream: its reference count and the extents that hold it.
        for (id, file) in fileByID {
            var refcnt = Data(); refcnt.appendLE32(1)
            recs.append(((id, Self.typeDStreamID, 0, ""), Data.le64(id | Self.typeDStreamID << 60), refcnt))
            for run in file.runs {
                var key = Data.le64(id | Self.typeFileExtent << 60); key.appendLE64(run.logical)
                var value = Data.le64(run.blocks * blockSize)        // length in bytes, no flags
                value.appendLE64(run.paddr); value.appendLE64(0)     // physical block, crypto id
                recs.append(((id, Self.typeFileExtent, UInt32(run.logical / blockSize), ""), key, value))
                var refValue = Data.le64(run.blocks | 1 << 60)       // APFS_KIND_NEW
                refValue.appendLE64(id); refValue.appendLE32(1)      // owner, refcount
                extentRefs.append((Data.le64(run.paddr | Self.typeExtent << 60), refValue))
            }
        }
        extentRefs.sort { ByteReader($0.key).u64(at: 0) & 0x0FFF_FFFF_FFFF_FFFF < ByteReader($1.key).u64(at: 0) & 0x0FFF_FFFF_FFFF_FFFF }
        recs.sort { a, b in
            if a.sort.0 != b.sort.0 { return a.sort.0 < b.sort.0 }
            if a.sort.1 != b.sort.1 { return a.sort.1 < b.sort.1 }
            if a.sort.2 != b.sort.2 { return a.sort.2 < b.sort.2 }
            return Array(a.sort.3.utf8).lexicographicallyPrecedes(Array(b.sort.3.utf8))
        }
        records = recs.map { ($0.key, $0.value) }
    }

    static func inodeValue(parent: UInt64, id: UInt64, name: String, children: Int, time: UInt64,
                           file: File? = nil, attributes: APFSContainer.Attributes? = nil,
                           blockSize: UInt64 = 4096) -> Data {
        var v = Data()
        v.appendLE64(parent); v.appendLE64(id)                       // parent, private id (= data stream id)
        for _ in 0..<4 { v.appendLE64(time) }                        // create/mod/change/access
        v.appendLE64(0x8000)                                         // internal_flags: INODE_NO_RSRC_FORK
        v.appendLE32(file == nil ? UInt32(children) : 1)             // nchildren, or nlink for a file
        v.appendLE32(0); v.appendLE32(0); v.appendLE32(0)            // protection class, write gen, bsd flags
        v.appendLE32(attributes?.uid ?? 0); v.appendLE32(attributes?.gid ?? 0)   // owner, group
        v.appendLE16((file == nil ? 0o040000 : 0o100000) | (attributes?.mode ?? (file == nil ? 0o755 : 0o644)))
        v.appendLE16(0)
        v.appendLE64(0)
        // Extended fields: the inode's name (INO_EXT_TYPE_NAME, XF_DO_NOT_COPY) and, for a file,
        // its data stream (INO_EXT_TYPE_DSTREAM, XF_SYSTEM_FIELD).
        let nameData = Data(name.utf8) + Data([0])
        let namePadded = (nameData.count + 7) & ~7
        v.appendLE16(file == nil ? 1 : 2)
        v.appendLE16(UInt16(namePadded + (file == nil ? 0 : 40)))
        v.append(4); v.append(0x02); v.appendLE16(UInt16(nameData.count))
        if file != nil { v.append(8); v.append(0x20); v.appendLE16(40) }
        v.append(nameData)
        v.append(Data(count: namePadded - nameData.count))
        if let file {
            let allocated = file.runs.reduce(0) { $0 + $1.blocks } * blockSize
            v.appendLE64(file.size); v.appendLE64(allocated)         // size, alloced_size
            v.appendLE64(0); v.appendLE64(file.size); v.appendLE64(0) // crypto id, bytes written, read
        }
        return v
    }

    /// APFS directory-entry name hash: CRC-32C of the name's UTF-32 code points, 22 bits.
    static func nameHash(_ name: String, caseInsensitive: Bool) -> UInt32 {
        var s = name.decomposedStringWithCanonicalMapping
        if caseInsensitive { s = s.lowercased() }
        var crc: UInt32 = 0xFFFF_FFFF
        for scalar in s.unicodeScalars {
            for b in Swift.withUnsafeBytes(of: scalar.value.littleEndian, Array.init) {
                crc ^= UInt32(b)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1 }
            }
        }
        return crc & 0x3F_FFFF
    }
}

// MARK: - Helpers

extension Data {
    static func le16(_ v: UInt16) -> Data { var d = Data(); d.appendLE16(v); return d }
    static func le32(_ v: UInt32) -> Data { var d = Data(); d.appendLE32(v); return d }
    static func le64(_ v: UInt64) -> Data { var d = Data(); d.appendLE64(v); return d }

    func slice(_ offset: Int, _ count: Int) -> Data {
        Data(self[(startIndex + offset)..<(startIndex + offset + count)])
    }

    mutating func put16(_ v: UInt16, at i: Int) {
        replaceSubrange((startIndex + i)..<(startIndex + i + 2), with: Swift.withUnsafeBytes(of: v.littleEndian, Array.init))
    }
    mutating func put32(_ v: UInt32, at i: Int) {
        replaceSubrange((startIndex + i)..<(startIndex + i + 4), with: Swift.withUnsafeBytes(of: v.littleEndian, Array.init))
    }
    mutating func put64(_ v: UInt64, at i: Int) {
        replaceSubrange((startIndex + i)..<(startIndex + i + 8), with: Swift.withUnsafeBytes(of: v.littleEndian, Array.init))
    }

    /// obj_phys_t without the checksum (see `APFSContainer.seal`).
    mutating func putHeader(oid: UInt64, xid: UInt64, type: UInt32, subtype: UInt32) {
        put64(oid, at: 8); put64(xid, at: 16); put32(type, at: 24); put32(subtype, at: 28)
    }
}
