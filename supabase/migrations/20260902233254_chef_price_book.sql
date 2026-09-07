-- What the kitchen actually pays, per usable unit.
--
-- A chef does not think in cases. He thinks in ounces on a plate, so the
-- number that matters is cost_per_base_unit -- already normalised by
-- packCodes.js, with catch weight resolved to the billed weight rather than
-- the case estimate.
--
-- One row per item, carrying its most recent price and what that price did
-- last time it moved.

create or replace view public.v_chef_price_book as
with ranked as (
  select
    i.client_id,
    li.item_description,
    li.vendor_item_code,
    i.vendor_name,
    i.invoice_date,
    i.invoice_number,
    li.raw_uom,
    li.standardized_base_unit,
    li.total_base_units,
    li.cost_per_base_unit,
    li.line_total,
    li.is_flagged,
    row_number() over (
      partition by i.client_id, coalesce(li.vendor_item_code, li.item_description)
      order by i.invoice_date desc nulls last, i.created_at desc
    ) as recency,
    lag(li.cost_per_base_unit) over (
      partition by i.client_id, coalesce(li.vendor_item_code, li.item_description)
      order by i.invoice_date asc nulls first, i.created_at asc
    ) as prior_cost
  from invoice_line_items li
  join invoices i on i.id = li.invoice_id
  where li.cost_per_base_unit is not null
)
select
  client_id,
  item_description,
  vendor_item_code,
  vendor_name,
  raw_uom              as pack,
  standardized_base_unit as unit,
  round(total_base_units, 2)   as units_per_purchase,
  round(cost_per_base_unit, 4) as cost_per_unit,
  round(line_total, 2)         as last_line_total,
  invoice_date         as last_seen,
  invoice_number       as last_invoice,
  round(prior_cost, 4) as previous_cost_per_unit,
  case when prior_cost is not null and prior_cost <> 0
       then round((cost_per_base_unit - prior_cost) / prior_cost, 4)
  end as change_pct,
  is_flagged           as needs_review
from ranked
where recency = 1;

comment on view public.v_chef_price_book is
  'One row per item at its latest price, in the unit the kitchen uses. Catch weight is the billed weight, never the case estimate.';
