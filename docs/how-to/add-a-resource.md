# Add a resource

How to start tracking a repository, model, dataset or container, for administrators signed in to
the console. The account it belongs to must already exist; see
[Track a new account](track-a-new-account.md).

## Steps

1. Open **Resources** and click **Add resource**.
2. Choose the **Account**. The list shows each account as *name · platform*.
3. Type the **Name** as it appears in the resource's URL:

   | Platform | URL | Name |
   |---|---|---|
   | GitHub | `github.com/icicle-ai/camera_trap` | `camera_trap` |
   | Hugging Face | `huggingface.co/icicle-ai/yield-estimation` | `yield-estimation` |
   | GHCR | `github.com/orgs/icicle-ai/packages/container/package/harvest-inference` | `harvest-inference` |

   Names are stored lowercase.
4. Choose the **Kind**: repository, model, dataset, container, package, service or agent. It does
   not change automatically when you change the account.
5. Set **Collect every (days)**. The hint under the field gives the limit: 7 days for GitHub, 30
   for the others. Keep 7 unless you have a reason.
6. Click **Add resource**.

## Check it worked

- The resource appears in the list with **Next collection** set.
- It is collected right away. Within a few minutes its readings appear under **Metrics**, and on
  its page on the public dashboard.
- If collection fails, it shows under **Operations → Recent failures**. See
  [Diagnose a collection failure](diagnose-a-collection-failure.md).

## Change or remove it later

- **Edit** changes the name, kind and cadence. To move a resource to another account, delete it and
  add it again.
- **Delete resource** stops collection and removes it from the dashboard. Its history stays in the
  database.

npm and PyPI resources can be added to the catalog, but nothing collects them. That is deliberate;
see [Metrics](../reference/metrics.md).

#icicle-insights# #How-To# #Administrator#
