import WebKit
import Foundation
import LottieSettings
import UniformTypeIdentifiers
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TextFormat
import AccountContext
import TouchDownGesture
import ImageTransparency
import ActivityIndicator
import AnimationUI
import Speak
import ObjCRuntimeUtils
import AvatarNode
import ContextUI
import InvisibleInkDustNode
import TextInputMenu
import Pasteboard
import ChatPresentationInterfaceState
import ManagedAnimationNode
import EditableChatTextNode
import EmojiTextAttachmentView
import LottieAnimationComponent
import ComponentFlow
import EmojiSuggestionsComponent
import AudioToolbox
import ChatControllerInteraction
import UndoUI
import PremiumUI
import StickerPeekUI
import LottieComponent
import SolidRoundedButtonNode
import TooltipUI
import ChatTextInputMediaRecordingButton
import ChatContextQuery
import ChatInputTextNode
import ChatInputPanelNode
import ChatRichTextEditorComposer
import TelegramNotices
import AnimatedCountLabelNode
import TelegramStringFormatting
import TextNodeWithEntities
import DeviceModel
import PhotoResources
import GlassBackgroundComponent
import ComponentDisplayAdapters
import ChatInputAccessoryPanel
import ChatInputAutocompletePanel
import ChatTextInputSlowmodePlaceholderNode
import ChatTextInputActionButtonsNode
import ChatTextInputAudioRecordingTimeNode
import ChatTextInputAudioRecordingCancelIndicator
import ChatRecordingViewOnceButtonNode
import ChatRecordingPreviewInputPanelNode
import ChatInputContextPanelNode
import RasterizedCompositionComponent
import RichTextEditorUIKit
import RichTextEditorCore

/// The chat composer's inline custom-emoji view already exposes `dynamicColor` (forwarding to its backing
/// `InlineStickerItemLayer`), so it satisfies the editor's emoji-view contract as-is. Declared here (the one
/// module importing both) to keep `EmojiTextAttachmentView` free of a rich-text-editor dependency.
extension EmojiTextAttachmentView: @retroactive RichTextEmojiView {}

private let counterFont = Font.with(size: 14.0, design: .regular, traits: [.monospacedNumbers])

public let chatTextInputMinFontSize: CGFloat = 5.0

private let minInputFontSize = chatTextInputMinFontSize

private func calclulateTextFieldMinHeight(_ presentationInterfaceState: ChatPresentationInterfaceState, metrics: LayoutMetrics) -> CGFloat {
    return chatTextInputFieldMinHeight(for: presentationInterfaceState.fontSize)
}

private func calculateTextFieldRealInsets(presentationInterfaceState: ChatPresentationInterfaceState, accessoryButtonsWidth: CGFloat, actionControlsWidth: CGFloat) -> UIEdgeInsets {
    var insets = chatTextInputFieldVerticalInsets(for: presentationInterfaceState.fontSize)
    insets.right += max(0.0, accessoryButtonsWidth - 14.0)
    if actionControlsWidth != 0.0 {
        insets.right += actionControlsWidth - 10.0
    }
    return insets
}

public enum ChatTextInputPanelPasteData {
    case images([UIImage])
    case video(Data)
    case gif(Data)
    case sticker(UIImage, Bool)
    case animatedSticker(Data)
}

final class ChatTextViewForOverlayContent: UIView, ChatInputPanelViewForOverlayContent {
    let ignoreHit: (UIView, CGPoint) -> Bool
    let dismissSuggestions: () -> Void
    
    init(ignoreHit: @escaping (UIView, CGPoint) -> Bool, dismissSuggestions: @escaping () -> Void) {
        self.ignoreHit = ignoreHit
        self.dismissSuggestions = dismissSuggestions
        
        super.init(frame: CGRect())
    }
    
    required init(coder: NSCoder) {
        preconditionFailure()
    }
    
    func maybeDismissContent(point: CGPoint) {
        for subview in self.subviews.reversed() {
            if let _ = subview.hitTest(self.convert(point, to: subview), with: nil) {
                return
            }
        }
        
        self.dismissSuggestions()
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in self.subviews.reversed() {
            if let result = subview.hitTest(self.convert(point, to: subview), with: event) {
                return result
            }
        }
        
        if event == nil || self.ignoreHit(self, point) {
            return nil
        }
        
        self.dismissSuggestions()
        return nil
    }
}

private func makeTextInputTheme(context: AccountContext, interfaceState: ChatPresentationInterfaceState) -> ChatInputTextView.Theme {
    let lineStyle: ChatInputTextView.Theme.Quote.LineStyle
    let authorNameColor: UIColor
    
    if let peer = interfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = peer.info, let nameColor = peer.nameColor {
        let colors = context.peerNameColors.get(nameColor)
        authorNameColor = colors.main
        
        if let secondary = colors.secondary, let tertiary = colors.tertiary {
            lineStyle = .tripleDashed(mainColor: colors.main, secondaryColor: secondary, tertiaryColor: tertiary)
        } else if let secondary = colors.secondary {
            lineStyle = .doubleDashed(mainColor: colors.main, secondaryColor: secondary)
        } else {
            lineStyle = .solid(color: colors.main)
        }
    } else if let accountPeerColor = interfaceState.accountPeerColor {
        authorNameColor = interfaceState.theme.list.itemAccentColor
        
        switch accountPeerColor.style {
        case .solid:
            lineStyle = .solid(color: authorNameColor)
        case .doubleDashed:
            lineStyle = .doubleDashed(mainColor: authorNameColor, secondaryColor: .clear)
        case .tripleDashed:
            lineStyle = .tripleDashed(mainColor: authorNameColor, secondaryColor: .clear, tertiaryColor: .clear)
        }
    } else {
        lineStyle = .solid(color: interfaceState.theme.list.itemAccentColor)
        authorNameColor = interfaceState.theme.list.itemAccentColor
    }
    
    let codeBackgroundColor: UIColor
    if interfaceState.theme.overallDarkAppearance {
        codeBackgroundColor = UIColor(white: 1.0, alpha: 0.05)
    } else {
        codeBackgroundColor = UIColor(white: 0.0, alpha: 0.05)
    }
    
    return ChatInputTextView.Theme(
        quote: ChatInputTextView.Theme.Quote(
            background: authorNameColor.withMultipliedAlpha(interfaceState.theme.overallDarkAppearance ? 0.2 : 0.1),
            foreground: authorNameColor,
            lineStyle: lineStyle,
            codeBackground: codeBackgroundColor,
            codeForeground: authorNameColor
        )
    )
}

public class ChatTextInputPanelNode: ChatInputPanelNode, ASEditableTextNodeDelegate, ChatInputTextNodeDelegate {
    private enum AudioRecordingRemoveAnimationState {
        case recordingToAttachButton
        case previewToAttachButton
    }
    
    public let textPlaceholderNode: ImmediateTextNodeWithEntities
    
    private let glassBackgroundContainer: GlassBackgroundContainerView
    
    public var textLockIconNode: ASImageNode?
    public var contextPlaceholderNode: TextNode?
    public var slowmodePlaceholderNode: ChatTextInputSlowmodePlaceholderNode?
    private let textInputContainerBackgroundView: GlassBackgroundView
    private let accessoryPanelContainer: UIView
    public let textInputNodeClippingContainer: UIView
    public let textInputSeparator: GlassBackgroundView.ContentColorView
    public private(set) var richTextInputNode: ChatRichTextInputNode?
    private var textInputNodeLayout: (frame: CGRect, insets: UIEdgeInsets)?
    
    public let textInputBackgroundNode: ASImageNode
    public var textInputBackgroundTapRecognizer: TouchDownGestureRecognizer?
    public let mediaActionButtons: ChatTextInputActionButtonsNode
    public let sendActionButtons: ChatTextInputActionButtonsNode
    private let slowModeButton: BoostSlowModeButton
    public var mediaRecordingAccessibilityArea: AccessibilityAreaNode?
    private let counterTextNode: ImmediateTextNode
    
    // The AI (compose) button now lives inside the attachment button's glass background (top slot of the
    // capsule), not in the text field. See the 3-line capsule geometry in updateLayout.
    private var attachmentAIButton: (button: HighlightTrackingButton, icon: UIImageView)?
    private struct ThreeLineHeightCacheEntry { let width: CGFloat; let baseFontSize: CGFloat; let value: CGFloat }
    private var threeLineHeightCache: ThreeLineHeightCacheEntry?

    private var expandButton: (button: HighlightTrackingButton, icon: UIImageView)?
    private var heightDependentExpandButtonAlpha: CGFloat = 0.0

    public let menuButton: HighlightTrackingButtonNode
    private let menuButtonBackgroundView: GlassBackgroundView
    private let menuButtonClippingNode: ASDisplayNode
    private let menuButtonIconNode: MenuIconNode
    private let menuButtonTextNode: ImmediateTextNode
    
    private let startButton: SolidRoundedButtonNode
    
    public let sendAsAvatarButtonNode: HighlightableButtonNode
    public let sendAsAvatarReferenceNode: ContextReferenceContentNode
    public let sendAsAvatarContainerNode: ContextControllerSourceNode
    private let sendAsAvatarNode: AvatarNode
    private let sendAsCloseIconView: UIImageView
    
    public let attachmentButton: HighlightTrackingButton
    public let attachmentButtonBackground: GlassBackgroundView
    private let attachmentButtonIcon: UIImageView
    private var commentsButtonIcon: RasterizedCompositionMonochromeLayer?
    private var commentsButtonCenterIcon: UIImageView?
    private var commentsButtonContentsLayer: RasterizedCompositionImageLayer?
    private var commentsButtonDotLayer: RasterizedCompositionImageLayer?
    private var attachmentButtonUnseenIcon: UIImageView?
    public let attachmentButtonDisabledNode: HighlightableButtonNode
    
    public var attachmentImageNode: TransformImageNode?
    
    public let searchLayoutClearButton: HighlightTrackingButton
    private let searchLayoutClearButtonIcon: GlassBackgroundView.ContentImageView
    private var searchActivityIndicator: ActivityIndicator?
    public var audioRecordingInfoContainerNode: ASDisplayNode?
    public var audioRecordingDotView: UIImageView?
    private var audioRecordingRemoveAnimationState: AudioRecordingRemoveAnimationState?
    public var audioRecordingTimeNode: ChatTextInputAudioRecordingTimeNode?
    public var audioRecordingCancelIndicator: ChatTextInputAudioRecordingCancelIndicator?
    
    public var viewOnce = false
    public let viewOnceButton: ChatRecordingViewOnceButtonNode
    public let recordMoreButton: ChatRecordingViewOnceButtonNode
    
    private var accessoryPanel: (component: AnyComponentWithIdentity<ChatInputAccessoryPanelEnvironment>, view: ComponentView<ChatInputAccessoryPanelEnvironment>)?
    public var accessoryPanelView: ChatInputAccessoryPanelView? {
        return self.accessoryPanel?.view.view as? ChatInputAccessoryPanelView
    }
    private var contextPanel: (container: UIView, mask: UIImageView, panel: ChatInputContextPanelNode)?
    private var mediaPreviewPanelNode: ChatRecordingPreviewInputPanelNodeImpl?
    
    private var accessoryItemButtons: [(ChatTextInputAccessoryItem, AccessoryItemIconButton)] = []
    
    private var isUpdating: Bool = false
    private var validLayout: (CGFloat, CGFloat, CGFloat, CGFloat, UIEdgeInsets, CGFloat, CGFloat, LayoutMetrics, Bool, Bool, DeviceMetrics)?
    private var leftMenuInset: CGFloat = 0.0
    private var rightSlowModeInset: CGFloat = 0.0
    private var currentTextInputBackgroundWidthOffset: CGFloat = 0.0
    
    private var enableBounceAnimations: Bool = false
    // Rich-input configuration from the server flag `ios_rich_input_mode` (Double): 0 / absent (default) is the
    // dual-field switch — the composer defaults to the legacy field and latches to native only when content
    // becomes legacy-non-representable; 1 is always-native; 2 is legacy-only. The `useInputDecEngine` experimental
    // flag (Debug Settings ▸ "Input V3") forces always-native regardless of `ios_rich_input_mode`.
    // `enableRichTextInput` = native is permitted at all (false only in legacy-only mode);
    // `alwaysUseNativeInput` = native from the start (mode 1 or `useInputDecEngine`). See `desiredUseNative(for:)`.
    private var enableRichTextInput: Bool = false
    private var alwaysUseNativeInput: Bool = false
    // Which input backend a NATIVE composer is built for — orthogonal to the two flags above, which
    // decide WHETHER the native composer is used at all. Production stays `.legacy`; Debug Settings ▸
    // "Text Field v2: InputDec backend" (`inputDecTextBackend`) selects `.inputDecIfSupported`, which
    // itself falls back to legacy on a runtime the InputDec backend cannot drive.
    private var richTextInputBackendPreference: RichTextEditorInputBackendPreference = .legacy
    /// Debug Settings ▸ "Input V3". Selects the engine-backed editor
    /// rather than a backend of the legacy one — a different type, read once at panel setup.
    private var useInputDecEngineEditor: Bool = false
    
    public var displayAttachmentMenu: () -> Void = { }
    public var sendMessage: () -> Void = { }
    public var paste: (ChatTextInputPanelPasteData) -> Void = { _ in }
    public var updateHeight: (Bool) -> Void = { _ in }
    public var toggleExpandMediaInput: (() -> Void)?
    public var switchToTextInputIfNeeded: (() -> Void)?
    /// Parses pasted plain text as markdown into a `ChatInputContent`, or nil when the text should paste
    /// as-is. Injected by the panel's owner (only the monolith can reach the BrowserUI-backed parser).
    /// Takes the context explicitly so the panel does not have to capture it.
    public var pastedMarkdownParser: ((AccountContext, String) -> ChatInputContent?)?
    public var textInputAccessoryPanel: ((_ context: AccountContext, _ chatPresentationInterfaceState: ChatPresentationInterfaceState, _ chatControllerInteraction: ChatControllerInteraction?, _ interfaceInteraction: ChatPanelInterfaceInteraction?) -> AnyComponentWithIdentity<ChatInputAccessoryPanelEnvironment>?)?
    public var textInputContextPanel: ((_ context: AccountContext, _ chatPresentationInterfaceState: ChatPresentationInterfaceState, _ chatControllerInteraction: ChatControllerInteraction?, _ interfaceInteraction: ChatPanelInterfaceInteraction?, _ current: ChatInputContextPanelNode?) -> ChatInputContextPanelNode?)?
    
    public var updateActivity: () -> Void = { }
    
    private var updatingInputState = false
    
    private var currentPlaceholder: String?
    private var sendingTextDisabled: Bool = false
    
    private var presentationInterfaceState: ChatPresentationInterfaceState?
    private var initializedPlaceholder = false
    
    private var keepSendButtonEnabled = false
    private var extendedSearchLayout = false
    
    public var isMediaDeleted: Bool = false
    private var recordingPaused = false
    
    private let inputMenu: TextInputMenu
    
    private var theme: PresentationTheme?
    private var strings: PresentationStrings?
    
    private let hapticFeedback = HapticFeedback()
    
    public var isAIEnabled: Bool = false
    
    public var inputTextState: ChatTextInputState {
        if let richTextInputNode = self.richTextInputNode {
            let selectionRange: Range<Int> = richTextInputNode.selectedRange.location ..< (richTextInputNode.selectedRange.location + richTextInputNode.selectedRange.length)
            // The GET read-back passes the node's `ChatInputContent` DIRECTLY into the state (no `NSAttributedString`
            // round-trip): structural blocks (`.media`/`.table`/heading/list) only the native engine produces would
            // otherwise be flattened away by `attributedString(from:)`. For the legacy node the content is always flat,
            // so this is identical to the former `attributedString(from:)` round-trip (the conversion is round-trip
            // identity for flat content); `ChatTextInputState.==` is value-based so the freshly-built content doesn't
            // churn change-detection. This is the "no NSAttributedString storage in the pipeline" boundary.
            return ChatTextInputState(content: richTextInputNode.currentInputContent().content, selectionRange: selectionRange)
        } else {
            return ChatTextInputState()
        }
    }
    
    public var storedInputLanguage: String?
    public var effectiveInputLanguage: String? {
        if let richTextInputNode = self.richTextInputNode, richTextInputNode.isInputFirstResponder {
            return richTextInputNode.primaryLanguage
        } else {
            return self.storedInputLanguage
        }
    }
    
    public var enablePredictiveInput: Bool = true {
        didSet {
            if let richTextInputNode = self.richTextInputNode {
                richTextInputNode.autocorrectionType = self.enablePredictiveInput ? .default : .no
            }
        }
    }
    
    public var ignoreInputStateUpdates: Bool = false
    private var ignoreChatInputTextNodeDidUpdateText: Bool = false
    
    override public var context: AccountContext? {
        didSet {
            self.sendActionButtons.micButton.statusBarHost = self.context?.sharedContext.mainWindow?.statusBarHost
            self.mediaActionButtons.micButton.statusBarHost = self.context?.sharedContext.mainWindow?.statusBarHost
        }
    }

    public var micButton: ChatTextInputMediaRecordingButton? {
        return self.mediaActionButtons.micButton
    }
    
    private let statusDisposable = MetaDisposable()
    override public var interfaceInteraction: ChatPanelInterfaceInteraction? {
        didSet {
            if let statuses = self.interfaceInteraction?.statuses {
                self.statusDisposable.set((statuses.inlineSearch
                |> distinctUntilChanged
                |> deliverOnMainQueue).startStrict(next: { [weak self] value in
                    self?.updateIsProcessingInlineRequest(value)
                }).strict())
            }
        }
    }
    
    public enum LeftAction {
        case empty
        case toggleExpanded(isVisible: Bool, isExpanded: Bool, hasUnseen: Bool)
        case settings(isVisible: Bool, action: (UIView) -> Void)
    }
    
    public enum RightAction {
        case empty
        case stars(count: Int, isFilled: Bool, action: (UIView) -> Void, longPressAction: ((UIView) -> Void)?)
        case liveMicrophone(call: AnyObject?, action: (UIView) -> Void)
    }
    
    public var customPlaceholder: String?
    public var customIsDisabled: Bool = false
    public var customLeftAction: LeftAction?
    public var customSecondaryLeftAction: LeftAction?
    public var customRightAction: RightAction?
    public var customSecondaryRightAction: RightAction?
    public var customSendColor: UIColor?
    public var customSendIsDisabled: Bool = false
    public var customInputTextMaxLength: Int?
    public var customSwitchToKeyboard: (() -> Void)?
    public var allowConsecutiveNewlines = true
    
    private var starReactionButton: ComponentView<Empty>?
    private var liveMicrophoneButton: ComponentView<Empty>?
    private var settingsButton: ComponentView<Empty>?
    
    public func insertText(text: NSAttributedString) {
        guard let textInputState = self.presentationInterfaceState?.interfaceState.effectiveInputState else {
            return
        }
        
        let range = textInputState.selectionRange

        // The quote (`.block`) attribute used to be copied from the character at the range start onto the
        // replacement so inserted text inherited the quote. `replacingFlatRange` splices into the quote's
        // own content, so that is now automatic — see
        // `ChatInputContentInsertIntoQuoteTests.test_insertingInsideAQuote_staysQuotedWithoutAnyAttributeCopying`.
        let updatedState = textInputState.replacingFlatRange(
            NSRange(location: range.lowerBound, length: range.count),
            with: text
        )
        let content = updatedState.content
        // An inserted fragment can be legacy-non-representable (e.g. a collapsed quote). Convert the field to the
        // native backend BEFORE handing it the content: the legacy node lossily filters inside `setInputContent`,
        // and the `chatInputTextNodeDidUpdateText` echo below reads the content back from the (legacy) node, so a
        // later round-trip conversion would arrive after the structure was already dropped. Gated on an existing
        // node to preserve the prior no-op-when-unloaded behavior.
        if self.richTextInputNode != nil {
            self.ensureInputNodeKind(for: content)
        }

        if let richTextInputNode = self.richTextInputNode, let context = self.context {
            var textColor: UIColor = .black
            var primaryTextColor: UIColor = .black
            var accentTextColor: UIColor = .blue
            var baseFontSize: CGFloat = 17.0

            if let presentationInterfaceState = self.presentationInterfaceState {
                textColor = presentationInterfaceState.theme.chat.inputPanel.inputTextColor
                primaryTextColor = presentationInterfaceState.theme.chat.inputPanel.primaryTextColor
                accentTextColor = presentationInterfaceState.theme.chat.inputPanel.panelControlAccentColor
                baseFontSize = chatTextInputBaseFontSize(for: presentationInterfaceState.fontSize)
            }

            let selection = ChatInputSelection(nsRange: NSMakeRange(updatedState.selectionRange.lowerBound, updatedState.selectionRange.count), in: content)
            if !richTextInputNode.usesNativeRichTextEngine {
                richTextInputNode.applyRenderingConfig(context: context, baseFontSize: baseFontSize, textColor: textColor, primaryTextColor: primaryTextColor, accentTextColor: accentTextColor, spoilersRevealed: richTextInputNode.spoilersRevealed, availableEmojis: Set(context.animatedEmojiStickersValue.keys), emojiViewProvider: self.emojiViewProvider)
            }
            richTextInputNode.setInputContent(content, selection: selection)
            self.chatInputTextNodeDidUpdateText()
        }
    }
            
    public func updateInputTextState(_ state: ChatTextInputState, keepSendButtonEnabled: Bool, extendedSearchLayout: Bool, accessoryItems: [ChatTextInputAccessoryItem], animated: Bool) {
        if self.ignoreInputStateUpdates {
            return
        }
        
        self.ignoreChatInputTextNodeDidUpdateText = true
        defer {
            self.ignoreChatInputTextNodeDidUpdateText = false
        }
        
        if let currentState = self.presentationInterfaceState {
            var updateAccessoryButtons = false
            if accessoryItems.count == self.accessoryItemButtons.count {
                for i in 0 ..< accessoryItems.count {
                    if accessoryItems[i] != self.accessoryItemButtons[i].0 {
                        updateAccessoryButtons = true
                        break
                    }
                }
            } else {
                updateAccessoryButtons = true
            }
            
            if updateAccessoryButtons {
                var updatedButtons: [(ChatTextInputAccessoryItem, AccessoryItemIconButton)] = []
                for item in accessoryItems {
                    var itemAndButton: (ChatTextInputAccessoryItem, AccessoryItemIconButton)?
                    for i in 0 ..< self.accessoryItemButtons.count {
                        if self.accessoryItemButtons[i].0.key == item.key {
                            itemAndButton = self.accessoryItemButtons[i]
                            itemAndButton?.0 = item
                            self.accessoryItemButtons.remove(at: i)
                            break
                        }
                    }
                    if itemAndButton == nil {
                        let button = AccessoryItemIconButton(item: item, theme: currentState.theme, strings: currentState.strings)
                        button.addTarget(self, action: #selector(self.accessoryItemButtonPressed(_:)), for: .touchUpInside)
                        itemAndButton = (item, button)
                    }
                    updatedButtons.append(itemAndButton!)
                }
                for (_, button) in self.accessoryItemButtons {
                    button.removeFromSuperview()
                }
                self.accessoryItemButtons = updatedButtons
            }
        }
        
        if !state.isEmpty {
            self.ensureInputNodeKind(for: state.content)
        }
        
        if let richTextInputNode = self.richTextInputNode, let _ = self.presentationInterfaceState, let context = self.context {
            self.updatingInputState = true

            var textColor: UIColor = .black
            var primaryTextColor: UIColor = .black
            var accentTextColor: UIColor = .blue
            var baseFontSize: CGFloat = 17.0
            if let presentationInterfaceState = self.presentationInterfaceState {
                textColor = presentationInterfaceState.theme.chat.inputPanel.inputTextColor
                primaryTextColor = presentationInterfaceState.theme.chat.inputPanel.primaryTextColor
                accentTextColor = presentationInterfaceState.theme.chat.inputPanel.panelControlAccentColor
                baseFontSize = chatTextInputBaseFontSize(for: presentationInterfaceState.fontSize)
            }
            if richTextInputNode.usesNativeRichTextEngine {
                // Pass the model content DIRECTLY (not via `state.inputText`, which flattens structural blocks through
                // `NSAttributedString`) — see `inputTextState`. Flat for the legacy node, lossless for native.
                let content = state.content
                richTextInputNode.setInputContent(
                    content,
                    selection: ChatInputSelection(nsRange: NSMakeRange(state.selectionRange.lowerBound, state.selectionRange.count), in: content)
                )
            } else {
                richTextInputNode.applyRenderingConfig(context: context, baseFontSize: baseFontSize, textColor: textColor, primaryTextColor: primaryTextColor, accentTextColor: accentTextColor, spoilersRevealed: richTextInputNode.spoilersRevealed, availableEmojis: (self.context?.animatedEmojiStickersValue.keys).flatMap(Set.init) ?? Set(), emojiViewProvider: self.emojiViewProvider)
                // The node runs the in-place fix-up (`refreshTextInputAttributes`) inside `setInputContent` now,
                // using the config supplied by `applyRenderingConfig` above — so the panel no longer drives it.
                // Pass the model content DIRECTLY (not via `state.inputText`, which flattens structural blocks through
                // `NSAttributedString`) — see `inputTextState`. Flat for the legacy node, lossless for native.
                let content = state.content
                richTextInputNode.setInputContent(
                    content,
                    selection: ChatInputSelection(nsRange: NSMakeRange(state.selectionRange.lowerBound, state.selectionRange.count), in: content)
                )
            }

            self.updatingInputState = false
            self.keepSendButtonEnabled = keepSendButtonEnabled
            self.extendedSearchLayout = extendedSearchLayout
            self.updateTextNodeText(animated: animated)
            self.updateSpoiler()
        }
    }
    
    public func updateInputTextState(_ state: ChatTextInputState) {
        if self.ignoreInputStateUpdates {
            return
        }
        if !state.isEmpty {
            self.ensureInputNodeKind(for: state.content)
        }
        
        if let richTextInputNode = self.richTextInputNode, let _ = self.presentationInterfaceState, let context = self.context {
            self.updatingInputState = true

            var textColor: UIColor = .black
            var primaryTextColor: UIColor = .black
            var accentTextColor: UIColor = .blue
            var baseFontSize: CGFloat = 17.0
            if let presentationInterfaceState = self.presentationInterfaceState {
                textColor = presentationInterfaceState.theme.chat.inputPanel.inputTextColor
                primaryTextColor = presentationInterfaceState.theme.chat.inputPanel.primaryTextColor
                accentTextColor = presentationInterfaceState.theme.chat.inputPanel.panelControlAccentColor
                baseFontSize = chatTextInputBaseFontSize(for: presentationInterfaceState.fontSize)
            }
            if richTextInputNode.usesNativeRichTextEngine {
                // Pass the model content DIRECTLY (not via `state.inputText`, which flattens structural blocks through
                // `NSAttributedString`) — see `inputTextState`. Flat for the legacy node, lossless for native.
                let content = state.content
                richTextInputNode.setInputContent(
                    content,
                    selection: ChatInputSelection(nsRange: NSMakeRange(state.selectionRange.lowerBound, state.selectionRange.count), in: content)
                )
            } else {
                richTextInputNode.applyRenderingConfig(context: context, baseFontSize: baseFontSize, textColor: textColor, primaryTextColor: primaryTextColor, accentTextColor: accentTextColor, spoilersRevealed: richTextInputNode.spoilersRevealed, availableEmojis: (self.context?.animatedEmojiStickersValue.keys).flatMap(Set.init) ?? Set(), emojiViewProvider: self.emojiViewProvider)
                // The node runs the in-place fix-up (`refreshTextInputAttributes`) inside `setInputContent` now,
                // using the config supplied by `applyRenderingConfig` above — so the panel no longer drives it.
                // Pass the model content DIRECTLY (not via `state.inputText`, which flattens structural blocks through
                // `NSAttributedString`) — see `inputTextState`. Flat for the legacy node, lossless for native.
                let content = state.content
                richTextInputNode.setInputContent(
                    content,
                    selection: ChatInputSelection(nsRange: NSMakeRange(state.selectionRange.lowerBound, state.selectionRange.count), in: content)
                )
            }

            self.updatingInputState = false
            self.updateTextNodeText(animated: false)
            self.updateSpoiler()
        }
    }
    
    public func updateKeepSendButtonEnabled(keepSendButtonEnabled: Bool, extendedSearchLayout: Bool, animated: Bool) {
        if keepSendButtonEnabled != self.keepSendButtonEnabled || extendedSearchLayout != self.extendedSearchLayout {
            self.keepSendButtonEnabled = keepSendButtonEnabled
            self.extendedSearchLayout = extendedSearchLayout
            self.updateTextNodeText(animated: animated)
        }
    }
    
    public var text: String {
        get {
            return self.richTextInputNode?.attributedText?.string ?? ""
        } set(value) {
            if let richTextInputNode = self.richTextInputNode {
                var textColor: UIColor = .black
                var primaryTextColor: UIColor = .black
                var accentTextColor: UIColor = .blue
                var baseFontSize: CGFloat = 17.0
                if let presentationInterfaceState = self.presentationInterfaceState {
                    textColor = presentationInterfaceState.theme.chat.inputPanel.inputTextColor
                    primaryTextColor = presentationInterfaceState.theme.chat.inputPanel.primaryTextColor
                    accentTextColor = presentationInterfaceState.theme.chat.inputPanel.panelControlAccentColor
                    baseFontSize = chatTextInputBaseFontSize(for: presentationInterfaceState.fontSize)
                }
                // Route the plain-text set through the model so the node owns decoration (no baked font/color here).
                if let context = self.context {
                    richTextInputNode.applyRenderingConfig(context: context, baseFontSize: baseFontSize, textColor: textColor, primaryTextColor: primaryTextColor, accentTextColor: accentTextColor, spoilersRevealed: richTextInputNode.spoilersRevealed, availableEmojis: (self.context?.animatedEmojiStickersValue.keys).flatMap(Set.init) ?? Set(), emojiViewProvider: self.emojiViewProvider)
                }
                let content = chatInputContent(from: NSAttributedString(string: value))
                richTextInputNode.setInputContent(content, selection: ChatInputSelection(nsRange: NSMakeRange((value as NSString).length, 0), in: content))
                self.chatInputTextNodeDidUpdateText()
            }
        }
    }
    
    private let textInputViewInternalInsets: UIEdgeInsets
    private let accessoryButtonSpacing: CGFloat = 0.0
    private let accessoryButtonInset: CGFloat = 4.0

    private var animatingTransition = false
    
    private var touchDownGestureRecognizer: TouchDownGestureRecognizer?
    
    public var emojiViewProvider: ((ChatTextInputTextCustomEmojiAttribute) -> UIView)?

    public var mediaItemViewFactory: ((_ items: [(media: EngineMedia, naturalSize: CGSize, isSpoiler: Bool, kind: MediaKind)], _ existing: (UIView & RichTextMediaItemView)?) -> (UIView & RichTextMediaItemView)?)? {
        didSet { self.richTextInputNode?.mediaItemViewFactory = self.mediaItemViewFactory }
    }

    public var formulaRenderer: ((RichTextFormulaRenderContext) -> RichTextFormulaRenderResult?)? {
        didSet { self.richTextInputNode?.formulaRenderer = self.formulaRenderer }
    }

    private let presentationContext: ChatPresentationContext?
    
    private var tooltipController: TooltipScreen?
    
    public init(context: AccountContext, presentationInterfaceState: ChatPresentationInterfaceState, presentationContext: ChatPresentationContext?, presentController: @escaping (ViewController) -> Void) {
        self.presentationInterfaceState = presentationInterfaceState
        self.presentationContext = presentationContext
        
        self.textInputViewInternalInsets = UIEdgeInsets(top: 5.0, left: 12.0, bottom: 4.0, right: 11.0)

        var hasSpoilers = true
        var hasQuotes = true
        if presentationInterfaceState.chatLocation.peerId?.namespace == Namespaces.Peer.SecretChat {
            hasSpoilers = false
            hasQuotes = false
        }
        self.inputMenu = TextInputMenu(hasSpoilers: hasSpoilers, hasQuotes: hasQuotes)
        
        self.glassBackgroundContainer = GlassBackgroundContainerView()
        
        self.textInputContainerBackgroundView = GlassBackgroundView(frame: CGRect())
        
        self.accessoryPanelContainer = UIView()
        self.accessoryPanelContainer.clipsToBounds = true
        
        self.textInputNodeClippingContainer = UIView()
        self.textInputNodeClippingContainer.clipsToBounds = true
        self.textInputNodeClippingContainer.layer.name = "textInputNodeClippingContainer"
        
        self.textInputSeparator = GlassBackgroundView.ContentColorView()
        //self.textInputContainerBackgroundView.contentView.addSubview(self.textInputSeparator)
        
        self.textInputBackgroundNode = ASImageNode()
        self.textInputBackgroundNode.displaysAsynchronously = false
        self.textInputBackgroundNode.displayWithoutProcessing = true
        
        self.textPlaceholderNode = ImmediateTextNodeWithEntities()
        self.textPlaceholderNode.arguments = TextNodeWithEntities.Arguments(
            context: context,
            cache: context.animationCache,
            renderer: context.animationRenderer,
            placeholderColor: .clear,
            attemptSynchronous: true
        )
        self.textPlaceholderNode.contentMode = .topLeft
        self.textPlaceholderNode.contentsScale = UIScreenScale
        self.textPlaceholderNode.maximumNumberOfLines = 1
        self.textPlaceholderNode.isUserInteractionEnabled = false

        self.menuButton = HighlightTrackingButtonNode()
        self.menuButton.clipsToBounds = true
        self.menuButton.cornerRadius = 16.0
        self.menuButton.accessibilityLabel = presentationInterfaceState.strings.Conversation_InputMenu
        self.menuButtonBackgroundView = GlassBackgroundView()
        self.menuButtonBackgroundView.isUserInteractionEnabled = false
        self.menuButtonClippingNode = ASDisplayNode()
        self.menuButtonClippingNode.clipsToBounds = true
        self.menuButtonClippingNode.isUserInteractionEnabled = false
        
        self.menuButtonIconNode = MenuIconNode(lottieSettings: context.lottieRenderingSettings)
        self.menuButtonIconNode.isUserInteractionEnabled = false
        self.menuButtonIconNode.customColor = presentationInterfaceState.theme.chat.inputPanel.actionControlForegroundColor
        self.menuButtonTextNode = ImmediateTextNode()
        
        self.startButton = SolidRoundedButtonNode(title: presentationInterfaceState.strings.Bot_Start, theme: SolidRoundedButtonTheme(theme: presentationInterfaceState.theme), glass: true, glassInset: true, height: 50.0, cornerRadius: 50.0 * 0.5, isShimmering: true)
        self.startButton.progressType = .embedded
        self.startButton.isHidden = true
        
        self.sendAsAvatarButtonNode = HighlightableButtonNode()
        self.sendAsAvatarReferenceNode = ContextReferenceContentNode()
        self.sendAsAvatarContainerNode = ContextControllerSourceNode()
        self.sendAsAvatarContainerNode.animateScale = false
        self.sendAsAvatarNode = AvatarNode(font: avatarPlaceholderFont(size: 16.0))
        self.sendAsCloseIconView = UIImageView()
        
        self.attachmentButton = HighlightTrackingButton()
        self.attachmentButton.accessibilityLabel = presentationInterfaceState.strings.VoiceOver_AttachMedia
        self.attachmentButton.accessibilityTraits = [.button]
        self.attachmentButton.isAccessibilityElement = true
        
        self.attachmentButtonBackground = GlassBackgroundView(frame: CGRect())
        self.attachmentButtonBackground.contentView.addSubview(self.attachmentButton)
        
        self.attachmentButtonIcon = UIImageView()
        self.attachmentButtonIcon.isUserInteractionEnabled = false
        self.attachmentButtonIcon.contentMode = .center
        self.attachmentButtonBackground.contentView.addSubview(self.attachmentButtonIcon)
        
        self.attachmentButtonDisabledNode = HighlightableButtonNode()
        self.searchLayoutClearButton = HighlightTrackingButton()
        self.searchLayoutClearButtonIcon = GlassBackgroundView.ContentImageView()
        
        self.sendActionButtons = ChatTextInputActionButtonsNode(context: context, presentationInterfaceState: presentationInterfaceState, presentationContext: presentationContext, presentController: presentController)
        self.sendActionButtons.micButtonBackgroundView.alpha = 0.0
        self.sendActionButtons.micButton.alpha = 0.0
        self.sendActionButtons.micButtonTintMaskView.alpha = 0.0
        self.sendActionButtons.expandMediaInputButtonBackgroundView.alpha = 0.0
        self.sendActionButtons.stopButtonIcon.alpha = 0.0
        
        self.mediaActionButtons = ChatTextInputActionButtonsNode(context: context, presentationInterfaceState: presentationInterfaceState, presentationContext: presentationContext, presentController: presentController)
        self.mediaActionButtons.sendContainerNode.alpha = 0.0
        
        self.counterTextNode = ImmediateTextNode()
        self.counterTextNode.textAlignment = .center
        
        self.slowModeButton = BoostSlowModeButton()
        self.slowModeButton.alpha = 0.0
        
        self.viewOnceButton = ChatRecordingViewOnceButtonNode(icon: .viewOnce)
        self.recordMoreButton = ChatRecordingViewOnceButtonNode(icon: .recordMore)
        
        super.init()
        
        self.view.addSubview(self.glassBackgroundContainer)
        
        self.slowModeButton.requestUpdate = { [weak self] in
            self?.requestLayout(transition: .animated(duration: 0.2, curve: .easeInOut))
        }
        self.slowModeButton.addTarget(self, action: #selector(self.slowModeButtonPressed), forControlEvents: .touchUpInside)
        
        self.viewForOverlayContent = ChatTextViewForOverlayContent(
            ignoreHit: { [weak self] view, point in
                guard let strongSelf = self else {
                    return false
                }
                if strongSelf.view.hitTest(view.convert(point, to: strongSelf.view), with: nil) != nil {
                    return true
                }
                if view.convert(point, to: strongSelf.view).y > strongSelf.view.bounds.maxY {
                    return true
                }
                return false
            },
            dismissSuggestions: { [weak self] in
                guard let strongSelf = self, let currentEmojiSuggestion = strongSelf.currentEmojiSuggestion, let richTextInputNode = strongSelf.richTextInputNode else {
                    return
                }

                strongSelf.dismissedEmojiSuggestionPosition = currentEmojiSuggestion.position
                strongSelf.updateInputField(textInputFrame: richTextInputNode.textFieldFrame, transition: .immediate)
            }
        )
        
        self.context = context
        
        /*self.enableBounceAnimations = true
        if let data = context.currentAppConfiguration.with({ $0 }).data, data["ios_killswitch_input_bounce"] != nil {
            self.enableBounceAnimations = false
        }*/
        
        // `ios_rich_input_mode` (Double): 0 / absent = dual-field switch (legacy default, latch to native on
        // non-representable content); 1 = always native; 2 = legacy only. The `useInputDecEngine` experimental
        // flag, below, forces always-native (enableRichTextInput + alwaysUseNativeInput) with the engine editor.
        self.enableRichTextInput = true
        self.alwaysUseNativeInput = false
        if let data = self.context?.currentAppConfiguration.with({ $0 }).data, let mode = data["ios_rich_input_mode"] as? Double {
            if mode == 1.0 {
                self.alwaysUseNativeInput = true
            } else if mode == 2.0 {
                self.enableRichTextInput = false
            }
        }
        if context.sharedContext.immediateExperimentalUISettings.inputDecTextBackend {
            self.richTextInputBackendPreference = .inputDecIfSupported
        }
        // Below iOS 18.4 the engine editor cannot be built (`RichTextEditorChatInputNode` checks the
        // same availability), so the flag must change nothing there — not even force the composer
        // native, which is what setting the two flags below without the check did.
        if context.sharedContext.immediateExperimentalUISettings.useInputDecEngine, #available(iOS 18.4, *) {
            // Rich input must be on for the composer to build a rich node at all; the engine editor
            // is a choice WITHIN that, not an alternative to it.
            self.enableRichTextInput = true
            self.alwaysUseNativeInput = true
            self.useInputDecEngineEditor = true
        }
        
        self.sendAsAvatarContainerNode.activated = { [weak self] gesture, _ in
            guard let strongSelf = self else {
                return
            }
            strongSelf.interfaceInteraction?.openSendAsPeer(strongSelf.sendAsAvatarReferenceNode, gesture)
        }
        
        self.sendAsAvatarButtonNode.addTarget(self, action: #selector(self.sendAsAvatarButtonPressed), forControlEvents: .touchUpInside)
        self.sendAsAvatarButtonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .spring)
                    transition.updateTransformScale(node: strongSelf.sendAsAvatarButtonNode, scale: 0.85)
                } else {
                    let transition: ContainedViewLayoutTransition = .animated(duration: 0.5, curve: .spring)
                    transition.updateTransformScale(node: strongSelf.sendAsAvatarButtonNode, scale: 1.0)
                }
            }
        }
        
        self.menuButton.addTarget(self, action: #selector(self.menuButtonPressed), forControlEvents: .touchUpInside)
        self.menuButton.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .spring)
                    transition.updateTransformScale(node: strongSelf.menuButton, scale: 0.85)
                } else {
                    let transition: ContainedViewLayoutTransition = .animated(duration: 0.5, curve: .spring)
                    transition.updateTransformScale(node: strongSelf.menuButton, scale: 1.0)
                }
            }
        }
        
        self.startButton.pressed = { [weak self] in
            guard let self, let presentationInterfaceState = self.presentationInterfaceState else {
                return
            }
            if presentationInterfaceState.peerIsBlocked {
                self.interfaceInteraction?.unblockPeer()
            } else {
                self.interfaceInteraction?.sendBotStart(presentationInterfaceState.botStartPayload)
            }
            
            if let tooltipController = self.tooltipController {
                self.tooltipController = nil
                tooltipController.dismiss()
            }
        }
        
        self.attachmentButton.addTarget(self, action: #selector(self.attachmentButtonPressed), for: .touchUpInside)
        self.attachmentButton.highligthedChanged = { [weak self] highlighted in
            if let self {
                if highlighted {
                    self.attachmentButtonIcon.layer.removeAnimation(forKey: "opacity")
                    self.attachmentButtonIcon.alpha = 0.4
                } else {
                    self.attachmentButtonIcon.alpha = 1.0
                    self.attachmentButtonIcon.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        self.attachmentButtonDisabledNode.addTarget(self, action: #selector(self.attachmentButtonPressed), forControlEvents: .touchUpInside)
  
        self.sendActionButtons.sendButtonLongPressed = { [weak self] node, gesture in
            self?.interfaceInteraction?.displaySendMessageOptions(node, gesture)
        }
        
        self.mediaActionButtons.micButton.recordingDisabled = { [weak self] in
            if let strongSelf = self {
                if strongSelf.presentationInterfaceState?.voiceMessagesAvailable == false {
                    self?.interfaceInteraction?.displayRestrictedInfo(.premiumVoiceMessages, .tooltip)
                } else {
                    self?.interfaceInteraction?.displayRestrictedInfo(.mediaRecording, .tooltip)
                }
            }
        }
        
        self.mediaActionButtons.micButton.beginRecording = { [weak self] in
            if let strongSelf = self, let presentationInterfaceState = strongSelf.presentationInterfaceState, let interfaceInteraction = strongSelf.interfaceInteraction {
                let isVideo: Bool
                switch presentationInterfaceState.interfaceState.mediaRecordingMode {
                    case .audio:
                        isVideo = false
                    case .video:
                        isVideo = true
                }
                interfaceInteraction.beginMediaRecording(isVideo)
            }
        }
        self.mediaActionButtons.micButton.endRecording = { [weak self] sendMedia in
            if let strongSelf = self, let interfaceState = strongSelf.presentationInterfaceState, let interfaceInteraction = strongSelf.interfaceInteraction {
                if let _ = interfaceState.inputTextPanelState.mediaRecordingState {
                    if sendMedia {
                        interfaceInteraction.finishMediaRecording(.send(viewOnce: strongSelf.viewOnce))
                    } else {
                        strongSelf.audioRecordingRemoveAnimationState = .recordingToAttachButton
                        interfaceInteraction.finishMediaRecording(.dismiss)
                    }
                } else {
//                    interfaceInteraction.finishMediaRecording(.dismiss)
                }
                strongSelf.viewOnce = false
                strongSelf.tooltipController?.dismiss()
            }
        }
        self.mediaActionButtons.micButton.offsetRecordingControls = { [weak self] in
            if let strongSelf = self, let presentationInterfaceState = strongSelf.presentationInterfaceState {
                if let (width, leftInset, rightInset, bottomInset, additionalSideInsets, maxHeight, maxOverlayHeight, metrics, isSecondary, isMediaInputExpanded, deviceMetrics) = strongSelf.validLayout {
                    let _ = strongSelf.updateLayout(width: width, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, additionalSideInsets: additionalSideInsets, maxHeight: maxHeight, maxOverlayHeight: maxOverlayHeight, isSecondary: isSecondary, transition: .immediate, interfaceState: presentationInterfaceState, metrics: metrics, deviceMetrics: deviceMetrics, isMediaInputExpanded: isMediaInputExpanded)
                }
            }
        }
        self.mediaActionButtons.micButton.updateCancelTranslation = { [weak self] in
            if let strongSelf = self, let presentationInterfaceState = strongSelf.presentationInterfaceState {
                if let (width, leftInset, rightInset, bottomInset, additionalSideInsets, maxHeight, maxOverlayHeight, metrics, isSecondary, isMediaInputExpanded, deviceMetrics) = strongSelf.validLayout {
                    let _ = strongSelf.updateLayout(width: width, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, additionalSideInsets: additionalSideInsets, maxHeight: maxHeight, maxOverlayHeight: maxOverlayHeight, isSecondary: isSecondary, transition: .immediate, interfaceState: presentationInterfaceState, metrics: metrics, deviceMetrics: deviceMetrics, isMediaInputExpanded: isMediaInputExpanded)
                }
            }
        }
        self.mediaActionButtons.micButton.stopRecording = { [weak self] in
            if let strongSelf = self, let interfaceInteraction = strongSelf.interfaceInteraction {
                interfaceInteraction.stopMediaRecording()
                
                strongSelf.tooltipController?.dismiss()
            }
        }
        self.mediaActionButtons.micButton.updateLocked = { [weak self] _ in
            if let strongSelf = self, let interfaceInteraction = strongSelf.interfaceInteraction {
                interfaceInteraction.lockMediaRecording()
            }
        }
        self.mediaActionButtons.micButton.switchMode = { [weak self] in
            if let strongSelf = self, let interfaceInteraction = strongSelf.interfaceInteraction {
                interfaceInteraction.switchMediaRecordingMode()
            }
        }
        
        self.sendActionButtons.sendButton.addTarget(self, action: #selector(self.sendButtonPressed), forControlEvents: .touchUpInside)
        self.sendActionButtons.sendContainerNode.alpha = 0.0
        self.sendActionButtons.updateAccessibility()
        self.mediaActionButtons.updateAccessibility()
        
        self.mediaActionButtons.expandMediaInputButton.addTarget(self, action: #selector(self.expandButtonPressed), for: .touchUpInside)
        self.mediaActionButtons.stopButton.addTarget(self, action: #selector(self.stopButtonPressed), for: .touchUpInside)
        self.mediaActionButtons.expandMediaInputButtonBackgroundView.alpha = 0.0
        
        self.searchLayoutClearButton.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            if highlighted {
                self.searchLayoutClearButtonIcon.alpha = 0.6
            } else {
                self.searchLayoutClearButtonIcon.alpha = 1.0
                let transition: ContainedViewLayoutTransition = .animated(duration: 0.2, curve: .easeInOut)
                transition.updateAlpha(layer: self.searchLayoutClearButtonIcon.layer, alpha: 1.0)
            }
        }
        self.searchLayoutClearButton.addTarget(self, action: #selector(self.searchLayoutClearButtonPressed), for: .touchUpInside)
        self.searchLayoutClearButton.alpha = 0.0
        self.searchLayoutClearButtonIcon.alpha = 0.0
        
        self.glassBackgroundContainer.contentView.addSubview(self.textInputBackgroundNode.view)
        
        self.glassBackgroundContainer.contentView.addSubview(self.textInputContainerBackgroundView)
        
        self.textInputContainerBackgroundView.contentView.addSubview(self.accessoryPanelContainer)
        self.textInputContainerBackgroundView.contentView.addSubview(self.textPlaceholderNode.view)
        self.textInputContainerBackgroundView.contentView.addSubview(self.textInputNodeClippingContainer)
        
        self.menuButton.view.addSubview(self.menuButtonBackgroundView)
        self.menuButton.addSubnode(self.menuButtonClippingNode)
        self.menuButtonClippingNode.addSubnode(self.menuButtonTextNode)
        self.menuButton.addSubnode(self.menuButtonIconNode)
        
        self.sendAsAvatarContainerNode.addSubnode(self.sendAsAvatarReferenceNode)
        self.sendAsAvatarReferenceNode.addSubnode(self.sendAsAvatarNode)
        self.sendAsAvatarReferenceNode.view.addSubview(self.sendAsCloseIconView)
        self.sendAsAvatarButtonNode.addSubnode(self.sendAsAvatarContainerNode)
        self.textInputContainerBackgroundView.contentView.addSubview(self.sendAsAvatarButtonNode.view)
        
        self.glassBackgroundContainer.contentView.addSubview(self.menuButton.view)
        self.glassBackgroundContainer.contentView.addSubview(self.attachmentButtonBackground)
        self.glassBackgroundContainer.contentView.addSubview(self.attachmentButtonDisabledNode.view)
        
        self.glassBackgroundContainer.contentView.addSubview(self.startButton.view)
          
        self.glassBackgroundContainer.contentView.addSubview(self.sendActionButtons.view)
        self.glassBackgroundContainer.contentView.addSubview(self.mediaActionButtons.view)
        self.textInputContainerBackgroundView.contentView.addSubview(self.counterTextNode.view)
        
        self.glassBackgroundContainer.contentView.addSubview(self.slowModeButton.view)
        
        self.textInputContainerBackgroundView.contentView.addSubview(self.searchLayoutClearButton)
        self.textInputContainerBackgroundView.contentView.addSubview(self.searchLayoutClearButtonIcon)
        self.textInputContainerBackgroundView.maskContentView.addSubview(self.searchLayoutClearButtonIcon.tintMask)
        
        self.textInputBackgroundNode.clipsToBounds = true
        let recognizer = TouchDownGestureRecognizer(target: self, action: #selector(self.textInputBackgroundViewTap(_:)))
        recognizer.touchDown = { [weak self] in
            if let strongSelf = self {
                if strongSelf.sendingTextDisabled {
                    guard let controller = (strongSelf.interfaceInteraction?.chatController() as? ChatController) else {
                        return
                    }
                    
                    if let boostsToUnrestrict = strongSelf.presentationInterfaceState?.boostsToUnrestrict, boostsToUnrestrict > 0 {
                        strongSelf.interfaceInteraction?.openBoostToUnrestrict()
                        return
                    }
                    
                    strongSelf.interfaceInteraction?.displayUndo(.universal(animation: "premium_unlock", scale: 1.0, colors: ["__allcolors__": UIColor(white: 1.0, alpha: 1.0)], title: nil, text: controller.restrictedSendingContentsText(), customUndoText: nil, timeout: nil))
                } else {
                    strongSelf.ensureFocused()
                }
            }
        }
        recognizer.waitForTouchUp = { [weak self] in
            guard let strongSelf = self, let richTextInputNode = strongSelf.richTextInputNode else {
                return true
            }

            if richTextInputNode.isInputFirstResponder {
                return true
            } else {
                return false
            }
        }
        self.textInputBackgroundTapRecognizer = recognizer
        self.textInputBackgroundNode.isUserInteractionEnabled = true
        self.textInputBackgroundNode.view.addGestureRecognizer(recognizer)
        
        if let presentationContext = presentationContext {
            self.emojiViewProvider = { [weak self, weak presentationContext] emoji in
                guard let strongSelf = self, let presentationContext = presentationContext, let presentationInterfaceState = strongSelf.presentationInterfaceState, let context = strongSelf.context else {
                    return UIView()
                }
                
                let pointSize = floor(24.0 * 1.3)
                return EmojiTextAttachmentView(context: context, userLocation: .other, emoji: emoji, file: emoji.file, cache: presentationContext.animationCache, renderer: presentationContext.animationRenderer, placeholderColor: presentationInterfaceState.theme.chat.inputPanel.inputTextColor.withAlphaComponent(0.12), pointSize: CGSize(width: pointSize, height: pointSize))
            }
        }
        
        self.viewOnceButton.addTarget(self, action: #selector(self.viewOncePressed), forControlEvents: [.touchUpInside])
        self.recordMoreButton.addTarget(self, action: #selector(self.recordMorePressed), forControlEvents: [.touchUpInside])
        
        self.view.addSubview(self.recordMoreButton.view)
        
        if let viewForOverlayContent = self.viewForOverlayContent {
            viewForOverlayContent.addSubnode(self.viewOnceButton)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.statusDisposable.dispose()
        self.tooltipController?.dismiss()
        self.currentEmojiSuggestion?.disposable.dispose()
    }
    
    override public func didLoad() {
        super.didLoad()
    }
    
    public func loadTextInputNodeIfNeeded() {
        if self.richTextInputNode == nil {
            self.loadTextInputNode(useNative: self.alwaysUseNativeInput)
        }
    }

    /// Decide which backend the given content requires. One-way latch: once the native rich-text backend is
    /// active it stays active for the panel's lifetime (never switches back to legacy). Legacy-only mode
    /// (`ios_rich_input_mode == 2`) always uses legacy; always-native mode (`ios_rich_input_mode == 1` or the
    /// `useInputDecEngine` experimental flag) always uses native; otherwise (dual-field switch) native is used
    /// only once the content is not representable in the legacy backend.
    private func desiredUseNative(for content: ChatInputContent) -> Bool {
        if self.richTextInputNode?.usesNativeRichTextEngine == true {
            return true
        }
        guard self.enableRichTextInput else {
            return false
        }
        if self.alwaysUseNativeInput {
            return true
        }
        return !content.isEntityExpressible()
    }

    /// Ensure the active input node is the right backend for `content`: create it (with the correct backend) if
    /// none exists yet, or replace the legacy node with a native one once `content` is no longer representable in
    /// the legacy backend. Never switches back to legacy (one-way latch).
    private func ensureInputNodeKind(for content: ChatInputContent) {
        let useNative = self.desiredUseNative(for: content)
        if self.richTextInputNode == nil {
            self.loadTextInputNode(useNative: useNative)
        } else if useNative && self.richTextInputNode?.usesNativeRichTextEngine == false {
            self.replaceLegacyWithNative()
        }
    }

    /// Replace the current legacy input node with a freshly-built native node, transferring first-responder
    /// status (become-new BEFORE resign-old, so the keyboard is not dismissed and re-presented). The caller sets
    /// content on the new node immediately afterwards.
    private func replaceLegacyWithNative() {
        guard let old = self.richTextInputNode, !old.usesNativeRichTextEngine else {
            return
        }
        let wasFirstResponder = old.isInputFirstResponder
        self.loadTextInputNode(useNative: true)
        guard let new = self.richTextInputNode, new !== old else {
            return
        }
        if wasFirstResponder {
            new.makeInputFirstResponder()
        }
        old.resignInputFirstResponder()
        old.asNode.removeFromSupernode()
    }

    private func loadTextInputNode(useNative: Bool = false) {
        let richTextInputNode: ChatRichTextInputNode
        if useNative {
            richTextInputNode = RichTextEditorChatInputNode(strings: self.presentationInterfaceState?.strings ?? defaultPresentationStrings, inputBackend: self.richTextInputBackendPreference, useInputDecEngine: self.useInputDecEngineEditor)
        } else {
            richTextInputNode = makeChatRichTextInputNode()
        }
        richTextInputNode.initialPrimaryLanguage = self.presentationInterfaceState?.interfaceState.inputLanguage
        var textColor: UIColor = .black
        var tintColor: UIColor = .blue
        var baseFontSize: CGFloat = 17.0
        var keyboardAppearance: UIKeyboardAppearance = UIKeyboardAppearance.default
        if let context = self.context, let presentationInterfaceState = self.presentationInterfaceState {
            richTextInputNode.inputTheme = makeTextInputTheme(context: context, interfaceState: presentationInterfaceState)
            richTextInputNode.applyRichTextTheme(self.makeRichTextThemeColors(presentationInterfaceState.theme))

            textColor = presentationInterfaceState.theme.chat.inputPanel.inputTextColor
            tintColor = presentationInterfaceState.theme.list.itemAccentColor
            baseFontSize = chatTextInputBaseFontSize(for: presentationInterfaceState.fontSize)
            keyboardAppearance = presentationInterfaceState.theme.rootController.keyboardColor.keyboardAppearance
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1.0
        paragraphStyle.lineHeightMultiple = 1.0
        paragraphStyle.paragraphSpacing = 1.0
        paragraphStyle.maximumLineHeight = 20.0
        paragraphStyle.minimumLineHeight = 20.0
        
        richTextInputNode.inputTypingAttributes = [NSAttributedString.Key.font: Font.regular(baseFontSize), NSAttributedString.Key.foregroundColor: textColor, NSAttributedString.Key.paragraphStyle: paragraphStyle]
        richTextInputNode.inputClipsToBounds = false
        richTextInputNode.inputDelegate = self
        if let textView = richTextInputNode.inputView as? ChatInputTextView {
            textView.shouldDeleteBackward = { [weak self] in
                guard let self else {
                    return true
                }
                return !self.unquoteParagraphOnBackspaceAtBlockStart()
            }
        }
        if #available(iOS 16.0, *) {
            richTextInputNode.contextMenuItemsProvider = { [weak self] defaultElements in
                return self?.buildRichTextContextMenuElements(defaultElements: defaultElements) ?? defaultElements
            }
        }
        richTextInputNode.canPasteMedia = { Self.pasteboardMayHoldMedia() }
        richTextInputNode.onPasteMedia = { [weak self] in self?.handlePastedMedia(perform: true) ?? false }
        richTextInputNode.pastedMarkdownFragmentParser = { [weak self] text in
            guard let self, let context = self.context, let content = self.pastedMarkdownParser?(context, text) else {
                return nil
            }
            return pasteFra
