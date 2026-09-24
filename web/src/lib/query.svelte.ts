/**
 * Loads data that depends on reactive state (the URL's filters, a route param) and reloads when
 * that state changes.
 *
 * `fn` must read its reactive inputs synchronously, before its first `await` — that is what the
 * effect tracks. Two behaviours matter for a dashboard:
 *
 * - A response that arrives after a newer request started is dropped, so quickly switching
 *   filters can never leave an older answer on screen.
 * - While reloading, `data` keeps the previous result. Charts hold their last render (the page
 *   dims it) instead of flashing a skeleton and jumping the layout on every filter change.
 */
export function query<T>(fn: () => Promise<T>) {
	let data = $state<T | undefined>(undefined);
	let error = $state<unknown>(undefined);
	let loading = $state(true);
	let version = $state(0);
	let latest = 0;

	$effect(() => {
		// Read so `refresh()` re-runs this effect.
		void version;
		const id = ++latest;
		loading = true;
		fn().then(
			(value) => {
				if (id !== latest) return;
				data = value;
				error = undefined;
				loading = false;
			},
			(reason: unknown) => {
				if (id !== latest) return;
				error = reason;
				loading = false;
			}
		);
	});

	return {
		get data() {
			return data;
		},
		get error() {
			return error;
		},
		get loading() {
			return loading;
		},
		refresh() {
			version++;
		}
	};
}
