import Flutter
import UIKit
import AVFoundation
import AVKit

/// iOS 画中画控制器（手动触发）。
///
/// 主播放器是 media_kit（mpv），它无法直接进入系统画中画，所以点画中画按钮时
/// 这里临时建一个同源的 AVPlayer 接管播放。
///
/// 重要：`FlutterViewController.view.layer` 本身就是渲染用的 CAMetalLayer，
/// 往它里面插入 sublayer 会盖在 Flutter 画面之上（之前版本播放页下方出现黑块
/// 就是这个原因）。所以这里只在真正需要时创建图层，尺寸压到很小并放在左上角，
/// 退出画中画立即移除。
private final class SelenePictureInPictureController: NSObject,
  AVPictureInPictureControllerDelegate {
  /// 承载 PiP 的图层必须在视图层级里且尺寸非零，但不需要真的给用户看。
  private static let hostLayerSize = CGSize(width: 2, height: 2)

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
      channel.invokeMethod("failed", arguments: "此设备不支持画中画")
      return false
    }

    teardown(notify: false)

    let headers = arguments["headers"] as? [String: String] ?? [:]
    let asset = AVURLAsset(
      url: url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.allowsExternalPlayback = false

    let layer = AVPlayerLayer(player: player)
    layer.frame = CGRect(origin: .zero, size: Self.hostLayerSize)
    layer.videoGravity = .resizeAspect
    hostView.layer.addSublayer(layer)

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      channel.invokeMethod("failed", arguments: "无法创建画中画")
      return false
    }
    controller.delegate = self

    self.player = player
    playerLayer = layer
    pipController = controller

    let positionMs = arguments["positionMs"] as? Int ?? 0
    let position = CMTime(value: CMTimeValue(max(positionMs, 0)), timescale: 1000)
    player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      guard let self else { return }
      player.play()
      self.startWhenPossible(attemptsRemaining: 40)
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
      channel.invokeMethod("failed", arguments: "画中画未能就绪")
      teardown(notify: false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.startWhenPossible(attemptsRemaining: attemptsRemaining - 1)
    }
  }

  func dispose() {
    teardown(notify: false)
  }

  private func currentPositionMs() -> Int {
    let seconds = player?.currentTime().seconds ?? 0
    return seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : 0
  }

  private func teardown(notify: Bool) {
    let positionMs = currentPositionMs()
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

  // MARK: - AVPictureInPictureControllerDelegate

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
    teardown(notify: false)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    teardown(notify: true)
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
        let arguments = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
          result(controller.start(arguments: arguments, in: hostView))
        case "dispose":
          controller.dispose()
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
