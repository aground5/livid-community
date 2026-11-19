import Foundation

extension String {
    func deletingPathExtension() -> String {
        (self as NSString).deletingPathExtension
    }
}
