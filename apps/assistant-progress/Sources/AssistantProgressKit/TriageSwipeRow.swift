/// A reversible horizontal pull with a short hold arms Add or Ignore. Only
/// release commits; vertical scrolling and cancelled drags never submit.
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct TriageSwipeRow<Content: View>: View {
    let isWorking: Bool
    let background: Color
    let accept: () -> Void
    let ignore: () -> Void
    let content: Content
    @State private var offset: CGFloat = 0
    @State private var armedDirection = 0
    @State private var pendingDirection = 0
    @State private var hold: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public init(isWorking: Bool, background: Color, accept: @escaping () -> Void,
                ignore: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isWorking = isWorking
        self.background = background
        self.accept = accept
        self.ignore = ignore
        self.content = content()
    }

    public var body: some View {
        ZStack {
            HStack {
                cue(direction: 1)
                Spacer()
                cue(direction: -1)
            }
            .padding(.horizontal, 16)
            .background(offset >= 0 ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .opacity(offset == 0 ? 0 : 1)
            .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .offset(x: offset)
                .allowsHitTesting(offset == 0 && !isWorking)
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else {
                        reset()
                        return
                    }
                    pull(value.translation.width)
                }
                .onEnded { _ in release() }
        )
        .accessibilityAction(named: "Add to Todos", accept)
        .accessibilityAction(named: "Ignore", ignore)
        .onChange(of: isWorking) { _, _ in reset() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { reset() } }
        .onDisappear { reset() }
        #if os(macOS)
        .overlay {
            TodoRowMenu(primaryTitle: "Add to Todos", primaryEnabled: !isWorking,
                        ignoreEnabled: !isWorking, primary: accept, ignore: ignore,
                        scrollChanged: { delta in pull(offset + delta) },
                        scrollEnded: { cancelled in if cancelled { reset() } else { release() } })
        }
        #endif
    }

    private func cue(direction: Int) -> some View {
        let armed = armedDirection == direction
        return Label(armed ? (direction > 0 ? "Release to add" : "Release to ignore")
                           : (direction > 0 ? "Add" : "Ignore"),
                     systemImage: direction > 0 ? "plus.circle.fill" : "hand.thumbsdown.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(direction > 0 ? Color.green : Color.orange)
            .frame(maxHeight: .infinity)
    }

    private func pull(_ translation: CGFloat) {
        guard !isWorking else { return }
        offset = min(180, max(-180, translation))
        let direction = abs(offset) >= 104 ? (offset > 0 ? 1 : -1) : 0
        guard direction != pendingDirection else { return }
        hold?.cancel()
        armedDirection = 0
        pendingDirection = direction
        guard direction != 0 else { return }
        hold = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard !Task.isCancelled, pendingDirection == direction, !isWorking else { return }
            armedDirection = direction
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            #elseif os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            #endif
        }
    }

    private func release() {
        let direction = armedDirection
        reset()
        guard !isWorking else { return }
        if direction > 0 { accept() }
        if direction < 0 { ignore() }
    }

    private func reset() {
        hold?.cancel()
        hold = nil
        pendingDirection = 0
        armedDirection = 0
        withAnimation(reduceMotion ? nil : .default) { offset = 0 }
    }
}
