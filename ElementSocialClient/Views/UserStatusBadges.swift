import SwiftUI

struct UserStatusBadges: View {
    let isVerified: Bool
    let hasGold: Bool
    let size: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            if isVerified {
                Image("Verify")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: size, height: size)
            }
            if hasGold {
                Image("Star")
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}
