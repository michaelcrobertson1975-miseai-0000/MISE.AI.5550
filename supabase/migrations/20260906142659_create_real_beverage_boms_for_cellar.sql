INSERT INTO public.beverage_boms (client_id, pos_item_name, beverage_item_id, serving_size_oz, yield_factor, notes)
SELECT '7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10', v.name, bi.id, v.serving_size, v.yield_factor, v.notes
FROM (VALUES
  ('House Lager', 16, 1.0, 'ASSUMED 16oz pint -- confirm real pour size with Cellar.'),
  ('Cabernet', 6, 1.0, 'ASSUMED 6oz wine pour -- confirm real pour size with Cellar.'),
  ('Mt Dew', 16, 0.125, 'ASSUMED 16oz fountain cup, ~2oz syrup (industry-standard ratio) -- confirm real cup size and mix ratio with Cellar.'),
  ('Pepsi', 16, 0.125, 'ASSUMED 16oz fountain cup, ~2oz syrup -- confirm real cup size and mix ratio with Cellar.'),
  ('Lemonade', 16, 0.125, 'ASSUMED 16oz fountain cup, ~2oz syrup -- confirm real cup size and mix ratio with Cellar.')
) AS v(name, serving_size, yield_factor, notes)
JOIN public.beverage_items bi ON bi.client_id = '7d1f0a2e-6c44-4b9a-9f31-2ab8e5c07d10'
  AND bi.name = CASE v.name
    WHEN 'House Lager' THEN 'Lager At World''s End Keg'
    WHEN 'Cabernet' THEN 'Domaine Bousquet Cab 750ml'
    WHEN 'Mt Dew' THEN 'Mountain Dew Syrup'
    WHEN 'Pepsi' THEN 'Pepsi Cola Syrup'
    WHEN 'Lemonade' THEN 'Tropicana Lemonade Syrup'
  END;
