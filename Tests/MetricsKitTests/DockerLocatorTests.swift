import Testing
import Foundation
@testable import MetricsKit

struct DockerLocatorTests {
    let noFiles: (String) -> Data? = { _ in nil }

    func locate(_ env: [String: String] = [:], existing: Set<String>, files: [String: String] = [:]) -> String? {
        DockerLocator.socketPath(environment: env, fileExists: { existing.contains($0) },
                                 readFile: { files[$0].map { Data($0.utf8) } }, home: "/Users/x")
    }

    @Test func prefersDockerHostUnixSocket() {
        #expect(locate(["DOCKER_HOST": "unix:///custom/docker.sock"],
                       existing: ["/custom/docker.sock", "/var/run/docker.sock"]) == "/custom/docker.sock")
    }
    @Test func ignoresTcpDockerHostAndFallsBack() {
        #expect(locate(["DOCKER_HOST": "tcp://1.2.3.4:2375"], existing: ["/Users/x/.docker/run/docker.sock"])
                == "/Users/x/.docker/run/docker.sock")
    }
    @Test func fallsBackToVarRun() {
        #expect(locate(existing: ["/var/run/docker.sock"]) == "/var/run/docker.sock")
    }
    @Test func noneFound() {
        #expect(locate(existing: []) == nil)
    }
    @Test func installedWhenAppPresentEvenWithoutSocket() {
        #expect(DockerLocator.isInstalled(environment: [:], fileExists: { $0 == "/Applications/Docker.app" },
                                          readFile: noFiles, home: "/Users/x"))
        #expect(!DockerLocator.isInstalled(environment: [:], fileExists: { _ in false }, readFile: noFiles, home: "/Users/x"))
    }
    @Test(arguments: ["/Applications/OrbStack.app", "/Applications/Rancher Desktop.app", "/opt/homebrew/bin/colima"])
    func installedForOtherRuntimes(_ marker: String) {
        #expect(DockerLocator.isInstalled(environment: [:], fileExists: { $0 == marker }, readFile: noFiles, home: "/Users/x"))
    }

    // MARK: - Known runtime sockets (GUI apps do not inherit the shell's DOCKER_HOST)

    @Test(arguments: [
        "/Users/x/.docker/run/docker.sock",       // Docker Desktop 4.13+
        "/Users/x/.orbstack/run/docker.sock",     // OrbStack
        "/Users/x/.colima/default/docker.sock",   // Colima (profile "default")
        "/Users/x/.colima/docker.sock",           // Colima (older layout)
        "/Users/x/.rd/docker.sock",               // Rancher Desktop
        "/var/run/docker.sock",                   // legacy symlink / Linux-style installs
    ])
    func findsEachKnownRuntimeSocket(_ socket: String) {
        #expect(locate(existing: [socket]) == socket)
    }
    @Test func knownSocketOrderPrefersDockerDesktopOverVarRun() {
        #expect(locate(existing: ["/var/run/docker.sock", "/Users/x/.orbstack/run/docker.sock"])
                == "/Users/x/.orbstack/run/docker.sock")
    }

    // MARK: - Docker CLI context

    /// `docker context use colima` writes `currentContext` to config.json; the endpoint lives in
    /// `contexts/meta/<sha256(name)>/meta.json`. The hash below is sha256("desktop-linux"),
    /// checked against this machine's real `~/.docker/contexts/meta` directory name.
    static let desktopLinuxHash = "fe9c6bd7a66301f49ca9b6a70b217107cd1284598bfc254700c989b916da791e"

    @Test func contextDirectoryIsSHA256OfName() {
        #expect(DockerLocator.contextDirectoryName("desktop-linux") == Self.desktopLinuxHash)
    }
    @Test func currentContextEndpointWinsOverKnownSockets() {
        let meta = "/Users/x/.docker/contexts/meta/\(Self.desktopLinuxHash)/meta.json"
        let files = ["/Users/x/.docker/config.json": #"{"auths":{},"currentContext":"desktop-linux"}"#,
                     meta: #"{"Name":"desktop-linux","Metadata":{"Description":"Docker Desktop"},"Endpoints":{"docker":{"Host":"unix:///Users/x/custom/ctx.sock","SkipTLSVerify":false}}}"#]
        #expect(locate(existing: ["/Users/x/custom/ctx.sock", "/var/run/docker.sock"], files: files) == "/Users/x/custom/ctx.sock")
    }
    @Test func dockerContextEnvironmentOverridesConfigFile() {
        let colima = DockerLocator.contextDirectoryName("colima")
        let files = ["/Users/x/.docker/config.json": #"{"currentContext":"desktop-linux"}"#,
                     "/Users/x/.docker/contexts/meta/\(colima)/meta.json":
                        #"{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///Users/x/.colima/default/docker.sock"}}}"#]
        #expect(locate(["DOCKER_CONTEXT": "colima"], existing: ["/Users/x/.colima/default/docker.sock", "/Users/x/.docker/run/docker.sock"],
                       files: files) == "/Users/x/.colima/default/docker.sock")
    }
    @Test func dockerConfigEnvironmentRelocatesConfigDirectory() {
        let files = ["/cfg/config.json": #"{"currentContext":"desktop-linux"}"#,
                     "/cfg/contexts/meta/\(Self.desktopLinuxHash)/meta.json":
                        #"{"Endpoints":{"docker":{"Host":"unix:///elsewhere.sock"}}}"#]
        #expect(locate(["DOCKER_CONFIG": "/cfg"], existing: ["/elsewhere.sock"], files: files) == "/elsewhere.sock")
    }
    @Test func tcpContextOrMissingMetaFallsBackToKnownSockets() {
        let files = ["/Users/x/.docker/config.json": #"{"currentContext":"remote"}"#,
                     "/Users/x/.docker/contexts/meta/\(DockerLocator.contextDirectoryName("remote"))/meta.json":
                        #"{"Endpoints":{"docker":{"Host":"tcp://10.0.0.1:2376"}}}"#]
        #expect(locate(existing: ["/var/run/docker.sock"], files: files) == "/var/run/docker.sock")
        #expect(locate(existing: ["/var/run/docker.sock"],
                       files: ["/Users/x/.docker/config.json": #"{"currentContext":"gone"}"#]) == "/var/run/docker.sock")
    }
    @Test func defaultContextOrGarbageConfigIsIgnored() {
        #expect(locate(existing: ["/var/run/docker.sock"],
                       files: ["/Users/x/.docker/config.json": #"{"currentContext":"default"}"#]) == "/var/run/docker.sock")
        #expect(locate(existing: ["/var/run/docker.sock"],
                       files: ["/Users/x/.docker/config.json": "not json"]) == "/var/run/docker.sock")
    }
    /// A context name is hashed, never used as a path component, so `../` cannot escape.
    @Test func contextNameCannotTraverse() {
        let name = "../../../../etc"
        #expect(DockerLocator.contextDirectoryName(name).allSatisfy { $0.isHexDigit })
    }
}
