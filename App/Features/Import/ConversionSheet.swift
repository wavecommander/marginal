import ReaderCore
import SwiftUI

/// The Convert to PDF sheet (docs/FORMAT_IMPORT_PLAN.md, "What the sheet says"): shown in the
/// window that asked, every time an import includes a file that needs converting, before anything
/// is converted. It says what converting costs (the common block, then one block per kind of file
/// in the batch), offers the Text size for EPUB and text formats, lists the batch's files that
/// can't be imported, and ends with Cancel or Convert. There is no "don't show again".
///
/// The Library presents it for `ImportService.conversionRequest(for:)` and passes the answer
/// back (`ImportService.convert` / `.discard`); dismissing it any other way counts as Cancel.
struct ConversionSheet: View {
    let request: ConversionRequest
    let onConvert: (ConversionOptions) -> Void
    let onCancel: () -> Void

    @State private var textSize = ConversionOptions().textSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    commonBlock
                }
                ForEach(request.groups, id: \.self) { group in
                    Section {
                        groupBlock(group)
                    } header: {
                        Text(group.sheetTitle)
                    }
                }
                if request.offersTextSizeChoice {
                    Section {
                        textSizePicker
                    } header: {
                        Text("Text Size", comment: "Convert to PDF sheet: header of the text size setting.")
                    } footer: {
                        Text("Choose now. It can't be changed after converting.",
                             comment: "Convert to PDF sheet: line under the Text size setting.")
                    }
                }
                if !request.rejected.isEmpty {
                    Section {
                        rejectedBlock
                    } header: {
                        Text("Can't Be Imported", comment: "Convert to PDF sheet: header of the list of files that can't be imported.")
                    }
                }
            }
            .navigationTitle(Text("Convert to PDF?", comment: "Convert to PDF sheet: title."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel", comment: "Convert to PDF sheet: button that discards the import.")
                    }
                    .accessibilityIdentifier(AccessibilityID.Conversion.cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var options = ConversionOptions()
                        options.textSize = textSize
                        onConvert(options)
                    } label: {
                        Text("Convert", comment: "Convert to PDF sheet: button that starts converting the files.")
                    }
                    .accessibilityIdentifier(AccessibilityID.Conversion.convert)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Conversion.sheet)
    }

    // MARK: Blocks

    private var commonBlock: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Tactile Texts reads PDFs. These files will be converted to PDF copies so you can write on them, highlight them and attach notes to their pages.",
                 comment: "Convert to PDF sheet: first paragraph, the same for every format.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ConversionLimitation.common, id: \.self) {
                LimitationRow(limitation: $0, identifier: AccessibilityID.Conversion.limitation($0))
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Conversion.commonBlock)
    }

    private func groupBlock(_ group: LimitationGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(request.items(in: group)) { item in
                    IconRow(systemImage: group.systemImage) {
                        Text(verbatim: item.fileName)
                            .font(.body.weight(.semibold))
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
            }
            ForEach(ConversionLimitation.specific(to: group), id: \.self) {
                LimitationRow(limitation: $0, identifier: AccessibilityID.Conversion.limitation($0))
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Conversion.block(group))
    }

    @ViewBuilder
    private var textSizePicker: some View {
        let picker = Picker(selection: $textSize) {
            ForEach(ConversionTextSize.allCases, id: \.self) { size in
                Text(size.label).tag(size)
            }
        } label: {
            Text("Text Size", comment: "Convert to PDF sheet: accessibility label of the text size setting.")
        }
        .accessibilityIdentifier(AccessibilityID.Conversion.textSize)
        // Three segments truncate at accessibility text sizes; a list of choices does not.
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.inline).labelsHidden()
        } else {
            picker.pickerStyle(.segmented).labelsHidden()
        }
    }

    private var rejectedBlock: some View {
        ForEach(request.rejected) { file in
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(verbatim: file.fileName)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(file.error.shortReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Conversion.rejected(file.fileName))
        }
    }
}

extension ConversionTextSize {
    var label: String {
        switch self {
        case .small: String(localized: "Small", comment: "Convert to PDF sheet: text size choice.")
        case .medium: String(localized: "Medium", comment: "Convert to PDF sheet: text size choice.")
        case .large: String(localized: "Large", comment: "Convert to PDF sheet: text size choice.")
        }
    }
}

extension AccessibilityID {
    /// The Convert to PDF sheet.
    nonisolated enum Conversion {
        static let sheet = "conversion.sheet"
        static let convert = "conversion.convert"
        static let cancel = "conversion.cancel"
        /// The first block, the same for every format.
        static let commonBlock = "conversion.block.common"
        /// One block per limitation group: `conversion.block.<LimitationGroup rawValue>`.
        static func block(_ group: LimitationGroup) -> String { "conversion.block.\(group.rawValue)" }
        /// One row per limitation: `conversion.limitation.<ConversionLimitation rawValue>`.
        static func limitation(_ limitation: ConversionLimitation) -> String { "conversion.limitation.\(limitation.rawValue)" }
        static let textSize = "conversion.textSize"
        /// One row per file that can't be imported: `conversion.rejected.<file name>`.
        static func rejected(_ fileName: String) -> String { "conversion.rejected.\(fileName)" }
    }
}
