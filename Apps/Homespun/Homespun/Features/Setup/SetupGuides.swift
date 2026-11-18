// SPDX-License-Identifier: Apache-2.0
import HomespunCore
import SwiftUI

// Setting Homespun Server up on the machine chosen from the answers (DESIGN 01·3.3, 3.6, 4.2, 4.3),
// then waiting for it to show up on the Wi‑Fi (3.4, 4.4). Today the server is built from source
// on a Mac or Linux; homespun.photos/setup has the same steps.

/// The page with every step, for sending to the computer.
private let setupPage = URL(string: "https://homespun.photos/setup")!

/// The steps up to starting the server; pairing happens in the app.
private func buildSteps(_ os: ServerSetup.OperatingSystem, _ manager: ServerSetup.PackageManager? = nil) -> [ServerSetup.Step] {
    ServerSetup.installSteps(for: os, packageManager: manager).filter { !$0.commands.isEmpty && !$0.title.contains("pair") }
}

private func stepsText(_ steps: [ServerSetup.Step]) -> String {
    steps.enumerated().map { index, step in
        "# \(index + 1). \(step.title)\n" + step.commands.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

// MARK: 3.3 Set up on a Mac

struct MacGuidePage: View {
    let flow: SetupFlow
    @State private var sharing = false

    var body: some View {
        SetupScaffold(title: "Set up Homespun on your Mac") {
            VStack(alignment: .leading, spacing: 18) {
                NumberedStep(number: 1, title: "Get the steps on your Mac",
                             detail: "Send the link to your Mac with AirDrop or Messages, or open homespun.photos/setup "
                                + "there.")
                NumberedStep(number: 2, title: "Run them, and choose where originals go",
                             detail: "A folder on the Mac or an attached drive. Homespun Server starts with the Mac from "
                                + "then on.")
                NumberedStep(number: 3, title: "Come back here",
                             detail: "This iPhone finds the Mac on your Wi‑Fi. Then click Allow on the Mac.")
            }
            .padding(.top, 8)
        } actions: {
            PrimaryButton(title: "Send Link to My Mac", systemImage: "square.and.arrow.up", id: "guide.send") {
                sharing = true
            }
            SecondaryButton(title: "Show Terminal Steps", id: "guide.terminal") { flow.go(.terminalSteps(.macOS)) }
            Text("For now Homespun Server is built from source in Terminal. It takes about 15 minutes.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [setupPage]) { done in
                sharing = false
                if done { flow.go(.waiting(.macDesktop)) }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Today's build-from-source steps, with a copy button on each command.
struct TerminalStepsPage: View {
    let flow: SetupFlow
    let os: ServerSetup.OperatingSystem

    var body: some View {
        let steps = buildSteps(os)
        SetupScaffold(title: os == .macOS ? "In Terminal on your Mac" : "In a terminal on your computer") {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                NumberedStep(number: index + 1, title: step.title, detail: step.detail) {
                    ForEach(step.commands, id: \.self) { CommandBox(command: $0) }
                }
            }
        } actions: {
            PrimaryButton(title: "I've Done This", systemImage: "checkmark", id: "guide.done") {
                flow.go(.waiting(os == .macOS ? .macDesktop : .linux))
            }
            ShareLink(item: stepsText(steps), subject: Text("Homespun Server setup")) {
                Label("Send These Steps", systemImage: "square.and.arrow.up")
            }
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 44)
        }
    }
}

// MARK: 3.6 Set up on Linux

struct LinuxGuidePage: View {
    let flow: SetupFlow
    @State private var manager = ServerSetup.PackageManager.apt
    @State private var sharing = false

    var body: some View {
        let steps = buildSteps(.linux, manager)
        SetupScaffold(title: "Set up Homespun on Linux") {
            Picker("Distribution", selection: $manager) {
                Text("Ubuntu").tag(ServerSetup.PackageManager.apt)
                Text("Fedora").tag(ServerSetup.PackageManager.dnf)
                Text("Arch").tag(ServerSetup.PackageManager.pacman)
                Text("openSUSE").tag(ServerSetup.PackageManager.zypper)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("guide.distribution")
            Text("On the Linux computer, open a terminal and run these:")
                .font(.body).foregroundStyle(Theme.secondaryLabel)
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                NumberedStep(number: index + 1, title: step.title, detail: step.detail) {
                    ForEach(step.commands, id: \.self) { CommandBox(command: $0) }
                }
            }
            Text("They install what Homespun needs (libvips, ffmpeg, avahi), build the server and start its service. "
                 + "It takes about 15 minutes.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel)
        } actions: {
            PrimaryButton(title: "Send Commands to My Computer", systemImage: "square.and.arrow.up", id: "guide.send") {
                sharing = true
            }
            SecondaryButton(title: "I've Done This", id: "guide.done") { flow.go(.waiting(.linux)) }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(items: [stepsText(steps)]) { done in
                sharing = false
                if done { flow.go(.waiting(.linux)) }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: 4.2 Which NAS?

struct NASBrandsPage: View {
    let flow: SetupFlow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SetupScaffold(title: "Which NAS do you have?",
                      subtitle: "Homespun Server runs on it in Docker. Choose the brand for its exact steps.") {
            // A few brands: all laid out at once (no lazy grid guessing sizes).
            let brands = Array(NASBrand.allCases), columns = typeSize.isAccessibilitySize ? 1 : 2
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: brands.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(brands[start..<min(start + columns, brands.count)]) { brand($0) }
                    }
                }
            }
            Text("Not sure? The brand is printed on the front of the NAS.")
                .font(.footnote).foregroundStyle(Theme.secondaryLabel).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .navigationTitle("Your NAS")
    }

    private func brand(_ brand: NASBrand) -> some View {
        Button { flow.go(.nasGuide(brand)) } label: {
            HStack(spacing: 10) {
                Image(systemName: SetupAdvisor.Machine.nas.symbol).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(brand.name).foregroundStyle(Theme.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nas.\(brand.rawValue)")
    }
}

// MARK: 4.3 A NAS brand's guide

struct NASGuidePage: View {
    let flow: SetupFlow
    let brand: NASBrand

    var body: some View {
        SetupScaffold(title: "Set up Homespun on \(brand == .other ? "your NAS" : brand.name)") {
            if brand == .synology {
                InlineNotice(tone: .info, title: "Synology j and se models can't run Docker",
                             message: "Use a Mac or a Linux computer instead.")
            }
            let steps = brand.steps
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                NumberedStep(number: index + 1, title: step) {
                    if index == brand.composeStep {
                        CommandBox(command: brand.compose, label: "Copy compose file")
                            .accessibilityIdentifier("nas.compose")
                    }
                }
            }
        } actions: {
            PrimaryButton(title: "Copy Compose File", systemImage: "doc.on.doc", id: "nas.copy") {
                UIPasteboard.general.string = brand.compose
                flow.go(.waiting(.nas))
            }
        }
        .navigationTitle(brand.name)
    }
}

extension NASBrand {
    /// Where originals go on the NAS, as the brand names its folders.
    var folder: String {
        switch self {
        case .synology, .ugreen: "/volume1/photos/Homespun"
        case .qnap: "/share/Photos/Homespun"
        case .truenas: "/mnt/tank/photos/Homespun"
        case .unraid: "/mnt/user/photos/Homespun"
        case .asustor: "/volume1/Photos/Homespun"
        case .terramaster: "/Volume1/photos/Homespun"
        case .other: "/path/to/photos/Homespun"
        }
    }

    /// The same as deploy/compose.yaml in the repository, with this brand's folder: host networking
    /// and the NAS's D-Bus, so Bonjour from inside the container reaches the iPhone. The catalog
    /// lives next to the project file; originals go in a folder on the photos share.
    var compose: String {
        """
        services:
          homespun:
            image: ghcr.io/akshob/homespun-server:latest
            container_name: homespun
            network_mode: host
            user: "\(userIDs)"  # your user's IDs: `id` on the NAS
            environment:
              HOMESPUN_NAME: Homespun
              HOMESPUN_HARDWARE: \(self == .other ? "NAS" : "\(name) NAS")
            volumes:
              - ./data:/data
              - \(folder):/originals
              - /var/run/dbus:/var/run/dbus:ro
            security_opt:
              - apparmor:unconfined
            restart: unless-stopped
        """
    }

    /// The IDs Homespun writes the folders as: the NAS's first user is usually these.
    var userIDs: String { self == .synology ? "1026:100" : "1000:100" }

    /// The step that shows the compose file.
    var composeStep: Int { 1 }

    var steps: [String] {
        let done = "Homespun finds the NAS on your Wi‑Fi when the project starts."
        return switch self {
        case .synology: [
            "In DSM, open Package Center and install Container Manager.",
            "Create a shared folder for originals, for example “photos”. Then Container Manager › Project › Create. "
                + "Name it homespun, choose “Create docker-compose.yml”, and paste this:",
            "Tap Next, then Done. \(done)",
        ]
        case .qnap: [
            "In App Center, install Container Station.",
            "Create a shared folder for originals, for example “Photos”. Then Container Station › Applications › "
                + "Create. Name it homespun and paste this:",
            "Tap Create. \(done)",
        ]
        case .ugreen: [
            "In the App Center, install Docker.",
            "Create a shared folder for originals, for example “photos”. Then Docker › Project › Create. Name it "
                + "homespun and paste this:",
            "Tap Deploy. \(done)",
        ]
        case .truenas: [
            "Create a dataset for originals, for example “photos”.",
            "Apps › Discover Apps › Custom App, then Install via YAML. Name it homespun and paste this:",
            "Tap Save. \(done)",
        ]
        case .unraid: [
            "Create a share for originals, for example “photos”, and install Compose Manager from Community Apps.",
            "Docker › Compose › Add New Stack. Name it homespun and paste this:",
            "Tap Compose Up. \(done)",
        ]
        case .asustor: [
            "In App Central, install Portainer CE.",
            "Create a shared folder for originals, for example “Photos”. Then Portainer › Stacks › Add stack. Name it "
                + "homespun and paste this:",
            "Tap Deploy the stack. \(done)",
        ]
        case .terramaster: [
            "In the App Center, install Container Manager.",
            "Create a shared folder for originals, for example “photos”. Then Container Manager › Projects › Create. "
                + "Name it homespun and paste this:",
            "Tap Create. \(done)",
        ]
        case .other: [
            "Install Docker with Docker Compose on the NAS.",
            "Make a folder for originals, then save this as docker-compose.yml, with your folder's path:",
            "Run “docker compose up -d” in that folder. \(done)",
        ]
        }
    }
}

// MARK: 3.4 Waiting for the server · 4.4 Waiting for the NAS

struct WaitingPage: View {
    let flow: SetupFlow
    let machine: SetupAdvisor.Machine
    @State private var since = Date()
    @State private var known = Set<String>()
    @State private var found: SetupFlow.PairTarget?

    private var isNAS: Bool { machine == .nas }
    /// When to say "Still waiting" (IN-S): a NAS downloads an image first.
    private var patience: TimeInterval { isNAS ? 600 : 180 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let slow = context.date.timeIntervalSince(since) > patience
            SetupScaffold(title: isNAS ? "Waiting for your NAS" : "Waiting for \(machine.yours)") {
                SetupCard {
                    StepRow(state: .done, title: isNAS ? "Compose file copied"
                            : machine == .linux ? "Commands sent to your computer" : "Steps sent to your Mac")
                    StepRow(state: found == nil ? .running : .done,
                            title: isNAS ? "Project starting on the NAS" : "Homespun Server starts",
                            detail: isNAS ? "Downloading the image can take a few minutes."
                                : "Usually under a minute after it's built.")
                    StepRow(state: found == nil ? .waiting : .done, title: "Found on your network")
                    StepRow(state: found == nil ? .waiting : .running, title: "Paired with this iPhone")
                }
                if slow {
                    InlineNotice(tone: .info, title: "Still waiting",
                                 message: isNAS ? "Is the project running in the NAS's container app?"
                                    : "Is \(machine.yours) awake and on this Wi‑Fi? Guest networks can't see other devices.")
                }
                Text("Homespun keeps looking on your Wi‑Fi while this page is open.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, 4)
            } actions: {
                if isNAS {
                    SecondaryButton(title: "Show the Steps Again", id: "waiting.steps") {
                        if !flow.path.isEmpty { flow.path.removeLast() }
                    }
                } else {
                    SecondaryButton(title: "Connect Another Way", id: "setup.otherWays") { flow.go(.otherWays) }
                }
            }
        }
        .onAppear {
            flow.discovery.start()
            if known.isEmpty { known = Set(flow.discovery.ready.map(\.name)) }
        }
        .onChange(of: flow.discovery.ready.map(\.name)) { _, names in
            // A server that wasn't there before: the new one.
            guard found == nil, flow.current == .waiting(machine),
                  let name = names.first(where: { !known.contains($0) }), var target = flow.target(for: name) else { return }
            target.waitedFor = true
            found = target
            Announce.say("Found \(target.displayName) on your network.")
            Task {
                try? await Task.sleep(for: .seconds(1))
                flow.go(.pair(target))
            }
        }
    }
}
