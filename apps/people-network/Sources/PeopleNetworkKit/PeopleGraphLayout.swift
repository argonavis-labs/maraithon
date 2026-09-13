/// Static collision relaxation for the bounded visible graph.
/// It runs once per node-set change, never while panning, zooming, or drawing.
import Foundation

enum PeopleGraphLayout {
    static func positions(_ people: [PeopleNetworkData.Person]) -> [String: CGPoint] {
        let ids = ["you"] + people.map(\.id)
        var points = [CGPoint.zero] + people.map { CGPoint(x: $0.x, y: $0.y) }
        for _ in 0..<40 {
            for i in points.indices {
                for j in points.indices where j > i {
                    let dx = points[j].x - points[i].x
                    let dy = points[j].y - points[i].y
                    let distance = max(hypot(dx, dy), 0.001)
                    guard distance < 0.2 else { continue }
                    let push = (0.2 - distance) * 0.2
                    let x = (dx == 0 ? 0.001 : dx) / distance * push
                    let y = (dy == 0 ? 0.001 : dy) / distance * push
                    if i != 0 { points[i].x -= x; points[i].y -= y }
                    points[j].x += x; points[j].y += y
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(ids, points))
    }
}
