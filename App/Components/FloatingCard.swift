import SwiftUI
import CloakKit

/// The one card that floats at the bottom of the map.
///
/// A card exists only while there is something to show. It is one surface: a
/// title with an optional line under it, content that sizes to itself and
/// scrolls inside past the room it is given, and an optional action bar. It
/// ends where its content ends. There is no second header stacked on top and
/// nothing drawn under the home indicator.
///
/// A collapsible card can be shrunk to its header, so the map and the route
/// show through, and opened again. It matches the running card: a chevron in
/// the header, and a tap or a drag on the header, toggle it. The footer, the
/// one that carries Build or Start, stays visible when the body hides.
struct FloatingCard<Accessory: View, Content: View, Footer: View>: View {
    /// Nil for a card with no header, like search.
    var title: String?
    var subtitle: String?
    var collapsible: Bool = false
    var onClose: (() -> Void)?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                header(title)
            }

            if !(collapsible && collapsed) {
                CardScroll(topPadding: title == nil ? CardMetrics.padding : Metrics.hair) {
                    content
                }
                .transition(.opacity)
            }

            footer
        }
        .frame(maxWidth: .infinity)
        .cardSurface()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        #if DEBUG
        .onAppear {
            // Lets a screenshot open straight into the collapsed state.
            if collapsible, ProcessInfo.processInfo.environment["CLOAK_TOUR_COLLAPSE"] == "1" {
                collapsed = true
            }
        }
        #endif
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        if collapsible {
            CardHeader(
                title: title,
                subtitle: subtitle,
                collapsed: collapsed,
                onToggleCollapse: { toggleCollapse() },
                onClose: onClose
            ) { accessory }
            .modifier(CollapseDrag(enabled: true, collapsed: collapsed, toggle: toggleCollapse))
        } else {
            CardHeader(title: title, subtitle: subtitle, onClose: onClose) { accessory }
        }
    }

    private func toggleCollapse() {
        if reduceMotion {
            collapsed.toggle()
        } else {
            withAnimation(.snappy(duration: 0.3)) { collapsed.toggle() }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}

extension FloatingCard where Accessory == EmptyView {
    init(title: String?, subtitle: String? = nil, collapsible: Bool = false, onClose: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(title: title, subtitle: subtitle, collapsible: collapsible, onClose: onClose, accessory: { EmptyView() }, content: content, footer: footer)
    }
}

extension FloatingCard where Accessory == EmptyView, Footer == EmptyView {
    init(title: String?, subtitle: String? = nil, collapsible: Bool = false, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, collapsible: collapsible, onClose: onClose, accessory: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

extension FloatingCard where Footer == EmptyView {
    init(title: String?, subtitle: String? = nil, collapsible: Bool = false, onClose: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, collapsible: collapsible, onClose: onClose, accessory: accessory, content: content, footer: { EmptyView() })
    }
}

/// The drag on a collapsible card's header: up opens it, down shrinks it, the
/// same feel as the running card. A tap on the header still toggles it, and a
/// drag under the threshold does nothing, so the header's own buttons keep
/// working.
private struct CollapseDrag: ViewModifier {
    let enabled: Bool
    let collapsed: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onEnded { value in
                            let up = value.translation.height < -24
                            let down = value.translation.height > 24
                            if (up && collapsed) || (down && !collapsed) { toggle() }
                        }
                )
        } else {
            content
        }
    }
}

/// A card's title row: the title and an optional quiet line under it, then any
/// accessory, an optional collapse chevron, then the close button.
struct CardHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    /// Nil on a card that does not collapse. Otherwise the current state, with
    /// `onToggleCollapse` set, which draws the chevron and makes the title a
    /// button.
    var collapsed: Bool? = nil
    var onToggleCollapse: (() -> Void)? = nil
    var onClose: (() -> Void)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Metrics.hair) {
            titleArea
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory
            if let collapsed, let onToggleCollapse {
                Button(action: onToggleCollapse) {
                    CollapseChevron(collapsed: collapsed)
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel(collapsed ? "Expand" : "Collapse")
            }
            if let onClose {
                Button(action: onClose) {
                    CardHeaderGlyph(symbol: "xmark")
                }
                .buttonStyle(PressableStyle(scale: 0.9))
                .accessibilityLabel("Close")
            }
        }
        .padding(.leading, CardMetrics.padding + 2)
        .padding(.trailing, Metrics.tight)
        .padding(.top, Metrics.tight)
        .padding(.bottom, Metrics.hair)
    }

    @ViewBuilder
    private var titleArea: some View {
        if let onToggleCollapse {
            Button(action: onToggleCollapse) { titleLabel }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(collapsed == true ? "Expands the card" : "Collapses the card to see the map")
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// The disclosure chevron in a collapsible card's header. A 30 point grey
/// circle inside a 44 point target, matching the close X, that flips as the
/// card opens and shuts.
struct CollapseChevron: View {
    let collapsed: Bool

    var body: some View {
        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
            .font(.footnote.weight(.bold))
            .foregroundStyle(Color(.secondaryLabel))
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.12), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Content that is as tall as itself and no taller, gives up height when the
/// card is offered less, and scrolls past that.
struct CardScroll<Content: View>: View {
    var topPadding: CGFloat = Metrics.hair
    var bottomPadding: CGFloat = CardMetrics.padding
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, CardMetrics.padding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .frame(minHeight: 0, idealHeight: contentHeight, maxHeight: contentHeight)
    }
}

/// The bar under a card's scrolling content: one wide primary action, and
/// optionally a square secondary one beside it.
struct CardActionBar<Primary: View, Secondary: View>: View {
    var status: String?
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        VStack(spacing: Metrics.tight) {
            if let status {
                HStack(spacing: Metrics.tight) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: Metrics.tight) {
                primary
                secondary
            }
        }
        .padding(.horizontal, CardMetrics.padding)
        .padding(.top, Metrics.hair)
        .padding(.bottom, CardMetrics.padding)
    }
}

/// What every tool card is handed by the map.
struct CardContext {
    var onClose: () -> Void
}
