DELETE FROM public.nightly_product_mix_depletions WHERE nightly_product_mix_id = '8240e850-9b33-42b7-8e0d-81a837459fd0';
DELETE FROM public.nightly_product_mix WHERE id = '8240e850-9b33-42b7-8e0d-81a837459fd0';
DELETE FROM public.nightly_reports WHERE id = '011af565-e17e-44fc-8311-5859d7964369';
DELETE FROM public.beverage_boms WHERE pos_item_name = 'TEST Rum & Coke';
DELETE FROM public.beverage_items WHERE name IN ('TEST Rum', 'TEST Coke Syrup');
