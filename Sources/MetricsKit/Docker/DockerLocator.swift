import CryptoKit
import Foundation

/// Finds the Docker Engine socket and decides whether Docker is installed at all.
/// All inputs are injectable so tests never look at the real file system.
///
/// A menu bar app launched from Finder or as a login item does **not** inherit the shell's
/// environment, so `DOCKER_HOST` set in `.zshrc` is invisible to it. The Docker CLI's own
/// configuration (the current context) and each runtime's well-known socket path are what
/// make discovery work for a GUI app.
public enum DockerLocator {
    /// First existing socket, in this order:
    /// 1. `$DOCKER_HOST`, only `unix://` (TCP hosts are ignored: the client speaks unix sockets only).
    /// 2. The Docker CLI context: `$DOCKER_CONTEXT`, else `currentContext` from
    ///    `<config>/config.json` (`<config>` = `$DOCKER_CONFIG` or `~/.docker`), resolved via
    ///    `<config>/contexts/meta/<sha256(name)>/meta.json` → `Endpoints.docker.Host` (unix only).
    ///    The `default` context has no meta file and means "the default socket", i.e. step 3.
    /// 3. Known runtime sockets: Docker Desktop, OrbStack, Colima (two layouts), Rancher
    ///    Desktop, then `/var/run/docker.sock`.
    ///
    /// - Parameters:
    ///   - readFile: Returns a file's contents or `nil`; only the two small Docker CLI JSON
    ///     files are read. Malformed files are ignored, never fatal.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                  readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) },
                                  home: String = NSHomeDirectory()) -> String? {
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], let path = unixPath(host) { candidates.append(path) }
        if let path = contextSocket(environment: environment, readFile: readFile, home: home) { candidates.append(path) }
        candidates += knownSockets(home: home)
        return candidates.first(where: fileExists)
    }

    /// `true` if a socket exists or a known Docker distribution is installed. Distinguishes
    /// "Docker çalışmıyor" (show the card) from "not installed" (hide the card).
    public static func isInstalled(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                   readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) },
                                   home: String = NSHomeDirectory()) -> Bool {
        socketPath(environment: environment, fileExists: fileExists, readFile: readFile, home: home) != nil
            || ["/Applications/Docker.app", "\(home)/Applications/Docker.app", "/Applications/OrbStack.app",
                "/Applications/Rancher Desktop.app", "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                "/usr/local/bin/colima", "/opt/homebrew/bin/colima"]
                .contains(where: fileExists)
    }

    /// Directory name the Docker CLI uses for a context: lowercase hex SHA-256 of the name.
    /// Hashing also means a context name can never act as a path component (no `../`).
    static func contextDirectoryName(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func knownSockets(home: String) -> [String] {
        ["\(home)/.docker/run/docker.sock",          // Docker Desktop 4.13+
         "\(home)/.orbstack/run/docker.sock",        // OrbStack
         "\(home)/.colima/default/docker.sock",      // Colima, profile "default"
         "\(home)/.colima/docker.sock",              // Colima, older layout
         "\(home)/.rd/docker.sock",                  // Rancher Desktop (moby engine)
         "/var/run/docker.sock"]
    }

    private static func unixPath(_ host: String) -> String? {
        host.hasPrefix("unix://") ? String(host.dropFirst(7)) : nil
    }

    private struct CLIConfig: Decodable { let currentContext: String? }
    private struct ContextMeta: Decodable {
        struct Endpoint: Decodable { let Host: String? }
        let Endpoints: [String: Endpoint]?
    }

    private static func contextSocket(environment: [String: String], readFile: (String) -> Data?, home: String) -> String? {
        let configDir = environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.docker"
        let name = environment["DOCKER_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? readFile("\(configDir)/config.json").flatMap { try? JSONDecoder().decode(CLIConfig.self, from: $0) }?.currentContext
        guard let name, !name.isEmpty, name != "default" else { return nil }
        let metaPath = "\(configDir)/contexts/meta/\(contextDirectoryName(name))/meta.json"
        guard let data = readFile(metaPath),
              let meta = try? JSONDecoder().decode(ContextMeta.self, from: data),
              let host = meta.Endpoints?["docker"]?.Host else { return nil }
        return unixPath(host)
    }
}
