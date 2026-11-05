import Darwin

/// Continuous monotonic nanoseconds, including system sleep and unaffected by wall-clock edits.
/// CLOCK_MONOTONIC_RAW is available since macOS 10.12; never mix it with DispatchTime uptime.
public enum SamplingClock {
    public static var nowNanoseconds: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
}
