import SwiftUI

struct RemoteView: View {
    @StateObject private var client: RemoteClient
    @Environment(\.scenePhase) private var scenePhase

    init(mac: DiscoveredMac) {
        _client = StateObject(wrappedValue: RemoteClient(mac: mac))
    }

    var body: some View {
        Group {
            switch client.status {
            case .idle, .connecting:
                ProgressView("Connecting…")
            case .needsPIN(let message):
                PINEntryView(macName: client.mac.name, error: message) { pin in
                    client.connect(pin: pin)
                }
            case .disconnected(let message):
                DisconnectedView(message: message) {
                    client.connect()
                }
            case .connected:
                ControlsView(client: client)
            }
        }
        .navigationTitle(client.mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.connect() }
        .onDisappear { client.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.reconnectIfNeeded()
            }
        }
    }
}

/// Fixed layout: everything below the artwork has a constant height, so controls never move
/// because of the track (long titles scroll, missing info keeps its space). The artwork takes
/// whatever height is left, which depends only on the screen.
private struct ControlsView: View {
    @ObservedObject var client: RemoteClient
    @State private var sliderValue = 0.0
    @State private var isDragging = false
    @State private var tapCount = 0
    /// Per-button tap counters that drive the symbol bounce.
    @State private var previousTaps = 0
    @State private var playTaps = 0
    @State private var nextTaps = 0

    var body: some View {
        VStack(spacing: 0) {
            ArtworkView(image: client.artwork)
                .frame(maxWidth: 360, maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 24)

            VStack(spacing: 20) {
                NowPlayingView(client: client)
                ScrubberView(client: client, duration: client.duration)
                transportControls
                volumeSlider
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .toolbar {
            if client.outputs.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    OutputPicker(client: client)
                }
            }
        }
        .onAppear { sliderValue = client.volume ?? 0 }
        .onChange(of: client.volume) { _, volume in
            if !isDragging, let volume { sliderValue = volume }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            controlButton("backward.fill", command: .previous, taps: $previousTaps, label: "Previous")

            Button {
                playTaps += 1
                send(.playPause)
            } label: {
                Image(systemName: playButtonSymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce, options: .speed(1.5), value: playTaps)
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel(client.isPlaying == true ? Text("Pause") : Text("Play"))

            controlButton("forward.fill", command: .next, taps: $nextTaps, label: "Next")
        }
    }

    /// Always shown; disabled when the Mac's output has no software volume (e.g. HDMI).
    private var volumeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
            Slider(value: $sliderValue, in: 0...1) { editing in
                isDragging = editing
                if !editing { client.send(.setVolume, value: sliderValue) }
            }
            .onChange(of: sliderValue) { _, value in
                if isDragging { client.send(.setVolume, value: value) }
            }
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
        .disabled(client.volume == nil)
        .opacity(client.volume == nil || client.muted ? 0.4 : 1)
    }

    private var playButtonSymbol: String {
        switch client.isPlaying {
        case true?: "pause.fill"
        case false?: "play.fill"
        case nil: "playpause.fill"
        }
    }

    private func controlButton(_ symbol: String, command: RemoteCommand, taps: Binding<Int>, label: LocalizedStringKey) -> some View {
        Button {
            taps.wrappedValue += 1
            send(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .symbolEffect(.bounce, options: .speed(1.5), value: taps.wrappedValue)
                .foregroundStyle(.primary)
                .frame(width: 72, height: 72)
        }
        .buttonStyle(HighlightCircleButtonStyle())
        .accessibilityLabel(label)
    }

    private func send(_ command: RemoteCommand) {
        tapCount += 1
        client.send(command)
    }
}

/// Shrinks with a springy release while pressed.
private struct PressScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Borderless button that grows a soft circle behind its icon while pressed.
private struct HighlightCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.quaternary)
                    .scaleEffect(configuration.isPressed ? 1 : 0.5)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Square cover art. Non-square art (e.g. YouTube thumbnails) is fitted over a blurred fill of itself.
private struct ArtworkView: View {
    let image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 24)
                            .opacity(0.6)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    ZStack {
                        LinearGradient(colors: [.pink.opacity(0.5), .purple.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note")
                            .font(.system(size: 64, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .animation(.default, value: image)
    }
}

/// Playback position; drag or tap to seek. Keeps its height when the duration is unknown.
private struct ScrubberView: View {
    @ObservedObject var client: RemoteClient
    let duration: Double?
    /// Position under the finger while dragging.
    @State private var scrubPosition: Double?

    var body: some View {
        // Paused while scrubbing so periodic redraws can't interfere with the gesture.
        TimelineView(.animation(minimumInterval: 0.5, paused: scrubPosition != nil || duration == nil)) { context in
            let duration = duration ?? 0
            let position = duration > 0 ? min(scrubPosition ?? client.elapsed(at: context.date) ?? 0, duration) : 0
            VStack(spacing: 2) {
                GeometryReader { geometry in
                    let width = max(geometry.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(scrubPosition == nil ? Color.secondary : Color.primary)
                            .frame(width: duration > 0 ? width * position / duration : 0)
                    }
                    .frame(height: scrubPosition == nil ? 6 : 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                scrubPosition = Self.position(at: value.location.x, width: width, duration: duration)
                            }
                            .onEnded { value in
                                guard duration > 0 else { return }
                                client.seek(to: Self.position(at: value.location.x, width: width, duration: duration))
                                scrubPosition = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: scrubPosition == nil)
                }
                .frame(height: 24)

                HStack {
                    Text(verbatim: duration > 0 ? Self.format(position) : "--:--")
                    Spacer()
                    Text(verbatim: duration > 0 ? "-" + Self.format(duration - position) : "--:--")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(scrubPosition == nil ? .secondary : .primary)
            }
        }
        .allowsHitTesting(duration != nil)
    }

    private static func position(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        Double(min(max(x / width, 0), 1)) * duration
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Picks the Mac's sound output, like the AirPlay button.
private struct OutputPicker: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        Menu {
            Picker("Sound output", selection: Binding(get: { client.outputID ?? "" }, set: { client.selectOutput($0) })) {
                ForEach(client.outputs) { output in
                    Label(output.name, systemImage: Self.symbol(for: output.kind))
                        .tag(output.id)
                }
            }
        } label: {
            Image(systemName: Self.symbol(for: client.outputs.first { $0.id == client.outputID }?.kind ?? .other))
        }
        .accessibilityLabel("Sound output")
    }

    static func symbol(for kind: AudioOutput.Kind) -> String {
        switch kind {
        case .builtIn: "hifispeaker.fill"
        case .bluetooth: "headphones"
        case .airPlay: "airplayaudio"
        case .usb: "cable.connector"
        case .display: "tv"
        case .other: "speaker.wave.2.fill"
        }
    }
}

/// Three single lines (title, artist, app) that always take the same space.
private struct NowPlayingView: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        VStack(spacing: 4) {
            MarqueeText(text: client.title ?? String(localized: "Nothing playing"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(client.title == nil ? .secondary : .primary)

            Text(verbatim: client.artist ?? " ")
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: client.isPlaying == true ? "speaker.wave.2.fill" : "pause.circle")
                Text(verbatim: client.appName ?? " ")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(client.appName == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line of text that scrolls horizontally when it doesn't fit, like Apple Music.
private struct MarqueeText: View {
    let text: String

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 48
    private let speed: CGFloat = 30 // points per second
    private var overflows: Bool { textWidth > boxWidth + 1 }

    var body: some View {
        // The hidden copy gives the view its one-line height and the full available width.
        Text(verbatim: text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: overflows ? .leading : .center) {
                HStack(spacing: gap) {
                    Text(verbatim: text)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    if overflows {
                        Text(verbatim: text)
                            .fixedSize()
                    }
                }
                .offset(x: offset)
            }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflows ? 12 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: overflows ? 12 : 0)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
            .task(id: "\(text)|\(textWidth)|\(boxWidth)") {
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { offset = 0 }
                guard overflows else { return }
                let distance = textWidth + gap
                let duration = Double(distance / speed)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: duration)) { offset = -distance }
                    try? await Task.sleep(for: .seconds(duration))
                    withTransaction(reset) { offset = 0 }
                }
            }
    }
}

private struct DisconnectedView: View {
    let message: String
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 88, height: 88)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(spacing: 6) {
                Text("Disconnected")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: reconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 50)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 5)
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PINEntryView: View {
    let macName: String
    let error: String?
    let submit: (String) -> Void

    @State private var pin = ""
    @State private var shakes = 0
    @FocusState private var focused: Bool

    private static let length = 6

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 88, height: 88)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            Text("Enter the PIN to connect to “\(macName)”.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            ZStack {
                // The real input; the boxes just mirror it.
                TextField(String(), text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.001)
                    .onChange(of: pin) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(Self.length))
                        if digits != value { pin = digits }
                        if digits.count == Self.length {
                            // Let the last digit show before switching to "Connecting…".
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { submit(digits) }
                        }
                    }

                HStack(spacing: 10) {
                    ForEach(0..<Self.length, id: \.self) { index in
                        digitBox(at: index)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
            .modifier(ShakeEffect(shakes: CGFloat(shakes)))

            Text(verbatim: error ?? " ")
                .font(.callout)
                .foregroundStyle(.red)
                .opacity(error == nil ? 0 : 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .sensoryFeedback(.error, trigger: shakes)
        .onAppear {
            focused = true
            if error != nil {
                withAnimation(.linear(duration: 0.45)) { shakes += 1 }
            }
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(pin)
        let isCurrent = focused && index == digits.count
        let borderColor: Color = isCurrent ? .accentColor
            : error != nil && pin.isEmpty ? .red.opacity(0.6)
            : .clear

        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 2)

            if index < digits.count {
                Text(String(digits[index]))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if isCurrent {
                BlinkingCaret()
            } else {
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 14, height: 3)
            }
        }
        .frame(width: 46, height: 58)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pin)
    }
}

private struct BlinkingCaret: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 26)
            .phaseAnimator([1.0, 0.0]) { caret, opacity in
                caret.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.5)
            }
    }
}

/// Horizontal shake; animate `shakes` by +1 for one shake.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(shakes * .pi * 4), y: 0))
    }
}
