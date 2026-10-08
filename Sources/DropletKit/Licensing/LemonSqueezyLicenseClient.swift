import Foundation

/// Lemon Squeezy's public License API (activate, validate, deactivate). It
/// needs no API secret, so nothing administrative is shipped in the app. Only
/// the key, an instance name/ID and this request reach the provider; video
/// URLs and cookies never do.
struct LemonSqueezyLicenseClient: LicenseClient {
    static let providerID = "lemonsqueezy"
    let transport: any HTTPTransport
    var endpoint = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!
    /// Shown in the seller's dashboard next to the activation. Deliberately
    /// generic: the Mac's name would identify the customer's computer.
    var instanceName = "Droplet for Mac"

    func activate(key: String) async throws -> LicenseEvidence {
        let response = try await send("activate", ["license_key": key, "instance_name": instanceName], flag: "activated")
        do { return try evidence(from: response) } catch {
            // The provider counted an activation this app cannot use; release it.
            if let id = response.instance?.id, !id.isEmpty {
                try? await deactivate(key: key, instance: LicenseInstance(instanceID: id))
            }
            throw error
        }
    }

    func validate(key: String, instance: LicenseInstance) async throws -> LicenseEvidence {
        let response = try await send("validate", ["license_key": key, "instance_id": instance.instanceID], flag: "valid")
        return try evidence(from: response)
    }

    func deactivate(key: String, instance: LicenseInstance) async throws {
        _ = try await send("deactivate", ["license_key": key, "instance_id": instance.instanceID], flag: "deactivated")
    }

    // MARK: wire format

    struct Response: Decodable {
        let activated: Bool?
        let valid: Bool?
        let deactivated: Bool?
        let error: String?
        let licenseKey: Key?
        let instance: Instance?
        let meta: Meta?

        struct Key: Decodable {
            let status: String?
            let expiresAt: String?
        }
        struct Instance: Decodable { let id: String }
        struct Meta: Decodable {
            let storeId: FlexibleID?
            let productId: FlexibleID?
            let variantId: FlexibleID?
        }

        func flag(_ name: String) -> Bool? {
            switch name {
            case "activated": return activated
            case "valid": return valid
            case "deactivated": return deactivated
            default: return nil
            }
        }
    }

    /// The API documents numeric IDs; accept strings too rather than fail.
    struct FlexibleID: Decodable, Equatable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) { value = String(number) }
            else { value = try container.decode(String.self) }
        }
    }

    static func decode(_ data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw LicenseError.invalidResponse }
    }

    /// 2xx with the operation's flag true is success. A 4xx JSON body that
    /// explicitly reports the flag as false is the provider's authoritative
    /// refusal (unknown key, activation limit, disabled key, missing instance).
    /// Rate limits, server errors and anything unparseable stay transient.
    static func interpret(_ response: HTTPResponse, flag: String) throws -> Response {
        let status = response.statusCode
        if (200..<300).contains(status) {
            try LicenseEvidenceValidator.requireSuccessfulResponse(response)
            let body = try decode(response.data)
            guard body.flag(flag) == true else { throw LicenseError.rejected(body.error) }
            return body
        }
        if (400..<500).contains(status), status != 408, status != 429,
           !response.data.isEmpty, response.data.count <= 1_048_576,
           let body = try? decode(response.data), body.flag(flag) == false {
            throw LicenseError.rejected(body.error)
        }
        throw LicenseError.unexpectedHTTPStatus(status)
    }

    private func send(_ operation: String, _ fields: [String: String], flag: String) async throws -> Response {
        var request = URLRequest(url: endpoint.appendingPathComponent(operation), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        return try Self.interpret(try await transport.send(request), flag: flag)
    }

    static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }

    func evidence(from response: Response) throws -> LicenseEvidence {
        guard let meta = response.meta, let store = meta.storeId?.value, let product = meta.productId?.value,
              let instance = response.instance?.id else { throw LicenseError.invalidResponse }
        let status: LicenseEvidence.Status = response.licenseKey?.status == "active" ? .active : .rejected
        var expiry: Date?
        if let raw = response.licenseKey?.expiresAt {
            guard let parsed = Self.parseDate(raw) else { throw LicenseError.invalidResponse }
            expiry = parsed
        }
        return LicenseEvidence(
            product: LicenseProduct(providerID: Self.providerID, storeID: store, productID: product,
                                    variantID: meta.variantId?.value ?? ""),
            instance: LicenseInstance(instanceID: instance), status: status, expiresAt: expiry)
    }

    /// ISO 8601 with optional fractional seconds of any length
    /// ("2026-01-24T14:15:07.000000Z").
    static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let fractionEnd = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            text.removeSubrange(dot..<fractionEnd)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
