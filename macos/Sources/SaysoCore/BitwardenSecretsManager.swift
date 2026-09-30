import Foundation

public enum BitwardenSecretsManager {
    static let accessTokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".secrets/bws-access-token", isDirectory: false)

    private struct Secret: Decodable {
        let key: String
        let value: String
    }

    public static func typeSafeKey() async -> String? {
        await Task.detached(priority: .userInitiated) {
            loadTypeSafeKey()
        }.value
    }

    static func typeSafeKey(from data: Data) -> String? {
        guard let secrets = try? JSONDecoder().decode([Secret].self, from: data) else { return nil }
        return secrets.first { $0.key == "TYPESAFE_API_KEY" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func accessToken(from data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func loadTypeSafeKey() -> String? {
        let executablePaths = ["/opt/homebrew/bin/bws", "/usr/local/bin/bws"]
        guard let executable = executablePaths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        guard let tokenData = try? Data(contentsOf: accessTokenURL),
              let accessToken = accessToken(from: tokenData) else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["secret", "list", "--output", "json"]
        var environment = ProcessInfo.processInfo.environment
        environment["BWS_ACCESS_TOKEN"] = accessToken
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return typeSafeKey(from: data)
        } catch {
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
