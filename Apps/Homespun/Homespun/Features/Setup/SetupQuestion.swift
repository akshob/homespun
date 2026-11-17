// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

// When no Homespun server answers, setup asks what people have at home and recommends one machine
// from the answers (DESIGN 01·3.2, 3.0, 4.1, 3.7, 3.1, 4.5; §6.2–6.3).

// MARK: 3.2 What do you have at home?

struct QuestionPage: View {
    @Bindable var flow: SetupFlow
    @State private var announced = Set<String>()

    private var hint: String? {
        if case .ask(let hint) = flow.answerAdvice { return hint }
        return nil
    }

    private var canContinue: Bool {
        if case .ask = flow.answerAdvice { return false }
        return true
    }

    /// Asked because nothing answered, rather than from "Set Up a Different Computer".
    private var nothingFound: Bool { flow.discovery.ready.isEmpty }

    var body: some View {
        SetupScaffold(title: "What do you have at home?",
                      subtitle: (nothingFound ? "No computer on this Wi‑Fi runs Homespun yet. " : "")
                        + "Choose all that apply.") {
            // Looking goes on: a server that answers late slides in here (DI-0 → DI-2).
            if let late = flow.foundAdvice?.recommended {
                HStack(spacing: 12) {
                    Image(systemName: late.symbol).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Found \(late.name)").font(.body)
                        Text(late.summary).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer()
                    Button("Use") { flow.go(.found) }
                        .buttonStyle(.glassProminent).tint(Theme.accent)
                        .accessibilityLabel("Use \(late.name)")
                        .accessibilityIdentifier("question.useFound")
                }
                .card(padding: 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            SetupCard {
                ForEach(SetupAdvisor.Answer.allCases) { answer in
                    AnswerRow(answer: answer, selected: flow.answers.contains(answer)) {
                        withAnimation(.snappy) { flow.answers = SetupAdvisor.toggle(answer, in: flow.answers) }
                    }
                }
            }
            if let hint {
                Label(hint, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("question.hint")
            }
            Button { flow.go(.notShowingUp) } label: {
                Text("Already set up Homespun Server? It isn't showing up ›").font(.subheadline)
                    .foregroundStyle(Theme.accent).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 4)
            .accessibilityLabel("Already set up Homespun Server? It isn't showing up")
            .accessibilityIdentifier("question.notShowing")
        } actions: {
            PrimaryButton(title: "Continue", systemImage: "arrow.right", id: "question.continue") {
                flow.continueWithAnswers()
            }
            .disabled(!canContinue)
            .accessibilityHint(canContinue ? "" : "Choose at least one")
            SecondaryPair {
                SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
            } second: {
                SecondaryButton(title: "Set Up Later", id: "setup.later") { flow.finish() }
            }
        }
        .animation(.default, value: flow.foundAdvice?.recommended.id)
        .task { flow.discovery.start() }
        .onChange(of: flow.foundAdvice?.recommended.id) { _, id in
            if let id, !announced.contains(id), let name = flow.foundAdvice?.recommended.name {
                announced.insert(id)
                Announce.say("Found \(name)")
            }
        }
    }

    /// A toggle row with a trailing check circle; the selected state is a trait, not just colour.
    private struct AnswerRow: View {
        let answer: SetupAdvisor.Answer
        let selected: Bool
        let toggle: () -> Void

        var body: some View {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Image(systemName: answer.symbol)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(answer.title).font(.body).foregroundStyle(Theme.label)
                        if let detail = answer.detail {
                            Text(detail).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Theme.accent : Theme.tertiaryLabel)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([answer.title, answer.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(answer == .none ? "Clears the other answers" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("answer.\(answer.rawValue)")
        }
    }
}

// MARK: 3.0 Recommended from your answers · 4.1 Recommend the NAS

struct AnswerRecommendationPage: View {
    let flow: SetupFlow

    var body: some View {
        if case .recommend(let advice) = flow.answerAdvice {
            SetupScaffold(title: advice.title) {
                RecommendationCard(symbol: advice.machine.symbol, name: advice.name, summary: advice.summary,
                                   reasons: advice.reasons, action: advice.action, id: "recommend.setUp") {
                    flow.go(.guide(advice.machine.guide))
                }
                if !advice.alternatives.isEmpty {
                    SetupSectionHeader(text: advice.alternatives.count == 1 ? "Your other answer" : "Your other answers")
                    ForEach(advice.alternatives) { alternative in
                        SetupCard {
                            SetupLinkRow(symbol: alternative.symbol, title: alternative.title, detail: alternative.detail,
                                         id: "recommend.\(alternative.id)") {
                                switch alternative.target {
                                case .machine(let machine): flow.go(.guide(machine.guide))
                                case .both: flow.go(.splitRole)
                                case .server: break
                                }
                            }
                        }
                    }
                }
                SetupCard {
                    SetupLinkRow(symbol: "qrcode", title: "Connect Another Way", id: "setup.otherWays") {
                        flow.go(.otherWays)
                    }
                }
            } actions: {
                SecondaryButton(title: "Set Up Later", id: "setup.later") { flow.finish() }
            }
            .onAppear { Announce.say(advice.title) }
        } else {
            // The answers changed underneath (Back, then a different choice).
            QuestionPage(flow: flow)
        }
    }
}

// MARK: 3.1 Set up, but not showing up

struct NotShowingUpPage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "wifi.exclamationmark", title: "Homespun Server isn't showing up",
                      subtitle: "If you've set it up on a computer at home, check these, then look again.") {
            SetupCard {
                SetupRow(symbol: "wifi", title: "Same Wi‑Fi as the server?", detail: "Guest networks can't see other devices.")
                SetupRow(symbol: "bolt.fill", title: "Is the computer on and awake?")
                SetupRow(symbol: "terminal", title: "Linux: is avahi-daemon running?")
                SetupRow(symbol: SetupAdvisor.Machine.nas.symbol, title: "NAS: does the project use host networking?")
            }
        } actions: {
            PrimaryButton(title: "Look Again", id: "setup.lookAgain") { flow.lookAgain() }
            SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
        }
    }
}

// MARK: 3.7 None of these yet

struct NoneOfThesePage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(symbol: "house", title: "Homespun needs a computer at home",
                      subtitle: "It keeps your originals on your own computer at home. Any of these works:") {
            SetupCard {
                SetupRow(symbol: "macmini", title: "A Mac", detail: "Simplest. An old Mac works too.")
                SetupRow(symbol: SetupAdvisor.Machine.nas.symbol, title: "A NAS", detail: "Lots of room, and it stays on.")
                SetupRow(symbol: "terminal", title: "A Linux computer", detail: "An old PC with Ubuntu works.")
            }
            Button {
                flow.answers = [.immich]
                flow.go(.question)
            } label: {
                Text("Run Immich somewhere? Homespun can work with it ›").font(.subheadline).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("none.immich")
        } actions: {
            ConsequenceLine(text: "Set Up Later still shows what you could free up. Nothing leaves this iPhone.")
            PrimaryButton(title: "Set Up Later", id: "setup.later") { flow.finish() }
            SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
        }
    }
}

// MARK: 4.5 Split role (later)

struct SplitRolePage: View {
    let flow: SetupFlow

    var body: some View {
        SetupScaffold(title: "Your NAS and your Mac, together") {
            HStack {
                VStack(spacing: 6) {
                    Image(systemName: SetupAdvisor.Machine.nas.symbol).font(.system(size: 44))
                    Text("originals").font(.footnote).foregroundStyle(Theme.secondaryLabel)
                }
                Rectangle().fill(.clear).frame(height: 2)
                    .overlay(Line().stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 6])).foregroundStyle(Theme.accent))
                VStack(spacing: 6) {
                    Image(systemName: "macmini").font(.system(size: 44))
                    Text("Live Photos").font(.footnote).foregroundStyle(Theme.secondaryLabel)
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                PromiseRow(symbol: SetupAdvisor.Machine.nas.symbol, title: "Your NAS keeps every original",
                           detail: "It makes the photo and video copies too.")
                PromiseRow(symbol: "macmini", title: "Your Mac compresses Live Photo motion",
                           detail: "When it's awake, so this iPhone doesn't have to.")
                PromiseRow(symbol: "iphone", title: "If the Mac is asleep, this iPhone does it",
                           detail: "As with Linux.")
            }
            RecommendedChip(text: "Coming later")
        } actions: {
            PrimaryButton(title: "Set Up the NAS First", id: "split.nas") { flow.go(.guide(.nas)) }
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}
