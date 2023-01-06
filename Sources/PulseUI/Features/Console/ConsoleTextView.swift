// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import CoreData
import Pulse
import Combine

#warning("TODO: fix safe area")
#warning("TODO: fix where share and close buttons are form FIleView?")
#warning("TODO: cache strings")
#warning("TODO: fix jumping when updating expanding view (when new contnet is available?)")

#if os(iOS)

@available(iOS 14, tvOS 14, *)
struct ConsoleTextView: View {
    @StateObject private var viewModel = ConsoleTextViewModel()
    @State private var shareItems: ShareItems?
    @State private var isShowingSettings = false
    @ObservedObject private var settings: ConsoleTextViewSettings = .shared

    var entities: CurrentValueSubject<[NSManagedObject], Never>
    var options: TextRenderer.Options?
    var onClose: (() -> Void)?

    var body: some View {
        textView
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let options = options {
                    viewModel.options = options
                }
                viewModel.bind(entities)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Menu(content: { menu }) {
                            Image(systemName: "ellipsis.circle")
                        }
                        if let onClose = onClose {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                            }
                        }
                    }
                }
            }
            .sheet(item: $shareItems, content: ShareView.init)
            .sheet(isPresented: $isShowingSettings) { settingsView }
    }

    private var textView: some View {
        RichTextView(
            viewModel: viewModel.text,
            isAutomaticLinkDetectionEnabled: settings.isLinkDetectionEnabled
        )
    }

    @ViewBuilder
    private var menu: some View {
        Section {
            Button(action: { shareItems = ShareItems([viewModel.text.text.string]) }) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Section {
                Button(action: { settings.orderAscending.toggle() }) {
                    Label("Order by Date", systemImage: settings.orderAscending ? "arrow.up" : "arrow.down")
                }
                Button(action: { settings.isCollapsingResponses.toggle() }) {
                    Label(settings.isCollapsingResponses ? "Expand Responses" : "Collapse Responses", systemImage: settings.isCollapsingResponses ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                Button(action: viewModel.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(viewModel.isButtonRefreshHidden)
            }
            Section {
                Button(action: { isShowingSettings = true }) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
//            // Unfortunately, this isn't working properly in UITextView (use WebView!)
//            Button(action: viewModel.text.scrollToBottom) {
//                Label("Scroll to Bottom", systemImage: "arrow.down")
//            }
        }
    }

    private var settingsView: some View {
        NavigationView {
            ConsoleTextViewSettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button("Done") {
                    isShowingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        viewModel.reloadOptions()
                        viewModel.refresh()
                    }
                })
        }
    }
}

#warning("TODO: add more seettings for what to show in request info + show all")

@available(iOS 14, *)
private struct ConsoleTextViewSettingsView: View {
    @ObservedObject private var settings: ConsoleTextViewSettings = .shared

    var body: some View {
        Form {
            Section(header: Text("Appearance")) {
                Picker("Color Mode", selection: $settings.colorMode) {
                    Text("Automatic").tag(TextRenderer.ColorMode.automatic)
                    Text("Full").tag(TextRenderer.ColorMode.full)
                    Text("Monochrome").tag(TextRenderer.ColorMode.monochrome)
                }
                Toggle("Link Detection", isOn: $settings.isLinkDetectionEnabled)
            }
            Section(header: Text("Request Info")) {
                Toggle("Request Headers", isOn: $settings.showsTaskRequestHeader)
                Toggle("Response Headers", isOn: $settings.showsResponseHeaders)
                Toggle("Request Body", isOn: $settings.showsRequestBody)
                Toggle("Response Body", isOn: $settings.showsResponseBody)
            }
            Section {
                Button("Reset Settings") {
                    settings.reset()
                }
                .foregroundColor(.red)
            }
        }
    }
}

@available(iOS 14, *)
final class ConsoleTextViewModel: ObservableObject {
    let text: RichTextViewModel
    var options: TextRenderer.Options = .init()
    @Published private(set) var isButtonRefreshHidden = true

    private var expanded: Set<NSManagedObjectID> = []
    private let settings = ConsoleTextViewSettings.shared
    private var entities: CurrentValueSubject<[NSManagedObject], Never> = .init([])
    private var lastTimeRefreshHidden = Date().addingTimeInterval(-3)

    private var cancellables: [AnyCancellable] = []

    init() {
        self.text = RichTextViewModel(string: "")
        self.text.onLinkTapped = { [unowned self] in onLinkTapped($0) }
        self.reloadOptions()

        ConsoleTextViewSettings.shared.$orderAscending.dropFirst().sink { [weak self] _ in
            self?.refreshText()
        }.store(in: &cancellables)

        ConsoleTextViewSettings.shared.$isCollapsingResponses.dropFirst().sink { [weak self] isCollasped in
            self?.options.isBodyExpanded = !isCollasped
            self?.expanded.removeAll()
            self?.refreshText()
        }.store(in: &cancellables)
    }

    func bind(_ entities: CurrentValueSubject<[NSManagedObject], Never>) {
        self.entities = entities
        entities.dropFirst().sink { [weak self] _ in
            self?.showRefreshButtonIfNeeded()
        }.store(in: &cancellables)
        self.refresh()
    }

    func reloadOptions() {
        options.isBodyExpanded = !settings.isCollapsingResponses
        options.color = settings.colorMode
        if settings.showsTaskRequestHeader {
            options.networkContent.insert(.currentRequestHeaders)
            options.networkContent.insert(.originalRequestHeaders)
        } else {
            options.networkContent.remove(.currentRequestHeaders)
            options.networkContent.remove(.originalRequestHeaders)
        }
        if settings.showsRequestBody {
            options.networkContent.insert(.requestBody)
        } else {
            options.networkContent.remove(.requestBody)
        }
        if settings.showsResponseHeaders {
            options.networkContent.insert(.responseHeaders)
        } else {
            options.networkContent.remove(.responseHeaders)
        }
        if settings.showsResponseBody {
            options.networkContent.insert(.responseBody)
        } else {
            options.networkContent.remove(.responseBody)
        }

        text.textView?.isAutomaticLinkDetectionEnabled = settings.isLinkDetectionEnabled
    }

    func refresh() {
        self.refreshText()
        self.hideRefreshButton()
    }

    private func refreshText() {
        let entities = settings.orderAscending ? entities.value : entities.value.reversed()
        let renderer = TextRenderer(options: options)
        let strings: [NSAttributedString]
        if let messages = entities as? [LoggerMessageEntity] {
            strings = messages.enumerated().map { (index, message) in
                renderer.render(message, index: index, isExpanded: expanded.contains(message.objectID))
            }
        } else if let tasks = entities as? [NetworkTaskEntity] {
            strings = tasks.enumerated().map { (index, task) in
                renderer.render(task, index: index, isExpanded: expanded.contains(task.objectID))
            }
        } else {
            assertionFailure("Unsupported entities: \(entities)")
            strings = []
        }
        let string = renderer.joined(strings)
        self.text.display(string)
    }

    func onLinkTapped(_ url: URL) -> Bool {
        guard url.scheme == "pulse", url.host == "expand", let index = Int(url.lastPathComponent) else {
            return false
        }
        expanded.insert(entities.value[index].objectID)
        refreshText()
        return true
    }

    private func hideRefreshButton() {
        guard !isButtonRefreshHidden else { return }
        isButtonRefreshHidden = true
    }

    private func showRefreshButtonIfNeeded() {
        guard isButtonRefreshHidden else { return }
        isButtonRefreshHidden = false
    }
}

#if DEBUG
@available(iOS 14, *)
struct ConsoleTextView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationView {
                ConsoleTextView(entities: entities) { _ in
                    return // Use default settings
                }
            }
            .previewDisplayName("Default")

            NavigationView {
                ConsoleTextView(entities: entities) {
                    $0.color = .full
                    $0.networkContent = .all
                }
            }
            .previewDisplayName("Full Color")

            NavigationView {
                ConsoleTextView(entities: entities) {
                    $0.color = .monochrome
                    $0.networkContent = .all
                }
            }
            .previewDisplayName("Monochrome")

            NavigationView {
                ConsoleTextView(entities: entities) {
                    $0.networkContent = .all
                    $0.isBodyExpanded = true
                }
            }
            .previewDisplayName("Network: All")
        }
    }
}

private let entities = try! LoggerStore.mock.allMessages()

@available(iOS 14, tvOS 14, *)
private extension ConsoleTextView {
    init(entities: [LoggerMessageEntity], _ configure: (inout TextRenderer.Options) -> Void) {
        var options = TextRenderer.Options()
        configure(&options)
        self.init(entities: .init(entities.reversed()), options: options, onClose: {})
    }
}

#endif

#endif
