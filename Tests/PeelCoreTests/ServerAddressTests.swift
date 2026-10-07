import Testing
@testable import PeelCore

struct ServerAddressTests {
    @Test func tlsByDefault() throws {
        let address = try #require(ServerAddress("broker.example.com:8883"))
        #expect(address.host == "broker.example.com")
        #expect(address.port == 8883)
        #expect(address.tls)
    }

    @Test(arguments: ["127.0.0.1:1883", "localhost:1883"])
    func loopbackIsPlaintext(string: String) throws {
        #expect(try #require(ServerAddress(string)).tls == false)
    }

    @Test(arguments: ["mqtt://broker.example.com:1883", "tcp://broker.example.com:1883", "MQTT://broker.example.com:1883"])
    func plaintextSchemes(string: String) throws {
        #expect(try #require(ServerAddress(string)).tls == false)
    }

    @Test(arguments: ["mqtts://127.0.0.1:8883", "ssl://localhost:8883", "tls://broker.example.com:8883"])
    func tlsSchemes(string: String) throws {
        #expect(try #require(ServerAddress(string)).tls)
    }

    @Test func trimsWhitespace() throws {
        #expect(try #require(ServerAddress("  broker.example.com:8883\n")).host == "broker.example.com")
    }

    @Test(arguments: [
        "", "broker.example.com", ":8883", "broker.example.com:", "broker.example.com:port",
        "http://broker.example.com:8883", "a:b:c",
    ])
    func rejectsMalformed(string: String) {
        #expect(ServerAddress(string) == nil)
    }

    @Test(arguments: ["broker.example.com:8883", "mqtt://broker.example.com:1883", "127.0.0.1:1883"])
    func descriptionRoundTrips(string: String) throws {
        let address = try #require(ServerAddress(string))
        #expect(ServerAddress(address.description) == address)
    }

    // `init` splits on every colon, so an IPv6 host never parses and the "::1"
    // entry in its loopback list is unreachable.
    @Test func ipv6LoopbackParses() {
        withKnownIssue("ServerAddress cannot parse IPv6 hosts") {
            let address = try #require(ServerAddress("[::1]:1883"))
            #expect(address.tls == false)
        }
    }
}
