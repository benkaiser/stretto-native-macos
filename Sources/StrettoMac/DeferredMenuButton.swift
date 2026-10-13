import AppKit
import SwiftUI

struct DeferredMenuButton: NSViewRepresentable {
    var label: String
    var makeMenu: () -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(makeMenu: makeMenu) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.makeMenu = makeMenu
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @MainActor
    final class Coordinator: NSObject {
        var makeMenu: () -> NSMenu
        init(makeMenu: @escaping () -> NSMenu) { self.makeMenu = makeMenu }

        @objc func openMenu(_ sender: NSButton) {
            makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }
}

extension NSMenu {
    @MainActor
    func addAction(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        autoenablesItems = false
        let handler = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invokeAction), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        item.isEnabled = enabled
        addItem(item)
    }
}

@MainActor
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeAction() { action() }
}
