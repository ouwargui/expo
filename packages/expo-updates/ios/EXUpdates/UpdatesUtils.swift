//  Copyright © 2019 650 Industries. All rights reserved.

// swiftlint:disable force_unwrapping
// swiftlint:disable type_body_length
// swiftlint:disable function_body_length

import Foundation
import SystemConfiguration
import CommonCrypto
import Reachability
import ExpoModulesCore

internal extension Array where Element: Equatable {
  mutating func remove(_ element: Element) {
    if let index = firstIndex(of: element) {
      remove(at: index)
    }
  }
}

@objc(EXUpdatesUtils)
@objcMembers
public final class UpdatesUtils: NSObject {
  private static let EXUpdatesEventName = "Expo.nativeUpdatesEvent"
  private static let EXUpdatesUtilsErrorDomain = "EXUpdatesUtils"
  public static let methodQueue = DispatchQueue(label: "expo.modules.EXUpdatesQueue")

  internal static func runBlockOnMainThread(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async {
        block()
      }
    }
  }

  internal static func hexEncodedSHA256WithData(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
      _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.reduce("") { $0 + String(format: "%02x", $1) }
  }

  internal static func base64UrlEncodedSHA256WithData(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
      _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
    }
    let base64EncodedDigest = Data(digest).base64EncodedString()

    // ref. https://datatracker.ietf.org/doc/html/rfc4648#section-5
    return base64EncodedDigest
      .trimmingCharacters(in: CharacterSet(charactersIn: "=")) // remove extra padding
      .replacingOccurrences(of: "+", with: "-") // replace "+" character w/ "-"
      .replacingOccurrences(of: "/", with: "_") // replace "/" character w/ "_"
  }

  public static func initializeUpdatesDirectory() throws -> URL {
    let fileManager = FileManager.default
    let applicationDocumentsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).last!
    let updatesDirectory = applicationDocumentsDirectory.appendingPathComponent(".expo-internal")
    let updatesDirectoryPath = updatesDirectory.path

    var isDir = ObjCBool(false)
    let exists = fileManager.fileExists(atPath: updatesDirectoryPath, isDirectory: &isDir)

    if exists {
      if !isDir.boolValue {
        throw NSError(
          domain: EXUpdatesUtilsErrorDomain,
          code: 1005,
          userInfo: [
            NSLocalizedDescriptionKey: "Failed to create the Updates Directory; a file already exists with the required directory name"
          ]
        )
      }
    } else {
      try fileManager.createDirectory(atPath: updatesDirectoryPath, withIntermediateDirectories: true)
    }
    return updatesDirectory
  }

  public static func checkForUpdate(_ updatesService: (any EXUpdatesModuleInterface)?, _ block: @escaping ([String: Any]) -> Void) {
    let maybeConfig: UpdatesConfig? = updatesService?.config ?? AppController.sharedInstance.config
    let maybeSelectionPolicy: SelectionPolicy? = updatesService?.selectionPolicy ?? AppController.sharedInstance.selectionPolicy()
    let maybeIsStarted: Bool? = updatesService?.isStarted ?? AppController.sharedInstance.isStarted

    guard let config = maybeConfig,
      let selectionPolicy = maybeSelectionPolicy,
      config.isEnabled
    else {
      block(["message": UpdatesDisabledException().localizedDescription])
      return
    }
    guard maybeIsStarted ?? false else {
      block(["message": UpdatesNotInitializedException().localizedDescription])
      return
    }

    let database = updatesService?.database ?? AppController.sharedInstance.database
    let launchedUpdate = updatesService?.launchedUpdate ?? AppController.sharedInstance.launchedUpdate()
    let embeddedUpdate = updatesService?.embeddedUpdate ?? EmbeddedAppLoader.embeddedManifest(withConfig: config, database: database)

    var extraHeaders: [String: Any] = [:]
    database.databaseQueue.sync {
      extraHeaders = FileDownloader.extraHeadersForRemoteUpdateRequest(
        withDatabase: database,
        config: config,
        launchedUpdate: launchedUpdate,
        embeddedUpdate: embeddedUpdate
      )
    }

    let fileDownloader = FileDownloader(config: config)
    fileDownloader.downloadRemoteUpdate(
      // swiftlint:disable:next force_unwrapping
      fromURL: config.updateUrl!,
      withDatabase: database,
      extraHeaders: extraHeaders
    ) { updateResponse in
      guard let update = updateResponse.manifestUpdateResponsePart?.updateManifest else {
        postUpdateEventNotification(AppController.NoUpdateAvailableEventName)
        block([:])
        return
      }

      let launchedUpdate = launchedUpdate
      if selectionPolicy.shouldLoadNewUpdate(update, withLaunchedUpdate: launchedUpdate, filters: updateResponse.responseHeaderData?.manifestFilters) {
        let body = [
          "manifest": update.manifest.rawManifestJSON()
        ]
        block(body)
        postUpdateEventNotification(AppController.UpdateAvailableEventName, body: body)
      } else {
        block([:])
        postUpdateEventNotification(AppController.NoUpdateAvailableEventName)
      }
    } errorBlock: { error in
      let body = ["message": error.localizedDescription]
      block(body)
      postUpdateEventNotification(AppController.ErrorEventName, body: body)
    }
  }

  public static func fetchUpdate(_ updatesService: (any EXUpdatesModuleInterface)?, _ block: @escaping ([String: Any]) -> Void) {
    postUpdateEventNotification(AppController.DownloadStartEventName)
    guard let updatesService = updatesService,
      let config = updatesService.config,
      let selectionPolicy = updatesService.selectionPolicy,
      config.isEnabled else {
      let body = ["message": UpdatesDisabledException().localizedDescription]
      block(body)
      postUpdateEventNotification(AppController.ErrorEventName, body: body)
      return
    }
    guard updatesService.isStarted else {
      let body = ["message": UpdatesNotInitializedException().localizedDescription]
      block(body)
      postUpdateEventNotification(AppController.ErrorEventName, body: body)
      return
    }

    let remoteAppLoader = RemoteAppLoader(
      config: config,
      database: updatesService.database,
      directory: updatesService.directory,
      launchedUpdate: updatesService.launchedUpdate,
      completionQueue: methodQueue
    )
    remoteAppLoader.loadUpdate(
      // swiftlint:disable:next force_unwrapping
      fromURL: config.updateUrl!
    ) { updateResponse in
      if let updateDirective = updateResponse.directiveUpdateResponsePart?.updateDirective {
        switch updateDirective {
        case is NoUpdateAvailableUpdateDirective:
          return false
        case is RollBackToEmbeddedUpdateDirective:
          return true
        default:
          NSException(name: .internalInconsistencyException, reason: "Unhandled update directive type").raise()
          return false
        }
      }

      guard let update = updateResponse.manifestUpdateResponsePart?.updateManifest else {
        return false
      }

      return selectionPolicy.shouldLoadNewUpdate(
        update,
        withLaunchedUpdate: updatesService.launchedUpdate,
        filters: updateResponse.responseHeaderData?.manifestFilters
      )
    } asset: { asset, successfulAssetCount, failedAssetCount, totalAssetCount in
      postUpdateEventNotification(AppController.DownloadAssetEventName, body: [
        "assetInfo": [
          "assetName": asset.filename,
          "successfulAssetCount": successfulAssetCount,
          "failedAssetCount": failedAssetCount,
          "totalAssetCount": totalAssetCount
        ]
      ])
    } success: { updateResponse in
      if updateResponse?.directiveUpdateResponsePart?.updateDirective is RollBackToEmbeddedUpdateDirective {
        let body = [
          "isNew": false,
          "isRollBackToEmbedded": true
        ]
        block(body)
        postUpdateEventNotification(AppController.DownloadCompleteEventName, body: body)
        return
      } else {
        if let update = updateResponse?.manifestUpdateResponsePart?.updateManifest {
          updatesService.resetSelectionPolicy()
          let body = [
            "isNew": true,
            "isRollBackToEmbedded": false,
            "manifest": update.manifest.rawManifestJSON()
          ]
          block(body)
          postUpdateEventNotification(AppController.DownloadCompleteEventName, body: body)
          return
        } else {
          let body = [
            "isNew": false,
            "isRollBackToEmbedded": false
          ]
          block(body)
          postUpdateEventNotification(AppController.DownloadCompleteEventName, body: body)
          return
        }
      }
    } error: { error in
      let body = ["message": "Failed to download new update: \(error.localizedDescription)"]
      block(body)
      postUpdateEventNotification(AppController.ErrorEventName, body: body)
    }
  }

  internal static func shouldCheckForUpdate(withConfig config: UpdatesConfig) -> Bool {
    func isConnectedToWifi() -> Bool {
      do {
        return try Reachability().connection == .wifi
      } catch {
        return false
      }
    }

    switch config.checkOnLaunch {
    case .Always:
      return true
    case .WifiOnly:
      return isConnectedToWifi()
    case .Never:
      return false
    case .ErrorRecoveryOnly:
      // check will happen later on if there's an error
      return false
    }
  }

  internal static func postUpdateEventNotification(_ type: String, body: [AnyHashable: Any] = [:]) {
    AppController.sharedInstance.postUpdateEventNotification(type, body: body)
  }

  internal static func getRuntimeVersion(withConfig config: UpdatesConfig) -> String {
    // various places in the code assume that we have a nonnull runtimeVersion, so if the developer
    // hasn't configured either runtimeVersion or sdkVersion, we'll use a dummy value of "1" but warn
    // the developer in JS that they need to configure one of these values
    return config.runtimeVersion ?? config.sdkVersion ?? "1"
  }

  internal static func url(forBundledAsset asset: UpdateAsset) -> URL? {
    guard let mainBundleDir = asset.mainBundleDir else {
      return Bundle.main.url(forResource: asset.mainBundleFilename, withExtension: asset.type)
    }
    return Bundle.main.url(forResource: asset.mainBundleFilename, withExtension: asset.type, subdirectory: mainBundleDir)
  }

  internal static func path(forBundledAsset asset: UpdateAsset) -> String? {
    guard let mainBundleDir = asset.mainBundleDir else {
      return Bundle.main.path(forResource: asset.mainBundleFilename, ofType: asset.type)
    }
    return Bundle.main.path(forResource: asset.mainBundleFilename, ofType: asset.type, inDirectory: mainBundleDir)
  }

  /**
   Purges entries in the expo-updates log file that are older than 1 day
   */
  internal static func purgeUpdatesLogsOlderThanOneDay() {
    UpdatesLogReader().purgeLogEntries { error in
      if let error = error {
        NSLog("UpdatesUtils: error in purgeOldUpdatesLogs: %@", error.localizedDescription)
      }
    }
  }

  internal static func isNativeDebuggingEnabled() -> Bool {
    #if EX_UPDATES_NATIVE_DEBUG
    return true
    #else
    return false
    #endif
  }
}
