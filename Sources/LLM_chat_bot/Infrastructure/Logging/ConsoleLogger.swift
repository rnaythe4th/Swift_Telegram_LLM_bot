import Foundation

struct ConsoleLogger: LoggerPort {
    func info(_ message: String) {
        print("[INFO] \(message)")
    }
    
    func warning(_ message: String) {
        print("[WARN] \(message)")
    }
    
    func error(_ message: String) {
        print("[ERROR] \(message)")
    }
}
