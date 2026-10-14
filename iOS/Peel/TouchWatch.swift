import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Calls `touched` for each touch that begins anywhere in the window it is
/// placed in, without taking any touch from what it lands on: the phone's
/// `AppModel.noteActivity`, as the Mac's key and mouse monitor is.
struct TouchWatch: UIViewRepresentable {
    let touched: @MainActor () -> Void

    func makeUIView(context: Context) -> WatchView {
        WatchView(touched: touched)
    }

    func updateUIView(_ view: WatchView, context: Context) {
        view.recogniser.touched = touched
    }

    final class WatchView: UIView {
        let recogniser: Recogniser

        init(touched: @escaping @MainActor () -> Void) {
            recogniser = Recogniser(touched: touched)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recogniser.view?.removeGestureRecognizer(recogniser)
            window?.addGestureRecognizer(recogniser)
        }
    }

    /// Never recognises anything: it notes the touch and fails, so every
    /// other recogniser and control gets the touch as before.
    final class Recogniser: UIGestureRecognizer, UIGestureRecognizerDelegate {
        var touched: @MainActor () -> Void

        init(touched: @escaping @MainActor () -> Void) {
            self.touched = touched
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            touched()
            state = .failed
        }

        func gestureRecognizer(_ recogniser: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
