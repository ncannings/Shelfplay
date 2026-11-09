import SwiftUI

enum Theme {
    static let background = Color(red: 0.047, green: 0.039, blue: 0.035)   // #0c0a09
    static let surface = Color(red: 0.110, green: 0.098, blue: 0.090)      // #1c1917
    static let surfaceRaised = Color(red: 0.161, green: 0.145, blue: 0.141) // #292524
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)        // #f59e0b
    static let amberDeep = Color(red: 0.851, green: 0.467, blue: 0.024)    // #d97706
    static let textSecondary = Color(red: 0.659, green: 0.635, blue: 0.620) // #a8a29e

    static let amberGradient = LinearGradient(colors: [amber, amberDeep], startPoint: .top, endPoint: .bottom)
}

struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        Text("ShelfPlay")
            .font(.system(size: size, weight: .bold, design: .serif).italic())
            .foregroundStyle(Theme.amberGradient)
    }
}

struct CoverArt: View {
    let url: URL?
    var cornerRadius: CGFloat = 10

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Theme.surfaceRaised
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
