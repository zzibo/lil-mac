import Foundation
import Testing
@testable import LilMacRuntime

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ zone: String = "UTC") -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

let utc = TimeZone(identifier: "UTC")!
let newYork = TimeZone(identifier: "America/New_York")!

@Suite struct CronTests {
    @Test func weekdayMorningSkipsTheWeekend() throws {
        let cron = try Cron("0 8 * * 1-5")
        #expect(cron.next(after: date(2026, 10, 23, 9), in: utc) == date(2026, 10, 26, 8))  // Fri -> Mon
        #expect(cron.next(after: date(2026, 10, 26, 7, 59), in: utc) == date(2026, 10, 26, 8))
        #expect(cron.next(after: date(2026, 10, 26, 8), in: utc) == date(2026, 10, 27, 8))  // strictly after
    }

    @Test func steps() throws {
        let cron = try Cron("*/15 * * * *")
        #expect(cron.next(after: date(2026, 10, 27, 10, 7), in: utc) == date(2026, 10, 27, 10, 15))
        #expect(cron.next(after: date(2026, 10, 27, 10, 45), in: utc) == date(2026, 10, 27, 11, 0))
    }

    @Test func listsAndRanges() throws {
        let cron = try Cron("0,30 9-17 * * *")
        #expect(cron.next(after: date(2026, 10, 27, 8), in: utc) == date(2026, 10, 27, 9, 0))
        #expect(cron.next(after: date(2026, 10, 27, 9, 0), in: utc) == date(2026, 10, 27, 9, 30))
        #expect(cron.next(after: date(2026, 10, 27, 17, 30), in: utc) == date(2026, 10, 28, 9, 0))
    }

    @Test func sundayIsZeroOrSeven() throws {
        let expected = date(2026, 10, 25, 6)  // a Sunday
        #expect(try Cron("0 6 * * 0").next(after: date(2026, 10, 24), in: utc) == expected)
        #expect(try Cron("0 6 * * 7").next(after: date(2026, 10, 24), in: utc) == expected)
    }

    @Test func dayOfMonthOrDayOfWeekWhenBothRestricted() throws {
        let cron = try Cron("0 0 13 * 5")  // the 13th OR any Friday
        #expect(cron.next(after: date(2026, 10, 9), in: utc) == date(2026, 10, 13))  // Tue the 13th
        #expect(cron.next(after: date(2026, 10, 13), in: utc) == date(2026, 10, 16))  // Friday
        #expect(try Cron("0 0 * * 5").next(after: date(2026, 10, 9), in: utc) == date(2026, 10, 16))  // star: AND
    }

    @Test func impossibleDateGivesNil() throws {
        #expect(try Cron("0 0 30 2 *").next(after: date(2026, 1, 1), in: utc) == nil)
    }

    @Test(arguments: ["", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *",
                      "* * * 13 *", "* * * * 8", "*/0 * * * *", "+5 * * * *", "*/+5 * * * *", "1-+5 * * * *", "-5 * * * *", "a * * * *", "5-1 * * * *", ",5 * * * *", "1-2-3 * * * *"])
    func invalidExpressionsThrow(_ expression: String) {
        #expect(throws: (any Error).self) { try Cron(expression) }
    }

    @Test func wallClockHoldsAcrossSpringForward() throws {
        let cron = try Cron("0 8 * * *")
        let next = cron.next(after: date(2026, 3, 7, 8, 0, "America/New_York"), in: newYork)
        #expect(next == date(2026, 3, 8, 8, 0, "America/New_York"))  // 23 hours later
        #expect(next!.timeIntervalSince(date(2026, 3, 7, 8, 0, "America/New_York")) == 23 * 3600)
    }

    @Test func nonexistentLocalTimeIsSkippedForThatDay() throws {
        let cron = try Cron("30 2 * * *")  // 02:30 does not exist on 2026-03-08 in New York
        #expect(cron.next(after: date(2026, 3, 8, 0, 0, "America/New_York"), in: newYork)
            == date(2026, 3, 9, 2, 30, "America/New_York"))
    }

    @Test func fallBackHourFiresOnce() throws {
        let cron = try Cron("30 1 * * *")  // 01:30 happens twice on 2026-11-01 in New York
        let first = try #require(cron.next(after: date(2026, 11, 1, 0, 0, "America/New_York"), in: newYork))
        #expect(first == date(2026, 11, 1, 5, 30))  // 01:30 EDT
        #expect(cron.next(after: first, in: newYork) == date(2026, 11, 2, 1, 30, "America/New_York"))
    }

    @Test func scheduleKinds() {
        let now = date(2026, 10, 27, 8)
        #expect(Schedule.every(900).next(after: now, in: utc) == now.addingTimeInterval(900))
        #expect(Schedule.once(now.addingTimeInterval(60)).next(after: now, in: utc) == now.addingTimeInterval(60))
        #expect(Schedule.once(now).next(after: now, in: utc) == nil)
        #expect(Schedule.cron("not cron").next(after: now, in: utc) == nil)
    }
}
