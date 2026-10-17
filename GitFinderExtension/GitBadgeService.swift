import Foundation
import OSLog

/// Finder Sync extensions are sandboxed. Git status is therefore calculated
/// by the host app and exchanged through the existing shared preference domain.
final class GitBadgeService: @unchecked Sendable {
    private static let preferenceDomain = "jp.local.gitoperation"
    private static let requestKey = "pendingBadgePaths"
    private static let cacheKey = "gitBadgeStatusCache"
    private static let directoryRequestKey = "pendingBadgeDirectories"
    private static let directoryCacheKey = "gitBadgeDirectoryCache"

    private let logger = Logger(subsystem: "jp.local.gitoperation.finderextension", category: "GitBadgeService")
    private let queue = DispatchQueue(label: "jp.local.gitoperation.badges", qos: .utility)

    func badgeStatus(
        for itemURL: URL,
        completion: @escaping @MainActor @Sendable (GitBadgeStatus?) -> Void
    ) {
        let path = itemURL.standardizedFileURL.path
        let requestID = UUID().uuidString
        queue.async { [self] in
            // Show the last known state immediately. Scanning a repository on
            // an external or network volume can take longer than Finder waits
            // before redrawing an item.
            if let cached = cachedStatus(for: path) {
                complete(cached, using: completion)
            }
            enqueue(path, requestID: requestID)
            pollCache(for: path, requestID: requestID, attemptsRemaining: 60, completion: completion)
        }
    }

    func badgeStatuses(
        in directoryURL: URL,
        completion: @escaping @MainActor @Sendable ([URL: GitBadgeStatus]) -> Void
    ) {
        let path = directoryURL.standardizedFileURL.path
        let requestID = UUID().uuidString
        queue.async { [self] in
            // Gallery and large folders should not remain blank while a fresh
            // Git snapshot is being produced. Publish the previous directory
            // snapshot first, then publish the refreshed result below.
            if let cached = cachedDirectoryStatuses(for: path) {
                DispatchQueue.main.async { completion(cached) }
            }
            let domain = Self.preferenceDomain as CFString
            CFPreferencesAppSynchronize(domain)
            var requests = CFPreferencesCopyAppValue(Self.directoryRequestKey as CFString, domain)
                as? [String: String] ?? [:]
            requests[path] = requestID
            CFPreferencesSetAppValue(Self.directoryRequestKey as CFString, requests as CFDictionary, domain)
            CFPreferencesAppSynchronize(domain)
            pollDirectoryCache(
                for: path,
                requestID: requestID,
                attemptsRemaining: 60,
                completion: completion
            )
        }
    }

    private func enqueue(_ path: String, requestID: String) {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        var requests = CFPreferencesCopyAppValue(Self.requestKey as CFString, domain) as? [String: String] ?? [:]
        requests[path] = requestID
        CFPreferencesSetAppValue(Self.requestKey as CFString, requests as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private func pollCache(
        for path: String,
        requestID: String,
        attemptsRemaining: Int,
        completion: @escaping @MainActor @Sendable (GitBadgeStatus?) -> Void
    ) {
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            if let status = cachedStatus(for: path, requestID: requestID) {
                complete(status, using: completion)
            } else if attemptsRemaining > 1 {
                pollCache(
                    for: path,
                    requestID: requestID,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            } else {
                logger.error("Host app did not return a badge for \(path, privacy: .public)")
                complete(nil, using: completion)
            }
        }
    }

    private func cachedStatus(for path: String, requestID: String) -> GitBadgeStatus? {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        let cache = CFPreferencesCopyAppValue(Self.cacheKey as CFString, domain) as? [String: String]
        guard let value = cache?[path], value.hasPrefix(requestID + "\t") else { return nil }
        return GitBadgeStatus(rawValue: String(value.dropFirst(requestID.count + 1)))
    }

    private func cachedStatus(for path: String) -> GitBadgeStatus? {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        let cache = CFPreferencesCopyAppValue(Self.cacheKey as CFString, domain) as? [String: String]
        guard let value = cache?[path], let separator = value.firstIndex(of: "\t") else { return nil }
        return GitBadgeStatus(rawValue: String(value[value.index(after: separator)...]))
    }

    private func cachedDirectoryStatuses(for path: String) -> [URL: GitBadgeStatus]? {
        let domain = Self.preferenceDomain as CFString
        CFPreferencesAppSynchronize(domain)
        let cache = CFPreferencesCopyAppValue(Self.directoryCacheKey as CFString, domain)
            as? [String: [String: String]]
        guard let values = cache?[path] else { return nil }
        return decodeDirectoryStatuses(values)
    }

    private func decodeDirectoryStatuses(_ values: [String: String]) -> [URL: GitBadgeStatus] {
        var result: [URL: GitBadgeStatus] = [:]
        for (itemPath, rawValue) in values where itemPath != "__requestID" {
            if let status = GitBadgeStatus(rawValue: rawValue) {
                result[URL(fileURLWithPath: itemPath)] = status
            }
        }
        return result
    }

    private func pollDirectoryCache(
        for path: String,
        requestID: String,
        attemptsRemaining: Int,
        completion: @escaping @MainActor @Sendable ([URL: GitBadgeStatus]) -> Void
    ) {
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            let domain = Self.preferenceDomain as CFString
            CFPreferencesAppSynchronize(domain)
            let cache = CFPreferencesCopyAppValue(Self.directoryCacheKey as CFString, domain)
                as? [String: [String: String]]
            if let values = cache?[path], values["__requestID"] == requestID {
                let result = decodeDirectoryStatuses(values)
                DispatchQueue.main.async { completion(result) }
            } else if attemptsRemaining > 1 {
                pollDirectoryCache(
                    for: path,
                    requestID: requestID,
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            } else {
                logger.error("Host app did not return directory badges for \(path, privacy: .public)")
                DispatchQueue.main.async { completion([:]) }
            }
        }
    }

    private func complete(
        _ status: GitBadgeStatus?,
        using completion: @escaping @MainActor @Sendable (GitBadgeStatus?) -> Void
    ) {
        DispatchQueue.main.async { completion(status) }
    }
}
