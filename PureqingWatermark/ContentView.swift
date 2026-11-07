import SwiftUI
import Vision
import PhotosUI
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas ratio
private enum PWMCanvasRatio: String, CaseIterable, Identifiable, Sendable {
    case original = "原图比例"
    case square = "1:1"
    case portrait45 = "4:5"
    case portrait34 = "3:4"
    case story916 = "9:16"

    var id: String { rawValue }

    nonisolated func value(for sourceSize: CGSize) -> CGFloat {
        switch self {
        case .original:
            return sourceSize.width / max(sourceSize.height, 1)
        case .square:
            return 1.0
        case .portrait45:
            return 4.0 / 5.0
        case .portrait34:
            return 3.0 / 4.0
        case .story916:
            return 9.0 / 16.0
        }
    }
}

// MARK: - Imported frame asset
// 相框素材建议使用带透明中空区域的 PNG；相框方向始终保持原始状态。
struct PWMFrameAsset: Identifiable, @unchecked Sendable {
    let id: UUID
    var name: String
    var image: UIImage
    // 透明照片窗口的外接矩形（0...1 归一化坐标）。
    var aperture: CGRect?
    // 精确逐像素透明窗口蒙版：只允许照片显示在相框内部真正透明的区域。
    var apertureMask: UIImage?
    init(
        id: UUID = UUID(),
        name: String,
        image: UIImage,
        aperture: CGRect?,
        apertureMask: UIImage?
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.aperture = aperture
        self.apertureMask = apertureMask
    }
}

// Watermark eraser strokes are stored in normalized canvas coordinates so the same
// edit is used consistently by preview and full-resolution batch export.
private struct PWMEraserStroke: Identifiable, @unchecked Sendable {
    let id: UUID
    var points: [CGPoint]
    var brushSize: CGFloat
    var softness: CGFloat

    init(id: UUID = UUID(), points: [CGPoint], brushSize: CGFloat, softness: CGFloat = 0.6) {
        self.id = id
        self.points = points
        self.brushSize = brushSize
        self.softness = softness
    }
}

// MARK: - Compact editor tabs
private enum PWMStudioTab: String, CaseIterable, Identifiable {
    case image = "调整", watermark = "水印", frame = "相框", output = "输出"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .image: return "slider.horizontal.3"
        case .watermark: return "seal"
        case .frame: return "rectangle.inset.filled"
        case .output: return "square.and.arrow.up"
        }
    }
}

// MARK: - File-backed source photos
// 原图仅保存文件 URL 和少量元信息；UI 只读取独立缩略图，预览/导出时再按需解码。
private struct PWMSourcePhoto: Identifiable, Sendable {
    let id: UUID
    let originalURL: URL
    let thumbnailURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let fileExtension: String
}

// NSCache 会在系统内存压力下自动淘汰缩略图；磁盘缩略图可在缓存被淘汰后快速重载。
private final class PWMSourceThumbnailCache: @unchecked Sendable {
    static let shared = PWMSourceThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(for id: UUID) -> UIImage? {
        cache.object(forKey: id.uuidString as NSString)
    }

    func insert(_ image: UIImage, for id: UUID) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: id.uuidString as NSString, cost: cost)
    }

    func remove(_ id: UUID) {
        cache.removeObject(forKey: id.uuidString as NSString)
    }
}

// 人脸框按原图文件缓存；仅在开关开启时检测，避免拖动参数时重复运行 Vision。
private final class PWMFaceRegionCache: @unchecked Sendable {
    static let shared = PWMFaceRegionCache()
    let values = NSCache<NSURL, NSArray>()
    private init() { values.countLimit = 320 }
}

private struct PWMWatermarkStrip: @unchecked Sendable {
    let image: UIImage
    let rotation: Double
    let scale: Double
    let offsetX: Double
    let offsetY: Double
}

// MARK: - Main view
struct ContentView: View {
    // CIContext 支持并发渲染；复用预览上下文，避免每次滑动参数重新创建 GPU 资源。
    nonisolated private static let previewCIContext = CIContext(options: [.cacheIntermediates: false])
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var sourceImages: [PWMSourcePhoto] = []
    @State private var sourcePhotosDirectoryURL: URL? = nil
    @State private var selectedImageIndex = 0
    @State private var isImportingSource = false
    @State private var importedPhotoCount = 0
    @State private var importingPhotoCount = 0
    // 长按顶部缩略图进入多选删除模式。
    @State private var isSelectingSourceImages = false
    @State private var selectedSourceImageIndices: Set<Int> = []
    @State private var selectedControlTab: PWMStudioTab = .image
    @State private var showsControlMenu = false

    @State private var watermarkPickerItems: [PhotosPickerItem] = []
    @State private var replacementWatermarkItem: PhotosPickerItem?
    @State private var replacementWatermarkID: UUID?
    @State private var presetsLoaded = false
    @State private var isLoadingWatermarks = false
    @State private var watermarkLayers: [PWMStudioWatermarkAsset] = []
    // 用户本次要参与输出的水印，最多选择三张；每张水印独立使用标准或叠加混合模式。
    @State private var selectedWatermarkIDs: Set<UUID> = []
    @State private var selectedWatermarkID: UUID? = nil
    // 多层开关关闭时只绘制一轮；开启后按当前选中的水印顺序重复绘制。
    @State private var multiLayerWatermarkEnabled = false
    @State private var watermarkLayerCount = 2

    // 橡皮擦在涂抹区域恢复清晰照片，保留完整水印。
    @State private var blurEnabled = false
    @State private var autoFaceRestoreEnabled = false
    @State private var blurAmount: Double = 2
    @State private var imageBrightness: Double = 100
    @State private var canvasRatio: PWMCanvasRatio = .original

    // 可导入多款相框素材；当前选中的相框同时用于预览与批量输出。
    @State private var framePickerItems: [PhotosPickerItem] = []
    @State private var frameAssets: [PWMFrameAsset] = []
    @State private var selectedFrameID: UUID? = nil
    @State private var previewShowsFrame = true
    @State private var stripPickerItem: PhotosPickerItem?
    @State private var framePresetsLoaded = false
    @State private var stripPresetID = UUID()
    @State private var stripImage: UIImage?
    @State private var stripEnabled = false
    @State private var stripEditing = false
    @State private var stripRotation: Double = 0
    @State private var stripScale: Double = 1
    @State private var stripOffsetX: Double = 0
    @State private var stripOffsetY: Double = 0.3
    @GestureState private var stripLiveDrag: CGSize = .zero
    @GestureState private var stripLiveScale: CGFloat = 1
    @GestureState private var stripLiveRotation: Angle = .zero

    // 手动校准相框内的照片：相框始终保持原始方向，不再自动跟随窗口旋转。
    // 这组参数同时用于实时预览与相框批量输出。
    @State private var photoRotationDegrees: Double = 0
    @State private var photoZoomScale: Double = 1.0

    @State private var previewImage: UIImage?
    // 相框模式下把照片/水印与相框拆成两个预览层：只变换照片层，相框始终固定。
    @State private var previewPhotoLayer: UIImage?
    @State private var previewFrameLayer: UIImage?
    // 预览渲染延迟合并高频滑块变化，并在后台队列完成 Core Image / 位图合成。
    @State private var previewDebounceTask: Task<Void, Never>?
    @State private var previewRenderTask: Task<UIImage?, Never>?
    @State private var previewRenderGeneration = UUID()
    @GestureState private var livePhotoDrag: CGSize = .zero
    @GestureState private var livePhotoMagnification: CGFloat = 1.0
    @GestureState private var livePhotoRotation: Angle = .zero
    @State private var photoOffsetX: Double = 0
    @State private var photoOffsetY: Double = 0

    // 橡皮擦：路径使用 0...1 归一化坐标，导出时按原尺寸重绘。
    @State private var isEraserEnabled = false
    @State private var isFrameCalibrationEnabled = false
    @State private var eraserBrushSize: CGFloat = 0.06
    @State private var eraserSoftness: Double = 60
    @State private var eraserStrokes: [PWMEraserStroke] = []
    @State private var liveEraserScreenPoints: [CGPoint] = []

    // 成品逐张编码到临时文件，避免把几十张全分辨率 UIImage 长时间留在内存中。
    // 保存到系统相册时直接从文件 URL 创建资产，不再重新解码整组图片。
    @State private var normalGeneratedFileURLs: [URL] = []
    @State private var framedGeneratedFileURLs: [URL] = []
    @State private var normalGeneratedCount = 0
    @State private var framedGeneratedCount = 0

    @StateObject private var batchProgress = PWMBatchProgress()
    @State private var isGeneratingNormal = false
    @State private var isGeneratingFramed = false
    @State private var isSavingNormal = false
    @State private var isSavingFramed = false

    @State private var showAlert = false
    @State private var alertMessage = ""


    private var currentSourcePhoto: PWMSourcePhoto? {
        guard sourceImages.indices.contains(selectedImageIndex) else { return nil }
        return sourceImages[selectedImageIndex]
    }

    var body: some View {
        NavigationStack {
            alertBoundScreen
        }
        .tint(.blue)
        .accentColor(.blue)
        .task { await restoreWatermarkPresets(); await restoreFramePresets() }
    }

    // 把导航、照片/水印/相框监听拆开，降低 SwiftUI 单个表达式的类型推断负担。
    private var configuredScreen: some View {
        mainContent
            .navigationTitle("纯情の水印机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { appToolbar }
            .tint(.blue)
    }

    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            PhotosPicker(
                selection: $photoPickerItems,
                maxSelectionCount: nil,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("导入照片", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入照片")
            .disabled(isAnyTaskRunning)
        }
    }

    private var photoObservedScreen: some View {
        configuredScreen
            .onChange(of: photoPickerItems) { _, items in
                Task { await loadSourcePhotos(items) }
            }
            .onChange(of: watermarkPickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadWatermarks(items) }
            }
    }

    private var watermarkObservedScreen: some View {
        photoObservedScreen
            .onChange(of: selectedWatermarkID) { _, _ in refreshPreview() }
            .onChange(of: selectedWatermarkIDs) { _, _ in refreshPreview(); saveWatermarkPresets() }
            .onChange(of: replacementWatermarkItem) { _, item in
                guard let item, let id = replacementWatermarkID else { return }
                Task { await replaceWatermark(item, id: id) }
            }
            .onChange(of: multiLayerWatermarkEnabled) { _, _ in refreshPreview() }
            .onChange(of: watermarkLayerCount) { _, _ in refreshPreview() }
            .onChange(of: selectedImageIndex) { _, _ in refreshPreview() }
            .onChange(of: blurEnabled) { _, enabled in
                if !enabled {
                    isEraserEnabled = false
                    liveEraserScreenPoints.removeAll()
                }
                refreshPreview()
            }
            .onChange(of: autoFaceRestoreEnabled) { _, _ in refreshPreview() }
            .onChange(of: blurAmount) { _, _ in refreshPreview() }
            .onChange(of: imageBrightness) { _, _ in refreshPreview() }
            .onChange(of: canvasRatio) { _, _ in refreshPreview() }
            .onChange(of: watermarkLayers) { _, _ in refreshPreview(); saveWatermarkPresets() }
    }

    private var frameObservedScreen: some View {
        watermarkObservedScreen
            .onChange(of: framePickerItems) { _, items in
                Task { await loadFrameAssets(items) }
            }
            .onChange(of: stripPickerItem) { _, item in
                guard let item else { return }
                Task { await loadWatermarkStrip(item) }
            }
            .onChange(of: frameAssets.map(\.id)) { _, _ in persistFramePresets() }
            .onChange(of: stripPresetID) { _, _ in persistFramePresets() }
            .onChange(of: stripEnabled) { _, _ in persistFramePresets() }
            .onChange(of: [stripRotation, stripScale, stripOffsetX, stripOffsetY, photoRotationDegrees, photoZoomScale, photoOffsetX, photoOffsetY]) { _, _ in persistFramePresets() }
            .onChange(of: selectedFrameID) { _, _ in refreshPreview(); persistFramePresets() }
            .onChange(of: previewShowsFrame) { _, _ in refreshPreview(); persistFramePresets() }
    }

    private var alertBoundScreen: some View {
        frameObservedScreen
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
    }

    // MARK: iOS Photos-inspired editing workspace
    private var mainContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                previewSection
                    .overlay(alignment: .top) {
                        if isImportingSource {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在导入 \(importedPhotoCount) / \(importingPhotoCount)")
                                    .font(.caption.monospacedDigit())
                            }
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 12)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                if batchProgress.isRunning {
                    HStack {
                        ProgressView(value: Double(batchProgress.processed), total: Double(max(batchProgress.total, 1)))
                        Text("\(batchProgress.processed)/\(batchProgress.total)")
                            .font(.caption.monospacedDigit())
                        Button(batchProgress.cancellationRequested ? "停止中" : "取消") { batchProgress.cancel() }
                            .disabled(batchProgress.cancellationRequested)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 6)
                }
                sourceFilmstrip
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)

                if showsControlMenu {
                    controlMenuPanel
                        .frame(height: min(330, geometry.size.height * 0.44))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    controlTabPicker
                        .frame(maxWidth: 400)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }

    private var controlMenuPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedControlTab.rawValue)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成", action: closeControlMenu)
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)

            ScrollView(.vertical, showsIndicators: true) {
                activeControlPanel
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
            }
            .id(selectedControlTab)
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            controlTabPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 800)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .tint(.blue)
    }

    private func closeControlMenu() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showsControlMenu = false
        }
    }

    @ViewBuilder
    private var sourceFilmstrip: some View {
        if sourceImages.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("照片", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                Text("从照片图库导入图片，开始添加水印和相框。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PhotosPicker(selection: $photoPickerItems, maxSelectionCount: nil, matching: .images, photoLibrary: .shared()) {
                    Label("选择照片", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .pwmGlassSurface(cornerRadius: 20)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text("照片")
                        .font(.subheadline.weight(.semibold))
                    Text(isSelectingSourceImages ? "已选择 \(selectedSourceImageIndices.count) 张" : "\(sourceImages.count) 张")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isSelectingSourceImages {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSelectingSourceImages = false
                                selectedSourceImageIndices.removeAll()
                            }
                        } label: {
                            Text("取消")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(width: 54, height: 28)
                                .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7))
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteSelectedSourceImages()
                        } label: {
                            Text("删除")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 54, height: 28)
                                .background(Color.red, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedSourceImageIndices.isEmpty || isAnyTaskRunning)
                    } else {
                        Text("长按可删除")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(sourceImages.indices, id: \.self) { index in
                            sourceThumbnail(at: index)
                        }
                    }
                    .frame(height: 48)
                    .padding(.vertical, 4)
                }
                .frame(height: 56)
                .accessibilityLabel("已导入照片缩略图")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .pwmGlassSurface(cornerRadius: 20)
        }
    }

    private func sourceThumbnail(at index: Int) -> some View {
        let marked = selectedSourceImageIndices.contains(index)
        let isCurrent = selectedImageIndex == index
        let borderColor: Color = isSelectingSourceImages && marked
            ? .red
            : (!isSelectingSourceImages && isCurrent ? .accentColor : .clear)
        let borderWidth: CGFloat = (isCurrent || marked) ? 2 : 0

        return ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = thumbnailImage(for: sourceImages[index]) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            thumbnailSelectionBadge(isMarked: marked, isCurrent: isCurrent)
        }
        .frame(width: 48, height: 48)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(sourceThumbnailGesture(index: index))
        .accessibilityLabel("第 \(index + 1) 张图片")
        .accessibilityHint(isSelectingSourceImages ? "点按选择或取消选择，长按可删除" : "点按切换照片，长按可删除")
    }

    private func thumbnailImage(for photo: PWMSourcePhoto) -> UIImage? {
        if let cached = PWMSourceThumbnailCache.shared.image(for: photo.id) {
            return cached
        }
        // 仅在 NSCache 已淘汰时读取 256px 的磁盘缩略图，不会触碰原图文件。
        guard let image = UIImage(contentsOfFile: photo.thumbnailURL.path) else { return nil }
        PWMSourceThumbnailCache.shared.insert(image, for: photo.id)
        return image
    }

    @ViewBuilder
    private func thumbnailSelectionBadge(isMarked: Bool, isCurrent: Bool) -> some View {
        if isSelectingSourceImages {
            Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(isMarked ? Color.red : Color.white, Color.black.opacity(0.38))
                .padding(3)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white, Color.accentColor)
                .padding(3)
        }
    }

    private func sourceThumbnailGesture(index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 32)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first(_):
                    enterSourceImageSelection(at: index)
                case .second(_):
                    handleSourceImageTap(at: index)
                }
            }
    }

    private func handleSourceImageTap(at index: Int) {
        guard sourceImages.indices.contains(index) else { return }
        if isSelectingSourceImages {
            withAnimation(.easeInOut(duration: 0.15)) {
                if selectedSourceImageIndices.contains(index) {
                    selectedSourceImageIndices.remove(index)
                    if selectedSourceImageIndices.isEmpty {
                        isSelectingSourceImages = false
                    }
                } else {
                    selectedSourceImageIndices.insert(index)
                }
            }
        } else {
            selectedImageIndex = index
        }
    }

    private func enterSourceImageSelection(at index: Int) {
        guard sourceImages.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if !isSelectingSourceImages {
                isSelectingSourceImages = true
                selectedSourceImageIndices = [index]
            } else {
                selectedSourceImageIndices.insert(index)
            }
        }
    }

    // 删除顶部缩略图中勾选的待处理原图。按原始索引倒序处理，
    // 并把当前预览位置映射到删除后的数组，避免删除后预览错位。
    private func deleteSelectedSourceImages() {
        let validIndices = selectedSourceImageIndices
            .filter { sourceImages.indices.contains($0) }

        guard !validIndices.isEmpty else {
            isSelectingSourceImages = false
            selectedSourceImageIndices.removeAll()
            return
        }

        let indicesToDelete = Set(validIndices)
        let oldSelectedIndex = selectedImageIndex
        let deletedBeforeCurrent = validIndices.filter { $0 < oldSelectedIndex }.count
        let newSelectedIndex = max(0, oldSelectedIndex - deletedBeforeCurrent)
        let deletedCount = indicesToDelete.count

        let removedPhotos = sourceImages.enumerated().compactMap { index, photo in
            indicesToDelete.contains(index) ? photo : nil
        }
        for photo in removedPhotos {
            PWMSourceThumbnailCache.shared.remove(photo.id)
            try? FileManager.default.removeItem(at: photo.originalURL)
            try? FileManager.default.removeItem(at: photo.thumbnailURL)
        }
        sourceImages = sourceImages.enumerated().compactMap { index, photo in
            indicesToDelete.contains(index) ? nil : photo
        }

        if sourceImages.isEmpty {
            selectedImageIndex = 0
            if let directory = sourcePhotosDirectoryURL {
                try? FileManager.default.removeItem(at: directory)
                sourcePhotosDirectoryURL = nil
            }
        } else {
            // 如果当前照片被删除，优先显示它原位置上的下一张；
            // 若已到末尾，则自动回退到最后一张剩余照片。
            selectedImageIndex = min(newSelectedIndex, sourceImages.count - 1)
        }

        isSelectingSourceImages = false
        selectedSourceImageIndices.removeAll()

        // 原图列表变化后，旧批量结果不再对应当前素材，清空以防误保存。
        Self.removeGeneratedFiles(normalGeneratedFileURLs)
        Self.removeGeneratedFiles(framedGeneratedFileURLs)
        normalGeneratedFileURLs.removeAll()
        framedGeneratedFileURLs.removeAll()
        normalGeneratedCount = 0
        framedGeneratedCount = 0
        refreshPreview()

        alertMessage = "已从待处理列表删除 \(deletedCount) 张图片。原始照片不会从系统相册删除。"
        showAlert = true
    }

    private var previewSection: some View {
        VStack(spacing: 10) {
            previewCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !showsControlMenu {
                HStack(spacing: 12) {
                    workspaceToolRail
                    Spacer(minLength: 0)
                    if !sourceImages.isEmpty {
                        Text("\(selectedImageIndex + 1) / \(sourceImages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 16)
                if stripEditing && stripEnabled {
                    stripAdjustmentPanel.padding(.horizontal, 16)
                } else if isFrameCalibrationEnabled && selectedFrame != nil && previewShowsFrame {
                    photoAdjustmentControls.frame(height: 72)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: isEraserEnabled)
        .animation(.easeInOut(duration: 0.2), value: isFrameCalibrationEnabled)
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            previewCanvasContent(size: geometry.size)
        }
    }

    @ViewBuilder
    private func previewCanvasContent(size: CGSize) -> some View {
        Group {
            if previewShowsFrame, let frameImage = previewFrameLayer {
                framePreviewCanvas(frameImage: frameImage, canvasSize: size)
            } else {
                standardPreviewCanvas(image: previewImage, canvasSize: size)
            }
        }
        // 独立覆盖层始终绘制在照片、相框和校准工具层上方。
        .overlay {
            if stripEnabled, let stripImage,
               let baseImage = (previewShowsFrame ? previewFrameLayer : nil) ?? previewImage {
                let container = CGRect(origin: .zero, size: size)
                let photoBounds = previewShowsFrame && previewFrameLayer != nil ? container : container.insetBy(dx: 5, dy: 5)
                let area = aspectFitRect(for: baseImage.size, in: photoBounds)
                stripPreview(stripImage, area: area)
            }
        }
    }

    private var activeWatermarkStrip: PWMWatermarkStrip? {
        guard stripEnabled, let stripImage else { return nil }
        return PWMWatermarkStrip(image: stripImage, rotation: stripRotation, scale: stripScale,
                                 offsetX: stripOffsetX, offsetY: stripOffsetY)
    }

    private func stripPreview(_ image: UIImage, area: CGRect) -> some View {
        let base = Self.stripBaseSize(image.size, canvas: area.size)
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: base.width, height: base.height)
                .overlay {
                    if stripEditing {
                        Rectangle().strokeBorder(Color.blue.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    }
                }
                .scaleEffect(min(max(CGFloat(stripScale) * stripLiveScale, 0.1), 3))
                .rotationEffect(.degrees(stripRotation) + stripLiveRotation)
                .offset(x: CGFloat(stripOffsetX) * area.width + stripLiveDrag.width,
                        y: CGFloat(stripOffsetY) * area.height + stripLiveDrag.height)
                .allowsHitTesting(false)
            // 固定画布接收触摸，水印条再小或移到边缘都能从画布继续调整。
            Rectangle().fill(Color.clear)
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 1)
                    .updating($stripLiveDrag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        stripOffsetX = min(max(stripOffsetX + Double(value.translation.width / max(area.width, 1)), -1), 1)
                        stripOffsetY = min(max(stripOffsetY + Double(value.translation.height / max(area.height, 1)), -1), 1)
                    })
                .simultaneousGesture(MagnificationGesture()
                    .updating($stripLiveScale) { value, state, _ in state = value }
                    .onEnded { value in stripScale = min(max(stripScale * Double(value), 0.1), 3) })
                .simultaneousGesture(RotationGesture()
                    .updating($stripLiveRotation) { value, state, _ in state = value }
                    .onEnded { value in stripRotation = normalizedPhotoRotation(stripRotation + value.degrees) })
                .allowsHitTesting(stripEditing && !isEraserEnabled)
        }
        .frame(width: area.width, height: area.height)
        .clipped()
        .position(x: area.midX, y: area.midY)
    }

    private var stripControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("水印条", systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                PhotosPicker(selection: $stripPickerItem, matching: .images) {
                    Text(stripImage == nil ? "导入水印条" : "更换水印条")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Toggle("使用水印条", isOn: $stripEnabled)
                .disabled(stripImage == nil)
                .onChange(of: stripEnabled) { _, enabled in if !enabled { stripEditing = false } }
            if let stripImage {
                Image(uiImage: stripImage).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 48)

            } else {
                Text("支持导入一张水印条，建议使用透明 PNG。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var stripAdjustmentPanel: some View {
        VStack(spacing: 6) {
            Text("画布任意位置拖动 · 双指缩放与旋转")
                .font(.caption2).foregroundStyle(.secondary)
            compactSlider(title: "旋转", value: $stripRotation, range: -180...180, suffix: "°")
            compactSlider(title: "大小", value: Binding(get: { stripScale * 100 }, set: { stripScale = $0 / 100 }), range: 10...300, suffix: "%")
            Button("重置水印条") {
                stripRotation = 0; stripScale = 1; stripOffsetX = 0; stripOffsetY = 0.3
            }.font(.caption)
        }
        .padding(10)
        .pwmGlassSurface(cornerRadius: 13)
    }

    @MainActor
    private func restoreFramePresets() async {
        guard !framePresetsLoaded else { return }
        do {
            if let saved = try await PWMFramePresetStore.shared.load() {
                let frames = try saved.frames.map { entry -> PWMFrameAsset in
                    guard let image = UIImage(data: entry.png) else { throw CocoaError(.fileReadCorruptFile) }
                    return PWMFrameAsset(id: entry.id, name: entry.name, image: image, aperture: nil, apertureMask: nil)
                }
                let restoredStrip: UIImage?
                if let data = saved.strip {
                    guard let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                    restoredStrip = image
                } else { restoredStrip = nil }
                frameAssets = frames
                selectedFrameID = frames.first(where: { $0.id == saved.selected })?.id ?? frames.first?.id
                previewShowsFrame = saved.showsFrame
                stripImage = restoredStrip
                stripPresetID = saved.stripID
                stripEnabled = saved.stripEnabled && restoredStrip != nil
                if saved.transform.count >= 4, saved.transform.allSatisfy({ $0.isFinite }) {
                    stripRotation = saved.transform[0]; stripScale = min(max(saved.transform[1], 0.1), 3)
                    stripOffsetX = saved.transform[2]; stripOffsetY = saved.transform[3]
                    if saved.transform.count >= 8 {
                        photoRotationDegrees = normalizedPhotoRotation(saved.transform[4])
                        photoZoomScale = min(max(saved.transform[5], 0.2), 5)
                        photoOffsetX = min(max(saved.transform[6], -1.5), 1.5)
                        photoOffsetY = min(max(saved.transform[7], -1.5), 1.5)
                    }
                }
                refreshPreview()
            }
            framePresetsLoaded = true
        } catch {
            alertMessage = "相框/水印条预设读取失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    @MainActor
    private func saveFramePresets() async throws {
        guard framePresetsLoaded else { return }
        try await PWMFramePresetStore.shared.save(frames: frameAssets, selected: selectedFrameID,
            shows: previewShowsFrame, strip: stripImage, stripID: stripPresetID, enabled: stripEnabled,
            transform: [stripRotation, stripScale, stripOffsetX, stripOffsetY, photoRotationDegrees, photoZoomScale, photoOffsetX, photoOffsetY],
            revision: DispatchTime.now().uptimeNanoseconds)
    }

    private func persistFramePresets() {
        guard framePresetsLoaded else { return }
        Task {
            do { try await saveFramePresets() }
            catch { alertMessage = "预设保存失败：\(error.localizedDescription)"; showAlert = true }
        }
    }

    @MainActor
    private func loadWatermarkStrip(_ item: PhotosPickerItem) async {
        guard framePresetsLoaded else { return }
        defer { stripPickerItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            stripImage = Self.normalizedImage(image)
            stripPresetID = UUID()
            stripRotation = 0; stripScale = 1; stripOffsetX = 0; stripOffsetY = 0.3
            stripEnabled = true
            stripEditing = false
            isEraserEnabled = false
            isFrameCalibrationEnabled = false
            try await saveFramePresets()
        } catch {
            alertMessage = "无法读取水印条，请重新选择图片。"
            showAlert = true
        }
    }

    private var workspaceToolRail: some View {
        HStack(spacing: 10) {
            if stripImage != nil && stripEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        stripEditing.toggle()
                        if stripEditing { isEraserEnabled = false; isFrameCalibrationEnabled = false }
                    }
                } label: {
                    Label("水印条调整", systemImage: stripEditing ? "chevron.down" : "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 120, height: 44)
                        .background(stripEditing ? Color.blue.opacity(0.13) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(stripEditing ? Color.blue : Color.primary)
            }
            if selectedFrame != nil && previewShowsFrame {
                frameCalibrationControl.frame(width: 120, height: 44)
            }
        }
    }

    private var eraserToggleControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isEraserEnabled.toggle()
                if isEraserEnabled { isFrameCalibrationEnabled = false; stripEditing = false }
                liveEraserScreenPoints.removeAll(keepingCapacity: true)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isEraserEnabled ? "eraser.fill" : "eraser")
                    .font(.system(size: 14, weight: .medium))
                Text("橡皮擦")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: isEraserEnabled ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isEraserEnabled ? Color.accentColor : Color.primary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isEraserEnabled ? Color.accentColor.opacity(0.13) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isEraserEnabled ? Color.accentColor.opacity(0.35) : Color(.separator).opacity(0.18), lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(currentSourcePhoto == nil || !blurEnabled)
        .opacity(currentSourcePhoto == nil || !blurEnabled ? 0.45 : 1)
        .accessibilityLabel(isEraserEnabled ? "关闭橡皮擦" : "开启橡皮擦并展开设置")
    }

    private var frameCalibrationControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isFrameCalibrationEnabled.toggle()
                if isFrameCalibrationEnabled { isEraserEnabled = false; stripEditing = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isFrameCalibrationEnabled ? "crop.rotate" : "crop")
                    .font(.system(size: 14, weight: .medium))
                Text("相框校准")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Image(systemName: isFrameCalibrationEnabled ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(isFrameCalibrationEnabled ? Color.orange : Color.primary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isFrameCalibrationEnabled ? Color.orange.opacity(0.13) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isFrameCalibrationEnabled ? Color.orange.opacity(0.35) : Color(.separator).opacity(0.18), lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFrameCalibrationEnabled ? "关闭相框照片校准" : "开启相框照片校准并展开设置")
        .accessibilityHint("开启后可在工作区拖动、缩放和旋转相框内照片")
    }

    // 橡皮擦菜单压缩为工作区下方的一行滑块与两个图标操作。
    private var eraserSettingsPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "eraser.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("笔刷")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: $eraserBrushSize, in: 0.02...0.18, step: 0.01)
                .controlSize(.mini)
                .frame(maxWidth: .infinity)
            Text("\(Int((eraserBrushSize * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 30, alignment: .trailing)
            Button(action: undoLastEraserStroke) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(eraserStrokes.isEmpty)
            .opacity(eraserStrokes.isEmpty ? 0.35 : 1)
            Button(role: .destructive, action: clearEraserStrokes) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(eraserStrokes.isEmpty)
            .opacity(eraserStrokes.isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6).allowsHitTesting(false))
    }

    private func framePreviewCanvas(frameImage: UIImage, canvasSize: CGSize) -> some View {
        let canvasRect = aspectFitRect(
            for: frameImage.size,
            in: CGRect(origin: .zero, size: canvasSize)
        )

        return ZStack {
            Rectangle().fill(Color(.systemBackground))

            ZStack {
                if let previewPhotoLayer {
                    Image(uiImage: previewPhotoLayer)
                        .resizable()
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .scaleEffect(min(max(CGFloat(photoZoomScale) * livePhotoMagnification, 0.2), 5.0))
                        .rotationEffect(Angle(degrees: photoRotationDegrees) + livePhotoRotation)
                        .offset(
                            x: CGFloat(photoOffsetX) * canvasRect.width + livePhotoDrag.width,
                            y: CGFloat(photoOffsetY) * canvasRect.height + livePhotoDrag.height
                        )
                        .allowsHitTesting(false)
                }

                Image(uiImage: frameImage)
                    .resizable()
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .allowsHitTesting(false)

                Rectangle().fill(Color.clear)
                    .frame(width: canvasRect.width, height: canvasRect.height)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1)
                                .updating($livePhotoDrag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    photoOffsetX = min(max(photoOffsetX + Double(value.translation.width / max(canvasRect.width, 1)), -1.5), 1.5)
                                    photoOffsetY = min(max(photoOffsetY + Double(value.translation.height / max(canvasRect.height, 1)), -1.5), 1.5)
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .updating($livePhotoMagnification) { value, state, _ in state = value }
                                .onEnded { value in
                                    photoZoomScale = min(max(photoZoomScale * Double(value), 0.2), 5.0)
                                }
                        )
                        .simultaneousGesture(
                            RotationGesture()
                                .updating($livePhotoRotation) { value, state, _ in state = value }
                                .onEnded { value in
                                    photoRotationDegrees = normalizedPhotoRotation(photoRotationDegrees + value.degrees)
                                }
                        )
                        .allowsHitTesting(isFrameCalibrationEnabled && !isEraserEnabled && !stripEditing)
            }
            .frame(width: canvasRect.width, height: canvasRect.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if isEraserEnabled, previewPhotoLayer != nil {
                eraserGestureOverlay(
                    canvasSize: canvasRect.size,
                    appliesPhotoTransform: true
                )
                .position(x: canvasRect.midX, y: canvasRect.midY)
            }

            if isEraserEnabled || isFrameCalibrationEnabled {
                Text(isEraserEnabled ? "涂抹恢复清晰原图 · 保留完整水印" : "画布任意位置拖动照片 · 双指缩放与旋转")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func standardPreviewCanvas(image: UIImage?, canvasSize: CGSize) -> some View {
        let insetRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 5, dy: 5)
        let imageRect = image.map { aspectFitRect(for: $0.size, in: insetRect) } ?? insetRect

        return ZStack {
            Rectangle().fill(Color(.systemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                if isEraserEnabled {
                    eraserGestureOverlay(canvasSize: imageRect.size, appliesPhotoTransform: false)
                        .position(x: imageRect.midX, y: imageRect.midY)
                }
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32))
                    Text("导入照片，开始编辑").font(.subheadline)
                }
                .foregroundStyle(.secondary)
            }

            Text(isEraserEnabled ? "涂抹恢复清晰原图 · 保留完整水印" : "点按下方缩略图切换照片")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func eraserGestureOverlay(
        canvasSize: CGSize,
        appliesPhotoTransform: Bool
    ) -> some View {
        ZStack {
            Canvas { context, size in
                guard !liveEraserScreenPoints.isEmpty else { return }
                let width = max(2, eraserBrushSize * min(size.width, size.height))
                var path = Path()
                if let first = liveEraserScreenPoints.first {
                    path.move(to: first)
                    if liveEraserScreenPoints.count == 1 {
                        path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                    } else {
                        for point in liveEraserScreenPoints.dropFirst() { path.addLine(to: point) }
                    }
                }
                context.stroke(
                    path,
                    with: .color(Color.accentColor.opacity(0.92)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    appendLiveEraserPoint(value.location)
                }
                .onEnded { value in
                    var points = liveEraserScreenPoints
                    if points.last.map({ hypot($0.x - value.location.x, $0.y - value.location.y) > 0.5 }) ?? true {
                        points.append(value.location)
                    }
                    let normalizedPoints = points.map {
                        normalizedEraserPoint(
                            from: $0,
                            canvasSize: canvasSize,
                            appliesPhotoTransform: appliesPhotoTransform
                        )
                    }
                    liveEraserScreenPoints.removeAll(keepingCapacity: true)
                    guard !normalizedPoints.isEmpty else { return }
                    let imageSpaceBrushSize: CGFloat
                    if appliesPhotoTransform {
                        imageSpaceBrushSize = eraserBrushSize / max(CGFloat(photoZoomScale), 0.2)
                    } else {
                        imageSpaceBrushSize = eraserBrushSize
                    }
                    eraserStrokes.append(
                        PWMEraserStroke(points: normalizedPoints, brushSize: imageSpaceBrushSize, softness: CGFloat(eraserSoftness / 100))
                    )
                    refreshPreview()
                }
        )
    }

    private func appendLiveEraserPoint(_ point: CGPoint) {
        guard let last = liveEraserScreenPoints.last else {
            liveEraserScreenPoints = [point]
            return
        }
        if hypot(last.x - point.x, last.y - point.y) >= 2.5 {
            liveEraserScreenPoints.append(point)
        }
    }

    private func normalizedEraserPoint(
        from screenPoint: CGPoint,
        canvasSize: CGSize,
        appliesPhotoTransform: Bool
    ) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        var point = screenPoint

        if appliesPhotoTransform {
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let dx = point.x - center.x - CGFloat(photoOffsetX) * canvasSize.width
            let dy = point.y - center.y - CGFloat(photoOffsetY) * canvasSize.height
            let radians = CGFloat(-photoRotationDegrees * .pi / 180)
            let cosine = cos(radians)
            let sine = sin(radians)
            let inverseRotatedX = dx * cosine - dy * sine
            let inverseRotatedY = dx * sine + dy * cosine
            let scale = max(CGFloat(photoZoomScale), 0.2)
            point = CGPoint(
                x: center.x + inverseRotatedX / scale,
                y: center.y + inverseRotatedY / scale
            )
        }

        return CGPoint(
            x: point.x / canvasSize.width,
            y: point.y / canvasSize.height
        )
    }

    private func undoLastEraserStroke() {
        guard !eraserStrokes.isEmpty else { return }
        eraserStrokes.removeLast()
        refreshPreview()
    }

    private func clearEraserStrokes() {
        guard !eraserStrokes.isEmpty else { return }
        eraserStrokes.removeAll()
        refreshPreview()
    }


    // 相框校准面板与橡皮擦面板共用同一套玻璃容器和高度，显示在工作区下方。
    private var photoAdjustmentControls: some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Text("旋转").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                Slider(value: $photoRotationDegrees, in: -180...180, step: 1).controlSize(.mini)
                Text("\(Int(photoRotationDegrees.rounded()))°")
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 7) {
                Text("缩放").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                Slider(value: $photoZoomScale, in: 0.2...5.0, step: 0.05).controlSize(.mini)
                Text(String(format: "%.1f×", photoZoomScale))
                    .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Button {
                    photoRotationDegrees = 0
                    photoZoomScale = 1.0
                    photoOffsetX = 0
                    photoOffsetY = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重置相框照片校准")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6).allowsHitTesting(false))
    }

    private var controlTabPicker: some View {
        HStack(spacing: 4) {
            ForEach(PWMStudioTab.allCases) { tab in
                let isSelected = showsControlMenu && selectedControlTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isSelected {
                            showsControlMenu = false
                        } else {
                            selectedControlTab = tab
                            showsControlMenu = true
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background {
                        if isSelected {
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(isSelected ? "再次点按收起菜单" : "点按展开菜单")
            }
        }
        .padding(4)
        .photosLiquidGlass()
    }

    @ViewBuilder
    private var activeControlPanel: some View {
        switch selectedControlTab {
        case .image: imageControls
        case .watermark: watermarkControls
        case .frame: frameControls
        case .output: outputControls
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("原图效果", systemImage: "wand.and.stars").font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("模糊", isOn: $blurEnabled).labelsHidden().scaleEffect(0.88)
            }
            compactSlider(title: "高斯模糊", value: $blurAmount, range: 1...10, suffix: "")
                .opacity(blurEnabled ? 1 : 0.4).disabled(!blurEnabled)
            Toggle("自动清晰人脸（含动漫）", isOn: $autoFaceRestoreEnabled)
                .font(.subheadline)
                .disabled(!blurEnabled)
            Text("自动检测真人和动漫人脸，柔和擦除脸部模糊，保留水印。未检测到人脸时不改变效果。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            eraserToggleControl.frame(height: 44)
            Text("涂抹仅恢复清晰照片，水印保持完整。请先开启高斯模糊。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEraserEnabled {
                eraserSettingsPanel.frame(height: 50)
                compactSlider(title: "边缘柔和", value: $eraserSoftness, range: 0...100, suffix: "%")
                Text("柔和度用于接下来的笔迹；0% 为硬边，越高过渡越柔和。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            compactSlider(title: "亮度", value: $imageBrightness, range: 50...150, suffix: "%")
            HStack {
                Text("输出比例").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(PWMCanvasRatio.allCases) { ratio in
                        Button {
                            canvasRatio = ratio
                        } label: {
                            if canvasRatio == ratio { Label(ratio.rawValue, systemImage: "checkmark") }
                            else { Text(ratio.rawValue) }
                        }
                    }
                } label: {
                    Label(canvasRatio.rawValue, systemImage: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.10)).clipShape(Capsule())
                }
            }
        }
        .padding(14).pwmGlassSurface(cornerRadius: 18)
    }

    private var watermarkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            watermarkControlsHeader
            watermarkSelectionSummary
            if watermarkLayers.isEmpty {
                watermarkEmptyState
            } else {
                watermarkAssetCarousel
                watermarkUsageNote
            }
            watermarkLayerSettings
        }
        .padding(10)
        .pwmGlassSurface(cornerRadius: 14)
    }

    private var watermarkControlsHeader: some View {
        HStack {
            Label("水印素材", systemImage: "seal")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(isLoadingWatermarks ? "正在保存…" : "\(watermarkLayers.count)/3 已保存")
                .font(.caption)
                .foregroundStyle(.secondary)
            PhotosPicker(
                selection: $watermarkPickerItems,
                maxSelectionCount: max(1, 3 - watermarkLayers.count),
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("添加预设", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!presetsLoaded || isLoadingWatermarks || watermarkLayers.count >= 3)
        }
    }

    private var watermarkSelectionSummary: some View {
        HStack(spacing: 8) {
            Text("最多保留 3 个预设，自动保存；点击更换可替换素材。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("已选 \(selectedWatermarkIDs.count)/3")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(selectedWatermarkIDs.isEmpty ? Color.secondary : Color.accentColor)
            if !selectedWatermarkIDs.isEmpty {
                Button("清空") {
                    selectedWatermarkIDs.removeAll()
                    selectedWatermarkID = nil
                }
                .font(.caption2)
            }
        }
    }

    private var watermarkEmptyState: some View {
        Text("导入最多 3 张预设水印，重启后自动恢复。标准为正常贴图；叠加为 Overlay 混合效果。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }

    private var watermarkAssetCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 9) {
                ForEach(watermarkLayers) { asset in
                    watermarkAssetCard(asset)
                }
            }
        }
    }

    private func watermarkAssetCard(_ asset: PWMStudioWatermarkAsset) -> some View {
        let isChosen = selectedWatermarkIDs.contains(asset.id)
        return VStack(spacing: 6) {
            watermarkAssetSelectionButton(asset, isChosen: isChosen)
            watermarkModePicker(for: asset)
            PhotosPicker(selection: Binding(
                get: { replacementWatermarkID == asset.id ? replacementWatermarkItem : nil },
                set: { replacementWatermarkID = asset.id; replacementWatermarkItem = $0 }
            ), matching: .images) {
                Label("更换预设", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .disabled(isLoadingWatermarks || !presetsLoaded)
        }
        .padding(7)
        .frame(width: 124)
        .pwmGlassSurface(cornerRadius: 11)
        .contextMenu {
            Button(role: .destructive) {
                removeWatermark(id: asset.id)
            } label: {
                Label("删除素材", systemImage: "trash")
            }
        }
    }

    private func watermarkAssetSelectionButton(
        _ asset: PWMStudioWatermarkAsset,
        isChosen: Bool
    ) -> some View {
        Button {
            toggleWatermarkSelection(asset.id)
        } label: {
            VStack(spacing: 4) {
                Image(uiImage: asset.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 76)
                    .padding(4)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isChosen ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        watermarkSelectionIndicator(isChosen: isChosen)
                    }
                Text(asset.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(isChosen ? "已选择" : "点选使用")
                    .font(.system(size: 9, weight: isChosen ? .semibold : .regular))
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func watermarkSelectionIndicator(isChosen: Bool) -> some View {
        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(isChosen ? Color.accentColor : Color.secondary, Color(.systemBackground))
            .padding(3)
    }

    private func watermarkModePicker(for asset: PWMStudioWatermarkAsset) -> some View {
        Picker("水印模式", selection: watermarkModeBinding(for: asset.id)) {
            ForEach(PWMWatermarkMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var watermarkUsageNote: some View {
        Text("标准：正常模式直接贴在原图上；叠加：使用 Overlay 混合模式与原图融合。最多三张水印可同时作用于同一张原图。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var watermarkLayerSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: $multiLayerWatermarkEnabled) {
                    Label("多层水印", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 4)
                watermarkLayerCountControl
            }
            Text("开启后，按已选水印顺序重复绘制；标准和叠加模式仍分别生效。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var watermarkLayerCountControl: some View {
        if multiLayerWatermarkEnabled {
            Stepper(value: $watermarkLayerCount, in: 2...10) {
                Text("重复 \(watermarkLayerCount) 层")
                    .font(.caption.monospacedDigit())
            }
            .controlSize(.small)
            .fixedSize()
        } else {
            Text("1 层")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func watermarkModeBinding(for id: UUID) -> Binding<PWMWatermarkMode> {
        Binding(
            get: { watermarkLayers.first(where: { $0.id == id })?.mode ?? .standard },
            set: { newMode in
                guard let index = watermarkLayers.firstIndex(where: { $0.id == id }) else { return }
                watermarkLayers[index].mode = newMode
            }
        )
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("相框素材库", systemImage: "rectangle.inset.filled").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(frameAssets.count) 款").font(.caption).foregroundStyle(.secondary)
                PhotosPicker(selection: $framePickerItems, maxSelectionCount: 30, matching: .images, photoLibrary: .shared()) {
                    Label("导入素材", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
            Toggle("工作区显示相框", isOn: $previewShowsFrame)
                .font(.caption).disabled(selectedFrame == nil)
            if frameAssets.isEmpty {
                Text("可一次导入多款透明 PNG 相框。选中其中一款后，工作区和批量输出都会使用当前选中的相框。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(frameAssets) { asset in
                            frameAssetCard(asset)
                        }
                    }
                }
            }
            Divider().padding(.vertical, 4)
            stripControls
            if let selectedFrame {
                Label("工作区相框：\(selectedFrame.name)", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                if let aperture = selectedFrame.aperture {
                    Text("已识别透明窗口：宽 \(Int(aperture.width * 100))% · 高 \(Int(aperture.height * 100))%")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("相框保持原始方向；选中相框后，在工作区右侧开启“相框校准”，再用设置按钮精调旋转与倍率。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("没有识别到封闭透明窗口，将尝试整幅照片铺底；建议使用中间透明、四周边框闭合的 PNG。")
                        .font(.caption2).foregroundStyle(.orange)
                }

            }
        }
        .padding(14).pwmGlassSurface(cornerRadius: 18)
    }

    private func frameAssetCard(_ asset: PWMFrameAsset) -> some View {
        let isSelected = selectedFrameID == asset.id
        return Button {
            selectedFrameID = asset.id
            previewShowsFrame = true
        } label: {
            VStack(spacing: 4) {
                Image(uiImage: asset.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 76)
                    .padding(4)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    }
                Text(asset.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                removeFrameAsset(id: asset.id)
            } label: {
                Label("删除素材", systemImage: "trash")
            }
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("批量生成与保存", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
            if batchProgress.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(batchProgress.processed), total: Double(max(batchProgress.total, 1)))
                    Text("\(batchProgress.title)：已处理 \(batchProgress.processed) / \(batchProgress.total) 张 · 成功 \(batchProgress.succeeded) 张")
                        .font(.caption.monospacedDigit())
                    Button(batchProgress.cancellationRequested ? "正在停止…" : "取消生成", role: .destructive) {
                        batchProgress.cancel()
                    }
                    .disabled(batchProgress.cancellationRequested)
                    Text("停止后保留已生成的图片，可继续保存到相册。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                normalExportCard
                framedExportCard
            }
            Text("普通输出：每张原图一张。相框输出：每张原图只使用当前选中的相框；可导入多款并切换选择。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .pwmGlassSurface(cornerRadius: 18)
    }

    private var normalExportCard: some View {
        compactExportCard(
            title: "普通输出",
            subtitle: "模糊原图 + 水印",
            count: normalGeneratedCount,
            generateTitle: isGeneratingNormal ? "生成中" : "批量生成",
            saveTitle: isSavingNormal ? "保存中" : "保存相册",
            color: .accentColor,
            generate: generateNormalBatch,
            save: saveNormalImages,
            canGenerate: !sourceImages.isEmpty,
            canSave: !normalGeneratedFileURLs.isEmpty
        )
    }

    private var framedExportCard: some View {
        compactExportCard(
            title: "相框输出",
            subtitle: "每张原图 × 当前选中相框",
            count: framedGeneratedCount,
            generateTitle: isGeneratingFramed ? "生成中" : "批量生成",
            saveTitle: isSavingFramed ? "保存中" : "保存相册",
            color: .orange,
            generate: generateFramedBatch,
            save: saveFramedImages,
            canGenerate: !sourceImages.isEmpty && selectedFrame != nil,
            canSave: !framedGeneratedFileURLs.isEmpty
        )
    }

    private func saveNormalImages() {
        saveImagesToPhotos(normalGeneratedFileURLs, includesFrame: false)
    }

    private func saveFramedImages() {
        saveImagesToPhotos(framedGeneratedFileURLs, includesFrame: true)
    }

    private func compactExportCard(title: String, subtitle: String, count: Int, generateTitle: String,
        saveTitle: String, color: Color, generate: @escaping () -> Void, save: @escaping () -> Void,
        canGenerate: Bool, canSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
            Text("已生成 \(count) 张")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            exportGenerateButton(title: generateTitle, action: generate, color: color, enabled: canGenerate)
            exportSaveButton(title: saveTitle, action: save, enabled: canSave)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func exportGenerateButton(
        title: String,
        action: @escaping () -> Void,
        color: Color,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "wand.and.stars")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .tint(color)
        .disabled(!enabled || isAnyTaskRunning)
    }

    private func exportSaveButton(
        title: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(enabled ? .green : .secondary)
        .disabled(!enabled || isAnyTaskRunning)
    }

    private func compactSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    private var selectedFrame: PWMFrameAsset? {
        guard let selectedFrameID else { return nil }
        return frameAssets.first { $0.id == selectedFrameID }
    }

    private var isAnyTaskRunning: Bool {
        isImportingSource || isGeneratingNormal || isGeneratingFramed || isSavingNormal || isSavingFramed
    }

    // MARK: File-backed source image helpers
    nonisolated private static func makeSourcePhotosDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureqingWatermark", isDirectory: true)
            .appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // ImageIO 按需解码并应用 EXIF 方向；maxPixelSize 让预览和导出都不会解码超出实际需求的像素。
    nonisolated private static func decodeSourceImage(from url: URL, maxPixelSize: Int) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    nonisolated private static func sourcePixelDimensions(from url: URL) -> (width: Int, height: Int) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as NSDictionary? else {
            return (0, 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    // 在后台完成原图落盘与小尺寸缩略图生成；返回后不会把解码后的原图留在状态中。
    nonisolated private static func storeSourcePhotoData(
        _ data: Data,
        originalURL: URL,
        thumbnailURL: URL
    ) throws -> (width: Int, height: Int) {
        try data.write(to: originalURL, options: .atomic)
        let dimensions: (width: Int, height: Int)? = try autoreleasepool {
            guard let thumbnail = Self.decodeSourceImage(from: originalURL, maxPixelSize: 256),
                  let thumbnailData = thumbnail.jpegData(compressionQuality: 0.82) else {
                return nil
            }
            try thumbnailData.write(to: thumbnailURL, options: .atomic)
            let sourceSize = Self.sourcePixelDimensions(from: originalURL)
            return sourceSize
        }
        guard let dimensions else {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw NSError(
                domain: "PureqingWatermark.SourceImport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法为该图片生成缩略图"]
            )
        }
        return dimensions
    }

    // MARK: Photo loading
    @MainActor
    private func loadSourcePhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        guard !isAnyTaskRunning else {
            alertMessage = "当前正在处理照片，请完成后再导入。"
            showAlert = true
            return
        }

        isImportingSource = true
        importedPhotoCount = 0
        importingPhotoCount = items.count
        defer {
            isImportingSource = false
            photoPickerItems = []
        }

        let importDirectory: URL
        do {
            importDirectory = try Self.makeSourcePhotosDirectory()
        } catch {
            alertMessage = "无法创建原图临时目录：\(error.localizedDescription)"
            showAlert = true
            return
        }

        var loaded: [PWMSourcePhoto] = []
        loaded.reserveCapacity(items.count)

        // 逐张从 PhotosPicker 取出数据并写盘；不构建 [UIImage]，不会把整批原图常驻内存。
        for item in items {
            defer { importedPhotoCount += 1 }
            var pendingOriginalURL: URL?
            var pendingThumbnailURL: URL?
            do {
                // Data 只在当前循环中存在；写盘后不保留它，也不创建全尺寸 UIImage。
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    continue
                }
                let preferredExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "img"
                let safeExtension = preferredExtension.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil
                    ? preferredExtension.lowercased()
                    : "img"
                let id = UUID()
                let originalURL = importDirectory.appendingPathComponent("\(id.uuidString).\(safeExtension)")
                let thumbnailURL = importDirectory.appendingPathComponent("\(id.uuidString).thumb.jpg")
                pendingOriginalURL = originalURL
                pendingThumbnailURL = thumbnailURL
                let dimensions = try await Task.detached(priority: .utility) {
                    try Self.storeSourcePhotoData(data, originalURL: originalURL, thumbnailURL: thumbnailURL)
                }.value

                let photo = PWMSourcePhoto(
                    id: id,
                    originalURL: originalURL,
                    thumbnailURL: thumbnailURL,
                    pixelWidth: dimensions.width,
                    pixelHeight: dimensions.height,
                    fileExtension: safeExtension
                )
                loaded.append(photo)
                pendingOriginalURL = nil
                pendingThumbnailURL = nil
            } catch {
                if let pendingOriginalURL { try? FileManager.default.removeItem(at: pendingOriginalURL) }
                if let pendingThumbnailURL { try? FileManager.default.removeItem(at: pendingThumbnailURL) }
                print("保存原图文件失败：\(error.localizedDescription)")
            }
        }

        guard !loaded.isEmpty else {
            try? FileManager.default.removeItem(at: importDirectory)
            alertMessage = "没有读取到有效图片，请重新选择。原图格式可能不受支持或读取失败。"
            showAlert = true
            return
        }

        let oldDirectory = sourcePhotosDirectoryURL
        for oldPhoto in sourceImages {
            PWMSourceThumbnailCache.shared.remove(oldPhoto.id)
        }
        sourceImages = loaded
        sourcePhotosDirectoryURL = importDirectory
        if let oldDirectory, oldDirectory != importDirectory {
            try? FileManager.default.removeItem(at: oldDirectory)
        }

        eraserStrokes.removeAll()
        liveEraserScreenPoints.removeAll()
        selectedImageIndex = 0
        isSelectingSourceImages = false
        selectedSourceImageIndices.removeAll()
        Self.removeGeneratedFiles(normalGeneratedFileURLs)
        Self.removeGeneratedFiles(framedGeneratedFileURLs)
        normalGeneratedFileURLs = []
        framedGeneratedFileURLs = []
        normalGeneratedCount = 0
        framedGeneratedCount = 0
        refreshPreview()
    }

    @MainActor
    private func restoreWatermarkPresets() async {
        guard !presetsLoaded else { return }
        do {
            let (assets, selected) = try await PWMWatermarkPresetStore.shared.load()
            watermarkLayers = assets
            selectedWatermarkIDs = selected
            selectedWatermarkID = assets.first(where: { selected.contains($0.id) })?.id
        } catch {
            alertMessage = "预设水印读取失败：\(error.localizedDescription)"
            showAlert = true
        }
        presetsLoaded = true
    }

    private func saveWatermarkPresets() {
        guard presetsLoaded, !isLoadingWatermarks else { return }
        let revision = DispatchTime.now().uptimeNanoseconds
        let assets = watermarkLayers
        let selected = selectedWatermarkIDs
        Task {
            do {
                try await PWMWatermarkPresetStore.shared.save(assets, selected: selected, revision: revision)
            } catch {
                alertMessage = "预设水印保存失败，请重试：\(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    @MainActor
    private func replaceWatermark(_ item: PhotosPickerItem, id: UUID) async {
        guard !isLoadingWatermarks else { return }
        isLoadingWatermarks = true
        defer { replacementWatermarkItem = nil; replacementWatermarkID = nil; isLoadingWatermarks = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            guard let index = watermarkLayers.firstIndex(where: { $0.id == id }) else { return }
            let old = watermarkLayers[index]
            let asset = PWMStudioWatermarkAsset(name: old.name, image: Self.normalizedImage(image), mode: old.mode)
            var updated = watermarkLayers
            updated[index] = asset
            var selection = selectedWatermarkIDs
            if selection.remove(id) != nil { selection.insert(asset.id) }
            // 保存完成前不发布新素材，避免强制退出时只保存了界面状态。
            try await PWMWatermarkPresetStore.shared.save(updated, selected: selection,
                revision: DispatchTime.now().uptimeNanoseconds)
            watermarkLayers = updated
            selectedWatermarkIDs = selection
            if selectedWatermarkID == id { selectedWatermarkID = asset.id }
            refreshPreview()
        } catch {
            alertMessage = "更换预设失败，原预设已保留：\(error.localizedDescription)"
            showAlert = true
        }
    }

    @MainActor
    private func loadWatermarks(_ items: [PhotosPickerItem]) async {
        guard presetsLoaded, !isLoadingWatermarks else { return }
        isLoadingWatermarks = true
        defer { watermarkPickerItems = []; isLoadingWatermarks = false }
        var newlyLoaded: [PWMStudioWatermarkAsset] = []

        for (index, item) in items.prefix(max(0, 3 - watermarkLayers.count)).enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let assetName = "水印素材 \(watermarkLayers.count + newlyLoaded.count + 1)"
                    newlyLoaded.append(PWMStudioWatermarkAsset(
                        name: assetName,
                        image: Self.normalizedImage(image),
                        mode: .standard
                    ))
                }
            } catch {
                print("读取水印素材失败（第 \(index + 1) 张）：\(error.localizedDescription)")
            }
        }

        if !newlyLoaded.isEmpty {
            let updated = watermarkLayers + newlyLoaded
            var selection = selectedWatermarkIDs
            if selection.isEmpty, let first = newlyLoaded.first { selection.insert(first.id) }
            do {
                try await PWMWatermarkPresetStore.shared.save(updated, selected: selection,
                    revision: DispatchTime.now().uptimeNanoseconds)
                watermarkLayers = updated
                selectedWatermarkIDs = selection
                if selectedWatermarkID == nil { selectedWatermarkID = newlyLoaded.first?.id }
                refreshPreview()
            } catch {
                alertMessage = "预设保存失败，未完成导入，请重试：\(error.localizedDescription)"
                showAlert = true
            }
        } else {
            alertMessage = "没有读取到水印图片，请重新选择。"
            showAlert = true
        }
    }

    @MainActor
    private func loadFrameAssets(_ items: [PhotosPickerItem]) async {
        guard framePresetsLoaded else { return }
        guard !items.isEmpty else { return }
        var newlyLoaded: [PWMFrameAsset] = []
        for (index, item) in items.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let normalized = Self.normalizedImage(image)
                    let assetName = "相框素材 \(frameAssets.count + newlyLoaded.count + 1)"
                    // 按用户要求：不自动识别窗口、不修改相框效果；保留导入 PNG 的原始外观与 Alpha 通道。
                    newlyLoaded.append(PWMFrameAsset(
                        name: assetName,
                        image: normalized,
                        aperture: nil,
                        apertureMask: nil
                    ))
                }
            } catch {
                print("读取相框素材失败（第 \(index + 1) 张）：\(error.localizedDescription)")
            }
        }

        if !newlyLoaded.isEmpty {
            frameAssets.append(contentsOf: newlyLoaded)
            if selectedFrameID == nil {
                selectedFrameID = newlyLoaded.first?.id
                previewShowsFrame = true
            }
            refreshPreview()
            do { try await saveFramePresets() }
            catch {
                alertMessage = "相框预设保存失败，请重试：\(error.localizedDescription)"
                showAlert = true
                return
            }
            alertMessage = "成功导入 \(newlyLoaded.count) 款相框。相框保持原始效果，不进行自动识别或旋转。请选择一款用于工作区和批量输出。"
            showAlert = true
        } else {
            alertMessage = "没有读取到图片素材，请重新选择相框 PNG。"
            showAlert = true
        }
        framePickerItems = []
    }

    private func removeFrameAsset(id: UUID) {
        frameAssets.removeAll { $0.id == id }
        if selectedFrameID == id {
            selectedFrameID = frameAssets.first?.id
        }
        if selectedFrame == nil {
            previewShowsFrame = false
        }
        refreshPreview()
    }

    private func removeWatermark(id: UUID) {
        watermarkLayers.removeAll { $0.id == id }
        selectedWatermarkIDs.remove(id)
        if selectedWatermarkID == id {
            selectedWatermarkID = selectedWatermarkIDs.first
        }
        refreshPreview()
    }

    private func toggleWatermarkSelection(_ id: UUID) {
        if selectedWatermarkIDs.contains(id) {
            selectedWatermarkIDs.remove(id)
            if selectedWatermarkID == id {
                selectedWatermarkID = selectedWatermarkIDs.first
            }
        } else {
            guard selectedWatermarkIDs.count < 3 else {
                alertMessage = "最多只能同时选择三张水印。请先取消一张，再选择其他水印。"
                showAlert = true
                return
            }
            selectedWatermarkIDs.insert(id)
            selectedWatermarkID = id
        }
        refreshPreview()
    }

    // MARK: Preview / rendering
    // 已勾选的水印都会绘制到同一张原图上；每张水印自己的模式决定其混合方式。
    private var watermarkLayersForPreview: [PWMStudioWatermarkAsset] {
        watermarkLayers.filter { selectedWatermarkIDs.contains($0.id) }
    }

    private func refreshPreview() {
        guard let sourcePhoto = currentSourcePhoto else {
            previewDebounceTask?.cancel()
            previewRenderTask?.cancel()
            previewRenderGeneration = UUID()
            previewImage = nil
            previewPhotoLayer = nil
            previewFrameLayer = nil
            return
        }

        previewDebounceTask?.cancel()
        previewRenderTask?.cancel()
        let generation = UUID()
        previewRenderGeneration = generation
        let sourceURL = sourcePhoto.originalURL

        previewDebounceTask = Task { @MainActor in
            // 高频滑块变化只保留最后一次；原图解码和合成均在后台执行。
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, previewRenderGeneration == generation else { return }

            let previewLayers = watermarkLayersForPreview
            let repeatCount = multiLayerWatermarkEnabled ? watermarkLayerCount : 1
            let ratioSnapshot = canvasRatio
            let blurEnabledSnapshot = blurEnabled
        let autoFaceSnapshot = autoFaceRestoreEnabled
            let blurRadiusSnapshot = blurAmount
            let brightnessSnapshot = imageBrightness
            let strokesSnapshot = eraserStrokes
            let frameSnapshot = (previewShowsFrame ? selectedFrame : nil)

            let renderTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard !Task.isCancelled, let sourceSnapshot = Self.decodeSourceImage(from: sourceURL, maxPixelSize: 1800) else {
                    return nil
                }
                guard !Task.isCancelled else { return nil }
                let renderContext = Self.previewCIContext
                if let frameSnapshot {
                    let frameAspect = frameSnapshot.image.size.width / max(frameSnapshot.image.size.height, 1)
                    return Self.makeCompositeImage(
                        source: sourceSnapshot,
                        ratio: ratioSnapshot,
                        blurEnabled: blurEnabledSnapshot,
                        blurRadius: blurRadiusSnapshot,
                        brightness: brightnessSnapshot,
                        layers: previewLayers,
                        watermarkRepeatCount: repeatCount,
                        eraserStrokes: strokesSnapshot,
                        faceRegions: autoFaceSnapshot && blurEnabledSnapshot ? Self.detectFaceRegions(from: sourceURL) : [],
                        photoRotationDegrees: 0,
                        photoZoomScale: 1,
                        photoOffsetX: 0,
                        photoOffsetY: 0,
                        canvasAspectOverride: frameAspect,
                        fitPhotoToCanvas: true,
                        frameAsset: nil,
                        maxOutputDimension: 900,
                        ciContext: renderContext
                    )
                }
                return Self.makeCompositeImage(
                    source: sourceSnapshot,
                    ratio: ratioSnapshot,
                    blurEnabled: blurEnabledSnapshot,
                    blurRadius: blurRadiusSnapshot,
                    brightness: brightnessSnapshot,
                    layers: previewLayers,
                    watermarkRepeatCount: repeatCount,
                    eraserStrokes: strokesSnapshot,
                    faceRegions: autoFaceSnapshot && blurEnabledSnapshot ? Self.detectFaceRegions(from: sourceURL) : [],
                    frameAsset: nil,
                    maxOutputDimension: 900,
                    ciContext: renderContext
                )
            }
            previewRenderTask = renderTask
            let rendered = await renderTask.value
            guard !Task.isCancelled, previewRenderGeneration == generation else { return }

            if let frameSnapshot {
                previewPhotoLayer = rendered
                previewFrameLayer = frameSnapshot.image
                previewImage = nil
            } else {
                previewPhotoLayer = nil
                previewFrameLayer = nil
                previewImage = rendered
            }
        }
    }

    private func normalizedPhotoRotation(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    nonisolated private static func makeCompositeImage(
        source: UIImage,
        ratio: PWMCanvasRatio,
        blurEnabled: Bool,
        blurRadius: Double,
        brightness: Double,
        layers: [PWMStudioWatermarkAsset],
        watermarkRepeatCount: Int,
        eraserStrokes: [PWMEraserStroke] = [],
        faceRegions: [CGRect] = [],
        watermarkStrip: PWMWatermarkStrip? = nil,
        photoRotationDegrees: Double = 0,
        photoZoomScale: Double = 1.0,
        photoOffsetX: Double = 0,
        photoOffsetY: Double = 0,
        canvasAspectOverride: CGFloat? = nil,
        fitPhotoToCanvas: Bool = false,
        frameAsset: PWMFrameAsset?,
        maxOutputDimension: CGFloat,
        ciContext: CIContext
    ) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let normalized = Self.normalizedImage(source)
        let image = Self.resizedImage(normalized, maxDimension: maxOutputDimension)
        guard let cgImage = image.cgImage else { return nil }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let longEdge = min(max(sourceSize.width, sourceSize.height), maxOutputDimension)
        // 加框输出跟随相框素材自身比例，避免相框被拉伸；普通输出仍使用用户选择的画布比例。
        let aspect: CGFloat
        if let canvasAspectOverride, canvasAspectOverride > 0 {
            aspect = canvasAspectOverride
        } else if let frameAsset, frameAsset.image.size.height > 0 {
            aspect = frameAsset.image.size.width / frameAsset.image.size.height
        } else {
            aspect = ratio.value(for: sourceSize)
        }

        let canvasSize: CGSize
        if aspect >= 1 {
            canvasSize = CGSize(width: longEdge, height: longEdge / aspect)
        } else {
            canvasSize = CGSize(width: longEdge * aspect, height: longEdge)
        }

        // 高斯模糊直接作用于整张原图。
        var processedOriginal: UIImage
        if blurEnabled && blurRadius > 0 {
            processedOriginal = Self.makeBlurredImage(image, radius: blurRadius, brightness: brightness, ciContext: ciContext) ?? image
        } else {
            processedOriginal = Self.adjustBrightness(image, brightness: brightness, ciContext: ciContext) ?? image
        }

        let sharpOriginal = eraserStrokes.isEmpty && faceRegions.isEmpty ? image :
            (Self.adjustBrightness(image, brightness: brightness, ciContext: ciContext) ?? image)
        if blurEnabled && blurRadius > 0 && !faceRegions.isEmpty {
            processedOriginal = restoreFaceRegions(in: processedOriginal, sharp: sharpOriginal, regions: faceRegions)
        }

        guard !Task.isCancelled else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // 相框 PNG 的外围可能本身也是透明的；不能先铺黑底，否则识别窗口稍有偏差就会露出黑块。
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { rendererContext in
            let canvasBounds = CGRect(origin: .zero, size: canvasSize)
            rendererContext.cgContext.clear(canvasBounds)

            if let frameAsset {
                if let aperture = frameAsset.aperture, let apertureMask = frameAsset.apertureMask {
                    // 根据透明窗口蒙版的外接范围放置照片；不自动估算或应用相框倾斜角度。
                    let apertureRect = CGRect(
                        x: canvasBounds.minX + aperture.minX * canvasBounds.width,
                        y: canvasBounds.minY + aperture.minY * canvasBounds.height,
                        width: aperture.width * canvasBounds.width,
                        height: aperture.height * canvasBounds.height
                    ).intersection(canvasBounds)

                    if !apertureRect.isNull, apertureRect.width > 1, apertureRect.height > 1 {
                        let layerFormat = UIGraphicsImageRendererFormat()
                        layerFormat.scale = 1
                        layerFormat.opaque = false
                        let layerRenderer = UIGraphicsImageRenderer(size: canvasSize, format: layerFormat)
                        let photoAndWatermarkLayer = layerRenderer.image { layerContext in
                            let context = layerContext.cgContext
                            context.clear(canvasBounds)

                            // 相框始终按原图方向绘制。只对照片与其水印应用用户手动设置的旋转/缩放，
                            // 最后仍由真实透明窗口蒙版裁切，因此相框边框和不规则窗口边缘不会被变形。
                            Self.drawAdjustedPhotoAndWatermarks(
                                processedOriginal,
                                sharpOriginal: sharpOriginal,
                                layers: layers,
                                repeatCount: watermarkRepeatCount,
                                in: apertureRect,
                                rotationDegrees: photoRotationDegrees,
                                zoomScale: photoZoomScale,
                                offsetX: photoOffsetX,
                                offsetY: photoOffsetY,
                                eraserStrokes: eraserStrokes
                            )

                            // 再用原始透明窗口逐像素蒙版收边，保留圆角和抗锯齿，不露白边。
                            apertureMask.draw(in: canvasBounds, blendMode: .destinationIn, alpha: 1)
                        }

                        photoAndWatermarkLayer.draw(in: canvasBounds)
                        // 相框永远最后绘制，原始装饰与抗锯齿边缘完整保留。
                        frameAsset.image.draw(in: canvasBounds, blendMode: .normal, alpha: 1)
                    } else {
                        Self.drawAdjustedPhotoAndWatermarks(
                            processedOriginal,
                            sharpOriginal: sharpOriginal,
                            layers: layers,
                            repeatCount: watermarkRepeatCount,
                            in: canvasBounds,
                            rotationDegrees: photoRotationDegrees,
                            zoomScale: photoZoomScale,
                            offsetX: photoOffsetX,
                            offsetY: photoOffsetY,
                            eraserStrokes: eraserStrokes
                        )
                        frameAsset.image.draw(in: canvasBounds, blendMode: .normal, alpha: 1)
                    }
                } else {
                    // 当前相框导入不做窗口自动识别：按原图比例手动调整照片，再叠加原始相框 PNG。
                    // PNG 自带的透明区域会显示照片；不透明区域保持相框原样。
                    Self.drawAdjustedPhotoAndWatermarks(
                        processedOriginal,
                        sharpOriginal: sharpOriginal,
                        layers: layers,
                        repeatCount: watermarkRepeatCount,
                        in: canvasBounds,
                        rotationDegrees: photoRotationDegrees,
                        zoomScale: photoZoomScale,
                        offsetX: photoOffsetX,
                        offsetY: photoOffsetY,
                        eraserStrokes: eraserStrokes
                    )
                    frameAsset.image.draw(in: canvasBounds, blendMode: .normal, alpha: 1)
                }
            } else {
                if fitPhotoToCanvas {
                    Self.drawAspectFit(processedOriginal, in: canvasBounds)
                } else {
                    Self.drawAspectFill(processedOriginal, in: canvasBounds)
                }
                Self.restoreSharpPhoto(sharpOriginal, in: canvasBounds,
                                       fit: fitPhotoToCanvas, strokes: eraserStrokes)
                Self.drawWatermarkLayers(
                    layers,
                    canvasBounds: canvasBounds,
                    repeatCount: watermarkRepeatCount
                )
            }
            // 水印条最后绘制，覆盖相框的不透明边框和装饰。
            if let watermarkStrip {
                Self.drawWatermarkStrip(watermarkStrip, in: canvasBounds)
            }
        }
    }

    nonisolated private static func stripBaseSize(_ image: CGSize, canvas: CGSize) -> CGSize {
        let factor = min(canvas.width * 0.8 / max(image.width, 1), canvas.height * 0.35 / max(image.height, 1))
        return CGSize(width: image.width * factor, height: image.height * factor)
    }

    nonisolated private static func drawWatermarkStrip(_ strip: PWMWatermarkStrip, in bounds: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let size = stripBaseSize(strip.image.size, canvas: bounds.size)
        context.saveGState()
        context.translateBy(x: bounds.midX + CGFloat(strip.offsetX) * bounds.width,
                            y: bounds.midY + CGFloat(strip.offsetY) * bounds.height)
        context.rotate(by: CGFloat(strip.rotation * .pi / 180))
        let scale = CGFloat(min(max(strip.scale, 0.1), 3))
        context.scaleBy(x: scale, y: scale)
        strip.image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }

    // 只变换照片与水印，绝不变换相框。照片默认按完整比例显示，
    // 再围绕窗口中心执行手动平移、旋转和缩放；最外层透明蒙版负责精确裁边。
    nonisolated private static func drawAdjustedPhotoAndWatermarks(
        _ image: UIImage,
        sharpOriginal: UIImage,
        layers: [PWMStudioWatermarkAsset],
        repeatCount: Int,
        in rect: CGRect,
        rotationDegrees: Double,
        zoomScale: Double,
        offsetX: Double = 0,
        offsetY: Double = 0,
        eraserStrokes: [PWMEraserStroke] = []
    ) {
        guard rect.width > 0, rect.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }

        // 1× 为完整显示原图的基础尺寸，不再自动铺满相框，也不因旋转自动补偿放大。
        let effectiveZoom = min(max(zoomScale, 0.2), 5.0)
        let radians = rotationDegrees * .pi / 180.0

        context.saveGState()
        context.translateBy(
            x: rect.midX + CGFloat(offsetX) * rect.width,
            y: rect.midY + CGFloat(offsetY) * rect.height
        )
        context.rotate(by: radians)
        context.scaleBy(x: effectiveZoom, y: effectiveZoom)

        let localBounds = CGRect(
            x: -rect.width / 2,
            y: -rect.height / 2,
            width: rect.width,
            height: rect.height
        )
        Self.drawAspectFit(image, in: localBounds)
        Self.restoreSharpPhoto(sharpOriginal, in: localBounds, fit: true, strokes: eraserStrokes)
        // 清晰照片与水印共用笔迹坐标，并一起跟随相框校准变换。
        Self.drawWatermarkLayers(
            layers,
            canvasBounds: localBounds,
            repeatCount: repeatCount
        )
        context.restoreGState()
    }

    nonisolated private static func detectFaceRegions(from url: URL) -> [CGRect] {
        guard !Task.isCancelled else { return [] }
        let cache = PWMFaceRegionCache.shared.values
        if let cached = cache.object(forKey: url as NSURL) as? [NSValue] {
            return cached.map { $0.cgRectValue }
        }
        guard let image = decodeSourceImage(from: url, maxPixelSize: 1600),
              let cgImage = image.cgImage else { return [] }
        let request = VNDetectFaceRectanglesRequest()
        var regions = PWMAnimeFaceDetector.detect(cgImage)
        guard !Task.isCancelled else { return [] }
        do {
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            for observation in request.results ?? [] {
                let box = observation.boundingBox
                let face = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                if !regions.contains(where: { $0.intersection(face).width * $0.intersection(face).height > min($0.width * $0.height, face.width * face.height) * 0.5 }) {
                    regions.append(face)
                }
            }
            guard !Task.isCancelled else { return [] }
            cache.setObject(regions.map { NSValue(cgRect: $0) } as NSArray, forKey: url as NSURL)
        } catch {
            // 真人检测失败时仍保留动漫检测结果，不缓存错误以便下次重试。
        }
        return regions
    }

    nonisolated private static func makeFaceMask(size: CGSize, regions: [CGRect]) -> CGImage? {
        guard !regions.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 1800 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.lighten)
        context.setShouldAntialias(false)
        for face in regions {
            let rect = CGRect(x: face.minX * CGFloat(width), y: face.minY * CGFloat(height),
                              width: face.width * CGFloat(width), height: face.height * CGFloat(height))
            guard rect.width > 0, rect.height > 0 else { continue }
            // 椭圆比人脸框略大，外缘柔化，内部保持清晰，覆盖额头与下颌。
            for step in stride(from: 32, through: 0, by: -1) {
                let t = CGFloat(step) / 32
                let factor = 0.92 + 0.38 * t
                let ellipse = CGRect(x: rect.midX - rect.width * factor / 2,
                                     y: rect.midY - rect.height * factor / 2,
                                     width: rect.width * factor, height: rect.height * factor)
                context.setFillColor(gray: 1 - t * t * (3 - 2 * t), alpha: 1)
                context.fillEllipse(in: ellipse)
            }
        }
        return context.makeImage()
    }

    nonisolated private static func restoreFaceRegions(
        in blurred: UIImage, sharp: UIImage, regions: [CGRect]
    ) -> UIImage {
        guard let mask = makeFaceMask(size: blurred.size, regions: regions) else { return blurred }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: blurred.size, format: format).image { renderer in
            let bounds = CGRect(origin: .zero, size: blurred.size)
            blurred.draw(in: bounds)
            let context = renderer.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: bounds, mask: mask)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -bounds.height)
            sharp.draw(in: bounds)
            context.restoreGState()
        }
    }

    // 笔迹生成灰度遮罩，中心恢复清晰，边缘平滑过渡。水印在此之后完整绘制。
    nonisolated private static func restoreSharpPhoto(
        _ image: UIImage, in bounds: CGRect, fit: Bool, strokes: [PWMEraserStroke]
    ) {
        guard let context = UIGraphicsGetCurrentContext(),
              let mask = makeSoftEraserMask(size: bounds.size, strokes: strokes) else { return }
        context.saveGState()
        // CGImage 遮罩采用底部原点，先翻转后裁剪，再恢复 UIKit 的绘制坐标。
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: bounds.size), mask: mask)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.maxY)
        if fit { drawAspectFit(image, in: bounds) }
        else { drawAspectFill(image, in: bounds) }
        context.restoreGState()
    }

    nonisolated private static func makeSoftEraserMask(
        size: CGSize, strokes: [PWMEraserStroke]
    ) -> CGImage? {
        guard !strokes.isEmpty, size.width > 0, size.height > 0 else { return nil }
        // 单通道、最长边 1800px，避免全分辨率导出产生额外的大型 RGBA 遮罩。
        let scale = min(1, 1800 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let maskContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        maskContext.translateBy(x: 0, y: CGFloat(height))
        maskContext.scaleBy(x: 1, y: -1)
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(bounds)
        // 取覆盖强度的最大值，来回涂抹不会累积出硬边，也不会抵消已擦出的区域。
        maskContext.setBlendMode(.lighten)
        maskContext.setShouldAntialias(false)
        for stroke in strokes where !stroke.points.isEmpty {
            let softness = min(max(stroke.softness, 0), 1)
            let steps = softness > 0 ? 24 : 0
            for step in stride(from: steps, through: 0, by: -1) {
                let t = steps > 0 ? CGFloat(step) / CGFloat(steps) : 0
                let coverage = 1 - t * t * (3 - 2 * t)
                var ring = stroke
                ring.brushSize = stroke.brushSize * max(0.02, 1 - softness + softness * t)
                maskContext.setFillColor(gray: coverage, alpha: 1)
                for segment in makeEraserBrushSegments(ring, in: bounds) {
                    maskContext.addPath(segment)
                    maskContext.fillPath()
                }
            }
        }
        return maskContext.makeImage()
    }

    nonisolated private static func drawWatermarkLayers(
        _ layers: [PWMStudioWatermarkAsset],
        canvasBounds: CGRect,
        repeatCount: Int
    ) {
        guard !layers.isEmpty,
              canvasBounds.width > 0,
              canvasBounds.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }

        context.saveGState()
        context.setShouldAntialias(true)

        // 水印始终完整绘制，橡皮擦仅影响底层照片的模糊效果。
        let safeRepeatCount = min(max(repeatCount, 1), 10)
        for _ in 0..<safeRepeatCount {
            for asset in layers {
                let blendMode: CGBlendMode = asset.mode == .overlay ? .overlay : .normal
                asset.image.draw(in: canvasBounds, blendMode: blendMode, alpha: 1.0)
            }
        }

        context.restoreGState()
    }

    // 将一条笔迹拆成互相重叠的圆头线段。这样即使用户来回涂抹或画圈，
    // 每个裁剪子区域仍是简单胶囊，不会出现 even-odd 自交路径造成的漏擦小岛。
    nonisolated private static func makeEraserBrushSegments(
        _ stroke: PWMEraserStroke,
        in canvasBounds: CGRect
    ) -> [CGPath] {
        guard !stroke.points.isEmpty else { return [] }

        let shortestEdge = min(canvasBounds.width, canvasBounds.height)
        let lineWidth = max(1, stroke.brushSize * shortestEdge)
        let radius = lineWidth / 2
        let mappedPoints = stroke.points.map { point in
            CGPoint(
                x: canvasBounds.minX + point.x * canvasBounds.width,
                y: canvasBounds.minY + point.y * canvasBounds.height
            )
        }

        guard mappedPoints.count > 1 else {
            guard let point = mappedPoints.first else { return [] }
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: lineWidth,
                height: lineWidth
            ))
            return [dot]
        }

        var segments: [CGPath] = []
        segments.reserveCapacity(mappedPoints.count - 1)

        for index in 1..<mappedPoints.count {
            let start = mappedPoints[index - 1]
            let end = mappedPoints[index]
            if hypot(end.x - start.x, end.y - start.y) < 0.01 { continue }

            let centerline = CGMutablePath()
            centerline.move(to: start)
            centerline.addLine(to: end)
            // 此 API 返回非 Optional CGPath，直接接收，避免 Optional binding 编译错误。
            let capsule = centerline.copy(
                strokingWithWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            segments.append(capsule)
        }

        return segments
    }

    // 通过逐像素 alpha 连通域识别相框窗口，并生成真实透明区域蒙版。
    // 关键区别：旧逻辑只取透明区域的外接矩形，窗口不规则/识别范围略小时会露出白边；
    // 新逻辑用蒙版逐像素裁切照片，透明窗口内每个像素都会被照片覆盖。
    private func detectTransparentFrameApertureMask(in image: UIImage) -> (rect: CGRect, mask: UIImage)? {
        guard let cgImage = image.cgImage else { return nil }

        let maxSide = 1200
        let scale = min(1.0, CGFloat(maxSide) / CGFloat(max(cgImage.width, cgImage.height)))
        let width = max(32, Int((CGFloat(cgImage.width) * scale).rounded()))
        let height = max(32, Int((CGFloat(cgImage.height) * scale).rounded()))
        let totalPixels = width * height
        let bytesPerRow = width * 4
        var sourcePixels = [UInt8](repeating: 0, count: totalPixels * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        let rendered = sourcePixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // 近乎透明的抗锯齿像素也纳入候选窗口，避免边缘留一圈白缝。
        let alphaThreshold: UInt8 = 250
        var isTransparent = [UInt8](repeating: 0, count: totalPixels)
        for index in 0..<totalPixels {
            if sourcePixels[index * 4 + 3] <= alphaThreshold {
                isTransparent[index] = 1
            }
        }

        // 第一步：从四周边缘做 8 邻域 flood-fill，标记与画布外部连通的透明背景。
        var isExterior = [UInt8](repeating: 0, count: totalPixels)
        var queue: [Int] = []
        queue.reserveCapacity(totalPixels / 4)

        func addExterior(_ index: Int) {
            if isTransparent[index] == 1 && isExterior[index] == 0 {
                isExterior[index] = 1
                queue.append(index)
            }
        }

        for x in 0..<width {
            addExterior(x)
            addExterior((height - 1) * width + x)
        }
        for y in 0..<height {
            addExterior(y * width)
            addExterior(y * width + width - 1)
        }

        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            for dy in -1...1 {
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    addExterior(next)
                }
            }
        }

        // 第二步：找出内部封闭透明连通区，挑选面积最大的真实照片窗口。
        var isVisited = [UInt8](repeating: 0, count: totalPixels)
        var bestComponent: [Int] = []
        var bestBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        var bestCount = 0

        for start in 0..<totalPixels {
            guard isTransparent[start] == 1,
                  isExterior[start] == 0,
                  isVisited[start] == 0 else { continue }

            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            isVisited[start] = 1
            head = 0
            var component: [Int] = []
            var minX = width
            var minY = height
            var maxX = -1
            var maxY = -1

            while head < queue.count {
                let index = queue[head]
                head += 1
                component.append(index)
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                // 8 邻域连接，避免对角相连的透明背景被误判为内部窗口。
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if isTransparent[next] == 1 && isExterior[next] == 0 && isVisited[next] == 0 {
                            isVisited[next] = 1
                            queue.append(next)
                        }
                    }
                }
            }

            let boundsWidth = maxX - minX + 1
            let boundsHeight = maxY - minY + 1
            let areaRatio = Double(component.count) / Double(totalPixels)
            guard boundsWidth >= width / 5,
                  boundsHeight >= height / 5,
                  areaRatio >= 0.025 else { continue }

            if component.count > bestCount {
                bestCount = component.count
                bestComponent = component
                bestBounds = (minX, minY, maxX, maxY)
            }
        }

        guard !bestComponent.isEmpty, let bounds = bestBounds else { return nil }

        // 第三步：把内部透明连通区转成逐像素 alpha 蒙版（窗口内不透明白，其他地方透明）。
        var maskPixels = [UInt8](repeating: 0, count: totalPixels * 4)
        for index in bestComponent {
            let offset = index * 4
            maskPixels[offset] = 255
            maskPixels[offset + 1] = 255
            maskPixels[offset + 2] = 255
            maskPixels[offset + 3] = 255
        }

        let maskData = Data(maskPixels) as CFData
        guard let provider = CGDataProvider(data: maskData),
              let maskCGImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }

        let maskImage = UIImage(cgImage: maskCGImage, scale: 1, orientation: .up)
        let normalizedRect = CGRect(
            x: CGFloat(bounds.minX) / CGFloat(width),
            y: CGFloat(bounds.minY) / CGFloat(height),
            width: CGFloat(bounds.maxX - bounds.minX + 1) / CGFloat(width),
            height: CGFloat(bounds.maxY - bounds.minY + 1) / CGFloat(height)
        )

        // 只保留透明窗口的轴对齐外接矩形和真实像素蒙版；不再估算倾斜角度。
        // 相框方向保持原样，照片旋转由用户在实时预览中手动控制。
        return (normalizedRect, maskImage)
    }

    // 检查水印缩略图是否真的含有透明像素。全不透明的 JPG/PNG 会用较低透明度叠加，避免遮住原图。
    private func imageHasTransparentPixels(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = 96
        let height = 96
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        var transparentCount = 0
        for index in stride(from: 3, to: pixels.count, by: 4) {
            if pixels[index] < 245 { transparentCount += 1 }
        }
        return Double(transparentCount) / Double(width * height) > 0.02
    }

    private func aspectFitRect(for imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    nonisolated private static func makeBlurredImage(
        _ image: UIImage,
        radius: Double,
        brightness: Double,
        ciContext: CIContext
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(radius * max(image.size.width, image.size.height) / 900)
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return nil }
        let adjusted = Self.adjustedCIImage(blurred, brightness: brightness)
        return Self.renderCIImage(adjusted, extent: input.extent, ciContext: ciContext)
    }

    nonisolated private static func adjustBrightness(
        _ image: UIImage,
        brightness: Double,
        ciContext: CIContext
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let adjusted = Self.adjustedCIImage(input, brightness: brightness)
        return Self.renderCIImage(adjusted, extent: input.extent, ciContext: ciContext)
    }

    nonisolated private static func adjustedCIImage(_ image: CIImage, brightness: Double) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.brightness = Float((brightness - 100.0) / 100.0 * 0.45)
        return controls.outputImage ?? image
    }

    nonisolated private static func renderCIImage(
        _ image: CIImage,
        extent: CGRect,
        ciContext: CIContext
    ) -> UIImage? {
        guard let output = ciContext.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    nonisolated private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let drawRect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        image.draw(in: drawRect)
    }

    nonisolated private static func drawAspectFit(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let drawRect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        image.draw(in: drawRect)
    }

    nonisolated private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension, maxDimension > 0 else { return image }

        let ratio = maxDimension / longest
        let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated private static func normalizedImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: Batch image generation
    // 每次只合成、编码并写入一张成品；循环内使用 autoreleasepool 释放 UIKit/Core Image 临时对象。
    // 这样内存峰值接近“一张原图 + 一张输出图”，而不是“全部输出图之和”。
    private func makeBatchOutputDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PureqingWatermark-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static func removeGeneratedFiles(_ urls: [URL]) {
        let directories = Set(urls.map { $0.deletingLastPathComponent() })
        guard !directories.isEmpty else { return }
        // 临时目录清理由后台任务执行，避免大量文件删除时阻塞界面。
        Task.detached(priority: .utility) {
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    nonisolated private static func writePNG(_ image: UIImage, to url: URL) -> Bool {
        // ImageIO 直接写文件，避免 pngData() 创建一份与整张成品同量级的 Data 缓冲。
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
              ) else {
            return false
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func generateNormalBatch() {
        guard !sourceImages.isEmpty, !isAnyTaskRunning else { return }
        guard watermarkLayers.isEmpty || !selectedWatermarkIDs.isEmpty else {
            alertMessage = "请先选择要使用的预设水印。"
            showAlert = true
            return
        }

        // 新一轮开始时释放上一轮普通输出文件，避免临时目录持续累积。
        Self.removeGeneratedFiles(normalGeneratedFileURLs)
        normalGeneratedFileURLs.removeAll()
        normalGeneratedCount = 0
        isGeneratingNormal = true
        batchProgress.begin(title: "普通输出", total: sourceImages.count)

        let sourceSnapshot = sourceImages
        let stripSnapshot = activeWatermarkStrip
        let selectedAssets = watermarkLayers.filter { selectedWatermarkIDs.contains($0.id) }
        let ratioSnapshot = canvasRatio
        let blurEnabledSnapshot = blurEnabled
        let autoFaceSnapshot = autoFaceRestoreEnabled
        let blurRadiusSnapshot = blurAmount
        let brightnessSnapshot = imageBrightness
        let repeatCount = multiLayerWatermarkEnabled ? watermarkLayerCount : 1
        let strokesSnapshot = eraserStrokes
        let outputDirectory = makeBatchOutputDirectory(prefix: "Normal")

        Task { @MainActor in
            let worker = Task.detached(priority: .utility) { () -> [URL] in
                do {
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                } catch {
                    return []
                }

                let renderContext = CIContext(options: [.useSoftwareRenderer: false])
                var outputURLs: [URL] = []
                outputURLs.reserveCapacity(sourceSnapshot.count)

                for (index, sourcePhoto) in sourceSnapshot.enumerated() {
                    if Task.isCancelled { break }
                    let fileURL = outputDirectory.appendingPathComponent(String(format: "%04d.png", index + 1))
                    let didWrite = autoreleasepool { () -> Bool in
                        guard let source = Self.decodeSourceImage(from: sourcePhoto.originalURL, maxPixelSize: 6000),
                              let output = Self.makeCompositeImage(
                            source: source,
                            ratio: ratioSnapshot,
                            blurEnabled: blurEnabledSnapshot,
                            blurRadius: blurRadiusSnapshot,
                            brightness: brightnessSnapshot,
                            layers: selectedAssets,
                            watermarkRepeatCount: repeatCount,
                            eraserStrokes: strokesSnapshot,
                            faceRegions: autoFaceSnapshot && blurEnabledSnapshot ? Self.detectFaceRegions(from: sourcePhoto.originalURL) : [],
                            watermarkStrip: stripSnapshot,
                            frameAsset: nil,
                            maxOutputDimension: 6000,
                            ciContext: renderContext
                        ) else {
                            return false
                        }
                        return Self.writePNG(output, to: fileURL)
                    }
                    if didWrite { outputURLs.append(fileURL) }
                    await batchProgress.advance(processed: index + 1, succeeded: outputURLs.count)
                }
                renderContext.clearCaches()
                return outputURLs
            }
            batchProgress.attach(worker)
            let generatedURLs = await worker.value
            let wasCancelled = worker.isCancelled
            batchProgress.finish()

            normalGeneratedFileURLs = generatedURLs
            normalGeneratedCount = generatedURLs.count
            isGeneratingNormal = false
            if wasCancelled {
                if generatedURLs.isEmpty { try? FileManager.default.removeItem(at: outputDirectory) }
                alertMessage = "普通输出已停止，保留 \(generatedURLs.count) 张成品，可保存到相册。"
            } else if generatedURLs.isEmpty {
                try? FileManager.default.removeItem(at: outputDirectory)
                alertMessage = "普通输出没有生成成品，请检查图片和水印素材后重试。"
            } else if generatedURLs.count == sourceSnapshot.count {
                alertMessage = "普通输出完成，共生成 \(generatedURLs.count) 张图片。成品已暂存到文件，保存相册时逐张导入。"
            } else {
                alertMessage = "普通输出完成，成功生成 \(generatedURLs.count) / \(sourceSnapshot.count) 张。未成功的图片可检查后重新生成。"
            }
            showAlert = true
        }
    }

    private func generateFramedBatch() {
        guard !sourceImages.isEmpty, !isAnyTaskRunning else { return }
        guard watermarkLayers.isEmpty || !selectedWatermarkIDs.isEmpty else {
            alertMessage = "请先选择要使用的预设水印。"
            showAlert = true
            return
        }
        guard let frame = selectedFrame else {
            alertMessage = "请先导入相框，并在相框素材库中选中一款。"
            showAlert = true
            return
        }

        // 新一轮开始时释放上一轮相框输出文件。
        Self.removeGeneratedFiles(framedGeneratedFileURLs)
        framedGeneratedFileURLs.removeAll()
        framedGeneratedCount = 0
        isGeneratingFramed = true
        batchProgress.begin(title: "相框输出", total: sourceImages.count)

        let sourceSnapshot = sourceImages
        let stripSnapshot = activeWatermarkStrip
        let selectedAssets = watermarkLayers.filter { selectedWatermarkIDs.contains($0.id) }
        let ratioSnapshot = canvasRatio
        let blurEnabledSnapshot = blurEnabled
        let autoFaceSnapshot = autoFaceRestoreEnabled
        let blurRadiusSnapshot = blurAmount
        let brightnessSnapshot = imageBrightness
        let repeatCount = multiLayerWatermarkEnabled ? watermarkLayerCount : 1
        let strokesSnapshot = eraserStrokes
        let rotationSnapshot = photoRotationDegrees
        let zoomSnapshot = photoZoomScale
        let offsetXSnapshot = photoOffsetX
        let offsetYSnapshot = photoOffsetY
        let frameSnapshot = frame
        let frameName = frame.name
        let outputDirectory = makeBatchOutputDirectory(prefix: "Framed")

        Task { @MainActor in
            let worker = Task.detached(priority: .utility) { () -> [URL] in
                do {
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                } catch {
                    return []
                }

                let renderContext = CIContext(options: [.useSoftwareRenderer: false])
                var outputURLs: [URL] = []
                outputURLs.reserveCapacity(sourceSnapshot.count)

                for (index, sourcePhoto) in sourceSnapshot.enumerated() {
                    if Task.isCancelled { break }
                    let fileURL = outputDirectory.appendingPathComponent(String(format: "%04d.png", index + 1))
                    let didWrite = autoreleasepool { () -> Bool in
                        guard let source = Self.decodeSourceImage(from: sourcePhoto.originalURL, maxPixelSize: 6000),
                              let output = Self.makeCompositeImage(
                            source: source,
                            ratio: ratioSnapshot,
                            blurEnabled: blurEnabledSnapshot,
                            blurRadius: blurRadiusSnapshot,
                            brightness: brightnessSnapshot,
                            layers: selectedAssets,
                            watermarkRepeatCount: repeatCount,
                            eraserStrokes: strokesSnapshot,
                            faceRegions: autoFaceSnapshot && blurEnabledSnapshot ? Self.detectFaceRegions(from: sourcePhoto.originalURL) : [],
                            watermarkStrip: stripSnapshot,
                            photoRotationDegrees: rotationSnapshot,
                            photoZoomScale: zoomSnapshot,
                            photoOffsetX: offsetXSnapshot,
                            photoOffsetY: offsetYSnapshot,
                            frameAsset: frameSnapshot,
                            maxOutputDimension: 6000,
                            ciContext: renderContext
                        ) else {
                            return false
                        }
                        return Self.writePNG(output, to: fileURL)
                    }
                    if didWrite { outputURLs.append(fileURL) }
                    await batchProgress.advance(processed: index + 1, succeeded: outputURLs.count)
                }
                renderContext.clearCaches()
                return outputURLs
            }
            batchProgress.attach(worker)
            let generatedURLs = await worker.value
            let wasCancelled = worker.isCancelled
            batchProgress.finish()

            framedGeneratedFileURLs = generatedURLs
            framedGeneratedCount = generatedURLs.count
            isGeneratingFramed = false
            if wasCancelled {
                if generatedURLs.isEmpty { try? FileManager.default.removeItem(at: outputDirectory) }
                alertMessage = "相框输出已停止，保留 \(generatedURLs.count) 张成品，可保存到相册。"
            } else if generatedURLs.isEmpty {
                try? FileManager.default.removeItem(at: outputDirectory)
                alertMessage = "相框输出没有生成成品，请检查照片和相框素材后重试。"
            } else if generatedURLs.count == sourceSnapshot.count {
                alertMessage = "已使用相框「\(frameName)」为 \(sourceSnapshot.count) 张原图生成 \(generatedURLs.count) 张成品。成品已暂存到文件。"
            } else {
                alertMessage = "相框输出完成，成功生成 \(generatedURLs.count) / \(sourceSnapshot.count) 张。"
            }
            showAlert = true
        }
    }

    // MARK: Save to Photos
    // 使用 Photos 的文件 URL API，避免把全部成品重新解码为 UIImage 再一次性写入相册。
    // Apple 文档：creationRequestForAssetFromImage(atFileURL:) 从指定图片文件创建相册资产。
    private func saveImagesToPhotos(_ fileURLs: [URL], includesFrame: Bool) {
        let availableURLs = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !availableURLs.isEmpty else {
            alertMessage = "没有可保存的成品文件，请重新批量生成。"
            showAlert = true
            return
        }

        if includesFrame {
            isSavingFramed = true
        } else {
            isSavingNormal = true
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    if includesFrame {
                        isSavingFramed = false
                    } else {
                        isSavingNormal = false
                    }
                    alertMessage = "没有相册添加权限。请在系统设置中允许本 App 添加照片。"
                    showAlert = true
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                for fileURL in availableURLs {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if includesFrame {
                        isSavingFramed = false
                    } else {
                        isSavingNormal = false
                    }

                    if success {
                        let typeName = includesFrame ? "加框图片" : "普通图片"
                        alertMessage = "已成功保存 \(availableURLs.count) 张\(typeName)到系统相册。"
                        // Photos 完成导入后，删除对应临时输出目录，释放磁盘空间。
                        Self.removeGeneratedFiles(availableURLs)
                        if includesFrame {
                            framedGeneratedFileURLs.removeAll()
                        } else {
                            normalGeneratedFileURLs.removeAll()
                        }
                    } else {
                        // 保存失败时保留临时文件，用户可以直接重试，不必重新合成。
                        alertMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")。成品文件已保留，可再次尝试保存。"
                    }
                    showAlert = true
                }
            }
        }
    }

}


// Adaptive native-style grouped surface. Navigation bars and system controls keep
// Apple's own material/glass treatment; content cards use adaptive grouped colors.
private struct PWMGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay {
                shape.strokeBorder(Color(.separator).opacity(0.22), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

private struct PWMPhotosLiquidGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.16), lineWidth: 0.5))
        }
    }
}

private extension View {
    func photosLiquidGlass() -> some View {
        modifier(PWMPhotosLiquidGlassModifier())
    }
}

private extension View {
    func pwmGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(PWMGlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}

