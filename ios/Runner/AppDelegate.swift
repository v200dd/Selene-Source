import Flutter
import UIKit
import AVFoundation
import AVKit

/// iOS 画中画控制器。
///
/// 主播放器是 media_kit（mpv），它不能直接进入系统画中画，所以这里维护一个
/// 与主播放器同源的“影子” AVPlayer：
///
///   1. `prepare` —— 进入播放页就建好 AVPlayer / AVPlayerLayer / PiP 控制器，
///      静音预缓冲后暂停，保证 `isPictureInPicturePossible` 提前变成 true；
///   2. `updatePosition` —— Dart 侧持续同步播放进度与播放状态；
///   3. 回到桌面（`willResignActive`，此时 App 仍在前台）由原生侧主动
///      `startPictureInPicture()`，这样才不会像旧实现那样在切后台后才建 player
///      导致失败；
///   4. 退出画中画时把最终进度回传 Dart，主播放器接着播。
private final class SelenePictureInPictureController: NSObject,
  AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?
  private var prerollTimer: Timer?

  /// 最近一次由 Dart 同步过来的播放进度与播放状态。
  private var lastPositionMs: Int = 0
  private var isSourcePlaying: Bool = false
  /// 「回到桌面自动画中画」开关，由 Dart 侧设置项控制。
  private var autoEnterEnabled: Bool = true
  private var currentUrl: String?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  var isActive: Bool {
    pipController?.isPictureInPictureActive == true
  }

  // MARK: - Flutter 调用入口

  /// 进入播放页时预备影子播放器。重复调用同一地址不会重建。
  func prepare(arguments: [String: Any], in hostView: UIView) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let urlString = arguments["url"] as? String,
      let url = URL(string: urlString)
    else {
      return false
    }

    autoEnterEnabled = arguments["autoEnter"] as? Bool ?? autoEnterEnabled
    lastPositionMs = arguments["positionMs"] as? Int ?? 0
    isSourcePlaying = arguments["playing"] as? Bool ?? true

    if currentUrl == urlString, pipController != nil {
      return true
    }

    teardown(notify: false)
    currentUrl = urlString

    let headers = arguments["headers"] as? [String: String] ?? [:]
    let asset = AVURLAsset(
      url: url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
    )
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.allowsExternalPlayback = false

    let layer = AVPlayerLayer(player: player)
    // 尺寸必须非零且在视图层级内，PiP 才会认为可用；Flutter 视图不透明会盖住它。
    layer.frame = hostView.bounds.isEmpty
      ? CGRect(x: 0, y: 0, width: 320, height: 180)
      : hostView.bounds
    layer.videoGravity = .resizeAspect
    hostView.layer.insertSublayer(layer, at: 0)

    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      return false
    }
    controller.delegate = self
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }

    self.player = player
    playerLayer = layer
    pipController = controller

    // 静音预缓冲：解出首帧并让 item 进入 readyToPlay，之后暂停等待。
    seek(to: lastPositionMs) { [weak self] in
      guard let self, let player = self.player else { return }
      player.playImmediately(atRate: 1.0)
      self.prerollTimer?.invalidate()
      self.prerollTimer = Timer.scheduledTimer(
        withTimeInterval: 0.8,
        repeats: false
      ) { [weak self] _ in
        guard let self, self.isActive == false else { return }
        self.player?.pause()
      }
    }
    return true
  }

  func updatePosition(arguments: [String: Any]) {
    if let positionMs = arguments["positionMs"] as? Int {
      lastPositionMs = positionMs
    }
    if let playing = arguments["playing"] as? Bool {
      isSourcePlaying = playing
    }
  }

  func setAutoEnter(_ enabled: Bool) {
    autoEnterEnabled = enabled
  }

  /// 手动点击画中画按钮。
  func start(arguments: [String: Any], in hostView: UIView) -> Bool {
    lastPositionMs = arguments["positionMs"] as? Int ?? lastPositionMs
    if pipController == nil {
      guard prepare(arguments: arguments, in: hostView) else {
        channel.invokeMethod("failed", arguments: "Picture in Picture is unavailable")
        return false
      }
    }
    return enterPictureInPicture(notifyFailure: true, attemptsRemaining: 40)
  }

  func dispose() {
    teardown(notify: false)
  }

  // MARK: - 进入画中画

  @objc private func handleWillResignActive() {
    guard autoEnterEnabled,
      isSourcePlaying,
      pipController != nil,
      isActive == false
    else { return }
    // 通知 Dart 暂停 mpv，避免两个播放器同时出声。
    channel.invokeMethod("willEnterPip", arguments: nil)
    // 仍在前台的这一小段窗口内必须同步发起，切后台后系统会拒绝。
    _ = enterPictureInPicture(notifyFailure: false, attemptsRemaining: 6)
  }

  private func enterPictureInPicture(
    notifyFailure: Bool,
    attemptsRemaining: Int
  ) -> Bool {
    guard let controller = pipController, let player = self.player else {
      if notifyFailure {
        channel.invokeMethod("failed", arguments: "Picture in Picture is not ready")
      }
      return false
    }
    prerollTimer?.invalidate()
    player.isMuted = false
    seek(to: lastPositionMs) { [weak self] in
      self?.player?.play()
    }
    startWhenPossible(controller: controller,
                      notifyFailure: notifyFailure,
                      attemptsRemaining: attemptsRemaining)
    return true
  }

  private func startWhenPossible(
    controller: AVPictureInPictureController,
    notifyFailure: Bool,
    attemptsRemaining: Int
  ) {
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
      return
    }
    guard attemptsRemaining > 0 else {
      if notifyFailure {
        channel.invokeMethod("failed", arguments: "Picture in Picture did not become ready")
      }
      player?.pause()
      player?.isMuted = true
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.startWhenPossible(controller: controller,
                              notifyFailure: notifyFailure,
                              attemptsRemaining: attemptsRemaining - 1)
    }
  }

  private func seek(to positionMs: Int, completion: (() -> Void)? = nil) {
    guard let player = self.player else {
      completion?()
      return
    }
    let target = CMTime(value: CMTimeValue(max(positionMs, 0)), timescale: 1000)
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
      completion?()
    }
  }

  // MARK: - 清理

  private func currentPositionMs() -> Int {
    let seconds = player?.currentTime().seconds ?? 0
    return seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : lastPositionMs
  }

  private func teardown(notify: Bool) {
    let positionMs = currentPositionMs()
    prerollTimer?.invalidate()
    prerollTimer = nil
    player?.pause()
    pipController?.delegate = nil
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    playerLayer?.removeFromSuperlayer()
    player = nil
    playerLayer = nil
    pipController = nil
    currentUrl = nil
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
    player?.pause()
    player?.isMuted = true
    channel.invokeMethod("failed", arguments: error.localizedDescription)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // 保留影子播放器，方便下一次继续自动进入画中画。
    let positionMs = currentPositionMs()
    player?.pause()
    player?.isMuted = true
    lastPositionMs = positionMs
    channel.invokeMethod("stopped", arguments: ["positionMs": positionMs])
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
        case "prepare":
          result(controller.prepare(arguments: arguments, in: hostView))
        case "updatePosition":
          controller.updatePosition(arguments: arguments)
          result(nil)
        case "setAutoEnter":
          controller.setAutoEnter(arguments["enabled"] as? Bool ?? true)
          result(nil)
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
