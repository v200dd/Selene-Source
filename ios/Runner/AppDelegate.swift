import Flutter
import UIKit
import AVFoundation
import AVKit

private final class SelenePictureInPictureController: NSObject,
  AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func start(arguments: [String: Any], in hostView: UIView) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let urlString = arguments["url"] as? String,
      let url = URL(string: urlString)
    else {
      channel.invokeMethod("failed", arguments: "Picture in Picture is unavailable")
      return false
    }

    dispose(notify: false)
    let headers = arguments["headers"] as? [String: String] ?? [:]
    let asset = AVURLAsset(
      url: url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    let layer = AVPlayerLayer(player: player)
    layer.frame = hostView.bounds
    layer.videoGravity = .resizeAspect
    hostView.layer.insertSublayer(layer, at: 0)

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      channel.invokeMethod("failed", arguments: "Unable to create Picture in Picture controller")
      return false
    }
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = false
    }

    self.player = player
    playerLayer = layer
    pipController = controller

    let positionMs = arguments["positionMs"] as? Int ?? 0
    let position = CMTime(value: CMTimeValue(positionMs), timescale: 1000)
    player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      guard let self else { return }
      player.play()
      self.startWhenPossible(attemptsRemaining: 30)
    }
    return true
  }

  private func startWhenPossible(attemptsRemaining: Int) {
    guard let controller = pipController else { return }
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
      return
    }
    guard attemptsRemaining > 0 else {
      channel.invokeMethod("failed", arguments: "Picture in Picture did not become ready")
      dispose(notify: false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.startWhenPossible(attemptsRemaining: attemptsRemaining - 1)
    }
  }

  func dispose(notify: Bool) {
    let seconds = player?.currentTime().seconds ?? 0
    let positionMs = seconds.isFinite ? Int(seconds * 1000) : 0
    player?.pause()
    pipController?.delegate = nil
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    playerLayer?.removeFromSuperlayer()
    player = nil
    playerLayer = nil
    pipController = nil
    if notify {
      channel.invokeMethod("stopped", arguments: ["positionMs": positionMs])
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel.invokeMethod("started", arguments: nil)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    channel.invokeMethod("failed", arguments: error.localizedDescription)
    dispose(notify: false)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    dispose(notify: true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var pipChannel: FlutterMethodChannel?
  private var pictureInPictureController: SelenePictureInPictureController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let flutterController = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "selene/ios_pip",
        binaryMessenger: flutterController.binaryMessenger
      )
      let controller = SelenePictureInPictureController(channel: channel)
      channel.setMethodCallHandler { [weak flutterController, weak controller] call, result in
        guard let controller, let hostView = flutterController?.view else {
          result(false)
          return
        }
        switch call.method {
        case "start":
          guard let arguments = call.arguments as? [String: Any] else {
            result(false)
            return
          }
          result(controller.start(arguments: arguments, in: hostView))
        case "dispose":
          controller.dispose(notify: false)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      pipChannel = channel
      pictureInPictureController = controller
    }
    
    // 配置音频会话以支持后台播放和 PiP
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
      try audioSession.setActive(true)
    } catch {
      print("Failed to set audio session category: \(error)")
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
