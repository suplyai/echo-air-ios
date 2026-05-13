import SwiftUI
import AVFoundation

/// QR-code scan screen. Vendored `AVCaptureMetadataOutput` wrapper —
/// SwiftUI doesn't natively render a camera preview, so a UIKit
/// view-controller is bridged via `UIViewControllerRepresentable`.
///
/// On successful scan the payload is handed to `CaptureViewModel.onQrPayload`
/// which routes via `QrPayloadParser` to either the device-lookup or
/// AWB-identify endpoint.
struct QRScanView: View {
    @ObservedObject var captureVM: CaptureViewModel
    let onConfirmShipment: () -> Void

    @State private var permissionState: PermissionState = .checking
    @State private var showConfirmSheet = false
    @State private var failureAlertPresented = false

    private enum PermissionState { case checking, granted, denied }

    var body: some View {
        ZStack {
            switch permissionState {
            case .checking:
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            case .granted:
                QRCameraView { payload in
                    EchoHaptics.tick()
                    captureVM.onQrPayload(payload)
                }
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Text("capture_title_qr")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 48)
                }
            case .denied:
                VStack(spacing: 16) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("permission_camera_rationale")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button(String(localized: "capture_permission_grant")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if captureVM.state.loading {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    .tint(.white)
            }
        }
        .navigationTitle("capture_title_qr")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await requestCameraPermission()
        }
        .onChange(of: captureVM.state.shipment) { newValue in
            showConfirmSheet = (newValue != nil)
        }
        .onChange(of: captureVM.state.failure) { newValue in
            failureAlertPresented = (newValue != nil)
        }
        .sheet(isPresented: $showConfirmSheet) {
            if let shipment = captureVM.state.shipment {
                ConfirmSheet(
                    shipment: shipment,
                    confidence: captureVM.state.confidence,
                    onConfirm: {
                        EchoHaptics.tick()
                        showConfirmSheet = false
                        onConfirmShipment()
                    },
                    onCancel: {
                        showConfirmSheet = false
                        captureVM.clear()
                    }
                )
                .presentationDetents([.large])
            }
        }
        .alert(
            captureVM.state.failure?.copy.title ?? "",
            isPresented: $failureAlertPresented,
            actions: {
                Button(String(localized: "common_ok")) { captureVM.clear() }
            },
            message: { Text(captureVM.state.failure?.copy.body ?? "") }
        )
    }

    private func requestCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .granted : .denied
        case .denied, .restricted:
            permissionState = .denied
        @unknown default:
            permissionState = .denied
        }
    }
}

/// UIKit bridge for the QR camera preview. Owns an `AVCaptureSession`
/// configured with a back camera input and a `AVCaptureMetadataOutput`
/// observing `.qr` metadata objects. Stops the session on dismissal.
private struct QRCameraView: UIViewControllerRepresentable {
    let onDetect: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let vc = QRCameraController()
        vc.onDetect = onDetect
        return vc
    }

    func updateUIViewController(_ uiViewController: QRCameraController, context: Context) { }
}

private final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onDetect: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasFiredForThisSession = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasFiredForThisSession = false
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasFiredForThisSession,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue else {
            return
        }
        hasFiredForThisSession = true
        onDetect?(payload)
    }
}
