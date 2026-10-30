import Foundation
import PeelPush
import Sphinxrs

/// The core's `decryptChildIndex`, for the notification extension.
public struct SphinxChildDecryptor: ChildIndexDecrypting {
    public init() {}

    public func decrypt(child: String, pushKey: String) throws -> UInt64 {
        try decryptChildIndex(encryptedChild: child, pushKey: pushKey)
    }
}
