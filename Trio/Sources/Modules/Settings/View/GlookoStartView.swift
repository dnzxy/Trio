import SwiftUI
import Swinject

struct GlookoStartView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Glooko Integration"),
                content:
                {
                    VStack {
                        if state.glookoServiceUIType != nil,
                           state.provider.glookoManager.getGlookoPluginHost() != nil
                        {
                            if state.provider.glookoManager.getGlookoServiceUI() != nil
                            {
                                Button {
                                    state.setupGlooko.toggle()
                                }
                                label: {
                                    let issue = state.provider.glookoManager.glookoUploadIssue.value
                                    HStack {
                                        Group {
                                            switch issue {
                                            case .loginRequired: Text("Glooko Login Required")
                                            case .uploadsFailing: Text("Glooko Uploads Failing")
                                            case nil: Text("Connected to Glooko")
                                            }
                                        }
                                        .font(.title3)
                                        ZStack {
                                            Image(systemName: "network")
                                            Image(systemName: issue == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .foregroundColor(issue == nil ? .green : .red).font(.caption2)
                                                .offset(x: 9, y: 6)
                                        }
                                        .accessibilityHidden(true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    state.setupGlooko.toggle()
                                }
                                label: { Text("Connect to Glooko").font(.title3) }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .buttonStyle(.bordered)
                            }
                        }

                        HStack(alignment: .center) {
                            Text("You can connect Trio to send your glucose, carb and insulin data to Glooko.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(
                                action: {
                                    shouldDisplayHint.toggle()
                                },
                                label: {
                                    HStack {
                                        Image(systemName: "questionmark.circle").accessibilityLabel(Text("More information"))
                                    }
                                }
                            ).buttonStyle(BorderlessButtonStyle())
                        }.padding(.top)
                    }.padding(.vertical)
                }
            ).listRowBackground(Color.chart)
        }
        .sheet(isPresented: $state.setupGlooko) {
            if let serviceUIType = state.glookoServiceUIType,
               let pluginHost = state.provider.glookoManager.getGlookoPluginHost()
            {
                if let serviceUI = state.provider.glookoManager.getGlookoServiceUI() {
                    TidepoolSettingsView(
                        serviceUI: serviceUI,
                        serviceOnBoardDelegate: self.state,
                        serviceDelegate: self.state
                    )
                } else {
                    TidepoolSetupView(
                        serviceUIType: serviceUIType,
                        pluginHost: pluginHost,
                        serviceOnBoardDelegate: self.state,
                        serviceDelegate: self.state
                    )
                }
            }
        }
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: "Connect to Glooko",
                hintText: Text(
                    "Sign in with your Glooko account. Pick Glooko XT or Glooko to match the app your account uses.\n\nWhen connected, Trio sends your glucose readings, carb entries, boluses and basal insulin to Glooko, so you and your care team can see them there. Trio does not read anything back from Glooko, and nothing in Glooko changes how Trio doses insulin.\n\nThis connection is not made or supported by Glooko. It can stop working without warning if Glooko changes its systems, and data may show up late or not at all. Deleting a carb entry or bolus in Trio may not remove it from Glooko. Always use Trio itself, not Glooko, to check your current glucose, insulin and carbs."
                ),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Glooko")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear(perform: configureView)
    }
}
