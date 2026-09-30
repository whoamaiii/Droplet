import Foundation

/// Construct, rather than filter, the child environment. Inherited proxy,
/// certificate, Python, loader, plugin and config overrides cannot change the
/// downloader's policy. Browser access still needs the real, controlled HOME.
enum EngineProcessEnvironment {
    static func make(home: URL, temporary: URL, engine: URL, ffmpeg: URL) -> [String: String] {
        let paths = [engine.deletingLastPathComponent().path, ffmpeg.path,
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return [
            "HOME": home.path,
            "TMPDIR": temporary.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1"
        ]
    }
}
