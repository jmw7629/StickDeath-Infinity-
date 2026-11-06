import UIKit
import SwiftUI
import Foundation
import Darwin

@MainActor private final class ViewBox {
    var content: UIView?
    var viewport: UIView?
}

private struct LayoutProbe: UIViewRepresentable {
    let capture: (UIView) -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        capture(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { capture(view) }
}

@main @MainActor final class PopupLayoutAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "PopupLayout", sessionRole: session.role)
        configuration.delegateClass = PopupLayoutSceneDelegate.self
        return configuration
    }
}

@MainActor final class PopupLayoutSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = PopupLayoutRunner()
        self.window = window
        window.makeKeyAndVisible()
    }
}

@MainActor private final class PopupLayoutRunner: UIViewController {
    private var started = false
    private var cases: [[String: Any]] = []
    private let metadataKeys = ["nonce", "sourceCommit", "productionFileSHA256",
                                "productionHelperSHA256", "harnessSHA256"]

    override func loadView() {
        view = UIView()
        view.backgroundColor = .white
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { @MainActor in await runCases() }
    }

    private func finish(_ failure: String? = nil) {
        var report: [String: Any] = ["version": 1, "cases": cases,
                                     "passed": failure == nil ? cases.count : 0]
        for key in metadataKeys {
            report[key] = Bundle.main.object(forInfoDictionaryKey: "SDIPopup_" + key) as? String ?? ""
        }
        if let failure { report["failure"] = failure }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("STUDIO_POPUP_LAYOUT_RESULT=" + String(decoding: data, as: UTF8.self))
            if failure == nil {
                print("STUDIO_POPUP_LAYOUT=PASS 3/3 actual hosted UIKit cases")
            }
            fflush(stdout)
        } catch {
            fputs("FAIL popup result encoding\n", stderr)
            fflush(stderr)
        }
        exit(failure == nil ? 0 : 1)
    }

    private func number(_ value: CGFloat) -> Any {
        if value.isFinite { return Double(value) }
        return String(describing: value)
    }

    private func runCases() async {
        for (name, rows, bound) in [("short controls", 0, CGFloat(360)),
                                     ("long library", 30, CGFloat(360)),
                                     ("compact landscape", 0, CGFloat(88))] {
            let box = ViewBox()
            // These are the same controls, width, bounds and measured-size oracle
            // as the original harness, hosted by the actual iOS UIKit boundary.
            let content = ToolSettingsContentLayout(maximumHeight: bound) {
                VStack {
                    Button("Brush Library: Round") {}
                    Slider(value: .constant(0.5))
                    TextField("X", text: .constant("270"))
                    Button("Reset this tool") {}
                    ForEach(0..<rows, id: \.self) { i in Text("Library item \(i)") }
                }.background(LayoutProbe { box.content = $0 })
            }.background(LayoutProbe { box.viewport = $0 })
            let host = UIHostingController(rootView: content)
            addChild(host)
            view.addSubview(host.view)
            // Keep the probe inside the real window safe area; the popup's
            // content measurement must not include the application's status bar.
            host.view.frame = CGRect(x: view.safeAreaInsets.left,
                                     y: view.safeAreaInsets.top, width: 236, height: 400)
            host.didMove(toParent: self)
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + 1
            while ProcessInfo.processInfo.systemUptime < deadline {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { finish("Layout task cancelled"); return }
            }
            let measured = box.content?.frame.height ?? 0
            let viewport = box.viewport?.frame.height ?? 0
            let fitting = host.sizeThatFits(in: CGSize(width: 236, height: 400)).height
            let expected = min(measured, bound)
            let valid = measured > 0 && viewport > 0
                && abs(viewport - expected) < 0.5 && abs(fitting - expected) < 0.5
            cases.append(["name": name, "rows": rows, "width": 236, "bound": Double(bound),
                          "content": number(measured), "viewport": number(viewport),
                          "fitting": number(fitting), "passed": valid,
                          "caseBudgetSeconds": 1,
                          "measurementSeconds": ProcessInfo.processInfo.systemUptime - started])
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            guard valid else { finish("Actual hosted geometry failed: " + name); return }
        }
        finish()
    }
}
