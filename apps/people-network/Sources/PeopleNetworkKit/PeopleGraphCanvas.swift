/// A bounded two-dimensional explorer with native, accessible person buttons.
/// Drawing happens on interaction; there is no animation timer or force simulation.
import SwiftUI

struct PeopleGraphCanvas: View {
    let network: PeopleNetworkData.Network
    let selectedID: String?
    let select: (String) -> Void
    let inspect: (PeopleNetworkData.Edge) -> Void
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var layout: [String: CGPoint] = [:]
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Solid: your communication · Dashed: shared context")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Zoom", systemImage: "plus.magnifyingglass") {
                    Button("Zoom in") { zoom = min(zoom * 1.3, 4) }
                    Button("Zoom out") { zoom = max(zoom / 1.3, 0.5) }
                    Button("Fit network") { zoom = 1; offset = .zero }
                }
            }
            .padding(8)
            Divider()
            GeometryReader { geometry in
                let points = positions(in: geometry.size)
                ZStack {
                    Canvas { context, _ in
                        for edge in network.edges {
                            guard let a = points[edge.from], let b = points[edge.to] else { continue }
                            var line = Path()
                            line.move(to: a)
                            line.addLine(to: b)
                            let highlighted = edge.from == selectedID || edge.to == selectedID
                            context.stroke(line, with: .color(highlighted ? .accentColor : .secondary.opacity(0.3)),
                                           style: StrokeStyle(lineWidth: highlighted ? 2 : 1,
                                                              dash: edge.kind == "direct" ? [] : [4, 4]))
                        }
                    }
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let edge = nearestEdge(to: tap.location, points: points) { inspect(edge) }
                    })

                    Text("You").font(.caption.weight(.semibold))
                        .padding(8).background(.background, in: Circle())
                        .overlay(Circle().stroke(.secondary.opacity(0.4)))
                        .position(points["you"] ?? .zero)
                        .accessibilityLabel("You, center of your communication network")

                    ForEach(network.nodes) { node in
                        Button { select(node.id) } label: {
                            VStack(spacing: 4) {
                                Text(node.initials).font(.caption.weight(.semibold))
                                    .frame(width: diameter(node), height: diameter(node))
                                    .background(node.id == selectedID ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06), in: Circle())
                                    .overlay(Circle().stroke(node.id == selectedID ? Color.accentColor : Color.secondary.opacity(0.4)))
                                if node.id == selectedID || node.rank > 40 || zoom > 1.5 {
                                    Text(node.name).font(.caption).lineLimit(1).frame(maxWidth: 112)
                                        .padding(.horizontal, 4).background(.background.opacity(0.9))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(node.name), \(node.activeDays) active days")
                        .accessibilityAddTraits(node.id == selectedID ? .isSelected : [])
                        .help(node.name)
                        .position(points[node.id] ?? .zero)
                    }
                }
                .clipped()
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    })
                .simultaneousGesture(MagnificationGesture()
                    .updating($magnification) { value, state, _ in state = value }
                    .onEnded { zoom = min(max(zoom * $0, 0.5), 4) })
            }
        }
        .onChange(of: network.nodes.map { "\($0.id):\($0.x):\($0.y)" }, initial: true) { _, _ in
            layout = PeopleGraphLayout.positions(network.nodes)
        }
    }

    private func diameter(_ person: PeopleNetworkData.Person) -> CGFloat {
        28 + CGFloat(sqrt(max(person.rank, 0))) * 1.6
    }

    private func positions(in size: CGSize) -> [String: CGPoint] {
        let scale = min(size.width, size.height) * 0.4 * min(max(zoom * magnification, 0.5), 4)
        let center = CGPoint(x: size.width / 2 + offset.width + drag.width,
                             y: size.height / 2 + offset.height + drag.height)
        var result = ["you": center]
        for node in network.nodes {
            let point = layout[node.id] ?? CGPoint(x: node.x, y: node.y)
            result[node.id] = CGPoint(x: center.x + point.x * scale, y: center.y + point.y * scale)
        }
        return result
    }

    private func nearestEdge(to point: CGPoint, points: [String: CGPoint]) -> PeopleNetworkData.Edge? {
        var nearest: (PeopleNetworkData.Edge, CGFloat)?
        for edge in network.edges {
            guard let a = points[edge.from], let b = points[edge.to] else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            guard length > 0 else { continue }
            let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / length, 0), 1)
            let distance = hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
            if distance < 8 && distance < (nearest?.1 ?? .infinity) { nearest = (edge, distance) }
        }
        return nearest?.0
    }
}
