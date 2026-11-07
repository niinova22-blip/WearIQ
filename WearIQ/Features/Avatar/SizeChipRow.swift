import SwiftUI

/// The sizes to try on, as a row of chips that scrolls sideways. A segmented control
/// squeezed jeans' 18 waist/length sizes ("31/32") down to "…"; chips keep every label
/// whole and bring the chosen one into view.
struct SizeChipRow: View {
    let labels: [String]
    @Binding var selection: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(labels, id: \.self) { label in
                        FilterChip(title: label, selected: label == selection) {
                            withAnimation(.snappy) { selection = label }
                        }
                        .id(label)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { withAnimation { proxy.scrollTo(selection, anchor: .center) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Size"))
    }
}
