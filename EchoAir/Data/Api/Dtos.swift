import Foundation

// Wire-format DTOs for the Suply API. Translated 1:1 from
// `app/src/main/kotlin/app/suply/echoair/data/api/Dtos.kt` (Kotlin
// kotlinx.serialization) at Android v0.7.0.
//
// Auth DTOs (LoginRequest, LoginResponse, UserDto) are intentionally
// omitted — the consignee app is stateless and uses AWB / container
// number as the credential (handoff §9). Login surfaces are for other
// clients (dashboard/admin) not ported here.
//
// Translation notes:
// • Kotlin's `List<T> = emptyList()` and `Boolean = false` / `Int = 0`
//   defaults are preserved via custom `init(from:)` decoders so missing
//   JSON keys decode to the same empty/zero values as on Android.
// • Each DTO has both a `Decodable` init and an explicit memberwise
//   init with the same defaults — the latter is for UI stubs and tests.
// • `Long` (Kotlin 64-bit signed) → `Int` (also 64-bit on iOS).
// • Date-typed fields are kept as ISO-8601 `String` per §3.1 — consumers
//   parse via `ISO8601DateFormatter` when an epoch representation is
//   needed.

// MARK: - Cargo profile

/// High-level commodity profile carried on `ShipmentDto.cargoProfile`.
/// `category` (here) is the canonical source as of v0.7.0; fall back to
/// `ShipmentDto.commodityCategory` only when the profile is absent.
/// Drives the icon + accent on the Confirm Sheet.
struct CargoProfileDto: Codable, Equatable {
    let name: String?
    let category: String?
    let minTemp: Double?
    let maxTemp: Double?
    let minHumidity: Double?
    let maxHumidity: Double?

    enum CodingKeys: String, CodingKey {
        case name, category
        case minTemp = "min_temp"
        case maxTemp = "max_temp"
        case minHumidity = "min_humidity"
        case maxHumidity = "max_humidity"
    }

    init(
        name: String? = nil,
        category: String? = nil,
        minTemp: Double? = nil,
        maxTemp: Double? = nil,
        minHumidity: Double? = nil,
        maxHumidity: Double? = nil
    ) {
        self.name = name
        self.category = category
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.minHumidity = minHumidity
        self.maxHumidity = maxHumidity
    }
}

// MARK: - Shipment

/// Wire-format shipment record. Air vs ocean is dispatched via
/// `transportMode` ("air_freight" / "ocean_reefer" as of v0.7.0). The
/// `isOcean` computed property captures the defensive default:
/// unrecognised non-null modes are treated as ocean to avoid crashes on
/// new backend modes the iOS app doesn't yet know about. **Null
/// `transportMode` returns `isOcean == false`** — verbatim from Kotlin.
struct ShipmentDto: Codable, Equatable {
    let id: String
    /// Air-freight reference. nil on ocean shipments.
    let airwayBillNumber: String?
    /// Ocean-freight reference (ISO 6346, e.g. "EITU3171741"). nil on air.
    /// Top-level on the shipment, NOT nested under a sub-object.
    let containerNumber: String?
    let airOriginIata: String?
    let airOriginCity: String?
    let airDestIata: String?
    let airDestCity: String?
    /// Port of loading (UN/LOCODE or carrier-specific). Ocean only.
    let pol: String?
    /// Port of discharge. Ocean only.
    let pod: String?
    /// ISO-8601 ETA. Ocean uses a single ETA field; air uses richer
    /// schedule data not currently surfaced on this response.
    let eta: String?
    /// "air_freight" or "ocean_reefer" as of v0.7.0.
    let transportMode: String?
    let status: String
    /// Commodity name at shipment root (backend's chosen shape — not
    /// nested under cargo_profile). Drives the hero text.
    let commodityName: String?
    /// Legacy category field. Prefer `cargoProfile?.category`; fall back
    /// here only when the profile or its category is absent.
    let commodityCategory: String?
    let cargoProfile: CargoProfileDto?
    let devices: [ShipmentDeviceDto]
    /// MPS breakdown — same devices as `devices`, bucketed per unit.
    /// Empty list on pre-MPS deployments → fall back to flat-list render.
    /// Single-unit shipments arrive with size == 1.
    let units: [UnitDto]

    enum CodingKeys: String, CodingKey {
        case id
        case airwayBillNumber = "airway_bill_number"
        case containerNumber = "container_number"
        case airOriginIata = "air_origin_iata"
        case airOriginCity = "air_origin_city"
        case airDestIata = "air_dest_iata"
        case airDestCity = "air_dest_city"
        case pol, pod, eta
        case transportMode = "transport_mode"
        case status
        case commodityName = "commodity_name"
        case commodityCategory = "commodity_category"
        case cargoProfile = "cargo_profile"
        case devices, units
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        airwayBillNumber = try c.decodeIfPresent(String.self, forKey: .airwayBillNumber)
        containerNumber = try c.decodeIfPresent(String.self, forKey: .containerNumber)
        airOriginIata = try c.decodeIfPresent(String.self, forKey: .airOriginIata)
        airOriginCity = try c.decodeIfPresent(String.self, forKey: .airOriginCity)
        airDestIata = try c.decodeIfPresent(String.self, forKey: .airDestIata)
        airDestCity = try c.decodeIfPresent(String.self, forKey: .airDestCity)
        pol = try c.decodeIfPresent(String.self, forKey: .pol)
        pod = try c.decodeIfPresent(String.self, forKey: .pod)
        eta = try c.decodeIfPresent(String.self, forKey: .eta)
        transportMode = try c.decodeIfPresent(String.self, forKey: .transportMode)
        status = try c.decode(String.self, forKey: .status)
        commodityName = try c.decodeIfPresent(String.self, forKey: .commodityName)
        commodityCategory = try c.decodeIfPresent(String.self, forKey: .commodityCategory)
        cargoProfile = try c.decodeIfPresent(CargoProfileDto.self, forKey: .cargoProfile)
        devices = try c.decodeIfPresent([ShipmentDeviceDto].self, forKey: .devices) ?? []
        units = try c.decodeIfPresent([UnitDto].self, forKey: .units) ?? []
    }

    init(
        id: String,
        airwayBillNumber: String? = nil,
        containerNumber: String? = nil,
        airOriginIata: String? = nil,
        airOriginCity: String? = nil,
        airDestIata: String? = nil,
        airDestCity: String? = nil,
        pol: String? = nil,
        pod: String? = nil,
        eta: String? = nil,
        transportMode: String? = nil,
        status: String,
        commodityName: String? = nil,
        commodityCategory: String? = nil,
        cargoProfile: CargoProfileDto? = nil,
        devices: [ShipmentDeviceDto] = [],
        units: [UnitDto] = []
    ) {
        self.id = id
        self.airwayBillNumber = airwayBillNumber
        self.containerNumber = containerNumber
        self.airOriginIata = airOriginIata
        self.airOriginCity = airOriginCity
        self.airDestIata = airDestIata
        self.airDestCity = airDestCity
        self.pol = pol
        self.pod = pod
        self.eta = eta
        self.transportMode = transportMode
        self.status = status
        self.commodityName = commodityName
        self.commodityCategory = commodityCategory
        self.cargoProfile = cargoProfile
        self.devices = devices
        self.units = units
    }

    /// True iff this shipment is ocean reefer (or any non-air mode the
    /// backend reports — defensive default for unrecognised modes).
    /// **Verbatim from Kotlin: null `transportMode` returns false.**
    var isOcean: Bool {
        guard let mode = transportMode else { return false }
        return mode.caseInsensitiveCompare("air") != .orderedSame
            && mode.caseInsensitiveCompare("air_freight") != .orderedSame
    }
}

/// One physical pallet / ULD / lot inside a Multiple Package Shipment.
/// `label` is whatever the shipper configured on the dashboard ("ULD 1",
/// "Pallet A", "Lote-247", etc.) and is rendered verbatim in
/// customer-facing copy — customer's stored label always wins over
/// Suply's terminology (handoff §3.4).
struct UnitDto: Codable, Equatable, Identifiable {
    let id: String
    /// Customer-supplied label. May be nil/blank for the synthetic
    /// "Unattributed" unit.
    let label: String?
    /// Free-form physical position, e.g. "stack 3, row 2". Optional.
    let position: String?
    /// 1-based ordering on the shipment, matches dashboard display order.
    let sequenceIndex: Int?
    /// Per-unit commodity override; usually nil for homogeneous shipments.
    let commodityOverride: String?
    /// Devices bucketed under this unit. Same device objects as
    /// `ShipmentDto.devices`, filtered by `unitId`.
    let devices: [ShipmentDeviceDto]

    enum CodingKeys: String, CodingKey {
        case id, label, position
        case sequenceIndex = "sequence_index"
        case commodityOverride = "commodity_override"
        case devices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        sequenceIndex = try c.decodeIfPresent(Int.self, forKey: .sequenceIndex)
        commodityOverride = try c.decodeIfPresent(String.self, forKey: .commodityOverride)
        devices = try c.decodeIfPresent([ShipmentDeviceDto].self, forKey: .devices) ?? []
    }

    init(
        id: String,
        label: String? = nil,
        position: String? = nil,
        sequenceIndex: Int? = nil,
        commodityOverride: String? = nil,
        devices: [ShipmentDeviceDto] = []
    ) {
        self.id = id
        self.label = label
        self.position = position
        self.sequenceIndex = sequenceIndex
        self.commodityOverride = commodityOverride
        self.devices = devices
    }
}

struct ShipmentDeviceDto: Codable, Equatable, Identifiable {
    /// Stable id for SwiftUI diffing — aliases `deviceId`.
    var id: String { deviceId }

    let deviceId: String
    /// MAC address in colon-formatted form ("BC:57:29:1C:D6:A6"). Backend
    /// field is `mac_address`; older deployments may have sent `mac` —
    /// CodingKey is pinned to the canonical name.
    let mac: String?
    /// KKM serial. For Echo Air devices this is the same value as deviceId.
    let serial: String?
    let model: String?
    let status: String
    /// True once the destination consignee has scanned this device.
    let echoScanned: Bool?
    /// 1-based ordering across scans on the shipment.
    let scanSequence: Int?
    /// ISO-8601 instant of the last successful scan (kept as string per §3.1).
    let scannedAt: String?
    /// Inferred position in the cargo — free-form.
    let inferredPosition: String?
    /// Multi-unit attribution. References `UnitDto.id`; nil only for the
    /// rare "Unattributed" edge case.
    let unitId: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case mac = "mac_address"
        case serial, model, status
        case echoScanned = "echo_scanned"
        case scanSequence = "scan_sequence"
        case scannedAt = "scanned_at"
        case inferredPosition = "inferred_position"
        case unitId = "unit_id"
    }
}

struct ShipmentListResponse: Codable, Equatable {
    let shipments: [ShipmentDto]
    let total: Int

    enum CodingKeys: String, CodingKey {
        case shipments, total
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shipments = try c.decodeIfPresent([ShipmentDto].self, forKey: .shipments) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }

    init(shipments: [ShipmentDto] = [], total: Int = 0) {
        self.shipments = shipments
        self.total = total
    }
}

// MARK: - Vision

/// Identify-shipment request body. As of v0.7.0 the endpoint dispatches
/// on which identifier is present — **exactly one** of `awbNumber` (air)
/// or `containerNumber` (ocean) should be populated per request. The
/// legacy `image_base64` OCR field was removed in v0.6.1.
struct VisionRequest: Codable, Equatable {
    let awbNumber: String?
    /// ISO 6346 container number, canonicalised to 11 uppercase chars.
    /// Mutually exclusive with `awbNumber`.
    let containerNumber: String?

    enum CodingKeys: String, CodingKey {
        case awbNumber = "awb_number"
        case containerNumber = "container_number"
    }

    init(awbNumber: String? = nil, containerNumber: String? = nil) {
        self.awbNumber = awbNumber
        self.containerNumber = containerNumber
    }
}

struct VisionResponse: Codable, Equatable {
    let awbNumber: String?
    /// Echoed back when the request specified `containerNumber`. The
    /// capture VM uses whichever of the two identifier fields is non-nil
    /// to pick the right not-found Failure variant.
    let containerNumber: String?
    /// "high" | "medium" | "low"
    let confidence: String?
    let reasoning: String?
    let shipment: ShipmentDto?

    enum CodingKeys: String, CodingKey {
        case awbNumber = "awb_number"
        case containerNumber = "container_number"
        case confidence, reasoning, shipment
    }
}

// MARK: - Device lookup

struct DeviceLookupResponse: Codable, Equatable {
    let deviceId: String
    let mac: String?
    let serial: String?
    let model: String?
    let hardwareType: String?
    let shipment: ShipmentDto?
    let assigned: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case mac = "mac_address"
        case serial, model
        case hardwareType = "hardware_type"
        case shipment, assigned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        mac = try c.decodeIfPresent(String.self, forKey: .mac)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        hardwareType = try c.decodeIfPresent(String.self, forKey: .hardwareType)
        shipment = try c.decodeIfPresent(ShipmentDto.self, forKey: .shipment)
        assigned = try c.decodeIfPresent(Bool.self, forKey: .assigned) ?? false
    }
}

// MARK: - Echo scan

struct EchoScanRequest: Codable, Equatable {
    let deviceId: String
    let temperatureRecords: [ReadingDto]
    /// Phone UTC minus device UTC at start of readout (seconds). Sent
    /// unmodified — backend's fusion layer applies the correction.
    let deviceClockOffsetSeconds: Int?
    /// Consignee location at the moment this device was successfully
    /// collected. Optional — omitted when user declined opt-in, OS
    /// permission missing, or fix timed out.
    let location: LocationDto?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case temperatureRecords = "temperature_records"
        case deviceClockOffsetSeconds = "device_clock_offset_seconds"
        case location
    }
}

/// Point-in-time location fix attached to a single /api/echo-scan POST.
/// One-shot at the moment of successful GATT collection — not
/// continuous tracking (handoff §3.6).
struct LocationDto: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    /// Horizontal accuracy radius in metres.
    let accuracyM: Float
    /// ISO-8601 UTC instant, e.g. "2026-04-24T11:42:00.000Z".
    let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case accuracyM = "accuracy_m"
        case capturedAt = "captured_at"
    }
}

struct ReadingDto: Codable, Equatable {
    let temperature: Double
    let humidity: Double?
    /// Unit (millis vs seconds) is deferred to Phase 5 — Kotlin field is
    /// `Long`, semantics confirmed there.
    let timestamp: Int
}

struct EchoScanResponse: Codable, Equatable {
    let shipmentId: String?
    let devicesScanned: Int
    let devicesTotal: Int
    let allScanned: Bool
    let siblingsPending: [String]
    let thisDeviceAlert: Bool
    let temperatureAlert: Bool

    enum CodingKeys: String, CodingKey {
        case shipmentId = "shipment_id"
        case devicesScanned = "devices_scanned"
        case devicesTotal = "devices_total"
        case allScanned = "all_scanned"
        case siblingsPending = "siblings_pending"
        case thisDeviceAlert = "this_device_alert"
        case temperatureAlert = "temperature_alert"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shipmentId = try c.decodeIfPresent(String.self, forKey: .shipmentId)
        devicesScanned = try c.decodeIfPresent(Int.self, forKey: .devicesScanned) ?? 0
        devicesTotal = try c.decodeIfPresent(Int.self, forKey: .devicesTotal) ?? 0
        allScanned = try c.decodeIfPresent(Bool.self, forKey: .allScanned) ?? false
        siblingsPending = try c.decodeIfPresent([String].self, forKey: .siblingsPending) ?? []
        thisDeviceAlert = try c.decodeIfPresent(Bool.self, forKey: .thisDeviceAlert) ?? false
        temperatureAlert = try c.decodeIfPresent(Bool.self, forKey: .temperatureAlert) ?? false
    }
}

// MARK: - Error envelope

/// All three fields are optional — backend may return any subset.
/// `APIClient` decodes this from non-2xx response bodies to surface
/// server-side error context to callers.
struct ApiError: Codable, Equatable {
    let error: String?
    let message: String?
    let code: String?
}
