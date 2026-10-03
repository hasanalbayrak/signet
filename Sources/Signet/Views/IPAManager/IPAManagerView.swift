import SwiftUI
import UniformTypeIdentifiers
import AppKit

public struct IPAManagerView: View {
    @ObservedObject var appState: SignetAppState
    @Environment(\.dismiss) private var dismiss

    public enum ManagerTab: String, CaseIterable, Identifiable {
        case extract = "Extract & Export"
        case `import` = "Import & Apply"
        case compare = "Compare Entitlements"

        public var id: String { rawValue }

        public var iconName: String {
            switch self {
            case .extract: return "square.and.arrow.up.fill"
            case .import: return "square.and.arrow.down.fill"
            case .compare: return "arrow.left.and.right.square.fill"
            }
        }
    }

    public enum EntitlementsViewMode: String, CaseIterable, Identifiable {
        case visual = "Capabilities"
        case xml = "XML Plist"
        public var id: String { rawValue }
    }

    @State private var selectedTab: ManagerTab = .extract
    @State private var viewMode: EntitlementsViewMode = .visual

    // Source IPA State (for Extraction)
    @State private var sourceIPAURL: URL?
    @State private var sourceMetadata: IPAMetadata?
    @State private var isExtractingSource: Bool = false
    @State private var sourceEntitlements: IPAEntitlements?
    @State private var sourceSearchQuery: String = ""
    @State private var sourceStatusMessage: String?

    // Target IPA State (for Import)
    @State private var targetIPAURL: URL?
    @State private var targetMetadata: IPAMetadata?
    @State private var isInspectingTarget: Bool = false
    @State private var importedEntitlements: IPAEntitlements?
    @State private var customXMLText: String = ""
    @State private var adaptTeamId: Bool = true
    @State private var adaptBundleId: Bool = true
    @State private var targetStatusMessage: String?
    @State private var isDirectSigning: Bool = false
    @State private var directSignProgress: String = ""

    // Drop states
    @State private var isSourceDropTargeted: Bool = false
    @State private var isTargetDropTargeted: Bool = false

    public init(appState: SignetAppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView()

            Divider()

            pickerTabBar()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .extract:
                        extractTabContent()
                    case .import:
                        importTabContent()
                    case .compare:
                        compareTabContent()
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: 960, minHeight: 680, idealHeight: 740)
        .onAppear {
            initializeInitialState()
        }
    }

    // MARK: - Initial State Setup

    private func initializeInitialState() {
        // If an IPA is already loaded in the main window, preload it as Source IPA
        if let mainIPA = appState.selectedIPA, sourceIPAURL == nil {
            loadSourceIPA(url: mainIPA)
        }
        // If custom entitlements are already active in appState, preload them into import tab
        if let activeEnt = appState.customEntitlements, importedEntitlements == nil {
            importedEntitlements = activeEnt
            customXMLText = activeEnt.rawXML
        }
    }

    // MARK: - Header & Tab Bar

    @ViewBuilder
    private func headerView() -> some View {
        HStack(spacing: 12) {
            ZStack {
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("IPA Manager & Entitlements Hub")
                        .font(.system(size: 15, weight: .bold))

                    if let activeCount = appState.customEntitlements?.count {
                        Text("\(activeCount) Custom Entitlements Active")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18))
                            .foregroundStyle(Color.green)
                            .clipShape(Capsule())
                    }
                }

                Text("Inspect app packages, extract entitlements from an IPA, and import or inject them into another IPA.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func pickerTabBar() -> some View {
        HStack {
            Picker("Mode", selection: $selectedTab) {
                ForEach(ManagerTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.iconName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)

            Spacer()

            if selectedTab == .extract || selectedTab == .import {
                Picker("View", selection: $viewMode) {
                    ForEach(EntitlementsViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: - Tab 1: Extract & Export Content

    @ViewBuilder
    private func extractTabContent() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Source IPA Selection Card / Drop Zone
            sourceIPAPickerCard()

            if isExtractingSource {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(sourceStatusMessage ?? "Decompressing package and analyzing entitlements...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Cancel") {
                        self.isExtractingSource = false
                        self.sourceStatusMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let meta = sourceMetadata {
                // App Overview & Package Info
                sourceAppMetadataCard(meta: meta)

                // Entitlements Viewer
                if let ent = sourceEntitlements, !ent.isEmpty {
                    entitlementsViewerCard(entitlements: ent, isSource: true)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                            Text("No entitlements found in provisioning profile or package root.")
                                .font(.system(size: 12, weight: .semibold))
                        }

                        Text("The IPA may be unsigned, decrypted, or stripped of its profile. You can attempt a deep Mach-O binary scan or create default entitlements below.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                if let url = sourceIPAURL {
                                    deepScanSourceBinary(url: url, meta: meta)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "cpu")
                                    Text("Deep Mach-O Binary Scan")
                                }
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                createEmptySourceEntitlements()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle")
                                    Text("Create Default Entitlements")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25), lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder
    private func sourceIPAPickerCard() -> some View {
        VStack(spacing: 8) {
            if let url = sourceIPAURL {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.8), Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44, height: 44)
                        Image(systemName: "doc.zipper")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Source IPA (Export Target):")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .bold))
                                .lineLimit(1)
                        }

                        Text(url.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose Other IPA...") {
                        browseForSourceIPA()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if appState.selectedIPA != nil && appState.selectedIPA != url {
                        Button("Use Active IPA") {
                            if let main = appState.selectedIPA {
                                loadSourceIPA(url: main)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
            } else {
                Button {
                    browseForSourceIPA()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.accentColor)

                        Text("Drop Source .ipa here to export entitlements")
                            .font(.system(size: 13, weight: .semibold))

                        Text("or click to select an IPA from Finder")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let active = appState.selectedIPA {
                            Button("Load Currently Active IPA (\(active.lastPathComponent))") {
                                loadSourceIPA(url: active)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSourceDropTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSourceDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isSourceDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.pathExtension.lowercased() == "ipa" else { return }
                Task { @MainActor in
                    self.loadSourceIPA(url: url)
                }
            }
            return true
        }
    }

    @ViewBuilder
    private func sourceAppMetadataCard(meta: IPAMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(meta.displayName ?? meta.fileName)
                            .font(.system(size: 14, weight: .bold))

                        if let ver = meta.version {
                            Text("v\(ver)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if let minOS = meta.minimumOSVersion {
                            Text("iOS \(minOS)+")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    HStack(spacing: 8) {
                        if let bid = meta.bundleIdentifier {
                            Text(bid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(meta.formattedSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let pkg = meta.packageDetails {
                    HStack(spacing: 8) {
                        if !pkg.frameworks.isEmpty {
                            Label("\(pkg.frameworks.count) Frameworks", systemImage: "puzzlepiece.extension")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        if !pkg.appExtensions.isEmpty {
                            Label("\(pkg.appExtensions.count) Extensions", systemImage: "square.stack.3d.up")
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Entitlements Viewer Component

    @ViewBuilder
    private func entitlementsViewerCard(entitlements: IPAEntitlements, isSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title & Badges
            HStack(spacing: 8) {
                Label("Entitlements (\(entitlements.count) Keys)", systemImage: "key.fill")
                    .font(.system(size: 12, weight: .bold))

                HStack(spacing: 4) {
                    Image(systemName: entitlements.source.iconName)
                    Text(entitlements.source.rawValue)
                }
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12))
                .foregroundStyle(Color.blue)
                .clipShape(Capsule())

                Spacer()

                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Search keys...", text: $sourceSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 120)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if viewMode == .visual {
                // Visual categorized items
                let filteredItems = entitlements.items.filter { item in
                    sourceSearchQuery.isEmpty ||
                    item.key.localizedCaseInsensitiveContains(sourceSearchQuery) ||
                    item.valueDescription.localizedCaseInsensitiveContains(sourceSearchQuery)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.category.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.key)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.primary)
                                        .textSelection(.enabled)

                                    Text(item.valueDescription)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(item.isBoolean ? (item.valueDescription == "true" ? Color.green : Color.secondary) : Color.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                }

                                Spacer()

                                Text(item.category.rawValue)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else {
                // XML Plist Text View
                ScrollView {
                    Text(entitlements.rawXML)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Action Buttons
            HStack(spacing: 10) {
                Button {
                    copyToClipboard(text: entitlements.rawXML)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy XML")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    exportEntitlementsToFile(entitlements)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.to.line")
                        Text("Export to File (.entitlements)...")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                if isSource {
                    Button {
                        // Transfer to Import Tab
                        self.importedEntitlements = entitlements
                        self.customXMLText = entitlements.rawXML
                        self.selectedTab = .import
                    } label: {
                        HStack(spacing: 5) {
                            Text("Use in Target IPA")
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    appState.setCustomEntitlements(entitlements)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Apply to Active Signet")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Tab 2: Import & Apply Content

    @ViewBuilder
    private func importTabContent() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Target IPA Selection Card / Drop Zone
            targetIPAPickerCard()

            if isInspectingTarget {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Inspecting Target IPA...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let target = targetMetadata {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Target: **\(target.displayName ?? target.fileName)** (\(target.bundleIdentifier ?? "No Bundle ID"))")
                            .font(.system(size: 11))
                        if let origEnt = target.entitlements {
                            Text("Original IPA has \(origEnt.count) entitlements. Imported entitlements will override or augment them.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Entitlements to Import
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Entitlements to Import / Inject", systemImage: "square.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .bold))

                    Spacer()

                    Button {
                        browseForEntitlementsFile()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("Import from File...")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let sourceEnt = sourceEntitlements, importedEntitlements != sourceEnt {
                        Button {
                            self.importedEntitlements = sourceEnt
                            self.customXMLText = sourceEnt.rawXML
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Re-use Source IPA")
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let currentImport = currentEffectiveEntitlements() {
                    entitlementsViewerCard(entitlements: currentImport, isSource: false)

                    // Reconcile / Adapt Options
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Import & Resigning Adaptation:")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)

                        Toggle(isOn: $adaptTeamId) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Adapt Team ID to Target Profile")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Replaces old Team ID in 'application-identifier' and 'keychain-access-groups' with active developer Team ID (\(appState.selectedTeam?.id ?? appState.certificate?.teamId ?? "Active Team")) to eliminate signature mismatch.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)

                        if targetMetadata?.bundleIdentifier != nil {
                            Toggle(isOn: $adaptBundleId) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Adapt Bundle ID to Target IPA")
                                        .font(.system(size: 11, weight: .medium))
                                    Text("Ensures 'application-identifier' matches target IPA's bundle identifier: `\(targetMetadata?.bundleIdentifier ?? "")`.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Final Action Buttons
                    HStack(spacing: 12) {
                        Button {
                            applyToActiveSession(entitlements: currentImport)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.forward.app.fill")
                                Text("Apply to Signet Active Session")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            directSignTargetIPA(entitlements: currentImport)
                        } label: {
                            HStack(spacing: 6) {
                                if isDirectSigning {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "signature")
                                }
                                Text("Sign & Export IPA Now...")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(targetIPAURL == nil || isDirectSigning || appState.certificate == nil || appState.profile == nil)
                    }
                    .padding(.top, 6)

                    if !directSignProgress.isEmpty {
                        Text(directSignProgress)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    // Empty state
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.secondary)

                        Text("No entitlements loaded for import yet.")
                            .font(.system(size: 12, weight: .semibold))

                        Text("Export entitlements from a Source IPA in the first tab, or click 'Import from File...' to choose an existing .entitlements or .plist file.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func targetIPAPickerCard() -> some View {
        VStack(spacing: 8) {
            if let url = targetIPAURL {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color.green.opacity(0.8), Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44, height: 44)
                        Image(systemName: "target")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Target IPA (Import Destination):")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .bold))
                                .lineLimit(1)
                        }

                        Text(url.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose Other IPA...") {
                        browseForTargetIPA()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
            } else {
                Button {
                    browseForTargetIPA()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.green)

                        Text("Drop Target .ipa here to apply entitlements")
                            .font(.system(size: 13, weight: .semibold))

                        Text("Choose the second IPA that will receive the imported entitlements")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isTargetDropTargeted ? Color.green.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isTargetDropTargeted ? Color.green : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url, url.pathExtension.lowercased() == "ipa" else { return }
                Task { @MainActor in
                    self.loadTargetIPA(url: url)
                }
            }
            return true
        }
    }

    // MARK: - Tab 3: Compare Entitlements Content

    @ViewBuilder
    private func compareTabContent() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Side-by-Side Entitlements Comparison")
                        .font(.system(size: 14, weight: .bold))
                    Text("Compare capabilities between Source IPA and Target IPA.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let sEnt = sourceEntitlements, let tEnt = targetMetadata?.entitlements ?? importedEntitlements {
                let allKeys = Array(Set(sEnt.dictionary.keys).union(tEnt.dictionary.keys)).sorted()

                VStack(spacing: 6) {
                    HStack {
                        Text("Entitlement Key")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Source: \(sourceMetadata?.displayName ?? "Source IPA")")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Target / Imported")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(allKeys, id: \.self) { key in
                                let sVal = sEnt.dictionary[key]
                                let tVal = tEnt.dictionary[key]
                                let isMatch = (sVal != nil && tVal != nil && sVal == tVal)
                                let isDiff = (sVal != nil && tVal != nil && sVal != tVal)

                                HStack(alignment: .top, spacing: 8) {
                                    Text(key)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(sVal != nil ? String(describing: sVal!) : "—")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(sVal != nil ? Color.primary : Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(tVal != nil ? String(describing: tVal!) : "—")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(tVal != nil ? (isDiff ? Color.orange : Color.primary) : Color.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isMatch ? Color.green.opacity(0.06) : (isDiff ? Color.orange.opacity(0.1) : Color(nsColor: .textBackgroundColor).opacity(0.3)))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.left.and.right.square")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Select both a Source IPA and a Target IPA to inspect comparison diff.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Logic & Operations

    private func loadSourceIPA(url: URL) {
        self.sourceIPAURL = url
        self.isExtractingSource = true
        self.sourceStatusMessage = "Analyzing IPA package and entitlements..."

        Task { @MainActor in
            let meta = await IPAManager.shared.inspectIPA(at: url)
            self.sourceMetadata = meta
            self.sourceEntitlements = meta.entitlements

            // Auto-populate into import tab if empty
            if self.importedEntitlements == nil, let ent = meta.entitlements {
                self.importedEntitlements = ent
                self.customXMLText = ent.rawXML
            }

            self.isExtractingSource = false
            self.sourceStatusMessage = nil

            if let ent = meta.entitlements {
                self.appState.appendLog(LogMessage(level: .success, message: "Extracted \(ent.count) entitlements from \(meta.displayName ?? meta.fileName) (\(ent.source.rawValue))"))
            } else {
                self.appState.appendLog(LogMessage(level: .warning, message: "No embedded entitlements discovered in \(meta.displayName ?? meta.fileName)."))
            }
        }
    }

    private func deepScanSourceBinary(url: URL, meta: IPAMetadata) {
        self.isExtractingSource = true
        self.sourceStatusMessage = "Performing deep Mach-O CodeSignature scan..."

        Task { @MainActor in
            if let ent = await IPAManager.shared.extractEntitlementsFromCodeSignature(ipaURL: url, executableName: meta.executableName) {
                self.sourceEntitlements = ent
                self.sourceMetadata?.entitlements = ent
                if self.importedEntitlements == nil {
                    self.importedEntitlements = ent
                    self.customXMLText = ent.rawXML
                }
                self.appState.appendLog(LogMessage(level: .success, message: "Found \(ent.count) entitlements via Mach-O deep scan!"))
            } else {
                self.appState.appendLog(LogMessage(level: .info, message: "Mach-O deep scan did not detect embedded code signature entitlements."))
            }
            self.isExtractingSource = false
            self.sourceStatusMessage = nil
        }
    }

    private func createEmptySourceEntitlements() {
        let teamId = appState.selectedTeam?.id ?? appState.certificate?.teamId ?? "TEAMID"
        let bundleId = sourceMetadata?.bundleIdentifier ?? "com.example.app"
        let defaultDict: [String: Any] = [
            "application-identifier": "\(teamId).\(bundleId)",
            "com.apple.developer.team-identifier": teamId,
            "get-task-allow": true,
            "keychain-access-groups": ["\(teamId).\(bundleId)"]
        ]
        let ent = IPAEntitlements.from(dictionary: defaultDict, source: .custom)
        self.sourceEntitlements = ent
        self.sourceMetadata?.entitlements = ent
        if self.importedEntitlements == nil {
            self.importedEntitlements = ent
            self.customXMLText = ent.rawXML
        }
    }

    private func loadTargetIPA(url: URL) {
        self.targetIPAURL = url
        self.isInspectingTarget = true

        Task {
            let meta = await IPAManager.shared.inspectIPA(at: url)
            self.targetMetadata = meta
            self.isInspectingTarget = false
        }
    }

    private func currentEffectiveEntitlements() -> IPAEntitlements? {
        guard var ent = importedEntitlements else { return nil }

        if adaptTeamId {
            let targetTeam = appState.selectedTeam?.id ?? appState.certificate?.teamId ?? ""
            let targetBundle = adaptBundleId ? targetMetadata?.bundleIdentifier : nil
            if !targetTeam.isEmpty {
                ent = ent.adapted(newTeamId: targetTeam, newBundleId: targetBundle)
            }
        }

        return ent
    }

    private func applyToActiveSession(entitlements: IPAEntitlements) {
        if let target = targetIPAURL {
            appState.applyTargetIPAWithEntitlements(targetIPA: target, entitlements: entitlements)
            dismiss()
        } else {
            appState.setCustomEntitlements(entitlements)
            dismiss()
        }
    }

    private func directSignTargetIPA(entitlements: IPAEntitlements) {
        guard let target = targetIPAURL,
              let cert = appState.certificate,
              let prof = appState.profile,
              let p12Path = cert.p12Path ?? UserDefaults.standard.string(forKey: "saved_p12_path") ?? CredentialService.shared.savedP12URL.path as String?,
              let profilePath = prof.profilePath ?? UserDefaults.standard.string(forKey: "saved_profile_path") ?? CredentialService.shared.savedProfileURL.path as String? else {
            appState.showError("Missing certificate or provisioning profile to sign.")
            return
        }

        // Open save panel for output IPA
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        let base = target.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(base)_with_custom_entitlements.ipa"
        savePanel.prompt = "Save Signed IPA"

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        isDirectSigning = true
        directSignProgress = "Signing \(target.lastPathComponent) with imported entitlements..."

        var config = appState.config
        config.ipaURL = target
        config.outputURL = outputURL
        config.customEntitlementsContent = entitlements.rawXML

        Task {
            do {
                _ = try await SignerService.shared.sign(
                    inputIPA: target,
                    outputIPA: outputURL,
                    p12Path: p12Path,
                    p12Password: appState.p12Password,
                    profilePath: profilePath,
                    config: config,
                    onProgress: { _, detail in
                        Task { @MainActor in
                            self.directSignProgress = detail
                        }
                    },
                    onLog: { log in
                        Task { @MainActor in
                            self.appState.appendLog(log)
                        }
                    }
                )
                self.isDirectSigning = false
                self.directSignProgress = "Successfully signed! Saved to: \(outputURL.lastPathComponent)"
                self.appState.appendLog(LogMessage(level: .success, message: "IPA Manager direct sign succeeded: \(outputURL.path)"))
            } catch {
                self.isDirectSigning = false
                self.directSignProgress = "Signing failed: \(error.localizedDescription)"
                self.appState.showError(error.localizedDescription)
            }
        }
    }

    private func browseForSourceIPA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.prompt = "Select Source IPA"

        if panel.runModal() == .OK, let url = panel.url {
            loadSourceIPA(url: url)
        }
    }

    private func browseForTargetIPA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.prompt = "Select Target IPA"

        if panel.runModal() == .OK, let url = panel.url {
            loadTargetIPA(url: url)
        }
    }

    private func browseForEntitlementsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "entitlements") ?? .data,
            UTType(filenameExtension: "plist") ?? .data,
            UTType(filenameExtension: "xml") ?? .plainText
        ]
        panel.prompt = "Import Entitlements"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let ent = try IPAManager.shared.importEntitlements(from: url)
                self.importedEntitlements = ent
                self.customXMLText = ent.rawXML
                appState.appendLog(LogMessage(level: .success, message: "Imported entitlements file: \(url.lastPathComponent) (\(ent.count) keys)"))
            } catch {
                appState.showError("Failed to import entitlements: \(error.localizedDescription)")
            }
        }
    }

    private func exportEntitlementsToFile(_ entitlements: IPAEntitlements) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [
            UTType(filenameExtension: "entitlements") ?? .data,
            UTType(filenameExtension: "plist") ?? .data
        ]
        let rawName = sourceMetadata?.displayName ?? sourceIPAURL?.deletingPathExtension().lastPathComponent ?? "App"
        let cleanName = rawName.replacingOccurrences(of: ".ipa", with: "", options: .caseInsensitive)
        savePanel.nameFieldStringValue = "\(cleanName).entitlements"
        savePanel.prompt = "Export Entitlements"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try IPAManager.shared.exportEntitlements(entitlements, to: url)
                appState.appendLog(LogMessage(level: .success, message: "Entitlements exported to: \(url.lastPathComponent)"))
            } catch {
                appState.showError("Failed to export entitlements: \(error.localizedDescription)")
            }
        }
    }

    private func copyToClipboard(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.appendLog(LogMessage(level: .info, message: "Entitlements XML copied to clipboard."))
    }
}
