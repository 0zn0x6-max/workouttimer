import SwiftUI
import AVFoundation

// MARK: - Phase

enum Phase {
    case setup, countdown, rest, restDone, done
}

// MARK: - Audio

class AudioEngine {
    static let shared = AudioEngine()

    func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func beep(freq: Double = 880, duration: Double = 0.15, volume: Float = 0.4) {
        DispatchQueue.global(qos: .userInteractive).async {
            let sr = 44100.0
            let count = Int(sr * duration)
            var data = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(i) / sr
                let env = max(0, 1.0 - t / duration)
                data[i] = Float(sin(2.0 * .pi * freq * t) * Double(volume) * env)
            }
            self.play(samples: data, sampleRate: sr)
        }
    }

    func playDone() {
        let freqs = [660.0, 880.0, 1100.0]
        for (i, f) in freqs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { self.beep(freq: f, duration: 0.2, volume: 0.5) }
        }
    }

    func playAlarm() {
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.28) {
                self.beep(freq: i % 2 == 0 ? 1200 : 900, duration: 0.25, volume: 0.6)
            }
        }
    }

    func playTick(isLast: Bool) { beep(freq: isLast ? 1100 : 660, duration: 0.12, volume: 0.35) }

    private func play(samples: [Float], sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let ch = buf.floatChannelData![0]
        for i in 0..<samples.count { ch[i] = samples[i] }
        try? engine.start()
        player.scheduleBuffer(buf, completionHandler: nil)
        player.play()
        Thread.sleep(forTimeInterval: Double(samples.count) / sampleRate + 0.05)
        engine.stop()
    }
}

// MARK: - ViewModel (date-based, screen-off safe)

class WorkoutViewModel: ObservableObject {
    @Published var phase: Phase = .setup
    @Published var sessionMin: Int = 10
    @Published var restMin: Int = 1
    @Published var enableRest: Bool = false

    // Displayed values derived from target dates
    @Published var sessionLeft: Int = 0
    @Published var elapsed: Int = 0
    @Published var rounds: Int = 0
    @Published var restCountdown: Int = 0
    @Published var sessionFired: Bool = false

    // Target end dates — accurate even when screen is off
    private var sessionEnd: Date?
    private var restEnd: Date?
    private var startDate: Date?

    private var ticker: Timer?
    // Tracks which rest-second ticks have already fired
    private var tickedSeconds = Set<Int>()

    var sessionPct: Double {
        let total = sessionMin * 60
        guard total > 0 else { return 0 }
        return Double(sessionLeft) / Double(total)
    }

    var restPct: Double {
        let total = restMin * 60
        guard total > 0 else { return 0 }
        return Double(restCountdown) / Double(total)
    }

    func startSession() {
        AudioEngine.shared.prepare()
        sessionFired = false
        rounds = 0
        elapsed = 0
        tickedSeconds = []

        let now = Date()
        startDate = now
        sessionEnd = now.addingTimeInterval(Double(sessionMin * 60))
        sessionLeft = sessionMin * 60

        cancelTicker()
        startTicker()
        phase = .countdown
    }

    func roundDone() {
        AudioEngine.shared.playDone()
        rounds += 1
        if enableRest {
            let now = Date()
            restEnd = now.addingTimeInterval(Double(restMin * 60))
            restCountdown = restMin * 60
            tickedSeconds = []
            phase = .rest
        } else {
            phase = .restDone
        }
    }

    func startNextRound() {
        restEnd = nil
        tickedSeconds = []
        phase = .countdown
    }

    func finishEarly() {
        cancelTicker()
        phase = .done
    }

    func reset() {
        cancelTicker()
        rounds = 0
        elapsed = 0
        sessionFired = false
        startDate = nil
        sessionEnd = nil
        restEnd = nil
        phase = .setup
    }

    private func startTicker() {
        // Fire every 0.25s so we catch exact second boundaries even when screen wakes up
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func cancelTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Date()

        // Elapsed
        if let start = startDate {
            elapsed = max(0, Int(now.timeIntervalSince(start)))
        }

        // Session countdown
        if let end = sessionEnd {
            let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
            sessionLeft = remaining
            if remaining == 0 && !sessionFired {
                sessionFired = true
                AudioEngine.shared.playAlarm()
            }
        }

        // Rest countdown
        if phase == .rest, let end = restEnd {
            let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
            restCountdown = remaining

            // 5-second countdown ticks — fire once per second
            if remaining <= 5 && remaining > 0 && !tickedSeconds.contains(remaining) {
                tickedSeconds.insert(remaining)
                AudioEngine.shared.playTick(isLast: remaining == 1)
            }

            if remaining == 0 {
                restEnd = nil
                phase = .restDone
            }
        }
    }
}

// MARK: - Helpers

func formatTime(_ s: Int) -> String {
    String(format: "%02d:%02d", s / 60, s % 60)
}

func formatElapsed(_ s: Int) -> String {
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return "\(h)h \(m)m \(sec)s" }
    if m > 0 { return "\(m)m \(sec)s" }
    return "\(sec)s"
}

// MARK: - Colors

extension Color {
    static let accent = Color(red: 1,     green: 0.42, blue: 0.21)
    static let green  = Color(red: 0.19,  green: 0.82, blue: 0.35)
    static let bg     = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let bg2    = Color(red: 0.09,  green: 0.09,  blue: 0.09)
    static let bg3    = Color(red: 0.1,   green: 0.1,   blue: 0.1)
    static let ring   = Color(red: 0.118, green: 0.118, blue: 0.118)
    static let dim    = Color(white: 0.33)
    static let dimmer = Color(white: 0.2)
}

// MARK: - Number Input Pad

struct NumberInputPad: View {
    let label: String
    let min: Int
    let max: Int
    @Binding var value: Int
    @Binding var isPresented: Bool

    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { isPresented = false }
                    .foregroundColor(.dim)
                Spacer()
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold)).kerning(3)
                    .foregroundColor(.dim)
                Spacer()
                Button("Done") { commit() }
                    .foregroundColor(.accent)
                    .font(.body.weight(.bold))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            // Display
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(input.isEmpty ? "—" : input)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .foregroundColor(input.isEmpty ? .dimmer : .white)
                Text("min")
                    .font(.system(size: 20)).foregroundColor(.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.bg2)

            // Keypad
            let keys: [[String]] = [["1","2","3"],["4","5","6"],["7","8","9"],["","0","⌫"]]
            VStack(spacing: 1) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                handleKey(key)
                            } label: {
                                Text(key)
                                    .font(.system(size: 28, weight: key == "⌫" ? .regular : .medium))
                                    .foregroundColor(key.isEmpty ? .clear : .white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 80)
                                    .background(key.isEmpty ? Color.bg : Color.bg3)
                            }
                            .disabled(key.isEmpty)
                        }
                    }
                }
            }
            .background(Color(white: 0.08))
        }
        .background(Color.bg)
        .onAppear { input = "\(value)" }
    }

    private func handleKey(_ key: String) {
        if key == "⌫" {
            if !input.isEmpty { input.removeLast() }
        } else {
            let next = input + key
            if let n = Int(next), n <= max {
                input = next
            }
        }
    }

    private func commit() {
        if let n = Int(input) {
            value = Swift.max(min, Swift.min(max, n))
        }
        isPresented = false
    }
}

// MARK: - SpinBox

struct SpinBox: View {
    let label: String
    @Binding var value: Int
    let min: Int
    let max: Int

    @State private var showPad = false

    var body: some View {
        HStack(spacing: 0) {
            Button { if value > min { value -= 1 } } label: {
                Text("−").font(.system(size: 24)).foregroundColor(.accent)
                    .frame(width: 52, height: 56)
            }
            Spacer()
            Button {
                showPad = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(value)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(label).font(.system(size: 12)).foregroundColor(.dim)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color.bg2)
                .cornerRadius(8)
            }
            Spacer()
            Button { if value < max { value += 1 } } label: {
                Text("+").font(.system(size: 24)).foregroundColor(.accent)
                    .frame(width: 52, height: 56)
            }
        }
        .background(Color.bg3)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.dimmer, lineWidth: 1))
        .sheet(isPresented: $showPad) {
            if #available(iOS 16.0, *) {
                NumberInputPad(label: label, min: min, max: max, value: $value, isPresented: $showPad)
                    .presentationDetents([.fraction(0.72)])
                    .presentationDragIndicator(.visible)
            } else {
                NumberInputPad(label: label, min: min, max: max, value: $value, isPresented: $showPad)
            }
        }
    }
}

// MARK: - Toggle Row

struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.accent : Color.dimmer).frame(width: 44, height: 26)
                Circle().fill(Color.white).frame(width: 20, height: 20).padding(3)
            }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isOn.toggle() } }
            Text(label).font(.system(size: 11, weight: .bold)).kerning(2)
                .textCase(.uppercase).foregroundColor(.dim)
        }
    }
}

// MARK: - Ring Button

struct RingButton: View {
    let phase: Phase
    let elapsed: Int
    let restCountdown: Int
    let restPct: Double
    let rounds: Int
    let onTap: () -> Void

    private let size: CGFloat = 300
    private let radius: CGFloat = 138
    private var circumference: CGFloat { 2 * .pi * radius }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle().stroke(Color.ring, lineWidth: 14).frame(width: size, height: size)

                Circle()
                    .trim(from: 0, to: phase == .countdown ? 1.0 : CGFloat(phase == .rest ? restPct : 0))
                    .stroke(
                        phase == .countdown ? Color.accent : Color.green,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: restPct)

                Circle().fill(Color.bg2).frame(width: size - 28, height: size - 28)

                VStack(spacing: 6) {
                    switch phase {
                    case .countdown:
                        Text("Round \(rounds + 1)")
                            .font(.system(size: 11, weight: .bold)).kerning(3)
                            .textCase(.uppercase).foregroundColor(.accent)
                        Text(formatElapsed(elapsed))
                            .font(.system(size: 50, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("tap when done")
                            .font(.system(size: 12)).foregroundColor(Color(white: 0.2))
                        Text("✓").font(.system(size: 22)).foregroundColor(.green)

                    case .rest:
                        Text("Rest")
                            .font(.system(size: 12, weight: .bold)).kerning(3)
                            .textCase(.uppercase).foregroundColor(.green)
                        Text(formatTime(restCountdown))
                            .font(.system(size: 50, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("tap to skip")
                            .font(.system(size: 11)).foregroundColor(.dim)
                        Text("→").font(.system(size: 18)).foregroundColor(.dim)

                    case .restDone:
                        Text("✓").font(.system(size: 40)).foregroundColor(.green)
                        Text("Round \(rounds) done")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        Text("ready when you are")
                            .font(.system(size: 12)).foregroundColor(.dim)
                        Text("TAP TO START →")
                            .font(.system(size: 13, weight: .bold)).kerning(2)
                            .foregroundColor(.accent).padding(.top, 4)

                    default: EmptyView()
                    }
                }
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .frame(width: size, height: size)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Setup View

struct SetupView: View {
    @ObservedObject var vm: WorkoutViewModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 4) {
                Text("Workout Timer")
                    .font(.system(size: 11, weight: .bold)).kerning(3)
                    .textCase(.uppercase).foregroundColor(.accent)
                Text("Configure your session")
                    .font(.system(size: 12)).foregroundColor(.dim)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Session Duration")
                    .font(.system(size: 11, weight: .bold)).kerning(2)
                    .textCase(.uppercase).foregroundColor(.dim)
                SpinBox(label: "min", value: $vm.sessionMin, min: 1, max: 180)
            }

            VStack(alignment: .leading, spacing: 8) {
                ToggleRow(label: "Rest between rounds", isOn: $vm.enableRest)
                if vm.enableRest {
                    SpinBox(label: "min", value: $vm.restMin, min: 1, max: 30)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.enableRest)

            Spacer()

            Button(action: vm.startSession) {
                Text("Start Workout")
                    .font(.system(size: 14, weight: .heavy)).kerning(2)
                    .textCase(.uppercase).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(Color.accent).cornerRadius(16)
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Active View

struct ActiveView: View {
    @ObservedObject var vm: WorkoutViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workout Timer")
                    .font(.system(size: 11, weight: .bold)).kerning(3)
                    .textCase(.uppercase).foregroundColor(.accent)
                Spacer()
                Button(action: vm.finishEarly) {
                    Text("Finish ✕")
                        .font(.system(size: 11, weight: .bold)).kerning(1)
                        .textCase(.uppercase)
                        .foregroundColor(Color(white: 0.53))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.bg3)
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.dimmer, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)

            VStack(spacing: 5) {
                HStack {
                    Text("Session").font(.system(size: 10, weight: .bold)).kerning(2)
                        .textCase(.uppercase).foregroundColor(.dim)
                    Spacer()
                    Text(vm.sessionFired ? "TIME'S UP" : formatTime(vm.sessionLeft))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(vm.sessionFired ? .red : Color(white: 0.67))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.13)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(vm.sessionFired ? Color.red : Color.accent)
                            .frame(width: geo.size.width * CGFloat(vm.sessionPct), height: 4)
                            .animation(.linear(duration: 0.25), value: vm.sessionPct)
                    }
                }.frame(height: 4)
            }
            .padding(.horizontal, 20).padding(.top, 10)

            HStack(spacing: 6) {
                ForEach(0..<max(vm.rounds + 1, 1), id: \.self) { i in
                    Circle()
                        .fill(i < vm.rounds ? Color.accent : Color(white: 0.16))
                        .overlay(Circle().stroke(i == vm.rounds && vm.phase == .countdown ? Color.accent : Color.clear, lineWidth: 1))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 10).frame(maxWidth: .infinity)

            Spacer()

            RingButton(
                phase: vm.phase,
                elapsed: vm.elapsed,
                restCountdown: vm.restCountdown,
                restPct: vm.restPct,
                rounds: vm.rounds,
                onTap: {
                    switch vm.phase {
                    case .countdown:        vm.roundDone()
                    case .rest, .restDone:  vm.startNextRound()
                    default: break
                    }
                }
            )

            HStack(spacing: 40) {
                StatView(label: "Rounds",     value: "\(vm.rounds)")
                StatView(label: "Total Time", value: formatElapsed(vm.elapsed))
            }
            .padding(.top, 18)

            Spacer()
        }
    }
}

// MARK: - Done View

struct DoneView: View {
    @ObservedObject var vm: WorkoutViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("🏁").font(.system(size: 52)).padding(.bottom, 8)
            Text("Workout Complete").font(.system(size: 26, weight: .bold)).foregroundColor(.white).padding(.bottom, 4)
            Text("Great effort!").font(.system(size: 13)).foregroundColor(.dim).padding(.bottom, 32)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ResultCard(label: "Total Rounds", value: "\(vm.rounds)",          accent: .accent)
                ResultCard(label: "Total Time",   value: formatElapsed(vm.elapsed), accent: .green)
                ResultCard(label: "Session Set",  value: "\(vm.sessionMin)m",     accent: Color(red: 0, green: 0.48, blue: 1))
                ResultCard(label: "Avg / Round",
                           value: vm.rounds > 0 ? formatElapsed(vm.elapsed / vm.rounds) : "—",
                           accent: Color(red: 0.69, green: 0.32, blue: 0.87))
            }
            .padding(.horizontal, 24).padding(.bottom, 32)

            Button(action: vm.reset) {
                Text("New Workout").font(.system(size: 14, weight: .heavy)).kerning(2)
                    .textCase(.uppercase).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(Color.accent).cornerRadius(16)
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

// MARK: - Sub-components

struct StatView: View {
    let label: String; let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).kerning(2)
                .textCase(.uppercase).foregroundColor(.dim)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
        }
    }
}

struct ResultCard: View {
    let label: String; let value: String; let accent: Color
    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold)).kerning(2)
                .textCase(.uppercase).foregroundColor(.dim)
            Text(value).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(Color.bg3).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.dimmer, lineWidth: 1))
        .overlay(Rectangle().fill(accent).frame(height: 3), alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = WorkoutViewModel()

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            switch vm.phase {
            case .setup:                        SetupView(vm: vm)
            case .countdown, .rest, .restDone:  ActiveView(vm: vm)
            case .done:                         DoneView(vm: vm)
            }
        }
        .preferredColorScheme(.dark)
    }
}
