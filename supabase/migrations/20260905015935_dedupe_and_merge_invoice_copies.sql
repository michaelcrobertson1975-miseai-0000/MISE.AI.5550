-- Eight invoice numbers arrived more than once while we were debugging email
-- routing. Two kinds of copy, and they need opposite treatment:
--
--   TRUE DUPLICATE - the same photo read twice. Identical money, text differing
--     only by punctuation ("Keg, 19.5 L" vs "Keg 19.5 L"). Keep one.
--   PAGE SPLIT - different pages of one invoice ingested separately before the
--     grouping fix. Different line counts, different money. Merge the lines.
--
-- Money is the fingerprint. Text is not: the model punctuates the same item
-- differently on two reads, which made identical invoices look distinct.

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS merged_into uuid REFERENCES public.invoices(id),
  ADD COLUMN IF NOT EXISTS superseded_reason text;

COMMENT ON COLUMN public.invoices.merged_into IS
  'Set when this row was a duplicate or a stray page of another invoice. The row is kept so the ingest history stays auditable; status excludes it from the queue and every report.';

WITH ranked AS (
  SELECT i.id, i.client_id, i.invoice_number, i.vendor_name, i.created_at,
         md5(coalesce(string_agg(li.line_total::text, ',' ORDER BY li.line_total), 'none')) AS money_print,
         count(li.id) AS line_count
    FROM public.invoices i
    LEFT JOIN public.invoice_line_items li
      ON li.invoice_id = i.id AND li.removed_by_review IS NOT TRUE
   WHERE i.invoice_number IS NOT NULL AND i.merged_into IS NULL
   GROUP BY i.id
),
-- One survivor per identical money fingerprint.
dupes AS (
  SELECT id, first_value(id) OVER (
           PARTITION BY client_id, upper(invoice_number), money_print
           ORDER BY created_at, line_count DESC
         ) AS keeper
    FROM ranked
)
UPDATE public.invoices i
   SET merged_into = d.keeper,
       status = 'duplicate',
       superseded_reason = 'Identical line totals to an earlier ingest of the same invoice number.'
  FROM dupes d
 WHERE i.id = d.id AND d.id <> d.keeper;

-- What is left with the same number but different money is a page split: move
-- its lines onto the earliest surviving copy.
WITH survivors AS (
  SELECT i.id, i.client_id, upper(i.invoice_number) AS num, i.created_at,
         row_number() OVER (PARTITION BY i.client_id, upper(i.invoice_number)
                            ORDER BY (i.grand_total IS NULL), i.created_at) AS rn
    FROM public.invoices i
   WHERE i.merged_into IS NULL AND i.invoice_number IS NOT NULL
),
keepers AS (SELECT client_id, num, id AS keeper FROM survivors WHERE rn = 1),
strays  AS (SELECT s.id, k.keeper FROM survivors s JOIN keepers k
             ON k.client_id = s.client_id AND k.num = s.num
           WHERE s.rn > 1)
UPDATE public.invoice_line_items li
   SET invoice_id = s.keeper
  FROM strays s
 WHERE li.invoice_id = s.id;

WITH survivors AS (
  SELECT i.id, i.client_id, upper(i.invoice_number) AS num, i.created_at,
         row_number() OVER (PARTITION BY i.client_id, upper(i.invoice_number)
                            ORDER BY (i.grand_total IS NULL), i.created_at) AS rn
    FROM public.invoices i
   WHERE i.merged_into IS NULL AND i.invoice_number IS NOT NULL
),
keepers AS (SELECT client_id, num, id AS keeper FROM survivors WHERE rn = 1)
UPDATE public.invoices i
   SET merged_into = k.keeper,
       status = 'merged',
       superseded_reason = 'Pages of this invoice were ingested separately before page grouping existed; its lines were moved onto the surviving copy.'
  FROM survivors s
  JOIN keepers k ON k.client_id = s.client_id AND k.num = s.num
 WHERE i.id = s.id AND s.rn > 1;

-- Stop it happening again: one live invoice per number per vendor per client.
CREATE UNIQUE INDEX IF NOT EXISTS invoices_one_live_per_number
  ON public.invoices (client_id, upper(invoice_number), upper(coalesce(vendor_name,'')))
  WHERE merged_into IS NULL AND invoice_number IS NOT NULL;
