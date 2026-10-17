import AppKit
import SwiftUI

/// Ask before the main window disappears, so Cancel can actually keep it open.
/// Forward SwiftUI's other window delegate callbacks to its original delegate.
struct EditorWindowCloseGuard: NSViewRepresentable {
    var model: EditorModel
    var approved: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, approved: approved) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.attached = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: HookView, context: Context) {
        context.coordinator.model = model
        context.coordinator.approved = approved
        context.coordinator.attach(view.window)
    }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }
    final class HookView: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var model: EditorModel?
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        var approved: () -> Void
        init(model: EditorModel, approved: @escaping () -> Void) { self.model = model; self.approved = approved }
        func attach(_ target: NSWindow?) {
            guard target !== window else { return }
            detach()
            window = target; original = target?.delegate
            target?.delegate = self
            DispatchQueue.main.async { [weak model,weak target] in
                model?.editorWindow=target;model?.offerRecovery()
            }
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = original }
            window = nil; original = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.makeFirstResponder(nil)
            guard model?.confirmUnsavedChanges() != false else { return false }
            approved()
            return true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}
