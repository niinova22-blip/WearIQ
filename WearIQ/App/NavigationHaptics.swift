import ObjectiveC
import UIKit

/// A light tap on every navigation push and pop (including the back button and the
/// swipe-back gesture), like Apple's own apps. SwiftUI owns the navigation
/// controllers, so this hooks `UINavigationController` once at launch.
enum NavigationHaptics {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        swap(#selector(UINavigationController.pushViewController(_:animated:)),
             #selector(UINavigationController.wq_pushViewController(_:animated:)))
        swap(#selector(UINavigationController.popViewController(animated:)),
             #selector(UINavigationController.wq_popViewController(animated:)))
    }

    private static func swap(_ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(UINavigationController.self, a),
              let m2 = class_getInstanceMethod(UINavigationController.self, b) else { return }
        method_exchangeImplementations(m1, m2)
    }

    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred(intensity: 0.7)
    }
}

extension UINavigationController {
    @objc func wq_pushViewController(_ viewController: UIViewController, animated: Bool) {
        if animated, !viewControllers.isEmpty { NavigationHaptics.tap() }
        wq_pushViewController(viewController, animated: animated)  // original implementation
    }

    @objc func wq_popViewController(animated: Bool) -> UIViewController? {
        if animated { NavigationHaptics.tap() }
        return wq_popViewController(animated: animated)  // original implementation
    }
}
