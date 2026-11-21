import Foundation

public enum WindowLayout {
    public static func pipHeight(width: Double) -> Double {
        max(0, width) * 9 / 16
    }
}
