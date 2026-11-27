import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var pendingFileSaveResult: FlutterResult?
  private var openFileController: UIDocumentInteractionController?
  private var audioPlaybackBridge: AudioPlaybackBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    audioPlaybackBridge = AudioPlaybackBridge(messenger: engineBridge.applicationRegistrar.messenger())
    let clipboard = FlutterMethodChannel(
      name: "moe.aks.matter/clipboard",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    clipboard.setMethodCallHandler { call, result in
      guard call.method == "readFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let items = UIPasteboard.general.items
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          var files: [[String: Any]] = []
          var total = 0
          for item in items {
            let fileURL: URL?
            if let value = item[UTType.fileURL.identifier] as? URL {
              fileURL = value
            } else if let value = item[UTType.fileURL.identifier] as? Data {
              fileURL = URL(dataRepresentation: value, relativeTo: nil)
            } else if let value = item[UTType.fileURL.identifier] as? String {
              fileURL = URL(string: value)
            } else {
              fileURL = nil
            }
            let data: Data
            let type: UTType?
            let name: String
            if let url = fileURL, url.isFileURL {
              let accessing = url.startAccessingSecurityScopedResource()
              defer { if accessing { url.stopAccessingSecurityScopedResource() } }
              let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
              guard values.isDirectory != true else {
                throw NSError(domain: "clipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂不支持发送文件夹"])
              }
              guard (values.fileSize ?? 0) <= 64 * 1024 * 1024 - total else {
                throw NSError(domain: "clipboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "剪贴板附件超过 64MB 限制"])
              }
              guard let stream = InputStream(url: url) else {
                throw NSError(domain: "clipboard", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法读取剪贴板文件"])
              }
              stream.open()
              defer { stream.close() }
              var contents = Data()
              var buffer = [UInt8](repeating: 0, count: 8192)
              while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? NSError(domain: "clipboard", code: 3) }
                if count == 0 { break }
                guard contents.count + count <= 64 * 1024 * 1024 - total else {
                  throw NSError(domain: "clipboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "剪贴板附件超过 64MB 限制"])
                }
                contents.append(contentsOf: buffer.prefix(count))
              }
              data = contents
              type = values.contentType
              name = url.lastPathComponent
            } else {
              guard let representation = item.first(where: { key, value in
                guard let candidate = UTType(key), value is Data else { return false }
                return !candidate.conforms(to: .text) && !candidate.conforms(to: .url) &&
                  candidate.conforms(to: .data) && candidate.preferredMIMEType != nil
              }), let value = representation.value as? Data else { continue }
              data = value
              type = UTType(representation.key)
              name = "clipboard_\(files.count).\(type?.preferredFilenameExtension ?? "bin")"
            }
            total += data.count
            guard total <= 64 * 1024 * 1024 else {
              throw NSError(domain: "clipboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "剪贴板附件超过 64MB 限制"])
            }
            files.append([
              "name": name,
              "mime": type?.preferredMIMEType ?? "application/octet-stream",
              "bytes": FlutterStandardTypedData(bytes: data),
            ])
          }
          DispatchQueue.main.async { result(files) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "clipboard_read_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    let channel = FlutterMethodChannel(
      name: "moe.aks.matter/file_saver",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "无法打开文件", details: nil))
        return
      }
      switch call.method {
      case "saveFile": self.saveFile(arguments: call.arguments, result: result)
      case "openFile": self.openFile(arguments: call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func openFile(arguments: Any?, result: @escaping FlutterResult) {
    guard let values = arguments as? [String: Any],
      let path = values["path"] as? String,
      let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
      let controller = activeViewController()
    else {
      result(FlutterError(code: "invalid_file", message: "找不到待打开的文件", details: nil))
      return
    }
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let root = cache.appendingPathComponent("matter_open_files").resolvingSymlinksInPath()
    guard file.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
      FileManager.default.fileExists(atPath: file.path)
    else {
      result(FlutterError(code: "invalid_file", message: "文件路径无效", details: nil))
      return
    }
    let document = UIDocumentInteractionController(url: file)
    document.uti = "net.daringfireball.markdown"
    openFileController = document
    result(document.presentOpenInMenu(
      from: CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1),
      in: controller.view, animated: true
    ))
  }

  private func saveFile(arguments: Any?, result: @escaping FlutterResult) {
    guard pendingFileSaveResult == nil else {
      result(FlutterError(code: "save_in_progress", message: "已有文件保存请求正在处理", details: nil))
      return
    }
    guard
      let values = arguments as? [String: Any],
      let path = values["path"] as? String,
      FileManager.default.fileExists(atPath: path),
      let controller = activeViewController()
    else {
      result(FlutterError(code: "invalid_file", message: "找不到待保存的下载文件", details: nil))
      return
    }

    let picker = UIDocumentPickerViewController(
      url: URL(fileURLWithPath: path),
      in: .exportToService
    )
    picker.delegate = self
    pendingFileSaveResult = result
    controller.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    finishFileSave(saved: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishFileSave(saved: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishFileSave(saved: false)
  }

  private func finishFileSave(saved: Bool) {
    let result = pendingFileSaveResult
    pendingFileSaveResult = nil
    result?(saved)
  }

  private func activeViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow })
    else {
      return nil
    }
    return window.rootViewController
  }
}
