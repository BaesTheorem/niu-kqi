import Foundation
import CryptoKit

/// NIU cloud client: the few calls this app needs, ported from `niu_cloud.py`.
///
/// The overseas region is the "-fk" host pair. Every reply is
/// `{status, desc, data}` and a non-zero status is an error, including on HTTP 200.
actor NIUCloud {
    static let shared = NIUCloud()

    private let accountHost = "https://account-fk.niu.com/"
    private let apiHost = "https://app-api-fk.niu.com/"
    private let appIDs = ["niu_8xt1afu6", "niu_ktdrr960"]

    /// The app identifies as the Android client; the API is picky about the shape
    /// of this string. The timezone here does NOT drive the ride-date bug: the
    /// backend buckets days in its own zone regardless of what we claim.
    private var userAgent: String {
        "manager/5.12.2 (android; Pixel 8 14);lang=en-US;clientIdentifier=Overseas;"
        + "timezone=\(TimeZone.current.identifier);model=google_Pixel 8;deviceName=Pixel 8;ostype=android"
    }

    struct CloudError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private func request(_ method: String, _ url: URL, token: String?,
                         form: [String: String]? = nil, json: [String: Any]? = nil) async throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "X-No-Encrypt")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue(token, forHTTPHeaderField: "token") }
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        } else if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError(msg: "non-JSON reply from \(url.lastPathComponent)")
        }
        let status = (obj["status"] as? Int) ?? 0
        guard status == 0 else {
            throw CloudError(msg: (obj["desc"] as? String) ?? "cloud error \(status)")
        }
        return obj["data"] ?? [:]
    }

    // MARK: - auth

    struct Session: Codable {
        var account: String
        var appID: String
        var token: String
        var refreshToken: String
        var expiresAt: Date
    }

    func login(account: String, password: String) async throws -> Session {
        let md5 = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        var last: Error = CloudError(msg: "login failed")
        for aid in appIDs {
            do {
                let data = try await request("POST", URL(string: accountHost + "v3/api/oauth2/token")!,
                    token: nil,
                    form: ["account": account, "password": md5, "grant_type": "password",
                           "scope": "base", "app_id": aid])
                guard let d = data as? [String: Any], let tok = d["token"] as? [String: Any],
                      let access = tok["access_token"] as? String, !access.isEmpty else {
                    last = CloudError(msg: "login reply had no token"); continue
                }
                let ttl = (tok["token_expires_in"] as? Double) ?? 0
                return Session(account: account, appID: aid, token: access,
                               refreshToken: (tok["refresh_token"] as? String) ?? "",
                               expiresAt: Date().addingTimeInterval(ttl))
            } catch { last = error }
        }
        throw last
    }

    func refresh(_ s: Session) async throws -> Session {
        let data = try await request("POST", URL(string: accountHost + "v3/api/oauth2/token")!,
            token: nil,
            form: ["refresh_token": s.refreshToken, "grant_type": "refresh_token",
                   "scope": "base", "app_id": s.appID])
        guard let d = data as? [String: Any], let tok = d["token"] as? [String: Any],
              let access = tok["access_token"] as? String else {
            throw CloudError(msg: "refresh reply had no token")
        }
        var out = s
        out.token = access
        out.refreshToken = (tok["refresh_token"] as? String) ?? s.refreshToken
        out.expiresAt = Date().addingTimeInterval((tok["token_expires_in"] as? Double) ?? 0)
        return out
    }

    // MARK: - vehicle

    func scooters(token: String) async throws -> [Scooter] {
        let data = try await request("GET", URL(string: apiHost + "v5/scooter/list")!, token: token)
        let items: [Any]
        if let arr = data as? [Any] { items = arr }
        else if let d = data as? [String: Any] { items = (d["items"] as? [Any]) ?? (d["list"] as? [Any]) ?? [] }
        else { items = [] }
        let raw = try JSONSerialization.data(withJSONObject: items)
        return (try? JSONDecoder().decode([Scooter].self, from: raw)) ?? []
    }

    struct BLEInfo: Codable {
        let bleMac: String?
        let bleName: String?
        let blePassword: String?
        let bleAes: String?
        let bleSign: String?
    }

    /// The BLE credentials for a scooter, by serial. This is what lets an iPhone
    /// talk to the scooter at all: CoreBluetooth hides MAC addresses, so the
    /// macOS-only MAC discovery the CLI uses is not available here.
    func bleInfo(token: String, sn: String) async throws -> BLEInfo {
        var c = URLComponents(string: apiHost + "v5/ble/bleinfo")!
        c.queryItems = [URLQueryItem(name: "sn", value: sn)]
        let data = try await request("GET", c.url!, token: token)
        let raw = try JSONSerialization.data(withJSONObject: data)
        return try JSONDecoder().decode(BLEInfo.self, from: raw)
    }

    func detail(token: String, sn: String) async throws -> [String: Any] {
        let data = try await request("GET", URL(string: apiHost + "v5/scooter/detail/" + sn)!, token: token)
        return (data as? [String: Any]) ?? [:]
    }

    // MARK: - rides

    /// One page of rides. `index` is a 1-based page number the server insists on
    /// receiving as a *string* while `pagesize` must be a number; sending both as
    /// the same type fails parameter validation. v3 is the endpoint that answers
    /// for kick scooters (v2 accepts the call but always returns an empty list).
    func rides(token: String, sn: String, page: Int, pageSize: Int = 20) async throws -> [Ride] {
        let data = try await request("POST", URL(string: apiHost + "v5/track/list/v3")!, token: token,
                                     json: ["sn": sn, "pagesize": pageSize, "index": String(page)])
        guard let d = data as? [String: Any], let items = d["items"] as? [Any] else { return [] }
        let raw = try JSONSerialization.data(withJSONObject: items)
        return (try? JSONDecoder().decode([Ride].self, from: raw)) ?? []
    }

    /// Every ride, walking pages until one comes back empty.
    func allRides(token: String, sn: String, maxPages: Int = 50) async throws -> [Ride] {
        var out: [Ride] = []
        var seen = Set<String>()
        for p in 1...maxPages {
            let batch = try await rides(token: token, sn: sn, page: p)
            let fresh = batch.filter { !seen.contains($0.trackId) }
            if fresh.isEmpty { break }
            fresh.forEach { seen.insert($0.trackId) }
            out += fresh
        }
        return out.sorted { $0.startTime > $1.startTime }
    }

    // MARK: - firmware

    static let otaDeviceTypes = ["FOC", "DB", "BMS", "LCU", "ECU_BT"]

    func firmware(token: String, sn: String) async throws -> [[String: Any]] {
        let devices = Self.otaDeviceTypes.map {
            ["devicetype": $0, "soft_version": "0.0.0", "hard_version": "0.0.0"]
        }
        let data = try await request("POST", URL(string: apiHost + "v5/ota/checkupdate")!, token: token,
                                     json: ["sn": sn, "devices": devices])
        return ((data as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    }
}
