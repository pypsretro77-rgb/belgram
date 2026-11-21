import Foundation
import UIKit
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore
import SafariServices
import MobileCoreServices
import Intents
import LegacyComponents
import TelegramPresentationData
import TelegramUIPreferences
import DeviceAccess
import TextFormat
import TelegramBaseController
import AccountContext
import BrowserUI
import TelegramStringFormatting
import OverlayStatusController
import DeviceLocationManager
import UrlEscaping
import ContextUI
import AlertUI
import PresentationDataUtils
import UndoUI
import TelegramCallsUI
import TelegramNotices
import GameUI
import ScreenCaptureDetection
import GalleryUI
import OpenInExternalAppUI
import LegacyUI
import InstantPageUI
import LocationUI
import BotPaymentsUI
import DeleteChatPeerActionSheetItem
import HashtagSearchUI
import LegacyMediaPickerUI
import Emoji
import PeerAvatarGalleryUI
import PeerInfoUI
import RaiseToListen
import UrlHandling
import AvatarNode
import AppBundle
import LocalizedPeerData
import PhoneNumberFormat
import SettingsUI
import UrlWhitelist
import TelegramIntents
import TooltipUI
import StatisticsUI
import MediaResources
import GalleryData
import ChatInterfaceState
import InviteLinksUI
import Markdown
import TelegramPermissionsUI
import Speak
import TranslateUI
import TextProcessingScreen
import UniversalMediaPlayer
import WallpaperBackgroundNode
import ChatListUI
import CalendarMessageScreen
import ReactionSelectionNode
import ReactionListContextMenuContent
import AttachmentUI
import AttachmentTextInputPanelNode
import MediaPickerUI
import ChatPresentationInterfaceState
import ChatTextInputPanelNode
import Pasteboard
import ChatSendMessageActionUI
import ChatTextLinkEditUI
import WebUI
import PremiumUI
import ImageTransparency
import StickerPackPreviewUI
import TextNodeWithEntities
import EntityKeyboard
import ChatTitleView
import EmojiStatusComponent
import ChatTimerScreen
import MediaPasteboardUI
import ChatListHeaderComponent
import ChatControllerInteraction
import FeaturedStickersScreen
import ChatEntityKeyboardInputNode
import StorageUsageScreen
import AvatarEditorScreen
import ChatScheduleTimeController
import ICloudResources
import StoryContainerScreen
import MoreHeaderButton
import VolumeButtons
import ChatAvatarNavigationNode
import ChatContextQuery
import PeerReportScreen
import PeerSelectionController
import SaveToCameraRoll
import ChatMessageDateAndStatusNode
import ReplyAccessoryPanelNode
import TextSelectionNode
import ChatMessagePollBubbleContentNode
import ChatMessageItem
import ChatMessageItemImpl
import ChatMessageItemView
import ChatMessageItemCommon
import ChatMessageAnimatedStickerItemNode
import ChatMessageBubbleItemNode
import ChatNavigationButton
import WebsiteType
import PeerInfoScreen
import MediaEditorScreen
import WallpaperGalleryScreen
import WallpaperGridScreen
import VideoMessageCameraScreen
import TopMessageReactions
import AudioWaveform
import PeerNameColorScreen
import ChatEmptyNode
import ChatMediaInputStickerGridItem
import PostSuggestionsSettingsScreen
import ChatSendStarsScreen
import ChatSendAsContextMenu
import GlobalControlPanelsContext
import ComponentFlow
import ComponentDisplayAdapters
import UIKitRuntimeUtils

extension ChatControllerImpl {
    func reloadChatLocation(chatLocation: ChatLocation, chatLocationContextHolder: Atomic<ChatLocationContextHolder?>, historyNode: ChatHistoryListNodeImpl, apply: @escaping ((ContainedViewLayoutTransition?) -> Void) -> Void) {
        self.contentDataReady.set(false)
        
        self.contentDataDisposable?.dispose()
        
        self.newTopicEventsDisposable?.dispose()
        self.newTopicEventsDisposable = nil
        
        let configuration: Signal<ChatControllerImpl.ContentData.Configuration, NoError> = self.presentationInterfaceStatePromise.get()
        |> map { presentationInterfaceState -> ChatControllerImpl.ContentData.Configuration in
            return ChatControllerImpl.ContentData.Configuration(
                subject: presentationInterfaceState.subject,
                selectionState: presentationInterfaceState.interfaceState.selectionState,
                reportReason: presentationInterfaceState.reportReason
            )
        }
        |> distinctUntilChanged
        
        let contentData = ChatControllerImpl.ContentData(
            context: self.context,
            chatLocation: chatLocation,
            chatLocationContextHolder: chatLocationContextHolder,
            initialSubject: self.subject,
            mode: self.mode,
            configuration: configuration,
            adMessagesContext: self.chatDisplayNode.adMessagesContext,
            currentChatListFilter: self.currentChatListFilter,
            customChatNavigationStack: self.customChatNavigationStack,
            presentationData: self.presentationData,
            historyNode: historyNode,
            inviteRequestsContext: self.contentData?.inviteRequestsContext
        )
        self.pendingContentData = (contentData, historyNode)
        self.contentDataDisposable = (contentData.isReady.get()
        |> filter { $0 }
        |> take(1)
        |> deliverOnMainQueue).startStrict(next: { [weak self, weak contentData, weak historyNode] _ in
            guard let self, let contentData, self.pendingContentData?.contentData === contentData else {
                return
            }
            
            apply({ [weak self, weak contentData] forceAnimationTransition in
                guard let self, let contentData, self.pendingContentData?.contentData === contentData else {
                    return
                }
                
                self.contentData = contentData
                self.pendingContentData = nil
                
                self.contentDataUpdated(synchronous: true, forceAnimationTransition: forceAnimationTransition, previousState: contentData.state)
                
                self.chatThemePromise.set(contentData.chatThemePromise.get())
                self.chatWallpaperPromise.set(contentData.chatWallpaperPromise.get())
                
                if let historyNode {
                    self.setupChatHistoryNode(historyNode: historyNode)
                    
                    historyNode.contentPositionChanged(historyNode.visibleContentOffset())
                }
                
                self.contentDataReady.set(true)
                
                contentData.onUpdated = { [weak self, weak contentData] previousState in
                    guard let self, let contentData, self.contentData === contentData else {
                        return
                    }
                    
                    self.contentDataUpdated(synchronous: false, forceAnimationTransition: nil, previousState: previousState)
                }
            })
            
            if self.newTopicEventsDisposable == nil, let peerId = chatLocation.peerId, chatLocation.threadId == EngineMessage.newTopicThreadId {
                self.newTopicEventsDisposable = (self.context.account.pendingMessageManager.newTopicEvents(peerId: peerId)
                |> mapToSignal { event -> Signal<Int64, NoError> in
                    if case let .didMove(fromThreadId, toThreadId) = event {
                        if fromThreadId == EngineMessage.newTopicThreadId {
                            return .single(toThreadId)
                        }
                    }
                    return .never()
                }
                |> take(1)
                |> deliverOnMainQueue).startStrict(next: { [weak self] threadId in
                    guard let self else {
                        return
                    }
                    if chatLocation.peerId != peerId {
                        self.updateInitialChatBotForumLocationThread(linkedForumId: peerId, threadId: threadId)
                    } else {
                        self.updateChatLocationThread(threadId: threadId, animationDirection: nil, replaceInline: true, transferInputState: true)
                    }
                })
            }
        })
    }
    
    func contentDataUpdated(synchronous: Bool, forceAnimationTransition: ContainedViewLayoutTransition?, previousState: ContentData.State) {
        guard let contentData = self.contentData else {
            return
        }
        self.navigationBar?.userInfo = contentData.state.navigationUserInfo
        
        if let infoAvatar = contentData.state.infoAvatar {
            switch infoAvatar {
            case let .peer(peer, imageOverride, contextActionIsEnabled, accessibilityLabel):
                (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.setPeer(context: self.context, theme: self.presentationData.theme, peer: peer, overrideImage: imageOverride, synchronousLoad: synchronous)
                (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.contextActionIsEnabled = contextActionIsEnabled
                self.chatInfoNavigationButton?.buttonItem.accessibilityLabel = accessibilityLabel
            case let .emojiStatus(content, contextActionIsEnabled):
                (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.setStatus(context: self.context, content: content)
                (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.contextActionIsEnabled = contextActionIsEnabled
                self.chatInfoNavigationButton?.buttonItem.accessibilityLabel = self.presentationData.strings.Conversation_ContextMenuOpenProfile
            }
        } else {
            (self.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.contextActionIsEnabled = false
        }
        
        if let avatarNode = self.avatarNode {
            avatarNode.avatarNode.setStoryStats(storyStats: contentData.state.storyStats.flatMap { storyStats -> AvatarNode.StoryStats? in
                if storyStats.totalCount == 0 {
                    return nil
                }
                if storyStats.unseenCount == 0 {
                    return nil
                }
                return AvatarNode.StoryStats(
                    totalCount: storyStats.totalCount,
                    unseenCount: storyStats.unseenCount,
                    hasUnseenCloseFriendsItems: storyStats.hasUnseenCloseFriends,
                    hasLiveItems: storyStats.hasLiveItems
                )
            }, presentationParams: AvatarNode.StoryPresentationParams(
                colors: AvatarNode.Colors(theme: self.presentationData.theme),
                lineWidth: 1.5,
                inactiveLineWidth: 1.5
            ), transition: .immediate)
        }
        
        self.chatDisplayNode.overlayTitle = contentData.overlayTitle
        self.chatDisplayNode.overlayTitleContent = contentData.state.chatTitleContent
        
        self.chatDisplayNode.historyNode.nextChannelToRead = contentData.state.nextChannelToRead.flatMap { nextChannelToRead -> (peer: EnginePeer, threadData: (id: Int64, data: MessageHistoryThreadData)?, unreadCount: Int, location: TelegramEngine.NextUnreadChannelLocation)? in
            return (
                nextChannelToRead.peer,
                nextChannelToRead.threadData.flatMap { threadData -> (id: Int64, data: MessageHistoryThreadData) in
                    return (threadData.id, threadData.data)
                },
                nextChannelToRead.unreadCount,
                nextChannelToRead.location
            )
        }
        self.chatDisplayNode.historyNode.nextChannelToReadDisplayName = contentData.state.nextChannelToReadDisplayName
        self.updateNextChannelToReadVisibility()
        
        var animated = false
        if self.presentationInterfaceState.adMessage?.id != contentData.state.adMessage?.id {
            animated = true
        }
        if let peer = previousState.renderedPeer?.peer as? TelegramSecretChat, let updated = contentData.state.renderedPeer?.peer as? TelegramSecretChat, peer.embeddedState != updated.embeddedState {
            animated = true
        }
        if let peer = previousState.renderedPeer?.peer as? TelegramChannel, let updated = contentData.state.renderedPeer?.peer as? TelegramChannel {
            if peer.participationStatus != updated.participationStatus {
                animated = true
            }
        }
        
        var didDisplayActionsPanel = false
        if let contactStatus = previousState.contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
            if !peerStatusSettings.flags.isEmpty {
                if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                    didDisplayActionsPanel = true
                } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                    didDisplayActionsPanel = true
                } else if peerStatusSettings.contains(.canShareContact) {
                    didDisplayActionsPanel = true
                } else if peerStatusSettings.contains(.suggestAddMembers) {
                    didDisplayActionsPanel = true
                }
            }
        }
        if let contactStatus = previousState.contactStatus, contactStatus.managingBot != nil {
            didDisplayActionsPanel = true
        }
        if self.presentationInterfaceState.search != nil && self.presentationInterfaceState.hasSearchTags {
            didDisplayActionsPanel = true
        }
        
        var previousInvitationPeers: [EnginePeer] = []
        if let requestsState = previousState.requestsState {
            previousInvitationPeers = Array(requestsState.importers.compactMap({ $0.peer.peer.flatMap({ EnginePeer($0) }) }).prefix(3))
        }
        var previousInvitationRequestsPeersDismissed = false
        if let dismissedInvitationRequests = previousState.dismissedInvitationRequests, Set(previousInvitationPeers.map({ $0.id.toInt64() })) == Set(dismissedInvitationRequests) {
            previousInvitationRequestsPeersDismissed = true
        }
        if let requestsState = previousState.requestsState, requestsState.count > 0 && !previousInvitationRequestsPeersDismissed {
            didDisplayActionsPanel = true
        }
        if previousState.removePaidMessageFeeData != nil {
            didDisplayActionsPanel = true
        }
        
        var displayActionsPanel = false
        if let contactStatus = contentData.state.contactStatus, !contactStatus.isEmpty, let peerStatusSettings = contactStatus.peerStatusSettings {
            if !peerStatusSettings.flags.isEmpty {
                if contactStatus.canAddContact && peerStatusSettings.contains(.canAddContact) {
                    displayActionsPanel = true
                } else if peerStatusSettings.contains(.canReport) || peerStatusSettings.contains(.canBlock) {
                    displayActionsPanel = true
                } else if peerStatusSettings.contains(.canShareContact) {
                    displayActionsPanel = true
                } else if peerStatusSettings.contains(.suggestAddMembers) {
                    displayActionsPanel = true
                }
            }
        }
        if let contactStatus = contentData.state.contactStatus, contactStatus.managingBot != nil {
            displayActionsPanel = true
        }
        if self.presentationInterfaceState.search != nil && contentData.state.hasSearchTags {
            displayActionsPanel = true
        }
        
        var invitationPeers: [EnginePeer] = []
        if let requestsState = contentData.state.requestsState {
            invitationPeers = Array(requestsState.importers.compactMap({ $0.peer.peer.flatMap({ EnginePeer($0) }) }).prefix(3))
        }
        var invitationRequestsPeersDismissed = false
        if let dismissedInvitationRequests = contentData.state.dismissedInvitationRequests, Set(invitationPeers.map({ $0.id.toInt64() })) == Set(dismissedInvitationRequests) {
            invitationRequestsPeersDismissed = true
        }
        if let requestsState = contentData.state.requestsState, requestsState.count > 0 && !invitationRequestsPeersDismissed {
            displayActionsPanel = true
        }
        if contentData.state.removePaidMessageFeeData != nil {
            displayActionsPanel = true
        }
        
        if displayActionsPanel != didDisplayActionsPanel {
            animated = true
        }
        if previousState.pinnedMessage != contentData.state.pinnedMessage {
            animated = true
        }
        if previousState.pinnedMessageSkeletonId != contentData.state.pinnedMessageSkeletonId {
            animated = true
        }
        if previousState.translationState?.isEnabled != contentData.state.translationState?.isEnabled {
            animated = true
        }
        if previousState.chatTitleContent != contentData.state.chatTitleContent {
            animated = true
        }
        if previousState.slowmodeState != contentData.state.slowmodeState || previousState.boostsToUnrestrict != contentData.state.boostsToUnrestrict {
            animated = true
        }
        if previousState.canStopIncomingStreamingMessage != contentData.state.canStopIncomingStreamingMessage {
            animated = true
        }
        
        var transition: ContainedViewLayoutTransition = animated ? .animated(duration: 0.4, curve: .spring) : .immediate
        if let forceAnimationTransition {
            transition = forceAnimationTransition
        }
        if !self.willAppear {
            transition = .immediate
        }
        
        self.updateChatPresentationInterfaceState(transition: transition, interactive: false, force: true, { presentationInterfaceState in
            var presentationInterfaceState = presentationInterfaceState
            presentationInterfaceState = presentationInterfaceState.updatedPeer({ _ in
                return contentData.state.renderedPeer
            })
            presentationInterfaceState = presentationInterfaceState.updatedChatLocation(contentData.chatLocation)
            presentationInterfaceState = presentationInterfaceState.updatedIsNotAccessible(contentData.state.isNotAccessible)
            presentationInterfaceState = presentationInterfaceState.updatedContactStatus(contentData.state.contactStatus)
            presentationInterfaceState = presentationInterfaceState.updatedIsManagedBot(contentData.state.isManagedBot)
            presentationInterfaceState = presentationInterfaceState.updatedHasBots(contentData.state.hasBots)
            presentationInterfaceState = presentationInterfaceState.updatedHasBotCommands(contentData.state.hasBotCommands)
            presentationInterfaceState = presentationInterfaceState.updatedBotMenuButton(contentData.state.botMenuButton)
            presentationInterfaceState = presentationInterfaceState.updatedIsArchived(contentData.state.isArchived)
            presentationInterfaceState = presentationInterfaceState.updatedPeerIsMuted(contentData.state.peerIsMuted)
            presentationInterfaceState = presentationInterfaceState.updatedPeerDiscussionId(contentData.state.peerDiscussionId)
            presentationInterfaceState = presentationInterfaceState.updatedPeerGeoLocation(contentData.state.peerGeoLocation)
            presentationInterfaceState = presentationInterfaceState.updatedExplicitelyCanPinMessages(contentData.state.explicitelyCanPinMessages)
            presentationInterfaceState = presentationInterfaceState.updatedHasScheduledMessages(contentData.state.hasScheduledMessages)
            presentationInterfaceState = presentationInterfaceState.updatedAutoremoveTimeout(contentData.state.autoremoveTimeout)
            presentationInterfaceState = presentationInterfaceState.updatedCurrentSendAsPeerId(contentData.state.currentSendAsPeerId)
            presentationInterfaceState = presentationInterfaceState.updatedCopyProtectionEnabled(contentData.state.copyProtectionEnabled)
            presentationInterfaceState = presentationInterfaceState.updatedMyCopyProtectionEnabled(contentData.state.myCopyProtectionEnabled)
            presentationInterfaceState = presentationInterfaceState.updatedHasSearchTags(contentData.state.hasSearchTags)
            presentationInterfaceState = presentationInterfaceState.updatedIsPremiumRequiredForMessaging(contentData.state.isPremiumRequiredForMessaging)
            presentationInterfaceState = presentationInterfaceState.updatedSendPaidMessageStars(contentData.state.sendPaidMessageStars)
            presentationInterfaceState = presentationInterfaceState.updatedGramAddress(contentData.state.gramAddress)
            presentationInterfaceState = presentationInterfaceState.updatedAlwaysShowGiftButton(contentData.state.alwaysShowGiftButton)
            presentationInterfaceState = presentationInterfaceState.updatedDisallowedGifts(contentData.state.disallowedGifts)
            presentationInterfaceState = presentationInterfaceState.updatedHasSavedChats(contentData.state.hasSavedChats)
            presentationInterfaceState = presentationInterfaceState.updatedAppliedBoosts(contentData.state.appliedBoosts)
            presentationInterfaceState = presentationInterfaceState.updatedBoostsToUnrestrict(contentData.state.boostsToUnrestrict)
            presentationInterfaceState = presentationInterfaceState.updatedHasBirthdayToday(contentData.state.hasBirthdayToday)
            presentationInterfaceState = presentationInterfaceState.updatedBusinessIntro(contentData.state.businessIntro)
            presentationInterfaceState = presentationInterfaceState.updatedAdMessage(contentData.state.adMessage)
            presentationInterfaceState = presentationInterfaceState.updatedPeerVerification(contentData.state.peerVerification)
            presentationInterfaceState = presentationInterfaceState.updatedStarGiftsAvailable(contentData.state.starGiftsAvailable)
            presentationInterfaceState = presentationInterfaceState.updatedSavedMessagesTopicPeer(contentData.state.savedMessagesTopicPeer)
            presentationInterfaceState = presentationInterfaceState.updatedKeyboardButtonsMessage(contentData.state.keyboardButtonsMessage)
            presentationInterfaceState = presentationInterfaceState.updatedPinnedMessageId(contentData.state.pinnedMessageId)
            presentationInterfaceState = presentationInterfaceState.updatedPinnedMessage(contentData.state.pinnedMessage)
            presentationInterfaceState = presentationInterfaceState.updatedPinnedMessageSkeletonId(contentData.state.pinnedMessageSkeletonId)
            presentationInterfaceState = presentationInterfaceState.updatedPeerIsBlocked(contentData.state.peerIsBlocked)
            presentationInterfaceState = presentationInterfaceState.updatedCallsAvailable(contentData.state.callsAvailable)
            presentationInterfaceState = presentationInterfaceState.updatedCallsPrivate(contentData.state.callsPrivate)
            presentationInterfaceState = presentationInterfaceState.updatedActiveGroupCallInfo(contentData.state.activeGroupCallInfo)
            presentationInterfaceState = presentationInterfaceState.updatedSlowmodeState(contentData.state.slowmodeState)
            presentationInterfaceState = presentationInterfaceState.updatedSuggestPremiumGift(contentData.state.suggestPremiumGift)
            presentationInterfaceState = presentationInterfaceState.updatedTranslationState(contentData.state.translationState)
            presentationInterfaceState = presentationInterfaceState.updatedVoiceMessagesAvailable(contentData.state.voiceMessagesAvailable)
            presentationInterfaceState = presentationInterfaceState.updatedCustomEmojiAvailable(contentData.state.customEmojiAvailable)
            presentationInterfaceState = presentationInterfaceState.updatedThreadData(contentData.state.threadData)
            presentationInterfaceState = presentationInterfaceState.updatedForumTopicData(contentData.state.forumTopicData)
            presentationInterfaceState = presentationInterfaceState.updatedIsGeneralThreadClosed(contentData.state.isGeneralThreadClosed)
            presentationInterfaceState = presentationInterfaceState.updatedPremiumGiftOptions(contentData.state.premiumGiftOptions)
            presentationInterfaceState = presentationInterfaceState.updatedRemovePaidMessageFeeData(contentData.state.removePaidMessageFeeData)
            presentationInterfaceState = presentationInterfaceState.updatedViewForumAsMessages(contentData.state.viewForumAsMessages)
            presentationInterfaceState = presentationInterfaceState.updatedHasTopics(contentData.state.hasTopics)
            presentationInterfaceState = presentationInterfaceState.updatedCanStopIncomingStreamingMessage(contentData.state.canStopIncomingStreamingMessage)
            
            presentationInterfaceState = presentationInterfaceState.updatedTitlePanelContext({ context in
                if contentData.state.pinnedMessageId != nil {
                    if !context.contains(where: { item in
                        switch item {
                        case .pinnedMessage:
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = context
                        updatedContexts.append(.pinnedMessage)
                        return updatedContexts.sorted()
                    } else {
                        return context
                    }
                } else {
                    if let index = context.firstIndex(where: { item in
                        switch item {
                        case .pinnedMessage:
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = context
                        updatedContexts.remove(at: index)
                        return updatedContexts
                    } else {
                        return context
                    }
                }
            })
            presentationInterfaceState = presentationInterfaceState.updatedTitlePanelContext { context in
                var peers: [EnginePeer] = []
                if let requestsState = contentData.state.requestsState {
                    peers = Array(requestsState.importers.compactMap({ $0.peer.peer.flatMap({ EnginePeer($0) }) }).prefix(3))
                }
                
                var peersDismissed = false
                if let dismissedInvitationRequests = contentData.state.dismissedInvitationRequests, Set(peers.map({ $0.id.toInt64() })) == Set(dismissedInvitationRequests) {
                    peersDismissed = true
                }
                if let requestsState = contentData.state.requestsState, requestsState.count > 0 && !peersDismissed {
                    if !context.contains(where: {
                        switch $0 {
                        case .inviteRequests(peers, requestsState.count):
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = context.filter { c in
                            if case .inviteRequests = c {
                                return false
                            } else {
                                return true
                            }
                        }
                        updatedContexts.append(.inviteRequests(peers, requestsState.count))
                        return updatedContexts.sorted()
                    } else {
                        return context
                    }
                } else {
                    if let index = context.firstIndex(where: { item in
                        switch item {
                        case .inviteRequests:
                            return true
                        default:
                            return false
                        }
                    }) {
                        var updatedContexts = context
                        updatedContexts.remove(at: index)
                        return updatedContexts
                    } else {
                        return context
                    }
                }
            }
            
            let initialInterfaceState = contentData.initialInterfaceState
            contentData.initialInterfaceState = nil
            let initialTextInputState = self.initialTextInputState
            self.initialTextInputState = nil
            
            if !self.didInitializePersistentPeerInterfaceData, let initialPersistentPeerData = contentData.initialPersistentPeerData {
                self.didInitializePersistentPeerInterfaceData = true
                presentationInterfaceState = presentationInterfaceState.updatedPersistentData(initialPersistentPeerData)
            }
            
            presentationInterfaceState = presentationInterfaceState.updatedInterfaceState { interfaceState in
                var interfaceState = interfaceState
                if let initialInterfaceState {
                    interfaceState = initialInterfaceState.interfaceState
                }
                if let initialTextInputState {
                    interfaceState = interfaceState.withUpdatedComposeInputState(initialTextInputState)
                }
                
                if let channel = contentData.state.renderedPeer?.peer as? TelegramChannel {
                    if channel.hasBannedPermission(.banSendVoice) != nil && channel.hasBannedPermission(.banSendInstantVideos) != nil {
                        interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                    } else if channel.hasBannedPermission(.banSendVoice) != nil {
                        if channel.hasBannedPermission(.banSendInstantVideos) == nil {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                        }
                    } else if channel.hasBannedPermission(.banSendInstantVideos) != nil {
                        if channel.hasBannedPermission(.banSendVoice) == nil {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                        }
                    }
                } else if let group = contentData.state.renderedPeer?.peer as? TelegramGroup {
                    if group.hasBannedPermission(.banSendVoice) && group.hasBannedPermission(.banSendInstantVideos) {
                        interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                    } else if group.hasBannedPermission(.banSendVoice) {
                        if !group.hasBannedPermission(.banSendInstantVideos) {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.video)
                        }
                    } else if group.hasBannedPermission(.banSendInstantVideos) {
                        if !group.hasBannedPermission(.banSendVoice) {
                            interfaceState = interfaceState.withUpdatedMediaRecordingMode(.audio)
                        }
                    }
                }
                
                return interfaceState
            }
            
            if let editMessage = initialInterfaceState?.editMessage {
                let (updatedState, updatedPreviewQueryState) = updatedChatEditInterfaceMessageState(context: self.context, state: presentationInterfaceState, message: editMessage)
                presentationInterfaceState = updatedState
                self.editingUrlPreviewQueryState?.1.dispose()
                self.editingUrlPreviewQueryState = updatedPreviewQueryState
            }
            
            return presentationInterfaceState
        })
        
        if let initialNavigationBadge = contentData.initialNavigationBadge {
            contentData.initialNavigationBadge = nil
            if self.showsUnreadChatsBackBadge {
                self.navigationItem.badge = initialNavigationBadge
            }
        }
        
        if let performDismissAction = contentData.state.performDismissAction, !self.didHandlePerformDismissAction {
            self.didHandlePerformDismissAction = true
            
            switch performDismissAction {
            case let .upgraded(upgradedToPeerId):
                if let navigationController = self.effectiveNavigationController {
                    var viewControllers = navigationController.viewControllers
                    if let index = viewControllers.firstIndex(where: { $0 === self }) {
                        viewControllers[index] = ChatControllerImpl(context: self.context, chatLocation: .peer(id: upgradedToPeerId))
                        navigationController.setViewControllers(viewControllers, animated: false)
                    }
                }
            case .movedToForumTopics:
                if let peerView = contentData.state.peerView, let navigationController = self.effectiveNavigationController {
                    let chatListController = self.context.sharedContext.makeChatListController(context: self.context, location: .forum(peerId: peerView.peerId), controlsHistoryPreload: false, hideNetworkActivityStatus: false, previewing: false, enableDebugActions: false)
                    navigationController.replaceController(self, with: chatListController, animated: true)
                }
            case .dismiss:
                self.dismiss()
            }
        }
        
        self.updatePreloadNextChatPeerId()
    }
    
    func updatePreloadNextChatPeerId() {
        if !self.checkedPeerChatServiceActions {
            return
        }
        
        if self.preloadNextChatPeerId != self.contentData?.state.preloadNextChatPeerId {
            self.preloadNextChatPeerId = self.contentData?.state.preloadNextChatPeerId
            if let nextPeerId = self.contentData?.state.preloadNextChatPeerId {
                let combinedDisposable = DisposableSet()
                self.preloadNextChatPeerIdDisposable.set(combinedDisposable)
                combinedDisposable.add(self.context.account.viewTracker.polledChannel(peerId: nextPeerId).startStrict())
                combinedDisposable.add(self.context.account.addAdditionalPreloadHistoryPeerId(peerId: nextPeerId))
            } else {
                self.preloadNextChatPeerIdDisposable.set(nil)
            }
        }
    }
    
    func reloadCachedData() {
        var measure_isFirstTime = true
        #if DEBUG
        let initTimestamp = self.initTimestamp
        #endif
        
        self.ready.set(combineLatest(queue: .mainQueue(), [
            self.contentDataReady.get(),
            self.wallpaperReady.get(),
            self.presentationReady.get()
        ])
        |> map { values in
            return !values.contains(where: { !$0 })
        }
        |> filter { $0 }
        |> take(1)
        |> distinctUntilChanged
        |> beforeNext { value in
            if measure_isFirstTime {
                measure_isFirstTime = false
                #if DEBUG
                let deltaTime = (CFAbsoluteTimeGetCurrent() - initTimestamp) * 1000.0
                print("Chat controller init to ready: \(deltaTime) ms")
                #endif
            }
        })
    }
    
    func loadDisplayNodeImpl() {
        self.navigationBar?.backPressed = { [weak self] in
            guard let self else {
                return
            }
            if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.isForumOrMonoForum, self.presentationInterfaceState.persistentData.topicListPanelLocation == .side, self.presentationInterfaceState.chatLocation.threadId != nil {
                self.updateChatLocationThread(threadId: nil, animationDirection: .left)
            } else {
                if self.attemptNavigation({ [weak self] in
                    self?.dismiss()
                }) {
                    self.dismiss()
                }
            }
        }
        
        if #available(iOS 18.0, *) {
            if engineExperimentalInternalTranslationService == nil, let hostView = self.context.sharedContext.mainWindow?.hostView {
                let translationService = ExperimentalInternalTranslationServiceImpl(view: hostView.containerView)
                engineExperimentalInternalTranslationService = translationService
            }
        }
        
        self.displayNode = ChatControllerNode(context: self.context, chatLocation: self.chatLocation, chatLocationContextHolder: self.chatLocationContextHolder, subject: self.subject, controllerInteraction: self.controllerInteraction!, chatPresentationInterfaceState: self.presentationInterfaceState, automaticMediaDownloadSettings: self.automaticMediaDownloadSettings, navigationBar: self.navigationBar, statusBar: self.statusBar, backgroundNode: self.chatBackgroundNode, controller: self)
        
        if let currentItem = self.globalControlPanelsContext?.tempVoicePlaylistCurrentItem {
            self.chatDisplayNode.historyNode.voicePlaylistItemChanged(nil, currentItem)
        }
        
        if case .peer(self.context.account.peerId) = self.chatLocation {
            var didDisplayTooltip = false
            if "".isEmpty {
                didDisplayTooltip = true
            }
            self.chatDisplayNode.historyNode.hasLotsOfMessagesUpdated = { [weak self] hasLotsOfMessages in
                guard let self, hasLotsOfMessages else {
                    return
                }
                if didDisplayTooltip {
                    return
                }
                didDisplayTooltip = true
                
                let _ = (ApplicationSpecificNotice.getSavedMessagesChatsSuggestion(accountManager: self.context.sharedContext.accountManager)
                |> deliverOnMainQueue).startStandalone(next: { [weak self] counter in
                    guard let self else {
                        return
                    }
                    if counter >= 3 {
                        return
                    }
                    guard let navigationBar = self.navigationBar else {
                        return
                    }
                    
                    let tooltipScreen = TooltipScreen(account: self.context.account, sharedContext: self.context.sharedContext, text: .plain(text: self.presentationData.strings.Chat_SavedMessagesChatsTooltip), location: .point(navigationBar.frame, .top), displayDuration: .manual, shouldDismissOnTouch: { point, _ in
                        return .ignore
                    })
                    self.present(tooltipScreen, in: .current)
                    
                    let _ = ApplicationSpecificNotice.incrementSavedMessagesChatsSuggestion(accountManager: self.context.sharedContext.accountManager).startStandalone()
                })
            }
        }

        self.chatDisplayNode.historyNode.addContentOffset = { [weak self] offset, itemNode in
            guard let strongSelf = self else {
                return
            }
            strongSelf.chatDisplayNode.messageTransitionNode.addContentOffset(offset: offset, itemNode: itemNode)
        }
        
        var closeOnEmpty = false
        if case .pinnedMessages = self.presentationInterfaceState.subject {
            closeOnEmpty = true
        } else if self.chatLocation.peerId == self.context.account.peerId {
            if let data = self.context.currentAppConfiguration.with({ $0 }).data, let _ = data["ios_killswitch_disable_close_empty_saved"] {
            } else {
                closeOnEmpty = true
            }
        }
        
        if closeOnEmpty {
            self.chatDisplayNode.historyNode.addSetLoadStateUpdated({ [weak self] state, _ in
                guard let self else {
                    return
                }
                if case .empty = state {
                    if self.chatLocation.peerId == self.context.account.peerId {
                        if self.chatDisplayNode.historyNode.tag != nil {
                            self.updateChatPresentationInterfaceState(animated: true, interactive: false, { state in
                                return state.updatedSearch(nil).updatedHistoryFilter(nil)
                            })
                        } else if case .replyThread = self.chatLocation {
                            self.dismiss()
                        }
                    } else {
                        self.dismiss()
                    }
                }
            })
        }
        
        let currentAccountPeer = self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
        |> mapToSignal { peer -> Signal<EnginePeer, NoError> in
            if let peer {
                return .single(peer)
            } else {
                return .never()
            }
        }
        |> map { peer in
            return SendAsPeer(peer: peer, subscribers: nil, isPremiumRequired: false)
        }
        
        if let peerId = self.chatLocation.peerId, [Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup].contains(peerId.namespace) {
            self.sendAsPeersDisposable = (combineLatest(
                queue: Queue.mainQueue(),
                currentAccountPeer,
                self.context.account.postbox.peerView(id: peerId),
                self.context.engine.peers.sendAsAvailablePeers(peerId: peerId))
            ).startStrict(next: { [weak self] currentAccountPeer, peerView, peers in
                guard let strongSelf = self else {
                    return
                }
                
                if let channel = peerViewMainPeer(peerView) as? TelegramChannel, channel.isMonoForum {
                    return
                }
                
                let isPremium = strongSelf.presentationInterfaceState.isPremium
                
                var allPeers: [SendAsPeer]?
                if !peers.isEmpty {
                    if let channel = peerViewMainPeer(peerView) as? TelegramChannel, case .group = channel.info, channel.hasPermission(.canBeAnonymous) {
                        allPeers = peers
                        
                        var hasAnonymousPeer = false
                        for peer in peers {
                            if peer.peer.id == channel.id {
                                hasAnonymousPeer = true
                                break
                            }
                        }
                        if !hasAnonymousPeer {
                            allPeers?.insert(SendAsPeer(peer: EnginePeer(channel), subscribers: 0, isPremiumRequired: false), at: 0)
                        }
                    } else if let channel = peerViewMainPeer(peerView) as? TelegramChannel, case let .broadcast(info) = channel.info, (info.flags.contains(.messagesShouldHaveSignatures) || info.flags.contains(.messagesShouldHaveProfiles)) {
                        allPeers = peers
                        
                        var hasAnonymousPeer = false
                        var hasSelfPeer = false
                        for peer in peers {
                            if peer.peer.id == channel.id {
                                hasAnonymousPeer = true
                            } else if peer.peer.id == strongSelf.context.account.peerId {
                                hasSelfPeer = true
                            }
                        }
                        if !hasSelfPeer {
                            allPeers?.insert(currentAccountPeer, at: 0)
                        }
                        if !hasAnonymousPeer {
                            allPeers?.insert(SendAsPeer(peer: EnginePeer(channel), subscribers: 0, isPremiumRequired: false), at: 0)
                        }
                    } else {
                        allPeers = peers.filter { $0.peer.id != peerViewMainPeer(peerView)?.id }
                        allPeers?.insert(currentAccountPeer, at: 0)
                    }
                }
                if allPeers?.count == 1 {
                    allPeers = nil
                }
                
                var currentSendAsPeerId = strongSelf.presentationInterfaceState.currentSendAsPeerId
                if let peerId = currentSendAsPeerId, let peer = allPeers?.first(where: { $0.peer.id == peerId }) {
                    if !isPremium && peer.isPremiumRequired {
                        currentSendAsPeerId = nil
                    }
                } else {
                    currentSendAsPeerId = nil
                }
                
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, {
                    return $0.updatedSendAsPeers(allPeers).updatedCurrentSendAsPeerId(currentSendAsPeerId)
                })
            })
        }
        
        if let peerId = self.chatLocation.peerId {
            self.chatThemePromise.set(self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ChatTheme(id: peerId)))
            let chatWallpaper = self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Wallpaper(id: peerId))
            |> take(1)
            self.chatWallpaperPromise.set(chatWallpaper)
        } else {
            self.chatThemePromise.set(.single(nil))
            self.chatWallpaperPromise.set(.single(nil))
        }
        
        self.reloadCachedData()
        
        if self.context.sharedContext.immediateExperimentalUISettings.crashOnLongQueries {
            let _ = (self.ready.get()
            |> filter({ $0 })
            |> take(1)
            |> timeout(0.8, queue: .concurrentDefaultQueue(), alternate: Signal { _ in
                preconditionFailure()
            })).startStandalone()
        }
        
        self.setupChatHistoryNode(historyNode: self.chatDisplayNode.historyNode)
        
        self.chatDisplayNode.requestLayout = { [weak self] transition in
            self?.requestLayout(transition: transition)
        }
        
        var enableSendAnimationV2 = false
        if let data = self.context.currentAppConfiguration.with({ $0 }).data, let _ = data["ios_killswitch_disable_send_animation_v2"] {
        } else {
            enableSendAnimationV2 = true
        }
        
        self.chatDisplayNode.setupSendActionOnViewUpdate = { [weak self] f, messageCorrelationId in
            //print("setup layoutActionOnViewTransition")

            guard let self else {
                return
            }
            self.layoutActionOnViewTransitionAction = f
            
            if !enableSendAnimationV2 {
                self.chatDisplayNode.historyNode.pinToTopStableId = nil
            } else if !self.chatDisplayNode.historyNode.isStrictlyScrolledToPinToEdgeItem() {
                self.chatDisplayNode.historyNode.pinToTopStableId = nil
            }
            self.chatDisplayNode.historyNode.layoutActionOnViewTransition = ({ [weak self] transition in
                f()
                if let strongSelf = self, let validLayout = strongSelf.validLayout {
                    strongSelf.layoutActionOnViewTransitionAction = nil
                    
                    var mappedTransition: (ChatHistoryListViewTransition, ListViewUpdateSizeAndInsets?)?
                    
                    let isScheduledMessages: Bool
                    if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        isScheduledMessages = true
                    } else {
                        isScheduledMessages = false
                    }
                    let hasScheduledTransitions = strongSelf.chatDisplayNode.messageTransitionNode.hasScheduledTransitions
                    let sendAnimationParameters = strongSelf.chatDisplayNode.messageTransitionNode.animationParameters
                    let duration: Double = hasScheduledTransitions ? sendAnimationParameters.duration : 0.18
                    let curve: ContainedViewLayoutTransitionCurve = hasScheduledTransitions ? sendAnimationParameters.verticalCurve : .easeInOut
                    // The list scrolls on the bubble's own vertical curve, or the new bubble drifts against its neighbours.
                    let listCurve: ListViewAnimationCurve = hasScheduledTransitions ? sendAnimationParameters.verticalListCurve : .Custom(duration: duration, 0.5, 0.33, 0.0, 0.0)

                    let shouldUseFastMessageSendAnimation = strongSelf.chatDisplayNode.shouldUseFastMessageSendAnimation
                    
                    strongSelf.chatDisplayNode.containerLayoutUpdated(validLayout, navigationBarHeight: strongSelf.navigationLayout(layout: validLayout).navigationFrame.maxY, transition: .animated(duration: duration, curve: curve), listViewTransaction: { [weak strongSelf]
                        updateSizeAndInsets, _, _, _ in
                        var options = transition.options
                        let _ = options.insert(.Synchronous)
                        let _ = options.insert(.LowLatency)
                        let _ = options.insert(.PreferSynchronousResourceLoading)

                        var deleteItems = transition.deleteItems
                        var insertItems: [ChatHistoryListViewInsertItem] = []
                        var stationaryItemRange: (Int, Int)?
                        var scrollToItem: ListViewScrollToItem?

                        if shouldUseFastMessageSendAnimation {
                            options.remove(.AnimateInsertion)
                            options.insert(.RequestItemInsertionAnimations)

                            deleteItems = transition.deleteItems.map({ item in
                                return ListViewDeleteItem(index: item.index, directionHint: nil)
                            })

                            var maxInsertedItem: Int?
                            var insertedIndex: Int?
                            for i in 0 ..< transition.insertItems.count {
                                let item = transition.insertItems[i]
                                if item.directionHint == .Down && (maxInsertedItem == nil || maxInsertedItem! < item.index) {
                                    maxInsertedItem = item.index
                                }
                                insertedIndex = item.index
                                insertItems.append(ChatHistoryListViewInsertItem(index: item.index, previousIndex: item.previousIndex, stableId: item.stableId, item: item.item, directionHint: item.directionHint == .Down ? .Up : nil))
                            }

                            if isScheduledMessages, let insertedIndex {
                                scrollToItem = ListViewScrollToItem(index: insertedIndex, position: .visible, animated: true, curve: listCurve, directionHint: .Down)
                            } else if transition.historyView.originalView.laterId == nil {
                                scrollToItem = ListViewScrollToItem(index: 0, position: .top(0.0), animated: true, curve: listCurve, directionHint: .Up)
                                if enableSendAnimationV2, Thread.isMainThread, let strongSelf {
                                    if strongSelf.chatDisplayNode.historyNode.isStrictlyScrolledToPinToEdgeItem() {
                                        scrollToItem = nil
                                    }
                                }
                            }

                            if let maxInsertedItem = maxInsertedItem {
                                stationaryItemRange = (maxInsertedItem + 1, Int.max)
                            }
                        }
                        
                        mappedTransition = (ChatHistoryListViewTransition(historyView: transition.historyView, deleteItems: deleteItems, insertItems: insertItems, updateItems: transition.updateItems, options: options, scrollToItem: scrollToItem, stationaryItemRange: stationaryItemRange, initialData: transition.initialData, keyboardButtonsMessage: transition.keyboardButtonsMessage, cachedData: transition.cachedData, cachedDataMessages: transition.cachedDataMessages, readStateData: transition.readStateData, scrolledToIndex: transition.scrolledToIndex, scrolledToSomeIndex: transition.scrolledToSomeIndex, peerType: transition.peerType, networkType: transition.networkType, animateIn: false, reason: transition.reason, flashIndicators: transition.flashIndicators, animateFromPreviousFilter: false), updateSizeAndInsets)
                    }, updateExtraNavigationBarBackgroundHeight: { value, hitTestSlop, _ in
                        strongSelf.additionalNavigationBarBackgroundHeight = value
                        strongSelf.additionalNavigationBarHitTestSlop = hitTestSlop
                    })
                    
                    if let mappedTransition = mappedTransition {
                        return mappedTransition
                    }
                }
                return (transition, nil)
            }, messageCorrelationId)
        }
        
        self.chatDisplayNode.sendMessages = { [weak self] messages, silentPosting, scheduleTime, repeatPeriod, isAnyMessageTextPartitioned, postpone in
            guard let strongSelf = self else {
                return
            }

            if messages.count == 1,
               case let .message(commandText, _, _, _, _, _, _, _, _, _) = messages[0] {
                let commandParts = commandText.split(whereSeparator: { $0.isWhitespace })
                if commandParts.first == "/soft" {
                    // This is a local-only preview command. Clear the composer before returning
                    // from Telegram's normal send path; no gift transfer is performed.
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: false, { state in
                        state.updatedInterfaceState { interfaceState in
                            interfaceState.withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: "")))
                        }
                    })

                    let requestedSlug: String? = {
                        guard commandParts.count == 2,
                              let url = URL(string: String(commandParts[1])),
                              let host = url.host?.lowercased(),
                              (host == "t.me" || host == "telegram.me"),
                              let nftIndex = url.pathComponents.firstIndex(of: "nft"),
                              url.pathComponents.count > nftIndex + 1 else {
                            return nil
                        }
                        return url.pathComponents[nftIndex + 1]
                    }()

                    let isRandomCommand = commandParts.count == 3 && commandParts[1] == "random"
                    let requestedPeerId = isRandomCommand ? Int64(String(commandParts[2])) : nil
                    guard let peerId = strongSelf.chatLocation.peerId,
                          peerId.namespace == Namespaces.Peer.CloudUser,
                          peerId != strongSelf.context.account.peerId,
                          (requestedSlug != nil || (isRandomCommand && requestedPeerId == peerId.id._internalGetInt64Value())) else {
                        strongSelf.present(
                            textAlertController(
                                context: strongSelf.context,
                                updatedPresentationData: strongSelf.updatedPresentationData,
                                title: nil,
                                text: "Формат: /soft https://t.me/nft/InstantRamen-213507 или /soft random ID текущего собеседника",
                                actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                            ),
                            in: .window(.root)
                        )
                        return
                    }

                    if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        strongSelf.present(
                            textAlertController(
                                context: strongSelf.context,
                                updatedPresentationData: strongSelf.updatedPresentationData,
                                title: nil,
                                text: strongSelf.presentationData.strings.ScheduledMessages_BotActionUnavailable,
                                actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                            ),
                            in: .window(.root)
                        )
                        return
                    }

                    let addDemoGift: (StarGift, String) -> Void = { gift, demoDescription in
                        let giftAction = TelegramMediaAction(action: .starGift(
                            gift: gift,
                            convertStars: nil,
                            text: demoDescription,
                            entities: nil,
                            nameHidden: false,
                            savedToProfile: false,
                            converted: false,
                            upgraded: false,
                            canUpgrade: false,
                            upgradeStars: nil,
                            isRefunded: false,
                            isPrepaidUpgrade: false,
                            upgradeMessageId: nil,
                            peerId: nil,
                            senderId: nil,
                            savedId: nil,
                            prepaidUpgradeHash: nil,
                            giftMessageId: nil,
                            upgradeSeparate: false,
                            isAuctionAcquired: false,
                            toPeerId: nil,
                            number: nil
                        ))

                        strongSelf.addLocalSoftGiftMessage(
                            peerId: peerId,
                            threadId: strongSelf.chatLocation.threadId,
                            giftAction: giftAction,
                            completion: { [weak controller = strongSelf] in
                                controller?.chatDisplayNode.historyNode.scrollToEndOfHistory()
                            }
                        )
                    }

                    if let requestedSlug {
                        // Resolve the exact collectible from Telegram's unique-gift endpoint.
                        // This creates only a local DEMO message; it does not transfer an NFT.
                        let _ = (strongSelf.context.engine.payments.getUniqueStarGift(slug: requestedSlug)
                        |> deliverOnMainQueue).start(next: { [weak strongSelf] uniqueGift in
                            guard strongSelf != nil else {
                                return
                            }
                            let title = uniqueGift.title
                            addDemoGift(
                                .unique(uniqueGift),
                                "DEMO • Локальный предпросмотр коллекционного NFT \(title). NFT не передан."
                            )
                        }, error: { [weak strongSelf] _ in
                            guard let strongSelf else {
                                return
                            }
                            strongSelf.present(
                                textAlertController(
                                    context: strongSelf.context,
                                    updatedPresentationData: strongSelf.updatedPresentationData,
                                    title: nil,
                                    text: "Не удалось загрузить коллекционный NFT по этой ссылке. Проверь ссылку или попробуй позже.",
                                    actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                                ),
                                in: .window(.root)
                            )
                        })
                    } else {
                        let giftsSignal = softCompleting(strongSelf.context.engine.payments.keepStarGiftsUpdated(), with: ())
                        |> mapToSignal { _ in
                            strongSelf.context.engine.payments.cachedStarGifts() |> take(1)
                        }
                        |> deliverOnMainQueue

                        let _ = giftsSignal.start(next: { [weak strongSelf] gifts in
                            guard let strongSelf else {
                                return
                            }

                            let regularGifts = (gifts ?? []).compactMap { gift -> StarGift.Gift? in
                                if case let .generic(value) = gift {
                                    return value
                                }
                                return nil
                            }

                            guard let selectedGift = regularGifts.randomElement() else {
                                strongSelf.present(
                                    textAlertController(
                                        context: strongSelf.context,
                                        updatedPresentationData: strongSelf.updatedPresentationData,
                                        title: nil,
                                        text: "Общий каталог подарков Telegram пока не загружен или пуст. Повтори команду позже.",
                                        actions: [TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})]
                                    ),
                                    in: .window(.root)
                                )
                                return
                            }

                            addDemoGift(
                                .generic(selectedGift),
                                "DEMO • Локальная демонстрация. Подарок не передан."
                            )
                        })
                    }

                    return
                }
            }
            var correlationIds: [Int64] = []
            for message in messages {
                switch message {
                case let .message(_, _, _, _, _, _, _, _, correlationId, _):
                    if let correlationId = correlationId {
                        correlationIds.append(correlationId)
                    }
                default:
                    break
                }
            }
            strongSelf.commitPurposefulAction()
            
            if let peerId = strongSelf.chatLocation.peerId {
                var hasDisabledContent = false
                if "".isEmpty {
                    hasDisabledContent = false
                }
                
                if let channel = strongSelf.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.isRestrictedBySlowmode {
                    let forwardCount = messages.reduce(0, { count, message -> Int in
                        if case .forward = message {
                            return count + 1
                        } else {
                            return count
                        }
                    })
                    
                    var errorText: String?
                    if forwardCount > 1 {
                        errorText = strongSelf.presentationData.strings.Chat_AttachmentMultipleForwardDisabled
                    } else if isAnyMessageTextPartitioned {
                        errorText = strongSelf.presentationData.strings.Chat_MultipleTextMessagesDisabled
                    } else if hasDisabledContent {
                        errorText = strongSelf.restrictedSendingContentsText()
                    }
                    
                    if let errorText = errorText {
                        let alertController = textAlertController(
                            context: strongSelf.context,
                            title: nil,
                            text: errorText,
                            actions: [
                                TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})
                            ]
                        )
                        strongSelf.present(alertController, in: .window(.root))
                        return
                    }
                }
                
                let effectiveSilentPosting = silentPosting ?? strongSelf.presentationInterfaceState.interfaceState.silentPosting
                let transformedMessages = strongSelf.transformEnqueueMessages(messages, silentPosting: effectiveSilentPosting, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, postpone: postpone)
                
                var forwardedMessages: [[EnqueueMessage]] = []
                var forwardSourcePeerIds = Set<EnginePeer.Id>()
                for message in transformedMessages {
                    if case let .forward(source, _, _, _, _) = message {
                        forwardSourcePeerIds.insert(source.peerId)
                        
                        var added = false
                        if var last = forwardedMessages.last {
                            if let currentMessage = last.first, case let .forward(currentSource, _, _, _, _) = currentMessage, currentSource.peerId == source.peerId {
                                last.append(message)
                                added = true
                            }
                        }
                        if !added {
                            forwardedMessages.append([message])
                        }
                    }
                }
                
                let _ = (strongSelf.shouldDivertMessagesToScheduled(messages: transformedMessages)
                |> deliverOnMainQueue).start(next: { shouldDivert in
                    let signal: Signal<[EngineMessage.Id?], NoError>
                    var shouldOpenScheduledMessages = false
                    if forwardSourcePeerIds.count > 1 {
                        var forwardedMessages = forwardedMessages
                        if shouldDivert {
                            forwardedMessages = forwardedMessages.map { messageGroup -> [EnqueueMessage] in
                                return messageGroup.map { message -> EnqueueMessage in
                                    return message.withUpdatedAttributes { attributes in
                                        var attributes = attributes
                                        attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
                                        attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: Int32(Date().timeIntervalSince1970) + 10 * 24 * 60 * 60, repeatPeriod: nil))
                                        return attributes
                                    }
                                }
                            }
                            shouldOpenScheduledMessages = true
                        }
                        
                        var signals: [Signal<[EngineMessage.Id?], NoError>] = []
                        for messagesGroup in forwardedMessages {
                            signals.append(enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: messagesGroup))
                        }
                        signal = combineLatest(signals)
                        |> map { results in
                            var ids: [EngineMessage.Id?] = []
                            for result in results {
                                ids.append(contentsOf: result)
                            }
                            return ids
                        }
                    } else {
                        var transformedMessages = transformedMessages
                        if shouldDivert {
                            transformedMessages = transformedMessages.map { message -> EnqueueMessage in
                                return message.withUpdatedAttributes { attributes in
                                    var attributes = attributes
                                    attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
                                    attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: Int32(Date().timeIntervalSince1970) + 10 * 24 * 60 * 60, repeatPeriod: nil))
                                    return attributes
                                }
                            }
                            shouldOpenScheduledMessages = true
                        }
                        
                        signal = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: transformedMessages)
                    }
                    
                    let _ = (signal
                    |> deliverOnMainQueue).startStandalone(next: { messageIds in
                        guard let strongSelf = self else {
                            return
                        }
                        if case .scheduledMessages = strongSelf.presentationInterfaceState.subject {
                        } else {
                            strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
                            
                            if shouldOpenScheduledMessages {
                                if let layoutActionOnViewTransitionAction = strongSelf.layoutActionOnViewTransitionAction {
                                    strongSelf.layoutActionOnViewTransitionAction = nil
                                    layoutActionOnViewTransitionAction()
                                }
                            }
                        }
                    })
                    
                    donateSendMessageIntent(account: strongSelf.context.account, sharedContext: strongSelf.context.sharedContext, intentContext: .chat, peerIds: [peerId])
                })
            } else if case let .customChatContents(customChatContents) = strongSelf.subject {
                switch customChatContents.kind {
                case .hashTagSearch:
                    break
                case .quickReplyMessageInput, .welcomeMessages:
                    customChatContents.enqueueMessages(messages: messages)
                    strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
                case let .businessLinkSetup(link):
                    if messages.count > 1 {
                        let alertController = textAlertController(
                            context: strongSelf.context,
                            title: nil,
                            text: strongSelf.presentationData.strings.BusinessLink_AlertTextLimitText,
                            actions: [
                                TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_OK, action: {})
                            ]
                        )
                        strongSelf.present(alertController, in: .window(.root))
                        return
                    }
                    
                    var text: String = ""
                    var entities: [MessageTextEntity] = []
                    if let message = messages.first {
                        if case let .message(textValue, attributes, _, _, _, _, _, _, _, _) = message {
                            text = textValue
                            for attribute in attributes {
                                if let attribute = attribute as? TextEntitiesMessageAttribute {
                                    entities = attribute.entities
                                }
                            }
                        }
                    }
                    
                    let _ = strongSelf.context.engine.accountData.editBusinessChatLink(url: link.url, message: text, entities: entities, title: link.title).start()
                    if case let .customChatContents(customChatContents) = strongSelf.subject {
                        customChatContents.businessLinkUpdate(message: text, entities: entities, title: link.title)
                    }
                    
                    strongSelf.present(UndoOverlayController(presentationData: strongSelf.presentationData, content: .succeed(text: strongSelf.presentationData.strings.Business_Links_EditLinkToastSaved, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
                }
            }
            strongSelf.updateChatPresentationInterfaceState(interactive: true, { $0.updatedShowCommands(false) })
        }
        
        if case let .customChatContents(customChatContents) = self.subject {
            customChatContents.hashtagSearchResultsUpdate = { [weak self] searchResult in
                guard let self else {
                    return
                }
                let (results, state) = searchResult
                let isEmpty = results.totalCount == 0
                if isEmpty {
                    self.alwaysShowSearchResultsAsList = true
                }
                self.updateChatPresentationInterfaceState(animated: true, interactive: true, { current in
                    var updatedState = current
                    if let data = current.search {
                        let messageIndices = results.messages.map({ $0.index }).sorted()
                        var currentIndex = messageIndices.last
                        if let previousResultId = data.resultsState?.currentId {
                            for index in messageIndices {
                                if index.id >= previousResultId {
                                    currentIndex = index
                                break
                                }
                            }
                        }
                        updatedState = updatedState.updatedSearch(data.withUpdatedResultsState(ChatSearchResultsState(messageIndices: messageIndices, currentId: currentIndex?.id, state: state, totalCount: results.totalCount, completed: results.completed)))
                    }
                    if isEmpty {
                        updatedState = updatedState.updatedDisplayHistoryFilterAsList(true)
                    }
                    return updatedState
                })
                self.searchResult.set(.single((results, state, .general(scope: .channels, groupId: nil, tags: nil, minDate: nil, maxDate: nil, folderId: nil, communityId: nil))))
            }
        }
        
        self.chatDisplayNode.requestUpdateChatInterfaceState = { [weak self] transition, saveInterfaceState, f in
            self?.updateChatPresentationInterfaceState(transition: transition, interactive: true, saveInterfaceState: saveInterfaceState, { $0.updatedInterfaceState(f) })
        }
        
        self.chatDisplayNode.requestUpdateInterfaceState = { [weak self] transition, interactive, f in
            self?.updateChatPresentationInterfaceState(transition: transition, interactive: interactive, f)
        }
        
        self.chatDisplayNode.displayAttachmentMenu = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.interfaceInteraction?.updateShowWebView { _ in
                return false
            }
            if strongSelf.presentationInterfaceState.interfaceState.editMessage == nil, let _ = strongSelf.presentationInterfaceState.slowmodeState, strongSelf.presentationInterfaceState.subject != .scheduledMessages {
                if let rect = strongSelf.chatDisplayNode.frameForAttachmentButton() {
                    strongSelf.interfaceInteraction?.displaySlowmodeTooltip(strongSelf.chatDisplayNode.view, rect)
                }
                return
            }
            if let messageId = strongSelf.presentationInterfaceState.interfaceState.editMessage?.messageId {
                let _ = (strongSelf.context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
                |> deliverOnMainQueue).startStandalone(next: { message in
                    guard let strongSelf = self, let editMessageState = strongSelf.presentationInterfaceState.editMessageState else {
                        return
                    }
                    var originalMediaReference: AnyMediaReference?
                    if let message = message {
                        for media in message.media {
                            if let image = media as? TelegramMediaImage {
                                originalMediaReference = .message(message: MessageReference(message._asMessage()), media: image)
                            } else if let file = media as? TelegramMediaFile {
                                if file.isVideo || file.isAnimated {
                                    originalMediaReference = .message(message: MessageReference(message._asMessage()), media: file)
                                }
                            }
                        }
                    }
                    var editMediaOptions: MessageMediaEditingOptions?
                    if case let .media(options) = editMessageState.content {
                        editMediaOptions = options
                    }
                    strongSelf.presentAttachmentMenu(subject: .edit(mediaOptions: editMediaOptions, mediaReference: originalMediaReference))
                })
            } else {
                strongSelf.presentAttachmentMenu(subject: .default)
            }
        }
        self.chatDisplayNode.paste = { [weak self] data in
            switch data {
            case let .images(images):
                self?.displayPasteMenu(images.map { .image($0) })
            case let .video(data):
                let tempFilePath = NSTemporaryDirectory() + "\(Int64.random(in: 0...Int64.max)).mp4"
                let url = NSURL(fileURLWithPath: tempFilePath) as URL
                try? data.write(to: url)
                self?.displayPasteMenu([.video(url)])
            case let .gif(data):
                self?.enqueueGifData(data)
            case let .sticker(image, isMemoji):
                self?.enqueueStickerImage(image, isMemoji: isMemoji)
            case let .animatedSticker(data):
                self?.enqueueAnimatedStickerData(data)
            }
        }
        self.chatDisplayNode.updateTypingActivity = { [weak self] value in
            if let strongSelf = self {
                if value {
                    strongSelf.typingActivityPromise.set(Signal<Bool, NoError>.single(true)
                    |> then(
                        Signal<Bool, NoError>.single(false)
                        |> delay(4.0, queue: Queue.mainQueue())
                    ))
                    
                    if !strongSelf.didDisplayGroupEmojiTip, value {
                        strongSelf.didDisplayGroupEmojiTip = true
                        
                        Queue.mainQueue().after(2.0) {
                            strongSelf.displayGroupEmojiTooltip()
                        }
                    }
                    
                    if !strongSelf.didDisplaySendWhenOnlineTip, value {
                        strongSelf.didDisplaySendWhenOnlineTip = true
                        
                        strongSelf.displaySendWhenOnlineTipDisposable.set(
                            (strongSelf.typingActivityPromise.get()
                            |> filter { !$0 }
                            |> take(1)
                            |> deliverOnMainQueue).start(next: { [weak self] _ in
                                if let strongSelf = self {
                                    Queue.mainQueue().after(2.0) {
                                        strongSelf.displaySendWhenOnlineTooltip()
                                    }
                                }
                            })
                        )
                    }
                } else {
                    strongSelf.typingActivityPromise.set(.single(false))
                }
            }
        }
        
        self.chatDisplayNode.dismissUrlPreview = { [weak self] in
            if let strongSelf = self {
                if let _ = strongSelf.presentationInterfaceState.interfaceState.editMessage {
                    if let link = strongSelf.presentationInterfaceState.editingUrlPreview?.url {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { presentationInterfaceState in
                            return presentationInterfaceState.updatedInterfaceState { interfaceState in
                                return interfaceState.withUpdatedEditMessage(interfaceState.editMessage.flatMap { editMessage in
                                    var editMessage = editMessage
                                    if !editMessage.disableUrlPreviews.contains(link) {
                                        editMessage.disableUrlPreviews.append(link)
                                    }
                                    return editMessage
                                })
                            }
                        })
                    }
                } else {
                    if let link = strongSelf.presentationInterfaceState.urlPreview?.url {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { presentationInterfaceState in
                            return presentationInterfaceState.updatedInterfaceState { interfaceState in
                                var composeDisableUrlPreviews = interfaceState.composeDisableUrlPreviews
                                if !composeDisableUrlPreviews.contains(link) {
                                    composeDisableUrlPreviews.append(link)
                                }
                                return interfaceState.withUpdatedComposeDisableUrlPreviews(composeDisableUrlPreviews)
                            }
                        })
                    }
                }
            }
        }
        
        self.chatDisplayNode.navigateButtons.downPressed = { [weak self] in
            guard let self else {
                return
            }
            
            if case let .customChatContents(contents) = self.presentationInterfaceState.subject, case .hashTagSearch = contents.kind {
                self.chatDisplayNode.historyNode.scrollToEndOfHistory()
            } else if let resultsState = self.presentationInterfaceState.search?.resultsState, !resultsState.messageIndices.isEmpty {
                if let currentId = resultsState.currentId, let index = resultsState.messageIndices.firstIndex(where: { $0.id == currentId }) {
                    if index != resultsState.messageIndices.count - 1 {
                        self.interfaceInteraction?.navigateMessageSearch(.later)
                    } else {
                        self.scrollToEndOfHistory()
                    }
                } else {
                    self.scrollToEndOfHistory()
                }
            } else {
                if let messageId = self.contentData?.historyNavigationStack.removeLast() {
                    self.navigateToMessage(from: nil, to: .id(messageId.id, NavigateToMessageParams(timestamp: nil, quote: nil)), rememberInStack: false)
                } else {
                    if case .known = self.chatDisplayNode.historyNode.visibleContentOffset() {
                        self.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    } else if case .peer = self.chatLocation {
                        self.scrollToEndOfHistory()
                    } else if case .replyThread = self.chatLocation {
                        self.scrollToEndOfHistory()
                    } else {
                        self.chatDisplayNode.historyNode.scrollToEndOfHistory()
                    }
                }
            }
        }
        self.chatDisplayNode.navigateButtons.upPressed = { [weak self] in
            guard let self else {
                return
            }
            
            if self.presentationInterfaceState.search?.resultsState != nil {
                self.interfaceInteraction?.navigateMessageSearch(.earlier)
            }
        }
        
        self.chatDisplayNode.navigateButtons.mentionsPressed = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded, let peerId = strongSelf.chatLocation.peerId {
                let signal = strongSelf.context.engine.messages.earliestUnseenPersonalMentionMessage(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { result in
                    if let strongSelf = self {
                        switch result {
                            case let .result(messageId):
                                if let messageId = messageId {
                                    strongSelf.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)))
                                }
                            case .loading:
                                break
                        }
                    }
                }))
            }
        }
        
        self.chatDisplayNode.navigateButtons.mentionsButton.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var menuItems: [ContextMenuItem] = []
            menuItems.append(.action(ContextMenuActionItem(
                id: nil,
                text: strongSelf.presentationData.strings.WebSearch_RecentSectionClear,
                textColor: .primary,
                textLayout: .singleLine,
                icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    
                    guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                        return
                    }
                    let _ = clearPeerUnseenPersonalMessagesInteractively(account: strongSelf.context.account, peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
                }
            )))
            let items = ContextController.Items(content: .list(menuItems))
            
            let controller = makeContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageNavigationButtonContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, contentNode: strongSelf.chatDisplayNode.navigateButtons.mentionsButton.containerNode)), items: .single(items), recognizer: nil, gesture: gesture)
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
            strongSelf.window?.presentInGlobalOverlay(controller)
        }
        
        self.chatDisplayNode.navigateButtons.reactionsPressed = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded, let peerId = strongSelf.chatLocation.peerId {
                let signal = strongSelf.context.engine.messages.earliestUnseenPersonalReactionMessage(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { result in
                    if let strongSelf = self {
                        switch result {
                            case let .result(messageId):
                                if let messageId = messageId {
                                    strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = true
                                    strongSelf.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), scrollPosition: .center(.top), completion: {
                                        guard let strongSelf = self else {
                                            return
                                        }
                                        // The history node plays it and marks the message seen, so it does not play again when
                                        // the message is reported on screen.
                                        strongSelf.chatDisplayNode.historyNode.displayUnseenReactionAnimationsAndMarkSeen(messageIds: [messageId])
                                        
                                        strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = false
                                    })
                                }
                            case .loading:
                                break
                        }
                    }
                }))
            }
        }
        
        self.chatDisplayNode.navigateButtons.reactionsButton.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var menuItems: [ContextMenuItem] = []
            menuItems.append(.action(ContextMenuActionItem(
                id: nil,
                text: strongSelf.presentationData.strings.Conversation_ReadAllReactions,
                textColor: .primary,
                textLayout: .singleLine,
                icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    
                    guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                        return
                    }
                    let _ = clearPeerUnseenReactionsAndPollVotesInteractively(account: strongSelf.context.account, peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
                }
            )))
            let items = ContextController.Items(content: .list(menuItems))
            
            let controller = makeContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageNavigationButtonContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, contentNode: strongSelf.chatDisplayNode.navigateButtons.reactionsButton.containerNode)), items: .single(items), recognizer: nil, gesture: gesture)
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
            strongSelf.window?.presentInGlobalOverlay(controller)
        }
        
        self.chatDisplayNode.navigateButtons.pollVotesPressed = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded, let peerId = strongSelf.chatLocation.peerId {
                let signal = strongSelf.context.engine.messages.earliestUnseenPollVoteMessage(peerId: peerId, threadId: strongSelf.chatLocation.threadId)
                strongSelf.navigationActionDisposable.set((signal |> deliverOnMainQueue).startStrict(next: { result in
                    if let strongSelf = self {
                        switch result {
                            case let .result(messageId):
                                if let messageId = messageId {
                                    strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = true
                                    strongSelf.navigateToMessage(from: nil, to: .id(messageId, NavigateToMessageParams(timestamp: nil, quote: nil)), scrollPosition: .center(.top), completion: {
                                        strongSelf.chatDisplayNode.historyNode.suspendReadingReactions = false
                                    })
                                }
                            case .loading:
                                break
                        }
                    }
                }))
            }
        }
        
        self.chatDisplayNode.navigateButtons.pollVotesButton.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            
            strongSelf.chatDisplayNode.messageTransitionNode.dismissMessageReactionContexts()
            
            var menuItems: [ContextMenuItem] = []
            menuItems.append(.action(ContextMenuActionItem(
                id: nil,
                text: strongSelf.presentationData.strings.Conversation_ReadAllPollVotes,
                textColor: .primary,
                textLayout: .singleLine,
                icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.contextMenu.primaryColor)
                },
                action: { _, f in
                    f(.dismissWithoutContent)
                    
                    guard let strongSelf = self, let peerId = strongSelf.chatLocation.peerId else {
                        return
                    }
                    let _ = clearPeerUnseenReactionsAndPollVotesInteractively(account: strongSelf.context.account, peerId: peerId, threadId: strongSelf.chatLocation.threadId).startStandalone()
                }
            )))
            let items = ContextController.Items(content: .list(menuItems))
            
            let controller = makeContextController(presentationData: strongSelf.presentationData, source: .extracted(ChatMessageNavigationButtonContextExtractedContentSource(chatNode: strongSelf.chatDisplayNode, contentNode: strongSelf.chatDisplayNode.navigateButtons.pollVotesButton.containerNode)), items: .single(items), recognizer: nil, gesture: gesture)
            
            strongSelf.forEachController({ controller in
                if let controller = controller as? TooltipScreen {
                    controller.dismiss()
                }
                return true
            })
            strongSelf.window?.presentInGlobalOverlay(controller)
        }
        
        let interfaceInteraction = ChatPanelInterfaceInteraction(setupReplyMessage: { [weak self] messageId, innerSubject, completion in
            guard let strongSelf = self, strongSelf.isNodeLoaded else {
                return
            }
            
            guard !strongSelf.presentAccountFrozenInfoIfNeeded(delay: true) else {
                completion(.immediate, {})
                return
            }
            
            if let messageId = messageId {
                let intrinsicCanSendMessagesHere = canSendMessagesToChat(strongSelf.presentationInterfaceState)
                var canSendMessagesHere = intrinsicCanSendMessagesHere
                if case .standard(.embedded) = strongSelf.presentationInterfaceState.mode {
                    canSendMessagesHere = false
                }
                if case .inline = strongSelf.presentationInterfaceState.mode {
                    canSendMessagesHere = false
                }
                
                if canSendMessagesHere {
                    let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                        if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId)?._asMessage() {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({
                                $0.withUpdatedReplyMessageSubject(ChatInterfaceState.ReplyMessageSubject(
                                    messageId: message.id,
                                    quote: nil,
                                    innerSubject: innerSubject
                                ))
                            }).updatedReplyMessage(message).updatedSearch(nil).updatedShowCommands(false) }, completion: { t in
                                completion(t, {})
                            })
                            strongSelf.updateItemNodesSearchTextHighlightStates()
                            if !strongSelf.chatDisplayNode.ensureInputViewFocused() {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    self.chatDisplayNode.ensureInputViewFocused()
                                }
                            }
                        } else {
                            completion(.immediate, {})
                        }
                    }, alertAction: {
                        completion(.immediate, {})
                    }, delay: true)
                } else {
                    let replySubject = ChatInterfaceState.ReplyMessageSubject(
                        messageId: messageId,
                        quote: nil,
                        innerSubject: innerSubject
                    )
                    
                    completion(.immediate, {
                        guard let self else {
                            return
                        }
                        if intrinsicCanSendMessagesHere {
                            if let peerId = self.chatLocation.peerId {
                                moveReplyToChat(selfController: self, peerId: peerId, threadId: self.chatLocation.threadId, replySubject: replySubject, completion: {})
                            }
                        } else {
                            moveReplyMessageToAnotherChat(selfController: self, replySubject: replySubject)
                        }
                    })
                }
            } else {
                strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withUpdatedReplyMessageSubject(nil).withUpdatedSendMessageEffect(nil).withUpdatedPostSuggestionState(nil) }) }, completion: { t in
                    completion(t, {})
                })
            }
        }, setupEditMessage: { [weak self] messageId, completion in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                guard let messageId = messageId else {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                        var state = state
                        state = state.updatedInterfaceState {
                            $0.withUpdatedEditMessage(nil)
                        }
                        state = state.updatedEditMessageState(nil)
                        return state
                    }, completion: completion)
                    
                    return
                }
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId)?._asMessage() {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { state in
                            var entities: [MessageTextEntity] = []
                            for attribute in message.attributes {
                                if let attribute = attribute as? TextEntitiesMessageAttribute {
                                    entities = attribute.entities
                                    break
                                }
                            }
                            var inputTextMaxLength: Int32 = 4096
                            var webpageUrl: String?
                            for media in message.media {
                                if media is TelegramMediaImage || media is TelegramMediaFile {
                                    inputTextMaxLength = strongSelf.context.userLimits.maxCaptionLength
                                } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                                    webpageUrl = content.url
                                }
                            }
                            
                            let editInputState: ChatTextInputState
                            if let richTextAttribute = message.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
                                let content = chatInputContent(fromInstantPage: richTextAttribute.instantPage)
                                editInputState = ChatTextInputState(content: content, selectionRange: content.length ..< content.length)
                            } else {
                                let inputText = chatInputStateStringWithAppliedEntities(message.text, entities: entities)
                                editInputState = ChatTextInputState(inputText: inputText)
                            }
                            var disableUrlPreviews: [String] = []
                            if webpageUrl == nil {
                                disableUrlPreviews = detectUrls(editInputState.inputText)
                            }

                            var updated = state.updatedInterfaceState { interfaceState in
                                return interfaceState.withUpdatedEditMessage(ChatEditMessageState(messageId: messageId, inputState: editInputState, disableUrlPreviews: disableUrlPreviews, inputTextMaxLength: inputTextMaxLength, mediaCaptionIsAbove: nil))
                            }
                            
                            let (updatedState, updatedPreviewQueryState) = updatedChatEditInterfaceMessageState(context: strongSelf.context, state: updated, message: message)
                            updated = updatedState
                            strongSelf.editingUrlPreviewQueryState?.1.dispose()
                            strongSelf.editingUrlPreviewQueryState = updatedPreviewQueryState
                            
                            updated = updated.updatedInputMode({ _ in
                                return .text
                            })
                            updated = updated.updatedShowCommands(false)
                            
                            return updated
                        }, completion: completion)
                        
                        if !strongSelf.chatDisplayNode.ensureInputViewFocused() {
                            DispatchQueue.main.async { [weak self] in
                                guard let self else {
                                    return
                                }
                                self.chatDisplayNode.ensureInputViewFocused()
                            }
                        }
                    }
                }, alertAction: {
                    completion(.immediate)
                }, delay: true)
            }
        }, beginMessageSelection: { [weak self] messageIds, completion in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                let _ = strongSelf.presentVoiceMessageDiscardAlert(action: {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withUpdatedSelectedMessages(messageIds) }.updatedShowCommands(false) }, completion: completion)
                    
                    if let selectionState = strongSelf.presentationInterfaceState.interfaceState.selectionState {
                        let count = selectionState.selectedIds.count
                        let text = strongSelf.presentationData.strings.VoiceOver_Chat_MessagesSelected(Int32(count))
                        UIAccessibility.post(notification: UIAccessibility.Notification.announcement, argument: text)
                    }
                }, alertAction: {
                    completion(.immediate)
                }, delay: true)
            } else {
                completion(.immediate)
            }
        }, cancelMessageSelection: { [weak self] transition in
            guard let self else {
                return
            }
            self.updateChatPresentationInterfaceState(transition: transition, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
        }, deleteSelectedMessages: { [weak self] sourceView in
            if let strongSelf = self {
                if let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !messageIds.isEmpty {
                    strongSelf.messageContextDisposable.set((strongSelf.context.sharedContext.chatAvailableMessageActions(engine: strongSelf.context.engine, accountPeerId: strongSelf.context.account.peerId, messageIds: messageIds, keepUpdated: false)
                    |> deliverOnMainQueue).startStrict(next: { actions in
                        if let strongSelf = self, !actions.options.isEmpty {
                            if let banAuthor = actions.banAuthor {
                                strongSelf.presentBanMessageOptions(accountPeerId: strongSelf.context.account.peerId, author: banAuthor, messageIds: messageIds, options: actions.options)
                            } else if !actions.banAuthors.isEmpty {
                                strongSelf.presentMultiBanMessageOptions(accountPeerId: strongSelf.context.account.peerId, authors: actions.banAuthors, messageIds: messageIds, options: actions.options)
                            } else {
                                if actions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty {
                                    strongSelf.presentClearCacheSuggestion()
                                } else {
                                    strongSelf.presentDeleteMessageOptions(messageIds: messageIds, options: actions.options, contextController: nil, sourceView: sourceView, completion: { _ in })
                                }
                            }
                        }
                    }))
                }
            }
        }, reportSelectedMessages: { [weak self] in
            if let strongSelf = self, let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !messageIds.isEmpty {
                if let reportReason = strongSelf.presentationInterfaceState.reportReason {
                    let presentationData = strongSelf.presentationData
                    strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } }, completion: { _ in
                        let _ = (strongSelf.context.engine.messages.reportContent(subject: .messages(Array(messageIds)), option: reportReason.option, message: reportReason.message)
                        |> deliverOnMainQueue).startStandalone(completed: {
                            strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .emoji(name: "PoliceCar", text: presentationData.strings.Report_Succeed), elevatedLayout: false, action: { _ in return false }), in: .current)
                        })
                    })
                } else {
                    strongSelf.context.sharedContext.makeContentReportScreen(
                        context: strongSelf.context,
                        subject: .messages(Array(messageIds).sorted()),
                        forceDark: false,
                        present: { [weak self] controller in
                            self?.push(controller)
                        },
                        completion: { [weak self] in
                            self?.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        },
                        requestSelectMessages: nil
                    )
                }
            }
        }, reportMessages: { [weak self] messages, contextController in
            guard let self, !messages.isEmpty else {
                return
            }
            contextController?.dismiss()
            self.context.sharedContext.makeContentReportScreen(
                context: self.context,
                subject: .messages(messages.map({ $0.id }).sorted()),
                forceDark: false,
                present: { [weak self] controller in
                    guard let self else {
                        return
                    }
                    self.push(controller)
                },
                completion: {},
                requestSelectMessages: nil
            )
        }, blockMessageAuthor: { [weak self] message, contextController in
            contextController?.dismiss(completion: {
                guard let strongSelf = self else {
                    return
                }
                
                let author = message.forwardInfo?.author
                
                guard let peer = author else {
                    return
                }
                
                let presentationData = strongSelf.presentationData
                let controller = ActionSheetController(presentationData: presentationData)
                let dismissAction: () -> Void = { [weak controller] in
                    controller?.dismissAnimated()