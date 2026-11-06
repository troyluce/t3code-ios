import Foundation

struct ServerRuntimeConfig: Decodable, Sendable {
    let providers: [ServerProvider]
}

struct ServerProvider: Decodable, Hashable, Identifiable, Sendable {
    let instanceId: ProviderInstanceID
    let driver: String
    let displayName: String?
    let enabled: Bool
    let installed: Bool
    let status: String
    let auth: ServerProviderAuth
    let models: [ServerProviderModel]
    let showInteractionModeToggle: Bool?

    var id: ProviderInstanceID { instanceId }

    var isUsable: Bool {
        enabled && installed && auth.status != "unauthenticated"
    }

    var label: String {
        displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? displayName!
            : driver.providerDisplayName
    }
}

struct ServerProviderAuth: Decodable, Hashable, Sendable {
    let status: String
    let label: String?
    let email: String?
}

struct ServerProviderModel: Decodable, Hashable, Identifiable, Sendable {
    let slug: String
    let name: String
    let shortName: String?
    /// OpenCode: upstream catalog name (Zen, Go, GitHub Copilot, …) — matches desktop `ServerProviderModel.subProvider`.
    let subProvider: String?
    let isCustom: Bool
    /// When the desktop server sends tier/catalog hints (Zen vs Go, etc.).
    let tier: String?
    let catalog: String?
    let bundle: String?
    /// When `false`, the model is hidden from pickers (server marks unusable for this account).
    let eligible: Bool?

    var id: String { slug }
    var label: String { shortName ?? name }

    enum CodingKeys: String, CodingKey {
        case slug, name, shortName, subProvider, isCustom
        case tier, catalog, bundle
        case subscription, routing, channel, offer
        case eligible, available, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName)
        if let raw = try c.decodeIfPresent(String.self, forKey: .subProvider)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            subProvider = raw
        } else {
            subProvider = nil
        }
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false

        tier = try Self.decodeFirstString(c, keys: [.tier, .subscription, .routing, .channel, .offer])
        catalog = try c.decodeIfPresent(String.self, forKey: .catalog)
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle)

        eligible = try Self.decodeFirstBool(c, keys: [.eligible, .available, .enabled])
    }

    private static func decodeFirstString(_ c: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) throws -> String? {
        for k in keys {
            if let v = try c.decodeIfPresent(String.self, forKey: k)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !v.isEmpty {
                return v
            }
        }
        return nil
    }

    private static func decodeFirstBool(_ c: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) throws -> Bool? {
        for k in keys {
            if let v = try c.decodeIfPresent(Bool.self, forKey: k) { return v }
        }
        return nil
    }
}

/// OpenCode may surface the same logical model through Zen, Go, or direct API routing — used for submenu grouping.
enum OpenCodeRoutingBucket: String, Hashable, Sendable {
    case zen
    case go
    case standard
    case other

    static func fromMetadata(tier: String?, catalog: String?, bundle: String?, subProvider: String? = nil) -> OpenCodeRoutingBucket? {
        let bits = [tier, catalog, bundle, subProvider].compactMap { $0?.lowercased() }
        for raw in bits {
            if raw.contains("zen") { return .zen }
        }
        for raw in bits {
            if raw.contains("google") { continue }
            if raw == "go"
                || raw.hasPrefix("go/")
                || raw.hasSuffix("/go")
                || raw.contains(" opencode go")
                || raw == "opencode-go" {
                return .go
            }
        }
        return nil
    }

    /// Path-based routing, e.g. `zen/openai/gpt-5` vs `go/kimi/...` vs `openai/gpt-5`.
    static func fromSlugPrefix(_ slug: String) -> OpenCodeRoutingBucket? {
        guard let slash = slug.firstIndex(of: "/") else { return nil }
        switch String(slug[..<slash]).lowercased() {
        case "zen": return .zen
        case "go": return .go
        default: return nil
        }
    }

    var sectionSuffix: String {
        switch self {
        case .zen: return "Zen"
        case .go: return "Go"
        case .standard: return "标准路由"
        case .other: return "其他"
        }
    }

    /// Order for submenu sections in the model picker.
    static let allCasesInOrder: [OpenCodeRoutingBucket] = [.zen, .go, .standard, .other]
}

extension ServerProviderModel {
    func opencodeRoutingBucket() -> OpenCodeRoutingBucket {
        if let fromMeta = OpenCodeRoutingBucket.fromMetadata(tier: tier, catalog: catalog, bundle: bundle, subProvider: subProvider) {
            return fromMeta
        }
        if let fromSlug = OpenCodeRoutingBucket.fromSlugPrefix(slug) {
            return fromSlug
        }
        return .standard
    }
}

extension ServerProvider {
    var defaultModel: String {
        models.first(where: { !$0.isCustom && $0.eligible != false })?.slug
            ?? models.first(where: { $0.eligible != false })?.slug
            ?? models.first?.slug
            ?? defaultModelSlug(for: driver)
    }

    func modelLabel(_ slug: String) -> String {
        models.first { $0.slug == slug }?.label ?? slug
    }

    /// User-visible product name for the integration (Anthropic, Cursor, OpenCode, …).
    var brandDisplayName: String {
        switch driver {
        case "claudeAgent":
            return "Anthropic"
        case "cursor":
            return "Cursor"
        case "opencode":
            return "OpenCode"
        case "openaiChat", "openAIChat", "openai":
            return "OpenAI"
        case "gemini", "googleGemini":
            return "Google"
        default:
            return driver.providerDisplayName
        }
    }

    /// OpenCode uses `upstreamVendor/model` slugs — returns the upstream API vendor when parseable.
    func upstreamVendorLabel(forModelSlug slug: String) -> String? {
        guard driver == "opencode" else { return nil }
        let routed = Self.opencodeUpstreamSlug(slug)
        guard let slash = routed.firstIndex(of: "/") else { return nil }
        let prefix = String(routed[..<slash]).lowercased()
        return Self.opencodeVendorTitle(prefix)
    }

    /// Strips leading `zen/` or `go/` routing prefixes before resolving vendor/model.
    static func opencodeUpstreamSlug(_ slug: String) -> String {
        guard let slash = slug.firstIndex(of: "/") else { return slug }
        switch String(slug[..<slash]).lowercased() {
        case "zen", "go":
            let rest = slug[slug.index(after: slash)...]
            return rest.isEmpty ? slug : String(rest)
        default:
            return slug
        }
    }

    private static func opencodeVendorTitle(_ raw: String) -> String {
        switch raw {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google", "gemini": return "Google"
        case "groq": return "Groq"
        case "x-ai", "xai": return "xAI"
        case "mistralai", "mistral": return "Mistral"
        case "deepseek": return "DeepSeek"
        case "meta-llama", "meta": return "Meta"
        case "cohere": return "Cohere"
        default:
            return raw
                .split(separator: "-")
                .map(\.capitalized)
                .joined(separator: " ")
        }
    }

    private func defaultModelSlug(for driver: String) -> String {
        switch driver {
        case "claudeAgent":
            return "claude-sonnet-4-6"
        case "cursor":
            return "auto"
        case "opencode":
            return "openai/gpt-5"
        default:
            return "gpt-5.4"
        }
    }
}

extension ServerRuntimeConfig {
    func modelDisplayLabel(selection: ModelSelection) -> String {
        guard let provider = providers.first(where: { $0.instanceId == selection.instanceId }) else {
            return selection.model
        }
        return provider.modelLabel(selection.model)
    }
}

/// One selectable row in model pickers: a concrete model on a specific provider instance.
struct ModelCatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ServerProvider
    let model: ServerProviderModel

    /// Zen / Go / Standard — for subsection titles and row badges.
    var opencodeBucket: OpenCodeRoutingBucket? {
        guard provider.driver == "opencode" else { return nil }
        return model.opencodeRoutingBucket()
    }

    /// Short badge when metadata names the offer (server may send tier/catalog beyond slug parsing).
    var opencodeOfferBadge: String? {
        guard provider.driver == "opencode" else { return nil }
        if let sp = model.subProvider, !sp.isEmpty { return sp }
        let meta = [model.tier, model.catalog, model.bundle].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return meta.first
    }

    static func sortedCatalog(providers: [ServerProvider]) -> [ModelCatalogEntry] {
        let usable = providers.filter(\.isUsable).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        var rows: [ModelCatalogEntry] = []
        for p in usable {
            for m in p.models where m.eligible != false {
                rows.append(ModelCatalogEntry(
                    id: "\(p.instanceId.rawValue)|\(m.slug)",
                    provider: p,
                    model: m
                ))
            }
        }
        rows.sort {
            let nameCmp = $0.model.label.localizedCaseInsensitiveCompare($1.model.label)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return $0.provider.label.localizedCaseInsensitiveCompare($1.provider.label) == .orderedAscending
        }
        return rows
    }

    /// Secondary line when models are listed in a flat menu (no section headers).
    var pickerSubtitle: String {
        let brand = provider.brandDisplayName
        var parts: [String] = [brand]
        if provider.driver == "opencode", let sp = model.subProvider, !sp.isEmpty {
            parts.append(sp)
        } else if provider.driver == "opencode", let b = opencodeBucket {
            parts.append(b.sectionSuffix)
        }
        if let upstream = provider.upstreamVendorLabel(forModelSlug: model.slug) {
            parts.append(upstream)
        }
        parts.append(provider.label)
        return parts.joined(separator: " · ")
    }
}

/// Models grouped by configured provider instance — OpenCode is further split by Zen / Go / routing bucket.
struct ModelCatalogSection: Identifiable, Sendable {
    /// Stable across subsections (OpenCode uses provider id + bucket).
    let sectionId: String
    let provider: ServerProvider
    let entries: [ModelCatalogEntry]
    /// When set, appended to the header (Zen, Go, Standard routing, …).
    let headerSuffix: String?

    var id: String { sectionId }

    var headerTitle: String {
        let base = "\(provider.brandDisplayName) · \(provider.label)"
        if let headerSuffix {
            return "\(base) · \(headerSuffix)"
        }
        return base
    }

    static func grouped(providers: [ServerProvider]) -> [ModelCatalogSection] {
        let usable = providers
            .filter(\.isUsable)
            .sorted {
                let brandCmp = $0.brandDisplayName.localizedCaseInsensitiveCompare($1.brandDisplayName)
                if brandCmp != .orderedSame { return brandCmp == .orderedAscending }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }

        var sections: [ModelCatalogSection] = []

        for p in usable {
            let rawEntries: [ModelCatalogEntry] = p.models
                .filter { $0.eligible != false }
                .map { m in
                    ModelCatalogEntry(
                        id: "\(p.instanceId.rawValue)|\(m.slug)",
                        provider: p,
                        model: m
                    )
                }

            guard !rawEntries.isEmpty else { continue }

            if p.driver != "opencode" {
                let sorted = rawEntries.sorted {
                    $0.model.label.localizedCaseInsensitiveCompare($1.model.label) == .orderedAscending
                }
                sections.append(ModelCatalogSection(
                    sectionId: p.instanceId.rawValue,
                    provider: p,
                    entries: sorted,
                    headerSuffix: nil
                ))
                continue
            }

            // Desktop sends `subProvider` per model (OpenCode inventory provider name — Zen, Go, Copilot, …).
            let subProviderKeys = Set(
                rawEntries.compactMap { $0.model.subProvider?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            if !subProviderKeys.isEmpty {
                let groups = Dictionary(grouping: rawEntries) { entry -> String in
                    let s = entry.model.subProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return s.isEmpty ? "__none__" : s
                }
                let orderedKeys = groups.keys.sorted { a, b in
                    if a == "__none__" { return false }
                    if b == "__none__" { return true }
                    return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
                let nonEmptyKeys = orderedKeys.filter { $0 != "__none__" }
                let shouldShowSuffix = nonEmptyKeys.count > 1 || (orderedKeys.contains("__none__") && !nonEmptyKeys.isEmpty)

                for key in orderedKeys {
                    guard var items = groups[key] else { continue }
                    items.sort {
                        $0.model.label.localizedCaseInsensitiveCompare($1.model.label) == .orderedAscending
                    }
                    let label = key == "__none__" ? "其他" : key
                    let suffix: String? = shouldShowSuffix ? label : nil
                    let sid = "\(p.instanceId.rawValue)|\(key)"
                    sections.append(ModelCatalogSection(
                        sectionId: sid,
                        provider: p,
                        entries: items,
                        headerSuffix: suffix
                    ))
                }
            } else {
                let buckets = Dictionary(grouping: rawEntries) { $0.model.opencodeRoutingBucket() }
                let orderedBuckets = OpenCodeRoutingBucket.allCasesInOrder.filter { buckets[$0] != nil }

                let shouldShowSuffix = !(orderedBuckets.count == 1 && orderedBuckets.first == .standard)

                for bucket in orderedBuckets {
                    guard var items = buckets[bucket] else { continue }
                    items.sort {
                        $0.model.label.localizedCaseInsensitiveCompare($1.model.label) == .orderedAscending
                    }
                    let suffix: String? = shouldShowSuffix ? bucket.sectionSuffix : nil

                    let sid = "\(p.instanceId.rawValue)|\(bucket.rawValue)"
                    sections.append(ModelCatalogSection(
                        sectionId: sid,
                        provider: p,
                        entries: items,
                        headerSuffix: suffix
                    ))
                }
            }
        }

        return sections
    }
}

private extension String {
    var providerDisplayName: String {
        replacingOccurrences(of: "([a-z])([A-Z])",
                              with: "$1 $2",
                              options: .regularExpression)
            .replacingOccurrences(of: "[-_]+",
                                  with: " ",
                                  options: .regularExpression)
            .capitalized
    }
}
