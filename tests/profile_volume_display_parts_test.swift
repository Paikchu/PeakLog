import Foundation

@main
struct ProfileVolumeDisplayPartsTestRunner {
    static func main() {
        assertParts("999kg", value: "999", unit: "kg")
        assertParts("1.0t", value: "1.0", unit: "t")
        assertParts("220lbs", value: "220", unit: "lbs")
        assertParts("2.2k lbs", value: "2.2", unit: "k lbs")
        assertParts("—", value: "—", unit: "")

        print("profile_volume_display_parts_test passed")
    }

    private static func assertParts(_ display: String, value: String, unit: String) {
        let parts = ProfileVolumeDisplayParts(display)
        precondition(
            parts.value == value && parts.unit == unit,
            "\(display) must split into \(value) and \(unit)"
        )
    }
}
