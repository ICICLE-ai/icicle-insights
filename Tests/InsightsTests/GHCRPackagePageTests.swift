import Foundation
import Testing

@testable import Insights

/// `GHCRPackagePage` is the only thing standing between GitHub's markup and a stored total, and a
/// scraper fails quietly by default: a missed element reads as zero, and zero looks like a real
/// figure. These pin that every figure comes from the right element, and that anything unexpected
/// throws instead of guessing.
///
/// Run against two real pages rather than hand-written HTML. The August one was saved while the
/// collector was being designed; the September one was fetched when it shipped, and GitHub had
/// reformatted its chart in between, to one attribute per line. Both parse, which is the point.
@Suite("GHCR package page")
struct GHCRPackagePageTests {
  private let august = "package-page-2026-08.html"
  private let september = "package-page-2026-09.html"
  private let url = "https://github.com/orgs/ICICLE-ai/packages/container/package/insights"

  /// The `(url, detail)` of the `pageLayoutChanged` a parse threw, or nil if it threw anything
  /// else or nothing.
  private func layoutChange(_ html: String) -> (url: String, detail: String)? {
    do {
      _ = try GHCRPackagePage(html: html, url: url)
      return nil
    } catch JobError.pageLayoutChanged(let url, let detail) {
      return (url, detail)
    } catch {
      return nil
    }
  }

  /// Midnight UTC of a calendar day, built by hand rather than through `UTCDay`, so the test does
  /// not assert the parser against the helper the parser itself uses.
  private func utcMidnight(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    try #require(
      DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year, month: month, day: day
      ).date)
  }

  // MARK: - Real pages

  @Test
  func `The August page yields its exact total and 30 summed days`() throws {
    let page = try GHCRPackagePage(html: try ghcrFixture(august), url: url)

    // The `title`, not a neighbour's: "Last published" and "Issues" each carry an `<h3 title>` in
    // the same markup, just above.
    #expect(page.totalDownloads == 248)
    #expect(page.days.count == 30)
    // 3 + 2 + 2 + 9 + 4 + 9, read off the chart's non-zero bars.
    #expect(page.trailingDownloads == 29)
    #expect(page.days.map { $0.count }.filter { $0 > 0 } == [3, 2, 2, 9, 4, 9])
  }

  @Test
  func `The September page yields its exact total and 30 summed days`() throws {
    let page = try GHCRPackagePage(html: try ghcrFixture(september), url: url)

    #expect(page.totalDownloads == 302)
    #expect(page.days.count == 30)
    // 4 + 7 + 2 + 11 + 14.
    #expect(page.trailingDownloads == 38)
    #expect(page.days.map { $0.count }.filter { $0 > 0 } == [4, 7, 2, 11, 14])
  }

  /// Newest first, one per consecutive day, each at midnight UTC. A date parsed in the process's
  /// own zone would land on the previous evening anywhere west of Greenwich, and both
  /// `metric_daily_totals` and the fold key on UTC days.
  @Test
  func `Chart dates are consecutive UTC calendar days, newest first`() throws {
    let page = try GHCRPackagePage(html: try ghcrFixture(september), url: url)

    #expect(page.days.first?.date == (try utcMidnight(2026, 9, 24)))
    #expect(page.days.last?.date == (try utcMidnight(2026, 8, 26)))
    for (newer, older) in zip(page.days, page.days.dropFirst()) {
      #expect(newer.date.timeIntervalSince(older.date) == 86_400)
    }
  }

  // MARK: - The total

  /// GitHub may abbreviate the visible figure, but the `title` holds the exact one.
  @Test
  func `The total comes from the title even when the text is abbreviated`() throws {
    let html = try replacingOnce(
      #"<h3 title="302">302</h3>"#, with: #"<h3 title="12,345">12.3K</h3>"#,
      in: try ghcrFixture(september))

    #expect(try GHCRPackagePage(html: html, url: url).totalDownloads == 12_345)
  }

  @Test
  func `A total with thousands separators and no title is read from its text`() throws {
    let html = try replacingOnce(
      #"<h3 title="302">302</h3>"#, with: "<h3>1,234</h3>", in: try ghcrFixture(september))

    #expect(try GHCRPackagePage(html: html, url: url).totalDownloads == 1_234)
  }

  /// The case the title exists to avoid. Read as 1,200 it would be stored as exact, and
  /// `setAllTime` would overwrite the true figure with it on every sweep.
  @Test
  func `An abbreviated total with no title throws rather than being rounded`() throws {
    let html = try replacingOnce(
      #"<h3 title="302">302</h3>"#, with: "<h3>1.2K</h3>", in: try ghcrFixture(september))

    let change = try #require(layoutChange(html))
    #expect(change.url == url)
    #expect(change.detail.contains("1.2K"))
  }

  @Test
  func `A missing total label throws pageLayoutChanged`() throws {
    let html = try replacingOnce(
      ">Total downloads<", with: ">Downloads<", in: try ghcrFixture(august))

    let change = try #require(layoutChange(html))
    #expect(change.detail.contains("Total downloads"))
  }

  @Test
  func `A total label with nothing after it throws pageLayoutChanged`() throws {
    let html = try replacingOnce(
      #"<h3 title="302">302</h3>"#, with: "", in: try ghcrFixture(september))

    #expect(layoutChange(html) != nil)
  }

  // MARK: - The chart

  @Test
  func `A missing chart throws pageLayoutChanged`() throws {
    let html = try replacingOnce(
      #"aria-label="Downloads for the last 30 days""#, with: #"aria-label="Activity""#,
      in: try ghcrFixture(september))

    let change = try #require(layoutChange(html))
    #expect(change.detail.contains("Downloads for the last 30 days"))
  }

  /// A chart that has lost its data attributes is as broken as a missing one; summing nothing
  /// would store a confident zero.
  @Test
  func `A chart whose bars carry no counts throws pageLayoutChanged`() throws {
    let html = try ghcrFixture(august).replacingOccurrences(
      of: "data-merge-count=", with: "data-count=")

    #expect(layoutChange(html) != nil)
  }

  @Test
  func `A bar with an unreadable count or date throws pageLayoutChanged`() throws {
    let badCount = try replacingOnce(
      #"data-merge-count="3" data-date="2026-07-29""#,
      with: #"data-merge-count="3.5" data-date="2026-07-29""#, in: try ghcrFixture(august))
    #expect(layoutChange(badCount)?.detail.contains("3.5") == true)

    let badDate = try replacingOnce(
      #"data-date="2026-07-29""#, with: #"data-date="Jul 29""#, in: try ghcrFixture(august))
    #expect(layoutChange(badDate)?.detail.contains("Jul 29") == true)
  }

  /// More bars than the label's 30 days means the window moved underneath the label, and the sum
  /// would no longer be the metric it is stored as.
  @Test
  func `A chart with more than 30 bars throws pageLayoutChanged`() throws {
    let extra =
      #"<rect x="0" y="24" data-merge-count="5" data-date="2026-07-09" width="2"></rect>"#
    let html = try replacingOnce("</svg>", with: extra + "</svg>", in: try ghcrFixture(august))

    #expect(layoutChange(html)?.detail.contains("31 bars") == true)
  }

  // MARK: - Whole numbers

  @Test(arguments: [
    ("82", 82),
    ("1234", 1_234),
    ("1,234", 1_234),
    ("12,345,678", 12_345_678),
    (" 302\n", 302),
  ])
  func `A plain whole number is accepted`(text: String, value: Int) {
    #expect(GHCRPackagePage.plainInteger(text) == value)
  }

  @Test(arguments: ["1.2K", "12K", "1.2M", "1,2", "1234,567", ",123", "+5", "-5", "", "8 2", "٨٢"])
  func `Anything but a plain whole number is refused`(text: String) {
    #expect(GHCRPackagePage.plainInteger(text) == nil)
  }
}
