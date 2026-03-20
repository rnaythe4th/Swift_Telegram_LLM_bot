import Foundation

struct UserInputContent: Sendable {
    var text: String?
    var attachments: [ResolvedMedia]
    
    init(text: String? = nil, attachments: [ResolvedMedia] = []) {
        self.text = text
        self.attachments = attachments
    }
}
