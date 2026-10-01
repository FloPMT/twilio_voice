import Contacts
import Foundation

/// Finds the phone contact saved with an incoming E.164 number.
///
/// Numbers saved with a country code ("+", "00" or "011") must match exactly. Numbers saved
/// without one match if the incoming number has one of the configured calling codes, with or
/// without the national trunk prefix (e.g. "0171 2345678" for "+49 171 2345678").
/// Keep in sync with TVContactLookup.kt.
enum ContactNameLookup {
    private static let kCallingCodes = "ContactLookupCallingCodes"

    static var callingCodes: [String] {
        get { UserDefaults.standard.stringArray(forKey: kCallingCodes) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: kCallingCodes) }
    }

    static var hasAccess: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            return true
        }
        if #available(iOS 18.0, *) {
            return status == .limited
        }
        return false
    }

    /// Blocks while reading the contacts, call off the main thread.
    static func name(for number: String) -> String? {
        guard number.hasPrefix("+"), hasAccess else { return nil }
        let store = CNContactStore()
        let codes = callingCodes
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let isMatch: (CNContact) -> Bool = { contact in
            displayName(of: contact) != nil && contact.phoneNumbers.contains { phoneNumber in
                matches(stored: phoneNumber.value.stringValue, incoming: number, callingCodes: codes)
            }
        }

        // Fast path: the Contacts framework's own matching, then confirm with our rules.
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        if let candidates = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
           let contact = candidates.first(where: isMatch) {
            return displayName(of: contact)
        }

        // It only knows the phone's region, so check the user's other countries as well.
        var match: CNContact?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, stop in
            if isMatch(contact) {
                match = contact
                stop.pointee = true
            }
        }
        return match.flatMap(displayName(of:))
    }

    static func matches(stored: String, incoming: String, callingCodes: [String]) -> Bool {
        let incomingDigits = digits(incoming)
        // "+49 (0)171 ..." is a common way to write the trunk prefix next to the country code
        let trimmed = stored.replacingOccurrences(of: "(0)", with: "").trimmingCharacters(in: .whitespaces)
        let storedDigits = digits(trimmed)
        guard !incomingDigits.isEmpty, !storedDigits.isEmpty else { return false }

        if trimmed.hasPrefix("+") {
            return storedDigits == incomingDigits
        }
        if storedDigits.hasPrefix("00") && String(storedDigits.dropFirst(2)) == incomingDigits {
            return true
        }
        if storedDigits.hasPrefix("011") && String(storedDigits.dropFirst(3)) == incomingDigits {
            return true
        }
        for code in callingCodes where !code.isEmpty && incomingDigits.hasPrefix(code) {
            let national = String(incomingDigits.dropFirst(code.count))
            if !national.isEmpty && (storedDigits == national || storedDigits == trunkPrefix(code) + national) {
                return true
            }
        }
        return false
    }

    private static func trunkPrefix(_ callingCode: String) -> String {
        switch callingCode {
        case "1": return "1"
        case "7", "370", "375": return "8"
        case "36": return "06"
        default: return "0"
        }
    }

    private static func digits(_ value: String) -> String {
        return value.filter { $0.isASCII && $0.isNumber }
    }

    private static func displayName(of contact: CNContact) -> String? {
        let name = CNContactFormatter.string(from: contact, style: .fullName)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty {
            return name
        }
        let organization = contact.organizationName.trimmingCharacters(in: .whitespaces)
        return organization.isEmpty ? nil : organization
    }
}
