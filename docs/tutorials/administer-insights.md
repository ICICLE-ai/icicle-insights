# Administer Insights

A first session in the admin console, for a new administrator. You will check the system is
healthy, follow one resource from registration to its first reading, and learn where problems
show up. Allow about 20 minutes.

## Before you start

- A Tapis account on the `icicleai` tenant that an existing administrator has added. See
  [Manage administrators](../how-to/manage-administrators.md).
- Something new to track. This tutorial uses a container image on GHCR, because GHCR needs no
  credential. Pick one of the institute's images that the dashboard does not list yet.

## 1. Sign in

1. Sign in to TapisUI at <https://icicleai.tapis.io>.
2. Open **ICICLE Services → Insights**. The dashboard header shows your username.
3. Click your username. The console opens at **Operations**.

**Checkpoint:** the sidebar footer shows your username and **Token expires in …**.

## 2. Read the health of the system

Operations answers three questions:

- **Is work being scheduled?** The **Scheduler** card should say **Healthy**, last seen within the
  hour.
- **Is work being done?** **Waiting on "metrics"** and **In progress** should be 0 or falling.
- **Is anything broken?** **Recent failures** lists collections that gave up. *No failures
  recorded.* is the goal.

Below them, **Watermarks** shows how far each GitHub traffic series has been counted. On a 7-day
cadence, a date up to about eight days old is normal.

## 3. Look at the catalog

1. Open **Accounts**. Each row is one organisation on one platform. **Credential** says *Stored in
   vault* for GitHub and Hugging Face.
2. Open **Resources**. **Next collection** says when each will next be read.
3. Open **Vaults**. **Expires** is when each platform token stops working. Nothing warns before
   that date, so note the earliest one.

## 4. Register a resource

1. On **Resources**, click **Add resource**.
2. Choose the account *icicle-ai · ghcr*.
3. Type the image's name as it appears in its package URL.
4. Set **Kind** to *container*. Leave **Collect every (days)** at 7.
5. Click **Add resource**.

It is collected straight away.

**Checkpoint:** the new row shows **Next collection** *in 7 days*.

## 5. Follow the first reading

1. Open **Metrics**. Within a few minutes, two new rows appear for your resource: **Pulls · 30
   days** and **Pulls · all time**.
2. Click **← Public dashboard**, open the platform picker and type the image's name.
3. Its page shows the figures, with **Tracked since** today.

If nothing appears, go back to **Operations → Recent failures**. A `page_layout_changed` or
`api_request_failed` 404 usually means a typo in the name.

## 6. Tidy up

If you registered the image only to practise, open its row menu on **Resources** and choose **Delete
resource**. Its readings stay in the database, but it leaves the dashboard.

## What you learned

- Operations tells you whether scheduling, work and collection are healthy.
- A resource is collected when it is added, then every *N* days.
- Failures show in **Recent failures** with an identifier that names the cause.

Next: [Diagnose a collection failure](../how-to/diagnose-a-collection-failure.md) and the
[Admin console reference](../reference/admin-console.md).

#icicle-insights# #Tutorial# #Administrator#
