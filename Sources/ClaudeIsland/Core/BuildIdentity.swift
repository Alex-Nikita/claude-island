import Foundation
import Security

// Identity of the running binary's code signature (its CDHash) — the same
// identity macOS binds keychain "Always Allow" grants to. Consent stored
// against this hash is exactly as durable as the grant itself: a rebuild
// changes both, an unchanged app keeps both.
enum BuildIdentity {
    static func currentCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let hash = dict[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
