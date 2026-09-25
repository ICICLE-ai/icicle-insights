# How collection works

Why collection is scheduled, retried and stored the way it is. For developers changing a collector,
and administrators who want to understand an alert.

## Due dates are leases

Every resource has a cadence, 7 days by default, and a next-collection date. Each hour the scheduler
queues a sync for every resource whose date has passed. As it queues one, it moves the date a full
cadence ahead.

That early move is a lease, not a promise. It stops the next hourly sweep from queuing the same
resource while the first job is still running. When the job succeeds, the date is booked again from
the moment of success, so the cadence follows real collections rather than attempts. Adding a
resource and **Collect now** in the admin console book the same lease when they queue a job.

A resource with no date at all is never swept, because the sweep looks for dates in the past. The
API gives every new resource a date. Rows created any other way, such as by a seed migration, must do
the same. npm and PyPI rows are the exception: nothing collects them, so they are left without one.

## Failures re-book instead of waiting

A sync that throws is retried three times, 30 seconds, 2 minutes and 8 minutes apart. After that it
is reported, and the lease is replaced with a shorter wait.

Without that replacement, one failure would cost a full cadence. Two in a row would cost two weeks,
which is GitHub's entire traffic window. So a credential failure retries every hour until someone
fixes the token. Any other failure retries after a quarter of its overdue time, between one and
twelve hours. Early retries are frequent while there is still data to save; later ones are spaced
out so a long outage does not flood the alert channel.

## Windows that forget

GitHub reports views and clones only for the last 14 days. Anything not read within that window is
gone. That is why GitHub resources cannot be set to collect less often than every 7 days: a single
delayed sweep still leaves a week of margin. If the gap between successes ever passes 14 days, a
separate alert says data was lost.

Hugging Face and GHCR report their own lifetime totals, so a late sweep costs detail but never
history. Patra reports whole counts each time.

## Three ways to store a figure

**Snapshots.** Every reading is stored as a row with its time. Totals such as stars are just the
series of snapshots.

**Lifetime totals the platform reports.** Hugging Face downloads and GHCR pulls come with a lifetime
figure. Insights overwrites its stored total with it on every sweep. Running the sweep twice changes
nothing.

**Lifetime totals Insights builds.** GitHub gives daily counts but no lifetime figure. Insights adds
each completed day to its own total, once. A *watermark* records the last day counted, so the
overlap between two 14-day windows is not counted twice. Today is skipped until it is over.

Each time a lifetime total changes, that day's value is also written to a daily history table. That
is what lets the dashboard chart lifetime figures over time.

## Safe to run twice

Job delivery is at least once, so every collector must be safe to repeat. Each one fetches
everything first, then writes all of it in one database transaction, success booking included. A
failure halfway through rolls back every row, and the retry starts clean.

Two workers can still collect the same resource at once, for example after a manual sweep or
**Collect now** on a resource whose job is already running.
Lifetime totals are guarded by a PostgreSQL advisory lock per resource and metric, so the two
serialise instead of racing.

## Patra builds its own catalog

Patra is a registry, not one project. Once a day Insights reads every public model card and
datasheet and registers each as a resource. Cards with the same name become one resource, because a
Patra card is one version of a model. Deployments are then counted per resource, summed across its
cards.

A card can say where the artifact also lives, such as a Hugging Face repository. When that location
matches a resource Insights already tracks, the two are linked. The Provenance page is built from
those links.

## GHCR is read from its web page

GitHub's Packages API has no download counts, so Insights reads the public package page. It takes
the exact lifetime total and the 30 daily bars of the download chart. It tries the organisation's
address first, then the user's.

Scraping breaks when GitHub redesigns the page. The parser then fails with `page_layout_changed`
rather than storing a wrong number. No credential is used, so a private package can never leak onto
the public dashboard.

#icicle-insights# #Explanation# #Developer# #Administrator#
