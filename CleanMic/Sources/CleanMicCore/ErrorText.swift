import Foundation

public enum ErrorText {
    /// Poruka za korisnika. Naši enum-i imaju pripremljen opis; za sistemske
    /// greške `localizedDescription` je čitljiviji od NSError dumpa.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let e as OpenRouterError: return e.description
        case let e as CaptureError: return e.description
        case let e as TranscriptionService.TranscribeError: return e.description
        case let e as ReportService.ReportError: return e.description
        case let e as StreamingWAVWriter.WriteError: return e.description
        default: return error.localizedDescription
        }
    }
}
