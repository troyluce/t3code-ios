import SwiftUI

struct ModelPickerSheet: View {
    let providers: [ServerProvider]
    let currentSelection: ModelSelection?
    let accentColor: Color
    let onSelect: (ServerProvider, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderId: ProviderInstanceID?

    private var usableProviders: [ServerProvider] {
        providers
            .filter(\.isUsable)
            .sorted {
                let brandCmp = $0.brandDisplayName.localizedCaseInsensitiveCompare($1.brandDisplayName)
                if brandCmp != .orderedSame { return brandCmp == .orderedAscending }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
    }

    private var selectedProvider: ServerProvider? {
        guard let id = selectedProviderId else { return usableProviders.first }
        return usableProviders.first { $0.instanceId == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                providerSelector
                Divider().overlay(T3Color.separator)
                modelList
            }
            .background(T3Color.surfaceGrouped)
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.medium)
                }
            }
            .task {
                if selectedProviderId == nil {
                    selectedProviderId = currentSelection?.instanceId
                        ?? usableProviders.first?.instanceId
                }
            }
        }
    }

    private var providerSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: T3Spacing.sm) {
                ForEach(usableProviders) { provider in
                    providerChip(provider)
                }
            }
            .padding(.horizontal, T3Spacing.lg)
            .padding(.vertical, T3Spacing.md)
        }
    }

    private func providerChip(_ provider: ServerProvider) -> some View {
        let isSelected = selectedProviderId == provider.instanceId
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedProviderId = provider.instanceId
            }
        } label: {
            HStack(spacing: 6) {
                ProviderIcon(driver: provider.driver, size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.brandDisplayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    Text(provider.label)
                        .font(.system(size: 10))
                        .foregroundStyle(T3Color.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, T3Spacing.md)
            .padding(.vertical, T3Spacing.sm)
            .background(isSelected ? accentColor.opacity(0.14) : T3Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.md, style: .continuous)
                    .stroke(isSelected ? accentColor.opacity(0.40) : T3Color.separator,
                            lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelList: some View {
        if let provider = selectedProvider {
            let sections = providerSections(provider)
            if sections.isEmpty {
                emptyModels
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(section.entries) { entry in
                                        modelRow(entry)
                                        if entry.id != section.entries.last?.id {
                                            Divider()
                                                .overlay(T3Color.separator)
                                                .padding(.leading, T3Spacing.xxl + T3Spacing.lg)
                                        }
                                    }
                                }
                                .background(T3Color.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                                        .stroke(T3Color.separator, lineWidth: 0.5)
                                )
                                .padding(.horizontal, T3Spacing.lg)
                            } header: {
                                sectionHeader(section)
                                    .padding(.horizontal, T3Spacing.lg)
                            }
                        }
                    }
                    .padding(.vertical, T3Spacing.md)
                }
            }
        } else {
            emptyModels
        }
    }

    private func sectionHeader(_ section: ModelCatalogSection) -> some View {
        Text(section.headerTitle)
            .font(T3Typography.caption)
            .foregroundStyle(T3Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, T3Spacing.sm)
            .padding(.top, T3Spacing.xs)
            .background(T3Color.surfaceGrouped)
    }

    private var emptyModels: some View {
        VStack(spacing: T3Spacing.md) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(T3Color.textTertiary)
            Text("暂无可用模型")
                .font(T3Typography.callout)
                .foregroundStyle(T3Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        Button {
            onSelect(entry.provider, entry.model.slug)
            dismiss()
        } label: {
            HStack(spacing: T3Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.model.label)
                        .font(T3Typography.body)
                        .foregroundStyle(T3Color.textPrimary)
                    HStack(spacing: 5) {
                        ProviderIcon(driver: entry.provider.driver, size: 11)
                        Text(modelRowSubtitle(entry))
                            .font(T3Typography.caption)
                            .foregroundStyle(T3Color.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: T3Spacing.sm)
                if isSelected(entry) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, T3Spacing.lg)
            .padding(.vertical, T3Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRowSubtitle(_ entry: ModelCatalogEntry) -> String {
        let brand = entry.provider.brandDisplayName
        if entry.provider.driver == "opencode" {
            if let sp = entry.model.subProvider?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sp.isEmpty {
                return "\(brand) · \(sp)"
            }
            if let bucket = entry.opencodeBucket, bucket != .standard {
                return "\(brand) · \(bucket.sectionSuffix)"
            }
        }
        if let upstream = entry.provider.upstreamVendorLabel(forModelSlug: entry.model.slug) {
            return "\(brand) · \(upstream)"
        }
        return brand
    }

    private func isSelected(_ entry: ModelCatalogEntry) -> Bool {
        guard let current = currentSelection else { return false }
        return current.instanceId == entry.provider.instanceId
            && current.model == entry.model.slug
    }

    private func providerSections(_ provider: ServerProvider) -> [ModelCatalogSection] {
        ModelCatalogSection.grouped(providers: [provider])
    }
}
