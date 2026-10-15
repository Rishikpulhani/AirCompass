import AirCompassCore
import PhotosUI
import QuickLook
import SwiftUI

struct CompanionView: View {
    @Bindable var model: CompanionModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.05), Color(red: 0.02, green: 0.07, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    dial
                    positionControls
                    alwaysOnCard
                    transferCard
                    actions
                    receivedList
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .quickLookPreview($model.previewURL, in: model.receivedFiles)
        .sheet(isPresented: $showingSettings) { SettingsSheet(model: model) }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    model.sendData(data, named: "Photo \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).\(ext)"
                        .replacingOccurrences(of: ":", with: "-"))
                }
                photoItem = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AirCompass")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.macName == nil ? Color.orange : CompassPalette.armed)
                        .frame(width: 8, height: 8)
                    Text(model.macName.map { "Connected to \($0)" } ?? "Looking for your Mac…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .tint(.white.opacity(0.8))
        }
        .padding(.top, 8)
    }

    // MARK: Dial

    private var dial: some View {
        let mirror = model.mirror
        let me = CompassNodeModel(
            id: model.identity.id, name: model.deviceName, kind: model.identity.kind,
            displayAzimuthDegrees: model.azimuthDegrees, labelDegrees: model.azimuthDegrees,
            scale: model.myScale, isTarget: model.isTargeted
        )
        let sector = mirror.map { model.sectorMode.sector(for: $0.theta) }

        return GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
                    .frame(width: size * 0.86, height: size * 0.86)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)

                CompassRadarView(
                    sectorMode: model.sectorMode,
                    nodes: [me],
                    vector: mirror.map { GestureVector(r: $0.r, theta: $0.theta) },
                    isArmed: mirror?.isArmed ?? false,
                    activeSector: sector
                ) {
                    macCore
                }
                .frame(width: size, height: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - geo.size.width / 2
                        let dy = value.location.y - geo.size.height / 2
                        // Ignore touches in the middle where the angle is unstable.
                        guard hypot(dx, dy) > size * 0.15 else { return }
                        model.dragDial(to: AngleMath.degrees(AngleMath.bearing(dx: dx, dy: -dy)))
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .sensoryFeedback(.selection, trigger: model.sectorMode.sector(forDegrees: model.azimuthDegrees))
    }

    private var macCore: some View {
        let accent = model.mirror?.isArmed == true && model.isTargeted ? CompassPalette.armed : CompassPalette.accent
        return ZStack {
            Circle().fill(.black.opacity(0.4)).frame(width: 84, height: 84)
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            if let transfer = model.currentTransfer {
                TransferRing(fraction: transfer.fraction, color: CompassPalette.armed)
                    .frame(width: 92, height: 92)
            }
            VStack(spacing: 2) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 26))
                    .foregroundStyle(accent)
                Text(model.macName ?? "Mac")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            }
        }
    }

    // MARK: Position controls

    private var positionControls: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Position").font(.headline)
                    Spacer()
                    Text("\(Int(model.azimuthDegrees.rounded()) % 360)° · sector \(model.sectorMode.sector(forDegrees: model.azimuthDegrees))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(CompassPalette.accent)
                }
                Picker("Mode", selection: $model.positionMode) {
                    ForEach(CompanionModel.PositionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch model.positionMode {
                case .acoustic:
                    Picker("This device is", selection: $model.hemisphere) {
                        ForEach(AcousticHemisphere.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Label(model.acousticStatus, systemImage: "waveform")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let last = model.lastFixDate {
                        (Text("Last reading ") + Text(last, style: .relative) + Text(" ago"))
                            .font(.caption.monospacedDigit()).foregroundStyle(CompassPalette.accent)
                    }
                    Text("Move the device and the Mac chirps right away; this device hears which speaker is closer to tell left from right. Pick which side of the Mac's screen you're on.")
                        .font(.caption).foregroundStyle(.tertiary)
                case .manual:
                    Text("Drag your device around the ring to match where it sits relative to the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .motion:
                    Button {
                        model.calibrateMotion()
                    } label: {
                        Label("Calibrate: current angle is correct", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                    Text("Rotating this device shifts its angle. Experimental: it senses turning, not moving across the room.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Always-On

    private var alwaysOnCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.alwaysOn) {
                    Label("Always-On", systemImage: "moon.zzz.fill").font(.headline)
                }
                .tint(CompassPalette.armed)
                Text("Stay reachable with the screen off or while using other apps. Uses extra battery and shows an audio/microphone indicator. Stops if you swipe the app away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Transfer

    @ViewBuilder
    private var transferCard: some View {
        if let transfer = model.currentTransfer {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        TransferRing(fraction: transfer.fraction, color: CompassPalette.armed)
                        Image(systemName: transfer.direction == .incoming ? "arrow.down" : "arrow.up")
                            .font(.headline)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transferTitle(transfer)).font(.subheadline.weight(.semibold))
                        Text(transfer.files.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func transferTitle(_ t: TransferProgress) -> String {
        switch t.state {
        case .completed: t.direction == .incoming ? "Received from \(t.peerName)" : "Sent to \(t.peerName)"
        case let .failed(reason): "Failed: \(reason)"
        default: "\(t.direction == .incoming ? "Receiving from" : "Sending to") \(t.peerName) · \(Int(t.fraction * 100))%"
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                model.sendTestFile()
            } label: {
                Label("Send Test File", systemImage: "doc.text")
                    .frame(maxWidth: .infinity)
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Send Photo", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(CompassPalette.accent.opacity(0.85))
        .foregroundStyle(.black)
        .disabled(model.macName == nil)
    }

    @ViewBuilder
    private var receivedList: some View {
        if !model.receivedFiles.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Received").font(.headline)
                    ForEach(model.receivedFiles.prefix(8), id: \.self) { url in
                        HStack {
                            Button {
                                model.previewURL = url
                            } label: {
                                Label(url.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                            }
                            Spacer()
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

private struct SettingsSheet: View {
    let model: CompanionModel
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Name") {
                    TextField("Name shown on the Mac", text: $name)
                        .onSubmit { model.rename(name) }
                }
                Section {
                    LabeledContent("Device ID", value: String(model.identity.id.prefix(8)))
                    LabeledContent("Saved files", value: "Files › On My \(model.identity.kind == .iPad ? "iPad" : "iPhone") › AirCompass")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.rename(name)
                        dismiss()
                    }
                }
            }
            .onAppear { name = model.deviceName }
        }
    }
}
