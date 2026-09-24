import type { Point } from './types';

/** A reading reduced to what totals need. `time` is epoch milliseconds. */
export interface Reading {
	resourceID: string;
	time: number;
	value: number;
}

const DAY = 86_400_000;

/** `2026-09-24` for any instant on that UTC day. */
export const isoDay = (time: number | Date): string =>
	new Date(typeof time === 'number' ? time : time.getTime()).toISOString().slice(0, 10);

/** Epoch milliseconds for the first instant after `day` ends (UTC). */
const endOf = (day: string): number => Date.parse(`${day}T00:00:00Z`) + DAY;

/** Every ISO day from `from` to `to`, inclusive. */
export function daysBetween(from: string, to: string): string[] {
	const days: string[] = [];
	for (
		let t = Date.parse(`${from}T00:00:00Z`), end = Date.parse(`${to}T00:00:00Z`);
		t <= end;
		t += DAY
	) {
		days.push(isoDay(t));
	}
	return days;
}

/**
 * The total across resources at the end of each day, each resource contributing its newest
 * reading so far.
 *
 * Carried forward, not summed per day: resources are collected on their own weekly schedules, so
 * any single day holds readings for only a few of them. Summing a day's readings would make the
 * total collapse on every day most resources weren't collected. Carrying each one's last value
 * forward is what makes a point mean "everything we know, as of that day".
 *
 * A resource contributes nothing before its first reading. Days before any reading at all are
 * left out entirely, so a chart starts where the data does instead of on a run of zeros.
 */
export function dailyTotals(readings: readonly Reading[], from: string, to: string): Point[] {
	const ordered = [...readings].sort((a, b) => a.time - b.time);
	const latest = new Map<string, number>();
	const points: Point[] = [];
	let total = 0;
	let index = 0;

	for (const day of daysBetween(from, to)) {
		const end = endOf(day);
		while (index < ordered.length && ordered[index].time < end) {
			const reading = ordered[index++];
			total += reading.value - (latest.get(reading.resourceID) ?? 0);
			latest.set(reading.resourceID, reading.value);
		}
		if (latest.size > 0) points.push({ t: day, v: total });
	}

	return points;
}

/** The total at the end of `day`, or null when no resource had been read by then. */
export function totalAsOf(readings: readonly Reading[], day: string): number | null {
	const end = endOf(day);
	const latest = new Map<string, { time: number; value: number }>();
	for (const reading of readings) {
		if (reading.time >= end) continue;
		const existing = latest.get(reading.resourceID);
		if (!existing || reading.time > existing.time) {
			latest.set(reading.resourceID, { time: reading.time, value: reading.value });
		}
	}
	if (latest.size === 0) return null;
	let total = 0;
	for (const { value } of latest.values()) total += value;
	return total;
}

/** Each resource's newest reading, resolved by time rather than array order. */
export function latestByResource(
	readings: readonly Reading[]
): Map<string, { time: number; value: number }> {
	const latest = new Map<string, { time: number; value: number }>();
	for (const reading of readings) {
		const existing = latest.get(reading.resourceID);
		if (!existing || reading.time > existing.time) {
			latest.set(reading.resourceID, { time: reading.time, value: reading.value });
		}
	}
	return latest;
}

/** Sum of every resource's newest reading. */
export function currentTotal(readings: readonly Reading[]): number {
	let total = 0;
	for (const { value } of latestByResource(readings).values()) total += value;
	return total;
}

/**
 * One point per ISO week: the value on the last day of that week inside the range. A week's
 * value is where it ended, not its average, so the last point always equals the daily series'.
 */
export function weekly(points: readonly Point[]): Point[] {
	const byWeek = new Map<string, Point>();
	for (const point of points) {
		const date = new Date(`${point.t}T00:00:00Z`);
		const monday = new Date(date.getTime() - ((date.getUTCDay() + 6) % 7) * DAY);
		byWeek.set(isoDay(monday), point);
	}
	return [...byWeek.values()];
}
