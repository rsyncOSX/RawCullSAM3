import SwiftUI
import UniformTypeIdentifiers

extension KeyPath: @unchecked @retroactive Sendable where Root == FileItem {}

struct RawCullMainView: View {
    @Bindable var viewModel: RawCullViewModel

    @State private var memoryWarningOpacity: Double = 0.3
    @State private var memoryMonitorModel = MemoryViewModel(pressureThresholdFactor: 0.85)
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn

    @State private var cgImage: CGImage?
    @State private var nsImage: NSImage?

    var body: some View {
        ZStack {
            loupeSplit

            if viewModel.zoomOverlayVisible {
                ZoomOverlayView(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .sheet(item: $viewModel.rawDiagnosticsPresentation) { presentation in
            RawFileDiagnosticsView(log: presentation.log) {
                viewModel.rawDiagnosticsPresentation = nil
            }
        }
    }

    private var loupeSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RAWCatalogSidebarView(
                sources: $viewModel.sources,
                selectedSource: $viewModel.selectedSource,
                isShowingPicker: $viewModel.isShowingPicker,
                cullingModel: viewModel.cullingModel,
            )
        } content: {
            SidebarARWCatalogFileView(
                viewModel: viewModel,
                isShowingPicker: $viewModel.isShowingPicker,
                progress: $viewModel.progress,
                selectedSource: $viewModel.selectedSource,
                scanning: $viewModel.scanning,
                creatingThumbnails: $viewModel.creatingthumbnails,
                nsImage: $nsImage,
                cgImage: $cgImage,
                issorting: viewModel.issorting,
                max: viewModel.max,
            )
            .navigationTitle((viewModel.selectedSource?.name ?? "Files") +
                " (\(viewModel.filteredFiles.count) files)")
            .toolbar { toolbarContent }
            .alert(viewModel.alertTitle, isPresented: $viewModel.showingAlert) {
                switch viewModel.alertType {
                case .extractJPGs:
                    Button("Extract", role: .destructive) {
                        extractFilteredFilesJPGS()
                    }
                    .frame(width: 100)

                case .createJPGDiskCache:
                    Button("Create Cache") {
                        viewModel.startScanAndExtractJPGs()
                    }
                    .frame(width: 100)

                case .clearRatedFiles:
                    Button("Clear", role: .destructive) {
                        viewModel.clearCurrentCatalogCullingState()
                    }
                    .frame(width: 100)

                case .none:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(viewModel.alertMessage)
            }
        } detail: {
            RawCullDetailContainerView(
                viewModel: viewModel,
                cgImage: $cgImage,
                nsImage: $nsImage,
                selectedFileID: $viewModel.selectedFileID,
                abort: abort,
            )
        }
        .task {
            columnVisibility = .doubleColumn
        }
        .focusedSceneValue(\.extractJPGs, $viewModel.focusExtractJPGs)
        .focusedSceneValue(\.aborttask, $viewModel.focusaborttask)
        .task {
            let handlers = CreateFileHandlers().createFileHandlers(
                fileHandler: { _ in },
                maxfilesHandler: { _ in },
                estimatedTimeHandler: { _ in },
                memorypressurewarning: viewModel.setMemoryPressureWarning,
                onExtractionNeeded: {},
            )
            await SharedMemoryCache.shared.setFileHandlers(handlers)
        }
        .inspector(isPresented: $viewModel.hideInspector) {
            FileInspectorView(
                file: viewModel.selectedFile,
            )
        }
        .fileImporter(isPresented: $viewModel.isShowingPicker, allowedContentTypes: [.folder]) { result in
            handlePickerResult(result)
        }
        .task(id: viewModel.selectedSource) {
            viewModel.startCatalogLoad(for: viewModel.selectedSource)
        }
        .onChange(of: viewModel.sortOrder) { _, _ in
            Task(priority: .background) {
                await viewModel.handleSortOrderChange()
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.memoryPressureWarning {
                MemoryWarningLabelView(
                    style: .full,
                    memoryWarningOpacity: $memoryWarningOpacity,
                    onAppearAction: startMemoryWarningFlash,
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if viewModel.softMemoryWarning {
                MemoryWarningLabelView(style: .soft)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await memoryMonitorModel.updateMemoryStats()
                let exceeded = memoryMonitorModel.usedMemory >= memoryMonitorModel.memoryPressureThreshold
                if exceeded {
                    let macOSLevel = SharedMemoryCache.shared.currentPressureLevel
                    viewModel.softMemoryWarning = macOSLevel == .normal
                } else {
                    viewModel.softMemoryWarning = false
                }
            }
        }
        .onChange(of: viewModel.memoryPressureWarning) { _, newValue in
            if newValue {
                startMemoryWarningFlash()
            }
        }
    }

    func abort() {
        viewModel.abort()
    }

    private func startMemoryWarningFlash() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            memoryWarningOpacity = 0.8
        }
    }
}
