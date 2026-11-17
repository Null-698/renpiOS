import Charts
import SwiftUI
import UIKit

struct PlayHistory: Codable {
    struct Game: Codable {
        var title: String
        var seconds: TimeInterval = 0
    }

    var games: [UUID: Game] = [:]
    var days: [Date: TimeInterval] = [:]
    var longestSession: TimeInterval = 0

    static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func day(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return dayCalendar.date(from: components) ?? dayCalendar.startOfDay(for: date)
    }

    mutating func record(game: Novel, from start: Date, seconds: TimeInterval,
                         sessionLength: TimeInterval, calendar: Calendar = PlayHistory.localCalendar) {
        guard seconds > 0 else { return }
        var entry = games[game.id] ?? Game(title: game.title)
        entry.title = game.title
        entry.seconds += seconds
        games[game.id] = entry
        longestSession = max(longestSession, sessionLength)

        var remaining = seconds
        var cursor = start
        while remaining > 0 {
            let midnight = calendar.dateInterval(of: .day, for: cursor)?.end
            let untilMidnight = midnight.map { $0.timeIntervalSince(cursor) } ?? remaining
            let segment = untilMidnight > 0 ? min(remaining, untilMidnight) : remaining
            days[Self.day(for: cursor, calendar: calendar), default: 0] += segment
            remaining -= segment
            cursor = cursor.addingTimeInterval(segment)
        }
    }

    func streaks(asOf date: Date, calendar: Calendar = PlayHistory.localCalendar) -> (current: Int, longest: Int) {
        let today = Self.day(for: date, calendar: calendar)
        let previousDay = today.addingTimeInterval(-86400)
        var previous: Date?
        var run = 0
        var longest = 0
        for day in days.keys.filter({ $0 <= today }).sorted() {
            run = previous.map { day.timeIntervalSince($0) == 86400 } == true ? run + 1 : 1
            longest = max(run, longest)
            previous = day
        }
        return (previous == today || previous == previousDay ? run : 0, longest)
    }
}

@MainActor
@Observable
final class PlayActivity: NSObject {
    private(set) var history: PlayHistory
    private let file: URL
    private var game: Novel?
    private var started: (date: Date, uptime: TimeInterval)?
    private var elapsed: TimeInterval = 0
    private var launchedAt: Date?
    private var savedLaunch = false
    private var timer: Timer?

    override init() {
        file = URL.documentsDirectory.appending(path: "reniOS/.play-history.json")
        history = (try? JSONDecoder().decode(PlayHistory.self, from: Data(contentsOf: file))) ?? PlayHistory()
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(becameInactive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func begin(_ game: Novel) {
        self.game = game
        if UserDefaults.standard.object(forKey: "insightsEnabled") != nil,
           !UserDefaults.standard.bool(forKey: "insightsEnabled") {
            return
        }
        elapsed = 0
        launchedAt = .now
        savedLaunch = false
        if UIApplication.shared.applicationState == .active { resume() }
        let ticker = Timer(timeInterval: 30, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func finish() {
        pause()
        timer?.invalidate()
        timer = nil
        game = nil
    }

    @objc private func becameActive(_ notification: Notification) { resume() }
    @objc private func becameInactive(_ notification: Notification) { pause() }
    @objc private func tick(_ timer: Timer) { checkpoint() }

    private func resume() {
        guard game != nil, started == nil,
              UserDefaults.standard.object(forKey: "insightsEnabled") == nil ||
              UserDefaults.standard.bool(forKey: "insightsEnabled") else { return }
        started = (.now, ProcessInfo.processInfo.systemUptime)
    }

    private func pause() {
        checkpoint()
        started = nil
    }

    private func checkpoint() {
        guard let game, let started else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let seconds = now - started.uptime
        guard seconds > 0 else { return }
        elapsed += seconds
        history.record(game: game, from: started.date, seconds: seconds, sessionLength: elapsed)
        self.started = (.now, now)
        do {
            if !savedLaunch, elapsed >= 5, let launchedAt {
                try LibraryStore.recordPlay(game, at: launchedAt)
                savedLaunch = true
            }
        } catch {
            NSLog("reniOS last played: %@", error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: file, options: .atomic)
        } catch {
            NSLog("reniOS play activity: %@", error.localizedDescription)
        }
    }
}

struct InsightsView: View {
    let history: PlayHistory
    let titles: [UUID: String]
    let wide: Bool
    @State private var selectedDay: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let streaks = history.streaks(asOf: context.date)
            let favorite = history.games.max {
                ($0.value.seconds, $0.key.uuidString) < ($1.value.seconds, $1.key.uuidString)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if history.games.isEmpty {
                        ContentUnavailableView("No play time yet", systemImage: "chart.bar.xaxis",
                                               description: Text("Your activity appears after you play a game."))
                    } else if wide {
                        HStack(alignment: .top, spacing: 14) {
                            summary(streaks: streaks, favorite: favorite)
                                .frame(maxWidth: 355)
                            busiestDays
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        summary(streaks: streaks, favorite: favorite)
                        busiestDays
                    }
                }
                .frame(maxWidth: wide ? 1100 : 780)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func summary(streaks: (current: Int, longest: Int),
                         favorite: (key: UUID, value: PlayHistory.Game)?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let columns = wide ? Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
                : [GridItem(.adaptive(minimum: 145), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                metric("Games played", history.games.count.formatted(), "rectangle.on.rectangle")
                metric("Current streak", days(streaks.current), "flame")
                metric("Longest streak", days(streaks.longest), "trophy")
                metric("Longest session", duration(history.longestSession), "clock")
            }
            if let favorite {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Most played game").font(.subheadline).foregroundStyle(amber)
                    Text(titles[favorite.key] ?? favorite.value.title)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                    Text(duration(favorite.value.seconds)).font(.subheadline.monospacedDigit())
                }
                .padding(wide ? 12 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panel, in: .rect(cornerRadius: 16))
            }
        }
    }

    private var busiestDays: some View {
        let days = rankedDays
        let spansYears = Set(days.map { PlayHistory.dayCalendar.component(.year, from: $0.key) }).count > 1
        let shortDate = Date.FormatStyle(timeZone: .gmt).month(.abbreviated).day()
        let format = spansYears ? shortDate.year(.twoDigits) : shortDate
        let points = days.map { entry in
            DayBar(date: entry.key, label: entry.key.formatted(format), seconds: entry.value)
        }
        let active = points.first { $0.label == selectedDay } ?? points.max { $0.seconds < $1.seconds }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Most played days").font(.headline)
                Spacer()
                if let active {
                    Text("\(active.label) · \(duration(active.seconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(amber)
                }
            }
            Chart(points) { day in
                BarMark(
                    x: .value("Day", day.label),
                    y: .value("Minutes played", day.seconds / 60),
                    width: .ratio(0.56)
                )
                .cornerRadius(5)
                .foregroundStyle(LinearGradient(
                    colors: [amber.opacity(day.id == active?.id ? 1 : 0.75), amber.opacity(0.24)],
                    startPoint: .top, endPoint: .bottom
                ))
                .accessibilityLabel(Text(day.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                .accessibilityValue(Text(duration(day.seconds)))
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.secondary) }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.10))
                    if let minutes = value.as(Double.self) {
                        AxisValueLabel { Text("\(Int(minutes))m").foregroundStyle(.secondary) }
                    }
                }
            }
            .chartXSelection(value: $selectedDay)
            .frame(height: wide ? 174 : 152)
            .accessibilityLabel("Play time on your five busiest days")
        }
        .padding(16)
        .background(panel, in: .rect(cornerRadius: 16))
    }

    private var rankedDays: [(key: Date, value: TimeInterval)] {
        history.days.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(5)
            .sorted { $0.key < $1.key }
    }

    private struct DayBar: Identifiable {
        let date: Date
        let label: String
        let seconds: TimeInterval
        var id: Date { date }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).foregroundStyle(amber).accessibilityHidden(true)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(wide ? 10 : 13).frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
}
