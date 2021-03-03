import SwiftUI

extension BasalProfileEditor {
    struct RootView: BaseView {
        @EnvironmentObject var viewModel: ViewModel<Provider>
        @State private var editMode = EditMode.inactive

        private var dateFormatter: DateFormatter {
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.timeStyle = .short
            return formatter
        }

        private var rateFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }

        var body: some View {
            Form {
                Section(header: Text("Schedule")) {
                    list
                    addButton
                }
                Section {
                    HStack {
                        if viewModel.syncInProgress {
                            ProgressView().padding(.trailing, 10)
                        }
                        Button { viewModel.save() }
                        label: {
                            Text(viewModel.syncInProgress ? "Saving..." : "Save on Pump")
                        }
                        .disabled(viewModel.syncInProgress || viewModel.items.isEmpty)
                    }
                }
            }
            .navigationTitle("Basal Profile")
            .navigationBarTitleDisplayMode(.automatic)
            .navigationBarItems(
                leading: Button("Close", action: viewModel.hideModal),
                trailing: EditButton()
            )
            .environment(\.editMode, $editMode)
            .onAppear {
                viewModel.validate()
            }
        }

        private func pickers(for index: Int) -> some View {
            GeometryReader { geometry in
                VStack {
                    HStack {
                        Text("Rate").frame(width: geometry.size.width / 2)
                        Text("Time").frame(width: geometry.size.width / 2)
                    }
                    HStack(spacing: 0) {
                        Picker(selection: $viewModel.items[index].rateIndex, label: EmptyView()) {
                            ForEach(0 ..< viewModel.rateValues.count, id: \.self) { i in
                                Text(
                                    (
                                        self.rateFormatter
                                            .string(from: viewModel.rateValues[i] as NSNumber) ?? ""
                                    ) + " U/h"
                                ).tag(i)
                            }
                        }
                        .frame(maxWidth: geometry.size.width / 2)
                        .clipped()

                        Picker(selection: $viewModel.items[index].timeIndex, label: EmptyView()) {
                            ForEach(0 ..< viewModel.timeValues.count, id: \.self) { i in
                                Text(
                                    self.dateFormatter
                                        .string(from: Date(
                                            timeIntervalSince1970: viewModel
                                                .timeValues[i]
                                        ))
                                ).tag(i)
                            }
                        }
                        .frame(maxWidth: geometry.size.width / 2)
                        .clipped()
                    }
                }
            }
        }

        private var list: some View {
            List {
                ForEach(viewModel.items.indexed(), id: \.1.id) { index, item in
                    NavigationLink(destination: pickers(for: index)) {
                        HStack {
                            Text("Rate").foregroundColor(.secondary)
                            Text(
                                "\(rateFormatter.string(from: viewModel.rateValues[item.rateIndex] as NSNumber) ?? "0") U/h"
                            )
                            Spacer()
                            Text("starts at").foregroundColor(.secondary)
                            Text(
                                "\(dateFormatter.string(from: Date(timeIntervalSince1970: viewModel.timeValues[item.timeIndex])))"
                            )
                        }
                    }
                    .moveDisabled(true)
                }
                .onDelete(perform: onDelete)
            }
        }

        private var addButton: some View {
            guard viewModel.canAdd else {
                return AnyView(EmptyView())
            }

            switch editMode {
            case .inactive:
                return AnyView(Button(action: onAdd) { Text("Add") })
            default:
                return AnyView(EmptyView())
            }
        }

        func onAdd() {
            viewModel.add()
        }

        private func onDelete(offsets: IndexSet) {
            viewModel.items.remove(atOffsets: offsets)
            viewModel.validate()
        }
    }
}
