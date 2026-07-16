import SwiftUI

struct EmptyStatePage: View {
    let route: DashboardRoute

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: route.icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.blue)
                .frame(width: 84, height: 84)
                .background(.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 22))

            VStack(spacing: 8) {
                Text(route.title)
                    .font(.title3.weight(.semibold))
                Text(route.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Text("当前页面暂无可展示的数据")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(route.title)，当前页面暂无可展示的数据")
    }
}
