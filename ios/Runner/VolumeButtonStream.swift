import AVFoundation
import Flutter
import MediaPlayer
import UIKit

// iOS exposes changes to the output volume, rather than individual volume-key presses.
final class VolumeButtonStream: NSObject, FlutterStreamHandler {
  private weak var view: UIView?
  private let session = AVAudioSession.sharedInstance()
  private var sink: FlutterEventSink?
  private var observation: NSKeyValueObservation?
  private var volumeView: MPVolumeView?
  private weak var slider: UISlider?
  private var originalVolume: Float = 0
  private var anchor: Float = 0
  private var pendingResetFrom: Float?
  private var outputIDs: [String] = []
  private var ownsAudioSession = false

  init(view: UIView) {
    self.view = view
    super.init()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(start), name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(stop), name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(routeChanged), name: AVAudioSession.routeChangeNotification, object: session)
    center.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: session)
    start()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    sink = nil
    stop()
    return nil
  }

  private var currentOutputs: [String] {
    session.currentRoute.outputs.map { $0.uid }
  }

  @objc private func start() {
    guard observation == nil, sink != nil, let view = view,
          UIApplication.shared.applicationState == .active else { return }

    // The default solo-ambient category would interrupt music in other apps.
    // Leave a category already configured by a media player alone.
    if session.category == .soloAmbient {
      do {
        try session.setCategory(.ambient)
        ownsAudioSession = true
        try session.setActive(true)
      } catch {
        stop()
        return
      }
    }

    let control = MPVolumeView(frame: CGRect(x: -160, y: 0, width: 150, height: 32))
    control.showsRouteButton = false
    control.isUserInteractionEnabled = false
    control.accessibilityElementsHidden = true
    view.addSubview(control)
    control.layoutIfNeeded()
    volumeView = control
    slider = control.subviews.compactMap { $0 as? UISlider }.first
    observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self, weak control] _, change in
      guard let oldVolume = change.oldValue, let volume = change.newValue else { return }
      DispatchQueue.main.async {
        // A notification can outlive a canceled or backgrounded subscription.
        guard let self = self, let control = control, self.volumeView === control,
              UIApplication.shared.applicationState == .active else { return }
        self.volumeChanged(from: oldVolume, to: volume)
      }
    }
    setBaselineForCurrentRoute()
  }

  @objc private func interrupted(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    DispatchQueue.main.async { [weak self] in
      if type == .began {
        self?.stop()
      } else if type == .ended {
        self?.start()
      }
    }
  }

  @objc private func routeChanged() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.volumeView != nil, self.currentOutputs != self.outputIDs else { return }
      self.setBaselineForCurrentRoute()
    }
  }

  private func setBaselineForCurrentRoute() {
    outputIDs = currentOutputs
    originalVolume = session.outputVolume
    pendingResetFrom = nil
    // Leave room for an observable change in both directions, even from mute or max.
    anchor = min(max(originalVolume, 1.0 / 16.0), 15.0 / 16.0)
    if originalVolume != anchor {
      pendingResetFrom = originalVolume
      writeVolume(anchor)
    }
  }

  private func volumeChanged(from oldVolume: Float, to volume: Float) {
    guard currentOutputs == outputIDs else {
      // New devices can have a different volume from the previous output.
      setBaselineForCurrentRoute()
      return
    }
    guard volume != oldVolume else { return }
    // Re-centering the slider also fires KVO. Only forward external changes.
    if slider != nil, let pending = pendingResetFrom {
      pendingResetFrom = nil
      if abs(volume - anchor) < 0.001 ||
          (abs(oldVolume - pending) < 0.001 && abs(volume - anchor) < abs(oldVolume - anchor)) {
        // Some accessories round slider values to the nearest supported step.
        anchor = volume
        return
      }
    }
    sink?(volume > oldVolume ? 1 : 2)
    if slider != nil && abs(volume - anchor) >= 0.001 {
      pendingResetFrom = volume
      writeVolume(anchor)
    }
  }

  private func writeVolume(_ value: Float) {
    slider?.setValue(value, animated: false)
    slider?.sendActions(for: .touchUpInside)
  }

  @objc private func stop() {
    observation?.invalidate()
    observation = nil
    if slider != nil, currentOutputs == outputIDs, anchor != originalVolume,
       abs(session.outputVolume - anchor) < 0.001 {
      writeVolume(originalVolume)
    }
    volumeView?.removeFromSuperview()
    volumeView = nil
    slider = nil
    if ownsAudioSession {
      if session.category == .ambient {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient)
      }
      ownsAudioSession = false
    }
  }
}
