import Intents
import UIKit
import UserNotifications

/// Turns an incoming notification into one that looks like it came from a
/// person: their photograph on the left, their name where the app's name would
/// be, and the message underneath.
///
/// **This is the only way iOS will draw a face in a banner.** A
/// `UNNotificationAttachment` puts a thumbnail on the *right*, beside the app
/// icon, and the banner still says "Written". Rendering the sender as a person
/// needs an `INSendMessageIntent` donated from an extension, the
/// `com.apple.developer.usernotifications.communication` entitlement, and
/// `INSendMessageIntent` listed in `NSUserActivityTypes` — three things in three
/// different places, each of which silently does nothing on its own.
///
/// **Everything here is best-effort and the fallback is the plain banner.** A
/// notification that arrives looking ordinary is enormously better than one that
/// does not arrive, so every failure below delivers the content unchanged rather
/// than throwing or waiting. The extension gets roughly thirty seconds;
/// `serviceExtensionTimeWillExpire` is what honours that ceiling, and iOS
/// delivers the original payload if even that is missed.
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var pending: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        pending = content

        let info = request.content.userInfo
        // `sender_name` rather than the title: the title is a headline —
        // "Marco likes you" — and using it as a display name produces a person
        // apparently called "Marco likes you". See `0027`.
        let name = info["sender_name"] as? String
        let senderID = info["sender_id"] as? String

        // Both are required. Without an id there is nothing to identify the
        // person by; without a name the banner would rename itself to nothing.
        guard let name, let senderID else {
            contentHandler(content)
            return
        }

        Task {
            let image = await Self.avatar(from: info["image_url"] as? String)
            contentHandler(
                Self.personalised(content, name: name, id: senderID, image: image, info: info)
            )
        }
    }

    /// Downloads the pre-signed photograph, or answers nil.
    ///
    /// **Pre-signed by `functions/push`, which is why this needs no session.**
    /// The bucket is private, and an extension that had to authenticate would
    /// have to read the session out of the shared keychain and refresh it —
    /// more moving parts, inside a process with a thirty-second life, for a
    /// picture.
    ///
    /// An expired URL, a phone with no signal, or a photograph since deleted all
    /// land on nil, and nil is survivable: the intent is still donated and the
    /// banner still renders as a person, just without a face.
    private static func avatar(from urlString: String?) async -> INImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        // Well inside the extension's own budget, so a slow download costs the
        // picture rather than the notification.
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return INImage(imageData: data)
    }

    /// Builds the intent, donates it, and returns the rewritten content.
    ///
    /// Donating is not decoration — `content.updating(from:)` changes nothing
    /// for an intent the system has not been told about.
    private static func personalised(
        _ content: UNMutableNotificationContent,
        name: String,
        id: String,
        image: INImage?,
        info: [AnyHashable: Any]
    ) -> UNNotificationContent {
        // `.unknown` because this is neither an email address nor a phone
        // number, and claiming either would invite iOS to match it against
        // Contacts — which could put somebody's saved contact photo on a
        // stranger's dating profile.
        let handle = INPersonHandle(value: id, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: name,
            image: image,
            contactIdentifier: nil,
            // Stable across notifications, so several messages from one person
            // group together rather than reading as several strangers.
            customIdentifier: id
        )

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            // The conversation for a message; the category otherwise, so likes
            // and matches do not collapse into a thread that does not exist.
            conversationIdentifier: (info["thread"] as? String) ?? (info["category"] as? String),
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        if let image { intent.setImage(image, forParameterNamed: \.sender) }

        let interaction = INInteraction(intent: intent, response: nil)
        // **Incoming, not outgoing.** The default is outgoing, and that would
        // teach the system that *you* messaged them — filling Siri's suggestions
        // with people who have only ever messaged you.
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        // Fails on an intent the system rejects. The unmodified content is still
        // a working notification, so this falls back rather than dropping it.
        return (try? content.updating(from: intent)) ?? content
    }

    /// iOS is about to give up waiting.
    ///
    /// Delivering the plain content here is what stops a slow image download
    /// costing somebody the notification entirely.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let pending {
            contentHandler(pending)
        }
    }
}
