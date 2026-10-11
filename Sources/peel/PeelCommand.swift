import Foundation
import PeelCore

// A development harness for PeelCore. It keeps the mnemonic in a plain file so
// it can run unattended, which is only acceptable for throwaway accounts.

@main
struct PeelCommand {
    static let usage = """
        usage: peel [options] <command>

          init                        new account with no invite (local test server; needs --server)
          signup <invite|->           new account from an invite link ("-" reads it from stdin)
          restore                     existing account; reads the twelve words from stdin
          whoami                      this account's contact info, balance, name and photo
          rename <name>               the name others see on messages sent from now on
          upload-photo <picture>      upload a picture to the memes server and make it this account's photo
          prefs                       every preference stored: its key, chat, value as the preferences file
                                      holds it, when it was chosen, and whether it follows the account
          pref <name> [value]         read or set one: \(Invocation.prefNames)
                                      (the boost amount is boost-amount, a chat's time zone switch
                                      share-timezone)
          contacts                    contacts known to the core
          add <code|picture> [name]   start a key exchange with someone: their contact info, a
                                      sphinx.chat share_contact link, an invite (adds its inviter), or a
                                      picture with one of those in a QR code
          contact-delete <pubkey>     remove a contact: their chat here and on the server; they can be
                                      added again (refused while a payment with them is on its way)
          scan <picture>              the QR codes in a picture and what each one is
          invite <sats>               make an invite with sats for someone new and print it (--nickname
                                      <name>, --message <text>, kept here only; always asks: --yes)
          invites                     invites waiting to be used
          invite-cancel <code>        cancel an invite and get its sats back (code from invites)
          send <pubkey> <text>        send a text message to a contact or a tribe
                                      (--reply <uuid> answers a message, --thread <uuid> posts in its thread)
          listen                      stay connected, reconnecting as needed, and print what arrives
          messages <pubkey>           a chat's main conversation, as the app shows it: row ids, uuids,
                                      delivery, quoted parents and collapsed threads
          thread <pubkey> <uuid>      one thread: its original and its messages
          threads                     threads (tribes and contacts) this account started or wrote in, newest first
          resend <id>                 send an undelivered message again (a failed payment: --yes over
                                      the confirmation threshold)
          discard <id>                drop an undelivered message
          delete <id>                 delete a message for everyone (yours, or any in a tribe you own)
          unread                      unread counts and mute levels by chat
          read <pubkey>               mark a chat read up to its newest message (offline: sent on the next connect)
          mark-unread <pubkey> [index]  mark a chat unread from a message (server index), else from its
                                      newest incoming message
          mute <pubkey> <0|1|2>       notify for all, mentions only, or nothing
          local-time <pubkey> [alias] a contact's local time, or a tribe member's by alias, from the
                                      offset they last sent (within 90 days)
          share-timezone <pubkey> [yes|no]  whether this account's offset goes with what it sends in a
                                      direct message or private tribe (on unless turned off; never in
                                      a public tribe); sets it when given
          send-file <pubkey> <path>...  send files to a contact or a tribe, one message each (--text <caption>
                                      on the last, --reply, --thread, --price <sats> to sell them: buyers pay
                                      to get the key)
          buy <id>                    buy someone's paid attachment (row id from messages; --yes over the
                                      confirmation threshold); it then downloads like any other
          download <id> <out path>    download and decrypt an attachment to a new file (never opened)

          tribes                      tribes this account is in
          tribe-join <link>           join from a sphinx.chat://?action=tribeV2 link, paying its price to
                                      join (--yes over the confirmation threshold)
          tribe-members <pubkey>      a tribe's members (the full list only for its owner)
          tribe-leave <pubkey>        leave a tribe
          tribe-create <name>         create a tribe owned by this account on its tribes server
          tribe-edit <pubkey>         change a tribe this account owns; options left out stay as they are
                                      (both take --name (edit), --description, --image <https url>,
                                      --price-per-message, --price-to-join, --escrow in sats,
                                      --escrow-hours, --private <yes|no>, --unlisted <yes|no>,
                                      --tags <Bitcoin,Tech,...> ("" for none))
          tribe-info <pubkey>         a tribe's details from its registry: owner, created, members, prices, tags
          tribe-alias <pubkey> [name|-] [https photo url|-]
                                      how this account appears in one tribe ("-" for the account's own;
                                      left out keeps what is set)
          tribe-delete <pubkey>       delete a tribe this account owns
          tribe-approve <pubkey> <request-uuid | member-pubkey [alias]>
          tribe-reject <pubkey> <request-uuid | member-pubkey [alias]>
                                      answer a request to join a private tribe this account owns
          tribe-kick <pubkey> <member-pubkey>   remove a member from a tribe this account owns
          tribe-pin <pubkey> <uuid|-> pin a message in a tribe this account owns ("-" unpins)
          mentions                    tribe messages that mention this account

          boost <id> [sats]           boost someone else's message (row id from messages); in a tribe the
                                      tribe's price per message and escrow are added; without an
                                      amount, the one-tap boost with the account's boost amount,
                                      sent with no confirmation, as in the official apps (one set on
                                      another device and over the threshold takes --yes once)
          pay <pubkey> <sats>         send sats to a contact in their chat (--text <note>)
                                      (both refuse more than the balance, and over the confirmation
                                      threshold without --yes)
          boost-amount [sats]         what a one-tap boost tips (default 100 sats); sets it when given (--yes over the threshold)
          payments [pubkey]           payments and boosts, in one chat or all, newest first
          history [pages]             fetch the server's payment history (50 rows a page, newest first) and
                                      print it joined to chats, notes and invoices
          invoice <sats> [memo]       make an invoice to receive sats; stays online --wait seconds to settle it
          decode <invoice>            what an invoice asks for, and whether this account paid it
          pay-invoice <invoice>       pay an invoice (--yes over the confirmation threshold); refuses expired,
                                      already paid or pending, own, and over the balance less a fee reserve
          request <pubkey> <sats> [memo]  ask a contact for sats in their chat (an invoice message)
          pay-request <id>            pay someone's request in a chat (row id from messages; --yes as above)

          call-start <pubkey>         start a video call in a contact's chat or a tribe and print its link
                                      (--audio for an audio call)
          call-ticket <id|link>       ask the call server for a ticket to join a call: prints the media server,
                                      room, identity, expiry and whether a token came (never the token)
          call-who <id|link>          who is on a call, from the call server's presence feed, for --wait seconds

        options:
          --profile <name>    which development account to use (required; under Peel/dev,
                              never the app's own profile)
          --server <host:port>  override the server (init, signup, restore; later runs reuse it)
          --network <bitcoin|regtest>   for init, signup and restore
          --alias <name>      the name others see (default: the profile name)
          --photo <https url> the photo others see beside this account's messages ("" for none)
          --wait <seconds>    how long to stay connected after a command (default: 5)
          --insecure          accept an untrusted TLS certificate
          --tribe-host <host:port>  the account's tribes server (init, signup and restore take it from
                              the config otherwise; later runs reuse it)
          --memes-host <host:port>  the account's memes server for attachments (default
                              memes.sphinx.chat; later runs reuse it)
          --call-server <host:port>  the account's call server (default chat.sphinx.chat, none on a
                              local test server; later runs reuse it)
        """

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        umask(0o077)
        do {
            try await run()
        } catch {
            let hint = switch error as? Engine.Failure {
            case .noMemesServer?: " (set one with --memes-host)"
            case .noCallServer?: " (set one with --call-server)"
            default: ""
            }
            FileHandle.standardError.write(Data("error: \(PeelError.readable(error))\(hint)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var arguments = Arguments(CommandLine.arguments.dropFirst())
        // The app's own profile holds the real account; the CLI only ever opens
        // development profiles, and never one called "default" so the two cannot be confused.
        guard let name = arguments.option("--profile"), name.lowercased() != "default" else {
            throw PeelError("pass --profile <name> for a development account; \"default\" is reserved for the app")
        }
        var invocation = try Invocation(profile: Profile(name: name, kind: .development), arguments: arguments)
        guard let command = invocation.arguments.next() else {
            print(usage)
            return
        }
        if try await invocation.account(command) { return }
        if try await invocation.contacts(command) { return }
        if try await invocation.chat(command) { return }
        if try await invocation.tribes(command) { return }
        if try await invocation.money(command) { return }
        if try await invocation.calls(command) { return }
        throw PeelError("unknown command \(command)\n\(usage)")
    }
}

/// One run of the command: the options it was given and the arguments left
/// after the command's name. The commands are its methods, by area, in
/// `Commands+*.swift`.
struct Invocation {
    var arguments: Arguments
    let profile: Profile
    let server: ServerAddress?
    let network: String
    let alias: String
    let photo: String?
    let wait: Int
    let insecure: Bool
    let tribeHost: String?
    let tribeOptions: TribeOptions
    let replyTo: String?
    let inThread: String?
    let memesHost: String?
    let note: String?
    let confirmed: Bool
    let priceOption: String?
    let callServer: String?
    let audioOnly: Bool
    let nickname: String?
    let inviteMessage: String?

    /// Takes the options out of `arguments`, in this order; what is left is
    /// the command and its own arguments.
    init(profile: Profile, arguments: Arguments) throws {
        var arguments = arguments
        self.profile = profile
        server = try arguments.option("--server").map { text in
            guard let address = ServerAddress(text) else { throw PeelError("cannot read server address \(text)") }
            return address
        }
        network = arguments.option("--network") ?? "bitcoin"
        alias = arguments.option("--alias") ?? profile.name
        photo = arguments.option("--photo")
        wait = arguments.option("--wait").flatMap { Int($0) } ?? 5
        insecure = arguments.flag("--insecure")
        tribeHost = arguments.option("--tribe-host")
        tribeOptions = try TribeOptions(&arguments)
        replyTo = arguments.option("--reply")
        inThread = arguments.option("--thread")
        memesHost = arguments.option("--memes-host")
        note = arguments.option("--text")
        confirmed = arguments.flag("--yes")
        priceOption = arguments.option("--price")
        callServer = arguments.option("--call-server")
        audioOnly = arguments.flag("--audio")
        nickname = arguments.option("--nickname")
        inviteMessage = arguments.option("--message")
        self.arguments = arguments
    }

    func withPhoto(_ engine: Engine) async throws -> Engine {
        if let photo { try await engine.setPhotoURL(photo) }
        if let callServer { try await engine.setCallServer(callServer) }
        return engine
    }
    func load() async throws -> Engine {
        try await withPhoto(Account.load(profile, server: server, tribeHost: tribeHost, memesHost: memesHost))
    }

    /// The profile's storage, read-only, for commands that only print what is stored.
    func readOnlyStorage() throws -> Storage {
        try Storage(directory: profile.directory, readOnly: true)
    }
}

/// A payment over the confirmation threshold: with `--yes`, sent again for
/// the amount the engine names (and printed); without, the refusal stands.
@discardableResult
func confirming<T>(_ yes: Bool, _ send: (UInt64?) async throws -> T) async throws -> T {
    do {
        return try await send(nil)
    } catch Engine.Failure.needsConfirmation(let msat) where yes {
        print("confirmed \(Sats.format(msat: msat)) (\(msat) msat)")
        return try await send(msat)
    }
}

func yesNo(_ text: String) throws -> Bool {
    switch text {
    case "yes": true
    case "no": false
    default: throw PeelError("expected yes or no, not \(text)")
    }
}

struct Arguments {
    private var items: [String]

    init(_ items: some Sequence<String>) { self.items = Array(items) }

    var isEmpty: Bool { items.isEmpty }

    mutating func next() -> String? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func rest() -> [String] {
        defer { items = [] }
        return items
    }

    mutating func option(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        defer { items.removeSubrange(index...index + 1) }
        return items[index + 1]
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }
}
