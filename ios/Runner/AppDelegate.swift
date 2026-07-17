import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var pendingFileSaveResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "moe.aks.matter/file_saver",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "saveFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(FlutterError(code: "unavailable", message: "无法保存文件", details: nil))
        return
      }
      self.saveFile(arguments: call.arguments, result: result)
    }
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
