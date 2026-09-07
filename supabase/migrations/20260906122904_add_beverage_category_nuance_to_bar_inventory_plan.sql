INSERT INTO public.locker_issues (title, description, area, status) VALUES (
  'Bar/beverage inventory: not all categories share the same BOM math',
  'Refinement to the beer + spirits inventory plans already logged. Wine, spirits, and kegs genuinely share one simple pattern -- a pour is a direct 1:1 depletion, same BOM shape works for all three.

Juice, fountain drinks, and coffee do NOT fit that same simple pattern and need their own conversion step:
- Fountain drinks: you buy syrup, not soda. A 16oz cup poured is a fraction of that in actual syrup used, depending on the machine''s mix ratio. That ratio must be part of the BOM or the numbers are wrong.
- Coffee: bought by weight (beans), sold by brewed volume. Needs its own conversion tied to grind/ratio/yield, not a simple bottle-to-pour depletion.
- Juice: fine as a simple 1:1 pour if used straight; behaves like fountain drinks if it is a diluted concentrate.

Do not build these six categories as one uniform BOM system -- wine/spirits/kegs can share a design, fountain/coffee/diluted-juice each need an extra conversion layer or the depletion math will be quietly wrong.',
  'bar-inventory',
  'open'
);
