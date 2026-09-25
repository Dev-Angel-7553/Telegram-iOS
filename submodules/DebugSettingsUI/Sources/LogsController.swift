import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import ZipArchive

// Onyxgram: a minimal, end-user-facing Logs screen (surfaced from Settings, "like beta Telegram").
// It intentionally does NOT expose the full DebugController (which contains destructive/dev-only actions).
// It offers: toggle file logging, send all collected logs as a .zip archive, and clear the logs on disk.

private let logsAllTypes: [String] = [
    "app-logs",
    "broadcast-logs",
    "siri-logs",
    "widget-logs",
    "notificationcontent-logs",
    "notification-logs"
]

private final class LogsControllerArguments {
    let sharedContext: SharedAccountContext
    let context: AccountContext?
    let presentController: (ViewController, ViewControllerPresentationArguments?) -> Void
    let pushController: (ViewController) -> Void
    let sendLogs: () -> Void
    let saveLogs: () -> Void
    let clearLogs: () -> Void

    init(sharedContext: SharedAccountContext, context: AccountContext?, presentController: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void, pushController: @escaping (ViewController) -> Void, sendLogs: @escaping () -> Void, saveLogs: @escaping () -> Void, clearLogs: @escaping () -> Void) {
        self.sharedContext = sharedContext
        self.context = context
        self.presentController = presentController
        self.pushController = pushController
        self.sendLogs = sendLogs
        self.saveLogs = saveLogs
        self.clearLogs = clearLogs
    }
}

private enum LogsSection: Int32 {
    case settings
    case actions
}

private enum LogsEntry: ItemListNodeEntry {
    case settingsHeader(String)
    case logToFile(String, Bool)
    case logToConsole(String, Bool)
    case redactSensitiveData(String, Bool)
    case settingsInfo(String)
    case sendLogs(String)
    case saveLogs(String)
    case clearLogs(String)
    case actionsInfo(String)

    var section: ItemListSectionId {
        switch self {
        case .settingsHeader, .logToFile, .logToConsole, .redactSensitiveData, .settingsInfo:
            return LogsSection.settings.rawValue
        case .sendLogs, .saveLogs, .clearLogs, .actionsInfo:
            return LogsSection.actions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .settingsHeader:
            return 0
        case .logToFile:
            return 1
        case .logToConsole:
            return 2
        case .redactSensitiveData:
            return 3
        case .settingsInfo:
            return 4
        case .sendLogs:
            return 5
        case .saveLogs:
            return 6
        case .clearLogs:
            return 7
        case .actionsInfo:
            return 8
        }
    }

    static func <(lhs: LogsEntry, rhs: LogsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LogsControllerArguments
        switch self {
        case let .settingsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .logToFile(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedLogToFile(value)
                }).start()
            })
        case let .logToConsole(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedLogToConsole(value)
                }).start()
            })
        case let .redactSensitiveData(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                let _ = updateLoggingSettings(accountManager: arguments.sharedContext.accountManager, {
                    $0.withUpdatedRedactSensitiveData(value)
                }).start()
            })
        case let .settingsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .sendLogs(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.sendLogs()
            })
        case let .saveLogs(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.saveLogs()
            })
        case let .clearLogs(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.clearLogs()
            })
        case let .actionsInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func logsControllerEntries(loggingSettings: LoggingSettings) -> [LogsEntry] {
    var entries: [LogsEntry] = []

    entries.append(.settingsHeader("LOGGING"))
    entries.append(.logToFile("Log to File", loggingSettings.logToFile))
    entries.append(.logToConsole("Log to Console", loggingSettings.logToConsole))
    entries.append(.redactSensitiveData("Remove Sensitive Data", loggingSettings.redactSensitiveData))
    entries.append(.settingsInfo("Logs are written to disk while \"Log to File\" is on. They are stored only on this device until you send them."))

    entries.append(.sendLogs("Send Logs"))
    entries.append(.saveLogs("Save Logs to Files"))
    entries.append(.clearLogs("Clear Logs"))
    entries.append(.actionsInfo("\"Send Logs\" packs all collected logs into a .zip archive and lets you forward it to a chat. \"Save Logs to Files\" downloads that same archive onto this device (Save to Files, AirDrop, …). \"Clear Logs\" deletes them from this device."))

    return entries
}

private func clearAllLogs(basePath: String) {
    let fileManager = FileManager.default
    for type in logsAllTypes {
        let logsPath = basePath + "/logs/\(type)"
        guard let names = try? fileManager.contentsOfDirectory(atPath: logsPath) else {
            continue
        }
        for name in names {
            if name.hasPrefix("log-") || name.hasPrefix("critlog-") {
                let _ = try? fileManager.removeItem(atPath: logsPath + "/" + name)
            }
        }
    }
}

// Builds a single .zip archive of all collected logs on disk and hands the caller a temp file
// (named "Logs-iOS.zip") on the main queue. Shared by both "Send Logs" (forward to a chat) and
// "Save Logs to Files" (export to the phone via the native share sheet). The caller owns the
// returned temp file: read its bytes / present it, then dispose it via EngineTempBox.
private func buildLogsArchive(context: AccountContext, completion: @escaping (EngineTempBox.File?) -> Void) {
    var logByType: [Signal<(type: String, logs: [(String, String)]), NoError>] = []
    for type in logsAllTypes {
        let logsPath = context.sharedContext.basePath + "/logs/\(type)"
        logByType.append(Logger(rootPath: logsPath, basePath: logsPath).collectLogs()
        |> map { result -> (type: String, logs: [(String, String)]) in
            return (type, result)
        })
    }

    let _ = (combineLatest(logByType)
    |> deliverOnMainQueue).start(next: { allLogs in
        let lineFeed = "\n".data(using: .utf8)!
        var tempSources: [EngineTempBox.File] = []
        for (type, logItems) in allLogs {
            if logItems.isEmpty {
                continue
            }
            let tempSource = EngineTempBox.shared.tempFile(fileName: "Log-\(type).txt")
            var rawLogData: Data = Data()
            for (name, path) in logItems {
                if !rawLogData.isEmpty {
                    rawLogData.append(lineFeed)
                    rawLogData.append(lineFeed)
                }
                rawLogData.append("------ File: \(name) ------\n".data(using: .utf8)!)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    rawLogData.append(data)
                }
            }
            let _ = try? rawLogData.write(to: URL(fileURLWithPath: tempSource.path))
            tempSources.append(tempSource)
        }

        if tempSources.isEmpty {
            completion(nil)
            return
        }

        let tempZip = EngineTempBox.shared.tempFile(fileName: "Logs-iOS.zip")
        SSZipArchive.createZipFile(atPath: tempZip.path, withFilesAtPaths: tempSources.map(\.path))
        for tempSource in tempSources {
            EngineTempBox.shared.dispose(tempSource)
        }

        completion(tempZip)
    })
}

private func sendAllLogsAsArchive(context: AccountContext, pushController: @escaping (ViewController) -> Void) {
    let controller = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: context, filter: [.onlyWriteable, .excludeDisabled]))
    controller.peerSelected = { [weak controller] peer, _ in
        let peerId = peer.id
        guard let strongController = controller else {
            return
        }
        strongController.dismiss()

        buildLogsArchive(context: context, completion: { tempZip in
            guard let tempZip, let gzippedData = try? Data(contentsOf: URL(fileURLWithPath: tempZip.path)) else {
                return
            }
            EngineTempBox.shared.dispose(tempZip)

            let id = Int64.random(in: Int64.min ... Int64.max)
            let fileResource = LocalFileMediaResource(fileId: id, size: Int64(gzippedData.count), isSecretRelated: false)
            context.engine.resources.storeResourceData(id: EngineMediaResource.Id(fileResource.id), data: gzippedData)

            let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: fileResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/zip", size: Int64(gzippedData.count), attributes: [.FileName(fileName: "Logs-iOS.zip")], alternativeRepresentations: [])
            let message: EnqueueMessage = .message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: file), threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])

            let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [message]).start()
        })
    }
    pushController(controller)
}

// Exports the logs archive to the phone using the native iOS share sheet. This surfaces
// "Save to Files" (and AirDrop / third-party apps) so the user can download the .zip onto the
// device without sending it to a chat.
private func saveAllLogsToFiles(context: AccountContext, sourceView: UIView?, present: @escaping (ViewController, ViewControllerPresentationArguments?) -> Void) {
    buildLogsArchive(context: context, completion: { tempZip in
        guard let tempZip else {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            present(textAlertController(sharedContext: context.sharedContext, title: nil, text: "There are no logs to save yet.", actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), nil)
            return
        }

        let fileUrl = URL(fileURLWithPath: tempZip.path)
        let activityController = UIActivityViewController(activityItems: [fileUrl], applicationActivities: nil)
        activityController.completionWithItemsHandler = { _, _, _, _ in
            EngineTempBox.shared.dispose(tempZip)
        }
        if let sourceView, let window = sourceView.window {
            activityController.popoverPresentationController?.sourceView = window
            activityController.popoverPresentationController?.sourceRect = CGRect(origin: CGPoint(x: window.bounds.width / 2.0, y: window.bounds.size.height - 1.0), size: CGSize(width: 1.0, height: 1.0))
        }
        context.sharedContext.applicationBindings.presentNativeController(activityController)
    })
}

public func logsController(context: AccountContext, sharedContext: SharedAccountContext, modal: Bool = false) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var getSourceViewImpl: (() -> UIView?)?

    let arguments = LogsControllerArguments(sharedContext: sharedContext, context: context, presentController: { controller, arguments in
        presentControllerImpl?(controller, arguments)
    }, pushController: { controller in
        pushControllerImpl?(controller)
    }, sendLogs: {
        sendAllLogsAsArchive(context: context, pushController: { controller in
            pushControllerImpl?(controller)
        })
    }, saveLogs: {
        saveAllLogsToFiles(context: context, sourceView: getSourceViewImpl?(), present: { controller, arguments in
            presentControllerImpl?(controller, arguments)
        })
    }, clearLogs: {
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([ActionSheetItemGroup(items: [
            ActionSheetTextItem(title: "All logs stored on this device will be deleted."),
            ActionSheetButtonItem(title: "Clear Logs", color: .destructive, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                clearAllLogs(basePath: sharedContext.basePath)
            })
        ]), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentControllerImpl?(actionSheet, nil)
    })

    let signal = combineLatest(sharedContext.presentationData, sharedContext.accountManager.sharedData(keys: Set([SharedDataKeys.loggingSettings])))
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let loggingSettings: LoggingSettings = sharedData.entries[SharedDataKeys.loggingSettings]?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings

        var leftNavigationButton: ItemListNavigationButton?
        if modal {
            leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
                dismissImpl?()
            })
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Logs"), leftNavigationButton: leftNavigationButton, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: logsControllerEntries(loggingSettings: loggingSettings), style: .blocks)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(sharedContext: sharedContext, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    getSourceViewImpl = { [weak controller] in
        return controller?.view
    }
    return controller
}
