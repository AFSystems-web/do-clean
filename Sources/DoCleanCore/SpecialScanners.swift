import Foundation

extension CleanScanner {
    static let ignoredNames: Set<String> = [".DS_Store", ".localized", "CACHEDIR.TAG", ".CFUserTextEncoding"]

    static func matches(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    static func listDir(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []))?
            .filter { !ignoredNames.contains($0.lastPathComponent) } ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: standard

    static func standardCandidates(rule: Rule, roots: [URL]) -> [URL] {
        var out: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            switch rule.itemMode {
            case .root:
                out.append(root)
            case .children:
                var level = [root]
                for depth in 1...max(1, rule.childDepth) {
                    let next = level.flatMap { listDir($0) }
                    if depth == max(1, rule.childDepth) { level = next } else { level = next.filter(isDirectory) }
                }
                out.append(contentsOf: level)
            case .files:
                if rule.recursive {
                    let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    while let f = en?.nextObject() as? URL {
                        if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(f) }
                    }
                } else {
                    out.append(contentsOf: listDir(root).filter { !isDirectory($0) })
                }
            }
        }
        return out.filter { url in
            let n = url.lastPathComponent
            if matches(n, patterns: rule.excludeNames) { return false }
            return rule.patterns.isEmpty || matches(n, patterns: rule.patterns)
        }
    }

    // MARK: iOS DeviceSupport — everything except the newest version per folder

    /// "iPhone14,2 26.6.2 (23G90)" or "15.4 (19E241)" -> [26, 6, 2]
    static func osVersion(fromDeviceSupportName name: String) -> [Int] {
        for token in name.split(separator: " ") {
            let parts = token.split(separator: ".").map { Int($0) }
            if parts.count >= 1, parts.allSatisfy({ $0 != nil }), token.contains(".") || parts.count == 1 && Int(token)! < 100 {
                return parts.map { $0! }
            }
        }
        return []
    }

    static func versionLess(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func deviceSupportCandidates(rule: Rule, roots: [URL], env: DoCleanEnvironment) -> Candidates {
        var c = Candidates(urls: [])
        var kept: [URL] = []
        for root in roots {
            let dirs = listDir(root).filter(isDirectory)
            guard dirs.count > 1 else { kept.append(contentsOf: dirs); continue }
            let sorted = dirs.sorted { a, b in
                let va = osVersion(fromDeviceSupportName: a.lastPathComponent), vb = osVersion(fromDeviceSupportName: b.lastPathComponent)
                return va == vb ? a.lastPathComponent < b.lastPathComponent : versionLess(va, vb)
            }
            kept.append(sorted.last!)
            c.urls.append(contentsOf: sorted.dropLast())
        }
        c.protectedBytes = kept.reduce(0) { $0 + FileMeasure.measure($1).bytes }
        c.note = kept.isEmpty ? nil : "kept: " + kept.map(\.lastPathComponent).joined(separator: ", ")
        return c
    }

    // MARK: HuggingFace — one item per model / dataset / space

    static func huggingFaceCandidates(roots: [URL]) -> [URL] {
        var out: [URL] = []
        for root in roots {
            for top in listDir(root) where isDirectory(top) {
                if top.lastPathComponent == "hub" {
                    out.append(contentsOf: listDir(top).filter { u in
                        isDirectory(u) && ["models--", "datasets--", "spaces--"].contains { u.lastPathComponent.hasPrefix($0) }
                    })
                } else {
                    out.append(top) // xet, assets, ...
                }
            }
        }
        return out
    }

    // MARK: Final Cut Pro render files

    static func fcpRenderCandidates(roots: [URL]) -> [URL] {
        var out: [URL] = []
        for root in roots {
            for lib in listDir(root) where lib.pathExtension == "fcpbundle" {
                for event in listDir(lib).filter(isDirectory) {
                    for name in ["Render Files", "Motion Render Files"] {
                        let r = event.appendingPathComponent(name)
                        if isDirectory(r) { out.append(r) }
                    }
                    // Project-level renders live one level deeper: <event>/<project>/Render Files
                    for project in listDir(event).filter(isDirectory) {
                        let r = project.appendingPathComponent("Render Files")
                        if isDirectory(r) { out.append(r) }
                    }
                }
            }
        }
        return out
    }

    // MARK: node_modules by project age

    static let nodeSkip: Set<String> = ["node_modules", ".git", "Library", ".Trash", "build", "DerivedData", "Pods", ".build", "target", "vendor"]

    static func nodeModuleCandidates(rule: Rule, roots: [URL], env: DoCleanEnvironment) -> Candidates {
        var c = Candidates(urls: [])
        let fm = FileManager.default
        func projectActivity(_ dir: URL) -> Date? {
            var newest: Date?
            func bump(_ u: URL) {
                if let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
            }
            for e in listDir(dir) where e.lastPathComponent != "node_modules" { bump(e) }
            for g in ["HEAD", "index"] { bump(dir.appendingPathComponent(".git/\(g)")) }
            return newest
        }
        func walk(_ dir: URL, depth: Int) {
            if Task.isCancelled || depth > 6 { return }
            let nm = dir.appendingPathComponent("node_modules")
            if isDirectory(nm), fm.fileExists(atPath: dir.appendingPathComponent("package.json").path) {
                c.urls.append(nm)
                if let a = projectActivity(dir) { c.activity[nm.path] = a }
            }
            for child in listDir(dir) {
                let n = child.lastPathComponent
                if nodeSkip.contains(n) || n.hasPrefix(".") { continue }
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                if isDirectory(child) { walk(child, depth: depth + 1) }
            }
        }
        for root in roots where fm.fileExists(atPath: root.path) { walk(root, depth: 0) }
        return c
    }

    // MARK: Command rules

    /// "1.2GB", "850 MB", "12.5kB" -> bytes (decimal units, as docker/brew print them)
    static func parseSize(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let idx = t.firstIndex(where: { !($0.isNumber || $0 == ".") }) else { return Int64(Double(t) ?? 0) }
        let num = Double(t[..<idx]) ?? 0
        let unit = t[idx...].trimmingCharacters(in: .whitespaces).uppercased()
        let mult: Double
        switch unit.prefix(2) {
        case "KB", "K": mult = 1e3
        case "MB", "M": mult = 1e6
        case "GB", "G": mult = 1e9
        case "TB", "T": mult = 1e12
        default: mult = 1
        }
        return Int64(num * mult)
    }

    static func commandRule(rule: Rule, env: DoCleanEnvironment, onBytes: (@Sendable (Int64) -> Void)?) async -> RuleResult {
        let runner = env.runner
        func unavailable(_ why: String) -> RuleResult { RuleResult(rule: rule, status: .unavailable, message: why) }
        let tool = rule.command.first ?? ""
        guard !rule.command.isEmpty, let exe = runner.locate(tool) else { return unavailable("\(tool) not installed") }
        var bytes: Int64 = 0
        var newest: Date?
        let devices = env.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")

        switch rule.kind {
        case .simctlUnavailable:
            let out = runner.run(exe, ["simctl", "list", "devices", "unavailable", "-j"])
            guard out.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any],
                  let groups = obj["devices"] as? [String: [[String: Any]]] else { return unavailable("simctl failed") }
            for d in groups.values.joined() {
                guard let p = d["dataPath"] as? String else { continue }
                let url = URL(fileURLWithPath: p)
                guard SafetyGuard.isInside(SafetyGuard.canonical(url), of: SafetyGuard.canonical(devices)) else { continue }
                let m = FileMeasure.measure(url, onBytes: onBytes)
                bytes += m.bytes
                if let d = m.newest, d > (newest ?? .distantPast) { newest = d }
            }
        case .simctlEraseAll:
            for dev in listDir(devices).filter(isDirectory) {
                let m = FileMeasure.measure(dev.appendingPathComponent("data"), onBytes: onBytes)
                bytes += m.bytes
                if let d = m.newest, d > (newest ?? .distantPast) { newest = d }
            }
        case .brewCleanup:
            let out = runner.run(exe, ["cleanup", "-n", "--prune=all"])
            guard out.status == 0 else { return unavailable("brew failed") }
            // "This operation would free approximately 1.2GB of disk space."
            if let r = out.stdout.range(of: #"approximately\s+([\d.]+\s*[KMGT]?B)"#, options: .regularExpression) {
                let frag = out.stdout[r].replacingOccurrences(of: "approximately", with: "")
                bytes = parseSize(frag)
            }
        case .dockerPrune:
            let out = runner.run(exe, ["system", "df", "--format", "{{json .}}"])
            guard out.status == 0 else { return unavailable("docker is not running") }
            for line in out.stdout.split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let rec = o["Reclaimable"] as? String else { continue }
                bytes += parseSize(String(rec.split(separator: " ").first ?? ""))
            }
        default: break
        }
        onBytes?(0)
        let item = ScanItem(id: "cmd:\(rule.id)", name: rule.command.joined(separator: " "), path: nil, bytes: bytes,
                            fingerprint: newest, detail: "command")
        guard bytes > 0 else { return RuleResult(rule: rule, status: .empty) }
        let blockers = env.probe.runningApps(matching: rule.requiresAppClosed)
        return RuleResult(rule: rule, items: [item], status: blockers.isEmpty ? .ready : .blockedByRunningApp, blockedBy: blockers)
    }
}
