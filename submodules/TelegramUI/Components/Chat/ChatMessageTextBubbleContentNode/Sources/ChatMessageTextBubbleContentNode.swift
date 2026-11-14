Skip to content
pypsretro77-rgb
belgram
Repository navigation
Code
Pull requests
Agents
Actions
Projects
Wiki
Security and quality
Insights
Settings
Commit 007fb3f
isaacclaude
isaac
and
claude
committed
3 weeks ago
Suspicious peers: hide buttons and emoji status, read nothing until accepted
While a user's chat shows the report/block panel (CachedUserData.isSuspiciousPeer),
their messages were only partly untrusted: plain-text links were stripped, but
buttons, rich-message links, link-preview text and their emoji status were live,
and the chat read their messages on sight. Until the panel is dismissed or the
account sends them a message:

- Reply-markup rows are not shown (bubbles, stickers, round videos). Rich messages go
  through instantPageForSuspiciousSender: links become plain text as in a plain
  message, inline pills and button rows are not shown, block indices are kept for
  rich-quote node ids. A link preview shows no button, opens nothing, and its text
  loses links too (MessageTextEntity.isShownFromSuspiciousPeer, now shared with the
  text bubble).
- The emoji status is hidden in the chat title, the panel's Premium-mark note and
  the profile header (with a collectible status's cover and colours).
- The history reads nothing, also while a non-contact's settings are still unknown.
- Sending a non-scheduled message clears canReport/canBlock locally (Add Contact
  stays), which ends the state.

Verified on the simulator with a temporary hook forcing the state (removed): keyboards
hidden and back live on dismiss, URL buttons likewise, title and profile show the
Premium star instead of the status, read decisions held and applied on dismiss and
on send (gate log; Skip Read History was on, so no read reached the server). Rich
messages are covered by InstantPageSuspiciousSenderTests only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
master
1 parent 
cfddf6e
 commit 
007fb3f
16 files changed

+491
-29
Lines changed: 491 additions & 29 deletions
File tree
Filter files…
CLAUDE.md
submodules
InstantPageUI
Sources
InstantPageSuspiciousSender.swift
Tests
InstantPageSuspiciousSenderTests.swift
TelegramCore/Sources
PendingMessages
EnqueueMessage.swift
SyncCore
SyncCore_PeerStatusSettings.swift
TelegramUI
Components
Chat
ChatMessageAnimatedStickerItemNode/Sources
ChatMessageAnimatedStickerItemNode.swift
ChatMessageBubbleItemNode/Sources
ChatMessageBubbleItemNode.swift
ChatMessageInstantVideoItemNode/Sources
ChatMessageInstantVideoItemNode.swift
ChatMessageRichDataBubbleContentNode/Sources
ChatMessageRichDataBubbleContentNode.swift
ChatMessageStickerItemNode/Sources
ChatMessageStickerItemNode.swift
ChatMessageTextBubbleContentNode/Sources
ChatMessageTextBubbleContentNode.swift
ChatMessageWebpageBubbleContentNode/Sources
ChatMessageWebpageBubbleContentNode.swift
PeerInfo/PeerInfoScreen/Sources
PeerInfoHeaderNode.swift
Sources
ChatControllerContentData.swift
ChatHistoryListNode.swift
ChatReportPeerTitlePanelNode.swift
Search within code
 
Customizable line height
The default line height has been increased for improved accessibility. You can choose to enable a more compact line height from the view settings menu.

‎CLAUDE.md‎
+28
Lines changed: 28 additions & 0 deletions


Original file line number	Diff line number	Diff line change
@@ -1353,6 +1353,34 @@ user's direct messages with a channel) keep their read state whatever the partic
opened from News also shows no unread badge on its back button
(`NavigateToChatControllerParams.showsUnreadChatsBackBadge`).

## A non-contact's chat before it is accepted (suspicious peer)
While a user's chat shows the report/block panel (`PeerStatusSettings` `canReport`/`canBlock`; the one
predicate is `CachedUserData.isSuspiciousPeer`), their incoming messages are untrusted until the panel is
dismissed or the account sends them a message:
- Links, mentions, hashtags and cashtags, emails, bank cards and TON addresses show as plain text
  (`MessageTextEntity.isShownFromSuspiciousPeer`, also in a link preview's text; `instantPageForSuspiciousSender`
  for rich messages). A link preview opens nothing and has no button.
- Buttons are not shown: reply-markup rows, rich inline pills and button rows. A link-styled rich button keeps
  its label as plain text.
- Their emoji status is hidden in the chat title, in the panel's "is a mark for Premium" note and in the
  profile header, including the cover and colours of a collectible status.
- Nothing is marked read (`ChatHistoryListNode.holdsReadsForSender`). Reads also wait while a non-contact's
  settings are still unknown, as on the first open of a chat they started: a read cannot be taken back.
Non-obvious:
- **Sending clears the flags locally.** `enqueueMessages(transaction:)` drops `canReport`/`canBlock` for a
  non-scheduled send; Add Contact stays. `users.getFullUser` rewrites the settings on every refresh, so if the
  server keeps those flags after a reply, the state returns on the next refresh. Unverified as of 2026-10-21
  (no second account to test with); the fallback is `hidePeerSettingsBar` on send, which also drops Add Contact.
- **The rich transform keeps every block's index.** A button row stays with no buttons, which lays out to
  nothing and adds no spacing. Block paths are rich-quote node ids, and quotes are built from the stored page.
  Removing an inline pill drops its label from its node's text, so such a message cannot be partially quoted
  while the state lasts.
- Private chats only. Chat list rows, search, and groups or channels with a report panel are unchanged.
## Postbox → TelegramEngine refactor (in progress)

A gradual migration is underway to eliminate direct `import Postbox` from consumer submodules in favor of `TelegramEngine`.
‎submodules/InstantPageUI/Sources/InstantPageSuspiciousSender.swift‎
+149
Lines changed: 149 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -0,0 +1,149 @@
import Foundation
import TelegramCore
/// The page as a chat shows it from a suspicious sender (`CachedUserData.isSuspiciousPeer`: the
/// chat's report/block panel is still up), matching what a plain message from them shows.
///
/// - Links, emails, mentions, hashtags and cashtags, bank cards and TON addresses become plain text:
///   the set a plain message from them loses (`MessageTextEntity.isShownFromSuspiciousPeer`). Phone
///   numbers, bot commands, dates, anchors and custom emoji stay. An image block loses its link.
/// - Buttons are not shown. An inline pill becomes nothing; a link-styled button is drawn as a link,
///   so its label stays as plain text. A button row keeps its place with no buttons, which lays out
///   to nothing and adds no spacing (`layoutBlockSequence` advances only on height).
///
/// Every block keeps its index: block paths are rich-quote node ids and structural paths, so the
/// original page's ids still address the same blocks here.
public func instantPageForSuspiciousSender(_ page: InstantPage) -> InstantPage {
    return InstantPage(
        blocks: page.blocks.map(suspiciousSenderBlock),
        media: page.media,
        isComplete: page.isComplete,
        rtl: page.rtl,
        url: page.url,
        views: page.views
    )
}
private func suspiciousSenderBlock(_ block: InstantPageBlock) -> InstantPageBlock {
    switch block {
    case .unsupported, .formula, .divider, .anchor, .channelBanner:
        return block
    case let .title(text):
        return .title(suspiciousSenderText(text))
    case let .subtitle(text):
        return .subtitle(suspiciousSenderText(text))
    case let .authorDate(author, date):
        return .authorDate(author: suspiciousSenderText(author), date: date)
    case let .header(text):
        return .header(suspiciousSenderText(text))
    case let .subheader(text):
        return .subheader(suspiciousSenderText(text))
    case let .heading(text, level):
        return .heading(text: suspiciousSenderText(text), level: level)
    case let .paragraph(text):
        return .paragraph(suspiciousSenderText(text))
    case let .preformatted(text, language):
        return .preformatted(text: suspiciousSenderText(text), language: language)
    case let .footer(text):
        return .footer(suspiciousSenderText(text))
    case let .list(items, ordered):
        return .list(items: items.map(suspiciousSenderListItem), ordered: ordered)
    case let .blockQuote(blocks, caption, collapsed):
        return .blockQuote(blocks: blocks.map(suspiciousSenderBlock), caption: suspiciousSenderText(caption), collapsed: collapsed)
    case let .pullQuote(text, caption):
        return .pullQuote(text: suspiciousSenderText(text), caption: suspiciousSenderText(caption))
    case let .image(id, caption, _, _, spoiler):
        return .image(id: id, caption: suspiciousSenderCaption(caption), url: nil, webpageId: nil, spoiler: spoiler)
    case let .video(id, caption, autoplay, loop, spoiler):
        return .video(id: id, caption: suspiciousSenderCaption(caption), autoplay: autoplay, loop: loop, spoiler: spoiler)
    case let .audio(id, caption):
        return .audio(id: id, caption: suspiciousSenderCaption(caption))
    case let .document(id, caption):
        return .document(id: id, caption: suspiciousSenderCaption(caption))
    case let .buttonRow(alignment, _):
        return .buttonRow(alignment: alignment, buttons: [])
    case let .cover(inner):
        return .cover(suspiciousSenderBlock(inner))
    case let .webEmbed(url, html, dimensions, caption, stretchToWidth, allowScrolling, coverId):
        return .webEmbed(url: url, html: html, dimensions: dimensions, caption: suspiciousSenderCaption(caption), stretchToWidth: stretchToWidth, allowScrolling: allowScrolling, coverId: coverId)
    case let .postEmbed(url, webpageId, avatarId, author, date, blocks, caption):
        return .postEmbed(url: url, webpageId: webpageId, avatarId: avatarId, author: author, date: date, blocks: blocks.map(suspiciousSenderBlock), caption: suspiciousSenderCaption(caption))
    case let .collage(items, caption):
        return .collage(items: items.map(suspiciousSenderBlock), caption: suspiciousSenderCaption(caption))
    case let .slideshow(items, caption):
        return .slideshow(items: items.map(suspiciousSenderBlock), caption: suspiciousSenderCaption(caption))
    case let .kicker(text):
        return .kicker(suspiciousSenderText(text))
    case let .thinking(text):
        return .thinking(suspiciousSenderText(text))
    case let .table(title, rows, bordered, striped, compact):
        let rows = rows.map { row in
            return InstantPageTableRow(cells: row.cells.map { cell in
                return InstantPageTableCell(text: cell.text.flatMap(suspiciousSenderText), header: cell.header, alignment: cell.alignment, verticalAlignment: cell.verticalAlignment, colspan: cell.colspan, rowspan: cell.rowspan)
            })
        }
        return .table(title: suspiciousSenderText(title), rows: rows, bordered: bordered, striped: striped, compact: compact)
    case let .details(title, blocks, expanded):
        return .details(title: suspiciousSenderText(title), blocks: blocks.map(suspiciousSenderBlock), expanded: expanded)
    case let .relatedArticles(title, articles):
        return .relatedArticles(title: suspiciousSenderText(title), articles: articles)
    case let .map(latitude, longitude, zoom, dimensions, caption):
        return .map(latitude: latitude, longitude: longitude, zoom: zoom, dimensions: dimensions, caption: suspiciousSenderCaption(caption))
    }
}
private func suspiciousSenderListItem(_ item: InstantPageListItem) -> InstantPageListItem {
    switch item {
    case .unknown:
        return item
    case let .text(text, num, checked):
        return .text(suspiciousSenderText(text), num, checked)
    case let .blocks(blocks, num, checked):
        return .blocks(blocks.map(suspiciousSenderBlock), num, checked)
    }
}
private func suspiciousSenderCaption(_ caption: InstantPageCaption) -> InstantPageCaption {
    return InstantPageCaption(text: suspiciousSenderText(caption.text), credit: suspiciousSenderText(caption.credit))
}
private func suspiciousSenderText(_ text: RichText) -> RichText {
    switch text {
    case .empty, .plain, .image, .formula, .textCustomEmoji:
        return text
    case let .bold(child):
        return .bold(suspiciousSenderText(child))
    case let .italic(child):
        return .italic(suspiciousSenderText(child))
    case let .underline(child):
        return .underline(suspiciousSenderText(child))
    case let .strikethrough(child):
        return .strikethrough(suspiciousSenderText(child))
    case let .fixed(child):
        return .fixed(suspiciousSenderText(child))
    case let .subscript(child):
        return .subscript(suspiciousSenderText(child))
    case let .superscript(child):
        return .superscript(suspiciousSenderText(child))
    case let .marked(child):
        return .marked(suspiciousSenderText(child))
    case let .textSpoiler(child):
        return .textSpoiler(text: suspiciousSenderText(child))
    case let .concat(children):
        return .concat(children.map(suspiciousSenderText))
    case let .phone(child, phone):
        return .phone(text: suspiciousSenderText(child), phone: phone)
    case let .anchor(child, name):
        return .anchor(text: suspiciousSenderText(child), name: name)
    case let .textAutoPhone(child):
        return .textAutoPhone(text: suspiciousSenderText(child))
    case let .textBotCommand(child):
        return .textBotCommand(text: suspiciousSenderText(child))
    case let .textDate(child, date, format):
        return .textDate(text: suspiciousSenderText(child), date: date, format: format)
    case let .url(child, _, _), let .email(child, _), let .textAutoEmail(child), let .textAutoUrl(child), let .textBankCard(child), let .textTonAddress(child), let .textCashtag(child), let .textHashtag(child), let .textMention(child), let .textMentionName(child, _):
        return suspiciousSenderText(child)
    case let .textButton(button):
        return button.isLink ? suspiciousSenderText(button.text) : .empty
    }
}
‎submodules/InstantPageUI/Tests/InstantPageSuspiciousSenderTests.swift‎
+122
Lines changed: 122 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -0,0 +1,122 @@
import XCTest
import TelegramCore
@testable import InstantPageUI
private func makePage(_ blocks: [InstantPageBlock]) -> InstantPage {
    return InstantPage(blocks: blocks, media: [:], isComplete: true, rtl: false, url: "", views: nil)
}
private func shown(_ blocks: [InstantPageBlock]) -> [InstantPageBlock] {
    return instantPageForSuspiciousSender(makePage(blocks)).blocks
}
private func shownText(_ text: RichText) -> RichText {
    guard case let .paragraph(result) = shown([.paragraph(text)]).first else {
        XCTFail("a paragraph stays a paragraph")
        return .empty
    }
    return result
}
private func makeButton(_ label: String, isLink: Bool) -> InstantPageButton {
    return InstantPageButton(text: .plain(label), action: .url("https://example.com"), color: nil, isLink: isLink)
}
final class InstantPageSuspiciousSenderTests: XCTestCase {
    /// The kinds a plain message from the same sender loses (`.Url`, `.TextUrl`, `.Email`, `.Mention`,
    /// `.TextMention`, `.Hashtag` with cashtags, `.BankCard`, `.TonAddress`) become their text,
    /// formatting inside them kept.
    func testLinkLikeRunsBecomeTheirText() {
        let inner = RichText.bold(.plain("x"))
        let stripped: [RichText] = [
            .url(text: inner, url: "https://example.com", webpageId: nil),
            .email(text: inner, email: "a@b.c"),
            .textAutoEmail(text: inner),
            .textAutoUrl(text: inner),
            .textBankCard(text: inner),
            .textTonAddress(text: inner),
            .textCashtag(text: inner),
            .textHashtag(text: inner),
            .textMention(text: inner),
            .textMentionName(text: inner, peerId: 1)
        ]
        for text in stripped {
            XCTAssertEqual(shownText(.concat([.plain("a "), text])), .concat([.plain("a "), inner]), "\(text)")
        }
    }
    /// What a plain message keeps (phone numbers, bot commands, dates) stays, and so do anchors.
    func testOtherRunsStay() {
        let kept: [RichText] = [
            .phone(text: .plain("+1"), phone: "+1"),
            .textAutoPhone(text: .plain("+1")),
            .textBotCommand(text: .plain("/start")),
            .textDate(text: .plain("today"), date: 1, format: nil),
            .anchor(text: .plain("a"), name: "a"),
            .textCustomEmoji(fileId: 1, alt: "a"),
            .textSpoiler(text: .plain("s"))
        ]
        for text in kept {
            XCTAssertEqual(shownText(text), text)
        }
    }
    /// A link inside a kept wrapper is still stripped.
    func testLinksInsideKeptRunsAreStripped() {
        let link = RichText.url(text: .plain("x"), url: "https://example.com", webpageId: nil)
        XCTAssertEqual(shownText(.textSpoiler(text: link)), .textSpoiler(text: .plain("x")))
        XCTAssertEqual(shownText(.italic(.underline(link))), .italic(.underline(.plain("x"))))
    }
    /// An inline pill is not shown; a link-styled button reads as a link, so its label stays as text.
    func testInlineButtons() {
        XCTAssertEqual(shownText(.concat([.plain("a"), .textButton(makeButton("Pay", isLink: false))])), .concat([.plain("a"), .empty]))
        XCTAssertEqual(shownText(.concat([.plain("a"), .textButton(makeButton("here", isLink: true))])), .concat([.plain("a"), .plain("here")]))
    }
    /// A button row loses its buttons but keeps its index, so the blocks after it keep their paths,
    /// which are the rich-quote node ids.
    func testButtonRowKeepsItsPlace() {
        let blocks: [InstantPageBlock] = [
            .paragraph(.plain("one")),
            .buttonRow(alignment: .center, buttons: [makeButton("Open", isLink: false)]),
            .paragraph(.url(text: .plain("two"), url: "https://example.com", webpageId: nil))
        ]
        let result = shown(blocks)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1], .buttonRow(alignment: .center, buttons: []))
        let originalNodes = instantPageQuotableNodes(blocks)
        let shownNodes = instantPageQuotableNodes(result)
        XCTAssertEqual(shownNodes.map(\.id), originalNodes.map(\.id))
        XCTAssertEqual(shownNodes.map(\.flatText), originalNodes.map(\.flatText))
    }
    /// Nested containers are walked: list items, table cells and titles, details, quotes and captions.
    func testNestedTextIsStripped() {
        let link = RichText.url(text: .plain("x"), url: "https://example.com", webpageId: nil)
        let caption = InstantPageCaption(text: link, credit: link)
        let blocks: [InstantPageBlock] = [
            .list(items: [.text(link, nil, nil), .blocks([.paragraph(link)], nil, nil)], ordered: false),
            .table(title: link, rows: [InstantPageTableRow(cells: [InstantPageTableCell(text: link, header: false, alignment: .left, verticalAlignment: .top, colspan: 1, rowspan: 1)])], bordered: false, striped: false, compact: false),
            .details(title: link, blocks: [.paragraph(link)], expanded: false),
            .blockQuote(blocks: [.paragraph(link)], caption: link, collapsed: nil),
            .image(id: EngineMedia.Id(namespace: 0, id: 1), caption: caption, url: "https://example.com", webpageId: nil, spoiler: false)
        ]
        let plain = RichText.plain("x")
        let plainCaption = InstantPageCaption(text: plain, credit: plain)
        XCTAssertEqual(shown(blocks), [
            .list(items: [.text(plain, nil, nil), .blocks([.paragraph(plain)], nil, nil)], ordered: false),
            .table(title: plain, rows: [InstantPageTableRow(cells: [InstantPageTableCell(text: plain, header: false, alignment: .left, verticalAlignment: .top, colspan: 1, rowspan: 1)])], bordered: false, striped: false, compact: false),
            .details(title: plain, blocks: [.paragraph(plain)], expanded: false),
            .blockQuote(blocks: [.paragraph(plain)], caption: plain, collapsed: nil),
            .image(id: EngineMedia.Id(namespace: 0, id: 1), caption: plainCaption, url: nil, webpageId: nil, spoiler: false)
        ])
    }
    /// A page with nothing to strip comes back equal.
    func testPlainPageIsUnchanged() {
        let blocks: [InstantPageBlock] = [.heading(text: .bold(.plain("h")), level: 1), .paragraph(.plain("p")), .formula(latex: "x")]
        XCTAssertEqual(shown(blocks), blocks)
    }
}
‎submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift‎
+13
Lines changed: 13 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -879,6 +879,19 @@ func enqueueMessages(transaction: Transaction, account: Account, peerId: PeerId,
        }
    }

    // Sending to a user whose chat still shows the report/block panel ends its suspicious state
    // (`CachedUserData.isSuspiciousPeer`): only the report and block flags go, so an Add Contact
    // offer stays. A scheduled message reaches no one yet and changes nothing.
    if peerId.namespace == Namespaces.Peer.CloudUser, messages.contains(where: { !$0.1.attributes.contains(where: { $0 is OutgoingScheduleInfoMessageAttribute }) }) {
        transaction.updatePeerCachedData(peerIds: Set([peerId]), update: { _, current in
            guard let current = current as? CachedUserData, current.isSuspiciousPeer, var peerStatusSettings = current.peerStatusSettings else {
                return current
            }
            peerStatusSettings.flags.subtract(.suspiciousPeer)
            return current.withUpdatedPeerStatusSettings(peerStatusSettings)
        })
    }
    
    var forwardedMessageIds = Set<MessageId>()
    for (_, message) in messages {
        if case let .forward(sourceId, _, _, _, _) = message {
‎submodules/TelegramCore/Sources/SyncCore/SyncCore_PeerStatusSettings.swift‎
+32
Lines changed: 32 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -145,3 +145,35 @@ public struct PeerStatusSettings: PostboxCoding, Equatable {
        return self.flags.contains(member)
    }
}
public extension PeerStatusSettings.Flags {
    /// The flags that keep a user's chat suspicious (`CachedUserData.isSuspiciousPeer`).
    static let suspiciousPeer: PeerStatusSettings.Flags = [.canReport, .canBlock]
}
public extension CachedUserData {
    /// The user's chat still shows the report/block panel: they wrote first, and the account has
    /// neither dismissed the panel nor sent them a message (`enqueueMessages` clears these flags
    /// locally). Until then the chat shows their links as plain text, hides their buttons and
    /// emoji status, and marks nothing read.
    var isSuspiciousPeer: Bool {
        guard let flags = self.peerStatusSettings?.flags else {
            return false
        }
        return !flags.isDisjoint(with: .suspiciousPeer)
    }
}
public extension MessageTextEntity {
    /// Whether a suspicious peer's text keeps this entity (`CachedUserData.isSuspiciousPeer`). Links,
    /// mentions, hashtags (cashtags arrive as hashtags), emails, bank cards and TON addresses show as
    /// plain text.
    var isShownFromSuspiciousPeer: Bool {
        switch self.type {
        case .Url, .TextUrl, .Mention, .TextMention, .Hashtag, .Email, .BankCard, .TonAddress:
            return false
        default:
            return true
        }
    }
}
‎submodules/TelegramUI/Components/Chat/ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift‎
+5
Lines changed: 5 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -1236,6 +1236,11 @@ public class ChatMessageAnimatedStickerItemNode: ChatMessageItemView {
                }
            }

            // A suspicious sender's buttons are not shown, as their links are not.
            if item.associatedData.isSuspiciousPeer && item.message.effectivelyIncoming(item.context.account.peerId) {
                replyMarkup = nil
            }
            
            var hasReply = replyMessage != nil || replyForward != nil || replyStory != nil
            if case let .peer(peerId) = item.chatLocation, (peerId == replyMessage?.id.peerId || item.message.threadId == 1), let peer = item.message.peers[item.message.id.peerId], peer.isForumOrMonoForum, item.message.associatedThreadInfo != nil {
                if let threadId = item.message.threadId, let replyMessage = replyMessage, Int64(replyMessage.id.id) == threadId {
‎submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift‎
+4
Lines changed: 4 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -2214,6 +2214,10 @@ public class ChatMessageBubbleItemNode: ChatMessageItemView, ChatMessagePreviewI
        if firstMessage.isRestricted(platform: "ios", contentSettings: item.context.currentContentSettings.with { $0 }) {
            replyMarkup = nil
        }
        // A suspicious sender's buttons are not shown, as their links are not.
        if item.associatedData.isSuspiciousPeer && firstMessage.effectivelyIncoming(item.context.account.peerId) {
            replyMarkup = nil
        }

        if let forwardInfo = firstMessage.forwardInfo, forwardInfo.psaType != nil {
            inlineBotNameString = nil
‎submodules/TelegramUI/Components/Chat/ChatMessageInstantVideoItemNode/Sources/ChatMessageInstantVideoItemNode.swift‎
+5
Lines changed: 5 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -520,6 +520,11 @@ public class ChatMessageInstantVideoItemNode: ChatMessageItemView, ASGestureReco
                }
            }

            // A suspicious sender's buttons are not shown, as their links are not.
            if item.associatedData.isSuspiciousPeer && item.message.effectivelyIncoming(item.context.account.peerId) {
                replyMarkup = nil
            }
            
            if replyMessage != nil || replyForward != nil || replyStory != nil {
                replyInfoApply = makeReplyInfoLayout(ChatMessageReplyInfoNode.Arguments(
                    presentationData: item.presentationData,
‎submodules/TelegramUI/Components/Chat/ChatMessageRichDataBubbleContentNode/Sources/ChatMessageRichDataBubbleContentNode.swift‎
+75
-9
Lines changed: 75 additions & 9 deletions
Original file line number	Diff line number	Diff line change
@@ -52,16 +52,69 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
                return .original
            }
        }
        func withPage(_ page: ObjectIdentifier) -> ResolvedRichDataPageKey {
            switch self {
            case let .pendingEdit(attribute, _):
                return .pendingEdit(attribute: attribute, page: page)
            case let .translated(language, attribute, _):
                return .translated(language: language, attribute: attribute, page: page)
            case let .original(attribute, _):
                return .original(attribute: attribute, page: page)
            }
        }
    }

    private struct ResolvedRichDataContent {
        let instantPage: InstantPage
        var instantPage: InstantPage
        let originalAttribute: RichTextMessageAttribute?
        let key: ResolvedRichDataPageKey
        var key: ResolvedRichDataPageKey
        let isTranslated: Bool
        let isTranslating: Bool
        /// Set when `instantPage` is a suspicious sender's page as shown (`showing(_:)`).
        var suspiciousSenderPage: SuspiciousSenderPage? = nil
        /// The page a selection quotes from: the page the server stored, which a suspicious sender's
        /// shown page maps back to only when stripping it left every quotable node's text alone.
        var quotablePage: InstantPage? {
            guard let suspiciousSenderPage = self.suspiciousSenderPage else {
                return self.instantPage
            }
            return suspiciousSenderPage.keepsQuotes ? suspiciousSenderPage.original : nil
        }
        func showing(_ suspiciousSenderPage: SuspiciousSenderPage) -> ResolvedRichDataContent {
            var result = self
            result.instantPage = suspiciousSenderPage.shown
            result.key = self.key.withPage(ObjectIdentifier(suspiciousSenderPage.shown))
            result.suspiciousSenderPage = suspiciousSenderPage
            return result
        }
    }
    
    /// A suspicious sender's page as shown (`instantPageForSuspiciousSender`), kept across layouts so
    /// the shown page's identity, and with it the page key the layout cache and the page view reuse
    /// on, changes only when the original page does.
    private struct SuspiciousSenderPage {
        let original: InstantPage
        let shown: InstantPage
        /// Stripping left every quotable node's text as it was. Removing an inline pill drops its
        /// label from its node, so a selection there would quote the wrong range.
        let keepsQuotes: Bool
        init(original: InstantPage, previous: SuspiciousSenderPage?) {
            self.original = original
            if let previous, previous.original === original {
                self.shown = previous.shown
                self.keepsQuotes = previous.keepsQuotes
            } else {
                let shown = instantPageForSuspiciousSender(original)
                self.shown = shown
                self.keepsQuotes = shown.quotableNodes.map(\.flatText) == original.quotableNodes.map(\.flatText)
            }
        }
    }
    private let containerNode: ContainerNode
    /// Clips `containerNode` to the bubble's four (possibly unequal, when merged) corner radii —
    /// see `applyContainerCorners`. Created on first layout, since an unloaded node has no layer.
@@ -101,6 +154,7 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
    // materialization), so this is a straight structural compare. It runs only on the
    // about-to-crossfade path, never on the hot same-content path.
    private var appliedInstantPage: InstantPage?
    private var suspiciousSenderPage: SuspiciousSenderPage?
    // messageStableVersion is in the cache key because the synthesized instantPage content
    // mutates between streamed AI message chunks (each chunk bumps stableVersion); without
    // this, the cached layout would shadow newly-arrived content during streaming.
@@ -535,7 +589,9 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
        // (`fullInstantPage`) rendering carries the same key but a different page object, so an
        // identity check excludes it. `originalAttribute` is Optional (it is the pending edit's
        // attribute in the `.pendingEdit` case).
        guard let attribute = resolved.originalAttribute, resolved.instantPage === attribute.instantPage else {
        // A suspicious sender's shown page is a copy of the stored one, with the same paths.
        let page = resolved.suspiciousSenderPage?.original ?? resolved.instantPage
        guard let attribute = resolved.originalAttribute, page === attribute.instantPage else {
            return false
        }
        return item.controllerInteraction.canEditMessageRichText(item.message)
@@ -582,6 +638,7 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
        let currentPageLayout = self.currentPageLayout
        let currentExpandedDetails = self.currentExpandedDetails
        let currentExpandedQuotePaths = self.currentExpandedQuotePaths
        let currentSuspiciousSenderPage = self.suspiciousSenderPage
        let showMoreExpandedState = self.showMoreExpanded
        let statusLayout = ChatMessageDateAndStatusNode.asyncLayout(self.statusNode)
        let showMoreTextLayout = TextNode.asyncLayout(self.showMoreTextNode)
@@ -805,7 +862,15 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode

                // Resolve the node-local expand state for THIS message (collapsed for any other).
                let showMoreExpanded = (showMoreExpandedState?.messageId == item.message.id) ? (showMoreExpandedState?.value ?? false) : false
                let resolvedContent = ChatMessageRichDataBubbleContentNode.resolvedRichDataContent(item: item, showMoreExpanded: showMoreExpanded)
                var resolvedContent = ChatMessageRichDataBubbleContentNode.resolvedRichDataContent(item: item, showMoreExpanded: showMoreExpanded)
                // A suspicious sender's links show as text and their buttons not at all, as in a plain
                // message from them (`ChatMessageTextBubbleContentNode`).
                var suspiciousSenderPage: SuspiciousSenderPage?
                if let content = resolvedContent, item.associatedData.isSuspiciousPeer, item.message.effectivelyIncoming(item.context.account.peerId) {
                    let page = SuspiciousSenderPage(original: content.instantPage, previous: currentSuspiciousSenderPage)
                    suspiciousSenderPage = page
                    resolvedContent = content.showing(page)
                }

                if let resolvedContent {
                    #if DEBUG && false
@@ -1341,6 +1406,7 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
                            codeHighlightState.disposable.dispose()
                        }

                        self.suspiciousSenderPage = suspiciousSenderPage
                        if let pageLayout, let pageWebpage, let resolvedContent {
                            self.currentPageLayout = (
                                suggestedBoundingWidth,
@@ -1355,10 +1421,10 @@ public class ChatMessageRichDataBubbleContentNode: ChatMessageBubbleContentNode
                                cachedMessageSyntaxHighlight,
                                pageLayout
                            )
                            if case .original = resolvedContent.key, !resolvedContent.isTranslated, !resolvedContent.isTranslating {
                                if self.quotablePage !== resolvedContent.instantPage {
                                    self.quotablePage = resolvedContent.instantPage
                                    self.quotableNodes = resolvedContent.instantPage.quotableNodes
                            if case .original = resolvedContent.key, !resolvedContent.isTranslated, !resolvedContent.isTranslating, let quotablePage = resolvedContent.quotablePage {
                                if self.quotablePage !== quotablePage {
                                    self.quotablePage = quotablePage
                                    self.quotableNodes = quotablePage.quotableNodes
                                }
                            } else {
                                self.quotablePage = nil
‎submodules/TelegramUI/Components/Chat/ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift‎
+5
Lines changed: 5 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -720,6 +720,11 @@ public class ChatMessageStickerItemNode: ChatMessageItemView {
                }
            }

            // A suspicious sender's buttons are not shown, as their links are not.
            if item.associatedData.isSuspiciousPeer && item.message.effectivelyIncoming(item.context.account.peerId) {
                replyMarkup = nil
            }
            
            var hasReply = replyMessage != nil || replyForward != nil || replyStory != nil
            if case let .peer(peerId) = item.chatLocation, (peerId == replyMessage?.id.peerId || item.message.threadId == 1), let peer = item.message.peers[item.message.id.peerId], peer.isForumOrMonoForum, item.message.associatedThreadInfo != nil {
                if let threadId = item.message.threadId, let replyMessage = replyMessage, Int64(replyMessage.id.id) == threadId {
‎submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift‎
+1
-8
Lines changed: 1 addition & 8 deletions
Original file line number	Diff line number	Diff line change
@@ -442,14 +442,7 @@ public class ChatMessageTextBubbleContentNode: ChatMessageBubbleContentNode {


                if incoming && item.associatedData.isSuspiciousPeer, let entities = messageEntities {
                    messageEntities = entities.filter { entity in
                        switch entity.type {
                        case .Url, .TextUrl, .Mention, .TextMention, .Hashtag, .Email, .BankCard, .TonAddress:
                            return false
                        default:
                            return true
                        }
                    }
                    messageEntities = entities.filter(\.isShownFromSuspiciousPeer)
                }

                var formattedDateUpdatePeriod: Int32?
‎submodules/TelegramUI/Components/Chat/ChatMessageWebpageBubbleContentNode/Sources/ChatMessageWebpageBubbleContentNode.swift‎
+20
-4
Lines changed: 20 additions & 4 deletions
Original file line number	Diff line number	Diff line change
@@ -66,7 +66,7 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
                                }
                            }

                            if shouldOpenUrl {
                            if shouldOpenUrl && !strongSelf.isFromSuspiciousSender(item) {
                                var isConcealed = true
                                if item.message.text.contains(content.url) {
                                    isConcealed = false
@@ -95,7 +95,7 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
                    openChatMessageMode = .automaticPlayback
                }
                if !item.controllerInteraction.openMessage(item.message, OpenMessageParams(mode: openChatMessageMode)) {
                    if let webPage = strongSelf.webPage, case let .Loaded(content) = webPage.content {
                    if !strongSelf.isFromSuspiciousSender(item), let webPage = strongSelf.webPage, case let .Loaded(content) = webPage.content {
                        var isConcealed = true
                        if item.message.text.contains(content.url) {
                            isConcealed = false
@@ -117,6 +117,9 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
        }
        self.contentNode.activateAction = { [weak self] in
            if let strongSelf = self, let item = strongSelf.item {
                if strongSelf.isFromSuspiciousSender(item) {
                    return
                }
                if let _ = item.message.adAttribute {
                    item.controllerInteraction.activateAdAction(item.message.id, strongSelf.contentNode.makeProgress(), false, false)
                } else {
@@ -160,8 +163,7 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
                return ChatMessageBubbleContentTapAction(content: .none)
            }

            let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
            if incoming && item.associatedData.isSuspiciousPeer {
            if self.isFromSuspiciousSender(item) {
                return ChatMessageBubbleContentTapAction(content: .none)
            }

@@ -193,6 +195,12 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
        fatalError("init(coder:) has not been implemented")
    }

    /// A suspicious sender's link preview opens nothing, as their links do not
    /// (`ChatMessageItemAssociatedData.isSuspiciousPeer`).
    private func isFromSuspiciousSender(_ item: ChatMessageBubbleContentItem) -> Bool {
        return item.associatedData.isSuspiciousPeer && item.message.effectivelyIncoming(item.context.account.peerId)
    }
    
    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let currentWebpage = self.webPage
        let currentContentNodeLayout = self.contentNode.asyncLayout(displayGiftIcon: true)
@@ -597,6 +605,14 @@ public final class ChatMessageWebpageBubbleContentNode: ChatMessageBubbleContent
                displayLine = true
            }

            // A suspicious sender's link preview opens nothing, so it offers no button either, and its
            // text shows links as plain text, as their message does.
            if item.associatedData.isSuspiciousPeer && item.message.effectivelyIncoming(item.context.account.peerId) {
                actionTitle = nil
                actionIcon = nil
                entities = entities?.filter(\.isShownFromSuspiciousPeer)
            }
            
            let (initialWidth, continueLayout) = contentNodeLayout(item.presentationData, item.controllerInteraction.automaticMediaDownloadSettings, item.associatedData, item.attributes, item.context, item.controllerInteraction, item.message, item.read, item.chatLocation, title, titleBadge, subtitle, text, entities, mediaAndFlags, badge, actionIcon, actionTitle, displayLine, layoutConstants, preparePosition, constrainedSize, item.controllerInteraction.presentationContext.animationCache, item.controllerInteraction.presentationContext.animationRenderer)

            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 8.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)
‎submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift‎
+7
Lines changed: 7 additions & 0 deletions
Original file line number	Diff line number	Diff line change
@@ -575,6 +575,13 @@ final class PeerInfoHeaderNode: ASDisplayNode {
            threadData = nil
        }

        // A suspicious peer's emoji status is not shown, as in their chat's title: neither the icon nor
        // the cover and colours a collectible status brings.
        var peer = peer
        if case let .user(user) = peer, user.emojiStatus != nil, (cachedData as? CachedUserData)?.isSuspiciousPeer == true {
            peer = .user(user.withUpdatedEmojiStatus(nil))
        }
        
        self.state = state
        self.peer = peer
        self.threadData = threadData
‎submodules/TelegramUI/Sources/ChatControllerContentData.swift‎
+3
-1
Lines changed: 3 additions & 1 deletion
Original file line number	Diff line number	Diff line change
@@ -615,7 +615,9 @@ extension ChatControllerImpl {
                                customSubtitle = strings.Chat_SavedMessagesStatusViewAsChats
                            }

                            strongSelf.state.chatTitleContent = .peer(peerView: ChatTitleContent.PeerData(peerView: peerView), customTitle: nil, customSubtitle: customSubtitle, onlineMemberCount: onlineMemberCount, isScheduledMessages: isScheduledMessages, isMuted: nil, customMessageCount: nil, hidePeerStatus: false, isEnabled: hasPeerInfo)
                            // A suspicious peer's emoji status is not shown, as their links are not.
                            let hidePeerStatus = (peerView.cachedData as? CachedUserData)?.isSuspiciousPeer ?? false
                            strongSelf.state.chatTitleContent = .peer(peerView: ChatTitleContent.PeerData(peerView: peerView), customTitle: nil, customSubtitle: customSubtitle, onlineMemberCount: onlineMemberCount, isScheduledMessages: isScheduledMessages, isMuted: nil, customMessageCount: nil, hidePeerStatus: hidePeerStatus, isEnabled: hasPeerInfo)

                            let imageOverride: AvatarNodeImageOverride?
                            if context.account.peerId == peer.id {
‎submodules/TelegramUI/Sources/ChatHistoryListNode.swift‎
+18
-6
Lines changed: 18 additions & 6 deletions
Original file line number	Diff line number	Diff line change
@@ -581,6 +581,10 @@ public final class ChatHistoryListNodeImpl: ASDisplayNode, ChatHistoryNode, Chat

    private let maxVisibleIncomingMessageIndex = ValuePromise<MessageIndex>(ignoreRepeated: true)
    let canReadHistory = Promise<Bool>()
    /// The chat reads nothing while its peer is suspicious (`CachedUserData.isSuspiciousPeer`), or
    /// may still turn out to be: a non-contact user whose settings have not been fetched yet, as on
    /// the first open of a chat they started. A read cannot be taken back. From the latest history view.
    private let holdsReadsForSender = ValuePromise<Bool>(ignoreRepeated: true)
    private var canReadHistoryValue: Bool = false
    private var canReadHistoryDisposable: Disposable?

@@ -2321,10 +2325,18 @@ public final class ChatHistoryListNodeImpl: ASDisplayNode, ChatHistoryNode, Chat
                    translateToLanguage = (normalizeTranslationLanguage(translationState.fromLang), normalizeTranslationLanguage(languageCode))
                }

                var isSuspiciousPeer = false
                if let cachedUserData = data.cachedData as? CachedUserData, let peerStatusSettings = cachedUserData.peerStatusSettings, peerStatusSettings.flags.contains(.canBlock) || peerStatusSettings.flags.contains(.canReport) {
                    isSuspiciousPeer = true
                let isSuspiciousPeer = (data.cachedData as? CachedUserData)?.isSuspiciousPeer ?? false
                var holdsReadsForSender = isSuspiciousPeer
                if let peerId = chatLocation.peerId, peerId.namespace == Namespaces.Peer.CloudUser, peerId != context.account.peerId, (data.cachedData as? CachedUserData)?.peerStatusSettings == nil {
                    let isContact = view.additionalData.contains(where: { entry in
                        if case let .peerIsContact(entryPeerId, value) = entry, entryPeerId == peerId {
                            return value
                        }
                        return false
                    })
                    holdsReadsForSender = !isContact
                }
                self?.holdsReadsForSender.set(holdsReadsForSender)

                let associatedData = extractAssociatedData(chatLocation: chatLocation, view: view, automaticDownloadNetworkType: networkType, preferredStoryHighQuality: preferredStoryHighQuality, animatedEmojiStickers: animatedEmojiStickers, additionalAnimatedEmojiStickers: additionalAnimatedEmojiStickers, premiumGiftStickers: premiumGiftStickers, tonGiftStickers: tonGiftStickers, subject: subject, currentlyPlayingMessageId: currentlyPlayingMessageIdAndType?.0, isCopyProtectionEnabled: isCopyProtectionEnabled, availableReactions: availableReactions, availableMessageEffects: availableMessageEffects, savedMessageTags: savedMessageTags, defaultReaction: defaultReaction.0, areStarReactionsEnabled: defaultReaction.1, isPremium: isPremium, alwaysDisplayTranscribeButton: alwaysDisplayTranscribeButton, accountPeer: accountPeer, topicAuthorId: topicAuthorId, hasBots: chatHasBots, translateToLanguage: translateToLanguage?.toLang, maxReadStoryId: maxReadStoryId, recommendedChannels: recommendedChannels, audioTranscriptionTrial: audioTranscriptionTrial, chatThemes: chatThemes, deviceContactsNumbers: deviceContactsNumbers, isInline: !rotated, showSensitiveContent: contentSettings.ignoreContentRestrictionReasons.contains("sensitive"), isSuspiciousPeer: isSuspiciousPeer, accountCountry: accountCountry)

@@ -2681,13 +2693,13 @@ public final class ChatHistoryListNodeImpl: ASDisplayNode, ChatHistoryNode, Chat

    private func beginReadHistoryManagement() {
        let previousMaxIncomingMessageIndexByNamespace = Atomic<[MessageId.Namespace: MessageIndex]>(value: [:])
        let readHistory = combineLatest(self.maxVisibleIncomingMessageIndex.get(), self.canReadHistory.get())
        let readHistory = combineLatest(self.maxVisibleIncomingMessageIndex.get(), self.canReadHistory.get(), self.holdsReadsForSender.get())

        self.readHistoryDisposable.set((readHistory |> deliverOnMainQueue).startStrict(next: { [weak self] messageIndex, canRead in
        self.readHistoryDisposable.set((readHistory |> deliverOnMainQueue).startStrict(next: { [weak self] messageIndex, canRead, holdsReadsForSender in
            guard let strongSelf = self else {
                return
            }
            if !canRead {
            if !canRead || holdsReadsForSender {
                return
            }

‎submodules/TelegramUI/Sources/ChatReportPeerTitlePanelNode.swift‎
+4
-1
Lines changed: 4 additions & 1 deletion
Original file line number	Diff line number	Diff line change
@@ -512,7 +512,10 @@ final class ChatReportPeerTitlePanelNode: ChatTitleAccessoryPanelNode {
        }

        var emojiStatus: PeerEmojiStatus?
        if let user = interfaceState.renderedPeer?.peer as? TelegramUser, let emojiStatusValue = user.emojiStatus {
        // A suspicious user's emoji status is not shown, so neither is the note explaining it
        // (`CachedUserData.isSuspiciousPeer`, here from the same settings that show this panel).
        let isSuspiciousPeer = !(interfaceState.contactStatus?.peerStatusSettings?.flags.isDisjoint(with: .suspiciousPeer) ?? true)
        if let user = interfaceState.renderedPeer?.peer as? TelegramUser, let emojiStatusValue = user.emojiStatus, !isSuspiciousPeer {
            if user.isFake || user.isScam { 
            } else {
                emojiStatus = emojiStatusValue
0 commit comments
Comments
0
 (0)
Comment
You're not receiving notifications from this thread.

5 files remain
