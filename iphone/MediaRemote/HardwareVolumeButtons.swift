import AVFoundation
import MediaPlayer
import SwiftUI

/// While active, turns the iPhone's physical volume buttons into Mac volume up/down.
///
/// iOS has no public API for the buttons, so this watches `AVAudioSession.outputVolume` and,
/// after each press, puts the phone's own volume back to the middle (so presses keep registering
/// at the top/bottom of the range) through a hidden `MPVolumeView`, which also suppresses the
/// system volume HUD. The phone's original volume is restored when it stops.
struct HardwareVolumeButtons: UIViewRepresentable {
    var isActive: Bool
    /// `true` for volume up, `false` for volume down.
    var onPress: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        context.coordinator.volumeView = view
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        context.coordinator.onPress = onPress
        if isActive {
            context.coordinator.start()
        } else {
            context.coordinator.stop()
        }
    }

    static func dismantleUIView(_ view: MPVolumeView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var volumeView: MPVolumeView?
        var onPress: ((Bool) -> Void)?

        private let session = AVAudioSession.sharedInstance()
        private var observation: NSKeyValueObservation?
        private var originalVolume: Float?
        private static let neutral: Float = 0.5

        func start() {
            guard observation == nil else { return }
            do {
                // Ambient + mix: don't interrupt anything the phone itself is playing.
                try session.setCategory(.ambient, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                return
            }
            originalVolume = session.outputVolume
            observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
                guard let old = change.oldValue, let new = change.newValue else { return }
                DispatchQueue.main.async { self?.volumeChanged(from: old, to: new) }
            }
            // The slider inside MPVolumeView only exists once it has been laid out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.setPhoneVolume(Self.neutral)
            }
        }

        func stop() {
            guard let observation else { return }
            observation.invalidate()
            self.observation = nil
            if let originalVolume {
                setPhoneVolume(originalVolume)
            }
            originalVolume = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [session] in
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        private func volumeChanged(from old: Float, to new: Float) {
            // Our own reset back to the middle.
            guard abs(new - Self.neutral) > 0.001 else { return }
            onPress?(new > old)
            setPhoneVolume(Self.neutral)
        }

        private func setPhoneVolume(_ value: Float) {
            guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = value
            slider.sendActions(for: .valueChanged)
        }
    }
}
