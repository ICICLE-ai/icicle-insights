# Correct a metric

How to add a reading no collector reports, fix a wrong one, or remove one. For administrators signed
in to the console.

Every change here also moves the matching lifetime total. Read the effect in each section before
you act.

## Record a reading

Use this for a figure you have from elsewhere, such as downloads from a mirror.

1. Open **Metrics** and click **Record reading**.
2. Choose the **Resource** and the **Metric**.
3. Type the **Reading**. It must be 0 or more.
4. Click **Record reading**.

The reading is stamped with the current time. A windowed reading, such as downloads or views, is
also added to its lifetime total.

For a Hugging Face resource, the next collection overwrites lifetime downloads with Hugging Face's
own figure. The hand-entered addition does not survive it.

## Correct a reading

1. On **Metrics**, find the row. The page lists the 100 newest readings.
2. Open its **⋯** menu and choose **Correct reading**.
3. Type the right value and click **Save correction**.

The lifetime total moves by the difference between the old and new value. Lifetime rows cannot be
corrected this way. Their menu says *All-time totals are derived by the server*.

## Delete a reading

1. Open the row's **⋯** menu and choose **Delete reading**.
2. Confirm with **Delete reading**.

The reading is taken back out of its lifetime total. Deleting a lifetime row resets that total
instead. Collection then rebuilds it only from the next uncounted day, not from the beginning.

## Check it worked

Open the resource's page on the public dashboard. Its tiles and charts show the change straight
away.

Background: [How collection works](../explanation/how-collection-works.md) explains lifetime totals.

#icicle-insights# #How-To# #Administrator#
