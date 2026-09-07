-- Add the DEPOSIT category (refundable, never a real cost) that the table was missing.
insert into pnl_categories (code, label, pnl_bucket, in_prime_cost, sort_order)
select 'DEPOSIT', 'Deposits (refundable)', 'other', false, 95
where not exists (select 1 from pnl_categories where code = 'DEPOSIT');

-- Replace the categorizer: emit PAPER / TO_GO / CLEANING / DEPOSIT (the codes the
-- table and the period P&L already support), catch wine/beer/kegs as BEVERAGE, and
-- return NULL for a genuinely unknown line instead of silently defaulting to FOOD.
create or replace function public.mise_pnl_category(vendor_category text, description text)
 returns character varying
 language plpgsql
 immutable
as $function$
declare
  v text := upper(coalesce(vendor_category, ''));
  d text := upper(coalesce(description, ''));
begin
  -- Refundable deposits are not a cost at all (keg/pallet deposits come back).
  if d ~ 'DEPOSIT' then
    return 'DEPOSIT';
  end if;

  -- Fees and freight are never inventory.
  if v like '%MISC%' or d ~ '(FUEL|FREIGHT|DELIVERY|SURCHARGE|SPLIT ?CASE|MIN.*ORDER|PICKUP)' then
    return 'FREIGHT';
  end if;

  -- To-go packaging: what leaves with the guest's food.
  if d ~ '(CONTAINER|CLAMSHELL|TO.?GO|TAKE.?OUT|HINGE|PORTION CUP|SOUFFLE|DELI CUP|CARRYOUT|CARRY.?OUT|\mLID\M)' then
    return 'TO_GO';
  end if;

  -- Paper goods.
  if d ~ '(NAPKIN|TOWEL|TISSUE|\mPAPER\M|\mFOIL\M|PARCHMENT|DOILY|CAN LINER)' then
    return 'PAPER';
  end if;

  -- Cleaning / chemical.
  if v ~ '(CHEMICAL|JANITOR)'
     or d ~ '(DETERGENT|BLEACH|SANITIZER|DEGREAS|CLEANER|DISHWASH|RINSE AID)' then
    return 'CLEANING';
  end if;

  -- Other disposables / supplies (masks, gloves, picks, generic disposable).
  if v ~ '(HEALTHCARE|SUPPL|DISPOSAB|SMALLWARE)'
     or d ~ '(\mMASK\M|GLOVE|BAMBOO|SANDWICH PICK|SKEWER|STIR STICK)' then
    return 'SUPPLIES';
  end if;

  -- Beverage and alcohol: wine varietals, spirits, beer styles, kegs, soda.
  if v ~ '(BEVERAGE|LIQUOR|BEER|WINE|SPIRIT|SODA)'
     or d ~ '(\mWINE\M|CHARD|CABERNET|SAUVIGNON|PINOT|MERLOT|ZINFANDEL|\mROSE\M|PROSECCO|CHAMPAGNE|VIOGNIER|SPARKLING|CHIANTI|MALBEC|SYRAH|RIESLING|GRIGIO|MOSCATO)'
     or d ~ '(VODKA|WHISKEY|WHISKY|BOURBON|TEQUILA|\mGIN\M|\mRUM\M|LIQUOR|COGNAC|BRANDY|APEROL|VERMOUTH)'
     or d ~ '(\mALE\M|LAGER|\mIPA\M|\mSTOUT\M|\mPORTER\M|PILSNER|HEFEWEIZEN|SAISON|KOLSCH|\mBLONDE\M|\mBBL\M|\mKEG\M|BREWING|PALE ALE)'
     or d ~ '(\mSODA\M|\mCOLA\M|LEMONADE|\mTONIC\M)' then
    return 'BEVERAGE';
  end if;

  -- Clear food sections.
  if v ~ '(DAIRY|MEAT|SEAFOOD|FROZEN|PRODUCE|BAKERY|GROCERY|CANNED|DRY|POULTRY|DELI|CHEESE)' then
    return 'FOOD';
  end if;

  -- Genuinely unknown: return NULL so the period-close readiness gate holds it out
  -- of prime cost until a human tags it. An honest gap beats a confident wrong number.
  return null;
end;
$function$;
