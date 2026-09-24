import { describe, expect, it } from 'vitest';
import {
	currentTotal,
	dailyTotals,
	daysBetween,
	latestByResource,
	totalAsOf,
	weekly,
	type Reading
} from './daily';

const at = (iso: string) => Date.parse(iso);
const r = (resourceID: string, iso: string, value: number): Reading => ({
	resourceID,
	time: at(iso),
	value
});

describe('daysBetween', () => {
	it('includes both ends', () => {
		expect(daysBetween('2026-09-01', '2026-09-03')).toEqual([
			'2026-09-01',
			'2026-09-02',
			'2026-09-03'
		]);
	});

	it('is empty when the range is inverted', () => {
		expect(daysBetween('2026-09-03', '2026-09-01')).toEqual([]);
	});
});

describe('dailyTotals', () => {
	it('carries each resource forward instead of summing only that day', () => {
		// a and b are collected on different days; the total must not dip on b's off days.
		const points = dailyTotals(
			[
				r('a', '2026-09-01T03:00:00Z', 10),
				r('b', '2026-09-02T03:00:00Z', 5),
				r('a', '2026-09-04T03:00:00Z', 12)
			],
			'2026-09-01',
			'2026-09-05'
		);
		expect(points).toEqual([
			{ t: '2026-09-01', v: 10 },
			{ t: '2026-09-02', v: 15 },
			{ t: '2026-09-03', v: 15 },
			{ t: '2026-09-04', v: 17 },
			{ t: '2026-09-05', v: 17 }
		]);
	});

	it('uses readings from before the range as the starting point', () => {
		const points = dailyTotals([r('a', '2026-08-01T00:00:00Z', 40)], '2026-09-01', '2026-09-02');
		expect(points).toEqual([
			{ t: '2026-09-01', v: 40 },
			{ t: '2026-09-02', v: 40 }
		]);
	});

	it('leaves out days before the first reading', () => {
		const points = dailyTotals([r('a', '2026-09-03T12:00:00Z', 1)], '2026-09-01', '2026-09-03');
		expect(points).toEqual([{ t: '2026-09-03', v: 1 }]);
	});

	it('ignores readings after the range', () => {
		const points = dailyTotals(
			[r('a', '2026-09-01T00:00:00Z', 1), r('a', '2026-10-01T00:00:00Z', 99)],
			'2026-09-01',
			'2026-09-01'
		);
		expect(points).toEqual([{ t: '2026-09-01', v: 1 }]);
	});

	it('does not depend on input order', () => {
		const readings = [r('a', '2026-09-02T00:00:00Z', 3), r('a', '2026-09-01T00:00:00Z', 1)];
		expect(dailyTotals(readings, '2026-09-01', '2026-09-02')).toEqual([
			{ t: '2026-09-01', v: 1 },
			{ t: '2026-09-02', v: 3 }
		]);
	});
});

describe('totalAsOf', () => {
	it('is null before anything was read', () => {
		expect(totalAsOf([r('a', '2026-09-02T00:00:00Z', 1)], '2026-09-01')).toBeNull();
	});

	it('includes a reading taken during the day', () => {
		expect(totalAsOf([r('a', '2026-09-01T23:59:00Z', 7)], '2026-09-01')).toBe(7);
	});

	it('distinguishes a zero total from no data', () => {
		expect(totalAsOf([r('a', '2026-09-01T00:00:00Z', 0)], '2026-09-01')).toBe(0);
	});
});

describe('latestByResource and currentTotal', () => {
	const readings = [
		r('a', '2026-09-03T00:00:00Z', 5),
		r('a', '2026-09-01T00:00:00Z', 50),
		r('b', '2026-09-02T00:00:00Z', 2)
	];

	it('picks the newest reading by time, not position', () => {
		expect(latestByResource(readings).get('a')?.value).toBe(5);
	});

	it('sums each resource once', () => {
		expect(currentTotal(readings)).toBe(7);
	});
});

describe('weekly', () => {
	it('keeps the last day of each ISO week', () => {
		const points = daysBetween('2026-09-07', '2026-09-16').map((t, i) => ({ t, v: i }));
		// 2026-09-07 is a Monday, so the first week ends on the 13th (v = 6).
		expect(weekly(points)).toEqual([
			{ t: '2026-09-13', v: 6 },
			{ t: '2026-09-16', v: 9 }
		]);
	});
});
