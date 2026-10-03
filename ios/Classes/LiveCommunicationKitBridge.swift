import AVFoundation
import Intents
import LiveCommunicationKit
import TwilioVoice
import UIKit

/// Reports calls to the system through LiveCommunicationKit instead of CallKit, so they show in the Phone app's
/// Recents with the contact name and photo and get the full Lock Screen conversation UI.
///
/// Used on iOS 17.4 and later, older versions keep the CXProvider code in SwiftTwilioVoicePlugin. Only one of the
/// two is ever created.
@available(iOS 17.4, *)
final class LiveCommunicationKitBridge: NSObject, ConversationManagerDelegate {

    private struct Remote {
        var value: String
        var name: String?
        let outgoing: Bool
    }

    private let manager: ConversationManager
    private weak var plugin: SwiftTwilioVoicePlugin?
    /// The other party of each conversation, kept to donate the call when it ends.
    private var remotes: [UUID: Remote] = [:]
    private var pendingIncomingReport: Task<Void, Never>?

    private let capabilities: Conversation.Capabilities = [.pausing, .playingTones]

    /// The device the Voice SDK plays and records with.
    private var audioDevice: DefaultAudioDevice? {
        return TwilioVoiceSDK.audioDevice as? DefaultAudioDevice
    }

    init(plugin: SwiftTwilioVoicePlugin, iconName: String) {
        // The initializer without `supportsAudioTranslation` is used on purpose, call translation stays off.
        let configuration = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: UIImage(named: iconName)?.pngData(),
            maximumConversationGroups: 1,
            maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: true,
            supportsVideo: false,
            // Phone numbers are what the system matches against contacts, generic covers client identities.
            supportedHandleTypes: [.phoneNumber, .generic]
        )
        manager = ConversationManager(configuration: configuration)
        self.plugin = plugin
        super.init()
        manager.delegate = self
    }

    deinit {
        manager.invalidate()
    }

    // MARK: Handles

    static func isPhoneNumber(_ value: String) -> Bool {
        return value.range(of: "^\\+[1-9][0-9]{6,14}$", options: .regularExpression) != nil
    }

    /// E.164 numbers are reported as phone numbers so the system can match them to a contact.
    /// A name that is only the number is left out, the system then shows its own contact name or formatting.
    private func makeHandle(value: String, name: String?) -> Handle {
        var displayName = name?.trimmingCharacters(in: .whitespaces)
        if displayName?.rangeOfCharacter(from: .letters) == nil {
            displayName = nil
        }
        return Handle(type: LiveCommunicationKitBridge.isPhoneNumber(value) ? .phoneNumber : .generic, value: value, displayName: displayName)
    }

    private func conversation(_ uuid: UUID) -> Conversation? {
        return manager.conversations.first(where: { $0.uuid == uuid })
    }

    func hasConversation(uuid: UUID) -> Bool {
        return conversation(uuid) != nil
    }

    // MARK: Requests from the plugin

    func startConversation(uuid: UUID, to: String, name: String?) {
        let handle = makeHandle(value: to, name: name)
        remotes[uuid] = Remote(value: to, name: handle.displayName, outgoing: true)
        let action = StartConversationAction(conversationUUID: uuid, handles: [handle], isVideo: false)
        let update = Conversation.Update(members: [handle], activeRemoteMembers: [handle], capabilities: capabilities)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.perform([action])
                self.log("StartConversationAction request successful")
                self.report(.conversationUpdated(update), uuid: uuid)
            } catch {
                self.log("StartConversationAction request failed: \(error.localizedDescription)")
                self.remotes[uuid] = nil
            }
        }
    }

    /// The report is asynchronous, `whenIncomingReported` lets the PushKit handler wait for it.
    func reportIncoming(uuid: UUID, from: String, name: String?) {
        let handle = makeHandle(value: from, name: name)
        remotes[uuid] = Remote(value: from, name: handle.displayName, outgoing: false)
        let update = Conversation.Update(members: [handle], activeRemoteMembers: [handle], capabilities: capabilities)
        pendingIncomingReport = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.reportNewIncomingConversation(uuid: uuid, update: update)
                self.log("Incoming conversation successfully reported.")
            } catch {
                self.log("Failed to report incoming conversation successfully: \(error.localizedDescription).")
            }
        }
    }

    /// Calls `completion` once the incoming conversation of the current VoIP push is reported to the system.
    func whenIncomingReported(_ completion: @escaping () -> Void) {
        guard let pending = pendingIncomingReport else {
            completion()
            return
        }
        pendingIncomingReport = nil
        Task { @MainActor in
            await pending.value
            completion()
        }
    }

    func updateName(uuid: UUID, value: String, name: String) {
        let handle = makeHandle(value: value, name: name)
        remotes[uuid]?.name = handle.displayName
        report(.conversationUpdated(Conversation.Update(members: [handle], activeRemoteMembers: [handle])), uuid: uuid)
    }

    func join(uuid: UUID) {
        let action = JoinConversationAction(conversationUUID: uuid)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.perform([action])
            } catch {
                self.log("JoinConversationAction request failed: \(error.localizedDescription)")
            }
        }
    }

    func end(uuid: UUID, completion: @escaping (Error?) -> Void) {
        let action = EndConversationAction(conversationUUID: uuid)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.manager.perform([action])
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func reportConnected(uuid: UUID) {
        report(.conversationConnected(Date()), uuid: uuid)
    }

    func reportEnded(uuid: UUID, reason: Conversation.EndedReason) {
        report(.conversationEnded(Date(), reason), uuid: uuid)
    }

    private func report(_ event: Conversation.Event, uuid: UUID) {
        guard let conversation = conversation(uuid) else { return }
        manager.reportConversationEvent(event, for: conversation)
    }

    // MARK: ConversationManagerDelegate

    func conversationManagerDidBegin(_ manager: ConversationManager) {
        log("conversationManagerDidBegin")
    }

    func conversationManagerDidReset(_ manager: ConversationManager) {
        log("conversationManagerDidReset")
        audioDevice?.isEnabled = false
    }

    func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        log("conversationManager:didActivateAudioSession:")
        audioDevice?.isEnabled = true
    }

    func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        log("conversationManager:didDeactivateAudioSession:")
        audioDevice?.isEnabled = false
    }

    func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        log("conversationManager:timedOutPerformingAction: \(type(of: action))")
    }

    func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
        let uuid = conversation.uuid
        guard conversation.state == .left else { return }
        onMain {
            guard let remote = self.remotes.removeValue(forKey: uuid) else { return }
            self.donate(remote)
        }
    }

    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        onMain {
            self.perform(action)
        }
    }

    private func perform(_ action: ConversationAction) {
        guard let plugin = plugin else {
            action.fail()
            return
        }
        let uuid = action.conversationUUID

        switch action {
        case let action as StartConversationAction:
            log("conversationManager:perform:StartConversationAction")
            guard plugin.accessToken != nil else {
                action.fail()
                return
            }
            report(.conversationStartedConnecting(Date()), uuid: uuid)
            plugin.performVoiceCall(uuid: uuid, client: "") { [weak self] success in
                if success {
                    self?.reportConnected(uuid: uuid)
                }
            }
            // Fulfilled right away like the CallKit path, the call can ring for longer than the action may take.
            action.fulfill(dateStarted: Date())

        case let action as JoinConversationAction:
            log("conversationManager:perform:JoinConversationAction")
            guard plugin.callInvite != nil else {
                action.fail()
                return
            }
            plugin.performAnswerVoiceCall(uuid: uuid) { success in
                if success {
                    action.fulfill(dateConnected: Date())
                } else {
                    action.fail()
                }
            }

        case let action as EndConversationAction:
            log("conversationManager:perform:EndConversationAction")
            if plugin.callInvite == nil && plugin.call != nil {
                // The conversation is ended by this action, the disconnect that follows must not report it again.
                plugin.userInitiatedDisconnect = true
            }
            plugin.endVoiceCall()
            action.fulfill(dateEnded: Date())

        case let action as MuteConversationAction:
            log("conversationManager:perform:MuteConversationAction")
            guard let call = plugin.call else {
                action.fail()
                return
            }
            call.isMuted = action.isMuted
            action.fulfill()
            plugin.sendEvent(action.isMuted ? "Mute" : "Unmute")

        case let action as PauseConversationAction:
            log("conversationManager:perform:PauseConversationAction")
            guard let call = plugin.call else {
                action.fail()
                return
            }
            call.isOnHold = action.isPaused
            if !action.isPaused {
                // The system does not always activate the audio session again when a call is resumed.
                audioDevice?.isEnabled = true
            }
            action.fulfill()
            plugin.sendEvent(action.isPaused ? "Hold" : "Unhold")

        case let action as PlayToneAction:
            log("conversationManager:perform:PlayToneAction")
            guard let call = plugin.call else {
                action.fail()
                return
            }
            call.sendDigits(action.digits)
            action.fulfill()

        default:
            log("Unhandled action: \(type(of: action))")
            action.fail()
        }
    }

    // MARK: Recents redial

    /// Donating the call lets the system offer SuperPhone for calling this person again, the app then receives
    /// an INStartCallIntent user activity.
    private func donate(_ remote: Remote) {
        let isPhoneNumber = LiveCommunicationKitBridge.isPhoneNumber(remote.value)
        let personHandle = INPersonHandle(value: remote.value, type: isPhoneNumber ? .phoneNumber : .unknown)
        let person = INPerson(personHandle: personHandle, nameComponents: nil, displayName: remote.name, image: nil, contactIdentifier: nil, customIdentifier: nil)
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown, destinationType: .normal, contacts: [person], callCapability: .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = remote.outgoing ? .outgoing : .incoming
        interaction.donate { [weak self] error in
            if let error = error {
                self?.log("Failed to donate call: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Helpers

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func log(_ message: String) {
        onMain {
            self.plugin?.sendPhoneCallEvents(description: "LOG|\(message)", isError: false)
        }
    }
}
