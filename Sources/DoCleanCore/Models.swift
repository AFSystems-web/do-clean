import Foundation

/// Safety tier of a rule (SPEC §1). Raw values are used in the JSON catalog and CLI.
public enum Tier: String, Codable, CaseIterable, Sendable, Comparable {
    case green, yellow, red

    private var order: Int { switch self { case .green: 0; case .yellow: 1; case .red: 2 } }
    public static func < (a: Tier, b: Tier) -> Bool { a.order < b.order }

    /// Green is pre-selected in the UI; yellow and red never are.
    public var selectedByDefault: Bool { self == .green }
}

public enum RuleCategory: String, Codable, CaseIterable, Sendable {
    case system, creative, dev, ai, personal
}

public enum Language: String, Sendable, Codable { case ru, en }

/// A user-facing string in both languages.
public struct L10n: Codable, Hashable, Sendable {
    public var ru: String
    public var en: String
    public init(ru: String, en: String) { self.ru = ru; self.en = en }
    public subscript(_ lang: Language) -> String { lang == .ru ? ru : en }
}

public enum DeletionMethod: String, Codable, Sendable {
    /// Removed permanently right away (green tier, and the Trash itself).
    case delete
    /// Moved to the Trash (yellow / red).
    case trash
    /// Runs a fixed, allow-listed command (`brew cleanup`, `simctl`, `docker prune`).
    case command
}

/// How a rule's roots are turned into scan items.
public enum ItemMode: String, Codable, Sendable {
    /// Each direct child (or descendant at `childDepth`) of a root is one item.
    case children
    /// The root itself is one item.
    case root
    /// Individual files matching `patterns` (top level only unless `recursive`).
    case files
}

/// Rules whose discovery needs more than "list a folder". Everything else is `.standard`.
public enum RuleKind: String, Codable, Sendable {
    case standard
    case deviceSupport      // all versions except the newest
    case simctlUnavailable  // `xcrun simctl delete unavailable`
    case simctlEraseAll     // `xcrun simctl erase all`
    case brewCleanup        // `brew cleanup`
    case dockerPrune        // `docker system prune`, only if docker is installed
    case nodeModules        // node_modules of projects untouched for N days
    case huggingface        // per model / dataset
    case fcpRender          // Final Cut render files inside ~/Movies/*.fcpbundle
}

/// A declarative cleanup category. Loaded from `Rules/*.json`.
public struct Rule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: L10n
    public var subtitle: L10n
    public var whySafe: L10n
    public var tier: Tier
    public var category: RuleCategory
    /// Palette key for the UI mesh blur: "adobe", "xcode", "ai", "downloads", "system".
    public var palette: String
    /// Bundle ids (trailing `*` = prefix) that must not be running. Rule is reported but not cleanable while they run.
    public var requiresAppClosed: [String]
    public var deletion: DeletionMethod
    public var kind: RuleKind
    /// Roots; `~` and `$TMPDIR` are expanded.
    public var roots: [String]
    public var itemMode: ItemMode
    public var childDepth: Int
    /// fnmatch globs on the item name. Empty = everything.
    public var patterns: [String]
    public var excludeNames: [String]
    /// Only items whose newest file is at least this old.
    public var minAgeDays: Int
    /// Keep the N newest items (by modification date).
    public var keepNewest: Int
    public var recursive: Bool
    /// Lower runs first and wins when two rules find the same path.
    public var priority: Int
    /// Fixed command for `deletion == .command`.
    public var command: [String]

    public var defaultSelected: Bool { tier.selectedByDefault }

    public init(id: String, title: L10n, subtitle: L10n = L10n(ru: "", en: ""), whySafe: L10n,
                tier: Tier, category: RuleCategory, palette: String = "system",
                requiresAppClosed: [String] = [], deletion: DeletionMethod? = nil, kind: RuleKind = .standard,
                roots: [String] = [], itemMode: ItemMode = .children, childDepth: Int = 1,
                patterns: [String] = [], excludeNames: [String] = [], minAgeDays: Int = 0,
                keepNewest: Int = 0, recursive: Bool = true, priority: Int = 100, command: [String] = []) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.whySafe = whySafe
        self.tier = tier; self.category = category; self.palette = palette
        self.requiresAppClosed = requiresAppClosed
        self.deletion = deletion ?? (tier == .green ? .delete : .trash)
        self.kind = kind; self.roots = roots; self.itemMode = itemMode; self.childDepth = childDepth
        self.patterns = patterns; self.excludeNames = excludeNames; self.minAgeDays = minAgeDays
        self.keepNewest = keepNewest; self.recursive = recursive; self.priority = priority
        self.command = command
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, whySafe, tier, category, palette, requiresAppClosed, deletion, kind, roots
        case itemMode, childDepth, patterns, excludeNames, minAgeDays, keepNewest, recursive, priority, command
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let tier = try c.decode(Tier.self, forKey: .tier)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(L10n.self, forKey: .title),
            subtitle: try c.decodeIfPresent(L10n.self, forKey: .subtitle) ?? L10n(ru: "", en: ""),
            whySafe: try c.decode(L10n.self, forKey: .whySafe),
            tier: tier,
            category: try c.decode(RuleCategory.self, forKey: .category),
            palette: try c.decodeIfPresent(String.self, forKey: .palette) ?? "system",
            requiresAppClosed: try c.decodeIfPresent([String].self, forKey: .requiresAppClosed) ?? [],
            deletion: try c.decodeIfPresent(DeletionMethod.self, forKey: .deletion),
            kind: try c.decodeIfPresent(RuleKind.self, forKey: .kind) ?? .standard,
            roots: try c.decodeIfPresent([String].self, forKey: .roots) ?? [],
            itemMode: try c.decodeIfPresent(ItemMode.self, forKey: .itemMode) ?? .children,
            childDepth: try c.decodeIfPresent(Int.self, forKey: .childDepth) ?? 1,
            patterns: try c.decodeIfPresent([String].self, forKey: .patterns) ?? [],
            excludeNames: try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? [],
            minAgeDays: try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0,
            keepNewest: try c.decodeIfPresent(Int.self, forKey: .keepNewest) ?? 0,
            recursive: try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? true,
            priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 100,
            command: try c.decodeIfPresent([String].self, forKey: .command) ?? [])
    }
}
