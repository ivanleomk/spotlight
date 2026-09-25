import SwiftUI

// A small rounded key, like the ↩ hints in Raycast's footer.
struct KeyCap: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 20)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

// The panel's frosted, nearly solid background. Raycast keeps it opaque enough
// that whatever is behind never competes with the text, so we use a thick
// material rather than the very see-through Liquid Glass.
struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thickMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
    }
}

extension View {
    func panelBackground(cornerRadius: CGFloat) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}
