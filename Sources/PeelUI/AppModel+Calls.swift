import Foundation
import PeelCore

/// What a call shows of the account: people's faces and the chat's title.
/// The calls themselves are `CallStore`'s (`calls`).
extension AppModel {
    /// Someone on a call: their name ("Guest" when they sent none) and
    /// photo as they sent them, a hue keyed as for a tribe member, and you
    /// as yourself.
    public func avatar(of person: CallParticipant) -> Sender {
        avatar(
            fromMe: person.identity == calls.call?.identity, alias: person.nickname.isEmpty ? String(localized: "Guest", table: "Shared") : person.nickname,
            photoURL: person.avatarURL?.absoluteString, chat: person.identity, inTribe: true
        )
    }

    /// Where a call started in `chat` brings Jamie from: the org or box
    /// picked there (a box while Peel is linked to it), else the tribe's
    /// own org (its `app_url`'s swarm), else none (`HivePeer.jamie`,
    /// docs/hive-calls.md).
    public func callJamie(in chat: String) -> CallJamie? {
        let tribe = tribes[chat]
        // Per-chat pick (""=no Jamie, nil=unset) wins; otherwise the tribe-level default.
        let picked = calls.jamiePicks[chat] ?? calls.tribeOrgs[chat]
        if let picked, case .box(let url) = JamieSource(id: picked) {
            return boxes.links.first { $0.url.absoluteString == url }.map(CallJamie.box)
        }
        return HivePeer.jamie(
            picked: picked, pages: [tribe?.appURL, tribe?.secondBrainURL], in: stadeum.live
        ).map(CallJamie.org)
    }

    /// Asks the server side to take Jamie out of the call in `room`, in
    /// `chat`. Answers whether Hive did (an org's Jamie); a box's Jamie is
    /// not Hive's to remove, so there is nothing to ask and the caller
    /// asks Jamie itself (`CallChatWire.leave`). Throws when Hive refuses.
    public func removeJamie(room: String, in chat: String) async throws -> Bool {
        if case .box = callJamie(in: chat) { return false }
        try await stadeum.removeJamie(room: room)
        return true
    }

    /// Whether a call in `chat` may record on the canvas: its Jamie is a
    /// box's, and the box does not say it can't (`BoxCalls.records`).
    public func offersRecording(in chat: String) -> Bool {
        guard case .box(let box) = callJamie(in: chat) else { return false }
        return boxes.records(on: box)
    }

    /// What a chat's call menu offers to bring Jamie from: each Stadeum
    /// org in use, then each box Peel is linked to whose Jamie can join a
    /// call on this account's call server (`BoxCalls.joins`), and the one
    /// picked in `chat` even while it cannot, so the menu says what is true.
    public func callJamies(in chat: String) -> [CallJamie] {
        let picked = callJamie(in: chat)
        let boxes = boxes.links.filter { box in
            self.boxes.calls[box.url]?.joins(callServer: calls.server) == true || picked == .box(box)
        }
        return stadeum.live.map(CallJamie.org) + boxes.map(CallJamie.box)
    }

    /// A call's Jamie as the menu names it: an org's name, a box's host
    /// (with its path beside another box on the same host).
    public func name(of jamie: CallJamie) -> String {
        switch jamie {
        case .org(let peer): peer.name
        case .box(let box): JamieChoices(orgs: nil, boxes: boxes.links).name(of: box)
        }
    }

    /// Reads again what each box says of its group calls, unless read in
    /// the last minute: as a chat that may start a call opens, so its menu
    /// offers the boxes ready then.
    public func readCallBoxes() async {
        await boxes.readCalls(ifOlderThan: 60)
    }

    /// "#tribe" or the contact's name, for the call window.
    public func chatTitle(_ chat: String) -> String {
        conversations.first { $0.chat == chat }?.title ?? String(localized: "Call", table: "Shared")
    }
}
