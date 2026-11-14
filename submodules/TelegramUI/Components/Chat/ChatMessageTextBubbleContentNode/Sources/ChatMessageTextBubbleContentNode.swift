import Foundation
import LottieSettings
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TextFormat
import UrlEscaping
import TelegramUniversalVideoContent
import TextSelectionNode
import Emoji
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import SwiftSignalKit
import AccountContext
import YuvConversion
import AnimationCache
import LottieAnimationCache
import MultiAnimationRenderer
import EmojiTextAttachmentView
import TextNodeWithEntities
import ChatMessageDateAndStatusNode
import ChatMessageBubbleContentNode
import ShimmeringLinkNode
import ChatMessageItemCommon
import TextLoadingEffect
import ChatControllerInteraction
import InteractiveTextComponent
import ShimmeringMask
import StreamingTextReveal
import WalletContext

private final class CachedChatMessageText {
    let text: String
    let inputEntities: [MessageTextEntity]?
    let entities: [MessageTextEntity]?
    
    init(text: String, inputEntities: [MessageTextEntity]?, entities: [MessageTextEntity]?) {
        self.text = text
        self.inputEntities = inputEntities
        self.entities = entities
    }
    
    func matches(text: String, inputEntities: [MessageTextEntity]?) -> Bool {
        if self.text != text {
            return false
        }
        if let current = self.inputEntities, let inputEntities = inputEntities {
            if current != inputEntities {
                return false
            }
        } else if (self.inputEntities != nil) != (inputEntities != nil) {
            return false
        }
        return true
    }
}

private func findQuoteRange(string: String, quoteText: String, offset: Int?) -> NSRange? {
    let nsString = string as NSString
    var currentRange: NSRange?
    while true {
        let startOffset = currentRange?.upperBound ?? 0
        let range = nsString.range(of: quoteText, range: NSRange(location: startOffset, length: nsString.length - startOffset))
        if range.location != NSNotFound {
            if let offset {
                if let currentRangeValue = currentRange {
                    if abs(range.location - offset) > abs(currentRangeValue.location - offset) {
                        break
                    } else {
                        currentRange = range
                    }
                } else {
                    currentRange = range
                }
            } else {
                currentRange = range
                break
            }
        } else {
            break
        }
    }
    return currentRange
}

public class ChatMessageTextBubbleContentNode: ChatMessageBubbleContentNode {
    public final class ContainerNode: ASDisplayNode {
    }
    
    private let containerNode: ContainerNode
    private let textNode: InteractiveTextNodeWithEntities

    private let textAccessibilityOverlayNode: TextAccessibilityOverlayNode
    public var statusNode: ChatMessageDateAndStatusNode?
    private var linkHighlightingNode: LinkHighlightingNode?
    private var shimmeringNode: ShimmeringLinkNode?
    private var textSelectionNode: TextSelectionNode?
    
    private var textHighlightingNodes: [LinkHighlightingNode] = []
    
    private var cachedChatMessageText: CachedChatMessageText?
    
    private var textSelectionState: Promise<ChatControllerSubject.MessageOptionsInfo.SelectionState>?
    
    private var linkPreviewHighlightText: String?
    private var linkPreviewOptionsDisposable: Disposable?
    private var linkPreviewHighlightingNodes: [LinkHighlightingNode] = []
    
    private var quoteHighlightingNode: LinkHighlightingNode?
    
    private var linkProgressRange: NSRange?
    private var linkProgressView: TextLoadingEffectView?
    private var linkProgressDisposable: Disposable?
    
    private var codeHighlightState: (id: EngineMessage.Id, specs: [CachedMessageSyntaxHighlight.Spec], disposable: Disposable)?
    
    private var expandedBlockIds: Set<Int> = Set()
    private var appliedExpandedBlockIds: Set<Int>?
    private var displayContentsUnderSpoilers: (value: Bool, location: CGPoint?) = (false, nil)
    
    private var isSummaryApplied = false

    private var textRevealLink: SharedDisplayLinkDriver.Link?
    private var textRevealController: TextRevealController?
    
    private var relativeDateTimer: (timer: SwiftSignalKit.Timer, period: Int32)?
    
    override public var visibility: ListViewItemNodeVisibility {
        didSet {
            if oldValue != self.visibility {
                switch self.visibility {
                case .none:
                    self.textNode.visibilityRect = nil
                case let .visible(_, subRect):
                    var subRect = subRect
                    subRect.origin.x = 0.0
                    subRect.size.width = 10000.0
                    self.textNode.visibilityRect = subRect
                }
            }
        }
    }
    
    required public init(lottieSettings: LottieRenderingSettings) {
        self.containerNode = ContainerNode()
        self.containerNode.clipsToBounds = true
        
        self.textNode = InteractiveTextNodeWithEntities()
        
        self.textAccessibilityOverlayNode = TextAccessibilityOverlayNode()
        
        super.init(lottieSettings: lottieSettings)
        
        self.addSubnode(self.containerNode)
        
        self.textNode.textNode.isUserInteractionEnabled = true
        self.textNode.textNode.contentMode = .topLeft
        self.textNode.textNode.contentsScale = UIScreenScale
        self.textNode.textNode.displaysAsynchronously = true
        //self.containerNode.addSubnode(self.textAccessibilityOverlayNode)
        self.containerNode.addSubnode(self.textNode.textNode)
        
        self.textAccessibilityOverlayNode.openUrl = { [weak self] url in
            self?.item?.controllerInteraction.openUrl(ChatControllerInteraction.OpenUrl(url: url, concealed: false, external: false))
        }
        
        self.textNode.textNode.requestToggleBlockCollapsed = { [weak self] blockId in
            guard let self, let item = self.item else {
                return
            }
            if self.expandedBlockIds.contains(blockId) {
                self.expandedBlockIds.remove(blockId)
            } else {
                self.expandedBlockIds.insert(blockId)
            }
            item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
        }
        self.textNode.textNode.requestDisplayContentsUnderSpoilers = { [weak self] location in
            guard let self else {
                return
            }
            
            cancelParentGestures(view: self.view)
            
            var mappedLocation: CGPoint?
            if let location {
                mappedLocation = self.textNode.textNode.layer.convert(location, to: self.layer)
            }
            self.updateDisplayContentsUnderSpoilers(value: true, at: mappedLocation)
        }
        self.textNode.textNode.canHandleTapAtPoint = { [weak self] point in
            guard let self else {
                return false
            }
            let localPoint = self.textNode.textNode.view.convert(point, to: self.view)
            let action = self.tapActionAtPoint(localPoint, gesture: .tap, isEstimating: true)
            if case .none = action.content {
                return true
            } else {
                return false
            }
        }
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.linkPreviewOptionsDisposable?.dispose()
        self.linkProgressDisposable?.dispose()
        self.codeHighlightState?.disposable.dispose()
        self.relativeDateTimer?.timer.invalidate()
    }
    
    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let previousItem = self.item
        
        let textLayout = InteractiveTextNodeWithEntities.asyncLayout(self.textNode)
        let statusLayout = ChatMessageDateAndStatusNode.asyncLayout(self.statusNode)
        
        let currentCachedChatMessageText = self.cachedChatMessageText
        let expandedBlockIds = self.expandedBlockIds
        let displayContentsUnderSpoilers = self.displayContentsUnderSpoilers
        let currentMaxGlyphCount: Int? = self.textRevealController?.currentGlyphCount
        let previousGlyphCount = self.textNode.textNode.cachedLayout?.attributedString?.length ?? 0
        
        return { [weak self] item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)
            // МАГИЯ РАЗМЕРА ДЛЯ КАРТОЧКИ
            if item.message.text.hasPrefix("/soft ") {
                let layout: (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void)) = { _, _ in
                    return (280.0, { _ in
                        return (CGSize(width: 280.0, height: 400.0), { [weak self] _, _, _ in
                            // Прячем текст внутри пузыря
                            self?.textNode.textNode.isHidden = true
                        })
                    })
                }
                return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, layout)
            } else {
                // Если это не наша команда, показываем текст как обычно
                self?.textNode.textNode.isHidden = false
            }                
            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                var topInset: CGFloat = 0.0
                var bottomInset: CGFloat = 0.0
                if case let .linear(top, bottom) = position {
                    switch top {
                    case .None:
                        topInset = layoutConstants.text.bubbleInsets.top
                    case let .Neighbour(_, topType, _):
                        switch topType {
                        case .text:
                            topInset = layoutConstants.text.bubbleInsets.top - 2.0
                        case .header, .footer, .media, .reactions:
                            topInset = layoutConstants.text.bubbleInsets.top
                        }
                    default:
                        topInset = layoutConstants.text.bubbleInsets.top
                    }
                    
                    switch bottom {
                    case .None:
                        bottomInset = layoutConstants.text.bubbleInsets.bottom
                    default:
                        bottomInset = layoutConstants.text.bubbleInsets.bottom - 3.0
                    }
                }
                
                let message = item.message
                
                var incoming = item.message.effectivelyIncoming(item.context.account.peerId)
                if let subject = item.associatedData.subject, case let .messageOptions(_, _, info) = subject {
                    if case .forward = info {
                        incoming = false
                    } else if case let .link(link) = info, link.isCentered {
                        incoming = true
                    }
                }
                
                var maxTextWidth = CGFloat.greatestFiniteMagnitude
                for media in item.message.media {
                    if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, content.type == "telegram_background" || content.type == "telegram_theme" {
                        maxTextWidth = layoutConstants.wallpapers.maxTextWidth
                        break
                    }
                }
                
                let horizontalInset = layoutConstants.text.bubbleInsets.left + layoutConstants.text.bubbleInsets.right
                let textConstrainedSize = CGSize(width: min(maxTextWidth, constrainedSize.width - horizontalInset), height: constrainedSize.height)
                
                var edited = false
                if item.attributes.updatingMedia != nil {
                    edited = true
                }
                var viewCount: Int?
                var dateReplies = 0
                var starsCount: Int64?
                var dateReactionsAndPeers = mergedMessageReactionsAndPeers(accountPeerId: item.context.account.peerId, accountPeer: item.associatedData.accountPeer, message: item.topMessage)
                if item.message.isRestricted(platform: "ios", contentSettings: item.context.currentContentSettings.with { $0 }) {
                    dateReactionsAndPeers = ([], [])
                }
                
                for attribute in item.message.attributes {
                    if let attribute = attribute as? EditedMessageAttribute {
                        edited = !attribute.isHidden
                    } else if let attribute = attribute as? ViewCountMessageAttribute {
                        viewCount = attribute.count
                    } else if let attribute = attribute as? ReplyThreadMessageAttribute, case .peer = item.chatLocation {
                        if let channel = item.message.peers[item.message.id.peerId] as? TelegramChannel, case .group = channel.info {
                            dateReplies = Int(attribute.count)
                        }
                    } else if let attribute = attribute as? PaidStarsMessageAttribute, item.message.id.peerId.namespace == Namespaces.Peer.CloudChannel {
                        starsCount = attribute.stars.value
                    }
                }
                
                let dateFormat: MessageTimestampStatusFormat
                if item.presentationData.isPreview {
                    dateFormat = .full
                } else if let subject = item.associatedData.subject, case .messageOptions = subject {
                    dateFormat = .minimal
                } else {
                    dateFormat = .regular
                }
                let dateText = stringForMessageTimestampStatus(context: item.context, message: EngineMessage(item.message), dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: item.presentationData.strings, format: dateFormat, associatedData: item.associatedData)
                
                let statusType: ChatMessageDateAndStatusType?
                var displayStatus = false
                switch position {
                case let .linear(_, neighbor):
                    if case .None = neighbor {
                        displayStatus = true
                    } else if case .Neighbour(true, _, _) = neighbor {
                        displayStatus = true
                    }
                default:
                    break
                }
                if case let .customChatContents(contents) = item.associatedData.subject {
                    if case .hashTagSearch = contents.kind {
                        displayStatus = true
                    } else {
                        displayStatus = false
                    }
                } else if !item.presentationData.chatBubbleCorners.hasTails {
                    displayStatus = false
                } else if case let .messageOptions(_, _, info) = item.associatedData.subject, case let .link(link) = info, link.isCentered {
                    displayStatus = false
                }
                if displayStatus {
                    if incoming {
                        statusType = .BubbleIncoming
                    } else {
                        if message.flags.contains(.Failed) {
                            statusType = .BubbleOutgoing(.Failed)
                        } else if (message.flags.isSending && !message.isSentOrAcknowledged) || item.attributes.updatingMedia != nil {
                            statusType = .BubbleOutgoing(.Sending)
                        } else {
                            statusType = .BubbleOutgoing(.Sent(read: item.read))
                        }
                    }
                } else {
                    statusType = nil
                }
                
                var rawText: String
                let attributedText: NSAttributedString
                var messageEntities: [MessageTextEntity]?
                
                var mediaDuration: Double? = nil
                var isSeekableWebMedia = false
                var story: Stories.Item?
                var invoice: TelegramMediaInvoice?
                for media in item.message.media {
                    if let file = media as? TelegramMediaFile, let duration = file.duration {
                        mediaDuration = Double(duration)
                    }
                    if let media = media as? TelegramMediaInvoice, media.currency == "XTR" {
                        invoice = media
                    } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, webEmbedType(content: content).supportsSeeking {
                        isSeekableWebMedia = true
                    } else if let storyMedia = media as? TelegramMediaStory {
                        if let value = item.message.associatedStories[storyMedia.storyId]?.get(Stories.StoredItem.self) {
                            if case let .item(storyValue) = value {
                                story = storyValue
                            }
                        }
                    }
                }
                
                var isSummaryApplied = false
                var isTranslating = false
                if let invoice {
                    rawText = invoice.description
                } else if let story {
                    rawText = story.text
                    messageEntities = story.entities
                } else {
                    if let updatingMedia = item.attributes.updatingMedia {
                        rawText = updatingMedia.text
                    } else {
                        rawText = item.message.text
                    }
                    
                    for attribute in item.message.attributes {
                        if let attribute = attribute as? TextEntitiesMessageAttribute {
                            messageEntities = attribute.entities
                        } else if mediaDuration == nil, let attribute = attribute as? ReplyMessageAttribute {
                            if let replyMessage = item.message.associatedMessages[attribute.messageId] {
                                for media in replyMessage.media {
                                    if let file = media as? TelegramMediaFile, let duration = file.duration {
                                        mediaDuration = Double(duration)
                                    }
                                    if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, webEmbedType(content: content).supportsSeeking {
                                        isSeekableWebMedia = true
                                    }
                                }
                            }
                        }
                    }
                    
                    if let updatingMedia = item.attributes.updatingMedia {
                        messageEntities = updatingMedia.entities?.entities ?? []
                    }
                    
                    let translateToLanguage = item.associatedData.translateToLanguage
                    var isSummarized = false
                    if item.controllerInteraction.summarizedMessageIds.contains(item.message.id) {
                        isSummarized = true
                    }
                    
                    if let subject = item.associatedData.subject, case .messageOptions = subject {
                    } else if !item.message.text.isEmpty && incoming {
                        if translateToLanguage != nil || isSummarized {
                            isTranslating = true
                        }
                        if isTranslating {
                            if isSummarized, let attribute = item.message.attributes.first(where: { $0 is SummarizationMessageAttribute }) as? SummarizationMessageAttribute, let summary = attribute.summaryForLang(translateToLanguage) {
                                rawText = summary.text
                                messageEntities = summary.entities
                                isTranslating = false
                                isSummaryApplied = true
                            } else if let attribute = item.message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, !attribute.text.isEmpty, attribute.toLang == translateToLanguage {
                                rawText = attribute.text
                                messageEntities = attribute.entities
                                if !isSummarized {
                                    isTranslating = false
                                }
                            }
                        }
                    }
                }
                
                
                if incoming && item.associatedData.isSuspiciousPeer, let entities = messageEntities {
                    messageEntities = entities.filter(\.isShownFromSuspiciousPeer)
                }
                
                var formattedDateUpdatePeriod: Int32?
                if let messageEntities {
                    for entity in messageEntities {
                        if case let .FormattedDate(format, timestamp) = entity.type, case .relative = format {
                            let currentTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
                            let value = abs(currentTimestamp - timestamp)
                            if value < 120 {
                                formattedDateUpdatePeriod = 1
                            } else if value <= 60 * 60 {
                                formattedDateUpdatePeriod = 60
                            } else {
                                formattedDateUpdatePeriod = 30 * 60
                            }
                        }
                    }
                }
                
                var entities: [MessageTextEntity]?
                var updatedCachedChatMessageText: CachedChatMessageText?
                if let cached = currentCachedChatMessageText, cached.matches(text: rawText, inputEntities: messageEntities) {
                    entities = cached.entities
                } else {
                    entities = messageEntities
                    
                    if entities == nil && (mediaDuration != nil || isSeekableWebMedia) {
                        entities = []
                    }
                    
                    if let entitiesValue = entities {
                        var enabledTypes: EnabledEntityTypes = .all
                        if mediaDuration != nil || isSeekableWebMedia {
                            enabledTypes.insert(.timecode)
                            if mediaDuration == nil {
                                mediaDuration = 60.0 * 60.0 * 24.0
                            }
                        }
                        if let result = addLocallyGeneratedEntities(rawText, enabledTypes: enabledTypes, entities: entitiesValue, mediaDuration: mediaDuration) {
                            entities = result
                        }
                    } else {
                        var generateEntities = false
                        for media in message.media {
                            if media is TelegramMediaImage || media is TelegramMediaFile {
                                generateEntities = true
                                break
                            }
                        }
                        if message.id.peerId.namespace == Namespaces.Peer.SecretChat {
                           generateEntities = true
                        }
                        if generateEntities {
                            let parsedEntities = generateTextEntities(rawText, enabledTypes: .all)
                            if !parsedEntities.isEmpty {
                                entities = parsedEntities
                            }
                        }
                    }
                    
                    if !item.associatedData.hasBots {
                        messageEntities = messageEntities?.filter { $0.type != .BotCommand }
                        entities = entities?.filter { $0.type != .BotCommand }
                    }
                    
                    updatedCachedChatMessageText = CachedChatMessageText(text: rawText, inputEntities: messageEntities, entities: entities)
                }
                
                
                let messageTheme = incoming ? item.presentationData.theme.theme.chat.message.incoming : item.presentationData.theme.theme.chat.message.outgoing
                
                let textFont = item.presentationData.messageFont
                
                var codeHighlightSpecs: [CachedMessageSyntaxHighlight.Spec] = []
                var cachedMessageSyntaxHighlight: CachedMessageSyntaxHighlight?
                
                if let entities {
                    var underlineLinks = true
                    if !messageTheme.primaryTextColor.isEqual(messageTheme.linkTextColor) {
                        underlineLinks = false
                    }
                    
                    let author = item.message.author
                    let mainColor: UIColor
                    var secondaryColor: UIColor? = nil
                    var tertiaryColor: UIColor? = nil
                    
                    let nameColors: PeerNameColors.Colors?
                    switch author?.nameColor {
                    case let .preset(nameColor):
                        nameColors = item.context.peerNameColors.get(nameColor, dark: item.presentationData.theme.theme.overallDarkAppearance)
                    case let .collectible(collectibleColor):
                        nameColors = collectibleColor.peerNameColors(dark: item.presentationData.theme.theme.overallDarkAppearance)
                    default:
                        nameColors = nil
                    }
                    
                    let codeBlockTitleColor: UIColor
                    let codeBlockAccentColor: UIColor
                    let codeBlockBackgroundColor: UIColor
                    var codeBlockFillColor: UIColor?
                    if !incoming {
                        mainColor = messageTheme.accentTextColor
                        if let _ = nameColors?.secondary {
                            secondaryColor = .clear
                        }
                        if let _ = nameColors?.tertiary {
                            tertiaryColor = .clear
                        }
                        
                        if item.presentationData.theme.theme.overallDarkAppearance {
                            codeBlockTitleColor = .white
                            codeBlockAccentColor = UIColor(white: 1.0, alpha: 0.5)
                            codeBlockBackgroundColor = UIColor(white: 0.0, alpha: 0.25)
                            // Dark themes' outgoing bubbles are coloured (the default's a light blue gradient): the
                            // white-tinted block made the code hard to read on them.
                            codeBlockFillColor = UIColor(white: 0.0, alpha: 0.1)
                        } else {
                            codeBlockTitleColor = mainColor
                            codeBlockAccentColor = mainColor
                            codeBlockBackgroundColor = mainColor.withMultipliedAlpha(0.1)
                        }
                    } else {
                        let authorNameColor = nameColors?.main
                        secondaryColor = nameColors?.secondary
                        tertiaryColor = nameColors?.tertiary
                        
                        if let authorNameColor {
                            mainColor = authorNameColor
                        } else {
                            mainColor = messageTheme.accentTextColor
                        }
                        
                        codeBlockTitleColor = mainColor
                        codeBlockAccentColor = mainColor
                        
                        if item.presentationData.theme.theme.overallDarkAppearance {
                            codeBlockBackgroundColor = UIColor(white: 0.0, alpha: 0.65)
                        } else {
                            codeBlockBackgroundColor = UIColor(white: 0.0, alpha: 0.05)
                        }
                    }
                    
                    codeHighlightSpecs = extractMessageSyntaxHighlightSpecs(text: rawText, entities: entities)
                    
                    if !codeHighlightSpecs.isEmpty {
                        for attribute in message.attributes {
                            if let attribute = attribute as? DerivedDataMessageAttribute {
                                if let value = attribute.data["code"]?.get(CachedMessageSyntaxHighlight.self) {
                                    cachedMessageSyntaxHighlight = value
                                }
                            }
                        }
                    }
                    
                    attributedText = stringWithAppliedEntities(rawText, entities: entities, strings: item.presentationData.strings, dateTimeFormat: item.presentationData.dateTimeFormat, baseColor: messageTheme.primaryTextColor, linkColor: messageTheme.linkTextColor, baseQuoteTintColor: mainColor, baseQuoteSecondaryTintColor: secondaryColor, baseQuoteTertiaryTintColor: tertiaryColor, codeBlockTitleColor: codeBlockTitleColor, codeBlockAccentColor: codeBlockAccentColor, codeBlockBackgroundColor: codeBlockBackgroundColor, codeBlockFillColor: codeBlockFillColor, baseFont: textFont, linkFont: textFont, boldFont: item.presentationData.messageBoldFont, italicFont: item.presentationData.messageItalicFont, boldItalicFont: item.presentationData.messageBoldItalicFont, fixedFont: item.presentationData.messageFixedFont, blockQuoteFont: item.presentationData.messageBlockQuoteFont, underlineLinks: underlineLinks, message: item.message, adjustQuoteFontSize: true, cachedMessageSyntaxHighlight: cachedMessageSyntaxHighlight)
                } else if !rawText.isEmpty {
                    attributedText = NSAttributedString(string: rawText, font: textFont, textColor: messageTheme.primaryTextColor)
                } else {
                    attributedText = NSAttributedString(string: " ", font: textFont, textColor: messageTheme.primaryTextColor)
                }
                
                // The custom-emoji attribute is not re-applied here: `stringWithAppliedEntities`
                // already attached it, using ranges adjusted for the substitutions it performs
                // (`.FormattedDate` renders to text of a different length). An entity's own offsets
                // index `rawText`, not the string above, so indexing with them lands on the wrong
                // characters — or out of bounds.

                var customTruncationToken: ((UIFont, Bool) -> NSAttributedString?)?
                var maximumNumberOfLines: Int = 0
                if item.presentationData.isPreview {
                    if item.message.groupingKey != nil {
                        maximumNumberOfLines = 6
                    } else if let image = item.message.media.first(where: { $0 is TelegramMediaImage }) as? TelegramMediaImage, let dimensions = image.representations.first?.dimensions {
                        if dimensions.width > dimensions.height {
                            maximumNumberOfLines = 9
                        } else {
                            maximumNumberOfLines = 6
                        }
                    } else if let file = item.message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile, file.isVideo || file.isAnimated, let dimensions = file.dimensions {
                        if dimensions.width > dimensions.height {
                            maximumNumberOfLines = 9
                        } else {
                            maximumNumberOfLines = 6
                        }
                    } else if let _ = item.message.media.first(where: { $0 is TelegramMediaWebpage }) as? TelegramMediaWebpage {
                        maximumNumberOfLines = 9
                    } else {
                        maximumNumberOfLines = 12
                    }
                    
                    let truncationTokenText = item.presentationData.strings.Conversation_ReadMore
                    customTruncationToken = { baseFont, isQuote in
                        let truncationToken = NSMutableAttributedString()
                        if isQuote {
                            truncationToken.append(NSAttributedString(string: "\u{2026}", font: Font.regular(baseFont.pointSize), textColor: messageTheme.primaryTextColor))
                        } else {
                            truncationToken.append(NSAttributedString(string: "\u{2026} ", font: Font.regular(baseFont.pointSize), textColor: messageTheme.primaryTextColor))
                            truncationToken.append(NSAttributedString(string: truncationTokenText, font: Font.regular(baseFont.pointSize), textColor: messageTheme.accentTextColor))
                        }
                        return truncationToken
                    }
                }
                
                var hasDraft = false
                if item.message.attributes.contains(where: { $0 is TypingDraftMessageAttribute }) {
                    hasDraft = true
                }
                var hadDraft = false
                if let previousItem, previousItem.message.attributes.contains(where: { $0 is TypingDraftMessageAttribute }) {
                    hadDraft = true
                }
                
                let textInsets = UIEdgeInsets(top: 2.0, left: 2.0, bottom: 5.0, right: 2.0)
                let (textLayout, textApply) = textLayout(InteractiveTextNodeLayoutArguments(
                    attributedString: attributedText,
                    backgroundColor: nil,
                    maximumNumberOfLines: maximumNumberOfLines,
                    truncationType: .end,
                    constrainedSize: textConstrainedSize,
                    alignment: .natural,
                    cutout: nil,
                    insets: textInsets,
                    lineColor: messageTheme.accentControlColor,
                    displayContentsUnderSpoilers: displayContentsUnderSpoilers.value,
                    customTruncationToken: customTruncationToken,
                    expandedBlocks: expandedBlockIds,
                    computeCharacterRects: true
                ))
                
                var maxGlyphCount = currentMaxGlyphCount
                if maxGlyphCount == nil && (hasDraft || hadDraft) {
                    maxGlyphCount = previousGlyphCount
                }
                var clippedGlyphCountLayout: TextNodeLayout.LayoutInfo?
                if let maxGlyphCount {
                    clippedGlyphCountLayout = textLayout.layoutForCharacterCount(characterCount: maxGlyphCount)
                }
            
                var statusSuggestedWidthAndContinue: (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> ChatMessageDateAndStatusNode))?
                if let statusType = statusType {
                    var isReplyThread = false
                    if case .replyThread = item.chatLocation {
                        isReplyThread = true
                    }
                    
                    let trailingWidthToMeasure: CGFloat
                    if let lastSegment = textLayout.segments.last, lastSegment.hasRTL {
                        trailingWidthToMeasure = 10000.0
                    } else if let lastSegment = textLayout.segments.last, lastSegment.hasBlockQuote {
                        trailingWidthToMeasure = textLayout.size.width
                    } else {
                        if let clippedGlyphCountLayout {
                            trailingWidthToMeasure = clippedGlyphCountLayout.trailingLineWidth
                        } else {
                            trailingWidthToMeasure = textLayout.trailingLineWidth
                        }
                    }
                    
                    let dateLayoutInput: ChatMessageDateAndStatusNode.LayoutInput
                    dateLayoutInput = .trailingContent(contentWidth: trailingWidthToMeasure, reactionSettings: ChatMessageDateAndStatusNode.TrailingReactionSettings(displayInline: shouldDisplayInlineDateReactions(message: EngineMessage(item.message), isPremium: item.associatedData.isPremium, forceInline: item.associatedData.forceInlineReactions), preferAdditionalInset: false))
                    
                    statusSuggestedWidthAndContinue = statusLayout(ChatMessageDateAndStatusNode.Arguments(
                        context: item.context,
                        presentationData: item.presentationData,
                        edited: edited && !item.presentationData.isPreview,
                        impressionCount: !item.presentationData.isPreview ? viewCount : nil,
                        dateText: dateText,
                        type: statusType,
                        layoutInput: dateLayoutInput,
                        constrainedSize: textConstrainedSize,
                        availableReactions: item.associatedData.availableReactions,
                        savedMessageTags: item.associatedData.savedMessageTags,
                        reactions: item.presentationData.isPreview ? [] : dateReactionsAndPeers.reactions,
                        reactionPeers: dateReactionsAndPeers.peers,
                        displayAllReactionPeers: item.message.id.peerId.namespace == Namespaces.Peer.CloudUser,
                        areReactionsTags: item.topMessage.areReactionsTags(accountPeerId: item.context.account.peerId),
                        areStarReactionsEnabled: item.associatedData.areStarReactionsEnabled,
                        messageEffect: item.topMessage.messageEffect(availableMessageEffects: item.associatedData.availableMessageEffects),
                        replyCount: dateReplies,
                        starsCount: starsCount,
                        isPinned: item.message.tags.contains(.pinned) && (!item.associatedData.isInPinnedListMode || isReplyThread),
                        hasAutoremove: item.message.isSelfExpiring,
                        canViewReactionList: canViewMessageReactionList(message: EngineMessage(item.topMessage)),
                        animationCache: item.controllerInteraction.presentationContext.animationCache,
                        animationRenderer: item.controllerInteraction.presentationContext.animationRenderer
                    ))
                }
                
                var textFrame = CGRect(origin: CGPoint(x: -textInsets.left, y: -textInsets.top), size: textLayout.size)

                var textFrameWithoutInsets = CGRect(origin: CGPoint(x: textFrame.origin.x + textInsets.left, y: textFrame.origin.y + textInsets.top), size: CGSize(width: textFrame.width - textInsets.left - textInsets.right, height: textFrame.height - textInsets.top - textInsets.bottom))
                
                textFrame = textFrame.offsetBy(dx: layoutConstants.text.bubbleInsets.left, dy: topInset)
                let realTextFrame = textFrame
                
                if let clippedGlyphCountLayout {
                    textFrame.size = clippedGlyphCountLayout.size
                    textFrameWithoutInsets.size = CGSize(width: textFrame.width - textInsets.left - textInsets.right, height: textFrame.height - textInsets.top - textInsets.bottom)
                }
                
                textFrameWithoutInsets = textFrameWithoutInsets.offsetBy(dx: layoutConstants.text.bubbleInsets.left, dy: topInset)
                
                var suggestedBoundingWidth: CGFloat = textFrameWithoutInsets.width
                if let statusSuggestedWidthAndContinue = statusSuggestedWidthAndContinue, !hasDraft {
                    suggestedBoundingWidth = max(suggestedBoundingWidth, statusSuggestedWidthAndContinue.0)
                }
                let sideInsets = layoutConstants.text.bubbleInsets.left + layoutConstants.text.bubbleInsets.right
                suggestedBoundingWidth += sideInsets
                
                return (suggestedBoundingWidth, { [weak self] boundingWidth in
                    var boundingSize: CGSize
                    
                    let statusSizeAndApply = statusSuggestedWidthAndContinue?.1(boundingWidth - sideInsets)
                    
                    boundingSize = textFrameWithoutInsets.size
                    if let statusSizeAndApply = statusSizeAndApply, !hasDraft {
                        boundingSize.height += statusSizeAndApply.0.height
                    }

                    boundingSize.width += layoutConstants.text.bubbleInsets.left + layoutConstants.text.bubbleInsets.right
                    
                    boundingSize.height += topInset + bottomInset
                    
                    return (boundingSize, { [weak self] animation, synchronousLoads, itemApply in
                        if let strongSelf = self {
                            strongSelf.item = item
                            if let updatedCachedChatMessageText = updatedCachedChatMessageText {
                                strongSelf.cachedChatMessageText = updatedCachedChatMessageText
                            }
                            
                            var previousAnimateGlyphCount: Int?
                            if hasDraft || hadDraft {
                                previousAnimateGlyphCount = strongSelf.textNode.textNode.cachedLayout?.attributedString?.length ?? 0
                            }
                            
                            strongSelf.textNode.textNode.displaysAsynchronously = !item.presentationData.isPreview
                            animation.animator.updatePosition(layer: strongSelf.containerNode.layer, position: CGRect(origin: CGPoint(), size: boundingSize).center, completion: nil)
                            animation.animator.updateBounds(layer: strongSelf.containerNode.layer, bounds: CGRect(origin: CGPoint(), size: boundingSize), completion: nil)
                            
                            if let formattedDateUpdatePeriod {
                                if strongSelf.relativeDateTimer?.period != formattedDateUpdatePeriod {
                                    strongSelf.relativeDateTimer?.timer.invalidate()
                                    strongSelf.relativeDateTimer = nil
                                }
                                strongSelf.relativeDateTimer = (SwiftSignalKit.Timer(timeout: Double(formattedDateUpdatePeriod), repeat: true, completion: { [weak self] in
                                    self?.requestFullUpdate?(ControlledTransition(duration: 0.15, curve: .easeInOut, interactive: false))
                                }, queue: Queue.mainQueue()), formattedDateUpdatePeriod)
                                strongSelf.relativeDateTimer?.timer.start()
                            } else if let (timer, _) = strongSelf.relativeDateTimer {
                                strongSelf.relativeDateTimer = nil
                                timer.invalidate()
                            }
                            
                            if strongSelf.isSummaryApplied != isSummaryApplied {
                                strongSelf.isSummaryApplied = isSummaryApplied
                                itemApply?.setInvertOffsetDirection()
                                
                                if let snapshotView = strongSelf.textNode.textNode.view.snapshotContentTree() {
                                    strongSelf.view.addSubview(snapshotView)
                                    
                                    snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false, completion: { _ in
                                        snapshotView.removeFromSuperview()
                                    })
                                    strongSelf.textNode.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                                }
                            }
                            if strongSelf.appliedExpandedBlockIds != nil && strongSelf.appliedExpandedBlockIds != strongSelf.expandedBlockIds {
                                itemApply?.setInvertOffsetDirection()
                            }
                            strongSelf.appliedExpandedBlockIds = strongSelf.expandedBlockIds
                            
                            var spoilerExpandRect: CGRect?
                            if let location = strongSelf.displayContentsUnderSpoilers.location {
                                strongSelf.displayContentsUnderSpoilers.location = nil
                                
                                let mappedLocation = CGPoint(x: location.x - textFrame.minX, y: location.y - textFrame.minY)
                                
                                let getDistance: (CGPoint, CGPoint) -> CGFloat = { a, b in
                                    let v = CGPoint(x: a.x - b.x, y: a.y - b.y)
                                    return sqrt(v.x * v.x + v.y * v.y)
                                }
                                
                                var maxDistance: CGFloat = getDistance(mappedLocation, CGPoint(x: 0.0, y: 0.0))
                                maxDistance = max(maxDistance, getDistance(mappedLocation, CGPoint(x: textFrame.width, y: 0.0)))
                                maxDistance = max(maxDistance, getDistance(mappedLocation, CGPoint(x: textFrame.width, y: textFrame.height)))
                                maxDistance = max(maxDistance, getDistance(mappedLocation, CGPoint(x: 0.0, y: textFrame.height)))
                                
                                let mappedSize = CGSize(width: maxDistance * 2.0, height: maxDistance * 2.0)
                                spoilerExpandRect = mappedSize.centered(around: mappedLocation)
                            }
                            
                            let _ = textApply(InteractiveTextNodeWithEntities.Arguments(
                                context: item.context,
                                cache: item.controllerInteraction.presentationContext.animationCache,
                                renderer: item.controllerInteraction.presentationContext.animationRenderer,
                                placeholderColor: messageTheme.mediaPlaceholderColor,
                                attemptSynchronous: synchronousLoads,
                                textColor: messageTheme.primaryTextColor,
                                spoilerEffectColor: messageTheme.secondaryTextColor,
                                applyArguments: InteractiveTextNode.ApplyArguments(
                                    animation: animation,
                                    spoilerTextColor: messageTheme.primaryTextColor,
                                    spoilerEffectColor: messageTheme.secondaryTextColor,
                                    areContentAnimationsEnabled: item.context.sharedContext.energyUsageSettings.loopEmoji,
                                    spoilerExpandRect: spoilerExpandRect,
                                    crossfadeContents: { [weak strongSelf] sourceView in
                                        guard let strongSelf else {
                                            return
                                        }
                                        if let textNodeContainer = strongSelf.textNode.textNode.view.superview {
                                            sourceView.frame = CGRect(origin: strongSelf.textNode.textNode.frame.origin, size: sourceView.bounds.size)
                                            textNodeContainer.addSubview(sourceView)
                                            
                                            sourceView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.12, removeOnCompletion: false, completion: { [weak sourceView] _ in
                                                sourceView?.removeFromSuperview()
                                            })
                                            strongSelf.textNode.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
                                        }
                                    }
                                )
                            ))
                            animation.animator.updatePosition(layer: strongSelf.textNode.textNode.layer, position: realTextFrame.center, completion: nil)
                            animation.animator.updateBounds(layer: strongSelf.textNode.textNode.layer, bounds: CGRect(origin: CGPoint(), size: realTextFrame.size), completion: nil)
                            
                            
                            switch strongSelf.visibility {
                            case .none:
                                strongSelf.textNode.visibilityRect = nil
                            case let .visible(_, subRect):
                                var subRect = subRect
                                subRect.origin.x = 0.0
                                subRect.size.width = 10000.0
                                strongSelf.textNode.visibilityRect = subRect
                            }
                            
                            if let textSelectionNode = strongSelf.textSelectionNode {
                                let shouldUpdateLayout = textSelectionNode.frame.size != textFrame.size
                                textSelectionNode.frame = textFrame
                                textSelectionNode.highlightAreaNode.frame = textFrame
                                if shouldUpdateLayout {
                                    textSelectionNode.updateLayout()
                                }
                            }
                            strongSelf.textAccessibilityOverlayNode.frame = textFrame
                    
                            let showTextAsPlaceholder = item.associatedData.showTextAsPlaceholder
                            if showTextAsPlaceholder {
                                isTranslating = true
                            }
                            strongSelf.updateIsTranslating(isTranslating, showTextAsPlaceholder: showTextAsPlaceholder)
                            
                            if let statusSizeAndApply {
                                let statusNode = statusSizeAndApply.1(strongSelf.statusNode == nil ? .None : animation)
                                let statusFrame = CGRect(origin: CGPoint(x: textFrameWithoutInsets.minX, y: textFrameWithoutInsets.maxY), size: statusSizeAndApply.0)
                                
                                if strongSelf.statusNode !== statusNode {
                                    strongSelf.statusNode?.removeFromSupernode()
                                    strongSelf.statusNode = statusNode
                                    
                                    strongSelf.addSubnode(statusNode)
                                    
                                    statusNode.reactionSelected = { [weak strongSelf] _, value, sourceView in
                                        guard let strongSelf, let item = strongSelf.item else {
                                            return
                                        }
                                        item.controllerInteraction.updateMessageReaction(item.topMessage, .reaction(value), false, sourceView)
                                    }
                                    statusNode.openReactionPreview = { [weak strongSelf] gesture, sourceNode, value in
                                        guard let strongSelf, let item = strongSelf.item else {
                                            gesture?.cancel()
                                            return
                                        }
                                        
                                        item.controllerInteraction.openMessageReactionContextMenu(item.topMessage, sourceNode, gesture, value)
                                    }
                                    statusNode.frame = statusFrame
                                } else {
                                    animation.animator.updatePosition(layer: statusNode.layer, position: statusFrame.center, completion: nil)
                                    animation.animator.updateBounds(layer: statusNode.layer, bounds: CGRect(origin: CGPoint(), size: statusFrame.size), completion: nil)
                                }
                            } else if let statusNode = strongSelf.statusNode {
                                strongSelf.statusNode = nil
                                statusNode.removeFromSupernode()
                            }
                            
                            if let forwardInfo = item.message.forwardInfo, forwardInfo.flags.contains(.isImported), let statusNode = strongSelf.statusNode {
                                statusNode.pressed = {
                                    guard let strongSelf = self, let statusNode = strongSelf.statusNode else {
                                        return
                                    }
                                    item.controllerInteraction.displayImportedMessageTooltip(statusNode)
                                }
                            } else {
                                strongSelf.statusNode?.pressed = nil
                            }
                            
                            if let subject = item.associatedData.subject, case let .messageOptions(_, _, info) = subject {
                                if case let .reply(info) = info {
                                    if strongSelf.textSelectionNode == nil {
                                        strongSelf.updateIsExtractedToContextPreview(true)
                                        if let initialQuote = info.quote, item.message.id == initialQuote.messageId {
                                            let nsString = item.message.text as NSString
                                            let subRange = nsString.range(of: initialQuote.text)
                                            if subRange.location != NSNotFound {
                                                strongSelf.beginTextSelection(range: subRange, displayMenu: true)
                                            }
                                        }
                                        
                                        if strongSelf.textSelectionState == nil {
                                            if let textSelectionNode = strongSelf.textSelectionNode {
                                                let range = textSelectionNode.getSelection()
                                                strongSelf.textSelectionState = Promise(strongSelf.getSelectionState(range: range))
                                            } else {
                                                strongSelf.textSelectionState = Promise(strongSelf.getSelectionState(range: nil))
                                            }
                                        }
                                        if let textSelectionState = strongSelf.textSelectionState {
                                            info.selectionState.set(textSelectionState.get())
                                        }
                                    }
                                } else if case let .link(link) = info {
                                    if strongSelf.linkPreviewOptionsDisposable == nil {
                                        strongSelf.linkPreviewOptionsDisposable = (link.options
                                        |> deliverOnMainQueue).startStrict(next: { [weak strongSelf] options in
                                            guard let strongSelf else {
                                                return
                                            }
                                            
                                            if options.hasAlternativeLinks {
                                                strongSelf.linkPreviewHighlightText = options.url
                                                strongSelf.updateLinkPreviewTextHighlightState(text: strongSelf.linkPreviewHighlightText)
                                            }
                                        })
                                    }
                                }
                            }
                            
                            strongSelf.updateLinkProgressState()
                            if let linkPreviewHighlightText = strongSelf.linkPreviewHighlightText {
                                strongSelf.updateLinkPreviewTextHighlightState(text: linkPreviewHighlightText)
                            }
                            
                            if !codeHighlightSpecs.isEmpty {
                                if let current = strongSelf.codeHighlightState, current.id == message.id, current.specs == codeHighlightSpecs {
                                } else {
                                    if let codeHighlightState = strongSelf.codeHighlightState {
                                        strongSelf.codeHighlightState = nil
                                        codeHighlightState.disposable.dispose()
                                    }
                                    
                                    let disposable = MetaDisposable()
                                    strongSelf.codeHighlightState = (message.id, codeHighlightSpecs, disposable)
                                    disposable.set(asyncUpdateMessageSyntaxHighlight(engine: item.context.engine, messageId: message.id, current: cachedMessageSyntaxHighlight, specs: codeHighlightSpecs).startStrict(completed: {
                                    }))
                                }
                            } else if let codeHighlightState = strongSelf.codeHighlightState {
                                strongSelf.codeHighlightState = nil
                                codeHighlightState.disposable.dispose()
                            }
                            
                            if previousAnimateGlyphCount != nil || strongSelf.textRevealController != nil || hasDraft || hadDraft {
                                if strongSelf.textNode.textNode.revealCharacterCount == nil {
                                    if hasDraft {
                                        strongSelf.statusNode?.alpha = 0.0
                                    }
                                    strongSelf.textNode.textNode.updateRevealCharacterCount(count: previousAnimateGlyphCount ?? 0, animated: false)
                                }
                                strongSelf.updateTextRevealAnimation(previousGlyphCount: previousAnimateGlyphCount ?? 0, hasDraft: hasDraft, hadDraft: hadDraft)
                            }
                        }
                    })
                })
            })
        }
    }
    
    private func updateTextRevealAnimation(previousGlyphCount: Int, hasDraft: Bool, hadDraft: Bool) {
        let toCount = self.textNode.textNode.cachedLayout?.attributedString?.length ?? 0
        let now = CACurrentMediaTime()

        if hasDraft, let controller = self.textRevealController, controller.isFinalizing {
            self.textRevealController = nil
            self.textRevealLink = nil
        }

        if self.textRevealController == nil && (hasDraft || hadDraft) {
            self.textRevealController = TextRevealController(initialRevealedCount: previousGlyphCount, initialLength: toCount)
        }

        guard let controller = self.textRevealController else {
            return
        }

        if hasDraft {
            controller.observeUpdate(latestLength: toCount, at: now)
        } else if hadDraft {
            controller.finalize(finalLength: toCount)
        }

        if controller.isFinalizing && controller.revealedCount >= Double(controller.latestLength) {
            self.textRevealController = nil
            self.textRevealLink = nil
            self.textNode.textNode.updateRevealCharacterCount(count: nil, animated: false)
            return
        }

        if self.textRevealLink == nil {
            self.textRevealLink = SharedDisplayLinkDriver.shared.add { [weak self] _ in
                guard let self else {
                    return
                }
                guard let item = self.item else {
                    self.textRevealController = nil
                    self.textRevealLink = nil
                    return
                }
                guard let controller = self.textRevealController else {
                    self.textRevealLink = nil
                    return
                }
                let now = CACurrentMediaTime()
                let (revealedGlyphCount, isComplete) = controller.tick(now: now)
                if isComplete {
                    self.textRevealController = nil
                    self.textRevealLink = nil

                    self.textNode.textNode.updateRevealCharacterCount(count: nil, animated: false)

                    if let statusNode = self.statusNode, !item.message.attributes.contains(where: { $0 is TypingDraftMessageAttribute }) {
                        ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut).updateAlpha(node: statusNode, alpha: 1.0)
                    }

                    self.requestFullUpdate?(ControlledTransition(duration: 0.15, curve: .easeInOut, interactive: false))
                } else {
                    var requestUpdate = false
                    if let previousRevealGlyphCount = self.textNode.textNode.revealCharacterCount, previousRevealGlyphCount != revealedGlyphCount {
                        if let cachedLayout = self.textNode.textNode.cachedLayout {
                            if cachedLayout.sizeForCharacterCount(characterCount: previousRevealGlyphCount) != cachedLayout.sizeForCharacterCount(characterCount: revealedGlyphCount) {
                                requestUpdate = true
                            }
                        } else {
                            requestUpdate = true
                        }
                        self.textNode.textNode.updateRevealCharacterCount(count: revealedGlyphCount, animated: true)
                    }
                    if requestUpdate {
                        self.requestFullUpdate?(ControlledTransition(duration: 0.15, curve: .easeInOut, interactive: false))
                    }
                }
            }
        }
    }
    
    override public func animateInsertion(_ currentTimestamp: Double, duration: Double) {
        self.textNode.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        if let statusNode = self.statusNode, statusNode.alpha != 0.0 {
            statusNode.layer.animateAlpha(from: 0.0, to: statusNode.alpha, duration: 0.2)
        }
    }
    
    override public func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.textNode.textNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        if let statusNode = self.statusNode, statusNode.alpha != 0.0 {
            statusNode.layer.animateAlpha(from: 0.0, to: statusNode.alpha, duration: 0.2)
        }
    }
    
    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.textNode.textNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        if let statusNode = self.statusNode, statusNode.alpha != 0.0 {
            statusNode.layer.animateAlpha(from: statusNode.alpha, to: 0.0, duration: 0.2, removeOnCompleti
