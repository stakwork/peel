import Foundation
import Testing
@testable import PeelCore

struct WebTests {
    @Test(arguments: [
        "https://example.com/a.png", "https://memes.sphinx.chat/public/x", "HTTPS://Example.COM/a.png",
        "https://example.com./a.png", "https://localhost.example.com/a.png",
    ])
    func publicHostsAreFetched(string: String) throws {
        #expect(Web.isPublic(try #require(URL(string: string))))
    }

    @Test(arguments: [
        // not https, or credentials
        "http://example.com/a.png", "ftp://example.com/a.png", "file:///etc/hosts", "https://user:pw@example.com/a.png",
        // this machine
        "https://localhost/a.png", "https://localhost./a.png", "https://app.localhost/a.png", "https://127.0.0.1/a.png",
        "https://127.1/a.png", "https://2130706433/a.png", "https://0x7f000001/a.png", "https://0.0.0.0/a.png",
        "https://[::1]/a.png", "https://[::]/a.png", "https://[::ffff:127.0.0.1]/a.png",
        // this network
        "https://10.0.0.1/a.png", "https://172.16.0.1/a.png", "https://172.31.255.255/a.png", "https://192.168.1.1/a.png",
        "https://169.254.169.254/latest/meta-data", "https://100.64.0.1/a.png", "https://[fe80::1]/a.png",
        "https://[fd00::1]/a.png", "https://[::ffff:192.168.1.1]/a.png", "https://224.0.0.1/a.png",
        "https://255.255.255.255/a.png", "https://[fec0::1]/a.png", "https://[2002:c0a8:101::1]/a.png",
        // any IP address, public or not
        "https://8.8.8.8/a.png", "https://[2606:4700::1111]/a.png",
        // names only this network resolves
        "https://printer.local/a.png", "https://router/a.png", "https://nas.home.arpa/a.png", "https://box.internal/a.png", "https://localhost%00.com/a.png",
    ])
    func privateOrInsecureURLsAreRefused(string: String) throws {
        #expect(!Web.isPublic(try #require(URL(string: string))))
    }

    @Test func redirectsStayOnPublicHTTPS() throws {
        let original = URLRequest(url: try #require(URL(string: "https://example.com/a.png")))
        let elsewhere = URLRequest(url: try #require(URL(string: "https://cdn.example.net/a.png")))
        #expect(Web.publicOnly(elsewhere, from: original) == elsewhere)
        for target in ["http://example.com/a.png", "https://192.168.1.1/a.png", "https://localhost/a.png"] {
            #expect(Web.publicOnly(URLRequest(url: try #require(URL(string: target))), from: original) == nil)
        }
    }

    @Test func refusedPhotoIsNotFetched() async throws {
        #expect(try await Web.photo(at: try #require(URL(string: "https://127.0.0.1/a.png"))) == nil)
    }

    @Test(arguments: ["192.168.1.1", "10.0.0.1:8811", "router.local"])
    func tribesRegistryOnThisNetworkIsRefused(host: String) async {
        await #expect(throws: PeelError.self) { try await TribeInfo.record(pubkey: "02ab", host: host) }
    }
}
