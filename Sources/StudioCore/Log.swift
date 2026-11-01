import os

/// One `Logger` per subsystem area; filter in Console.app with `subsystem:com.local.livewallpaper`.
public enum Log {
    private static let subsystem = "com.local.livewallpaper"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let download = Logger(subsystem: subsystem, category: "download")
}
