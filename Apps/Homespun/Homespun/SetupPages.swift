// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI
import UIKit

// The building blocks of setup pages (DESIGN §7 conventions): a New York title that is a header,
// content that scrolls, and the actions in a bottom safe-area bar: one prominent button with a
// consequence line above it, and plain secondary buttons below.

/// A setup page: optional art, the title, a line under it, the content, and the bottom actions.
struct SetupScaffold<Content: View, Actions: View>: View {
    /// Decorative art above the title (Welcome).
    var art: AnyView?
    var symbol: String?
    var symbolColor: Color = Theme.accent
    var title: String
    var subtitle: String?
    /// Centred, like Looking and Still looking.
    var centered = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: centered ? .center : .leading, spacing: 16) {
                if let art { art }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(symbolColor)
                        .padding(.top, 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .displayTitle()
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                    .accessibilityIdentifier("setup.title")
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(Theme.secondaryLabel)
                        .multilineTextAlignment(centered ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 6) { actions() }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { titleFocused = true }
    }
}

extension SetupScaffold where Actions == EmptyView {
    init(symbol: String? = nil, title: String, subtitle: String? = nil, centered: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(art: nil, symbol: symbol, title: title, subtitle: subtitle, centered: centered, content: content) {
            EmptyView()
        }
    }
}

/// The page's prominent action: a rust Liquid Glass capsule with its symbol, full width.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var busy = false
    var id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BusyLabel(title: title, systemImage: systemImage, busy: busy)
                .frame(maxWidth: .infinity)
        }
        .primaryAction()
        .allowsHitTesting(!busy)
        .accessibilityIdentifier(id)
    }
}

/// A plain rust text button under the prominent one.
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .font(.body)
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44)
        .accessibilityIdentifier(id)
    }
}

/// Two secondary buttons side by side, stacked at accessibility sizes.
struct SecondaryPair<First: View, Second: View>: View {
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            first().frame(maxWidth: .infinity)
            second().frame(maxWidth: .infinity)
        }
    }
}

/// What a button changes, what stays, and how to undo it, right above the button (L3).
struct ConsequenceLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One promise on a permission page (01·1.2, 1.8): read as one element.
struct PromiseRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3).foregroundStyle(Theme.label)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A white card holding rows separated by hairlines, like an inset grouped list.
struct SetupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 58) }
                    row
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A row in a card: a rust symbol, a title with a detail line, and an optional value or chevron.
struct SetupRow: View {
    var symbol: String?
    let title: String
    var detail: String?
    var value: String?
    var monospacedDetail = false
    var chevron = false
    var titleColor: Color = Theme.label

    var body: some View {
        HStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(titleColor)
                if let detail {
                    Text(detail)
                        .font(monospacedDetail ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(monospacedDetail ? 2 : nil)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let value { Text(value).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.trailing) }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryLabel)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A row that leads somewhere: "Use hydrogen Anyway", "Connect Another Way".
struct SetupLinkRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SetupRow(symbol: symbol, title: title, detail: detail, chevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// A small section label above a card ("Also running Homespun").
struct SetupSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.secondaryLabel)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Recommended".
struct RecommendedChip: View {
    var text = "Recommended"

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
    }
}

/// A reason (✓), a trade-off (ⓘ) or a time (clock), under a recommendation.
struct ReasonRow: View {
    let reason: SetupAdvisor.Reason

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: reason.symbol)
                .font(.subheadline.weight(reason.kind == .plus ? .semibold : .regular))
                .foregroundStyle(reason.kind == .plus ? Theme.teal : Theme.secondaryLabel)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(reason.text).font(.subheadline).foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The recommended machine (01·1.5, 2.5, 3.0, 4.1): a card with a rust outline, its reasons, the
/// consequence line, and the action inside it.
struct RecommendationCard: View {
    let symbol: String
    let name: String
    let summary: String
    var chip: String? = "Recommended"
    let reasons: [SetupAdvisor.Reason]
    var consequence: String?
    let action: String
    var busy = false
    var id: String
    let perform: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 48, height: 48)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text(name).font(.title3)
                                Spacer(minLength: 4)
                                if let chip { RecommendedChip(text: chip) }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.title3)
                                if let chip { RecommendedChip(text: chip) }
                            }
                        }
                        Text(summary).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                    }
                }
                ForEach(reasons, id: \.self) { ReasonRow(reason: $0) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(([name + (chip == nil ? "" : ", recommended"), summary] + reasons.map(\.text))
                .joined(separator: ". "))
            if let consequence { ConsequenceLine(text: consequence) }
            PrimaryButton(title: action, busy: busy, id: id, action: perform)
                .accessibilityHint(consequence ?? "")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2))
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

/// A step that's done (✓), running (a ring) or waiting (a dashed circle): told apart by shape (L2).
struct StepRow: View {
    enum State { case done, running, waiting }
    let state: State
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                case .running:
                    ProgressView().controlSize(.small).tint(Theme.accent)
                case .waiting:
                    Image(systemName: "circle.dashed").foregroundStyle(Theme.tertiaryLabel)
                }
            }
            .font(.title3)
            .frame(width: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(state == .waiting ? Theme.secondaryLabel : Theme.label)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.secondaryLabel) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "done" : state == .running ? "in progress" : "waiting")
    }
}

/// A command to run on the server, in a box with a copy button.
struct CommandBox: View {
    let command: String
    var label = "Copy command"
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if command.contains("\n") {
                    // A file (compose): lines keep their indentation and scroll sideways.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command).fixedSize()
                    }
                } else {
                    Text(command).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.footnote.monospaced())
            .foregroundStyle(Theme.label)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : label)
        }
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// A numbered guide step.
struct NumberedStep<Extra: View>: View {
    let number: Int
    let title: String
    var detail: String?
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body).foregroundStyle(Theme.label)
                    .accessibilityLabel("Step \(number). \(title)")
                if let detail { Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryLabel) }
                extra()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension NumberedStep where Extra == EmptyView {
    init(number: Int, title: String, detail: String? = nil) {
        self.init(number: number, title: title, detail: detail) { EmptyView() }
    }
}

/// A countdown to a deadline, as "m:ss", updated every second.
struct CountdownText: View {
    let deadline: Date
    var format: (String) -> String = { $0 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(format(SetupAdvisor.clock(Int(deadline.timeIntervalSince(context.date).rounded(.up)))))
                .monospacedDigit()
        }
    }
}

/// The system share sheet, which says when it's done (Send Link to My Mac → Waiting).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var completed: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, done, _, _ in completed(done) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The art on Welcome and Welcome back: this iPhone, a dashed thread, and the home computer.
struct ThreadArt: View {
    var end = "house"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").font(.system(size: 44, weight: .light))
            ThreadShape()
                .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 7]))
                .overlay(alignment: .center) { Circle().frame(width: 10, height: 10).offset(y: -2) }
                .frame(height: 64)
            Image(systemName: end).font(.system(size: 44, weight: .light))
        }
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityHidden(true)
    }

    private struct ThreadShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                          control1: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY - rect.height * 0.3),
                          control2: CGPoint(x: rect.minX + rect.width * 0.65, y: rect.maxY + rect.height * 0.3))
            return path
        }
    }
}

/// An error under a field, with its fix (L6): it stays until the field changes.
struct FieldError: View {
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.red)
        } icon: {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problem: \(text)")
    }
}

/// A labelled text field in the setup style: a white rounded box, rust outline when focused, red
/// with a problem. The field itself (with its identifier and focus) is the content.
struct SetupField<Field: View>: View {
    let label: String
    var error = false
    var focused: Bool
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundStyle(Theme.secondaryLabel).padding(.leading, 16)
                .accessibilityHidden(true)
            field()
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(error ? Theme.red : focused ? Theme.accent : Theme.separator,
                                  lineWidth: focused || error ? 1.5 : 1))
        }
    }
}
