import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShortVideoWebView") {
      ShortVideoWebViewPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PiliPlusPipQa") {
      PipQaLifecyclePlugin.register(with: registrar)
    }
  }
}

/// 自动 QA 的宿主控制通道。只有写入 Documents/pip_qa.json 时才会启用；
/// Dart 侧只负责启动后台和写判定，原生侧用全局队列计时并自动重新激活。
final class PipQaLifecyclePlugin: NSObject, FlutterPlugin {
  private static let shared = PipQaLifecyclePlugin()
  private static let suspendSelector = NSSelectorFromString("suspend")
  private static let resumeSelector = NSSelectorFromString("resume")
  private static let suspendDelay: Double = 0.2

  private let lock = NSLock()
  private var resumeWork: DispatchWorkItem?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var resumeTriggered = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "PiliPlus/PipQa",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(Self.shared, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "background":
      let seconds = Self.backgroundSeconds(from: call.arguments)
      DispatchQueue.main.async {
        self.beginBackgroundInterval(seconds: seconds)
        result(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.suspendDelay) {
          UIApplication.shared.perform(
            Self.suspendSelector,
            with: nil,
            afterDelay: 0
          )
        }
      }
    case "foreground":
      DispatchQueue.global(qos: .userInitiated).async {
        self.resumeNow()
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func backgroundSeconds(from arguments: Any?) -> Double {
    guard let args = arguments as? [String: Any],
          let value = args["seconds"] as? NSNumber else { return 10 }
    return min(60, max(2, value.doubleValue))
  }

  private func beginBackgroundInterval(seconds: Double) {
    lock.lock()
    resumeWork?.cancel()
    let previousTask = backgroundTask
    backgroundTask = .invalid
    resumeTriggered = false
    lock.unlock()
    if previousTask != .invalid {
      DispatchQueue.main.async {
        UIApplication.shared.endBackgroundTask(previousTask)
      }
    }
    let task = UIApplication.shared.beginBackgroundTask(
      withName: "PiliPlusPipQa"
    ) { [weak self] in
      DispatchQueue.global(qos: .userInitiated).async { self?.resumeNow() }
    }
    let work = DispatchWorkItem { [weak self] in
      self?.resumeNow()
    }
    lock.lock()
    backgroundTask = task
    resumeWork = work
    lock.unlock()
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + Self.suspendDelay + seconds,
      execute: work
    )
  }

  private func resumeNow() {
    lock.lock()
    if resumeTriggered {
      lock.unlock()
      return
    }
    resumeTriggered = true
    resumeWork?.cancel()
    resumeWork = nil
    let task = backgroundTask
    backgroundTask = .invalid
    lock.unlock()
    // 后台期间主队列可能已经被系统冻住；`resume` 不能排到主队列等它自己醒来。
    _ = UIApplication.shared.perform(Self.resumeSelector)
    if task != .invalid {
      DispatchQueue.main.async {
        UIApplication.shared.endBackgroundTask(task)
      }
    }
  }
}

/// 抖音 / TikTok 收藏的抓取网页。
///
/// 走原生 WKWebView 而不是 flutter_inappwebview：后者是 Flutter 的 platform view，
/// 在这套 iOS 构建里创建出来只有一片白（连页面都不渲染）。原生这边和 Kumone 用的是
/// 同一套代码路径，已经在真机上验证可用。
final class ShortVideoWebViewPlugin: NSObject, FlutterPlugin {
  static let channelName = "piliplus/shortvideo_web"

  private let channel: FlutterMethodChannel
  private var webController: ShortVideoWebViewController?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = ShortVideoWebViewPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "缺少参数", details: nil))
        return
      }
      if present(args: args) {
        result(nil)
      } else {
        result(FlutterError(
          code: "no_presenter",
          message: "找不到可用的窗口，无法打开网页",
          details: nil
        ))
      }
    case "close":
      webController?.closeSelf()
      result(nil)
    case "start":
      webController?.startCollecting()
      result(nil)
    case "stop":
      webController?.stopCollecting()
      result(nil)
    case "cookies":
      // 抖音 / TikTok 的 CDN 会按网页会话校验：Kumone 用 URLSession 下载时
      // 自动带上了 WKWebView 存在 HTTPCookieStorage 里的 cookie，而 Dart 的
      // HttpClient 是独立 cookie 罐，一个都不带——这就是「Kumone 下得动、
      // PiliPlus 0%」的根因。这里把网页的 cookie 交出去。
      let needle = (call.arguments as? [String: Any])?["domain"] as? String ?? ""
      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        let list: [[String: String]] = cookies.compactMap { cookie in
          if !needle.isEmpty, !cookie.domain.contains(needle) { return nil }
          return [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
          ]
        }
        DispatchQueue.main.async { result(list) }
      }
    case "deviceMemory":
      // 设备物理内存（字节）。Dart 侧据此决定短视频走不走「低内存」那套策略
      // （串行下载、缓存上限更小、解码缓冲压到最低）——6S 这类 2GB 机器顶不住。
      result(Int(ProcessInfo.processInfo.physicalMemory))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(args: [String: Any]) -> Bool {
    guard let root = Self.topViewController() else {
      NSLog("[ShortVideoWeb] no top view controller")
      return false
    }
    let controller = ShortVideoWebViewController(args: args) { [weak self] method, payload in
      self?.channel.invokeMethod(method, arguments: payload)
    }
    webController = controller
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    navigation.view.backgroundColor = .systemBackground
    root.present(navigation, animated: true)
    NSLog("[ShortVideoWeb] presented from \(type(of: root))")
    return true
  }

  private static func topViewController() -> UIViewController? {
    var root: UIViewController?
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where window.isKeyWindow {
        root = window.rootViewController
        break
      }
      if root != nil { break }
    }
    if root == nil {
      root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
    if root == nil {
      root = UIApplication.shared.windows.first?.rootViewController
    }
    var top = root
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

final class ShortVideoWebViewController: UIViewController {
  private let args: [String: Any]
  private let emit: (String, Any?) -> Void

  private var webView: WKWebView!
  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let hintButton = UIButton(type: .system)
  private lazy var startButton = UIBarButtonItem(
    title: "开始抓取",
    style: .done,
    target: self,
    action: #selector(toggleCollecting)
  )

  private var timer: Timer?
  private var idleRounds = 0
  private var lastCount = 0
  private var received = 0
  private var startedAt = Date()
  private var collecting = false
  private var didNotifyClose = false
  private var hookInstalled = false
  private var pendingStart = false
  private var didFinishLoading = false
  private var reloadingForCollect = false
  private var popup: ShortVideoPopupController?
  private var lastPopupURL = ""
  private var lastPopupAt = Date.distantPast

  static func armedHookScript(hookScript: String) -> String {
    """
    (function () {
      var armed = false;
      try { armed = window.localStorage.getItem('__kumoneArm') === '1'; } catch (e) {}
      if (!armed) { return; }
      \(hookScript)
    })();
    """
  }

  /// 常驻的极轻量脚本：只接管 `window.open`。
  static let popupBridgeScript = """
  (function () {
    if (window.__kumonePopupBridge) { return; }
    window.__kumonePopupBridge = true;
    var realOpen = window.open;
    window.open = function (url, name, features) {
      var handle = null;
      try { handle = realOpen.apply(window, arguments); } catch (e) { handle = null; }
      try {
        var target = url ? String(url) : '';
        if (!handle && target && target !== 'about:blank') {
          window.webkit.messageHandlers.shortvideo.postMessage({ popup: target });
        }
      } catch (e) {}
      return handle;
    };
  })();
  """

  private var homeURL: String { args["url"] as? String ?? "https://www.douyin.com/" }
  private var favoritesURL: String { args["favoritesUrl"] as? String ?? homeURL }
  private var loginURL: String { args["loginUrl"] as? String ?? homeURL }
  private var userAgent: String { args["userAgent"] as? String ?? "" }
  private var hookScript: String { args["hookScript"] as? String ?? "" }
  private var driverScript: String { args["driverScript"] as? String ?? "" }
  private var titleText: String { args["title"] as? String ?? "抓取" }

  init(args: [String: Any], emit: @escaping (String, Any?) -> Void) {
    self.args = args
    self.emit = emit
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = titleText
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .plain,
      target: self,
      action: #selector(closeSelf)
    )
    navigationItem.rightBarButtonItems = [
      startButton,
      UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        style: .plain,
        target: self,
        action: #selector(reloadFavorites)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "person.crop.circle"),
        style: .plain,
        target: self,
        action: #selector(openLogin)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "safari"),
        style: .plain,
        target: self,
        action: #selector(openInSafari)
      ),
    ]

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.userContentController.add(self, name: "shortvideo")
    // 只接管 window.open：登录阶段不注入抓取脚本，但弹窗被 WebKit 拦掉时
    // 连 delegate 都不回调，点了「登录」就是一点反应都没有。
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: ShortVideoWebViewController.popupBridgeScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    // 只有点「开始抓取」之后（localStorage 标记为 1）才会真正装监听：
    // 接口请求必须发生在监听装好之后，否则页面早就把收藏拉完了，一段都收不到。
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: ShortVideoWebViewController.armedHookScript(
          hookScript: args["hookScript"] as? String ?? ""
        ),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )

    let web = WKWebView(frame: .zero, configuration: configuration)
    web.customUserAgent = userAgent
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsBackForwardNavigationGestures = true
    web.isOpaque = true
    web.backgroundColor = .white
    web.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(web)

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 3
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    hintButton.setTitle("网页空白？点这里重试", for: .normal)
    hintButton.titleLabel?.font = .systemFont(ofSize: 12)
    hintButton.translatesAutoresizingMaskIntoConstraints = false
    hintButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
    hintButton.isHidden = true
    view.addSubview(hintButton)

    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      web.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.bottomAnchor.constraint(
        equalTo: hintButton.topAnchor,
        constant: -4
      ),
      hintButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      hintButton.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -8
      ),
      spinner.centerXAnchor.constraint(equalTo: web.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: web.centerYAnchor),
    ])

    webView = web
    load(homeURL)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopTimer()
    if !didNotifyClose {
      didNotifyClose = true
      emit("closed", nil)
    }
  }

  // MARK: - Actions

  @objc func closeSelf() {
    stopTimer()
    dismiss(animated: true)
  }

  @objc private func reloadFavorites() {
    load(favoritesURL)
  }

  @objc private func openLogin() {
    load(loginURL)
  }

  /// 开一个真正的弹窗，别把站点自己的页面冲掉。
  private func presentPopup(_ url: URL) {
    let scheme = (url.scheme ?? "").lowercased()
    guard scheme == "http" || scheme == "https" else { return }
    guard popup == nil else { return }
    let signature = url.absoluteString
    if signature == lastPopupURL, Date().timeIntervalSince(lastPopupAt) < 3 {
      return
    }
    lastPopupURL = signature
    lastPopupAt = Date()

    let controller = ShortVideoPopupController(url: url, userAgent: userAgent) {
      [weak self] in
      guard let self else { return }
      self.popup = nil
      self.setStatus("登录窗口已关闭，刷新本页…")
      self.webView.reload()
    }
    popup = controller
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    present(navigation, animated: true)
  }

  @objc private func openInSafari() {
    guard let url = webView.url ?? URL(string: homeURL) else { return }
    UIApplication.shared.open(url)
  }

  @objc private func retry() {
    hintButton.isHidden = true
    didFinishLoading = false
    load(webView.url?.absoluteString ?? homeURL)
  }

  @objc private func toggleCollecting() {
    if collecting {
      stopCollecting(message: "已停止，收到 \(received) 段数据")
    } else {
      startCollecting()
    }
  }

  private func load(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    webView.customUserAgent = userAgent
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    webView.load(request)
    didFinishLoading = false
    spinner.startAnimating()
    setStatus("正在打开 \(urlString)…")
    scheduleBlankCheck()
  }

  /// 10 秒还没渲染出内容就提示一下——比一片白什么都不说要好排查。
  private func scheduleBlankCheck() {
    hintButton.isHidden = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, !self.didFinishLoading else { return }
      self.hintButton.isHidden = false
      self.spinner.stopAnimating()
    }
  }

  func startCollecting() {
    guard !collecting else { return }
    if !isOnFavoritesPage {
      pendingStart = true
      load(favoritesURL)
      setStatus("正在打开收藏页，加载完自动开始抓取…")
      return
    }
    beginCollecting()
  }

  private var isOnFavoritesPage: Bool {
    guard let current = webView.url?.absoluteString else { return false }
    if favoritesURL.contains("/user/self") {
      return current.contains("/user/self") || current.contains("showTab=favorite")
    }
    if favoritesURL.contains("tiktok.com/@") {
      return current.contains("tiktok.com/@")
    }
    return current.contains(favoritesURL)
  }

  private func beginCollecting() {
    collecting = true
    startButton.title = "停止抓取"
    idleRounds = 0
    lastCount = received
    startedAt = Date()
    received = 0
    setStatus("正在抓取…正在重新加载页面，让收藏接口重新请求一次")
    // 接口请求必须发生在监听装好之后。以前在加载完的页面上补装监听，
    // 页面早把收藏拉过了，于是永远收到 0 段——TikTok 收藏页是整页渲染，
    // 切 tab 也不会再发请求，一条都抓不到。现在：置标记 → reload →
    // documentStart 按标记自动装监听 → 页面自己重新请求。
    let js = "try{localStorage.setItem('__kumoneArm','1');}catch(e){}"
    webView.evaluateJavaScript(js) { [weak self] _, _ in
      guard let self else { return }
      self.hookInstalled = true
      self.reloadingForCollect = true
      self.webView.reload()
    }
  }

  /// 只在抓取时才注入：登录 / 搜索阶段页面是干净的，不会被影响。
  private func installHook(_ completion: @escaping () -> Void) {
    guard !hookInstalled else { completion(); return }
    webView.evaluateJavaScript(hookScript) { [weak self] _, _ in
      self?.hookInstalled = true
      completion()
    }
  }

  func stopCollecting(message: String? = nil) {
    guard collecting else { return }
    collecting = false
    startButton.title = "开始抓取"
    stopTimer()
    webView.evaluateJavaScript(
      "try{clearInterval(window.__kumoneDriver);window.__kumoneDriver=null;"
      + "localStorage.setItem('__kumoneArm','0');}catch(e){}"
    )
    setStatus(message ?? "已停止，收到 \(received) 段数据")
  }

  private func startTimer() {
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard collecting else { return }
    webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
    if Date().timeIntervalSince(startedAt) > 300 {
      stopCollecting(message: "抓取超时，收到 \(received) 段数据")
      return
    }
    if received == lastCount {
      idleRounds += 1
    } else {
      idleRounds = 0
      lastCount = received
    }
    if idleRounds >= 10 {
      stopCollecting(message: "抓取完成，收到 \(received) 段数据")
    }
  }

  private func setStatus(_ text: String) {
    statusLabel.text = text
    emit("status", text)
  }
}

extension ShortVideoWebViewController: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "shortvideo",
          let payload = message.body as? [String: Any] else { return }

    if let popup = payload["popup"] as? String,
       let url = URL(string: popup) {
      presentPopup(url)
      return
    }

    guard let body = payload["body"] as? String else { return }
    received += 1
    emit("payload", ["body": body])
    if collecting {
      statusLabel.text = "收到 \(received) 段数据…"
    }
  }
}

extension ShortVideoWebViewController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    hookInstalled = false
    spinner.startAnimating()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    didFinishLoading = true
    spinner.stopAnimating()
    hintButton.isHidden = true
    if !collecting {
      setStatus("页面已响应：\(webView.url?.absoluteString.prefix(60) ?? "")")
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    didFinishLoading = true
    spinner.stopAnimating()
    hintButton.isHidden = true
    if pendingStart {
      pendingStart = false
      beginCollecting()
      return
    }
    if reloadingForCollect {
      reloadingForCollect = false
      webView.evaluateJavaScript(driverScript)
      startTimer()
      return
    }
    if !collecting {
      setStatus("页面已加载：登录后点右上角「开始抓取」")
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    spinner.stopAnimating()
    hintButton.isHidden = false
    setStatus("网页进程被系统回收，点「重试」或右上角刷新")
  }

  private func report(_ error: Error) {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
    spinner.stopAnimating()
    hintButton.isHidden = false
    setStatus("网页加载失败：\(error.localizedDescription)（\(ns.code)）")
  }
}

extension ShortVideoWebViewController: WKUIDelegate {
  /// `window.open` / `target=_blank` 单独弹一层窗口。
  ///
  /// 以前是「塞回本页加载」，结果把站点自己的 SPA 冲掉——表现就是
  /// 「二维码刚要出来又闪回首页」，登录永远做不成。现在开一个真正的弹窗，
  /// cookie 落在同一个域上，关掉弹窗本页刷新一下就是登录态。
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      presentPopup(url)
    }
    return nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

/// `window.open` 弹出来的登录窗。
///
/// 抖音 / TikTok 的二维码登录都走新窗口。塞回本页加载会把站点 SPA 冲掉，
/// 所以这里单独开一层；cookie 落在同一个域上，关掉后本页刷新即为登录态。
final class ShortVideoPopupCloseBridge: NSObject, WKScriptMessageHandler {
  var onClose: (() -> Void)?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "kumoneClose" else { return }
    DispatchQueue.main.async { [weak self] in
      self?.onClose?()
    }
  }
}

final class ShortVideoPopupController: UIViewController, WKNavigationDelegate {
  private let request: URL
  private let userAgent: String
  private let onClose: () -> Void
  private let closeBridge = ShortVideoPopupCloseBridge()
  private var didNotify = false

  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.userContentController.add(closeBridge, name: "kumoneClose")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.closeBridgeScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = userAgent
    view.navigationDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private static let closeBridgeScript = """
  (function () {
    if (window.__kumoneCloseBridge) { return; }
    window.__kumoneCloseBridge = true;
    var realClose = window.close;
    window.close = function () {
      try { window.webkit.messageHandlers.kumoneClose.postMessage({ close: true }); } catch (e) {}
      try { return realClose.apply(window, arguments); } catch (e) {}
    };
  })();
  """

  init(url: URL, userAgent: String, onClose: @escaping () -> Void) {
    self.request = url
    self.userAgent = userAgent
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = request.host ?? "登录"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .done,
      target: self,
      action: #selector(closeSelf)
    )
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        style: .plain,
        target: self,
        action: #selector(reloadSelf)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "chevron.backward"),
        style: .plain,
        target: self,
        action: #selector(backSelf)
      ),
    ]

    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    closeBridge.onClose = { [weak self] in
      self?.closeSelf()
    }
    webView.load(URLRequest(url: request, timeoutInterval: 30))
  }

  @objc private func closeSelf() {
    dismiss(animated: true)
  }

  @objc private func reloadSelf() {
    if webView.url == nil {
      webView.load(URLRequest(url: request, timeoutInterval: 30))
    } else {
      webView.reload()
    }
  }

  @objc private func backSelf() {
    if webView.canGoBack {
      webView.goBack()
    } else {
      reloadSelf()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard !didNotify else { return }
    didNotify = true
    onClose()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
    let inApp = scheme.isEmpty
      || scheme == "http"
      || scheme == "https"
      || scheme == "about"
      || scheme == "file"
      || scheme == "data"
      || scheme == "blob"
    if inApp {
      decisionHandler(.allow)
      return
    }
    if let url = navigationAction.request.url,
       UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    decisionHandler(.cancel)
  }
}
