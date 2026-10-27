import AVFAudio
import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import Network
import SafariServices
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var nowPlaying: NowPlaying?
  private var mediaLibrary: MediaLibrary?
  private var applePlayer: ApplePlayer?
  private var appIcon: FlutterMethodChannel?
  private var notifications: FlutterMethodChannel?
  private let browser = Browser()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The Rust engine opens a plain CoreAudio stream; the playback category is what keeps it
    // sounding with the silent switch on and the screen locked. The session is activated when
    // playback starts, so opening the app does not stop another app's music.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    } catch {
      NSLog("playback: cannot configure the audio session: \(error)")
    }
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "CauceNowPlaying") {
      nowPlaying = NowPlaying(messenger: registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "CauceMediaLibrary") {
      mediaLibrary = MediaLibrary(messenger: registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "CauceAudioControls") {
      registrar.register(SystemViewFactory { _ in VolumeSlider() }, withId: "cauce/volume")
      registrar.register(SystemViewFactory { _ in RoutePicker() }, withId: "cauce/route_picker")
      // Invisible, over a button Dart draws, so a whole chip opens the output list.
      registrar.register(SystemViewFactory { _ in RoutePicker(clear: true) }, withId: "cauce/route_picker_clear")
    }
    if let registrar = registrar(forPlugin: "CauceAppIcon") {
      appIcon = FlutterMethodChannel(name: "cauce/app_icon", binaryMessenger: registrar.messenger())
      // "set" takes an alternate icon's name, or nil for the app's own.
      appIcon?.setMethodCallHandler { call, result in
        guard call.method == "set" else { return result(FlutterMethodNotImplemented) }
        let name = (call.arguments as? String).map { "AppIcon-" + $0.prefix(1).uppercased() + $0.dropFirst() }
        guard UIApplication.shared.supportsAlternateIcons else {
          return result(FlutterError(code: "unsupported", message: nil, details: nil))
        }
        UIApplication.shared.setAlternateIconName(name) { error in
          result(error.map { FlutterError(code: "failed", message: $0.localizedDescription, details: nil) })
        }
      }
    }
    if let registrar = registrar(forPlugin: "CauceNotifications") {
      notifications = FlutterMethodChannel(name: "cauce/notifications", binaryMessenger: registrar.messenger())
      // "ask" requests permission once; "post" shows a notification now, if allowed.
      notifications?.setMethodCallHandler { call, result in
        let center = UNUserNotificationCenter.current()
        switch call.method {
        case "ask":
          center.requestAuthorization(options: [.alert, .sound]) { _, _ in result(nil) }
        case "post":
          let arguments = call.arguments as? [String: String] ?? [:]
          let content = UNMutableNotificationContent()
          content.title = arguments["title"] ?? ""
          content.body = arguments["body"] ?? ""
          center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
            result(nil)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = registrar(forPlugin: "CauceBrowser") {
      browser.attach(registrar.messenger())
    }
    if let registrar = registrar(forPlugin: "CauceApplePlayer") {
      applePlayer = ApplePlayer(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Safari inside the app, for sign-ins Google refuses in a webview. The app stays in front, so a
/// redirect to the core's loopback listener still reaches it.
final class Browser: NSObject, SFSafariViewControllerDelegate {
  private var channel: FlutterMethodChannel?
  private weak var shown: SFSafariViewController?

  func attach(_ messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cauce/browser", binaryMessenger: messenger)
    // "open" shows a page; "close" takes it away. Closing it by hand sends "closed" back.
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "open":
        guard let text = call.arguments as? String, let url = URL(string: text) else {
          return result(FlutterError(code: "url", message: nil, details: nil))
        }
        result(self.open(url))
      case "close":
        self.shown?.dismiss(animated: true)
        self.shown = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func open(_ url: URL) -> Bool {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
    while let presented = top.presentedViewController { top = presented }
    let safari = SFSafariViewController(url: url)
    safari.delegate = self
    shown = safari
    top.present(safari, animated: true)
    return true
  }

  func safariViewControllerDidFinish(_: SFSafariViewController) {
    shown = nil
    channel?.invokeMethod("closed", arguments: nil)
  }
}

/// Makes one of the system's own audio controls for Flutter to embed.
final class SystemViewFactory: NSObject, FlutterPlatformViewFactory {
  private let make: (CGRect) -> UIView

  init(make: @escaping (CGRect) -> UIView) {
    self.make = make
  }

  func create(withFrame frame: CGRect, viewIdentifier _: Int64, arguments _: Any?) -> FlutterPlatformView {
    SystemView(make(frame))
  }
}

final class SystemView: NSObject, FlutterPlatformView {
  private let content: UIView

  init(_ content: UIView) {
    self.content = content
  }

  func view() -> UIView { content }
}

/// The system volume slider: it moves the phone's own volume, follows the volume buttons, and
/// greys out where the route sets its own volume (AirPlay to some speakers).
final class VolumeSlider: UIView {
  private let slider = CenteredVolumeView()

  init() {
    super.init(frame: .zero)
    slider.setVolumeThumbImage(Self.thumb(diameter: 14), for: .normal)
    slider.setVolumeThumbImage(Self.thumb(diameter: 18), for: .highlighted)
    slider.tintColor = .white
    addSubview(slider)
  }

  required init?(coder _: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    slider.frame = bounds
  }

  /// A plain white dot, smaller than the system's default knob.
  private static func thumb(diameter: CGFloat) -> UIImage {
    let size = CGSize(width: diameter, height: diameter)
    return UIGraphicsImageRenderer(size: size).image { context in
      UIColor.white.setFill()
      context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
    }
  }
}

/// MPVolumeView lays its slider at the top of its frame; this one centers it, so it lines up
/// with the icons beside it.
final class CenteredVolumeView: MPVolumeView {
  override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
    let natural = super.volumeSliderRect(forBounds: bounds)
    return CGRect(x: bounds.minX, y: bounds.midY - natural.height / 2, width: bounds.width, height: natural.height)
  }
}

/// The system output picker, the one Music opens: the iPhone speaker, AirPlay and Bluetooth
/// devices.
final class RoutePicker: UIView {
  private let picker = AVRoutePickerView()
  /// Its glyph keeps one size whatever the frame, so it is scaled to sit with the 28 pt icons.
  private let scale: CGFloat = 1.3

  init(clear: Bool = false) {
    super.init(frame: .zero)
    picker.tintColor = clear ? .clear : UIColor(white: 0.56, alpha: 1)
    picker.activeTintColor = clear ? .clear : .white
    picker.prioritizesVideoDevices = false
    picker.transform = CGAffineTransform(scaleX: scale, y: scale)
    addSubview(picker)
  }

  required init?(coder _: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    picker.bounds = CGRect(x: 0, y: 0, width: bounds.width / scale, height: bounds.height / scale)
    picker.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}

/// The lock screen and Control Center player, and the audio session events Dart has to act on.
/// Dart sends what is playing on `update`; remote commands and interruptions come back as
/// `command` calls naming what to do.
final class NowPlaying {
  private let channel: FlutterMethodChannel
  private var artworkURL: String?
  /// Whether the last update said playing, so the session is claimed once per start.
  private var playing = false
  /// Another app took the audio since the last claim. The engine's output stopped then and is
  /// not restarted by anything but a new engine.
  private var interrupted = false
  /// When playback was paused because the headphones went away, so it resumes when they come
  /// back, as the AirPods do. Any play or pause the listener asks for clears it.
  private var unpluggedAt: Date?
  /// How long after the headphones left their return still resumes.
  private let resumeWithin: TimeInterval = 30 * 60
  /// Lets the audio go once playback has stayed paused this long.
  private let releaseAfter: TimeInterval = 3
  private var release: DispatchWorkItem?
  private var artwork: MPMediaItemArtwork?
  /// Plays when headphones connect, not only when they come back after dropping off.
  private var resumeOnConnect = false
  /// Tells Dart whether the phone is on mobile data, which picks the stream quality.
  private let network = NWPathMonitor()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cauce/now_playing", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "update":
        self?.update(call.arguments as? [String: Any] ?? [:])
        result(nil)
      case "claim":
        self?.unpluggedAt = nil
        // The system's player keeps an audio session of its own; taking ours would cut it off.
        if ApplePlayer.engaged { return result(false) }
        // Asked before every play: takes the audio, and answers whether the output has to be
        // opened again because another app had it.
        do {
          try AVAudioSession.sharedInstance().setActive(true)
        } catch {
          NSLog("playback: cannot activate the audio session: \(error)")
        }
        result(self?.interrupted ?? false)
        self?.interrupted = false
      case "clear":
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        result(nil)
      case "volume":
        // The tape's stepped volume: the phone's own, set through a system volume view.
        self?.setVolume(Float(call.arguments as? Double ?? 0))
        result(nil)
      case "output":
        self?.sendOutput()
        result(nil)
      case "options":
        let options = call.arguments as? [String: Any] ?? [:]
        self?.resumeOnConnect = options["resumeOnConnect"] as? Bool ?? false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    UIApplication.shared.beginReceivingRemoteControlEvents()
    volumeWatch = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
      self?.send("volume", session.outputVolume)
    }
    registerCommands()
    observeSession()
    network.pathUpdateHandler = { [weak self] path in
      self?.send("network", path.status == .satisfied && path.usesInterfaceType(.cellular))
      self?.send("online", path.status == .satisfied)
    }
    network.start(queue: DispatchQueue(label: "dev.manuxdev.cauce.network"))
  }

  /// What plays the sound now, by the name the phone shows, for the player's output chip. Only
  /// sent to Dart for the screen, never written to the log.
  private func sendOutput() {
    send("output", AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName)
    send("volume", AVAudioSession.sharedInstance().outputVolume)
  }

  /// Kept while the phone's volume is watched.
  private var volumeWatch: NSKeyValueObservation?
  /// Set through, off screen, only while setting the volume, as it hides the system's volume HUD.
  private var volumeView: MPVolumeView?
  /// Counts the sets, so the view leaves 1.5 s after the last one.
  private var volumeSets = 0

  private func setVolume(_ value: Float) {
    let view = volumeView ?? MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
    if volumeView == nil {
      volumeView = view
      UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.addSubview(view)
    }
    let slider = view.subviews.compactMap { $0 as? UISlider }.first
    // The view needs a moment in the window before its slider takes a value.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      slider?.value = min(max(value, 0), 1)
    }
    volumeSets += 1
    let set = volumeSets
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.volumeSets == set else { return }
      view.removeFromSuperview()
      self.volumeView = nil
    }
  }

  private func send(_ command: String, _ argument: Any? = nil) {
    DispatchQueue.main.async {
      self.channel.invokeMethod("command", arguments: ["name": command, "value": argument as Any])
    }
  }

  /// A play or pause from the lock screen or the headphones, noted in the log with when it came.
  private func remote(_ command: String) {
    note("remote \(command)")
    unpluggedAt = nil
    send(command)
  }

  /// A line in Cauce's log. Only kinds of events and port types, never a device's name.
  private func note(_ text: String) {
    DispatchQueue.main.async {
      self.channel.invokeMethod("log", arguments: text)
    }
  }

  private func registerCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in self?.remote("play"); return .success }
    center.pauseCommand.addTarget { [weak self] _ in self?.remote("pause"); return .success }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.remote("toggle"); return .success }
    center.nextTrackCommand.addTarget { [weak self] _ in self?.send("next"); return .success }
    center.previousTrackCommand.addTarget { [weak self] _ in self?.send("previous"); return .success }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.send("seek", event.positionTime)
      return .success
    }
  }

  private func observeSession() {
    let notifications = NotificationCenter.default
    notifications.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      // The system's player handles its own interruptions, ours included.
      guard !ApplePlayer.engaged, let info = notification.userInfo,
        let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      switch type {
      case .began:
        self?.playing = false
        self?.interrupted = true
        self?.send("pause")
      case .ended:
        let options = AVAudioSession.InterruptionOptions(
          rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        if options.contains(.shouldResume) {
          // The output comes back on its own after an interruption that ends.
          self?.interrupted = false
          try? AVAudioSession.sharedInstance().setActive(true)
          self?.send("play")
        }
      @unknown default:
        break
      }
    }
    // Headphones pulled out: pause rather than play out loud. The engine's output stays tied to
    // the device that left, which upstream leaves alone since a desktop moves it by itself, so
    // the next play opens a new one as after an interruption.
    notifications.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self,
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
      else { return }
      let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        .map { $0.portType.rawValue }.joined(separator: ",")
      self.note("route \(raw) now \(ports)")
      self.sendOutput()
      switch reason {
      case .oldDeviceUnavailable:
        if self.playing { self.unpluggedAt = Date() }
        self.playing = false
        self.interrupted = true
        self.send("pause")
      case .newDeviceAvailable:
        let headphones: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let wearing = AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphones.contains($0.portType) }
        if self.resumeOnConnect, wearing, !self.playing {
          self.unpluggedAt = nil
          self.note("playing as headphones connected")
          self.send("play")
          return
        }
        // Headphones that pause by dropping off and come back without asking to play.
        guard let at = self.unpluggedAt, Date().timeIntervalSince(at) < self.resumeWithin else { return }
        self.unpluggedAt = nil
        self.note("resuming as the headphones came back")
        self.send("play")
      case .override, .routeConfigurationChange:
        // A new output picked, as AirPlay's picker does: the engine's output breaks with the
        // route and does not come back by itself, so a new one is opened where it was.
        if self.playing {
          self.send("reroute")
        } else {
          self.interrupted = true
        }
      default:
        break
      }
    }
  }

  /// Once paused for a moment, gives the audio session up. The engine's output keeps running
  /// while paused, so iOS would go on telling headphones that Cauce plays, and headphones with a
  /// wear sensor then answer being put back on with another pause instead of a play. Giving it
  /// up stops the output, and the next play opens a new one as after an interruption.
  private func scheduleRelease() {
    release?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.playing else { return }
      // Deactivating with the output running stops it and answers "busy", which is expected.
      try? AVAudioSession.sharedInstance().setActive(false)
      self.interrupted = true
      self.note("released the audio session while paused")
    }
    release = work
    DispatchQueue.main.asyncAfter(deadline: .now() + releaseAfter, execute: work)
  }

  private func update(_ values: [String: Any]) {
    // Starting to play takes the audio from whatever app had it, as any music player does. After
    // another app interrupted us the session is inactive, and without this both would sound.
    let nowPlaying = values["playing"] as? Bool ?? false
    if nowPlaying && !playing {
      release?.cancel()
      release = nil
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        NSLog("playback: cannot activate the audio session: \(error)")
      }
    }
    if !nowPlaying && playing { scheduleRelease() }
    playing = nowPlaying
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: values["title"] as? String ?? "",
      MPMediaItemPropertyArtist: values["artist"] as? String ?? "",
      MPMediaItemPropertyAlbumTitle: values["album"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: values["duration"] as? Double ?? 0,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: values["position"] as? Double ?? 0,
      MPNowPlayingInfoPropertyPlaybackRate: (values["playing"] as? Bool ?? false) ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyIsLiveStream: values["live"] as? Bool ?? false,
    ]
    let url = values["artwork"] as? String
    if url == artworkURL, let artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    } else {
      artworkURL = url
      artwork = nil
      if let url { loadArtwork(url) }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// Fetches the cover, then adds it to whatever is showing if the track has not changed since.
  private func loadArtwork(_ url: String) {
    let load: (Data) -> Void = { [weak self] data in
      guard let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard let self, self.artworkURL == url else { return }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        self.artwork = artwork
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      }
    }
    if url.hasPrefix("http"), let remote = URL(string: url) {
      URLSession.shared.dataTask(with: remote) { data, _, _ in data.map(load) }.resume()
    } else if let data = FileManager.default.contents(atPath: url) {
      load(data)
    }
  }
}

/// The songs in the phone's Music library that Cauce can play: ones with a file behind them,
/// which leaves out Apple Music downloads (DRM) and songs only in the cloud. The Rust engine reads
/// files, so a song is exported to the cache once on `export` and played from there.
final class MediaLibrary {
  private let channel: FlutterMethodChannel
  private let folder: URL
  private let folders = Folders()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cauce/media_library", binaryMessenger: messenger)
    folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("media_library", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "songs":
        mediaLibraryAuthorized { granted in
          guard granted else { return result([]) }
          DispatchQueue.global(qos: .userInitiated).async {
            let songs = self.songs()
            DispatchQueue.main.async { result(songs) }
          }
        }
      case "export":
        guard let id = call.arguments as? String else { return result(nil) }
        self.export(id) { path in DispatchQueue.main.async { result(path) } }
      case "addFolder":
        self.folders.pick { added in result(added) }
      case "folders":
        DispatchQueue.global(qos: .userInitiated).async {
          let folders = self.folders.list()
          DispatchQueue.main.async { result(folders) }
        }
      case "removeFolder":
        guard let name = call.arguments as? String else { return result(nil) }
        self.folders.remove(name)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func songs() -> [[String: Any]] {
    let items = MPMediaQuery.songs().items ?? []
    return items.compactMap { item in
      // Apple Music downloads can still report a file; the asset says whether it is protected.
      guard let url = item.assetURL, !item.hasProtectedAsset, !item.isCloudItem,
        !AVURLAsset(url: url).hasProtectedContent
      else { return nil }
      let id = String(item.persistentID)
      var song: [String: Any] = [
        "id": id,
        "title": item.title ?? "",
        "artist": item.artist ?? "",
        "album": item.albumTitle ?? "",
        "durationMs": Int(item.playbackDuration * 1000),
      ]
      if let cover = cover(of: item, id: id) { song["cover"] = cover }
      return song
    }
  }

  /// A small JPEG of the song's artwork, written once, for the list.
  private func cover(of item: MPMediaItem, id: String) -> String? {
    let file = folder.appendingPathComponent("\(id).jpg")
    if FileManager.default.fileExists(atPath: file.path) { return file.path }
    guard let image = item.artwork?.image(at: CGSize(width: 300, height: 300)),
          let data = image.jpegData(compressionQuality: 0.85),
          (try? data.write(to: file)) != nil
    else { return nil }
    return file.path
  }

  private func export(_ id: String, done: @escaping (String?) -> Void) {
    let file = folder.appendingPathComponent("\(id).m4a")
    if FileManager.default.fileExists(atPath: file.path) { return done(file.path) }
    let predicate = MPMediaPropertyPredicate(value: UInt64(id), forProperty: MPMediaItemPropertyPersistentID)
    guard let item = MPMediaQuery(filterPredicates: [predicate]).items?.first, let url = item.assetURL else {
      return done(nil)
    }
    let asset = AVURLAsset(url: url)
    AVAssetExportSession.determineCompatibility(
      ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a
    ) { passthrough in
      // A copy when the audio already fits an M4A (AAC, ALAC); an AAC encode otherwise (MP3).
      let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A
      guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { return done(nil) }
      let partial = file.appendingPathExtension("part")
      try? FileManager.default.removeItem(at: partial)
      session.outputURL = partial
      session.outputFileType = .m4a
      session.metadata = asset.commonMetadata
      session.exportAsynchronously {
        guard session.status == .completed,
              (try? FileManager.default.moveItem(at: partial, to: file)) != nil
        else {
          NSLog("media library: cannot export \(id): \(String(describing: session.error))")
          return done(nil)
        }
        done(file.path)
      }
    }
  }
}

/// Folders the listener picked in the Files app, such as On My iPhone › Downloads, kept as
/// bookmarks so their audio files show on every launch. Access stays open for the app's life,
/// since the engine reads the files by path.
final class Folders: NSObject, UIDocumentPickerDelegate {
  private static let key = "folders"
  private static let audio: Set<String> = ["mp3", "m4a", "flac", "ogg", "opus", "wav", "aiff"]
  private var picked: ((Bool) -> Void)?
  private var opened = Set<URL>()

  private var bookmarks: [String: Data] {
    get { UserDefaults.standard.dictionary(forKey: Folders.key) as? [String: Data] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: Folders.key) }
  }

  func pick(_ done: @escaping (Bool) -> Void) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return done(false) }
    while let shown = top.presentedViewController { top = shown }
    picked?(false)
    picked = done
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    top.present(picker, animated: true)
  }

  func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    for url in urls {
      guard url.startAccessingSecurityScopedResource() else { continue }
      opened.insert(url)
      if let data = try? url.bookmarkData() { bookmarks[url.lastPathComponent] = data }
    }
    picked?(!urls.isEmpty)
    picked = nil
  }

  func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
    picked?(false)
    picked = nil
  }

  func remove(_ name: String) {
    bookmarks[name] = nil
  }

  /// Each folder's name and the audio files in it, found at any depth.
  func list() -> [[String: Any]] {
    var saved = bookmarks
    var folders: [[String: Any]] = []
    for (name, data) in saved.sorted(by: { $0.key < $1.key }) {
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { continue }
      if !opened.contains(url), url.startAccessingSecurityScopedResource() { opened.insert(url) }
      if stale, let fresh = try? url.bookmarkData() { saved[name] = fresh }
      let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
      var files: [String] = []
      while let file = walker?.nextObject() as? URL {
        if Folders.audio.contains(file.pathExtension.lowercased()) { files.append(file.path) }
      }
      folders.append(["name": name, "files": files.sorted { $0.lowercased() < $1.lowercased() }])
    }
    bookmarks = saved
    return folders
  }
}

/// Apple Music through the system's queue player, driven by the Rust core over
/// `cauce/apple_player`. Tracks are catalog store ids; what the player does goes back as calls
/// named after the event, about the id loaded last.
final class ApplePlayer {
  /// Whether an Apple Music track is loaded, so the app's own audio session stays out of its way.
  static private(set) var engaged = false

  private let channel: FlutterMethodChannel
  private let player = MPMusicPlayerController.applicationQueuePlayer
  private var id = ""
  private var duration: TimeInterval = 0
  /// Where the last poll found playback; the player reads zero again once a track ends.
  private var position: TimeInterval = 0
  /// Where the track starts once prepared, moved by a seek while it prepares.
  private var startAt: TimeInterval = 0
  private var preparing = false
  /// The item the queue player prepared for the track.
  private var item: MPMediaEntityPersistentID?
  /// The track has ended or failed and been reported, so nothing more is said about it.
  private var done = true
  private var ticker: Timer?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cauce/apple_player", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let arguments = call.arguments as? [String: Any] ?? [:]
      let at = TimeInterval(arguments["at"] as? Int ?? 0) / 1000
      switch call.method {
      case "load", "cue": self.load(arguments["id"] as? String ?? "", at: at, play: call.method == "load")
      case "play": self.player.play()
      case "pause": self.player.pause()
      case "seek": self.seek(at)
      case "stop": self.stop()
      default: return result(FlutterMethodNotImplemented)
      }
      result(nil)
    }
    player.beginGeneratingPlaybackNotifications()
    let notifications = NotificationCenter.default
    notifications.addObserver(
      forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main
    ) { [weak self] _ in self?.stateChanged() }
    notifications.addObserver(
      forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main
    ) { [weak self] _ in self?.itemChanged() }
  }

  private func load(_ id: String, at: TimeInterval, play: Bool) {
    self.id = id
    duration = 0
    item = nil
    position = at
    startAt = at
    preparing = true
    done = false
    ApplePlayer.engaged = true
    stopTicker()
    send("loading", at: at)
    mediaLibraryAuthorized { [weak self] granted in
      guard let self, self.id == id, !self.done else { return }
      guard granted else {
        NSLog("apple player: the media library is not authorized")
        return self.fail()
      }
      self.player.setQueue(with: [id])
      self.player.prepareToPlay { error in
        DispatchQueue.main.async {
          // Another load or a stop came first.
          guard self.id == id, !self.done else { return }
          if let error = error as NSError? {
            NSLog("apple player: cannot prepare a track (\(error.domain) \(error.code))")
            return self.fail()
          }
          self.preparing = false
          self.item = self.player.nowPlayingItem?.persistentID
          self.readLength()
          if self.startAt > 0 { self.player.currentPlaybackTime = self.startAt }
          self.position = self.startAt
          if play {
            self.player.play()
            self.send("playing", at: self.startAt)
            self.startTicker()
          } else {
            self.send("paused", at: self.startAt)
          }
        }
      }
    }
  }

  private func seek(_ at: TimeInterval) {
    guard !done else { return }
    startAt = at
    guard !preparing else { return }
    player.currentPlaybackTime = at
    position = at
    send("seeked", at: at)
  }

  private func stop() {
    id = ""
    done = true
    preparing = false
    ApplePlayer.engaged = false
    stopTicker()
    player.stop()
  }

  private func stateChanged() {
    guard !preparing, !done else { return }
    switch player.playbackState {
    case .playing:
      startTicker()
      send("playing", at: now)
    case .paused, .stopped, .interrupted:
      // ponytail: a pause within the last 1.5 s counts as the end; the player says no more.
      if duration > 0, position >= duration - 1.5 { return finish() }
      stopTicker()
      send("paused", at: now)
    default:
      break
    }
  }

  /// The queue holds one track, so any other item, or none, means it has played out. The item is
  /// compared with the one prepared, since its store id can differ from the one asked for.
  private func itemChanged() {
    guard !preparing, !done else { return }
    guard let current = player.nowPlayingItem?.persistentID else { return finish() }
    guard let item else {
      item = current
      return
    }
    if current != item { finish() }
  }

  private func startTicker() {
    guard ticker == nil else { return }
    ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self, !self.done else { return }
      if self.duration == 0 { self.readLength() }
      self.position = self.now
      self.send("position", at: self.position)
    }
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  private func readLength() {
    guard let length = player.nowPlayingItem?.playbackDuration, length > 0 else { return }
    duration = length
    send("length", at: 0, duration: length)
  }

  private func finish() {
    done = true
    stopTicker()
    send("ended", at: position)
  }

  private func fail() {
    done = true
    preparing = false
    stopTicker()
    send("unavailable", at: 0)
  }

  private var now: TimeInterval {
    let time = player.currentPlaybackTime
    return time.isFinite ? max(0, time) : position
  }

  private func send(_ event: String, at: TimeInterval, duration: TimeInterval = 0) {
    channel.invokeMethod(event, arguments: ["id": id, "at": Int(at * 1000), "duration": Int(duration * 1000)])
  }
}

/// Whether the app may use the media library, asking the first time. Answers on the main queue.
func mediaLibraryAuthorized(_ done: @escaping (Bool) -> Void) {
  switch MPMediaLibrary.authorizationStatus() {
  case .authorized: done(true)
  case .notDetermined:
    MPMediaLibrary.requestAuthorization { status in
      DispatchQueue.main.async { done(status == .authorized) }
    }
  default: done(false)
  }
}
