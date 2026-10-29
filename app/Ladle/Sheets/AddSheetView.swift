import LadleKit
import SwiftUI

/// The add sheet from the AddLink board: one link with a preview, or a list of links.
struct AddSheetView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sheet: AddSheetModel
    @Environment(\.palette) private var palette
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: sheet.isMany ? 14 : 18) {
            HStack {
                Text(sheet.title)
                    .font(Typeface.ui(18, .bold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.text)
                Spacer()
                Button {
                    model.closeAddSheet()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(RoundButtonStyle(kind: .glass, size: 30))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            if sheet.isMany {
                manyLinks
            } else {
                oneLink
            }

            footer
        }
        .padding(22)
        .popPanel(radius: 26)
        .onAppear { fieldFocused = true }
    }

    // MARK: One link

    private var oneLink: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Link")
                    .font(Typeface.ui(12, .semibold))
                    .foregroundStyle(palette.text2)
                HStack(spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: "link")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.text3)
                        TextField("https://", text: $sheet.text)
                            .textFieldStyle(.plain)
                            .font(Typeface.mono(12.5))
                            .foregroundStyle(palette.text)
                            .focused($fieldFocused)
                            .onSubmit { if sheet.canConfirm { sheet.confirm() } }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Capsule().fill(palette.tile))
                    .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
                    Button("Paste") { sheet.pasteFromClipboard() }
                        .buttonStyle(PillButtonStyle(kind: .glass, height: 40, horizontalPadding: 16))
                }
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 11))
                    Text(sheet.hint)
                }
                .font(Typeface.ui(12))
                .foregroundStyle(palette.text3)
                .padding(.leading, 4)
            }

            if let entry = sheet.single {
                preview(entry)
                options(entry)
            } else if sheet.showsBadLink {
                Text("That doesn’t look like a link yet. Links start with https://")
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.tile))
            }
        }
    }

    private func preview(_ entry: AddSheetModel.Entry) -> some View {
        let category = FileCategory.forFileName(entry.name)
        let ext = FileNaming.fileExtension(of: entry.name)
        return HStack(spacing: 12) {
            FileTile(category: category, badge: ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4)), size: 46, lit: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(Typeface.ui(14, .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.size.map(Format.size) ?? (entry.failure == nil ? "Checking…" : "Size unknown"))
                    Text("·")
                    Text(entry.url.host ?? "")
                    if entry.resumable == true {
                        Text("·")
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            Text("Resumable")
                        }
                        .foregroundStyle(palette.ink)
                    }
                }
                .font(Typeface.ui(12).monospacedDigit())
                .foregroundStyle(palette.text2)
                .lineLimit(1)
                if entry.plan?.alreadyDownloaded == true {
                    Text("You downloaded this link before.")
                        .font(Typeface.ui(12))
                        .foregroundStyle(palette.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .tileBox(radius: 18)
    }

    private func options(_ entry: AddSheetModel.Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                label("Save to")
                Button {
                    sheet.chooseFolder()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(palette.ink)
                        Text(sheet.folderLine(for: entry))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.text3)
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .glass, height: 36, horizontalPadding: 12, fontSize: 13, fullWidth: true))
            }
            GridRow {
                label("Start")
                PillSegmented(selection: $sheet.start, options: [(StartChoice.now, "Now"), (StartChoice.tonight, sheet.tonightLabel)])
            }
            GridRow {
                label("Speed")
                Text(sheet.connectionsLine)
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
            }
        }
    }

    // MARK: Many links

    private var manyLinks: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Links")
                        .font(Typeface.ui(12, .semibold))
                        .foregroundStyle(palette.text2)
                    Spacer()
                    (Text("Tip: ") + Text("ep-[140-150].mp3").font(Typeface.mono(11)) + Text(" adds a numbered series"))
                        .font(Typeface.ui(11.5))
                        .foregroundStyle(palette.text3)
                }
                TextEditor(text: $sheet.text)
                    .font(Typeface.mono(12))
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .focused($fieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.tile))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sheet.entries) { entry in
                        BatchRow(sheet: sheet, entry: entry, first: entry.id == sheet.entries.first?.id)
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(sheet.entries.count) * 42, 252))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label("Save to")
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(palette.ink)
                        Text(model.settings.sortIntoCategoryFolders ? "Each file goes to its category folder" : Destination.displayPath(model.settings.saveFolder().path))
                    }
                    .font(Typeface.ui(12.5))
                    .foregroundStyle(palette.text2)
                }
                GridRow {
                    label("Start")
                    PillSegmented(selection: $sheet.start, options: [(StartChoice.now, "Now"), (StartChoice.tonight, sheet.tonightLabel)])
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if sheet.isMany {
                Text(sheet.summary)
                    .font(Typeface.ui(12.5).monospacedDigit())
                    .foregroundStyle(palette.text2)
            }
            Spacer()
            Button("Cancel") { model.closeAddSheet() }
                .buttonStyle(PillButtonStyle(kind: .glass, height: 38, horizontalPadding: 16))
            Button(sheet.confirmTitle) { sheet.confirm() }
                .buttonStyle(PillButtonStyle(kind: .accent, height: 38, horizontalPadding: 18))
                .disabled(!sheet.canConfirm)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.top, 2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Typeface.ui(12))
            .foregroundStyle(palette.text2)
            .frame(width: 64, alignment: .leading)
    }
}

private struct BatchRow: View {
    @ObservedObject var sheet: AddSheetModel
    let entry: AddSheetModel.Entry
    let first: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let ext = FileNaming.fileExtension(of: entry.name)
        HStack(spacing: 10) {
            Button {
                sheet.toggle(entry)
            } label: {
                ZStack {
                    if entry.checked {
                        Circle().fill(Palette.accent)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Palette.onAccent)
                    } else {
                        Circle().strokeBorder(palette.line2, lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .accessibilityLabel("Include \(entry.name)")
            .accessibilityValue(entry.checked ? "Included" : "Skipped")
            ExtensionTile(badge: ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4)), size: 32, radius: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(Typeface.ui(13, .semibold))
                    .foregroundStyle(entry.checked ? palette.text : palette.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sheet.subtitle(for: entry))
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(palette.text3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.size.map(Format.size) ?? "")
                .font(Typeface.ui(12).monospacedDigit())
                .foregroundStyle(palette.text2)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }
}
