import Foundation

extension CaptureViewModel.Failure {
    /// Localised (title, body) for the AlertDialog rendered from `state.failure`.
    /// Mirrors Android's `failureCopy(failure)` helper.
    ///
    /// The DEBUG-only suffix carries exception class info on the `.server`
    /// and `.malformedResponse` paths so field-report screenshots from
    /// pilot devices are actionable — compiled out in release per the
    /// handoff §8 "no PII in release logs" rule.
    var copy: (title: String, body: String) {
        switch self {
        case .unreachable:
            return (
                String(localized: "failure_unreachable_title"),
                String(localized: "failure_unreachable_body")
            )
        case .timeout:
            return (
                String(localized: "failure_timeout_title"),
                String(localized: "failure_timeout_body")
            )
        case .server(let httpCode, let debugDetail):
            let title = String(localized: "failure_server_title")
            var body = httpCode > 0
                ? String(format: String(localized: "failure_server_body_with_code"), httpCode)
                : String(localized: "failure_server_body_unknown")
            #if DEBUG
            if let detail = debugDetail {
                body += String(format: String(localized: "failure_debug_detail_suffix"), detail)
            }
            #endif
            return (title, body)
        case .malformedResponse(let detail):
            var body = String(localized: "failure_malformed_body")
            #if DEBUG
            body += String(format: String(localized: "failure_debug_detail_suffix"), detail)
            #endif
            return (String(localized: "failure_malformed_title"), body)
        case .noShipmentForAwb(let awb):
            return (
                String(localized: "failure_no_shipment_for_awb_title"),
                String(format: String(localized: "failure_no_shipment_for_awb_body"), awb)
            )
        case .noShipmentForContainer(let containerNumber):
            return (
                String(localized: "failure_no_shipment_for_container_title"),
                String(format: String(localized: "failure_no_shipment_for_container_body"), containerNumber)
            )
        case .noAwbInImage:
            return (
                String(localized: "failure_no_awb_in_image_title"),
                String(localized: "failure_no_awb_in_image_body")
            )
        case .deviceNotRegistered:
            return (
                String(localized: "failure_device_not_registered_title"),
                String(localized: "failure_device_not_registered_body")
            )
        case .deviceNotAssigned:
            return (
                String(localized: "failure_device_not_assigned_title"),
                String(localized: "failure_device_not_assigned_body")
            )
        case .unrecognisedQr:
            return (
                String(localized: "failure_unrecognised_qr_title"),
                String(localized: "failure_unrecognised_qr_body")
            )
        }
    }
}
