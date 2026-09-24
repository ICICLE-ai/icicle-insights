import Foundation
import SwiftSoup

/// The download figures GitHub shows on a GHCR container package's public page, read out of its
/// HTML.
///
/// Scraped because there is nowhere else to read them: GitHub's Packages API lists a container's
/// versions and metadata but reports no download count at all, so the page rendered for a person is
/// the only published source. See docs/explanation/how-collection-works.md.
///
/// A pure parse, kept apart from `SyncGHCRStats` so every selector can be tested against saved
/// pages without a database, a queue, or the network. This is the one file that knows what the page
/// looks like, which is why `JobError.pageLayoutChanged` names it: when GitHub redesigns the page,
/// the fix is here and in the fixtures under `Tests/Fixtures/GHCR/`, nowhere else.
///
/// Every failure is a thrown `pageLayoutChanged` rather than a zero or a partial result. A scraper
/// that shrugs past a missing element writes a plausible, wrong number, and that is worse than no
/// number: nobody investigates a figure that looks fine.
struct GHCRPackagePage: Sendable {
  /// GitHub's own lifetime download count for the package, exact.
  let totalDownloads: Int

  /// The download chart's daily counts, newest first as GitHub orders them, each dated to the UTC
  /// calendar day it covers.
  let days: [(date: Date, count: Int)]

  /// The chart's days summed: a trailing 30-day window, the same shape as the Hub's `downloads`.
  var trailingDownloads: Int {
    days.reduce(0) { $0 + $1.count }
  }

  /// The label GitHub prints beside the lifetime count. Matched against the element's own text,
  /// exactly: "Last published" and "Issues" sit beside it in identical markup, each with its own
  /// `<h3 title>`, so structure alone cannot tell them apart.
  static let totalLabel = "Total downloads"

  /// The chart's accessible label, matched as a prefix. It is also a tooltip, so a future suffix
  /// such as a date range should not count as a redesign; a different window length should.
  static let chartLabelPrefix = "Downloads for the last 30 days"

  /// The most daily bars the chart may hold. More than the label promises means the window has
  /// changed underneath it, and summing them would silently store something other than 30 days.
  ///
  /// Fewer is accepted: whether GitHub draws a full 30 bars for a package younger than that has
  /// not been observed, and a short chart still sums to the correct window.
  static let chartDays = 30

  /// Parses a package page.
  ///
  /// - Parameters:
  ///   - html: The page body as GitHub served it.
  ///   - url: Where it came from, carried into the error so an alert names the page to open.
  /// - Throws: `JobError.pageLayoutChanged` when the total or the chart is missing, or holds a
  ///   value that is not a plain whole number or date.
  init(html: String, url: String) throws {
    // SwiftSoup's own `Exception` is folded into the same error. The HTML parser is lenient and
    // does not reject real pages, so the realistic source is a selector this file wrote, which
    // is exactly where `pageLayoutChanged` already sends whoever is paged.
    do {
      let document = try SwiftSoup.parse(html)
      totalDownloads = try Self.totalDownloads(in: document, url: url)
      days = try Self.days(in: document, url: url)
    } catch let error as JobError {
      throw error
    } catch {
      throw JobError.pageLayoutChanged(url: url, detail: "SwiftSoup could not read it: \(error)")
    }
  }

  /// Reads the lifetime count from the `<h3>` that follows the "Total downloads" label.
  ///
  /// The `title` attribute first: GitHub puts the exact figure there and may abbreviate the
  /// visible text. The text is only a fallback, and only when it is a plain whole number.
  private static func totalDownloads(in document: Document, url: String) throws -> Int {
    guard let label = try document.select("span").first(where: { $0.ownText() == totalLabel })
    else {
      throw JobError.pageLayoutChanged(url: url, detail: "no \"\(totalLabel)\" label")
    }

    // The next `<h3>` among the label's own siblings, not merely the next element: tolerant of a
    // wrapper or icon being slotted in between, but never reaching outside the label's block,
    // where "Last published" has an `<h3 title>` of its own.
    var sibling = try label.nextElementSibling()
    while let element = sibling, element.tagName() != "h3" {
      sibling = try element.nextElementSibling()
    }
    guard let heading = sibling else {
      throw JobError.pageLayoutChanged(
        url: url, detail: "no <h3> after the \"\(totalLabel)\" label")
    }

    let title = try heading.attr("title").trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty {
      guard let total = plainInteger(title) else {
        throw JobError.pageLayoutChanged(
          url: url, detail: "the total's title \"\(title)\" is not a whole number")
      }
      return total
    }

    // Thrown rather than expanded. "1.2K" read as 1,200 would store a rounded total that looks
    // exact, and `setAllTime` then replaces the true figure with it on every sweep until someone
    // happens to compare the two by hand.
    let text = try heading.text()
    guard let total = plainInteger(text) else {
      throw JobError.pageLayoutChanged(
        url: url,
        detail: "the total has no title and its text \"\(text)\" is not a whole number; "
          + "an abbreviated figure would store a rounded total")
    }
    return total
  }

  /// Reads one count per day from the bars of the 30-day chart.
  ///
  /// Each bar carries its day's count and date as attributes. Both are read as data rather than
  /// inferred from the bar's height or position, which are presentation and change with styling.
  private static func days(in document: Document, url: String) throws -> [(date: Date, count: Int)]
  {
    let chart = try document.select("[aria-label]").first { element in
      (try? element.attr("aria-label").hasPrefix(chartLabelPrefix)) == true
    }
    guard let chart else {
      throw JobError.pageLayoutChanged(
        url: url, detail: "no element labelled \"\(chartLabelPrefix)\"")
    }

    let bars = try chart.select("rect[data-date][data-merge-count]")
    guard !bars.isEmpty else {
      throw JobError.pageLayoutChanged(
        url: url, detail: "the download chart has no bars with a date and a count")
    }
    guard bars.count <= chartDays else {
      throw JobError.pageLayoutChanged(
        url: url,
        detail: "the download chart has \(bars.count) bars, more than the \(chartDays) days "
          + "its label promises")
    }

    return try bars.map { bar in
      let rawDate = try bar.attr("data-date")
      let rawCount = try bar.attr("data-merge-count")

      // UTC, because every day in this service is one: the daily totals, the watermark fold and
      // the insights API all key on UTC calendar days. `UTCDay.parse` is also strict on shape,
      // so a timestamp or a locale-formatted date is refused rather than guessed at.
      guard let date = UTCDay.parse(rawDate) else {
        throw JobError.pageLayoutChanged(
          url: url, detail: "a chart bar's date \"\(rawDate)\" is not YYYY-MM-DD")
      }
      // Digits only. `Int("+3")` would pass, and a separator in a per-day count would mean the
      // attribute no longer holds what this file assumes it does.
      guard !rawCount.isEmpty, rawCount.allSatisfy({ $0.isASCII && $0.isNumber }),
        let count = Int(rawCount)
      else {
        throw JobError.pageLayoutChanged(
          url: url, detail: "the chart bar for \(rawDate) has count \"\(rawCount)\"")
      }
      return (date: date, count: count)
    }
  }

  /// Parses a whole number written as digits with optional thousands separators, such as `82` or
  /// `1,234`. Returns nil for anything else, including `1.2K`, `1,2`, `+5`, and an empty string.
  ///
  /// Separators must fall every three digits. A loose "strip the commas" would read `1,2` as 12,
  /// which is no figure GitHub would print and so is better treated as a changed layout.
  static func plainInteger(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let groups = trimmed.split(separator: ",", omittingEmptySubsequences: false)
    guard let first = groups.first, !first.isEmpty,
      groups.count == 1 || first.count <= 3,
      groups.dropFirst().allSatisfy({ $0.count == 3 }),
      groups.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
    else {
      return nil
    }
    return Int(groups.joined())
  }
}
