import Foundation
import os

/// State machine for the capture flow: scan QR / enter AWB / enter
/// container → resolve via API → surface either a confirmed shipment or
/// a typed failure.
///
/// Translated from
/// `app/src/main/kotlin/app/suply/echoair/ui/capture/CaptureViewModel.kt`.
/// Two iOS-side simplifications:
///   • No `ShipmentRepository` indirection — calls `APIClient` directly.
///     Phase 5 will introduce a Swift repository when the offline cache
///     lands.
///   • Threading is `@MainActor` end-to-end. State publishes through
///     `@Published`; SwiftUI views observe directly.
///
/// Failure dispatch matches the Android sealed-interface shape — each
/// case maps to a distinct dialog title + body via the `.copy` extension
/// in `Failure+Copy.swift`, so a consignee can tell at a glance whether
/// to retry, fix the document, contact their shipper, or wait out a
/// network blip.
@MainActor
final class CaptureViewModel: ObservableObject {

    enum Failure: Equatable {
        /// TCP never connected — no network, wrong host, captive portal, etc.
        case unreachable
        /// TCP connected but the server took too long to respond.
        case timeout
        /// Server responded with 5xx or unexpected non-2xx. `debugDetail`
        /// carries exception class info so field reports are actionable.
        case server(httpCode: Int, debugDetail: String? = nil)
        /// Server responded 2xx but the JSON shape didn't match the DTO —
        /// almost always a backend/app schema drift. Surfaces the failing
        /// field so the right team can jump on it.
        case malformedResponse(detail: String)
        /// Backend has no matching shipment for the typed AWB.
        case noShipmentForAwb(awb: String)
        /// Backend has no matching ocean shipment for the typed container
        /// number. Distinct from `.noShipmentForAwb` so the dialog can
        /// name the right reference type.
        case noShipmentForContainer(containerNumber: String)
        /// Vision AI couldn't read an AWB from the image. (Vision OCR
        /// path; manual entry can't surface this.)
        case noAwbInImage
        /// QR scanned but the backend has no record of the device (404).
        case deviceNotRegistered
        /// Device exists in the backend but isn't on any active shipment.
        case deviceNotAssigned
        /// QR payload didn't parse as a `MAC:…,SERIAL:…;` tuple or an AWB.
        case unrecognisedQr
    }

    struct State: Equatable {
        var loading: Bool = false
        var shipment: ShipmentDto? = nil
        var confidence: String? = nil
        var failure: Failure? = nil
    }

    @Published private(set) var state = State()

    private let api: APIClient
    private let logger = Logger(subsystem: "app.suply.echoair", category: "capture")

    init(api: APIClient = .shared) {
        self.api = api
    }

    // MARK: - Public entry points

    /// Manual-entry counterpart to the QR path: the user typed an AWB.
    func identifyByAwb(_ awbNumber: String) {
        let clean = awbNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        runIdentify { try await self.api.identifyShipment(awb: clean) }
    }

    /// Manual-entry path for ocean reefer shipments. Caller has already
    /// canonicalised + validated the input via `Iso6346`.
    func identifyByContainer(_ containerNumber: String) {
        let clean = containerNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        runIdentify { try await self.api.identifyShipment(container: clean) }
    }

    /// Route a scanned QR payload by shape (see `QrPayloadParser`).
    func onQrPayload(_ payload: String) {
        guard !state.loading else { return }
        switch QrPayloadParser.parse(payload) {
        case .device(let identifier):
            runDeviceLookup(identifier)
        case .awb(let awbNumber):
            runIdentify { try await self.api.identifyShipment(awb: awbNumber) }
        case .unknown:
            state = State(failure: .unrecognisedQr)
        }
    }

    func clear() {
        state = State()
    }

    // MARK: - Internals

    private func runIdentify(_ block: @escaping @Sendable () async throws -> VisionResponse) {
        guard !state.loading else { return }
        state = State(loading: true)
        Task { @MainActor in
            do {
                let resp = try await block()
                if let shipment = resp.shipment {
                    logger.info("Vision response: shipment=\(shipment.id) devices=\(shipment.devices.count) confidence=\(resp.confidence ?? "nil") transportMode=\(shipment.transportMode ?? "nil")")
                    state = State(shipment: shipment, confidence: resp.confidence)
                } else if let container = resp.containerNumber {
                    logger.info("Vision response: container_number=\(container), shipment=nil → no matching ocean shipment")
                    state = State(failure: .noShipmentForContainer(containerNumber: container))
                } else if let awb = resp.awbNumber {
                    logger.info("Vision response: awb=\(awb), shipment=nil → no active shipment")
                    state = State(failure: .noShipmentForAwb(awb: awb))
                } else {
                    logger.info("Vision response: no readable identifier")
                    state = State(failure: .noAwbInImage)
                }
            } catch {
                logger.warning("identify failed: \(String(describing: error))")
                state = State(failure: classify(error))
            }
        }
    }

    private func runDeviceLookup(_ identifier: String) {
        guard !state.loading else { return }
        state = State(loading: true)
        Task { @MainActor in
            do {
                let resp = try await api.lookupDevice(identifier: identifier)
                if let shipment = resp.shipment {
                    logger.info("Device lookup: shipment=\(shipment.id) devices=\(shipment.devices.count) for \(identifier)")
                    state = State(shipment: shipment, confidence: "high")
                } else {
                    logger.info("Device lookup: identifier=\(identifier), 2xx with shipment=nil → not on an active shipment")
                    state = State(failure: .deviceNotAssigned)
                }
            } catch APIClient.Error.http(status: 404, body: _) {
                state = State(failure: .deviceNotRegistered)
            } catch {
                logger.warning("lookup failed: \(String(describing: error))")
                state = State(failure: classify(error))
            }
        }
    }

    /// Maps any thrown Error to a Failure. Inspects `APIClient.Error` for
    /// HTTP / decoding / transport variants; falls through to URLError
    /// for raw URLSession errors not wrapped by APIClient.
    private func classify(_ error: Error) -> Failure {
        if let api = error as? APIClient.Error {
            switch api {
            case .invalidBaseURL, .invalidResponse:
                return .server(httpCode: 0, debugDetail: String(describing: api))
            case .http(let status, _):
                return .server(httpCode: status)
            case .decoding(let underlying):
                return .malformedResponse(detail: String(describing: underlying))
            case .transport(let underlying):
                return classifyTransport(underlying)
            }
        }
        return classifyTransport(error)
    }

    private func classifyTransport(_ error: Error) -> Failure {
        guard let url = error as? URLError else {
            return .unreachable     // generic IOException analog
        }
        switch url.code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .networkConnectionLost,
             .dnsLookupFailed:
            return .unreachable
        default:
            return .unreachable
        }
    }
}
