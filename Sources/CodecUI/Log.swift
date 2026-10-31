import os

enum Log {
    static let app = Logger(subsystem: "com.srozen.codec", category: "app")
    static let pane = Logger(subsystem: "com.srozen.codec", category: "pane")
}
