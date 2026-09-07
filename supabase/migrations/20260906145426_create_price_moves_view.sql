create or replace view public.price_moves as
with priced as (
  select
    i.id            as ingredient_id,
    i.client_id,
    i.name,
    il.cost_per_base_unit,
    il.total_base_units,
    inv.invoice_date,
    lag(il.cost_per_base_unit) over (partition by i.id order by inv.invoice_date) as prev_price,
    array_agg(il.cost_per_base_unit) over (
      partition by i.id order by inv.invoice_date
      rows between 4 preceding and current row
    ) as recent_history
  from invoice_line_items il
  join invoices inv on inv.id = il.invoice_id
  join ingredients i on i.id = il.ingredient_id
  where il.ingredient_id is not null
    and il.removed_by_review is not true
    and il.cost_per_base_unit is not null
    and inv.merged_into is null
),
latest as (
  select distinct on (ingredient_id)
    ingredient_id, client_id, name,
    cost_per_base_unit as new_price,
    prev_price as old_price,
    total_base_units as qty,
    recent_history as history,
    invoice_date
  from priced
  order by ingredient_id, invoice_date desc
)
select *,
  case when old_price is not null and old_price != 0
    then round(((new_price - old_price) / old_price) * 100, 2)
    else null
  end as pct_change
from latest
where old_price is not null;