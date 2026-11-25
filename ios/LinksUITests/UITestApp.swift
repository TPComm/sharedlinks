import CoreFoundation
import XCTest

/// XCTest relaunches and opens URLs by terminating and re-finding the app's process, which a slow CI
/// Simulator fails at: "Failed to terminate com.tpcomm.links" and "does not have a process ID", a
/// different test each run. Debug builds of Links listen for these Darwin notifications instead
/// (LinksApp.init), so no test leaves XCTest a running process to terminate or re-find.
extension XCUIApplication {
    /// Has Links exit on its own, so the next launch() has nothing to terminate.
    func quit() {
        guard state != .notRunning else { return }
        postDarwinNotification("com.tpcomm.links.ui-test-quit")
        if !wait(for: .notRunning, timeout: 10) { terminate() }
    }

    /// Set before launch(): the URLs openInApp(_:) can open in this launch.
    func prepareToOpen(_ urls: [URL]) {
        var routes = [String: String]()
        for url in urls { routes["com.tpcomm.links.open-url.\(UUID().uuidString)"] = url.absoluteString }
        launchEnvironment["LINKS_TEST_OPEN_URLS"] = String(decoding: try! JSONEncoder().encode(routes), as: UTF8.self)
    }

    /// What open(_:) does for a URL the app handles, without XCTest relaunching the app.
    func openInApp(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let routes = launchEnvironment["LINKS_TEST_OPEN_URLS"]
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        guard let name = routes.first(where: { $0.value == url.absoluteString })?.key else {
            return XCTFail("\(url) wasn't passed to prepareToOpen before launch", file: file, line: line)
        }
        postDarwinNotification(name)
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(rawValue: name as CFString), nil, nil, true)
    }
}
