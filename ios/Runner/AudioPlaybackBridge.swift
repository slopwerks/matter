import AVFoundation
import Flutter
import MediaPlayer

/// System controls contain only display metadata. Media and account secrets
/// remain in the single Dart-owned playback session.
final class AudioPlaybackBridge {
  private let channel: FlutterMethodChannel
  private var generation: Int64 = 0
  private var activated = false
  private var observers: [NSObjectProtocol] = []
  private var targets: [(MPRemoteCommand, Any)] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "moe.aks.matter/audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "waveform" || call.method == "cancelWaveform" {
        AudioWaveformDecoder.handle(call, result: result)
        return
      }
      if call.method == "update", let values = call.arguments as? [String: Any] {
        self.generation = (values["generation"] as? NSNumber)?.int64Value ?? 0
        guard let title = values["title"] as? String else { self.stop(); result(nil); return }
        let playing = values["playing"] as? Bool ?? false
        do {
          if playing && !self.activated {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            self.activated = true
          }
          let duration = ((values["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
          var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: ((values["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? ((values["speed"] as? NSNumber)?.doubleValue ?? 1) : 0,
          ]
          if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
          MPNowPlayingInfoCenter.default().nowPlayingInfo = info
          MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = duration > 0
          MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = values["hasNext"] as? Bool ?? false
          MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = values["hasPrevious"] as? Bool ?? false
          result(nil)
        } catch {
          self.send("pause")
          result(FlutterError(code: "audio_session_failed", message: "无法启用后台音频", details: nil))
        }
      } else if call.method == "stop" {
        self.stop()
        result(nil)
      } else if call.method == "release" {
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    let commands = MPRemoteCommandCenter.shared()
    bind(commands.playCommand, "play")
    bind(commands.pauseCommand, "pause")
    bind(commands.stopCommand, "stop")
    bind(commands.nextTrackCommand, "next")
    bind(commands.previousTrackCommand, "previous")
    let seek = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self?.send("seek", positionMs: Int64(position.positionTime * 1000))
      return .success
    }
    targets.append((commands.changePlaybackPositionCommand, seek))
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] event in
      if (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue {
        self?.send("pause")
      }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] event in
      if (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.send("pause")
      }
    })
  }

  private func bind(_ command: MPRemoteCommand, _ action: String) {
    let token = command.addTarget { [weak self] _ in
      self?.send(action)
      return .success
    }
    targets.append((command, token))
  }

  private func send(_ action: String, positionMs: Int64? = nil) {
    let capturedGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == capturedGeneration else { return }
      var values: [String: Any] = ["generation": capturedGeneration]
      if let positionMs { values["positionMs"] = positionMs }
      self.channel.invokeMethod(action, arguments: values)
    }
  }

  private func stop() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    if activated {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      activated = false
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    for (command, token) in targets { command.removeTarget(token) }
  }
}
